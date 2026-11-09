// SPDX-License-Identifier: Apache-2.0
// 流控分流生效引擎：nft 表文本编译、ip rule/route 计划、apply/confirm/rollback/reset。
//
// 设计要点（见 .stage/flow-spec.md §5）：
//   * 标签基址 0x46460000，掩码 0xffff00ff；第 i 条线路 mark = base|(i+1)，路由表 300+i，
//     ip rule prio 10400+i。与 mihomo 的 0x434d / table 201 / prio 10390 完全错开。
//   * 自建独立表 inet console_flow，只挂 prerouting(-150) / forward(-5) / postrouting(srcnat)，
//     不改 fw4，不动 console_guard / console_meter / console_threat。
//   * 限速只能用 nftables limit 丢包（目标机无 tc、无 htb/cake/ifb 内核模块）。
//
// 注意 ucode 的两个坑：
//   1) 不做函数声明提升 —— 被调用者必须先于调用者定义，本文件严格按依赖顺序书写；
//   2) 数组是内建类型，没有 .push() 方法 —— 一律用 push(array, value)。
import { readfile, unlink, stat } from 'fs';
import {
	CONFIG, APPLIED, NFT, BACKUP, MARK_MASK_TEXT, MARK_BASE,
	fail, readJson, writeText, writeJson, ensure, ensureBackup,
	nftCheck, nftLoad, deleteTable, tableJson, output,
	ipAddRule, ipAddRoute, cleanupIp,
	withLock, pendingState, writePending, clearPending, spawnRollback,
	ip4, cidr4
} from 'console.flow-util';
import {
	config, writeConfig, normalize, warnings, topology, resolveLines, usableLines,
	devices, domainStore, writeDomainStore, caps, defaultConfig
} from 'console.flow-model';

// —— 文本与速率小工具 ——
// nft 集合元素表必须包在 { } 里，接口名还要加引号。
function ifnameElements(values) { return '{ ' + join(', ', map(values, value => '"' + value + '"')) + ' }'; }
// Kbps（比特率）→ nft 的 bytes/second（字节率），最小 1 字节/秒。
function rateBytes(kbps) { return max(1, int(+kbps * 1000 / 8)); }
function markText(mark) { return sprintf('0x%08x', mark); }
function appendAll(target, values) { for (let value in values) push(target, value); return target; }

// 用规则 ID 做稳定散列挑选自动线路：同一条规则每次重载都落到同一条线路，
// 避免每次 reload 都换出口导致连接抖动。
function stableLineId(available, ruleId) {
	if (!length(available)) return null;
	let hash = 0;
	for (let index = 0; index < length(ruleId); index++) hash = (hash * 31 + ord(substr(ruleId, index, 1))) % 100003;
	return available[hash % length(available)].id;
}
// 按权重生成 vmap 区间：区间长度 = 权重，因此 hash 值落在某线路区间的概率正比于权重
// （权重 2:1:3 → 区间 0-1 / 2 / 3-5，总权重 6）。
// 注意不能用「按权重展开数组 + 去重」的写法：去重会把重复项折回每线一次，权重完全失效。
function weightVmap(lines) {
	const mapping = [];
	let start = 0;
	for (let line in lines) {
		const weight = max(1, line.weight);
		const stop = start + weight - 1;
		push(mapping, (start == stop ? '' + start : start + '-' + stop) + ' : jump line_' + line.id);
		start += weight;
	}
	return { mapping, total: start };
}

// 受控终端：LAN 内、有 IPv4、排除路由器自身地址与智能流控例外网段。
function limitTargets(model, top) {
	const reserved = {};
	for (let iface in top.interfaces) for (let address in iface.addresses) reserved[address] = true;
	const exempt = [];
	for (let range in model.smart.exempt || []) { const parsed = cidr4(range); if (parsed) push(exempt, parsed); }
	const result = [];
	for (let device in devices(top)) {
		if (device.ip in reserved) continue;
		const key = ip4(device.ip);
		if (key == null) continue;
		let skip = false;
		for (let range in exempt) if (key >= range.base && key < range.base + range.size) skip = true;
		if (skip) continue;
		push(result, device);
	}
	return result;
}

