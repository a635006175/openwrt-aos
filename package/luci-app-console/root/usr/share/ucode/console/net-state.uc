// SPDX-License-Identifier: Apache-2.0
// 内外网设置后端：按爱快式"接口 = 角色 + 接入方式 + IP 配置"模型
// 读写 /etc/config/network。
//
// 设计要点：
// - 爱快把接口分为「外网（WAN）」与「内网（LAN）」并绑定物理网卡；
//   这里同样以 role(wan/lan) + device 描述，而不是暴露 OpenWrt 的
//   interface 段与 device 段的复杂关系。
// - 内网接口固定使用 static（静态地址）；外网接口支持 static、dhcp（DHCP 客户端）、pppoe（宽带拨号）。
// - 修改 LAN 地址极可能让管理员失联，因此 apply() 支持"确认窗口"：
//   写入后启动一个守护进程，若在窗口期内没有 confirm()，自动还原备份。
// - 只写 network 配置，不改 firewall 区域（防火墙由既有规则与 console 的
//   VPN 模块各自管理）。
// - 编辑弹框的「当前连接信息」需要 MTU / IP / 掩码 / 网关 / 是否默认路由 /
//   DNS / 拨号状态，字段与语义见 tmp/net-detail-contract.md（前后端契约）。
//   所有运行时数据只取自系统真实来源，读不到一律 null，绝不编造，也绝不
//   让 NaN 流进 JSON。

import { readfile, popen, lsdir, stat, rename, unlink, open, mkdir, chmod } from 'fs';

const CONFIG = '/etc/config/network';
const BACKUP = '/etc/console-backup/network.last-good';
const PENDING = '/etc/console-backup/network.pending';
const GUARD = '/usr/libexec/console-net-guard';
const RESOLV_AUTO = '/tmp/resolv.conf.d/resolv.conf.auto';
const MTU_MIN = 68;
const MTU_MAX = 9000;
const MTU_ERROR = 'MTU 必须是 68–9000 之间的整数';

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
function pow2(exp) { let n = 1; for (let i = 0; i < exp; i++) n *= 2; return n; }
function fileExists(path) { return stat(path) != null; }
function isPlainInt(value) { return type(value) == 'int' || type(value) == 'double'; }

/* ----------------------------- IPv4 工具 ----------------------------- */

