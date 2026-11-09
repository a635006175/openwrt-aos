// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require console.feedback as feedback';

// 内外网设置页（爱快式）：
// - 按角色列出接口（外网 / 内网），每行显示网卡、接入方式、当前地址与连接状态；
// - 内网接口固定使用静态地址；外网接口支持 静态地址 / DHCP 客户端 / PPPoE；
// - 修改 LAN 静态地址这类高危操作后，进入 120 秒确认窗口：
//   页面倒计时提示「确认生效」，超时未确认则由路由器自动回滚，避免失联；
// - 空闲网卡展示在「未分配网卡」区，可用来新建接口。
// 本页不写 firewall、不写 device（桥），只改 interface 段的接入配置。

const getState = rpc.declare({ object: 'console-net', method: 'state', reject: true });
const applyIface = rpc.declare({ object: 'console-net', method: 'apply', params: [ 'name', 'config' ], reject: true });
const checkIface = rpc.declare({ object: 'console-net', method: 'check', params: [ 'name', 'config' ], reject: true });
const confirmApply = rpc.declare({ object: 'console-net', method: 'confirm', reject: true });
const rollback = rpc.declare({ object: 'console-net', method: 'rollback', reject: true });
const createIface = rpc.declare({ object: 'console-net', method: 'create', params: [ 'config' ], reject: true });
const removeIface = rpc.declare({ object: 'console-net', method: 'remove', params: [ 'name' ], reject: true });
const checkBridge = rpc.declare({ object: 'console-net', method: 'bridge_check', params: [ 'name', 'ports' ], reject: true });
const applyBridge = rpc.declare({ object: 'console-net', method: 'bridge_apply', params: [ 'name', 'ports' ], reject: true });

const PROTO_TEXT = { static: '静态地址', dhcp: 'DHCP 客户端', pppoe: 'PPPoE 宽带' };
const ROLE_TEXT = { wan: '外网', lan: '内网' };

let fieldSeq = 0;
function field(labelText, control, help) {
	const id = 'cn-net-field-' + (++fieldSeq);
	if (!control.id) control.id = id;
	const body = E('div', { class: 'cbi-value-field' }, [ control ]);
	if (help) body.append(E('div', { class: 'cbi-value-description' }, help));
	return E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title', for: control.id }, labelText), body ]);
}

function bytes(value) {
	if (!Number.isFinite(+value)) return '—';
	const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let i = 0, n = +value;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return n.toFixed(i ? 2 : 0) + ' ' + units[i];
}

/* ------------------- 「当前连接信息」展示辅助 -------------------
 * 字段来源见 tmp/net-detail-contract.md。契约约定：state.defaultRoute、
 * state.residentDns、iface.mtuOption、iface.link.*、iface.runtime.* 全部可能缺失，
 * 前端必须降级为「—」，且渲染结果里不允许出现 undefined / NaN / null。
 * 下面这些函数是唯一的格式化出口：所有值都先过这里，再进 DOM。 */
const DASH = '—';

// 只认字符串 / 数字 / 布尔；对象、数组、函数一律当作「缺失」，
// 避免把 [object Object] 之类的值渲染到页面上。
function present(value) {
	if (value === null || value === undefined) return false;
	const kind = typeof value;
	if (kind === 'string') return value.trim() !== '';
	if (kind === 'number') return Number.isFinite(value);
	if (kind === 'boolean') return true;
	return false;
}

// 任意值 -> 可直接展示的文本（含布尔），缺失为「—」。
function shown(value) {
	if (typeof value === 'string') return value.trim() === '' ? DASH : value.trim();
	if (typeof value === 'number') return Number.isFinite(value) ? String(value) : DASH;
	if (typeof value === 'boolean') return value ? '是' : '否';
	return DASH;
}

// 任意值 -> 有限数字，否则 null（避免 NaN 流到页面上）。
function numberOrNull(value) {
	if (typeof value === 'number') return Number.isFinite(value) ? value : null;
	if (typeof value === 'string' && value.trim() !== '') {
		const parsed = +value;
		return Number.isFinite(parsed) ? parsed : null;
	}
	return null;
}

// 前缀长度 -> 点分十进制掩码。仅用于契约里 netmask 缺失时对同一个 prefix 做等价换算，
// 不引入任何后端未提供的信息。
function maskFromPrefix(prefix) {
	const bits = numberOrNull(prefix);
	if (bits === null || bits < 0 || bits > 32) return null;
	const parts = [];
	for (let i = 0; i < 4; i++) parts.push(String(256 - Math.pow(2, 8 - Math.min(8, Math.max(0, bits - i * 8)))));
	return parts.join('.');
}

// 掩码展示：255.255.254.0（/23）。只有 prefix 时退化为「（/23）」之外的空值。
function maskLabel(mask, netmask) {
	const prefix = numberOrNull(mask);
	const text = present(netmask) ? String(netmask).trim() : maskFromPrefix(prefix);
	if (!text) return prefix === null ? null : '/' + prefix;
	return prefix === null ? text : text + '（/' + prefix + '）';
}

