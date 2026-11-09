// SPDX-License-Identifier: Apache-2.0
// 流控分流配置模型：默认值、规范化校验、线路/拓扑解析、终端枚举与能力探测。
// 只做纯数据变换与只读探测，不写任何生效态（生效由 flow-engine.uc 负责）。
import { readfile, stat } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import {
	CONFIG, DOMAINS, MAX_LINES, MAX_RULES, MAX_LIMITS,
	MARK_BASE, TABLE_BASE, PRIO_BASE,
	fail, readJson, writeText, ensure, ip4, cidr4, inCidr4
} from 'console.flow-util';

const DEFAULT_TARGETS = ['223.5.5.5', '119.29.29.29'];
const LINE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/;
const IFACE_NAME = /^[A-Za-z0-9_]+$/;
const DOMAIN_NAME = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
const MAC_ADDRESS = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;

function defaultConfig() {
	return {
		revision: 0,
		enabled: false,
		lines: [],
		load: { enabled: false, mode: 'weighted', sticky: true, check: { enabled: true, interval: 10, fail: 3, up: 2, targets: [...DEFAULT_TARGETS] } },
		proto: [],
		port: [],
		domain: [],
		updown: { enabled: false, upload: '', download: '', uploadKbps: 0, downloadKbps: 0 },
		smart: { enabled: false, perIpUpKbps: 0, perIpDownKbps: 0, totalUpKbps: 0, totalDownKbps: 0, exempt: [], maxDevices: 256 },
		limit: []
	};
}

// 读盘：文件缺失 → 默认配置；文件损坏 → 抛中文错误（由 rpcd state 层降级展示，
// 页面仍能打开并提示“重置”，不会白屏）。
function config() {
	const raw = readfile(CONFIG);
	if (!length(trim(raw || ''))) return defaultConfig();
	let parsed = null;
	try { parsed = json(raw); } catch (e) { fail('流控分流配置文件已损坏，请点击“重置配置”或恢复 /etc/console-backup/flow.config.last-good'); }
	if (type(parsed) != 'object') fail('流控分流配置文件格式不正确，请重置配置');
	const result = defaultConfig();
	const revision = int(+(parsed.revision || 0));
	result.revision = revision > 0 ? revision : 0;
	if (type(parsed.enabled) == 'bool') result.enabled = parsed.enabled;
	for (let key in ['lines', 'proto', 'port', 'domain', 'limit']) if (type(parsed[key]) == 'array') result[key] = parsed[key];
	for (let key in ['load', 'updown', 'smart']) if (type(parsed[key]) == 'object') result[key] = parsed[key];
	return result;
}
function writeConfig(model) { ensure(); writeText(CONFIG, sprintf('%J\n', model)); }

// —— 基础校验 ——
// 文本字段：undefined/null 一律视为空串（可选字段），必填由调用处单独判断。
function text(value, label, limit) {
	if (value == null) return '';
	if (type(value) != 'string') fail(label + '格式不正确');
	const trimmed = trim(value);
	if (limit && length(trimmed) > limit) fail(label + '最多 ' + limit + ' 个字符');
	return trimmed;
}
function identifier(value, label) {
	const body = text(value, label + '标识', 32);
	if (!match(body, LINE_ID)) fail(label + '标识只能由字母、数字、下划线和减号组成，且必须以字母或数字开头');
	return body;
}
function rate(value, label) {
	if (value == null || value === '') return 0;
	const raw = '' + value;
	if (!match(raw, /^\d{1,8}$/)) fail(label + '必须是 0 到 10000000 之间的整数（单位 Kbps）');
	const number = int(+raw);
	if (number > 10000000) fail(label + '不能超过 10000000 Kbps');
	return number;
}
function intInRange(value, label, low, high, fallback) {
	if (value == null || value === '') return fallback;
	const raw = '' + value;
	if (!match(raw, /^\d{1,6}$/)) fail(label + '必须是整数');
	const number = int(+raw);
	if (number < low || number > high) fail(label + '必须在 ' + low + ' 到 ' + high + ' 之间');
	return number;
}
// ucode 的字符串没有 .trim() 方法（内建只有 trim() 函数），这里必须调函数。
function lined(value) { return trim(value || ''); }