function validIPv4(value) {
	const m = type(value) == 'string' && match(value, /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
	if (!m) return false;
	for (let i = 1; i <= 4; i++) if (+m[i] > 255 || (length(m[i]) > 1 && substr(m[i], 0, 1) == '0')) return false;
	return true;
}
function ipNumber(text) { let n = 0; for (let part in split(text, '.')) n = n * 256 + +part; return n; }
function ipText(n) { return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255); }
function maskToPrefix(mask) {
	if (!validIPv4(mask)) return null;
	let n = ipNumber(mask), prefix = 0, seenZero = false, divisor = 2147483648;
	for (let i = 0; i < 32; i++) {
		const bit = n >= divisor ? 1 : 0;
		if (bit) { if (seenZero) return null; prefix++; n -= divisor; }
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
// 解析 "192.168.1.1/24" 形式的地址
function splitAddress(value) {
	if (type(value) != 'string') return null;
	const parts = split(trim(value), '/');
	if (!validIPv4(parts[0])) return null;
	let prefix = 24;
	if (length(parts) > 1) { const p = int(+parts[1]); if (p >= 1 && p <= 32) prefix = p; }
	const size = pow2(32 - prefix);
	const ip = ipNumber(parts[0]);
	return { address: parts[0], prefix, network: int(ip / size) * size, broadcast: int(ip / size) * size + size - 1, size };
}

// /proc/net/route 里的地址是「小端 32 位十六进制」：010A10AC => 172.16.10.1。
// 逐字节倒序再拼成点分十进制，避免把 172.16.10.1 读成 1.10.16.172。
function routeHexToIPv4(text) {
	const m = type(text) == 'string' && match(text, /^([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/);
	if (!m) return null;
	const a = hex(m[1]), b = hex(m[2]), c = hex(m[3]), d = hex(m[4]);
	for (let part in [a, b, c, d]) if (part !== part || part < 0 || part > 255) return null;
	return sprintf('%d.%d.%d.%d', d, c, b, a);
}

// 归一化网关地址：0.0.0.0 / :: 表示「链路直连、没有下一跳」，不是可用网关，
// 按契约一律给 null，避免界面把 0.0.0.0 当默认网关显示。
function normGateway(value) {
	if (type(value) != 'string') return null;
	const text = trim(value);
	if (!length(text) || text == '0.0.0.0' || text == '::') return null;
	return text;
}

/* ----------------------------- 设备与角色 ----------------------------- */

// 可选网卡：保留物理网卡与已建立的 br-* 网桥；
// 其余虚拟设备（TUN/TAP 隧道如 cmihomo、cvpns、cvpnc）不属于可绑定网卡。
// 早先「排除所有 br-*」的写法会把 br-lan 从列表里去掉，编辑弹框的
// <select> 因此没有命中项，浏览器默认显示第一项（曾经是 cmihomo），
// 用户点保存就会把 lan.device 写成隧道名，内网直接断开。
function listDevices() {
	const names = [];
	const output = popen('/bin/sh -c "ls /sys/class/net"')?.read?.('all') || '';
	for (let name in split(output, '\n')) {
		const dev = trim(name);
		if (!dev || dev == 'lo') continue;
		if (fileExists('/sys/class/net/' + dev + '/device')) { push(names, dev); continue; }
		if (match(dev, /^br-/)) { push(names, dev); continue; }
	}
	return names;
}

function isPhysicalDevice(name) {
	return fileExists('/sys/class/net/' + name + '/device');
}

function zoneOf(name, zones) {
	for (let zone in zones) {
		const nets = type(zone.network) == 'array' ? zone.network : split(zone.network || '', /\s+/);
		if (index(nets, name) >= 0 && (zone.name == 'wan' || zone.name == 'lan')) return zone.name;
	}
	return null;
}

function listZones() {
	const zones = [];
	const output = popen('/sbin/uci -c /etc/config -q show firewall 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		// zone 段多为匿名段（firewall.@zone[0]=zone）。ucode 正则字符类
		// 对 [ ] 转义支持不完整，这里用 (.+) 通配再回验行尾。
		const m = match(line, /^firewall\.(.+)=zone$/);
		if (!m) continue;
		const section = m[1];
		push(zones, {
			section,
			name: uciGet('firewall.' + section + '.name', ''),
			network: uciGet('firewall.' + section + '.network', '')
		});
	}
	return zones;
}

function interfaceRole(name, zones) {
	return zoneOf(name, zones || listZones()) || (match(name, /^wan/) ? 'wan' : match(name, /^lan/) ? 'lan' : '');
}

// 接口段名 -> 对外描述。只收录 lan/wan/wan6 这类实际联网接口，
// 排除 loopback 与无 device 的虚拟接口。
// 注意：本版本 ucode 不支持函数前向引用，被调用者必须定义在调用者之前，
// 所以 interfaceIds() 放在 validatePorts() 之前（它先用到）。
function interfaceIds() {
	const ids = [];
	const output = popen('/sbin/uci -c /etc/config -q show network 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const m = match(line, /^network\.([A-Za-z0-9_]+)=interface$/);
		if (!m) continue;
		const name = m[1];
		if (name == 'loopback') continue;
		if (!length(uciGet('network.' + name + '.device', ''))) continue;
		push(ids, name);
	}
	return ids;
}

/* ----------------------------- 网桥成员 ----------------------------- */

// uci show 里多值 list 的实际输出形如：
//   network.@device[0].ports='eth2' 'eth3' 'eth4' 'eth5'
// 若按单个空格直接切，得到的是 "'eth3'" 这类带引号的碎片，一个成员也对不上，
// 于是桥成员全被当成"未分配网卡"、占用校验也形同虚设。
// 先去掉所有引号再按空白切分即可。
function splitPorts(text) {
	const ports = [];
	for (let item in split(replace('' + (text || ''), /'/g, ' '), /\s+/)) {
		const port = trim(item);
		if (length(port)) push(ports, port);
	}
	return ports;
}

// 按 name 反查 @device[N] 的序号。N 是配置中 device 段的匿名序号，
// 不是界面顺序；ucode 的 uci 命令必须用这个序号定位匿名段。
function deviceSectionIndex(deviceName) {
	const output = popen('/sbin/uci -c /etc/config -q show network 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const m = match(line, /^network\.@device\[(\d+)\]\.name='(.*)'$/);
		if (m && m[2] == deviceName) return int(m[1]);
	}
	return null;
}

// 某网桥的成员口；不是网桥（或没有该 device 段）返回 null。
function bridgeOf(deviceName) {
	const position = deviceSectionIndex(deviceName);
	if (position == null) return null;
	if (uciGet('network.@device[' + position + '].type', '') != 'bridge') return null;
	return splitPorts(uciGet('network.@device[' + position + '].ports', ''));
}

// 全部网桥成员 -> 所属网桥名。用于占用关系展示与冲突校验。
function bridgeMembership() {
	const map = {};
	const output = popen('/sbin/uci -c /etc/config -q show network 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const m = match(line, /^network\.@device\[(\d+)\]\.ports=(.*)$/);
		if (!m) continue;
		const deviceName = uciGet('network.@device[' + m[1] + '].name', '');
		if (!length(deviceName)) continue;
		for (let port in splitPorts(m[2])) map[port] = deviceName;
	}
	return map;
}

function samePorts(a, b) {
	const left = [], right = [];
	for (let item in a) push(left, trim('' + item));
	for (let item in b) push(right, trim('' + item));
	if (length(left) != length(right)) return false;
	sort(left); sort(right);
	for (let i = 0; i < length(left); i++) if (left[i] != right[i]) return false;
	return true;
}

// 校验桥成员：必须存在、是物理网卡、不能网桥嵌套、不能与其它接口或
// 其它网桥重复占用，且至少保留一个成员（否则 br-* 会失去所有端口）。
function validatePorts(ports, selfName) {
	if (type(ports) != 'array' || !length(ports)) fail('请至少选择一个网卡作为桥成员');
	const result = [];
	const members = bridgeMembership();
	const ownBridge = length(selfName) ? uciGet('network.' + selfName + '.device', '') : '';
	for (let item in ports) {
		const name = trim('' + item);
		if (!length(name) || !match(name, /^[A-Za-z0-9_.-]{1,32}$/)) fail('网卡名称无效');
		if (index(result, name) >= 0) continue;
		if (name == 'lo') fail('不能把 loopback 加入网桥');
		if (!fileExists('/sys/class/net/' + name)) fail('网卡 ' + name + ' 不存在');
		if (match(name, /^br-/)) fail('不能把网桥 ' + name + ' 加入另一个网桥');
		if (!isPhysicalDevice(name)) fail('网卡 ' + name + ' 是虚拟设备（隧道），只能选择物理网卡');
		for (let existing in interfaceIds()) {
			if (existing == selfName) continue;
			if (uciGet('network.' + existing + '.device', '') == name)
				fail('网卡 ' + name + ' 已被接口 ' + existing + ' 使用');
		}
		if (members[name] && members[name] != ownBridge)
			fail('网卡 ' + name + ' 已是网桥 ' + members[name] + ' 的成员');
		push(result, name);
	}
	return result;
}

/* ------------------- 运行时状态采集（每次 currentState 只采一次） ------------------- */

// ubus network.device status 体量大（每个网卡几十个字段），若每个接口各调一次，
// 页面刷新会多出成百上千次进程创建。这里在 currentState() 里只取一次快照，
// 再按设备名分发给所有接口复用。
function readDeviceStatus() {
	const map = {};
	const output = popen('/bin/ubus call network.device status 2>/dev/null')?.read?.('all') || '';
	if (!length(output)) return map;
	try {
		const parsed = json(output);
		if (type(parsed) == 'object' && parsed != null) return parsed;
	}
	catch (e) { /* ubus 不可用时退回空表，字段一律 null */ }
	return map;
}

// 协议辅助进程：网线不插/未拨号时上游不会给出地址，但 pppd/udhcpc/odhcp6c
// 仍在跑，这正是「正在拨号」与「未连接」的区别，所以必须看进程。
// 只扫 /proc/<pid>/cmdline（内核对其每次读取返回完整的 NUL 分隔 argv），
// 不依赖 ps，避免 busybox/ps 输出格式差异。
const PROTO_PROCESSES = [ 'pppd', 'udhcpc', 'odhcp6c' ];
const PROTO_EXPECTED = {
	dhcp: [ 'udhcpc' ],
	pppoe: [ 'pppd' ],
	pppoa: [ 'pppd' ],
	pptp: [ 'pppd' ],
	l2tp: [ 'pppd' ],
	dhcpv6: [ 'odhcp6c' ]
};

function readProtoProcesses() {
	const procs = [];
	const devices = {};
	const deviceNames = lsdir('/sys/class/net') || [];
	for (let name in deviceNames) if (type(name) == 'string' && length(name)) devices[name] = true;

	const entries = lsdir('/proc') || [];
	for (let entry in entries) {
		if (!match(entry, /^[0-9]{1,10}$/)) continue;
		const raw = readfile('/proc/' + entry + '/cmdline');
		if (type(raw) != 'string' || !length(raw)) continue;
		const argv = filter(split(raw, '\u0000'), arg => length(arg));
		if (!length(argv)) continue;
		const base = match(argv[0], /([^\/]+)$/);
		const program = base ? base[1] : argv[0];
		if (index(PROTO_PROCESSES, program) < 0) continue;

		// 从 argv 里认出设备名：udhcpc 用 -i <dev>，odhcp6c 把 <dev> 放在末尾，
		// pppd 用 nic-<dev>。统一做法是「参数去掉 nic- 前缀后能在
		// /sys/class/net 里找到」，这样三种进程用同一套判断，不必各写一份。
		const found = [];
		let ipparam = null;
		for (let i = 0; i < length(argv); i++) {
			const token = argv[i];
			if (token == 'ipparam' && i + 1 < length(argv)) ipparam = argv[i + 1];
			let candidate = token;
			if (match(candidate, /^nic-/)) candidate = substr(candidate, 4);
			if (candidate && candidate != '.' && candidate != '..' && devices[candidate] && index(found, candidate) < 0)
				push(found, candidate);
		}
		push(procs, { pid: int(entry), kind: program, devices: found, iface: ipparam });
	}
	return procs;
}

// 系统当前 IPv4 默认路由：直接读内核路由表（比任何缓存都真实），
// 取「目标/掩码都是 0」且带 RTF_UP 标志、metric 最小的一条。
function readDefaultRoute() {
	const text = readfile('/proc/net/route');
	if (type(text) != 'string' || !length(text)) return null;
	let best = null;
	const lines = split(text, '\n');
	for (let index = 1; index < length(lines); index++) {
		const fields = filter(split(trim(lines[index]), /\s+/), field => length(field));
		if (length(fields) < 8) continue;
		if (fields[1] != '00000000' || fields[7] != '00000000') continue;
		// flags 是十六进制，RTF_UP = 0x0001；没有 UP 位的条目已失效，跳过
		const flags = match(fields[3], /^[0-9a-fA-F]{1,8}$/) ? hex(fields[3]) : 0;
		if (!(flags & 1)) continue;
		const gateway = routeHexToIPv4(fields[2]);
		if (gateway == null) continue;
		const metric = match(fields[6], /^\d{1,9}$/) ? int(fields[6]) : 0;
		if (best != null && metric >= best.metric) continue;
		// 直连默认路由（如 PPP）的网关字段是 0.0.0.0，表示「没有下一跳」；
		// 如实记为 null，不要让界面把 0.0.0.0 当成默认网关显示。
		best = { device: fields[0], gateway: normGateway(gateway), metric };
	}
	return best ? { device: best.device, gateway: best.gateway } : null;
}

// /tmp/resolv.conf.d/resolv.conf.auto 由 netifd 按接口写入：
//   # Interface wan
//   nameserver 114.114.114.114
// 解析成 { wan: [ ... ] }。读不到就给空表（前端会降级为「—」）。
function readResidentDns() {
	const result = {};
	const text = readfile(RESOLV_AUTO);
	if (type(text) != 'string' || !length(text)) return result;
	let current = null;
	for (let line in split(text, '\n')) {
		const header = match(line, /^[#;][ \t]*Interfaces?[ \t]+([^\s]+)/i);
		if (header) {
			current = header[1];
			if (type(result[current]) != 'array') result[current] = [];
			continue;
		}
		const nameserver = match(line, /^nameserver[ \t]+([^\s]+)/i);
		if (nameserver && current != null) {
			const address = trim(nameserver[1]);
			if (length(address) && index(result[current], address) < 0) push(result[current], address);
		}
	}
	return result;
}

// 链路层信息：设备状态快照 + sysfs 的速率/双工。
// 虚拟化网卡上 /sys/class/net/<dev>/speed 是 -1、duplex 是 unknown，
// 契约要求这两种情况返回 null（界面显示「—」），而不是 -1 或 "unknown"。
function buildLink(deviceName, deviceStatus) {
	const queried = length(deviceName) ? deviceName : '';
	const info = length(queried) && deviceStatus[queried] ? deviceStatus[queried] : null;
	const link = {
		device: length(queried) ? queried : null,
		mtu: null,
		carrier: null,
		up: null,
		macaddr: null,
		speed: null,
		duplex: null,
		type: null
	};
	if (info) {
		if (isPlainInt(info.mtu) && info.mtu > 0) link.mtu = int(info.mtu);
		if (type(info.carrier) == 'bool') link.carrier = info.carrier;
		if (type(info.up) == 'bool') link.up = info.up;
		if (type(info.macaddr) == 'string' && length(trim(info.macaddr))) link.macaddr = trim(info.macaddr);
		if (type(info.devtype) == 'string' && length(trim(info.devtype))) link.type = trim(info.devtype);
	}
	if (length(queried)) {
		const speed = trim(readfile('/sys/class/net/' + queried + '/speed') || '');
		if (match(speed, /^\d{1,9}$/)) {
			const value = int(speed);
			if (value > 0) link.speed = value;
		}
		const duplexValue = trim(readfile('/sys/class/net/' + queried + '/duplex') || '');
		if (duplexValue == 'full' || duplexValue == 'half') link.duplex = duplexValue;
	}
	return link;
}

// 找出某接口对应的协议辅助进程。设备名相同的接口（如 wan/wan6 共用 eth1）
// 会同时命中 udhcpc 与 odhcp6c，必须再按 proto 期望的进程类型过滤，
// 否则 wan6 会错误地报成 udhcpc。
function protoProcessOf(name, proto, l3device, device, procs) {
	const expected = PROTO_EXPECTED[proto];
	if (type(expected) != 'array' || !length(expected)) return null;
	const candidates = [];
	if (length(device)) push(candidates, device);
	if (length(l3device) && l3device != device) push(candidates, l3device);
	for (let proc in procs) {
		if (index(expected, proc.kind) < 0) continue;
		let matched = length(proc.iface) && proc.iface == name;
		if (!matched) for (let dev in proc.devices) if (index(candidates, dev) >= 0) { matched = true; break; }
		if (matched) return proc;
	}
	return null;
}

// 契约表：static / connected / dialing / idle / disabled。
// dialText 由后端按 proto + dialState 生成，前端直接展示。
// 「静态」只给真正不涉及拨号的协议（static/none），其它协议（含本表未列出的
// ppp、relay 等）一律按「有没有地址 / 有没有辅助进程」判态，不硬套 static，
// 否则界面上会把一个没连上的动态接口说成「静态地址，无需拨号」。
function dialStateOf(proto, auto, known, up, hasAddress, proc) {
	if (auto == '0') return 'disabled';
	const dialUp = !(proto == 'static' || proto == 'none');
	if (!dialUp) {
		if (known && up !== true) return 'disabled';
		return 'static';
	}
	if (hasAddress) return 'connected';
	if (proc) return 'dialing';
	if (known && up !== true) return 'disabled';
	return 'idle';
}

function dialTextOf(proto, state) {
	if (state == 'static') return '静态地址，无需拨号';
	if (state == 'disabled') return '已停用';
	if (state == 'idle') return '未连接';
	if (state == 'dialing') {
		if (proto == 'pppoe') return '正在拨号';
		if (proto == 'dhcp' || proto == 'dhcpv6') return '正在获取地址';
		return '正在连接';
	}
	// connected
	if (proto == 'dhcp') return '已获取地址';
	if (proto == 'pppoe') return '已拨号成功';
	return '已连接';
}

/* ----------------------------- 读取接口 ----------------------------- */

function readInterface(name, zones, ctx) {
	const device = uciGet('network.' + name + '.device', '');
	const proto = uciGet('network.' + name + '.proto', 'static');
	const auto = uciGet('network.' + name + '.auto', '1');
	zones = zones || listZones();
	const role = interfaceRole(name, zones);

	// 运行状态：是否 up、当前地址
	let runtime = {
		up: false, addresses: [], gateway: null,
		pending: false, uptime: null, l3device: null, ipv6: [], dns: [], defaultRoute: false
	};
	let status = null;
	const statusText = popen('/bin/ubus call network.interface.' + name + ' status 2>/dev/null')?.read?.('all') || '';
	if (length(statusText)) {
		try { status = json(statusText); }
		catch (e) { status = null; }   // 状态读取失败时保持默认值
	}
	const l3device = (status && type(status.l3_device) == 'string' && length(status.l3_device))
		? status.l3_device : '';
	let hasV4DefaultRoute = false;
	if (status) {
		try {
			runtime.up = status.up === true;
			runtime.pending = status.pending === true;
			for (let addr in status['ipv4-address'] || []) {
				const mask = isPlainInt(addr.mask) ? int(addr.mask) : null;
				push(runtime.addresses, {
					address: '' + addr.address,
					mask,
					netmask: mask == null ? null : prefixToMask(mask)
				});
			}
			for (let addr in status['ipv6-address'] || [])
				push(runtime.ipv6, {
					address: '' + addr.address,
					mask: isPlainInt(addr.mask) ? int(addr.mask) : null
				});
			for (let dns in status['dns-server'] || [])
				if (type(dns) == 'string' && length(trim(dns))) push(runtime.dns, trim(dns));
			for (let route in status.route || []) {
				// 只认 IPv4 默认路由（target 0.0.0.0 + mask 0）。IPv6 默认路由的
				// nexthop 可能是 "::" 或 link-local 地址，混进 gateway 会让界面
				// 把 「::」 当成默认网关展示。
				if (route.target == '0.0.0.0' && (route.mask === 0 || route.mask == '0')) {
					hasV4DefaultRoute = true;
					const nexthop = normGateway(route.nexthop);
					if (nexthop != null) runtime.gateway = nexthop;
				}
			}
		}
		catch (e) { /* 字段结构异常时保留已解析部分 */ }
	}
	if (status != null && runtime.up && isPlainInt(status.uptime) && status.uptime >= 0)
		runtime.uptime = int(status.uptime);
	runtime.l3device = length(l3device) ? l3device : (length(device) ? device : null);

	// 链路层：l3_device 优先，回退 interface 段的 device。
	// link.device 记录「实际查询的设备名」，两者都没有时为 null。
	const queried = runtime.l3device || device;
	const link = buildLink(queried, ctx.deviceStatus);

	// 是否系统当前默认路由：内核路由表指向本接口的 l3 设备，且网关一致。
	// 这样 wan/wan6 共用 eth1 时只有真正持有 IPv4 默认路由的那个为 true。
	if (ctx.route && length(ctx.route.device)) {
		const routeMatchesDevice = runtime.l3device == ctx.route.device
			|| (length(device) && device == ctx.route.device);
		runtime.defaultRoute = routeMatchesDevice && hasV4DefaultRoute
			&& (length(ctx.route.gateway) ? runtime.gateway == ctx.route.gateway : true);
	}

	// 拨号状态
	const proc = protoProcessOf(name, proto, runtime.l3device, device, ctx.procs);
	const hasAddress = length(runtime.addresses) > 0 || length(runtime.ipv6) > 0;
	const known = status != null;
	const dialState = dialStateOf(proto, auto, known, runtime.up, hasAddress, proc);
	runtime.dialing = dialState == 'dialing';
	runtime.protoProcess = proc ? proc.kind : null;
	runtime.dialState = dialState;
	runtime.dialText = dialTextOf(proto, dialState);

	const entry = {
		name, device, proto, role,
		// 配置侧：uci 里的原始字符串；未配置为 ""（不是 0，也不是 null）
		mtuOption: uciGet('network.' + name + '.mtu', ''),
		link,
		runtime
	};

	if (proto == 'static') {
		const addr = uciGet('network.' + name + '.ipaddr', '');
		const parsed = splitAddress(addr);
		if (parsed) {
			entry.address = parsed.address;
			entry.prefix = parsed.prefix;
			entry.netmask = prefixToMask(parsed.prefix);
		}
		else {
			entry.address = ''; entry.prefix = 24; entry.netmask = '255.255.255.0';
		}
		entry.gateway = uciGet('network.' + name + '.gateway', '');
		entry.dns = [];
		const dnsText = uciGet('network.' + name + '.dns', '');
		for (let item in split(dnsText, /\s+/)) if (validIPv4(trim(item))) push(entry.dns, trim(item));
	}
	else if (proto == 'pppoe') {
		entry.username = uciGet('network.' + name + '.username', '');
		entry.password = '';   // 不返回密码
		entry.hasPassword = length(uciGet('network.' + name + '.password', '')) > 0;
		entry.ac = uciGet('network.' + name + '.ac', '');
		entry.service = uciGet('network.' + name + '.service', '');
	}
	else if (proto == 'dhcp') {
		entry.hostname = uciGet('network.' + name + '.hostname', '');
		entry.dns = [];
	}

	return entry;
}

function pendingInfo() {
	const text = readfile(PENDING);
	if (!text) return null;
	try {
		const data = json(text);
		const left = int(data.deadline - time());
		if (left <= 0) return null;
		return { deadline: data.deadline, secondsLeft: left, description: data.description || '' };
	}
	catch (e) { return null; }
}

function currentState() {
	const zones = listZones();
	// 以下四类运行时数据各取一次快照，供所有接口复用：
	// ubus 设备状态（大）、协议进程表、内核路由表、resolv.conf.auto。
	const ctx = {
		deviceStatus: readDeviceStatus(),
		procs: readProtoProcesses(),
		route: readDefaultRoute(),
		resident: readResidentDns()
	};
	const interfaces = [];
	for (let name in interfaceIds()) {
		try { push(interfaces, readInterface(name, zones, ctx)); }
		catch (e) { /* 单个接口读取失败不应影响其余 */ }
	}
	// /proc/net/route 读不到时的退路：以「自己持有一条 IPv4 默认路由」的接口为准。
	if (!ctx.route) {
		for (let iface in interfaces) {
			if (iface.runtime && length(iface.runtime.gateway)) {
				iface.runtime.defaultRoute = true;
				ctx.route = { device: iface.runtime.l3device, gateway: iface.runtime.gateway };
				break;
			}
		}
	}
	// 网卡占用：直接绑定的算被该接口用；桥成员算被桥的接口用（爱快视角
	// 下 LAN 卡就是这样"插在 LAN 上"的，不应显示为空闲）。
	const used = {};
	for (let iface in interfaces) if (length(iface.device)) used[iface.device] = iface.name;
	const members = bridgeMembership();
	for (let port, deviceName in members) {
		if (!used[port]) used[port] = deviceName + ' (桥接)';
	}
	// 绑定了网桥的接口附带 bridge 字段，前端据此显示成员与「桥成员」按钮，
	// 不必再自己解析 uci show 的引号格式。
	for (let iface in interfaces) {
		if (!length(iface.device)) continue;
		const ports = bridgeOf(iface.device);
		if (ports) iface.bridge = { name: iface.device, ports };
	}
	const devices = [];
	for (let dev in listDevices()) push(devices, { name: dev, usedBy: used[dev] || null });
	// 系统当前 IPv4 默认路由；没有默认路由时为 null。
	// interface 无法对应到某个接口段时为 null（device/gateway 仍如实给出）。
	let defaultRoute = null;
	if (ctx.route && length(ctx.route.device)) {
		let owner = null;
		for (let iface in interfaces) {
			if (iface.runtime && iface.runtime.defaultRoute === true) { owner = iface.name; break; }
		}
		defaultRoute = { interface: owner, device: ctx.route.device, gateway: ctx.route.gateway };
	}
	return {
		interfaces,
		devices,
		pending: pendingInfo(),
		defaultRoute,
		residentDns: ctx.resident
	};
}

/* ----------------------------- 确认窗口 ----------------------------- */

function ensureDir(path) { mkdir(path, 0700); }

function backupNetwork() {
	ensureDir('/etc/console-backup');
	run(['/bin/sh', '-c', 'cp ' + CONFIG + ' ' + BACKUP]);
}

// 启动守护：到点未确认就还原备份并重启网络
function armGuard(seconds, description) {
	ensureDir('/etc/console-backup');
	const deadline = time() + seconds;
	const fd = open(PENDING, 'w');
	if (!fd) fail('无法创建回滚标记文件');
	chmod(PENDING, 0600);
	fd.write(sprintf('%J\n', { deadline, description, backup: BACKUP }));
	fd.close();
	// 后台守护进程：等待 deadline，若标记仍在则还原
	const script = sprintf(
		'/bin/sh -c \'sleep %d; if [ -f %s ]; then cp %s %s && /etc/init.d/network reload && rm -f %s; fi\' >/dev/null 2>&1 &',
		seconds, PENDING, BACKUP, CONFIG, PENDING);
	run(['/bin/sh', '-c', script]);
	return deadline;
}

function confirmApply() {
	const text = readfile(PENDING);
	if (!text) return { ok: true, alreadyResolved: true };
	unlink(PENDING);
	// 保留本次备份作为 last-good
	return { ok: true, alreadyResolved: false };
}

/* ----------------------------- MTU 选项 ----------------------------- */

// 契约第五节：config.mtu 缺省 = 完全不触碰 uci 的 mtu；
// "" = 删除；68–9000 的整数（允许字符串数字）= 写入。
// 返回 { provided:false } / { provided:true, remove:true } / { provided:true, value:Number }
function mtuOptionOf(input) {
	if (type(input) != 'object') return { provided: false };
	const raw = input.mtu;
	if (raw == null) return { provided: false };
	if (type(raw) == 'string') {
		const text = trim(raw);
		if (!length(text)) return { provided: true, remove: true };
		if (!match(text, /^\d{1,5}$/)) fail(MTU_ERROR);
		const value = int(text);
		if (value < MTU_MIN || value > MTU_MAX) fail(MTU_ERROR);
		return { provided: true, value };
	}
	if (isPlainInt(raw)) {
		const value = int(raw);
		if (value != raw || value < MTU_MIN || value > MTU_MAX) fail(MTU_ERROR);
		return { provided: true, value };
	}
	fail(MTU_ERROR);
	return { provided: false };
}

// 写入 uci：与现值相同则不重复写。删除不存在的选项时 uci 返回非 0，
// 这属于正常情况（本来就是「不配置」），忽略即可。
function applyMtuOption(name, option) {
	const current = uciGet('network.' + name + '.mtu', '');
	if (option.remove) {
		if (length(current)) uci(['delete', 'network.' + name + '.mtu']);
		return;
	}
	if ('' + option.value == current) return;
	uci(['set', 'network.' + name + '.mtu=' + option.value]);
}

/* ----------------------------- 校验 ----------------------------- */

function validateInterface(input, role) {
	if (type(input) != 'object') fail('接口配置格式无效');
	// MTU 只做校验，写入由 applyInterface/createInterface 负责
	mtuOptionOf(input);
	const allowed = ['static', 'dhcp', 'pppoe'];
	if (index(allowed, input.proto) < 0) fail('接入方式无效');
	if (role == 'lan' && input.proto != 'static') fail('内网接口只支持静态地址');

	if (type(input.device) != 'string' || !match(input.device, /^[A-Za-z0-9_.-]{1,32}$/)) fail('网卡名称无效');
	if (!fileExists('/sys/class/net/' + input.device)) fail('网卡 ' + input.device + ' 不存在');
	if (input.device == 'lo') fail('不能将 loopback 用作接口网卡');

	const result = { proto: input.proto, device: input.device };

	if (input.proto == 'static') {
		if (!validIPv4(input.address)) fail('IP 地址无效');
		const prefix = int(+(input.prefix == null ? 24 : input.prefix));
		if (prefix < 1 || prefix > 32) fail('子网掩码无效');
		const parsed = splitAddress(input.address + '/' + prefix);

		// 主机地址不能是网络地址或广播地址
		const ip = ipNumber(parsed.address);
		if (prefix <= 30 && (ip == parsed.network || ip == parsed.broadcast))
			fail('该地址是网络地址或广播地址，不能用作接口 IP');

		if (length(input.gateway)) {
			if (!validIPv4(input.gateway)) fail('网关地址无效');
			const gw = ipNumber(input.gateway);
			if (gw < parsed.network || gw > parsed.broadcast) fail('网关必须与接口 IP 处于同一网段');
			if (gw == ip) fail('网关不能与接口 IP 相同');
		}
		for (let dns in input.dns || []) if (length(dns) && !validIPv4(dns)) fail('DNS 地址无效：' + dns);

		result.address = parsed.address;
		result.prefix = prefix;
		result.gateway = input.gateway || '';
		result.dns = filter(input.dns || [], v => length(v));
	}
	else if (input.proto == 'pppoe') {
		if (type(input.username) != 'string' || !match(input.username, /^[^ ]{1,64}$/)) fail('宽带账号无效');
		const pwd = input.password || '';
		if (length(pwd) && (length(pwd) < 1 || length(pwd) > 128)) fail('宽带密码长度无效');
		if (!length(pwd) && input.keepPassword !== true) fail('请输入宽带密码');
		result.username = input.username;
		result.password = pwd;
		result.keepPassword = input.keepPassword === true;
		result.ac = input.ac || '';
		result.service = input.service || '';
	}
	else if (input.proto == 'dhcp') {
		result.hostname = input.hostname || '';
		if (length(result.hostname) && !match(result.hostname, /^[A-Za-z0-9.-]{1,63}$/)) fail('主机名格式无效');
	}

	return result;
}

/* ----------------------------- 写入 ----------------------------- */

function applyInterface(name, input) {
	if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_]{1,32}$/)) fail('接口名称无效');
	if (name == 'loopback') fail('不能修改 loopback 接口');
	if (!length(uciGet('network.' + name, ''))) fail('接口 ' + name + ' 不存在');

	const role = interfaceRole(name);
	const v = validateInterface(input, role);
	// 契约第五节：仅在显式提供 mtu 时才处理，缺省时完全不触碰该选项
	const mtuOption = mtuOptionOf(input);

	// 记录当前状态用于回滚
	backupNetwork();

	uci(['set', 'network.' + name + '.proto=' + v.proto]);
	uci(['set', 'network.' + name + '.device=' + v.device]);

	// 清空与本次接入方式无关的旧选项，避免残留互相冲突
	for (let key in ['ipaddr', 'netmask', 'gateway', 'dns', 'username', 'password', 'ac', 'service', 'hostname'])
		uci(['delete', 'network.' + name + '.' + key]);

	if (v.proto == 'static') {
		uci(['set', 'network.' + name + '.ipaddr=' + v.address + '/' + v.prefix]);
		if (length(v.gateway)) uci(['set', 'network.' + name + '.gateway=' + v.gateway]);
		for (let dns in v.dns) uci(['add_list', 'network.' + name + '.dns=' + dns]);
	}
	else if (v.proto == 'pppoe') {
		uci(['set', 'network.' + name + '.username=' + v.username]);
		if (length(v.password)) uci(['set', 'network.' + name + '.password=' + v.password]);
		if (length(v.ac)) uci(['set', 'network.' + name + '.ac=' + v.ac]);
		if (length(v.service)) uci(['set', 'network.' + name + '.service=' + v.service]);
	}
	else if (v.proto == 'dhcp' && length(v.hostname)) {
		uci(['set', 'network.' + name + '.hostname=' + v.hostname]);
	}

	if (mtuOption.provided) applyMtuOption(name, mtuOption);

	if (!uci(['commit', 'network'])) { uci(['revert', 'network']); fail('保存网络配置失败'); }

	// LAN 地址变更风险最高：给 120 秒确认窗口，超时自动回滚
	const isLan = role == 'lan';
	const risky = (v.proto == 'static') && isLan;
	let deadline = null;
	if (risky) deadline = armGuard(120, name + ' 改为 ' + v.address + '/' + v.prefix);

	const reloaded = run(['/etc/init.d/network', 'reload']);
	return { reloaded, deadline, state: currentState() };
}

/* ----------------------------- 新增 / 删除 ----------------------------- */

// 爱快的新增接口 = 选角色(外网/内网) + 选网卡 + 填接入方式。
// OpenWrt 里"角色"由防火墙区域体现，所以这里要同时写 interface 段和
// firewall 区域的 network 列表，否则新接口的流量会被防火墙默认拒绝。
function zoneSectionByName(role) {
	for (let zone in listZones()) if (zone.name == role) return zone.section;
	return null;
}

function createInterface(input) {
	if (type(input) != 'object') fail('参数无效');
	const name = input.name;
	if (type(name) != 'string' || !match(name, /^[a-z][a-z0-9_]{0,31}$/)) fail('接口名只能用小写字母开头，含字母数字下划线');
	if (name == 'loopback') fail('接口名不能是 loopback');
	if (length(uciGet('network.' + name, ''))) fail('接口 ' + name + ' 已存在');

	const device = input.device;
	if (type(device) != 'string' || !match(device, /^[A-Za-z0-9_.-]{1,32}$/)) fail('网卡名称无效');
	if (!fileExists('/sys/class/net/' + device)) fail('网卡 ' + device + ' 不存在');
	if (device == 'lo') fail('不能将 loopback 用作接口网卡');

	const role = input.role;
	if (role != 'wan' && role != 'lan') fail('接口角色必须是外网(wan)或内网(lan)');

	// 网卡占用校验：已被接口或桥使用的网卡不能重复分配
	for (let existing in interfaceIds()) {
		if (existing == name) continue;
		if (uciGet('network.' + existing + '.device', '') == device)
			fail('网卡 ' + device + ' 已被接口 ' + existing + ' 使用');
	}
	const members = bridgeMembership();
	if (members[device])
		fail('网卡 ' + device + ' 是桥 ' + members[device] + ' 的成员，不能单独分配');

	// 接入方式校验复用既有逻辑（名称此时还不存在，传 keepPassword 标记）
	const config = {};
	for (let k, v in input) if (k != 'name' && k != 'role') config[k] = v;
	const v = validateInterface(config, role);
	// 与 apply 同样的语义：只有显式提供 mtu 时才写入
	const mtuOption = mtuOptionOf(config);

	// 名称与协议组合不能与既有 IPv6 段冲突：wan6/dhcpv6 由系统自行管理
	if (match(name, /6$/) && v.proto != 'dhcpv6' && role == 'wan')
		fail('以 6 结尾的外网接口名保留给 IPv6，请换个名称');

	backupNetwork();

	uci(['set', 'network.' + name + '=interface']);
	uci(['set', 'network.' + name + '.proto=' + v.proto]);
	uci(['set', 'network.' + name + '.device=' + v.device]);
	uci(['set', 'network.' + name + '.auto=1']);

	if (v.proto == 'static') {
		uci(['set', 'network.' + name + '.ipaddr=' + v.address + '/' + v.prefix]);
		if (length(v.gateway)) uci(['set', 'network.' + name + '.gateway=' + v.gateway]);
		for (let dns in v.dns) uci(['add_list', 'network.' + name + '.dns=' + dns]);
	}
	else if (v.proto == 'pppoe') {
		uci(['set', 'network.' + name + '.username=' + v.username]);
		if (length(v.password)) uci(['set', 'network.' + name + '.password=' + v.password]);
		if (length(v.ac)) uci(['set', 'network.' + name + '.ac=' + v.ac]);
		if (length(v.service)) uci(['set', 'network.' + name + '.service=' + v.service]);
	}
	else if (v.proto == 'dhcp' && length(v.hostname)) {
		uci(['set', 'network.' + name + '.hostname=' + v.hostname]);
	}

	if (mtuOption.provided) applyMtuOption(name, mtuOption);

	// 防火墙区域：把接口加入对应 zone 的 network 列表
	const zoneSection = zoneSectionByName(role);
	if (!zoneSection) { uci(['revert', 'network']); fail('未找到 ' + (role == 'wan' ? '外网(wan)' : '内网(lan)') + ' 防火墙区域，请先在防火墙设置中创建'); }
	uci(['add_list', 'firewall.' + zoneSection + '.network=' + name]);

	if (!uci(['commit', 'network'])) { uci(['revert', 'network']); fail('保存网络配置失败'); }
	if (!uci(['commit', 'firewall'])) {
		// firewall 提交失败时，网络段的提交也要一并撤销，避免留下半个接口
		uci(['revert', 'firewall']);
		run(['/bin/sh', '-c', 'cp ' + BACKUP + ' ' + CONFIG]);
		uci(['revert', 'network']);
		fail('更新防火墙区域失败，已还原本次改动');
	}

	run(['/etc/init.d/network', 'reload']);
	run(['/etc/init.d/firewall', 'reload']);
	return { state: currentState() };
}

function deleteInterface(name) {
	if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_]{1,32}$/)) fail('接口名称无效');
	if (name == 'lan' || name == 'wan' || name == 'loopback') fail('系统接口 ' + name + ' 不能删除');
	if (!length(uciGet('network.' + name, ''))) fail('接口 ' + name + ' 不存在');

	// 拒绝删除仍被 DHCP 引用的接口（会导致 dnsmasq 段悬空）
	if (length(uciGet('dhcp.' + name, '')))
		fail('接口 ' + name + ' 在 DHCP 设置中仍被引用，请先在「DHCP 服务器」清理相关配置');

	backupNetwork();

	// 从防火墙区域移除
	const zones = listZones();
	for (let zone in zones) {
		const nets = type(zone.network) == 'array' ? zone.network : split(zone.network || '', /\s+/);
		if (index(nets, name) >= 0) uci(['del_list', 'firewall.' + zone.section + '.network=' + name]);
	}

	uci(['delete', 'network.' + name]);
	if (!uci(['commit', 'network'])) { uci(['revert', 'network']); fail('删除失败'); }
	if (!uci(['commit', 'firewall'])) { uci(['revert', 'firewall']); uci(['revert', 'network']); fail('更新防火墙失败'); }

	run(['/etc/init.d/network', 'reload']);
	run(['/etc/init.d/firewall', 'reload']);
	return { state: currentState() };
}

/* ----------------------------- 桥成员写入 ----------------------------- */

// 只改 config device 段的 ports，不动 interface 段的地址配置。
// 成员无变化时直接返回 { changed: false }，不写盘、不 reload（避免无谓断网）。
// LAN 角色的桥成员变更可能中断管理通道，沿用既有的 120 秒确认窗口：
// 期间未确认由 armGuard 守护进程自动还原备份。
function applyBridge(name, ports) {
	if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_]{1,32}$/)) fail('接口名称无效');
	if (name == 'loopback') fail('不能修改 loopback 接口');
	if (!length(uciGet('network.' + name, ''))) fail('接口 ' + name + ' 不存在');

	const bridge = uciGet('network.' + name + '.device', '');
	if (!length(bridge)) fail('接口 ' + name + ' 未绑定网卡');
	if (!match(bridge, /^br-/)) fail('接口 ' + name + ' 绑定的 ' + bridge + ' 不是网桥，无法设置成员');

	const position = deviceSectionIndex(bridge);
	if (position == null) fail('找不到网桥 ' + bridge + ' 的设备配置段');
	if (uciGet('network.@device[' + position + '].type', '') != 'bridge')
		fail('设备 ' + bridge + ' 的类型不是 bridge，无法设置成员');

	const next = validatePorts(ports, name);
	const current = splitPorts(uciGet('network.@device[' + position + '].ports', ''));
	if (samePorts(current, next))
		return { changed: false, reloaded: false, deadline: null, state: currentState() };

	const role = interfaceRole(name);

	backupNetwork();

	// 多值 list 必须以「先删除、再逐项 add_list」的方式重建，
	// 直接 set 只会写入一个带空格的单值。
	uci(['delete', 'network.@device[' + position + '].ports']);
	for (let port in next) uci(['add_list', 'network.@device[' + position + '].ports=' + port]);

	if (!uci(['commit', 'network'])) {
		uci(['revert', 'network']);
		run(['/bin/sh', '-c', 'cp ' + BACKUP + ' ' + CONFIG]);
		fail('保存网桥配置失败，已还原本次改动');
	}

	// LAN 桥成员变更同样可能导致失联，套用确认窗口。
	let deadline = null;
	if (role == 'lan') deadline = armGuard(120, name + ' 的桥成员改为 ' + join(' / ', next));

	const reloaded = run(['/etc/init.d/network', 'reload']);
	return { changed: true, reloaded, deadline, state: currentState() };
}

export {
	currentState, applyInterface, validateInterface, interfaceRole, confirmApply, pendingInfo,
	createInterface, deleteInterface, zoneSectionByName,
	applyBridge, validatePorts, bridgeOf,
	validIPv4, maskToPrefix, prefixToMask, splitAddress, listDevices, BACKUP, CONFIG
};
