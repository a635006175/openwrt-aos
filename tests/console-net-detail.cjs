// SPDX-License-Identifier: Apache-2.0
// 内外网设置接口编辑弹框：用 LuCI 运行时桩把 net-server.js 真实渲染一遍，
// 验证「当前连接信息」区块确实展示了 MTU / IP / 掩码 / 网关 / 默认路由 / DNS / 拨号状态。
// 这个测试只读源码 + 纯函数渲染，不需要路由器、不需要浏览器。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const SOURCE = path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/view/console/net-server.js');

// ---- 最小 DOM 桩：足够让 net-server.js 的 E() 树构建起来 ----
function makeE() {
	function E(tag, attrs, children) {
		if (attrs === undefined || attrs === null) { attrs = {}; children = undefined; }
		else if (typeof attrs !== 'object' || Array.isArray(attrs)) { children = attrs; attrs = {}; }
		const node = { tag, attrs: attrs || {}, children: [] };
		function push(child) {
			if (child === null || child === undefined || child === false) return;
			if (Array.isArray(child)) return child.forEach(push);
			if (typeof child === 'object' && child.tag) return node.children.push(child);
			node.children.push(String(child));
		}
		if (children !== undefined) push(children);
		node.replaceChildren = (...next) => { node.children = []; next.forEach(push); };
		node.append = (...next) => next.forEach(push);
		node.setAttribute = (key, value) => { node.attrs[key] = value; };
		node.getAttribute = key => (key in node.attrs ? node.attrs[key] : null);
		node.addEventListener = (name, fn) => { (node.attrs['on' + name] = node.attrs['on' + name] || []).push(fn); };
		Object.defineProperty(node, 'className', {
			get() { return node.attrs.class || ''; }, set(v) { node.attrs.class = v; }
		});
		Object.defineProperty(node, 'isConnected', { get() { return true; } });
		return node;
	}
	return E;
}

function textOf(node) {
	if (node === null || node === undefined) return '';
	if (typeof node !== 'object') return String(node);
	return node.children.map(textOf).join('');
}

// 收集所有节点的 attrs.class，用于断言区块样式挂载成功
function collectClasses(node, bag) {
	if (!node || typeof node !== 'object') return bag;
	if (node.attrs && node.attrs.class) bag.add(String(node.attrs.class));
	(node.children || []).forEach(child => collectClasses(child, bag));
	return bag;
}

// ---- 真实设备样本（2026-11-06 从 192.168.1.1 实测）----
const SAMPLE = {
	interfaces: [
		{
			name: 'lan', device: 'br-lan', proto: 'static', role: 'lan',
			address: '192.168.1.1', prefix: 24, netmask: '255.255.255.0',
			gateway: '', dns: [], mtuOption: '',
			bridge: { name: 'br-lan', ports: [ 'eth0' ] },
			link: { device: 'br-lan', mtu: 1500, carrier: true, up: true, macaddr: 'aa:bb:cc:dd:ee:01', speed: null, duplex: null, type: 'bridge' },
			runtime: {
				up: true, pending: false, uptime: 50960, l3device: 'br-lan',
				addresses: [ { address: '192.168.1.1', mask: 24, netmask: '255.255.255.0' } ],
				ipv6: [], gateway: null, dns: [], defaultRoute: false,
				dialing: false, protoProcess: null, dialState: 'static', dialText: '静态地址，无需拨号'
			}
		},
		{
			name: 'wan', device: 'eth1', proto: 'dhcp', role: 'wan', mtuOption: '',
			link: { device: 'eth1', mtu: 1500, carrier: true, up: true, macaddr: 'aa:bb:cc:dd:ee:02', speed: null, duplex: null, type: 'ethernet' },
			runtime: {
				up: true, pending: false, uptime: 50960, l3device: 'eth1',
				addresses: [ { address: '172.16.10.13', mask: 23, netmask: '255.255.254.0' } ],
				ipv6: [], gateway: '172.16.10.1',
				dns: [ '114.114.114.114', '223.5.5.5' ], defaultRoute: true,
				dialing: false, protoProcess: 'udhcpc', dialState: 'connected', dialText: '已获取地址'
			}
		},
		{
			name: 'wan6', device: 'eth1', proto: 'dhcpv6', role: 'wan', mtuOption: '',
			link: { device: 'eth1', mtu: 1500, carrier: true, up: true, macaddr: 'aa:bb:cc:dd:ee:02', speed: null, duplex: null, type: 'ethernet' },
			runtime: {
				up: true, pending: false, uptime: 50956, l3device: 'eth1', addresses: [],
				ipv6: [ { address: 'fd00:1234:5678:0:a8bb:ccff:fedd:ee02', mask: 64 } ],
				gateway: null, dns: [], defaultRoute: false,
				dialing: false, protoProcess: 'odhcp6c', dialState: 'connected', dialText: '已连接'
			}
		},
		{
			name: 'lan2', device: 'eth2', proto: 'static', role: 'lan',
			address: '192.168.2.1', prefix: 24, netmask: '255.255.255.0',
			gateway: '', dns: [], mtuOption: '',
			link: { device: 'eth2', mtu: 1500, carrier: true, up: true, macaddr: '02:00:00:00:00:02', speed: null, duplex: null, type: 'ethernet' },
			runtime: {
				up: true, pending: false, uptime: 50960, l3device: 'eth2',
				addresses: [ { address: '192.168.2.1', mask: 24, netmask: '255.255.255.0' } ],
				ipv6: [], gateway: null, dns: [], defaultRoute: false,
				dialing: false, protoProcess: null, dialState: 'static', dialText: '静态地址，无需拨号'
			}
		}
	],
	devices: [
		{ name: 'br-lan', usedBy: 'lan' }, { name: 'eth0', usedBy: 'br-lan (桥接)' },
		{ name: 'eth1', usedBy: 'wan' }, { name: 'eth2', usedBy: 'lan2' }
	],
	defaultRoute: { interface: 'wan', device: 'eth1', gateway: '172.16.10.1' },
	residentDns: { wan: [ '114.114.114.114', '223.5.5.5' ] },
	pending: null
};