// 端口串：与 console-portmap 同一套规则，用户在两处看到同样的报错文案。
function parsePorts(value) {
	const body = text(value, '端口', 400);
	if (!length(body)) return [];
	const parts = [];
	for (let piece in split(replace(body, /\s/g, ''), ',')) {
		// ucode 正则不支持非捕获分组 (?:...)，一律用捕获分组：
		// matched[1]=起始端口，matched[2]="-\d+" 整体，matched[3]=结束端口。
		const matched = match(piece, /^([0-9]{1,5})(-([0-9]{1,5}))?$/);
		if (!matched) fail('端口只能用逗号分隔的数字或“起始-结束”，例如 80,443,8000-8100');
		const start = +matched[1], end = matched[3] ? +matched[3] : start;
		if (start < 1 || end > 65535 || start > end) fail('端口范围必须在 1-65535 之间，且起始不大于结束');
		for (let existing in parts) if (start <= existing.end && end >= existing.start) fail('同一规则里的端口段不能重叠');
		push(parts, { start, end, text: start == end ? '' + start : start + '-' + end });
	}
	if (length(parts) > 16) fail('单条规则最多 16 个端口或端口段');
	return parts;
}
// 源地址串：逗号分隔的 IPv4 地址/CIDR，统一归一到网络地址并按数值排序。
function parseSources(value) {
	const body = text(value, '来源网段', 400);
	if (!length(body)) return '';
	const parsed = [];
	for (let piece in split(replace(body, /\s/g, ''), ',')) {
		const item = cidr4(piece);
		if (!item) fail('来源网段必须是 IPv4 地址或 CIDR，例如 192.168.1.0/24');
		push(parsed, item);
	}
	const unique = {};
	for (let item in parsed) unique[item.value] = true;
	const ordered = sort(keys(unique), (a, b) => ip4(split(a, '/')[0]) - ip4(split(b, '/')[0]));
	return join(',', ordered);
}
function protocol(value, label) {
	if (index(['tcp', 'udp', 'tcp+udp'], value) < 0) fail(label + '协议必须是 TCP、UDP 或 TCP+UDP');
	return value;
}
function domainName(value) {
	const body = lc(text(value, '域名', 253));
	if (ip4(body) != null) fail('域名分流不接受 IP 地址：' + body + '（请使用端口分流）');
	if (!match(body, DOMAIN_NAME)) fail('域名格式不正确：' + body);
	return body;
}
function lineReference(value, lineIds, label) {
	if (value == null || value === '' || value === 'auto') return 'auto';
	const body = text(value, label, 32);
	if (index(lineIds, body) < 0) fail(label + '引用了不存在的线路：' + body);
	return body;
}