// —— nft 表编译 ——
// 返回 { text, warnings, ruleCount, limitRules }；text 直接喂 `nft -c -f` 与 `nft -f`。
function compileNft(model, top, resolved) {
	const available = usableLines(resolved);
	const byId = {};
	for (let line in available) byId[line.id] = line;
	const emitted = [];
	const warn = [];

	push(emitted, '# 由 console-flow 生成，请勿手工编辑；修改请使用 LuCI「流控分流」页面。');
	push(emitted, 'destroy table inet console_flow');
	push(emitted, 'table inet console_flow {');

	// 接口与网段集合：分流与限速都只作用于 LAN 侧。
	push(emitted, '\tset lan {');
	push(emitted, '\t\ttype ifname;');
	if (length(top.lan)) push(emitted, '\t\telements = ' + ifnameElements(top.lan) + ';');
	push(emitted, '\t}');
	push(emitted, '\tset wan {');
	push(emitted, '\t\ttype ifname;');
	if (length(top.wan)) push(emitted, '\t\telements = ' + ifnameElements(top.wan) + ';');
	push(emitted, '\t}');
	const lanV4 = [];
	for (let subnet in top.lanSubnets) { const parsed = cidr4(subnet); if (parsed && index(lanV4, parsed.value) < 0) push(lanV4, parsed.value); }
	if (length(lanV4)) {
		push(emitted, '\tset internal4 {');
		push(emitted, '\t\ttype ipv4_addr;');
		push(emitted, '\t\tflags interval;');
		push(emitted, '\t\telements = { ' + join(', ', lanV4) + ' };');
		push(emitted, '\t}');
	}

	// 域名集合：每个已解析的启用规则一组 interval 集合。
	// 解析失败的域名保留旧地址（见 refreshDomains），这里只提示不阻断。
	const store = domainStore();
	const groups = [];
	for (let rule in model.domain) {
		if (rule.enabled !== true) continue;
		const cached = store.groups ? store.groups[rule.id] : null;
		const addresses = [];
		if (cached && type(cached.domains) == 'object') {
			for (let name, entry in cached.domains) for (let address in entry.addresses || []) if (ip4(address) != null) push(addresses, address);
		}
		const unique = uniq(addresses);
		if (!length(unique)) {
			const unresolved = cached && length(cached.unresolved || []) ? '（' + join('、', slice(cached.unresolved, 0, 3)) + ' 解析失败）' : '';
			push(warn, '域名规则「' + rule.name + '」尚未解析到地址' + unresolved + '，请点击「立即解析」');
			continue;
		}
		const setName = 'domain_' + rule.id;
		push(emitted, '\tset ' + setName + ' {');
		push(emitted, '\t\ttype ipv4_addr;');
		push(emitted, '\t\tflags interval;');
		push(emitted, '\t\telements = { ' + join(', ', slice(unique, 0, 4096)) + ' };');
		push(emitted, '\t}');
		push(groups, { rule, setName, count: length(unique) });
	}

	// 命名 limit 对象：比内联 limit 易读，`nft list table` 能直接看到速率。
	function defineLimit(name, kbps) {
		push(emitted, '\tlimit ' + name + ' { rate ' + rateBytes(kbps) + ' bytes/second burst ' + rateBytes(kbps) + ' bytes; }');
	}
	for (let rule in model.limit) {
		if (rule.enabled !== true) continue;
		if (rule.upKbps > 0) defineLimit('up_' + rule.id, rule.upKbps);
		if (rule.downKbps > 0) defineLimit('down_' + rule.id, rule.downKbps);
	}
	if (model.smart.enabled === true) {
		if (model.smart.perIpUpKbps > 0) defineLimit('smart_up', model.smart.perIpUpKbps);
		if (model.smart.perIpDownKbps > 0) defineLimit('smart_down', model.smart.perIpDownKbps);
		if (model.smart.totalUpKbps > 0) defineLimit('smart_total_up', model.smart.totalUpKbps);
		if (model.smart.totalDownKbps > 0) defineLimit('smart_total_down', model.smart.totalDownKbps);
	}
	if (model.updown.enabled === true) {
		if (model.updown.uploadKbps > 0) defineLimit('updown_up', model.updown.uploadKbps);
		if (model.updown.downloadKbps > 0) defineLimit('updown_down', model.updown.downloadKbps);
	}

	// —— prerouting：分流打标 ——
	push(emitted, '\tchain prerouting {');
	push(emitted, '\t\ttype filter hook prerouting priority -150; policy accept;');
	// 只看 LAN 侧发往外网的新连接：本机流量、DNAT 回程、内网互访一律放过。
	if (length(top.lan)) push(emitted, '\t\tiifname != @lan return');
	else push(emitted, '\t\tiifname "lo" return');
	push(emitted, '\t\tct status dnat return');
	push(emitted, '\t\tfib daddr type local return');
	push(emitted, '\t\tmeta nfproto != ipv4 return');
	if (length(lanV4)) push(emitted, '\t\tip daddr @internal4 return');
	// 1) 按 conntrack 记录的 mark 还原线路选择。
	// 这里**不能**限定 `ct state established,related`：SYN 重传、UDP 未收到回包时
	// 连接一直是 `new`，只按 state 还原会让这些包重新走一次随机/规则匹配，
	// 同一连接的不同包被打上不同 mark（实测 6 次 SYN 重传 = 6 次随机，连接会跨线路抖动）。
	// 判据改为「ct mark 高 24 位属于本功能的基址」，与 state 无关；
	// 用高 24 位而不是 `!= 0` 是为了不误吸 mihomo 的 0x434d 等其他程序的标记。
	if (length(available)) push(emitted, '\t\tct mark & 0xffff0000 == ' + markText(MARK_BASE) + ' meta mark set ct mark');

	let ruleCount = 0;
	let currentLabel = '';
	// 2) 显式分流规则：只处理尚未打标（mark 低 8 位为 0）的流量，先命中者优先。
	function emitRule(matches, lineId, comment, label) {
		const line = byId[lineId];
		if (!line) { push(warn, '规则「' + label + '」没有可用线路，已跳过'); return; }
		currentLabel = label;
		const body = join(' ', filter(matches, part => length(part)));
		push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 ' + body + ' jump line_' + line.id + ' comment ' + sprintf('%J', comment));
		ruleCount++;
	}
	function protocolMatches(rule, withDestination) {
		const parts = [];
		if (rule.protocol == 'tcp+udp') push(parts, 'meta l4proto { tcp, udp }');
		else push(parts, 'meta l4proto ' + rule.protocol);
		const ports = filter(length(rule.ports || '') ? split(rule.ports, ',') : [], piece => length(piece));
		if (length(ports)) {
			// tcp+udp 必须用 th dport（通用传输层字段），单协议可用 tcp/udp dport。
			if (rule.protocol == 'tcp+udp') push(parts, 'th dport { ' + join(', ', ports) + ' }');
			else push(parts, rule.protocol + ' dport { ' + join(', ', ports) + ' }');
		}
		if (length(rule.src || '')) push(parts, 'ip saddr { ' + join(', ', split(rule.src, ',')) + ' }');
		if (withDestination && length(rule.dst || '')) push(parts, 'ip daddr { ' + join(', ', split(rule.dst, ',')) + ' }');
		return parts;
	}
	for (let rule in model.proto) {
		if (rule.enabled !== true) continue;
		const lineId = rule.line == 'auto' ? stableLineId(available, rule.id) : rule.line;
		emitRule(protocolMatches(rule, true), lineId, 'flow:proto:' + rule.id, rule.name);
	}
	for (let rule in model.port) {
		if (rule.enabled !== true) continue;
		const lineId = rule.line == 'auto' ? stableLineId(available, rule.id) : rule.line;
		emitRule(protocolMatches(rule, false), lineId, 'flow:port:' + rule.id, rule.name);
	}
	for (let group in groups) {
		const lineId = group.rule.line == 'auto' ? stableLineId(available, group.rule.id) : group.rule.line;
		emitRule(['ip daddr @' + group.setName], lineId, 'flow:domain:' + group.rule.id, group.rule.name);
	}
	// 3) 上下行分离：上行（LAN→WAN 新建连接）固定线路。
	if (model.updown.enabled === true && model.updown.upload != 'auto') {
		if (byId[model.updown.upload]) {
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 jump line_' + model.updown.upload + ' comment "flow:updown:upload"');
			ruleCount++;
		} else push(warn, '上下行分离的上行线路不可用，已跳过');
	}
	// 4) 多线负载：未命中任何规则的流量分配线路。
	if (model.load.enabled === true && length(available)) {
		if (model.load.mode == 'failover') {
			// 故障切换：只用第一条可用线路；它掉线后由后台刷新顺延到下一条。
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 jump line_' + available[0].id + ' comment "flow:load:failover"');
			ruleCount++;
			if (length(available) > 1) push(warn, '故障切换模式只用第一条可用线路「' + available[0].name + '」，掉线后自动顺延');
		} else if (length(available) > 1) {
			// 加权分配：用 jhash 把「流」散列到 0..总权重-1，vmap 区间长度即权重。
			// 为什么用 jhash 而不是 numgen random：
			//   numgen random 是**逐包**求值的（实测同一连接 8 次 SYN 重传 = 8 次随机），
			//   而 UDP 无回包时 conntrack 会持续超时重建，重建后又重新随机，同一「流」
			//   就会在几条线路之间跳来跳去，这与用户理解的「分流」语义直接冲突。
			//   jhash 对同一五元组恒定，天然粘滞：同一连接、同一流永远落同一线路，
			//   且不同流仍能按权重均匀铺开。
			// vmap 只支持 jump/goto，不能直接赋值 mark，因此每条线路一个出口链。
			const plan = weightVmap(available);
			// 有传输层头（TCP/UDP）时把端口也纳入 hash，避免只有源/目的 IP 相同的
			// 多条流（例如 浏览器开多个连接）挤到同一条线路上。
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 meta l4proto { tcp, udp } jhash ip saddr . ip daddr . meta l4proto . th dport mod ' + plan.total + ' vmap { ' + join(', ', plan.mapping) + ' } comment "flow:load:balance"');
			// 兜底分支：ICMP 等没有传输层头的包不能用 th dport，用三元组 hash。
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 jhash ip saddr . ip daddr . meta l4proto mod ' + plan.total + ' vmap { ' + join(', ', plan.mapping) + ' } comment "flow:load:fallback"');
			ruleCount += 2;
			push(warn, '多线负载按权重 + 五元组哈希分配：同一连接/同一流恒定走同一条线路（UDP 也稳定），不同流按权重铺开');
		} else {
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 jump line_' + available[0].id + ' comment "flow:load:single"');
			ruleCount++;
			if (model.load.mode == 'weighted' && length(available) < 2) push(warn, '多线负载只有一条可用线路，无法按权重分配');
		}
	}
	// 5) 写回 conntrack：新建连接把 mark 存进 ct mark，回程包据此还原。
	if (length(available)) {
		push(emitted, '\t\tct state new ct mark set meta mark');
		push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == 0 return');
	}
	push(emitted, '\t}');

	// 每条线路一个出口链：设 mark 后返回。
	for (let line in available) {
		push(emitted, '\tchain line_' + line.id + ' {');
		push(emitted, '\t\tmeta mark set ' + markText(line.mark));
		push(emitted, '\t\treturn');
		push(emitted, '\t}');
	}

	// —— forward：限速（丢包式，不做队列整形） ——
	push(emitted, '\tchain forward {');
	push(emitted, '\t\ttype filter hook forward priority -5; policy accept;');
	const upGuard = length(top.lan) ? 'iifname @lan ' : '';
	const downGuard = length(top.lan) ? 'oifname @lan ' : '';
	let limitRules = 0;
	for (let rule in model.limit) {
		if (rule.enabled !== true) continue;
		// 绑定 MAC 时同时校验 IP 与 MAC：只按 IP 限速会被同网段的其它设备伪装源地址绕过，
		// 只按 MAC 又会漏掉该 MAC 换 IP 前的情况，两条一起匹配才是用户期望的“这台设备”。
		// 上行看源 MAC，下行看目的 MAC（回程包的目的地址就是该终端）。
		const upMac = length(rule.mac || '') ? 'ether saddr ' + rule.mac + ' ' : '';
		const downMac = length(rule.mac || '') ? 'ether daddr ' + rule.mac + ' ' : '';
		if (rule.upKbps > 0) {
			push(emitted, '\t\t' + upGuard + 'ip saddr ' + rule.ip + ' ' + upMac + 'limit name up_' + rule.id + ' counter drop comment ' + sprintf('%J', 'flow:limit:' + rule.id + ':up'));
			limitRules++;
		}
		if (rule.downKbps > 0) {
			push(emitted, '\t\t' + downGuard + 'ip daddr ' + rule.ip + ' ' + downMac + 'limit name down_' + rule.id + ' counter drop comment ' + sprintf('%J', 'flow:limit:' + rule.id + ':down'));
			limitRules++;
		}
	}
	if (model.smart.enabled === true) {
		const targets = limitTargets(model, top);
		const capped = slice(targets, 0, model.smart.maxDevices);
		if (length(targets) > length(capped)) push(warn, '智能流控终端数超过上限 ' + model.smart.maxDevices + '，仅前 ' + length(capped) + ' 台生效');
		if ((model.smart.perIpUpKbps > 0 || model.smart.perIpDownKbps > 0) && !length(capped)) push(warn, '智能流控没有可用的内网终端（请检查 DHCP 租约或稍后重试）');
		for (let device in capped) {
			if (model.smart.perIpUpKbps > 0) {
				push(emitted, '\t\t' + upGuard + 'ip saddr ' + device.ip + ' limit name smart_up counter drop comment ' + sprintf('%J', 'flow:smart:' + device.ip + ':up'));
				limitRules++;
			}
			if (model.smart.perIpDownKbps > 0) {
				push(emitted, '\t\t' + downGuard + 'ip daddr ' + device.ip + ' limit name smart_down counter drop comment ' + sprintf('%J', 'flow:smart:' + device.ip + ':down'));
				limitRules++;
			}
		}
		// 总速率规则放在每终端规则之后：先限制单终端，再对整体丢包。
		if (model.smart.totalUpKbps > 0) { push(emitted, '\t\t' + upGuard + 'limit name smart_total_up counter drop comment "flow:smart:total:up"'); limitRules++; }
		if (model.smart.totalDownKbps > 0) { push(emitted, '\t\t' + downGuard + 'limit name smart_total_down counter drop comment "flow:smart:total:down"'); limitRules++; }
	}
	if (model.updown.enabled === true) {
		if (model.updown.uploadKbps > 0) { push(emitted, '\t\t' + upGuard + 'limit name updown_up counter drop comment "flow:updown:up"'); limitRules++; }
		if (model.updown.downloadKbps > 0) { push(emitted, '\t\t' + downGuard + 'limit name updown_down counter drop comment "flow:updown:down"'); limitRules++; }
	}
	if (!limitRules) push(emitted, '\t\tcounter comment "flow:unused"');
	push(emitted, '\t}');

	// —— postrouting：按线路 SNAT ——
	// fw4 已在 srcnat 做过默认 masquerade；本表只补“被策略路由送到指定线路、
	// 由该线路物理口发出”的情况，并跳过 DNAT 回程避免二次 NAT。
	push(emitted, '\tchain postrouting {');
	push(emitted, '\t\ttype nat hook postrouting priority srcnat; policy accept;');
	if (length(available)) {
		push(emitted, '\t\tct status dnat return');
		for (let line in available) {
			if (!length(line.device)) continue;
			push(emitted, '\t\tmeta mark & ' + MARK_MASK_TEXT + ' == ' + markText(line.mark) + ' oifname ' + sprintf('%J', line.device) + ' masquerade comment ' + sprintf('%J', 'flow:snat:' + line.id));
		}
	}
	push(emitted, '\t}');
	push(emitted, '}');
	return { text: join('\n', emitted) + '\n', warnings: uniq(warn), ruleCount, limitRules };
}

