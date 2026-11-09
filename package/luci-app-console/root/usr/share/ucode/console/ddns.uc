// SPDX-License-Identifier: Apache-2.0
// Console DDNS model on top of ddns-scripts (UCI /etc/config/ddns).
import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, lsdir, stat, popen } from 'fs';
import { writeText } from 'console.security';

const CONFIG = '/etc/config/ddns';
const DEFAULT_DIR = '/usr/share/ddns/default';
const CUSTOM_DIR = '/usr/share/ddns/custom';
const RUN_DIR = '/var/run/ddns';
const LOG_DIR = '/var/log/ddns';
const UPDATER = '/usr/lib/ddns/dynamic_dns_updater.sh';
const INIT = '/etc/init.d/ddns';
const MAX_SERVICES = 32;
const SECTIONS = /^[a-zA-Z][a-zA-Z0-9_]{0,31}$/;

const PROVIDER_LABELS = {
	'aliyun.com': '阿里云',
	'dnspod.cn': 'DNSPod（腾讯云）',
	'dnspod.cn-v3': 'DNSPod（腾讯云 V3）',
	'cloudflare.com-v4': 'Cloudflare',
	'huaweicloud.com': '华为云',
	'oray.com': '花生壳',
	'3322.org': '3322（公云）',
	'no-ip.com': 'No-IP',
	'duckdns.org': 'DuckDNS',
	'afraid.org-keyauth': 'FreeDNS（Key）',
	'afraid.org-basicauth': 'FreeDNS（密码）',
	'dyndns.org': 'DynDNS',
	'changeip.com': 'ChangeIP',
	'he.net': 'Hurricane Electric',
	'namecheap.com': 'Namecheap',
	'godaddy.com-v1': 'GoDaddy',
	'zoneedit.com': 'ZoneEdit'
};

function fail(s) { die(s + '\n'); }
function arr(v) { return type(v) == 'array' ? v : (v == null || v == '') ? [] : [v]; }
function str(v) { return v == null ? '' : '' + v; }
function bool(v) { return v == '1' || v == 1 || v === true; }
function run(args) {
	const p = popen(join(' ', args));
	if (!p) return { code: -1, out: '' };
	const out = p.read('all') || '';
	return { code: p.close(), out };
}
function seconds(value) {
	const n = +value || 0;
	return n > 100000000000 ? int(n / 1000) : n;
}

function scanProviders(dir, custom) {
	let out = [];
	if (!stat(dir)) return out;
	for (let file in lsdir(dir)) {
		if (!match(file, /^[a-zA-Z0-9._-]+\.json$/)) continue;
		let meta = {};
		try { meta = json(readfile(dir + '/' + file)) || {}; } catch (e) { meta = {}; }
		const value = replace(file, /\.json$/, '');
		const name = match(str(meta.name), /^[a-zA-Z0-9._-]+$/) ? meta.name : value;
		push(out, {
			value,
			label: PROVIDER_LABELS[value] || PROVIDER_LABELS[name] || name,
			ipv4: !!meta.ipv4,
			ipv6: !!meta.ipv6,
			custom
		});
	}
	return out;
}

function providers() {
	const seen = {}, out = [];
	for (let item in scanProviders(CUSTOM_DIR, true)) { seen[item.value] = true; push(out, item); }
	for (let item in scanProviders(DEFAULT_DIR, false)) if (!seen[item.value]) push(out, item);
	return sort(out, (a, b) => a.custom == b.custom ? (a.label < b.label ? -1 : a.label > b.label ? 1 : 0) : (a.custom ? -1 : 1));
}

function networks() {
	let list = [];
	const bus = connect();
	if (bus) {
		const dump = bus.call('network.interface', 'dump', {})?.interface || [];
		bus.disconnect();
		for (let d in dump) {
			if (d.interface == 'loopback') continue;
			push(list, {
				name: d.interface,
				up: !!d.up,
				proto: d.proto || '',
				addresses: map(d['ipv4-address'] || [], a => a.address)
			});
		}
	}
	return list;
}

function logLines(section, limit) {
	const path = LOG_DIR + '/' + section + '.log';
	if (!stat(path)) return [];
	const lines = split(readfile(path) || '', '\n');
	const n = limit || 200;
	return slice(lines, max(0, length(lines) - n));
}

function parseLog(section) {
	let lastIP = '', error = '';
	for (let line in logLines(section, 60)) {
		if (!length(trim(line))) continue;
		const ip = match(line, /IP[: ]+'?([0-9a-fA-F:.]+)'?/);
		if (ip && (match(ip[1], /^\d{1,3}(\.\d{1,3}){3}$/) || (index(ip[1], ':') >= 0 && match(ip[1], /^[0-9a-fA-F:.]+$/)))) lastIP = ip[1];
		if (match(line, /(ERROR|Error|failed|Failed|FAILED)/)) error = trim(line);
	}
	return { lastIP, error };
}

