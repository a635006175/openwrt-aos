// SPDX-License-Identifier: Apache-2.0
// DHCP 服务器设置后端：按爱快式地址池模型读写 /etc/config/dhcp。
//
// 设计取舍：
// - 爱快以"起始/结束 IP + 网关 + DNS + 租期"描述地址池，而 OpenWrt 的
//   dnsmasq 用 "start 偏移量 + limit 数量"。本模块对外只暴露起止 IP，
//   内部换算成 start/limit，避免用户手工算偏移。
// - 静态绑定写 dhcp host 段（mac + ip），并同步 hostname 以便解析。
// - 只读写 dhcp 配置；不写 network，不动其他服务配置。
// - 写操作前必然保留原文件副本，失败时回滚。

import { open, readfile, rename, unlink, stat, popen } from 'fs';

const CONFIG = '/etc/config/dhcp';
const BACKUP = '/etc/console-backup/dhcp.last-good';

function fail(message) { die(message + '\n'); }
function run(args) { return system(args) == 0; }

function uci(args) {
	const command = ['/sbin/uci', '-c', '/etc/config'];
	for (let arg in args) push(command, arg);
	return run(command);
}

function uciGet(key, fallback) {
	const out = trim(popen('/sbin/uci -c /etc/config -q get ' + key + ' 2>/dev/null')?.read?.('all') || '');
	return length(out) ? out : fallback;
}

/* ----------------------------- IPv4 工具 ----------------------------- */

function validIPv4(value) {
	const m = type(value) == 'string' && match(value, /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
	if (!m) return false;
	for (let i = 1; i <= 4; i++) if (+m[i] > 255 || (length(m[i]) > 1 && substr(m[i], 0, 1) == '0')) return false;
	return true;
}
function ipNumber(text) { let n = 0; for (let part in split(text, '.')) n = n * 256 + +part; return n; }
// ucode 没有 Math 对象，按位移算 2 的幂。
function pow2(exp) { let n = 1; for (let i = 0; i < exp; i++) n *= 2; return n; }
function ipText(n) { return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255); }

// 点分掩码 <-> 前缀长度
// ucode 不支持无符号右移(>>>)，用除法代替：从高位往低位累计连续的 1。
function maskToPrefix(mask) {
	if (!validIPv4(mask)) return null;
	let n = ipNumber(mask);
	let prefix = 0, seenZero = false;
	let divisor = 2147483648; // 2^31
	for (let i = 0; i < 32; i++) {
		const bit = n >= divisor ? 1 : 0;
		if (bit) {
			if (seenZero) return null; // 1 出现在 0 之后 -> 非连续掩码
			prefix++;
			n -= divisor;
		}
		else seenZero = true;
		divisor = int(divisor / 2);
	}
	return prefix;
}
function prefixToMask(prefix) {
	prefix = int(prefix);
	if (prefix < 0 || prefix > 32) return null;
	let n = 0;
	for (let i = 0; i < prefix; i++) n = n * 2 + 1;
	for (let i = prefix; i < 32; i++) n = n * 2;
	return ipText(n);
}

/* ----------------------------- 读取状态 ----------------------------- */

// 从 dhcp section 推算地址池起止 IP。
// OpenWrt 的 start 是相对网络地址的偏移量，limit 是数量。
function poolRange(section, lanAddress, lanPrefix) {
	if (!lanAddress || lanPrefix == null) return null;
	const size = pow2(32 - lanPrefix);
	const base = int(ipNumber(lanAddress) / size) * size;
	const start = section.start == null ? 100 : int(+section.start);
	const limit = section.limit == null ? 150 : int(+section.limit);
	if (!(limit > 0)) return null;
	const first = base + start, last = min(base + size - 2, base + start + limit - 1);
	return { startIP: ipText(first), endIP: ipText(last), start, limit };
}