// —— ip rule / 路由表计划 ——
function ipPlanLines(available) {
	const result = [];
	for (let line in available) {
		if (!length(line.gateway) || !length(line.device)) continue;
		push(result, 'ip route replace table ' + line.table + ' default via ' + line.gateway + ' dev ' + line.device);
		push(result, 'ip rule add fwmark ' + markText(line.mark) + '/' + MARK_MASK_TEXT + ' table ' + line.table + ' prio ' + line.prio);
	}
	return result;
}
function applyIpPlan(available) {
	for (let line in available) {
		if (!length(line.gateway) || !length(line.device)) continue;
		ipAddRoute(line.table, line.gateway, line.device);
		ipAddRule(line.mark, line.table, line.prio);
	}
}

// —— 备份与生效记录 ——
function applied() { return readJson(APPLIED, null); }
function recordApplied(model, text) {
	ensure();
	writeText(NFT, text || '');
	writeJson(APPLIED, { revision: model ? model.revision : 0, enabled: model ? model.enabled === true : false, nft: text || '', time: time() });
}
// 备份“当前生效态”：config 与 nft 文本各留一份 previous，供 rollback 使用。
function backupCurrent(previousConfig) {
	ensureBackup();
	const record = applied();
	const previousNft = record && length(record.nft || '') ? record.nft : (readfile(NFT) || '');
	if (previousConfig) writeText(BACKUP + '/flow.config.previous', sprintf('%J\n', previousConfig));
	if (length(previousNft)) writeText(BACKUP + '/flow.nft.previous', previousNft);
}
function markLastGood(model, text) {
	ensureBackup();
	writeText(BACKUP + '/flow.config.last-good', sprintf('%J\n', model));
	writeText(BACKUP + '/flow.nft.last-good', text || '');
}
// 停用 / 卸载：删自己的表 + 精确清理自己的 rule 与路由表区间。
function teardown() { deleteTable(); cleanupIp(); }