// 字符串数组 -> 「a b c」，空数组为「—」。
function joinText(values, separator) {
	if (!Array.isArray(values)) return DASH;
	const items = [];
	for (const value of values) {
		if (typeof value === 'string' && value.trim() !== '') items.push(value.trim());
		else if (typeof value === 'number' && Number.isFinite(value)) items.push(String(value));
	}
	return items.length ? items.join(separator) : DASH;
}

// 在线秒数 -> 「1 天 2 小时」这类中文时长；缺失 / 负数一律「—」。
function durationText(seconds) {
	const total = numberOrNull(seconds);
	if (total === null || total < 0) return DASH;
	const days = Math.floor(total / 86400);
	const hours = Math.floor((total % 86400) / 3600);
	const minutes = Math.floor((total % 3600) / 60);
	if (days > 0) return days + ' 天 ' + hours + ' 小时';
	if (hours > 0) return hours + ' 小时 ' + minutes + ' 分';
	if (minutes > 0) return minutes + ' 分';
	return Math.floor(total) + ' 秒';
}

// 链路状态三段：载波 / 速率 / 双工。契约明确 speed、duplex 在虚拟网卡上就是 null。
function carrierText(link) {
	const carrier = link ? link.carrier : null;
	if (carrier === true) return '载波正常';
	if (carrier === false) return '无载波';
	return '载波 ' + DASH;
}

function speedText(link) {
	const speed = numberOrNull(link ? link.speed : null);
	return speed !== null && speed > 0 ? speed + ' Mb/s' : '速率 ' + DASH;
}

function duplexText(link) {
	const duplex = link ? link.duplex : null;
	if (duplex === 'full') return '全双工';
	if (duplex === 'half') return '半双工';
	return '双工 ' + DASH;
}

// MTU 输入框即时校验：68–9000 的整数，或留空（留空 = 删除 uci 的 mtu 选项）。
// 返回 { value: 提交值, error: 提示文案 }，error 为 null 表示合法。
function mtuInputCheck(raw) {
	const text = (raw === null || raw === undefined) ? '' : String(raw).trim();
	if (text === '') return { value: '', error: null };
	if (!/^[0-9]{1,5}$/.test(text)) return { value: null, error: 'MTU 必须是 68–9000 之间的整数，或留空使用默认值。' };
	const parsed = +text;
	if (parsed < 68 || parsed > 9000) return { value: null, error: 'MTU 必须是 68–9000 之间的整数，或留空使用默认值。' };
	return { value: String(parsed), error: null };
}

// 可写输入框的初值：只接受字符串 / 有限数字，其余（缺失、对象、数组）一律空串，
// 避免把异常类型塞进 input 的 value 属性。
function textOrEmpty(value) {
	if (typeof value === 'string') return value;
	if (typeof value === 'number' && Number.isFinite(value)) return String(value);
	return '';
}

function listOrEmpty(value) {
	return Array.isArray(value) ? value : [];
}

