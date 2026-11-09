// SPDX-License-Identifier: Apache-2.0
// Loads the production LuCI modules against local, explicitly labelled fixtures.
(async function() {
	const baseclass = { extend: object => object };
	let index = 360, scenario = 'normal', current;
	const fixtureTime = Date.now() / 1000;
	function E(tag, attrs, children) {
		if (attrs === undefined || attrs === null) attrs = {};
		else if (typeof attrs !== 'object' || Array.isArray(attrs) || attrs.nodeType) { children = attrs; attrs = {}; }
		const node = document.createElement(tag);
		Object.entries(attrs).forEach(([ name, value ]) => {
			if (value === undefined || value === null || value === false) return;
			if (typeof value === 'function') node.addEventListener(name, value);
			else if (value === true) node.setAttribute(name, '');
			else node.setAttribute(name, value);
		});
		function append(child) {
			if (Array.isArray(child)) child.forEach(append);
			else if (child !== null && child !== undefined && child !== false) node.append(child.nodeType ? child : document.createTextNode(String(child)));
		}
		append(children);
		return node;
	}
	const L = {
		url: (...parts) => '/cgi-bin/luci/' + parts.join('/'), resource: path => '/resources/' + path,
		resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback)
	};
	async function load(path, imports) {
		const response = await fetch('/resources/' + path);
		if (!response.ok) throw new Error('Cannot load ' + path);
		return Function(...Object.keys(imports), await response.text())(...Object.values(imports));
	}
	function nextFixture() {
		current = ConsoleFixtures.snapshot(index, fixtureTime + (index - 360) * 5); index++;
		if (scenario === 'offline') current.interfaces.forEach(iface => { if (/^wan/.test(iface.interface)) { iface.up = false; iface['ipv4-address'] = []; iface['ipv6-address'] = []; } });
		if (scenario === 'no-wifi') current.wireless = {};
		if (scenario === 'no-accounting') current.accounting = '0';
		if (scenario === 'xss') current.board.hostname = '<img src=x onerror="window.injected=true">';
		return current;
	}
	const rpc = { declare: spec => async (...args) => {
		if (spec.method === 'board') nextFixture();
		if (scenario === 'rpc-error' && [ 'info', 'dump', 'getNetworkDevices' ].includes(spec.method)) throw new Error('Simulated RPC failure');
		switch (spec.method) {
		case 'board': return current.board;
		case 'info': return current.info;
		case 'dump': return { interface: current.interfaces };
		case 'getNetworkDevices': return current.devices;
		case 'getWirelessDevices': return scenario === 'no-wifi' || scenario === 'wifi-detection-error' ? 4 : scenario === 'wifi-rpc-error' ? 7 : current.wireless;
		case 'get': return scenario === 'wifi-config-error' ? 6 : 4;
		case 'devices': if (scenario === 'wifi-detection-error') throw new Error('Device detection failed'); return { devices: [] };
		case 'getDHCPLeases': return current.leases;
		case 'getHostHints': return current.hints;
		case 'getConntrackList': return { result: current.connections };
		case 'assoclist': return { results: current.associations[args[0]] || [] };
		case 'history': return { samples: [], seconds: args[0] || 300, interval: 5, last_sample: Date.now() / 1000, persistent: true };
		default: throw new Error('Unmocked method ' + spec.method);
		}
	} };
	const fs = {
		list: async path => path === '/sys/class/thermal' ? [ { name: 'thermal_zone0' } ] : [],
		trimmed: async path => {
			if (path.endsWith('/type')) return 'x86_pkg_temp';
			if (path.endsWith('/temp')) return current.temperatures[0];
			if (path === '/proc/stat') return current.cpu;
			if (path.endsWith('nf_conntrack_count')) return current.connectionCount;
			if (path.endsWith('nf_conntrack_acct')) return current.accounting;
			throw new Error('Unmocked file ' + path);
		}
	};
	const uci = {
		load: async name => { if (name === 'wireless' && [ 'no-wifi', 'wifi-config-error', 'wifi-detection-error' ].includes(scenario)) throw new Error('Wireless configuration unavailable'); },
		unload: () => {},
		sections: (config, type) => {
			const fixture = current || ConsoleFixtures.snapshot(index);
			if (config === 'firewall') return fixture.zones;
			if (config === 'dhcp') return type === 'host' ? fixture.staticLeases : fixture.dhcp;
			if (config === 'wireless') return scenario === 'no-wifi' ? [] : [ { '.name': 'default_radio0', device: 'radio0', mode: 'ap' }, { '.name': 'default_radio1', device: 'radio1', mode: 'ap', disabled: '1' } ];
			return [];
		}
	};
	const timers = new Map();
	const poll = { add: (fn, seconds) => timers.set(fn, setInterval(() => Promise.resolve(fn()).catch(console.error), seconds * 1000)), remove: fn => { clearInterval(timers.get(fn)); timers.delete(fn); } };
	const ui = { menu: {
		load: async () => ({ children: { admin: { children: {
			console: { title: '系统概况' },
			status: { title: '状态', children: { realtime: { title: '实时监控', children: { bandwidth: { title: '带宽' }, connections: { title: '连接数' } } }, logs: { title: '系统日志', children: { syslog: { title: '系统日志' }, dmesg: { title: '内核日志' } } } } },
			network: { title: '网络', children: { network: { title: '接口' }, dhcp: { title: 'DHCP' }, dns: { title: 'DNS' }, routes: { title: '路由' }, firewall: { title: '防火墙', children: { forwards: { title: '端口转发' }, rules: { title: '通信规则' } } } } },
			system: { title: '系统', children: { system: { title: '系统设置' }, startup: { title: '启动项' }, flash: { title: '备份与升级' }, reboot: { title: '重启' } } }
		} } } }),
		getChildren: node => Object.entries((node && node.children) || {}).map(([ name, value ]) => Object.assign({ name }, value))
	} };
	try {
		const model = await load('console/model.js', { baseclass });
		const dashboard = await load('console/dashboard.js', { baseclass, model, E });
		const view = await load('view/console/overview.js', { view: baseclass, rpc, fs, uci, poll, ui, model, dashboard, L, E, _: value => value });
		const readSnapshot = view.readSnapshot;
		view.readSnapshot = async function() { const data = await readSnapshot.call(this); data.time = current.time; return data; };
		const snapshot = await view.load();
		const now = snapshot.time;
		for (let i = 0; i < 360; i++) model.ingest(view.state, ConsoleFixtures.snapshot(i, now - (360 - i) * 5));
		const element = view.render(snapshot);
		view.options.preview = true;
		element.querySelector('.ow-local-label').replaceWith(E('span', { class: 'ow-preview-badge' }, '示例数据 · 预览'));
		element.querySelector('.ow-page-footer span:last-child').textContent = '界面预览 · 以下为示例数据';
		dashboard.update(view.refs, view.state.latest, view.options);
		document.getElementById('loading').replaceWith(element);
		element.addEventListener('click', event => {
			const link = event.target.closest('a');
			if (link && link.getAttribute('href').startsWith('/cgi-bin/luci/')) {
				event.preventDefault();
				view.refs.error.hidden = false;
				view.refs.error.textContent = '这是本地界面预览；安装到 OpenWrt 后，此链接会打开对应的设备管理页面。';
			}
		});
		window.ConsolePreview = { view, model, dashboard, setScenario: async value => { scenario = value; view.state = model.createState(); await view.loadConfig(); await view.refresh(); } };
	}
	catch (error) { document.getElementById('loading').textContent = error.stack; throw error; }
})();