function lanNetwork() {
	// network.lan.ipaddr 里可能带 /24 后缀；先剥离再校验。
	const raw = uciGet('network.lan.ipaddr', '192.168.1.1');
	const parts = split(raw, '/');
	const address = trim(parts[0]);
	if (!validIPv4(address)) return null;

	let prefix = null;
	// 优先用 netmask（prefixToMask 的逆运算），其次用 ipaddr 里的 /n
	const netmask = uciGet('network.lan.netmask', '');
	if (length(netmask)) { const p = maskToPrefix(netmask); if (p != null) prefix = p; }
	if (prefix == null && length(parts) > 1) {
		const p = int(+trim(parts[1]));
		if (p >= 1 && p <= 32) prefix = p;
	}
	if (prefix == null) prefix = 24;
	return { address, prefix };
}

function listHosts() {
	const result = [];
	const output = popen('/sbin/uci -c /etc/config -q show dhcp 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const m = match(line, /^dhcp\.([A-Za-z0-9_]+)=host$/);
		if (!m) continue;
		const name = m[1];
		const mac = uciGet(`dhcp.${name}.mac`, '');
		const ip = uciGet(`dhcp.${name}.ip`, '');
		const hostname = uciGet(`dhcp.${name}.name`, '');
		if (!mac && !ip) continue;
		push(result, { section: name, mac, ip, hostname, enabled: uciGet(`dhcp.${name}.ignore`, '0') != '1' });
	}
	return result;
}

function listDhcpOptions() {
	// dnsmasq 的 list dhcp_option：形如 "6,223.5.5.5,114.114.114.114"
	const out = popen('/sbin/uci -c /etc/config -q get dhcp.lan.dhcp_option 2>/dev/null')?.read?.('all') || '';
	const options = [];
	for (let line in split(out, '\n')) {
		const text = trim(line);
		if (text) push(options, text);
	}
	return options;
}

// 配置写了"启用"不代表真的在分配地址：
// OpenWrt 的 dhcp_check() 若在同网段探测到其他 DHCP 服务器，会把标记写成 1
// 并跳过该接口，生成的 dnsmasq 配置里就不会有 dhcp-range。
// 这里把"实际是否在服务"单独暴露，避免界面把配置状态当成运行状态。
function leaseCount() {
	const text = readfile('/tmp/dhcp.leases') || '';
	let count = 0;
	for (let line in split(text, '\n')) if (length(trim(line))) count++;
	return count;
}

function runtimeState() {
	const output = popen('/bin/sh -c "grep -l . /var/etc/dnsmasq.conf.* 2>/dev/null | head -1"')?.read?.('all') || '';
	const confFile = trim(output);
	let ranges = 0, blocked = false;
	if (length(confFile)) {
		const text = readfile(confFile) || '';
		for (let line in split(text, '\n'))
			if (match(trim(line), /^dhcp-range=/)) ranges++;
	}
	// dhcp_check 的缓存标记：1 表示因检测到其他 DHCP 服务器而放弃该接口
	const stamps = popen('/bin/sh -c "cat /tmp/run/dnsmasq.*.br-lan.dhcp 2>/dev/null"')?.read?.('all') || '';
	for (let value in split(stamps, '\n')) if (trim(value) == '1') blocked = true;

	const serving = ranges > 0;
	return {
		serving: serving,          // dnsmasq 真的加载了 dhcp-range
		rangeCount: ranges,
		blocked: blocked,          // 被 dhcp_check 挡住
		leases: leaseCount()
	};
}