// 校验并返回规范化配置。top 为 undefined 时跳过“接口必须存在”的核对。
function normalize(input, top) {
	if (type(input) != 'object') fail('配置格式不正确');
	const model = defaultConfig();
	model.revision = int(+(input.revision || 0));
	if (model.revision < 0) fail('配置版本号无效');
	model.enabled = input.enabled === true;

	const inputLines = input.lines == null ? [] : input.lines;
	if (type(inputLines) != 'array') fail('线路列表格式不正确');
	if (length(inputLines) > MAX_LINES) fail('最多支持 ' + MAX_LINES + ' 条线路');
	const lineIds = [], seenLines = {}, knownInterfaces = top ? map(top.interfaces, item => item.name) : [];
	for (let line in inputLines) {
		const id = identifier(line.id, '线路');
		if (seenLines[id]) fail('线路标识重复：' + id);
		seenLines[id] = true;
		push(lineIds, id);
		const name = text(line.name, '线路名称', 64);
		if (!length(name)) fail('线路名称不能为空');
		const iface = text(line.interface, '线路接口', 32);
		if (!match(iface, IFACE_NAME)) fail('线路接口名不正确：' + iface);
		if (top && index(knownInterfaces, iface) < 0) fail('线路「' + name + '」引用的接口 ' + iface + ' 不存在，请先在「内外网设置」中添加外网接口');
		const weight = intInRange(line.weight, '线路「' + name + '」权重', 1, 100, 1);
		push(model.lines, {
			id, name, interface: iface, weight,
			enabled: line.enabled === true,
			upKbps: rate(line.upKbps, '线路「' + name + '」上行带宽'),
			downKbps: rate(line.downKbps, '线路「' + name + '」下行带宽')
		});
	}

	if (input.load != null) {
		if (type(input.load) != 'object') fail('多线负载配置格式不正确');
		const load = input.load;
		model.load.enabled = load.enabled === true;
		if (load.mode != null) {
			if (index(['weighted', 'failover'], load.mode) < 0) fail('多线负载模式只能是按权重分配或故障切换');
			model.load.mode = load.mode;
		}
		model.load.sticky = load.sticky == null ? true : load.sticky === true;
		const check = type(load.check) == 'object' ? load.check : {};
		const targets = [];
		if (check.targets != null) {
			if (type(check.targets) != 'array' || !(length(check.targets) >= 1 && length(check.targets) <= 4)) fail('线路检测目标需要 1 到 4 个');
			for (let target in check.targets) {
				const body = text(target, '检测目标', 64);
				if (!length(body) || !match(body, /^[A-Za-z0-9][A-Za-z0-9.:-]{0,63}$/)) fail('检测目标格式不正确：' + body);
				push(targets, body);
			}
		} else for (let target in DEFAULT_TARGETS) push(targets, target);
		model.load.check = {
			enabled: check.enabled == null ? true : check.enabled === true,
			interval: intInRange(check.interval, '线路检测间隔', 5, 300, 10),
			fail: intInRange(check.fail, '线路连续失败次数', 1, 10, 3),
			up: intInRange(check.up, '线路恢复成功次数', 1, 10, 2),
			targets: uniq(targets)
		};
	}

	let ruleCount = 0;
	const seenRules = {};
	function ruleKey(value, label) {
		const id = identifier(value, label);
		if (seenRules[id]) fail('规则标识重复：' + id);
		seenRules[id] = true;
		ruleCount++;
		if (ruleCount > MAX_RULES) fail('分流规则最多 ' + MAX_RULES + ' 条');
		return id;
	}

	if (input.proto != null) {
		if (type(input.proto) != 'array') fail('协议分流规则格式不正确');
		for (let rule in input.proto) {
			const id = ruleKey(rule.id, '协议规则');
			const name = text(rule.name, '协议规则名称', 64);
			if (!length(name)) fail('协议规则名称不能为空');
			push(model.proto, {
				id, name, enabled: rule.enabled === true,
				protocol: protocol(rule.protocol, '协议规则「' + name + '」'),
				ports: join(',', map(parsePorts(rule.ports), part => part.text)),
				src: parseSources(rule.src),
				dst: parseSources(rule.dst),
				line: lineReference(rule.line, lineIds, '协议规则「' + name + '」的线路')
			});
		}
	}
	if (input.port != null) {
		if (type(input.port) != 'array') fail('端口分流规则格式不正确');
		for (let rule in input.port) {
			const id = ruleKey(rule.id, '端口规则');
			const name = text(rule.name, '端口规则名称', 64);
			if (!length(name)) fail('端口规则名称不能为空');
			const ports = parsePorts(rule.ports);
			if (rule.enabled === true && !length(ports)) fail('端口规则「' + name + '」启用时必须填写目的端口');
			push(model.port, {
				id, name, enabled: rule.enabled === true,
				protocol: protocol(rule.protocol, '端口规则「' + name + '」'),
				ports: join(',', map(ports, part => part.text)),
				src: parseSources(rule.src),
				line: lineReference(rule.line, lineIds, '端口规则「' + name + '」的线路')
			});
		}
	}
	if (input.domain != null) {
		if (type(input.domain) != 'array') fail('域名分流规则格式不正确');
		for (let rule in input.domain) {
			const id = ruleKey(rule.id, '域名规则');
			const name = text(rule.name, '域名规则名称', 64);
			if (!length(name)) fail('域名规则名称不能为空');
			if (type(rule.domains) != 'array' || !length(rule.domains)) fail('域名规则「' + name + '」至少需要一个域名');
			if (length(rule.domains) > 256) fail('域名规则「' + name + '」最多 256 个域名');
			push(model.domain, {
				id, name, enabled: rule.enabled === true,
				domains: uniq(map(rule.domains, domainName)),
				line: lineReference(rule.line, lineIds, '域名规则「' + name + '」的线路'),
				ttl: intInRange(rule.ttl, '域名规则「' + name + '」的解析间隔', 60, 86400, 600)
			});
		}
	}

	if (input.updown != null) {
		if (type(input.updown) != 'object') fail('上下行分离配置格式不正确');
		const updown = input.updown;
		model.updown = {
			enabled: updown.enabled === true,
			upload: lineReference(updown.upload, lineIds, '上下行分离的上行线路'),
			download: lineReference(updown.download, lineIds, '上下行分离的下行线路'),
			uploadKbps: rate(updown.uploadKbps, '上下行分离的上行限速'),
			downloadKbps: rate(updown.downloadKbps, '上下行分离的下行限速')
		};
	}

	if (input.smart != null) {
		if (type(input.smart) != 'object') fail('智能流控配置格式不正确');
		const smart = input.smart;
		const exempt = [];
		if (smart.exempt != null) {
			if (type(smart.exempt) != 'array' || length(smart.exempt) > 32) fail('智能流控例外地址最多 32 项');
			for (let value in smart.exempt) {
				const item = cidr4(text(value, '例外地址', 64));
				if (!item) fail('例外地址必须是 IPv4 地址或 CIDR：' + value);
				push(exempt, item.value);
			}
		}
		model.smart = {
			enabled: smart.enabled === true,
			perIpUpKbps: rate(smart.perIpUpKbps, '每终端上行限速'),
			perIpDownKbps: rate(smart.perIpDownKbps, '每终端下行限速'),
			totalUpKbps: rate(smart.totalUpKbps, '总上行限速'),
			totalDownKbps: rate(smart.totalDownKbps, '总下行限速'),
			exempt: uniq(exempt),
			maxDevices: intInRange(smart.maxDevices, '智能流控最多终端数', 1, 1024, 256)
		};
	}

	if (input.limit != null) {
		if (type(input.limit) != 'array') fail('终端限速规则格式不正确');
		if (length(input.limit) > MAX_LIMITS) fail('终端限速规则最多 ' + MAX_LIMITS + ' 条');
		const seenLimits = {};
		for (let rule in input.limit) {
			const id = identifier(rule.id, '终端限速规则');
			if (seenLimits[id]) fail('终端限速规则标识重复：' + id);
			seenLimits[id] = true;
			const name = text(rule.name, '终端限速名称', 64);
			if (!length(name)) fail('终端限速名称不能为空');
			const address = text(rule.ip, '终端地址', 32);
			if (ip4(address) == null) fail('终端限速「' + name + '」的地址必须是 IPv4 地址');
			const upKbps = rate(rule.upKbps, '终端限速「' + name + '」的上行限速');
			const downKbps = rate(rule.downKbps, '终端限速「' + name + '」的下行限速');
			if (rule.enabled === true && !upKbps && !downKbps) fail('终端限速「' + name + '」启用时上行和下行至少要填写一项');
			const item = { id, name, enabled: rule.enabled === true, ip: address, upKbps, downKbps, comment: text(rule.comment, '备注', 120) };
			if (rule.mac != null && length(lined('' + rule.mac))) {
				const mac = lc(text(rule.mac, 'MAC 地址', 17));
				if (!match(mac, MAC_ADDRESS)) fail('MAC 地址格式不正确：' + mac);
				item.mac = mac;
			}
			push(model.limit, item);
		}
	}
	return model;
}