// —— 内核态读取 ——
function nftCounters() {
	const inline = {};
	for (let item in tableJson()) {
		const rule = item.rule;
		if (!rule || !length(rule.comment || '')) continue;
		for (let expression in rule.expr || []) {
			const counter = expression.counter;
			if (counter && type(counter) == 'object') inline[rule.comment] = { packets: +counter.packets || 0, bytes: +counter.bytes || 0 };
		}
	}
	return inline;
}
function tablePresent() { try { return length(tableJson()) > 0; } catch (e) { return false; } }
function domainRuntime(model) {
	const store = domainStore();
	const groups = [];
	for (let rule in model.domain) {
		if (rule.enabled !== true) continue;
		const cached = store.groups ? store.groups[rule.id] : null;
		const seen = {};
		const domains = [];
		if (cached && type(cached.domains) == 'object') {
			for (let name in keys(cached.domains)) {
				const entry = cached.domains[name] || {};
				for (let address in entry.addresses || []) seen[address] = true;
				push(domains, { name, addresses: entry.addresses || [], error: entry.error || '' });
			}
		}
		push(groups, {
			id: rule.id, name: rule.name, line: rule.line, count: length(keys(seen)),
			unresolved: (cached && cached.unresolved) || [], domains,
			updated: cached ? (+cached.time || 0) : 0
		});
	}
	return groups;
}
function lineRuntime(resolved) {
	return map(resolved, line => ({
		id: line.id, name: line.name, interface: line.interface, weight: line.weight,
		enabled: line.enabled, upKbps: line.upKbps, downKbps: line.downKbps,
		up: line.up, degraded: line.degraded, addresses: line.addresses,
		gateway: line.gateway, device: line.device, ifname: line.ifname,
		mark: markText(line.mark), table: line.table, prio: line.prio
	}));
}

