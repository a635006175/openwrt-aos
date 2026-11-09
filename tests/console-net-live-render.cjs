// SPDX-License-Identifier: Apache-2.0
// 联合验证：把路由器上 `ubus call console-net state` 的**真实返回**喂给前端渲染桩，
// 逐项确认编辑弹框展示的文字与真实设备事实一致。
// 与 tests/console-net-detail.cjs 的区别：那个用合成样本，这个用真实抓取的数据。
//
// fixture 来源（2026-11-06，设备 192.168.1.1）：
//   ssh root@192.168.1.1 'ubus call console-net state' > tests/fixtures/net-state-live.json
// 重新抓取后如果设备配置变了，下面的 EXPECT 表也要跟着更新。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const SOURCE = path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/view/console/net-server.js');
const REAL_STATE = path.join(root, 'tests/fixtures/net-state-live.json');

if (!fs.existsSync(REAL_STATE)) {
	console.error('缺少 ' + REAL_STATE + '（先运行 ubus call console-net state 抓取）');
	process.exit(1);
}
const raw = JSON.parse(fs.readFileSync(REAL_STATE, 'utf8'));
const state = raw.state || raw;

function E(tag, attrs, children) {
	if (attrs === undefined || attrs === null) { attrs = {}; }
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
	Object.defineProperty(node, 'className', { get() { return node.attrs.class || ''; }, set(v) { node.attrs.class = v; } });
	Object.defineProperty(node, 'isConnected', { get() { return true; } });
	return node;
}
function textOf(node) {
	if (node === null || node === undefined) return '';
	if (typeof node !== 'object') return String(node);
	return node.children.map(textOf).join('');
}
function loadFeedback() {
	const source = fs.readFileSync(path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/console/feedback.js'), 'utf8');
	const sandbox = { baseclass: { extend: obj => obj } };
	sandbox.globalThis = sandbox;
	vm.createContext(sandbox);
	return vm.runInContext('(function(){' + source + '\n})()', sandbox);
}
function loadView() {
	const modals = [];
	const sandbox = {
		E, feedback: loadFeedback(), console,
		document: { hidden: false, getElementById: () => null, head: { append() {} } },
		Date, Math, Number, String, Array, Object, Set, Map, JSON, isNaN, parseInt, parseFloat, Intl,
		L: { url: (...p) => '/cgi-bin/luci/' + p.join('/') },
		rpc: { declare: () => async () => ({ state }) },
		poll: { add() {}, remove() {} },
		ui: { showModal: (title, body) => modals.push({ title, body }), hideModal() {}, addNotification() {}, menu: { load: async () => ({}) } },
		view: { extend: obj => obj }
	};
	sandbox.globalThis = sandbox;
	vm.createContext(sandbox);
	const source = fs.readFileSync(path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/view/console/net-server.js'), 'utf8');
	return { module: vm.runInContext('(function(){' + source + '\n})()', sandbox), modals };
}

let fails = 0, checks = 0;
function check(name, ok, detail) {
	checks++;
	if (!ok) { fails++; console.log('FAIL  ' + name + (detail ? '\n        ' + detail : '')); }
	else console.log('PASS  ' + name);
}

// 真实事实（来自独立 SSH 探测，不是本文件里 state 的值）
const EXPECT = {
	lan:  { ip: '192.168.1.1', mask: '255.255.255.0', prefix: 24, mtu: 1500, dial: '静态地址，无需拨号', defaultRoute: false, ports: [ 'eth0' ] },
	wan:  { ip: '172.16.10.13', mask: '255.255.254.0', prefix: 23, mtu: 1500, dial: '已获取地址', defaultRoute: true, gateway: '172.16.10.1', proc: 'udhcpc', dns: [ '114.114.114.114', '223.5.5.5' ] },
	wan6: { mtu: 1500, dial: '已连接', proc: 'odhcp6c', defaultRoute: false },
	lan2: { ip: '192.168.2.1', mask: '255.255.255.0', prefix: 24, mtu: 1500, dial: '静态地址，无需拨号', defaultRoute: false }
};

for (const iface of state.interfaces) {
	const expect = EXPECT[iface.name];
	if (!expect) continue;
	console.log('\n== 真实数据 · ' + iface.name + ' ==');
	const { module: view, modals } = loadView();
	view.state = state;
	view.root = { replaceChildren() {}, append() {}, children: [] };
	view.edit(iface);
	check(iface.name + ' 打开编辑弹框', modals.length === 1);
	const rendered = textOf({ children: modals[0].body });

	check(iface.name + ' 有「当前连接信息」区块', rendered.includes('当前连接信息'));
	if (expect.ip) check(iface.name + ' 展示真实 IP ' + expect.ip, rendered.includes(expect.ip));
	if (expect.mask) check(iface.name + ' 展示掩码 ' + expect.mask, rendered.includes(expect.mask));
	if (expect.prefix) check(iface.name + ' 展示前缀 /' + expect.prefix, rendered.includes('/' + expect.prefix));
	check(iface.name + ' 展示真实 MTU ' + expect.mtu, rendered.includes(String(expect.mtu)));
	check(iface.name + ' 展示拨号状态「' + expect.dial + '」', rendered.includes(expect.dial));
	if (expect.gateway) check(iface.name + ' 展示网关 ' + expect.gateway, rendered.includes(expect.gateway));
	if (expect.proc) check(iface.name + ' 展示协议进程 ' + expect.proc, rendered.includes(expect.proc));
	for (const dns of expect.dns || []) check(iface.name + ' 展示 DNS ' + dns, rendered.includes(dns));
	check(iface.name + ' 默认路由文案正确', expect.defaultRoute
		? rendered.includes('是（当前系统默认路由）')
		: rendered.includes('否（默认路由由 ' + state.defaultRoute.interface + ' 承担）'));
	for (const port of expect.ports || []) check(iface.name + ' 展示桥成员 ' + port, rendered.includes(port));

	// 禁词：真实数据里 speed/duplex 都是 null，正确降级后不应出现 null 字样
	const forbidden = [ 'undefined', 'NaN', 'null', '[object Object]' ].filter(bad => rendered.includes(bad));
	check(iface.name + ' 渲染无 undefined/NaN/null', forbidden.length === 0, '出现: ' + forbidden.join(', '));

	// 接口行：默认徽标只应出现在承担默认路由的接口
	const rowText = textOf(view.row(iface));
	check(iface.name + ' 接口行状态文案正确', rowText.includes(expect.dial), rowText);
	check(iface.name + ' 接口行「默认」徽标正确', rowText.includes('默认') === expect.defaultRoute, rowText);
}

console.log('\n断言总数 ' + checks + '，失败 ' + fails);
if (fails) process.exitCode = 1;
else console.log('通过：真实设备数据在编辑弹框中逐项正确展示。');