// 一致性提示：只返回警告文本，不阻断保存（避免用户被“只是提醒”卡住）。
function warnings(model, resolved) {
	const output = [];
	if (!model.enabled) { push(output, '流控分流尚未启用，保存后不会产生任何规则'); return output; }
	if (!length(resolved)) push(output, '没有可用线路（接口未上线或未获取网关），所有分流规则都不会生效');
	if (model.enabled && length(model.lines) && !length(filter(model.lines, line => line.enabled))) push(output, '所有线路都已停用，流控分流不会生效');
	if (model.load.enabled && length(resolved) < 2) push(output, '多线负载需要至少 2 条可用线路，当前只会走单线路');
	if (model.load.enabled && model.load.mode == 'weighted' && length(filter(resolved, line => line.weight > 0)) < 2) push(output, '按权重分配需要至少 2 条权重不为 0 的可用线路');
	const enabledRules = length(filter(model.proto, rule => rule.enabled));
	const enabledPorts = length(filter(model.port, rule => rule.enabled));
	const enabledDomains = length(filter(model.domain, rule => rule.enabled));
	if (enabledRules + enabledPorts + enabledDomains && !length(resolved)) push(output, '已启用分流规则但没有可用线路，规则不会生效');
	if (model.smart.enabled && !(model.smart.perIpUpKbps + model.smart.perIpDownKbps + model.smart.totalUpKbps + model.smart.totalDownKbps)) push(output, '智能流控已启用但没有填写任何限速值，不会产生限速规则');
	if (model.smart.enabled && model.smart.maxDevices > 256) push(output, '智能流控终端数超过 256，生成的规则较多，可能影响转发性能');
	for (let collection in [model.proto, model.port, model.domain]) for (let rule in collection) {
		if (rule.enabled !== true || rule.line == 'auto') continue;
		const line = filter(model.lines, item => item.id == rule.line)[0];
		if (line && line.enabled !== true) push(output, '规则「' + rule.name + '」引用的线路「' + line.name + '」已停用，将改为自动分配');
	}
	return uniq(output);
}