// —— 对外：状态聚合 ——
function state() {
	const top = topology();
	let model = defaultConfig(), configError = null;
	try { model = config(); } catch (e) { configError = e.message || '流控分流配置损坏'; }
	const resolved = resolveLines(model, top);
	const available = usableLines(resolved);
	const counters = nftCounters();
	const domains = domainRuntime(model);
	const unresolved = [];
	for (let group in domains) for (let name in group.unresolved) if (index(unresolved, name) < 0) push(unresolved, name);
	const list = [];
	for (let item in devices(top)) {
		const entry = { ip: item.ip };
		if (item.mac) entry.mac = item.mac;
		if (item.hostname) entry.hostname = item.hostname;
		if (item.up != null) entry.up = item.up;
		if (item.down != null) entry.down = item.down;
		if (item.online != null) entry.online = item.online;
		push(list, entry);
	}
	const result = {
		config: model,
		lines: lineRuntime(resolved),
		devices: list,
		topology: {
			lan: top.lan, wan: top.wan, lanSubnets: top.lanSubnets,
			candidates: map(top.candidates, item => ({ name: item.name, device: item.device, gateway: item.gateway, up: item.up, addresses: item.addresses })),
			interfaces: map(top.interfaces, item => ({ name: item.name, device: item.device, up: item.up, proto: item.proto, gateway: item.gateway, addresses: item.addresses }))
		},
		runtime: {
			enabled: model.enabled === true,
			applied: !!applied(),
			tablePresent: tablePresent(),
			lines: map(available, line => ({ id: line.id, mark: markText(line.mark), table: line.table, prio: line.prio, gateway: line.gateway, device: line.device })),
			counters,
			domains,
			unresolved,
			time: time()
		},
		pending: pendingState(),
		caps: caps()
	};
	if (configError) result.error = configError;
	return result;
}
function stateSafely() { try { return state(); } catch (e) { return { error: e.message || '读取流控分流状态失败' }; } }