// 全部字段缺失的极端场景：不允许出现 undefined / NaN / null
const EMPTY = {
	interfaces: [ { name: 'ghost', device: 'eth9', proto: 'static', role: 'wan' } ],
	devices: [ { name: 'eth9', usedBy: 'ghost' } ],
	pending: null
};

// feedback.decorate 只是给 submit/save/apply/... 套一层「处理中」状态与按钮禁用。
// 这里原样加载真实实现，避免测试替身掩盖真实装饰行为。
function loadFeedback() {
	const source = fs.readFileSync(
		path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/console/feedback.js'), 'utf8');
	const sandbox = { baseclass: { extend: obj => obj } };
	sandbox.globalThis = sandbox;
	vm.createContext(sandbox);
	return vm.runInContext('(function(){' + source + '\n})()', sandbox);
}

function loadView(state) {
	const modals = [];
	const sandbox = {
		E: makeE(),
		feedback: loadFeedback(),
		console,
		document: { hidden: false, getElementById: () => null, head: { append() {} } },
		Date, Math, Number, String, Array, Object, Set, Map, JSON, isNaN, parseInt, parseFloat, Intl,
		L: { url: (...parts) => '/cgi-bin/luci/' + parts.join('/') },
		rpc: { declare: () => async () => ({ state }) },
		poll: { add() {}, remove() {} },
		ui: {
			showModal(title, body) { modals.push({ title, body }); },
			hideModal() {}, addNotification() {},
			menu: { load: async () => ({}) }
		},
		view: { extend: obj => obj }
	};
	sandbox.globalThis = sandbox;
	vm.createContext(sandbox);
	const source = fs.readFileSync(SOURCE, 'utf8');
	const factory = vm.runInContext('(function(){' + source + '\n})()', sandbox);
	return { view: factory, modals };
}

function openEdit(state, ifaceName) {
	const { view, modals } = loadView(state);
	view.state = state;
	view.root = { replaceChildren() {}, append() {}, children: [] };
	const target = state.interfaces.find(iface => iface.name === ifaceName);
	if (!target) throw new Error('sample 缺少接口 ' + ifaceName);
	view.edit(target);
	if (!modals.length) throw new Error('edit() 没有打开任何弹框');
	return { text: textOf({ children: modals[0].body }), title: modals[0].title, view, modals };
}

// ---------------- 断言框架 ----------------
let failures = 0, checks = 0;
function check(name, ok, detail) {
	checks++;
	if (!ok) { failures++; console.log('FAIL  ' + name + (detail ? '\n        ' + detail : '')); }
	else console.log('PASS  ' + name);
}
function mustContain(rendered, needle, label) {
	check(label + '（含「' + needle + '」）', rendered.includes(needle), '实际渲染片段: ' + rendered.slice(0, 400));
}
function mustNotContainForbidden(rendered, label) {
	const hits = [ 'undefined', 'NaN', 'null', '[object Object]' ].filter(bad => rendered.includes(bad));
	check(label + '：无 undefined/NaN/null', hits.length === 0, '出现禁词: ' + hits.join(', '));
}

// ---------------- 用例 1：WAN（DHCP，承担默认路由）----------------
console.log('\n== 用例 1：编辑 wan（DHCP 客户端，当前默认路由）==');
{
	const { text, title } = openEdit(SAMPLE, 'wan');
	console.log('标题: ' + title);
	check('弹框标题包含接口名', title.includes('wan'));
	mustContain(text, '当前连接信息', '存在「当前连接信息」只读区块');
	mustContain(text, 'eth1', '展示绑定网卡');
	mustContain(text, 'aa:bb:cc:dd:ee:02', '展示 MAC 地址');
	mustContain(text, '1500', '展示 MTU 生效值');
	mustContain(text, '172.16.10.13', '展示运行时 IP');
	mustContain(text, '255.255.254.0', '展示点分十进制子网掩码');
	mustContain(text, '/23', '展示前缀长度');
	mustContain(text, '172.16.10.1', '展示默认网关');
	mustContain(text, '是（当前系统默认路由）', '标注该接口承担默认路由');
	mustContain(text, '114.114.114.114', '展示 DNS 之一');
	mustContain(text, '223.5.5.5', '展示 DNS 之二');
	mustContain(text, '已获取地址', '展示拨号状态文案');
	mustContain(text, 'udhcpc', '展示协议进程名');
	mustNotContainForbidden(text, 'WAN 弹框');
}

// ---------------- 用例 2：LAN（静态，非默认路由，桥）----------------
console.log('\n== 用例 2：编辑 lan（静态地址，网桥，默认路由由 wan 承担）==');
{
	const { text } = openEdit(SAMPLE, 'lan');
	mustContain(text, '255.255.255.0', '展示 /24 掩码');
	mustContain(text, '192.168.1.1', '展示静态 IP');
	mustContain(text, '静态地址，无需拨号', '静态接口的拨号状态文案');
	mustContain(text, '否（默认路由由 wan 承担）', '正确说明默认路由归属');
	mustContain(text, 'eth0', '展示桥成员 eth0');
	mustNotContainForbidden(text, 'LAN 弹框');
}

// ---------------- 用例 3：wan6 / lan2 不崩溃 ----------------
console.log('\n== 用例 3：wan6 与 lan2 渲染不崩溃 ==');
for (const name of [ 'wan6', 'lan2' ]) {
	const { text } = openEdit(SAMPLE, name);
	check(name + ' 渲染出非空信息', text.length > 40, '长度 ' + text.length);
	mustNotContainForbidden(text, name + ' 弹框');
}

// ---------------- 用例 4：极端缺数据，必须优雅降级 ----------------
console.log('\n== 用例 4：接口数据全部缺失时优雅降级 ==');
{
	const { text } = openEdit(EMPTY, 'ghost');
	mustContain(text, '—', '缺失字段降级为 —');
	mustNotContainForbidden(text, '缺数据弹框');
}

// ---------------- 用例 5：MTU 输入框 ----------------
console.log('\n== 用例 5：MTU 输入框存在且回填配置值 ==');
{
	const withMtu = JSON.parse(JSON.stringify(SAMPLE));
	withMtu.interfaces[1].mtuOption = '1480';
	const { text } = openEdit(withMtu, 'wan');
	mustContain(text, '1480', 'MTU 输入框回填 uci 配置值');
	mustContain(text, 'MTU', '存在 MTU 字段标签');
}

// ---------------- 用例 6：接口行徽标与状态文案 ----------------
console.log('\n== 用例 6：接口行展示拨号文案与「默认」徽标 ==');
{
	const { view } = loadView(SAMPLE);
	view.state = SAMPLE;
	view.root = { replaceChildren() {}, append() {}, children: [] };
	view.renderInto();
	const wan = SAMPLE.interfaces.find(iface => iface.name === 'wan');
	const rowNode = view.row(wan);
	// 行节点必须沿用既有 .cn-net-iface 样式钩子（up/down 状态类允许并存）
	const rowClasses = String(rowNode.attrs.class || '');
	check('仍使用既有 .cn-net-iface 行样式', rowClasses.includes('cn-net-iface'), '实际 class: ' + rowClasses);
	const rowText = textOf(rowNode);
	check('接口行显示拨号状态文案「已获取地址」', rowText.includes('已获取地址'), rowText);
	check('承担默认路由的接口行带「默认」标记', rowText.includes('默认'), rowText);
	const lan = SAMPLE.interfaces.find(iface => iface.name === 'lan');
	const lanRow = textOf(view.row(lan));
	check('非默认路由接口行不误标「默认」', !lanRow.includes('默认'), lanRow);
}

console.log('\n断言总数 ' + checks + '，失败 ' + failures);
if (failures) process.exitCode = 1;
else console.log('通过：编辑弹框展示 MTU / IP / 掩码 / 网关 / 默认网关 / DNS / 拨号状态，且缺失字段安全降级。');