// —— 拓扑探测 ——
// zone 归属用 firewall 的 zone 定义，判定口径与 console-security / console-portmap 一致。
function zoneMembers() {
	const zones = { lan: [], wan: [] }, handle = cursor();
	handle.foreach('firewall', 'zone', zone => {
		if (zone.name != 'lan' && zone.name != 'wan') return;
		zones[zone.name] = type(zone.network) == 'array' ? zone.network : split(zone.network || '', /\s+/);
	});
	return zones;
}
function topology() {
	const bus = connect();
	const dump = bus ? bus.call('network.interface', 'dump', {}) : null;
	if (bus) bus.disconnect();
	const interfaces = [], lanDevices = [], wanDevices = [], lanSubnets = [];
	for (let iface in (dump && dump.interface) || []) {
		const l3 = iface.l3_device || iface.device || '';
		const item = {
			name: iface.interface, device: l3,
			up: iface.up === true, pending: iface.pending === true, proto: iface.proto || '',
			addresses: map(iface['ipv4-address'] || [], address => address.address),
			subnets: map(iface['ipv4-address'] || [], address => address.address + '/' + address.mask),
			gateway: '', dns: iface['dns-server'] || []
		};
		for (let route in iface.route || []) {
			if ((route.target == '0.0.0.0' || route.target == '0') && +route.mask === 0 && route.nexthop && route.nexthop != '0.0.0.0') {
				if (!length(item.gateway)) item.gateway = route.nexthop;
			}
		}
		push(interfaces, item);
	}
	const zones = zoneMembers();
	for (let name in zones.lan) {
		const iface = filter(interfaces, item => item.name == name)[0];
		if (!iface || !length(iface.device)) continue;
		if (index(lanDevices, iface.device) < 0) push(lanDevices, iface.device);
		for (let subnet in iface.subnets) {
			const parsed = cidr4(subnet);
			if (parsed && index(lanSubnets, parsed.value) < 0) push(lanSubnets, parsed.value);
		}
	}
	for (let name in zones.wan) {
		const iface = filter(interfaces, item => item.name == name)[0];
		if (!iface || !length(iface.device)) continue;
		if (index(wanDevices, iface.device) < 0) push(wanDevices, iface.device);
	}
	// 线路候选 = 有 IPv4 默认网关的接口（DHCP / PPPoE / 静态都覆盖）。
	const candidates = filter(interfaces, item => length(item.gateway) && item.proto != 'dhcpv6');
	return { interfaces, lan: lanDevices, wan: wanDevices, lanSubnets, candidates };
}