// —— 对外：只校验不落盘 ——
function check(input) {
	const top = topology();
	const model = normalize(input, top);
	const resolved = resolveLines(model, top);
	const available = usableLines(resolved);
	const compiled = compileNft(model, top, resolved);
	const syntax = nftCheck(compiled.text);
	if (syntax) fail('规则校验未通过：' + syntax);
	return {
		ok: true,
		config: model,
		plan: {
			nftRules: compiled.ruleCount,
			limitRules: compiled.limitRules,
			ipRules: ipPlanLines(available),
			tables: map(available, line => line.table),
			lines: map(resolved, line => ({
				id: line.id, name: line.name, interface: line.interface,
				mark: markText(line.mark), table: line.table, prio: line.prio,
				gateway: line.gateway, device: line.device, degraded: line.degraded
			})),
			nftText: compiled.text,
			warnings: uniq([...warnings(model, available), ...compiled.warnings])
		}
	};
}

// 把 /etc/console-backup/flow.*.previous 恢复回来（生效失败或人工回滚共用）。
function restorePrevious() {
	const previousConfig = readJson(BACKUP + '/flow.config.previous', null);
	const previousNft = readfile(BACKUP + '/flow.nft.previous') || '';
	teardown();
	if (previousConfig && previousConfig.enabled === true && length(trim(previousNft))) {
		nftLoad(previousNft);
		const top = topology();
		applyIpPlan(usableLines(resolveLines(normalize(previousConfig, top), top)));
		writeConfig(previousConfig);
		recordApplied(previousConfig, previousNft);
	} else if (previousConfig) {
		// 上一份是“停用”状态：清空生效态，但**必须把 config 一起写回**，
		// 否则 config.json 还留着 enabled=true，页面会显示“已启用”而内核里什么都没有。
		writeConfig(previousConfig);
		writeText(NFT, '');
		recordApplied(previousConfig, '');
	} else {
		// 连备份都没有：退回“无配置”的初始状态。
		writeText(NFT, '');
		recordApplied(null, '');
	}
}