function readService(u, name, providerMap) {
	const o = u.get_all('ddns', name) || {};
	const pid = +trim(readfile(RUN_DIR + '/' + name + '.pid') || '0');
	const running = bool(o.enabled) && pid > 0 && !!stat('/proc/' + pid);
	const log = parseLog(name);
	const logStat = stat(LOG_DIR + '/' + name + '.log');
	const upStat = stat(RUN_DIR + '/' + name + '.update');
	const provider = providerMap[o.service_name] || null;
	return {
		id: name,
		enabled: bool(o.enabled),
		running,
		service_name: o.service_name || '',
		provider_label: provider ? provider.label : (o.service_name || ''),
		custom_url: o.update_url || '',
		domain: o.domain || o.lookup_host || '',
		username: o.username || '',
		password_set: length(o.password || '') > 0,
		use_ipv6: bool(o.use_ipv6),
		ip_source: o.ip_source || 'network',
		ip_network: o.ip_network || o.interface || '',
		ip_url: o.ip_url || '',
		ip_interface: o.ip_interface || '',
		check_interval: +o.check_interval || 10,
		check_unit: o.check_unit || 'minutes',
		force_interval: +o.force_interval || 72,
		force_unit: o.force_unit || 'hours',
		last_update: upStat ? seconds(upStat.mtime) : (logStat ? seconds(logStat.mtime) : 0),
		last_ip: log.lastIP,
		error: log.error
	};
}

function state() {
	const u = cursor();
	const list = providers();
	const map = {};
	for (let p in list) map[p.value] = p;
	const services = [];
	u.foreach('ddns', 'service', section => {
		if (length(services) >= MAX_SERVICES) return;
		const name = section['.name'];
		if (name) push(services, readService(u, name, map));
	});
	const global = u.get_all('ddns', 'global') || {};
	return {
		installed: !!stat(UPDATER) && !!stat(INIT),
		version: trim(readfile('/usr/share/ddns/version') || ''),
		services,
		providers: list,
		networks: networks(),
		global: {
			upd_privateip: bool(global.upd_privateip),
			loglines: +global.ddns_loglines || 250
		}
	};
}

function domain(value) {
	const s = trim(str(value));
	const parts = split(s, '@');
	if (length(parts) > 2) fail('域名格式不正确：' + s);
	if (length(parts) == 2 && length(parts[0]) && !match(parts[0], /^[a-zA-Z0-9*]([a-zA-Z0-9*_-]{0,61}[a-zA-Z0-9*])?$/))
		fail('域名格式不正确：' + s);
	const name = parts[length(parts) - 1];
	if (!match(name, /^([a-zA-Z0-9*]([a-zA-Z0-9*_-]{0,61}[a-zA-Z0-9*])?\.)+[a-zA-Z]{2,63}$/))
		fail('域名格式不正确：' + s);
	if (length(s) > 253) fail('域名过长');
	return s;
}

function number(value, min, max, label, fallback) {
	const raw = str(value);
	if (raw === '' && fallback != null) return fallback;
	const n = +value;
	if (!match(raw, /^\d{1,5}$/) || n < min || n > max) fail(label + '必须是 ' + min + ' - ' + max + ' 之间的整数');
	return n;
}

function unit(value, allowed, label) {
	if (index(allowed, value) < 0) fail(label + '只能是 ' + join('、', allowed));
	return value;
}