// 把配置里的启用线路解析成运行态，并按配置顺序分配 mark / 路由表 / rule prio。
// 编号一旦分配就只随配置顺序变化，不做压缩：避免热插拔时已建立连接跳表。
function resolveLines(model, top) {
	const resolved = [];
	for (let line in model.lines) {
		if (line.enabled !== true) continue;
		const iface = filter(top.interfaces, item => item.name == line.interface)[0];
		const index = length(resolved);
		const item = {
			id: line.id, name: line.name, interface: line.interface, weight: line.weight,
			enabled: true, upKbps: line.upKbps, downKbps: line.downKbps,
			up: false, degraded: false, addresses: [], gateway: '', device: '', ifname: '',
			mark: MARK_BASE | (index + 1), table: TABLE_BASE + index, prio: PRIO_BASE + index
		};
		if (iface) {
			item.up = iface.up;
			item.addresses = iface.addresses;
			item.gateway = iface.gateway;
			item.device = iface.device;
			item.ifname = iface.device;
			item.proto = iface.proto;
		}
		item.degraded = !(iface && item.up && length(item.gateway) && length(item.device));
		push(resolved, item);
	}
	return resolved;
}
function usableLines(resolved) { return filter(resolved, line => !line.degraded); }

// —— 终端枚举 ——
// 数据来源**全部是本地文件**，绝不调 ubus。
//
// 为什么不能用 `luci-rpc.getHostHints`：这个对象由 rpcd 自己的 luci.so 插件提供，
// 在 rpcd 的 ucode 方法里同步调它 = rpcd 等自己，会一直卡到 ubus 超时
// （/etc/config/rpcd 的 timeout，默认 30 秒），`state` 因此超时、所有页面打不开。
// 从 shell 单独调它是 0s，所以只测单个函数发现不了，必须整条 rpcd 路径验证。
//
// 替代来源（都能秒回）：
//   1) /tmp/dhcp.leases      —— dnsmasq 租约：过期时间 MAC IP 主机名
//   2) /etc/config/dhcp host —— 静态保留：name / mac / ip 绑定
//   3) /proc/net/arp         —— 当前在线邻居的 IP↔MAC（最直接的在线证据）
//   4) /tmp/console-security-state.json —— 采集器快照里的速率（可选）
//
// 只保留落在 LAN 网段内的地址（ARP 里必然混入 WAN 邻居，若一并展示会误导用户，
// 也会让智能流控给外网地址生成无意义的限速规则）。
// 取不到的字段一律省略，绝不用 0 填充（页面按“无数据”展示，不误导为“0 流量”）。
function devices(top) {
	const lanSubnets = (top && top.lanSubnets) || [];
	function inLan(address) {
		if (ip4(address) == null) return false;
		if (!length(lanSubnets)) return true;
		for (let subnet in lanSubnets) if (cidr4(subnet) && inCidr4(address, subnet)) return true;
		return false;
	}
	const names = {}, leaseIp = {}, arpMac = {};
	// 1) dnsmasq 租约：过期时间 MAC IP 主机名
	for (let line in split(readfile('/tmp/dhcp.leases') || '', '\n')) {
		const fields = split(trim(line), /\s+/);
		if (length(fields) < 4) continue;
		const mac = lc(fields[1]);
		if (!match(mac, MAC_ADDRESS) || ip4(fields[2]) == null) continue;
		leaseIp[mac] = fields[2];
		if (fields[3] != '*' && !names[mac]) names[mac] = fields[3];
	}
	// 2) /etc/config/dhcp 的静态 host 段：uci 读的是本地文件，不经过 ubus，安全。
	const handle = cursor();
	handle.foreach('dhcp', 'host', host => {
		const mac = lc(host.mac || '');
		if (!match(mac, MAC_ADDRESS)) return;
		if (host.name && !names[mac]) names[mac] = host.name;
		if (host.ip && ip4(host.ip) != null && !leaseIp[mac]) leaseIp[mac] = host.ip;
	});
	// 3) /proc/net/arp：IP HW地址 标志 ... （表头行要跳过）
	for (let line in split(readfile('/proc/net/arp') || '', '\n')) {
		const fields = split(trim(line), /\s+/);
		if (length(fields) < 4) continue;
		const mac = lc(fields[3]);
		if (!match(mac, MAC_ADDRESS) || ip4(fields[0]) == null) continue;
		// 标志位 0x2 = ATF_COM（已完成 ARP 解析），只有这种才是真实在线邻居；
		// 0x0 表示解析中/失败，不能当作在线证据。
		const flags = match(fields[2], /^0x([0-9a-fA-F]{1,8})$/);
		if (!flags || !(int(flags[1], 16) & 0x2)) continue;
		arpMac[fields[0]] = mac;
	}
	const snapshot = readJson('/tmp/console-security-state.json', {});
	const rates = {};
	for (let device in snapshot.devices || []) {
		const mac = lc(device.mac || '');
		if (!match(mac, MAC_ADDRESS)) continue;
		const entry = {};
		if (type(device.upload) == 'int' || type(device.upload) == 'double') entry.up = int(device.upload);
		if (type(device.download) == 'int' || type(device.download) == 'double') entry.down = int(device.download);
		if (type(device.online) == 'bool') entry.online = device.online;
		rates[mac] = entry;
	}
	const byIp = {}, order = [];
	function remember(address, mac, online) {
		if (!inLan(address)) return;
		if (!byIp[address]) { byIp[address] = { ip: address }; push(order, address); }
		if (mac && !byIp[address].mac) byIp[address].mac = mac;
		// 只要在 ARP 里出现过就算在线；离线状态不写，交给前端按“无数据”处理。
		if (online === true) byIp[address].online = true;
	}
	for (let mac, address in leaseIp) remember(address, mac, false);
	for (let device in snapshot.devices || []) for (let address in device.currentIPs || device.ips || []) remember(address, lc(device.mac || ''), false);
	for (let address, mac in arpMac) remember(address, mac, true);
	const list = [];
	for (let address in order) {
		const item = byIp[address];
		const mac = item.mac;
		const result = { ip: item.ip };
		if (mac) result.mac = mac;
		const hostname = mac ? (names[mac] || '') : '';
		if (length(hostname)) result.hostname = hostname;
		const rateInfo = mac ? rates[mac] : null;
		if (rateInfo) {
			if (rateInfo.up != null) result.up = rateInfo.up;
			if (rateInfo.down != null) result.down = rateInfo.down;
		}
		// 在线判定优先级：采集器快照 > ARP 表。两者都没有就不写该字段。
		if (rateInfo && rateInfo.online != null) result.online = rateInfo.online;
		else if (item.online === true) result.online = true;
		push(list, result);
	}
	return sort(list, (a, b) => ip4(a.ip) - ip4(b.ip));
}