// —— 对外：应用（120 秒确认窗口） ——
function applyPolicy(input) {
	ensure();
	return withLock(() => {
		if (pendingState()) fail('上一次变更还在确认窗口内，请先确认或回滚');
		const top = topology();
		const model = normalize(input, top);
		const previous = config();
		if (int(input.revision || 0) != previous.revision) fail('配置已被其他页面修改，请刷新页面后重试');

		const resolved = resolveLines(model, top);
		const available = usableLines(resolved);
		const compiled = compileNft(model, top, resolved);
		// 1) nft 语法预检：不通过就什么都不写，保证不会把人挡在门外。
		const syntax = nftCheck(compiled.text);
		if (syntax) fail('配置未通过 nftables 校验，已拒绝生效：' + syntax);

		// 2) 备份当前生效态，后续任何失败都能回到上一份可用配置。
		backupCurrent(previous);
		// 3) 先落 pending 再生效：断电或崩溃后由服务按 pending 回滚。
		writePending({ revision: model.revision + 1, kind: 'apply' });

		model.revision = previous.revision + 1;
		try {
			writeConfig(model);
			if (model.enabled === true) {
				nftLoad(compiled.text);
				applyIpPlan(available);
			} else {
				teardown();
			}
		} catch (e) {
			clearPending();
			try { restorePrevious(); } catch (ignored) {}
			die(e.message || '应用流控配置失败');
		}
		recordApplied(model, model.enabled === true ? compiled.text : '');
		markLastGood(model, model.enabled === true ? compiled.text : '');
		spawnRollback();
		return { ok: true, state: stateSafely(), pending: pendingState() };
	});
}

function confirmPolicy() {
	return withLock(() => {
		const pending = pendingState();
		if (pending && pending.secondsLeft <= 0) { clearPending(); fail('确认窗口已过期，配置已自动回滚'); }
		clearPending();
		return { ok: true };
	});
}

// 回滚。expiredOnly=true 时只在确认窗口到期后执行（后台计时器调用）。
function rollbackPolicy(expiredOnly) {
	const pending = pendingState();
	if (expiredOnly && (!pending || pending.secondsLeft > 0)) return { ok: true, skipped: true };
	return withLock(() => {
		restorePrevious();
		clearPending();
		return { ok: true, state: stateSafely() };
	});
}

// 重置：清空全部配置并卸载表 / rule / 路由表。
function reset() {
	return withLock(() => {
		teardown();
		unlink(CONFIG);
		unlink(NFT);
		unlink(APPLIED);
		clearPending();
		return { ok: true, config: config() };
	});
}

// 后台计时器到期：只回滚，不抛错（独立进程，失败写日志）。
function expirePending() {
	const pending = pendingState();
	if (!pending || pending.secondsLeft > 0) return { ok: true, skipped: true };
	try { return rollbackPolicy(true); }
	catch (e) { warn('流控分流自动回滚失败：' + (e.message || '未知错误') + '\n'); return { ok: false, error: e.message }; }
}

// 重建内核态（表 + ip rule + 路由表）。**调用方必须已持有写锁** —— 这里的重建
// 会先 destroy 再 load，若与其他写操作交错会出现短暂空窗。
// 供 restore() / refresh() / refreshDomains() 共用，避免在已持锁时再次进入 withLock
// （ucode 的 withLock 不可重入，嵌套调用会直接判定“另一个任务正在执行”而跳过）。
function reloadKernel(model) {
	const top = topology();
	const normalized = normalize(model, top);
	const resolved = resolveLines(normalized, top);
	const compiled = compileNft(normalized, top, resolved);
	nftLoad(compiled.text);
	applyIpPlan(usableLines(resolved));
	recordApplied(normalized, compiled.text);
	return { ok: true, nft: compiled.text };
}

// 开机恢复：读 config 重建表/规则/路由；无 config 则只清理。
// 若存在未确认的 pending（改完没确认就重启/断电），直接按备份回滚。
function restore() {
	ensure();
	try {
		if (pendingState()) {
			clearPending();
			restorePrevious();
			return { ok: true, rolledBack: true };
		}
	} catch (e) {
		warn('流控分流恢复上次配置失败：' + (e.message || '未知错误') + '\n');
	}
	let model = null;
	try { model = config(); } catch (e) { warn('流控分流配置损坏，已跳过恢复：' + (e.message || '') + '\n'); return { ok: false, error: e.message }; }
	if (!model || model.enabled !== true) { teardown(); return { ok: true, enabled: false }; }
	return withLock(() => {
		reloadKernel(model);
		return { ok: true, enabled: true };
	});
}