return view.extend(feedback.decorate({
	load() { return getState(); },

	async refresh() {
		try {
			const data = await getState();
			if (data.error) throw new Error(data.error);
			this.state = data.state;
			this.renderInto();
			this.checkPending();
		}
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '读取网络配置失败'), 'error'); }
	},

	async checkPending() {
		const pending = (this.state && this.state.pending) || null;
		if (!pending) return;
		ui.showModal('存在未确认的网络变更', [
			E('p', {}, '上一次修改尚未确认：' + (pending.description || '')),
			E('p', { class: 'cn-net-warn' },
				Math.max(0, pending.secondsLeft) + ' 秒后将自动回滚到修改前的配置。如果当前网络正常，请点击「确认生效」。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: async () => {
					try { await rollback(); ui.hideModal(); ui.addNotification(null, E('p', {}, '已回滚到修改前的配置。'), 'info'); this.refresh(); }
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '回滚失败'), 'error'); }
				} }, '立即回滚'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: async () => {
					try { await confirmApply(); ui.hideModal(); ui.addNotification(null, E('p', {}, '已确认，本次变更保留。'), 'success'); this.refresh(); }
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '确认失败'), 'error'); }
				} }, '确认生效')
			])
		]);
	},

	renderInto() {
		if (!this.root) return;
		const s = this.state || {};
		const wan = (s.interfaces || []).filter(i => i.role === 'wan');
		const lan = (s.interfaces || []).filter(i => i.role === 'lan');
		const other = (s.interfaces || []).filter(i => i.role !== 'wan' && i.role !== 'lan');
		const free = (s.devices || []).filter(d => !d.usedBy);
		this.root.replaceChildren(...[
			this.header(),
			this.summary(),
			this.groupPanel('外网接口 (WAN)', wan),
			this.groupPanel('内网接口 (LAN)', lan),
			other.length ? this.groupPanel('其他接口', other) : null,
			this.freePanel(free)
		].filter(Boolean));
	},

	header() {
		return E('div', { class: 'cn-net-heading' }, [
			E('div', {}, [ E('h2', {}, '内外网设置'), E('p', {}, '内网接口固定使用静态地址；外网可选自动获取、静态地址或 PPPoE。终端地址分配请在「DHCP 服务器」中设置。修改 LAN 静态地址会进入确认窗口，超时自动回滚。') ]),
			E('button', { type: 'button', class: 'cbi-button cbi-button-add', click: () => this.addInterface() }, '新增接口')
		]);
	},

	summary() {
		const s = this.state || {};
		const up = (s.interfaces || []).filter(i => i.runtime && i.runtime.up).length;
		return E('section', { class: 'cn-panel cn-net-summary' }, [
			E('div', { class: 'cn-net-metrics' }, [
				E('div', { class: 'cn-net-metric' }, [ E('strong', {}, String(up)), E('span', {}, '已连接接口') ]),
				E('div', { class: 'cn-net-metric' }, [ E('strong', {}, String((s.interfaces || []).length)), E('span', {}, '接口总数') ]),
				E('div', { class: 'cn-net-metric' }, [ E('strong', {}, String((s.devices || []).filter(d => !d.usedBy).length)), E('span', {}, '空闲网卡') ])
			])
		]);
	},

	// 单个接口行：状态灯 + 名称 + 网卡 + 接入方式 + 地址 + 操作
	row(iface) {
		const runtime = iface.runtime || {};
		const up = runtime.up === true;
		const addr = iface.proto === 'static'
			? (present(iface.address) ? textOrEmpty(iface.address) + '/' + shown(iface.prefix) : '未配置')
			: (listOrEmpty(runtime.addresses).length
				? listOrEmpty(runtime.addresses).map(a => shown(a && a.address) + '/' + shown(a && a.mask)).join(', ')
				: '等待地址');
		const gw = iface.proto === 'static' ? shown(iface.gateway) : shown(runtime.gateway);
		const ports = iface.bridge ? listOrEmpty(iface.bridge.ports).filter(p => present(p)) : [];
		const portList = ports.length ? ports : null;
		// 有 dialText 就用后端的权威文案（已获取地址 / 正在拨号 / 已停用 …），
		// 没有则退回原来的「已连接 / 未连接」。
		const statusText = present(runtime.dialText) ? String(runtime.dialText) : (up ? '已连接' : '未连接');
		const carriesRoute = runtime.defaultRoute === true;
		return E('div', { class: 'cn-net-iface' + (up ? ' up' : ' down') }, [
			E('span', { class: 'cn-net-dot' }),
			E('strong', { class: 'cn-net-name' }, ROLE_TEXT[iface.role] ? ROLE_TEXT[iface.role] + ' · ' : '', shown(iface.name)),
			carriesRoute ? E('span', { class: 'cn-net-badge' }, '默认') : null,
			E('span', { class: 'cn-net-device' }, shown(iface.device)),
			E('span', { class: 'cn-net-proto' }, PROTO_TEXT[iface.proto] || shown(iface.proto)),
			E('span', { class: 'cn-net-addr' }, addr),
			E('span', { class: 'cn-net-gw' }, '网关 ' + gw),
			// 桥成员直接列在行内，避免用户必须点进弹框才知道 LAN 桥带了哪几口
			portList ? E('span', { class: 'cn-net-ports-text' }, '成员 ' + portList.join(' / ')) : null,
			E('span', { class: 'cn-net-status' }, statusText),
			E('div', { class: 'cn-net-actions' }, [
				E('button', { type: 'button', class: 'cbi-button cbi-button-edit', click: () => this.edit(iface) }, '编辑'),
				portList ? E('button', { type: 'button', class: 'cbi-button', click: () => this.editBridge(iface) }, '桥成员') : null,
				E('button', { type: 'button', class: 'cbi-button', click: () => this.reconnect(iface) }, '重连'),
				iface.role !== 'lan' ? E('button', { type: 'button', class: 'cbi-button cbi-button-remove', click: () => this.remove(iface) }, '删除') : null
			].filter(Boolean))
		]);
	},

	groupPanel(title, list) {
		return E('section', { class: 'cn-panel' }, [
			E('h3', {}, title + ' (' + list.length + ')'),
			E('div', { class: 'cn-net-list' }, list.map(i => this.row(i)))
		]);
	},

	freePanel(free) {
		return E('section', { class: 'cn-panel cn-net-free' }, [
			E('h3', {}, '未分配网卡 (' + free.length + ')'),
			free.length
				? E('p', {}, free.map(d => d.name).join('　/　'))
				: E('p', {}, '所有物理网卡都已分配。'),
			E('p', { class: 'cn-help' }, '在上方选择接口点「编辑」可更换其绑定的网卡；「新增接口」可把空闲网卡接入网络。')
		]);
	},

	// 「当前连接信息」只读区块：把契约里能拿到的连接态一次性摊开给用户看，
	// 避免修接口时还要切到概览页比参数。所有字段缺失都给「—」，不猜值。
	infoBlock(iface) {
		const link = iface.link || null;
		const runtime = iface.runtime || null;
		const mtuValue = (link && numberOrNull(link.mtu) !== null) ? String(link.mtu) : DASH;

		// 1. 网卡 / MAC
		const device = present(iface.device) ? iface.device : DASH;
		const mac = link && present(link.macaddr) ? String(link.macaddr) : DASH;

		// 2. 链路状态：载波 + 速率 + 双工（另附设备上下线，便于判断「UP 但没插线」）
		const linkParts = [ carrierText(link), speedText(link), duplexText(link) ];
		if (link && typeof link.up === 'boolean') linkParts.push(link.up ? '设备已启用' : '设备未启用');

		// 3. MTU：只取生效值 link.mtu；配置值见下方可写的 MTU 输入框
		const mtu = mtuValue;

		// 4. IP 地址：运行时全部 IPv4；静态接口另附 uci 配置值。
		//    两边都有且不同时并存展示，避免用户误以为配置没生效。
		const runtimeAddrs = (runtime && Array.isArray(runtime.addresses) ? runtime.addresses : [])
			.filter(a => a && present(a.address))
			.map(a => String(a.address) + (numberOrNull(a.mask) !== null ? '/' + numberOrNull(a.mask) : ''));
		let ipText = runtimeAddrs.length ? runtimeAddrs.join('、') : DASH;
		if (iface.proto === 'static' && present(iface.address)) {
			const configured = String(iface.address) + (numberOrNull(iface.prefix) !== null ? '/' + numberOrNull(iface.prefix) : '');
			if (runtimeAddrs.length && !runtimeAddrs.includes(configured)) ipText += '（配置 ' + configured + '）';
			else if (!runtimeAddrs.length) ipText = configured + '（配置值，尚未生效）';
		}
		const ipv6List = (runtime && Array.isArray(runtime.ipv6) ? runtime.ipv6 : [])
			.filter(a => a && present(a.address))
			.map(a => String(a.address) + (numberOrNull(a.mask) !== null ? '/' + numberOrNull(a.mask) : ''));
		if (ipv6List.length) ipText += '　IPv6 ' + ipv6List.join('、');

		// 5. 子网掩码：255.255.254.0（/23）。静态接口优先用配置前缀。
		const primary = (runtime && Array.isArray(runtime.addresses) ? runtime.addresses : [])
			.find(a => a && present(a.address)) || null;
		const prefixSource = (iface.proto === 'static' && numberOrNull(iface.prefix) !== null)
			? iface.prefix : (primary ? primary.mask : null);
		const netmaskSource = (iface.proto === 'static' && present(iface.netmask))
			? iface.netmask : (primary ? primary.netmask : null);
		const mask = maskLabel(prefixSource, netmaskSource) || DASH;

		// 6. 默认网关：真实的 nexthop；静态接口回退到 uci 配置值。
		let gateway = DASH;
		if (runtime && present(runtime.gateway)) gateway = String(runtime.gateway);
		else if (iface.proto === 'static' && present(iface.gateway)) gateway = String(iface.gateway) + '（配置值）';
		else if (runtime) gateway = '未设置';

		// 7. 是否默认路由：三态文案，由后端 runtime.defaultRoute 判定。
		const routeOwner = (this.state && this.state.defaultRoute && present(this.state.defaultRoute.interface))
			? String(this.state.defaultRoute.interface) : null;
		let defaultRouteText = DASH;
		if (runtime && typeof runtime.defaultRoute === 'boolean') {
			if (runtime.defaultRoute) defaultRouteText = '是（当前系统默认路由）';
			else if (routeOwner) defaultRouteText = routeOwner === iface.name
				? '是（当前系统默认路由）' : '否（默认路由由 ' + routeOwner + ' 承担）';
			else defaultRouteText = '否（系统无默认路由）';
		}

		// 8. DNS：区分「静态配置值」与「上游下发值」，另列写入 resolv 的地址。
		const staticDns = Array.isArray(iface.dns) ? iface.dns.filter(d => present(d)) : [];
		const upstreamDns = (runtime && Array.isArray(runtime.dns) ? runtime.dns : []).filter(d => present(d));
		const residentList = (this.state && this.state.residentDns && Array.isArray(this.state.residentDns[iface.name]))
			? this.state.residentDns[iface.name].filter(d => present(d)) : [];
		const dnsRows = [];
		if (staticDns.length) dnsRows.push('静态配置：' + joinText(staticDns, '、'));
		if (upstreamDns.length) dnsRows.push('上游下发：' + joinText(upstreamDns, '、'));
		if (residentList.length) dnsRows.push('写入 resolv：' + joinText(residentList, '、'));
		if (!dnsRows.length && iface.proto === 'static' && iface.dns && iface.dns.length === 0) dnsRows.push('静态配置：未设置');

		// 9. 连接状态：dialText + 在线时长 + 协议进程名
		const statusParts = [ present(runtime && runtime.dialText) ? String(runtime.dialText) : DASH ];
		statusParts.push('在线 ' + (runtime && runtime.up ? durationText(runtime.uptime) : DASH));
		statusParts.push('进程 ' + (runtime && present(runtime.protoProcess) ? String(runtime.protoProcess) : DASH));
		if (runtime && runtime.pending === true) statusParts.push('配置下发中');

		// 10. 桥成员：仅桥接口
		const bridgePorts = iface.bridge && Array.isArray(iface.bridge.ports) && iface.bridge.ports.length
			? iface.bridge.ports.filter(p => present(p)).join(' / ') : null;

		const rows = [
			[ '网卡 / MAC', device + (mac !== DASH ? ' · ' + mac : '') ],
			[ '链路状态', linkParts.join(' · ') ],
			[ 'MTU（生效）', mtu ],
			[ 'IP 地址', ipText ],
			[ '子网掩码', mask ],
			[ '默认网关', gateway ],
			[ '默认路由', defaultRouteText ],
			[ 'DNS 服务器', dnsRows.length ? dnsRows.join('；') : DASH ],
			[ '连接状态', statusParts.join(' · ') ]
		];
		if (bridgePorts) rows.push([ '桥成员', bridgePorts ]);

		return E('section', { class: 'cn-net-info' }, [
			E('h4', { class: 'cn-net-info-title' }, '当前连接信息'),
			E('div', { class: 'cn-net-info-grid' }, rows.map(([ labelText, valueText ]) =>
				E('div', { class: 'cn-net-info-item' }, [
					E('span', { class: 'cn-net-info-label' }, labelText),
					E('span', { class: 'cn-net-info-value' }, valueText)
				])))
		]);
	},

	// 编辑弹框：接入方式切换时动态切换字段组
	edit(iface) {
		fieldSeq = 0;
		const isLan = iface.role === 'lan';
		const linkMtu = iface.link ? numberOrNull(iface.link.mtu) : null;
		const inputs = {
			device: E('select', {}, listOrEmpty(this.state.devices).map(d => {
				const name = shown(d && d.name);
				const usedBy = (d && present(d.usedBy) && d.usedBy !== iface.name) ? String(d.usedBy) : null;
				return E('option', { value: name, selected: name === iface.device || null },
					name + (usedBy ? '（已被 ' + usedBy + ' 使用）' : ''));
			})),
			proto: isLan ? null : E('select', {}, [ 'static', 'dhcp', 'pppoe' ].map(p =>
				E('option', { value: p, selected: p === iface.proto || null }, PROTO_TEXT[p]))),
			address: E('input', { type: 'text', value: textOrEmpty(iface.address), placeholder: '192.168.1.1' }),
			prefix: E('select', {}, [ 8, 16, 22, 23, 24, 25, 26, 28, 30 ].map(p =>
				E('option', { value: String(p), selected: (iface.prefix || 24) === p || null }, '255.255.255.' + (p === 24 ? '0' : '·') + '  (' + p + ' 位)'))),
			gateway: E('input', { type: 'text', value: textOrEmpty(iface.gateway), placeholder: '留空则不设网关' }),
			dns: E('input', { type: 'text', value: listOrEmpty(iface.dns).join(' '), placeholder: '223.5.5.5 114.114.114.114' }),
			username: E('input', { type: 'text', value: textOrEmpty(iface.username), autocomplete: 'off' }),
			password: E('input', { type: 'password', value: '', placeholder: iface.hasPassword ? '已保存，留空保持不变' : '' }),
			hostname: E('input', { type: 'text', value: textOrEmpty(iface.hostname), placeholder: '选填' }),
			// MTU 可写项：初值取 uci 原始字符串 mtuOption，留空表示「不配置，用默认」。
			mtu: E('input', {
				type: 'text', inputmode: 'numeric', autocomplete: 'off',
				value: present(iface.mtuOption) ? String(iface.mtuOption) : '',
				placeholder: linkMtu !== null ? '默认（当前生效 ' + linkMtu + '）' : '默认（当前生效 —）'
			})
		};
		// 即时校验：68–9000 整数或留空；不合法时标红提示，但允许用户继续改。
		// 说明文字里同时给出「uci 当前配置值」和「内核当前生效值」，
		// 用户才能判断留空会不会改变现状。
		const mtuConfigured = present(iface.mtuOption) ? String(iface.mtuOption).trim() : '';
		const effectiveText = linkMtu !== null ? String(linkMtu) : DASH;
		const mtuHelpText = () => {
			const effective = '当前生效 ' + effectiveText + '。';
			if (mtuConfigured) return '当前已配置 ' + mtuConfigured + '；留空将删除该配置，改用系统默认值（' + effective + '）。';
			return '当前未配置，使用系统默认值（' + effective + '）。留空表示不配置。';
		};
		const mtuNote = E('div', { class: 'cn-net-mtu-note' }, mtuHelpText());
		const validateMtu = () => {
			const result = mtuInputCheck(inputs.mtu.value);
			inputs.mtu.classList.toggle('invalid', !!result.error);
			mtuNote.textContent = result.error ? result.error : mtuHelpText();
			mtuNote.classList.toggle('cn-net-mtu-error', !!result.error);
			return result;
		};
		inputs.mtu.addEventListener('input', validateMtu);
		inputs.mtu.addEventListener('change', validateMtu);
		// MTU 三种接入方式都要能改，所以放在协议字段组之外、弹框底部。
		// 注意：同一个 DOM 节点不能同时挂到多个父节点（append 会移动节点），
		// 因此这里只有一个实例，不在 groups.* 里各放一份。
		const mtuField = E('div', { class: 'cn-net-mtu-field' }, [
			field('MTU', inputs.mtu),
			mtuNote
		]);
		const groups = {};
		groups.static = E('div', {}, [
			field('IP 地址', inputs.address, isLan ? '固定的路由器内网地址；终端自动获取地址请在「DHCP 服务器」中配置。' : ''),
			field('子网掩码', inputs.prefix),
			field('默认网关', inputs.gateway, '留空表示不设默认路由。'),
			field('DNS 服务器', inputs.dns, '多个地址用空格分隔。')
		]);
		groups.pppoe = E('div', {}, [
			field('宽带账号', inputs.username),
			field('宽带密码', inputs.password, iface.hasPassword ? '已保存的密码不会回显。' : '由运营商提供。'),
			field('服务名', E('input', { type: 'text', value: textOrEmpty(iface.service), placeholder: '一般留空' })),
			field('拨号附注', E('div', { class: 'cn-help' }, 'PPPoE 使用上方选择的网卡拨号，连接成功后地址由运营商分配。'))
		]);
		groups.dhcp = E('div', {}, [
			field('客户端主机名', inputs.hostname, '向 DHCP 服务器通告的主机名，可留空。'),
			field('附注', E('div', { class: 'cn-help' }, '地址、网关与 DNS 由上级 DHCP 服务器分配，本机无需填写。'))
		]);
		const body = E('div', { class: 'cn-net-proto-groups' }, [ groups[isLan ? 'static' : iface.proto] || E('div') ]);
		if (!isLan) inputs.proto.addEventListener('change', () => {
			body.replaceChildren(groups[inputs.proto.value] || E('div'));
		});

		ui.showModal('接口设置 · ' + iface.name, [
			E('div', { class: 'cn-net-modal-head' }, [
				E('span', { class: 'badge ' + (iface.runtime && iface.runtime.up ? 'label-success' : 'label-warning') },
					present(iface.runtime && iface.runtime.dialText)
						? String(iface.runtime.dialText)
						: (iface.runtime && iface.runtime.up ? '已连接' : '未连接')),
				E('span', {}, '当前地址 ' + (listOrEmpty(iface.runtime && iface.runtime.addresses)
					.map(a => shown(a && a.address)).filter(v => v !== DASH).join(', ') || '—'))
			]),
			// 只读区：先给用户看清「现在是什么样」，再往下才是可写的配置项。
			this.infoBlock(iface),
			field('绑定网卡', inputs.device, iface.role === 'lan' ? '内网接口可绑定网桥；要增删桥成员，请关闭本弹框后点该行的「桥成员」按钮。' : ''),
			field('接入方式', isLan ? E('div', { class: 'cn-net-proto-fixed' }, '静态地址') : inputs.proto),
			body,
			mtuField,
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.submit(iface, inputs) }, '保存')
			])
		]);
	},

	async submit(iface, inputs) {
		// MTU 先本地校验一次：不合法就不提交，避免把明显错误的配置送到后端。
		const mtu = mtuInputCheck(inputs.mtu ? inputs.mtu.value : '');
		if (mtu.error) {
			if (inputs.mtu) inputs.mtu.classList.add('invalid');
			ui.addNotification(null, E('p', {}, mtu.error), 'error');
			return;
		}
		const config = {
			proto: iface.role === 'lan' ? 'static' : inputs.proto.value,
			device: inputs.device.value,
			// 契约第五节：空字符串 = 删除 network.<name>.mtu；数字 = 写入。
			mtu: mtu.value
		};
		if (config.proto === 'static') {
			config.address = inputs.address.value.trim();
			config.prefix = +inputs.prefix.value;
			config.gateway = inputs.gateway.value.trim();
			config.dns = inputs.dns.value.trim().split(/\s+/).filter(Boolean);
			config.keepPassword = true;
		}
		else if (config.proto === 'pppoe') {
			config.username = inputs.username.value.trim();
			config.password = inputs.password.value;
			config.keepPassword = !inputs.password.value.length;
		}
		else if (config.proto === 'dhcp') {
			config.hostname = inputs.hostname.value.trim();
		}

		try {
			const check = await checkIface(iface.name, config);
			if (check.error) throw new Error(check.error);
			const result = await applyIface(iface.name, config);
			if (result.error) throw new Error(result.error);
			ui.hideModal();
			this.state = result.state;
			this.renderInto();
			if (result.deadline) this.showConfirm(iface.name, result, '地址已修改');
			else ui.addNotification(null, E('p', {}, '接口配置已保存并生效。'), 'info');
			this.checkPending();
		}
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '保存失败'), 'error'); }
	},

	// 确认窗口：写完高风险配置后请用户确认网络仍可访问，
	// 未确认则倒计时结束后由后端守护进程自动回滚。
	// 接口地址修改与网桥成员变更共用这段逻辑，避免两处各写一份。
	showConfirm(name, result, what) {
		const seconds = Math.max(0, +result.confirmSeconds || 0);
		ui.showModal('修改已提交，请确认网络可用', [
			E('p', { class: 'cn-net-warn' },
				'接口 ' + name + ' 的' + what + '。如果当前页面还能访问，说明网络正常，请点击「确认生效」。'),
			E('p', {}, '否则请不要操作，' + seconds + ' 秒后将自动回滚到修改前的配置。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: async () => {
					try { await rollback(); ui.hideModal(); this.refresh(); ui.addNotification(null, E('p', {}, '已回滚。'), 'info'); }
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '回滚失败'), 'error'); }
				} }, '立即回滚'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: async () => {
					try { await confirmApply(); ui.hideModal(); ui.addNotification(null, E('p', {}, '已确认，本次变更保留。'), 'success'); this.refresh(); }
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '确认失败'), 'error'); }
				} }, '确认生效')
			])
		]);
	},

	// 桥成员弹框：勾选物理网卡组成成员口。
	// 被其它接口独占的网卡置灰并标注占用者，避免用户提交后才发现被后端拒绝。
	editBridge(iface) {
		const bridge = iface.bridge || {};
		const current = bridge.ports || [];
		const ownBridge = iface.device;
		const boxes = [];

		const rows = (this.state.devices || []).map(d => {
			const isMember = current.includes(d.name);
			const isBridge = /^br-/.test(d.name);
			// usedBy 有两种来源：被某接口直接绑定（值为接口名），
			// 或者本身是某个网桥的成员（值为「网桥名 (桥接)」）。
			const inThisBridge = d.usedBy === ownBridge + ' (桥接)';
			// 只有「已是本桥成员」和「完全空闲的物理网卡」可以勾选；
			// 网桥自身、别处占用的网卡一律置灰，后端也会再校验一次。
			const selectable = !isBridge && (isMember || !d.usedBy);
			const box = E('input', {
				type: 'checkbox', value: d.name,
				checked: isMember || null,
				disabled: selectable ? null : true
			});
			if (selectable) boxes.push(box);
			let note;
			if (isMember) note = '当前成员';
			else if (isBridge) note = d.usedBy ? '网桥（已被 ' + d.usedBy + ' 使用）' : '网桥';
			else if (inThisBridge) note = '本桥成员';
			else if (d.usedBy) note = '已被 ' + d.usedBy + ' 使用';
			else note = '可用';
			return E('label', { class: 'cn-net-port' + (selectable ? '' : ' disabled') }, [
				box, E('span', {}, d.name), E('small', {}, note)
			]);
		});

		ui.showModal('桥成员 · ' + iface.name, [
			E('p', {}, '网桥 ' + ownBridge + ' 当前成员：' + (current.join(' / ') || '无') + '。'),
			E('p', { class: 'cn-help' },
				'勾选的物理网卡将成为该网桥的成员口。只有物理网卡可以加入网桥；' +
				'已被其它接口独占或已属于其它网桥的网卡不可选，至少需要保留一个成员。'),
			E('div', { class: 'cn-net-ports' }, rows),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: async () => {
					const ports = boxes.filter(b => b.checked).map(b => b.value);
					try {
						const checked = await checkBridge(iface.name, ports);
						if (checked.error) throw new Error(checked.error);
						const result = await applyBridge(iface.name, ports);
						if (result.error) throw new Error(result.error);
						ui.hideModal();
						this.state = result.state;
						this.renderInto();
						if (!result.changed) {
							ui.addNotification(null, E('p', {}, '桥成员未发生变化，未做任何改动。'), 'info');
						}
						else if (result.deadline) {
							this.showConfirm(iface.name, result, '桥成员已修改');
						}
						else {
							ui.addNotification(null, E('p', {}, '桥成员已保存并生效：' + ports.join(' / ') + '。'), 'info');
						}
						this.checkPending();
					}
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '保存桥成员失败'), 'error'); }
				} }, '保存')
			])
		]);
	},

	async reconnect(iface) {
		ui.showModal('重新连接 ' + iface.name, [
			E('p', {}, '将重启该接口（例如重新发起 DHCP 请求或 PPPoE 拨号）。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: async () => {
					ui.hideModal();
					try {
						// 重连=原样提交当前配置，后端会 reload 该接口
						await applyIface(iface.name, Object.assign({}, iface, { keepPassword: true }));
						ui.addNotification(null, E('p', {}, '接口已重新连接。'), 'info');
						this.refresh();
					}
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '重连失败'), 'error'); }
				} }, '确认重连')
			])
		]);
	},

	async remove(iface) {
		ui.showModal('删除接口 ' + iface.name, [
			E('p', { class: 'cn-net-warn' }, '删除后该网卡将变为空闲，接口上的配置会被清除，且会从防火墙区域中移除。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-remove', click: async () => {
					ui.hideModal();
					try {
						const result = await removeIface(iface.name);
						if (result.error) throw new Error(result.error);
						this.state = result.state;
						this.renderInto();
						ui.addNotification(null, E('p', {}, '接口 ' + iface.name + ' 已删除，网卡 ' + iface.device + ' 已变为空闲。'), 'info');
					}
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '删除失败'), 'error'); }
				} }, '删除')
			])
		]);
	},

	addInterface() {
		fieldSeq = 0;
		const free = (this.state.devices || []).filter(d => !d.usedBy);
		if (!free.length) { ui.addNotification(null, E('p', {}, '没有空闲网卡可用于新接口。'), 'warning'); return; }

		const inputs = {
			name: E('input', { type: 'text', placeholder: '例如 wan2 / lan2', maxlength: '32' }),
			role: E('select', {}, [
				E('option', { value: 'wan' }, '外网（WAN）'),
				E('option', { value: 'lan' }, '内网（LAN）')
			]),
			device: E('select', {}, free.map(d => E('option', { value: d.name }, d.name))),
			proto: E('select', {}, [ 'dhcp', 'static', 'pppoe' ].map(p =>
				E('option', { value: p, selected: p === 'dhcp' || null }, PROTO_TEXT[p]))),
			address: E('input', { type: 'text', placeholder: '192.168.2.1' }),
			prefix: E('select', {}, [ 24, 23, 22, 16, 28, 30 ].map(p => E('option', { value: String(p), selected: p === 24 || null }, p + ' 位'))),
			gateway: E('input', { type: 'text', placeholder: '留空则不设网关' }),
			dns: E('input', { type: 'text', placeholder: '223.5.5.5 114.114.114.114' }),
			username: E('input', { type: 'text', autocomplete: 'off' }),
			password: E('input', { type: 'password' })
		};

		const groups = {};
		groups.static = E('div', {}, [
			field('IP 地址', inputs.address, '静态地址固定配置在路由器接口上；终端自动获取地址由 DHCP 服务器单独配置。'),
			field('子网掩码', inputs.prefix),
			field('默认网关', inputs.gateway),
			field('DNS 服务器', inputs.dns)
		]);
		groups.pppoe = E('div', {}, [ field('宽带账号', inputs.username), field('宽带密码', inputs.password) ]);
		groups.dhcp = E('div', {}, [ field('附注', E('div', { class: 'cn-help' }, '地址由上级 DHCP 服务器分配，无需填写。')) ]);
		const protoField = E('div');
		const body = E('div', {}, [ groups.dhcp ]);
		const updateAccessMode = () => {
			const isLan = inputs.role.value === 'lan';
			const choices = isLan ? [ 'static' ] : [ 'dhcp', 'static', 'pppoe' ];
			const current = inputs.proto.value;
			const selected = isLan ? 'static' : (choices.includes(current) ? current : 'dhcp');
			inputs.proto.replaceChildren(...choices.map(p => E('option', { value: p, selected: p === selected || null }, PROTO_TEXT[p])));
			inputs.proto.value = selected;
			protoField.replaceChildren(field('接入方式', isLan
				? E('div', { class: 'cn-net-proto-fixed' }, '静态地址')
				: inputs.proto));
			body.replaceChildren(groups[selected] || E('div'));
		};
		inputs.role.addEventListener('change', updateAccessMode);
		inputs.proto.addEventListener('change', updateAccessMode);
		updateAccessMode();

		ui.showModal('新增接口', [
			field('接口名称', inputs.name, '小写字母开头，只能含字母、数字、下划线。用于系统内部标识，建议 wan2 / lan2 这类命名。'),
			field('角色', inputs.role, '决定该接口归入外网还是内网（即防火墙区域）。'),
			field('绑定网卡', inputs.device),
			protoField,
			body,
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: async () => {
					const name = inputs.name.value.trim();
					const config = {
						name, role: inputs.role.value, device: inputs.device.value,
						proto: inputs.role.value === 'lan' ? 'static' : inputs.proto.value
					};
					if (config.proto === 'static') {
						config.address = inputs.address.value.trim();
						config.prefix = +inputs.prefix.value;
						config.gateway = inputs.gateway.value.trim();
						config.dns = inputs.dns.value.trim().split(/\s+/).filter(Boolean);
					}
					else if (config.proto === 'pppoe') {
						config.username = inputs.username.value.trim();
						config.password = inputs.password.value;
					}
					try {
						const result = await createIface(config);
						if (result.error) throw new Error(result.error);
						ui.hideModal();
						this.state = result.state;
						this.renderInto();
						ui.addNotification(null, E('p', {}, '接口 ' + name + ' 已创建并加入' + (config.role === 'wan' ? '外网' : '内网') + '防火墙区域。'), 'info');
					}
					catch (e) { ui.addNotification(null, E('p', {}, e.message || '创建失败'), 'error'); }
				} }, '创建')
			])
		]);
	},

	render(data) {
		if (data && data.error) {
			return E('div', { class: 'cbi-map' }, [ E('h2', {}, '内外网设置'), E('p', { class: 'alert-message error' }, data.error) ]);
		}
		this.state = data && data.state ? data.state : {};
		if (!document.getElementById('cn-net-page-css')) {
			document.head.append(E('link', {
				id: 'cn-net-page-css', rel: 'stylesheet', href: '/luci-static/resources/console/net-page.css'
			}));
		}
		this.root = E('div', { class: 'cbi-map cn-net-page' });
		this.renderInto();
		this.checkPending();
		return this.root;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
}));