// —— 域名解析结果缓存 ——
// 结构：{ updated, groups: { <ruleId>: { resolved, unresolved: [...], time, addresses: {...}, domains: { name: { addresses, error, time } } } } }
function domainStore() { return readJson(DOMAINS, { updated: 0, groups: {} }); }
function writeDomainStore(store) { ensure(); writeText(DOMAINS, sprintf('%J\n', store)); }

// —— 能力探测 ——
// 只声明客观能力，不假装支持整形。shaping=false 时前端必须常驻提示丢包限速。
function caps() {
	const hasTc = !!(stat('/sbin/tc') || stat('/usr/sbin/tc'));
	const modules = trim(readfile('/proc/modules') || '');
	const hasShaping = hasTc || match(modules, /(^|\n)(sch_htb|sch_cake|sch_tbf|ifb)(\s|$)/) != null;
	return {
		nft: !!(stat('/usr/sbin/nft') || stat('/usr/bin/nft')),
		ip: !!(stat('/sbin/ip') || stat('/usr/sbin/ip') || stat('/bin/ip') || stat('/usr/bin/ip')),
		tc: hasTc,
		iptables: !!(stat('/usr/sbin/iptables') || stat('/usr/bin/iptables')),
		nftset: false,
		shaping: hasShaping,
		dnsmasq: !!(stat('/usr/sbin/dnsmasq') || stat('/usr/bin/dnsmasq')),
		shapingNote: hasShaping ? '' : '内核未编译 tc 调度模块，限速为 nftables 丢包限速，不整形队列',
		limitNote: '超过速率的报文会被直接丢弃（nftables limit），不做队列整形与重排'
	};
}

export {
	DEFAULT_TARGETS,
	defaultConfig, config, writeConfig, parsePorts, parseSources,
	normalize, warnings, topology, resolveLines, usableLines, devices,
	domainStore, writeDomainStore, caps
};