// reload：拓扑变化（线路上下线、DHCP 续租）后重建规则；有写锁在进行中的操作时跳过。
function refresh() {
	if (stat('/tmp/console-flow-write.lock')) return { ok: true, skipped: true };
	return withLock(() => {
		if (pendingState()) return { ok: true, skipped: true };
		const model = config();
		if (!model || model.enabled !== true) return { ok: true, skipped: true };
		reloadKernel(model);
		return { ok: true };
	});
}

// —— 域名解析 ——
// 目标机 dnsmasq 未编入 nftset，只能自己 nslookup 后写 interval 集合。
// nslookup 输出里 “Server/Address: 127.0.0.1” 是服务器本身，必须先排除。
function resolveNames(names) {
	const result = [];
	for (let name in names) {
		const addresses = [], errors = [];
		const text = output(['/usr/bin/nslookup', name, '127.0.0.1']);
		for (let line in split(text || '', '\n')) {
			const body = trim(line);
			const matched = match(body, /^Address:\s+([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$/);
			if (matched && ip4(matched[1]) != null && index(addresses, matched[1]) < 0) push(addresses, matched[1]);
			if (match(body, /^(No answer|NXDOMAIN|SERVFAIL|\*\* server)/)) push(errors, body);
			if (match(body, /^can't find /)) push(errors, body);
		}
		const entry = { name, addresses };
		if (!length(addresses)) entry.error = length(errors) ? errors[0] : '未解析到 IPv4 地址';
		push(result, entry);
	}
	return result;
}

// resolve：解析传入配置里的域名（不落盘、不改系统）。
function resolvePolicy(input) {
	const top = topology();
	const model = normalize(input, top);
	const groups = [];
	for (let rule in model.domain) {
		if (rule.enabled !== true) continue;
		push(groups, { id: rule.id, name: rule.name, domains: resolveNames(rule.domains) });
	}
	return { ok: true, groups };
}
// 刷新解析结果并重建 nft 集合。force=true 时忽略 ttl 立即解析。
function refreshDomains(force) {
	return withLock(() => {
		const model = config();
		if (model.enabled !== true) return { ok: true, skipped: true };
		const store = domainStore();
		if (type(store.groups) != 'object') store.groups = {};
		const now = time();
		let changed = false, attempted = 0;
		for (let rule in model.domain) {
			if (rule.enabled !== true) continue;
			const cached = store.groups[rule.id];
			// ttl 未到期且非强制刷新时跳过，避免每分钟重复查 DNS。
			if (!force && cached && cached.time && now - cached.time < rule.ttl) continue;
			attempted++;
			const entries = resolveNames(rule.domains);
			const domains = {}, unresolved = [];
			for (let entry in entries) {
				if (length(entry.addresses)) domains[entry.name] = { addresses: entry.addresses, time: now };
				else {
					// 解析失败保留旧地址：网络抖动时不能把集合清空导致分流跳线。
					const previous = cached && cached.domains ? cached.domains[entry.name] : null;
					domains[entry.name] = previous
						? { addresses: previous.addresses || [], time: previous.time || now, error: entry.error }
						: { addresses: [], time: now, error: entry.error };
					push(unresolved, entry.name);
				}
			}
			store.groups[rule.id] = { time: now, domains, unresolved };
			changed = true;
		}
		// 清掉已删除规则留下的孤儿组，避免 domains.json 无限增长。
		const valid = {};
		for (let rule in model.domain) valid[rule.id] = true;
		let dropped = false;
		for (let id in keys(store.groups)) if (!valid[id]) { delete store.groups[id]; dropped = true; }
		if (changed || dropped) {
			store.updated = now;
			writeDomainStore(store);
			// 立刻把新集合应用进内核（只重建表，不动配置与 revision）。
			// 这里已经持有写锁，必须调用免锁的 reloadKernel，不能调 refresh()。
			if (changed && !pendingState()) reloadKernel(model);
		}
		return { ok: true, changed, attempted };
	});
}

export {
	compileNft, ipPlanLines, limitTargets, rateBytes,
	check, applyPolicy, confirmPolicy, rollbackPolicy, reset,
	expirePending, restore, refresh, refreshDomains,
	state, resolvePolicy, restorePrevious
};