function currentState() {
	const lan = lanNetwork();
	const pool = { start: uciGet('dhcp.lan.start', '100'), limit: uciGet('dhcp.lan.limit', '150') };
	const range = lan ? poolRange(pool, lan.address, lan.prefix) : null;
	const options = listDhcpOptions();
	let gateway = uciGet('dhcp.lan.gateway', '');
	const dns = [];
	for (let option in options) {
		const parts = split(option, ',');
		const code = trim(parts[0]);
		if (code == '3' && length(parts) > 1 && !length(gateway)) gateway = trim(parts[1]);
		if (code == '6') for (let i = 1; i < length(parts); i++) {
			const v = trim(parts[i]);
			if (v && length(dns) < 2) push(dns, v);
		}
	}
	return {
		lan: lan,
		enabled: uciGet('dhcp.lan.ignore', '0') != '1',
		dynamicdhcp: uciGet('dhcp.lan.dynamicdhcp', '1') != '0',
		force: uciGet('dhcp.lan.force', '0') == '1',
		pool: range,
		leasetime: uciGet('dhcp.lan.leasetime', '12h'),
		gateway: length(gateway) ? gateway : (lan ? lan.address : ''),
		dns: dns,
		domain: uciGet('dhcp.@dnsmasq[0].domain', 'lan'),
		ra: uciGet('dhcp.lan.ra', 'server'),
		hosts: listHosts(),
		runtime: runtimeState()
	};
}

function leaseTimeSeconds(text) {
	const m = type(text) == 'string' && match(text, /^(\d+)([smhdw]?)$/i);
	if (!m) return null;
	const n = +m[1], unit = lc(m[2] || 's');
	const factors = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 };
	return n * (factors[unit] || 1);
}

/* ----------------------------- 校验 ----------------------------- */

// MAC 规范化必须先于 validate 定义：ucode 的函数声明不提升。
function normalizeMac(value) {
	if (type(value) != 'string') return null;
	const text = replace(trim(value), /[^0-9A-Fa-f]/g, '');
	if (length(text) != 12) return null;
	let out = [];
	for (let i = 0; i < 12; i += 2) push(out, uc(substr(text, i, 2)));
	return join(':', out);
}

function validate(input) {
	if (type(input) != 'object') fail('配置格式无效');
	const lan = lanNetwork();
	if (!lan) fail('无法读取 LAN 接口地址，请先在“接口”页配置 LAN');

	if (type(input.startIP) != 'string' || !validIPv4(input.startIP)) fail('起始 IP 无效');
	if (type(input.endIP) != 'string' || !validIPv4(input.endIP)) fail('结束 IP 无效');
	const first = ipNumber(input.startIP), last = ipNumber(input.endIP);
	if (first > last) fail('起始 IP 不能大于结束 IP');

	const size = pow2(32 - lan.prefix);
	const base = int(ipNumber(lan.address) / size) * size;
	const router = ipNumber(lan.address);
	const broadcast = base + size - 1;
	if (first <= base) fail('起始 IP 必须大于网络地址 ' + ipText(base));
	if (last >= broadcast) fail('结束 IP 必须小于广播地址 ' + ipText(broadcast));
	if (first == router || last == router) fail('地址池不能包含路由器自身地址 ' + lan.address);
	if (router > first && router < last) fail('地址池不能跨越路由器自身地址 ' + lan.address);
	const limit = last - first + 1;
	if (limit < 2) fail('地址池至少需要 2 个地址');

	const gateway = input.gateway || lan.address;
	if (!validIPv4(gateway)) fail('网关地址无效');
	if (ipNumber(gateway) < base || ipNumber(gateway) > broadcast) fail('网关必须与 LAN 处于同一网段');

	const dns = filter(type(input.dns) == 'array' ? input.dns : [], v => length(v));
	for (let entry in dns) if (!validIPv4(entry)) fail('DNS 地址无效：' + entry);
	if (length(dns) > 2) fail('DNS 最多填写 2 个');

	const seconds = leaseTimeSeconds(input.leasetime || '');
	if (seconds == null) fail('租期格式无效，示例：12h、1d、30m');
	if (seconds < 120) fail('租期不能短于 2 分钟');

	// 静态绑定校验
	const hosts = type(input.hosts) == 'array' ? input.hosts : [];
	const seenMac = {}, seenIP = {};
	let hostState = [];
	for (let host in hosts) {
		const mac = normalizeMac(host.mac);
		if (!mac) fail('静态绑定的 MAC 地址无效：' + (host.mac || '(空)'));
		const ip = host.ip;
		if (!validIPv4(ip)) fail('静态绑定的 IP 无效：' + (ip || '(空)'));
		const value = ipNumber(ip);
		if (value <= base || value >= broadcast) fail('静态绑定 ' + ip + ' 不在 LAN 网段内');
		if (value == router) fail('静态绑定不能使用路由器地址 ' + lan.address);
		if (seenMac[mac]) fail('MAC 地址重复：' + mac);
		if (seenIP[ip]) fail('IP 地址重复：' + ip);
		seenMac[mac] = true; seenIP[ip] = true;
		const section = host.section && match(host.section, /^[A-Za-z0-9_]+$/) ? host.section : null;
		push(hostState, { section, mac, ip, hostname: host.hostname || '' });
	}

	return { lan, base, broadcast, first, last, limit, startOffset: first - base, dns, hostState, gateway, seconds };
}