function validate(src, u, providerMap, netMap) {
	if (type(src) != 'object') fail('服务配置格式不正确');
	const id = str(src.id);
	if (!match(id, SECTIONS)) fail('服务名称只能使用字母、数字、下划线，并以字母开头（最长 32 字符）');
	if (id == 'global') fail('服务名称不能为 global');
	const old = u.get_all('ddns', id) || {};
	const enabled = !!src.enabled;
	const useIPv6 = !!src.use_ipv6;

	let service = trim(str(src.service_name));
	let updateUrl = trim(str(src.custom_url));
	if (!service && length(updateUrl)) service = 'custom';
	if (!service) fail('请选择 DDNS 服务商');
	if (service == 'custom') {
		if (!length(updateUrl)) fail('自定义服务必须填写更新 URL');
		if (!match(updateUrl, /^https?:\/\/[^ ]+$/)) fail('自定义更新 URL 必须以 http:// 或 https:// 开头且不能包含空格');
		if (index(updateUrl, '[DOMAIN]') < 0 || index(updateUrl, '[IP]') < 0)
			fail('自定义更新 URL 必须包含 [DOMAIN] 和 [IP] 占位符');
	}
	else {
		if (!providerMap[service]) fail('未知的 DDNS 服务商：' + service);
		const provider = providerMap[service];
		if (useIPv6 && !provider.ipv6) fail(provider.label + ' 不支持 IPv6');
		updateUrl = '';
	}

	const host = domain(src.domain);
	if (index([ 'aliyun.com', 'dnspod.cn-v3' ], service) >= 0 && !match(host, /^[^@]+@[^@]+$/))
		fail('该服务商要求域名写成“主机记录@域名”，例如 home@example.com');
	// ddns-scripts 用 lookup_host 做解析基线，"host@domain" 不是可解析域名，需还原成 FQDN。
	let lookupHost = host;
	if (substr(lookupHost, 0, 1) == '@') lookupHost = substr(lookupHost, 1);
	lookupHost = replace(lookupHost, '@', '.');
	const username = trim(str(src.username));
	if (length(username) > 256) fail('用户名过长');
	let password = src.password == null ? null : str(src.password);
	if (password == null || password === '') password = old.password != null ? str(old.password) : '';
	if (length(password) > 256) fail('密码过长');

	const source = str(src.ip_source) || 'network';
	if (index(['network', 'web', 'interface'], source) < 0) fail('IP 获取方式不正确');
	let ipNetwork = '', ipUrl = '', ipInterface = '';
	if (source == 'network') {
		ipNetwork = trim(str(src.ip_network));
		if (!ipNetwork) ipNetwork = useIPv6 ? 'wan6' : 'wan';
		if (!netMap[ipNetwork]) fail('网络接口不存在：' + ipNetwork);
	}
	else if (source == 'web') {
		ipUrl = trim(str(src.ip_url));
		if (!length(ipUrl)) ipUrl = 'https://checkip.amazonaws.com';
		if (!match(ipUrl, /^https?:\/\/[^ ]+$/)) fail('在线检测地址必须以 http:// 或 https:// 开头且不能包含空格');
	}
	else {
		ipInterface = trim(str(src.ip_interface));
		if (!match(ipInterface, /^[a-zA-Z0-9_.:@-]{1,32}$/)) fail('网卡名称不正确');
	}

	const checkInterval = number(src.check_interval, 1, 1440, '检查间隔', 10);
	const checkUnit = unit(str(src.check_unit) || 'minutes', ['minutes', 'hours'], '检查间隔单位');
	const forceInterval = number(src.force_interval, 0, 8760, '强制更新间隔', 72);
	const forceUnit = unit(str(src.force_unit) || 'hours', ['hours', 'days'], '强制更新间隔单位');

	const options = {
		enabled: enabled ? '1' : '0',
		service_name: service,
		domain: host,
		lookup_host: lookupHost,
		username,
		password,
		use_ipv6: useIPv6 ? '1' : '0',
		ip_source: source,
		interface: source == 'network' ? ipNetwork : (useIPv6 ? 'wan6' : 'wan'),
		ip_network: ipNetwork,
		ip_url: ipUrl,
		ip_interface: ipInterface,
		check_interval: '' + checkInterval,
		check_unit: checkUnit,
		force_interval: '' + forceInterval,
		force_unit: forceUnit,
		retry_interval: '60',
		retry_unit: 'seconds',
		retry_max_count: '0',
		use_logfile: '1',
		use_syslog: '2',
		use_https: '0',
		update_url: updateUrl
	};
	return { id, options };
}

function reload() {
	if (!stat(INIT)) return { ok: false, message: 'ddns-scripts 未安装' };
	const result = run([INIT, 'restart']);
	return { ok: result.code == 0, message: trim(result.out) };
}

function apply(cfg) {
	if (type(cfg) != 'object' || type(cfg.services) != 'array') fail('配置格式不正确');
	if (length(cfg.services) > MAX_SERVICES) fail('最多支持 ' + MAX_SERVICES + ' 个 DDNS 服务');

	const u = cursor();
	const netMap = {};
	for (let n in networks()) netMap[n.name] = n;
	const providerMap = {};
	for (let p in providers()) providerMap[p.value] = p;

	const current = [];
	u.foreach('ddns', 'service', section => {
		if (section['.name']) push(current, section['.name']);
	});

	const names = {}, next = [];
	for (let item in cfg.services) {
		const service = validate(item, u, providerMap, netMap);
		if (names[service.id]) fail('服务名称重复：' + service.id);
		names[service.id] = true;
		push(next, service);
	}

	const backup = readfile(CONFIG) || '';
	try {
		for (let name in current)
			if (!names[name]) u.delete('ddns', name);
		for (let service in next) {
			if (index(current, service.id) >= 0) u.delete('ddns', service.id);
			u.set('ddns', service.id, 'service');
			for (let key, value in service.options)
				if (value !== '') u.set('ddns', service.id, key, value);
		}
		const global = type(cfg.global) == 'object' ? cfg.global : {};
		u.set('ddns', 'global', 'ddns');
		u.set('ddns', 'global', 'ddns_dateformat', '%F %R');
		u.set('ddns', 'global', 'ddns_loglines', '' + number(global.loglines, 50, 2000, '日志行数', 250));
		u.set('ddns', 'global', 'upd_privateip', global.upd_privateip ? '1' : '0');
		if (!u.commit('ddns')) fail('保存 DDNS 配置失败');
	} catch (e) {
		try { writeText(CONFIG, backup); } catch (restore) {}
		fail(e.message);
	}

	const result = reload();
	const data = state();
	data.reloaded = result.ok;
	if (!result.ok) data.warning = result.message || 'DDNS 服务重启失败';
	return data;
}

function log(section) {
	if (!match(str(section), SECTIONS)) fail('服务名称不正确');
	return { section, lines: logLines(section, 300) };
}

function probe() {
	const result = reload();
	if (!result.ok) fail(result.message || 'DDNS 服务重启失败');
	return state();
}

export { state, apply, log, probe, providers, networks };