/* ----------------------------- 写入 ----------------------------- */

function backup() {
	run(['/bin/sh', '-c', 'mkdir -p /etc/console-backup && cp /etc/config/dhcp ' + BACKUP]);
}

function apply(input) {
	const v = validate(input);

	// 先备份，出错可回滚
	backup();

	const commit = () => {
		if (!uci(['commit', 'dhcp'])) { uci(['revert', 'dhcp']); fail('保存 DHCP 配置失败'); }
	};

	// 地址池
	uci(['set', 'dhcp.lan.start=' + v.startOffset]);
	uci(['set', 'dhcp.lan.limit=' + v.limit]);
	uci(['set', 'dhcp.lan.leasetime=' + input.leasetime]);
	uci(['set', 'dhcp.lan.ignore=' + (input.enabled ? '0' : '1')]);
	uci(['set', 'dhcp.lan.dynamicdhcp=' + (input.dynamicdhcp == false ? '0' : '1')]);
	uci(['set', 'dhcp.lan.force=' + (input.force ? '1' : '0')]);
	if (v.gateway && v.gateway != v.lan.address) uci(['set', 'dhcp.lan.gateway=' + v.gateway]);
	else uci(['delete', 'dhcp.lan.gateway']);

	// DHCP 选项：dnsmasq 用 `list dhcp_option`，格式 "选项号,值[,值]"
	// 3 = 默认网关，6 = DNS 服务器。先清空再写，避免残留旧选项。
	uci(['delete', 'dhcp.lan.dhcp_option']);
	if (v.gateway && v.gateway != v.lan.address)
		uci(['add_list', 'dhcp.lan.dhcp_option=3,' + v.gateway]);
	if (length(v.dns))
		uci(['add_list', 'dhcp.lan.dhcp_option=6,' + join(',', v.dns)]);

	// 静态绑定：清空后重建，保持输入顺序
	const output = popen('/sbin/uci -c /etc/config -q show dhcp 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const m = match(line, /^dhcp\.([A-Za-z0-9_]+)=host$/);
		if (m) uci(['delete', 'dhcp.' + m[1]]);
	}
	for (let host in v.hostState) {
		const section = 'console_' + replace(lower(host.mac), /:/g, '');
		uci(['set', 'dhcp.' + section + '=host']);
		uci(['set', 'dhcp.' + section + '.mac=' + host.mac]);
		uci(['set', 'dhcp.' + section + '.ip=' + host.ip]);
		uci(['set', 'dhcp.' + section + '.name=' + (host.hostname || '').replace(/[^\x20-\x7e]/g, '')]);
	}

	commit();

	// 重启 dnsmasq 使租约与绑定生效
	const restarted = run(['/etc/init.d/dnsmasq', 'restart']);
	return { state: currentState(), restarted };
}

export { currentState, apply, validate, normalizeMac, validIPv4, prefixToMask, maskToPrefix, leaseTimeSeconds, lanNetwork, poolRange, BACKUP, CONFIG };
