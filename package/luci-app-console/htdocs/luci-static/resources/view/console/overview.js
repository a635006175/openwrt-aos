// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require fs';
'require uci';
'require poll';
'require ui';
'require console.model as model';
'require console.dashboard as dashboard';

const callBoard = rpc.declare({ object: 'system', method: 'board' });
const callInfo = rpc.declare({ object: 'system', method: 'info' });
const callInterfaces = rpc.declare({ object: 'network.interface', method: 'dump' });
const callDevices = rpc.declare({ object: 'luci-rpc', method: 'getNetworkDevices' });
const callWireless = rpc.declare({ object: 'luci-rpc', method: 'getWirelessDevices' });
const callWirelessConfig = rpc.declare({ object: 'uci', method: 'get', params: [ 'config' ] });
const callWirelessHardware = rpc.declare({ object: 'iwinfo', method: 'devices' });
const callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases' });
const callHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints' });
const callConntrack = rpc.declare({ object: 'console-conntrack', method: 'list', reject: true });
const callLuciConnections = rpc.declare({ object: 'luci', method: 'getConntrackList' });
const callAssociations = rpc.declare({ object: 'iwinfo', method: 'assoclist', params: [ 'device' ] });
const callTrafficHistory = rpc.declare({ object: 'console-traffic', method: 'history', params: [ 'seconds' ], reject: true });
const callProtocol = rpc.declare({ object: 'console-security', method: 'protocol', reject: true });

function objectReply(data) {
	if (!data || typeof data !== 'object' || Array.isArray(data) || data.error) throw new Error('Invalid status reply');
	return data;
}

async function temperaturePaths() {
	const paths = [];
	const thermal = await L.resolveDefault(fs.list('/sys/class/thermal'), []);
	await Promise.all(thermal.filter(entry => /^thermal_zone\d+$/.test(entry.name)).map(async entry => {
		const path = '/sys/class/thermal/' + entry.name;
		const type = await L.resolveDefault(fs.trimmed(path + '/type'), '');
		if (/cpu|x86_pkg|soc_thermal|k10temp|coretemp/i.test(type)) paths.push(path + '/temp');
	}));
	const hwmon = await L.resolveDefault(fs.list('/sys/class/hwmon'), []);
	await Promise.all(hwmon.filter(entry => /^hwmon\d+$/.test(entry.name)).map(async entry => {
		const path = '/sys/class/hwmon/' + entry.name;
		const name = await L.resolveDefault(fs.trimmed(path + '/name'), '');
		if (!/coretemp|k10temp|cpu|zenpower/i.test(name)) return;
		const sensors = await L.resolveDefault(fs.list(path), []);
		paths.push(...sensors.filter(sensor => /^temp\d+_input$/.test(sensor.name)).map(sensor => path + '/' + sensor.name));
	}));
	return paths;
}

return view.extend({
	// 自带解析同时返回原方向与回程方向的字节计数；luci.getConntrackList 只有
	// 原方向 bytes，下载流量会几乎全部漏掉，这里仅在旧版 rpcd/ACL 未就绪时退回。
	async readConnections() {
		try {
			const result = objectReply(await callConntrack());
			if (Array.isArray(result.connections)) return result.connections;
		}
		catch (error) {}
		const fallback = objectReply(await callLuciConnections());
		if (!Array.isArray(fallback.result)) throw new Error('Missing connections');
		return fallback.result;
	},

	async readTrafficHistory() {
		const seconds = this.historySeconds || 300, now = Date.now();
		const cache = this.historyCache;
		if (cache && cache.seconds === seconds && now - cache.time < (seconds > 3600 ? 60000 : 5000)) return cache.data;
		const data = objectReply(await callTrafficHistory(seconds));
		if (!Array.isArray(data.samples)) throw new Error('Missing traffic history');
		this.historyCache = { seconds, time: now, data };
		return data;
	},

	async loadConfig() {
		this.configErrors = [];
		this.wirelessConfigError = false;
		await Promise.all([ 'dhcp', 'firewall', 'wireless' ].map(async name => {
			try { await uci.load(name); }
			catch (error) {
				if (name === 'wireless') this.wirelessConfigError = true;
				else this.configErrors.push(name + ' 配置');
				// UCI caches rejected requests; unload so the next refresh can recover.
				uci.unload(name);
			}
		}));
	},

	async readSnapshot() {
		const errors = (this.configErrors || []).slice();
		async function read(label, callback) {
			try { return await callback(); }
			catch (error) { errors.push(label); return null; }
		}
		const data = await Promise.all([
			read('系统信息', async () => {
				if (!this.boardCache || Date.now() - this.boardCache.time > 300000) this.boardCache = { data: objectReply(await callBoard()), time: Date.now() };
				return this.boardCache.data;
			}),
			read('运行状态', async () => objectReply(await callInfo())),
			read('网络接口', async () => {
				const result = objectReply(await callInterfaces());
				if (!Array.isArray(result.interface)) throw new Error('Missing interfaces');
				return result.interface;
			}),
			read('网卡计数', async () => objectReply(await callDevices())),
			L.resolveDefault(callWireless(), null),
			read('DHCP 租约', async () => objectReply(await callLeases())),
			read('终端信息', async () => objectReply(await callHints())),
			read('连接跟踪', () => this.readConnections()),
			read('CPU 计数', () => fs.trimmed('/proc/stat')),
			read('连接数', () => fs.trimmed('/proc/sys/net/netfilter/nf_conntrack_count')),
			L.resolveDefault(fs.trimmed('/proc/sys/net/netfilter/nf_conntrack_acct'), null),
			Promise.all((this.temperaturePaths || []).map(path => L.resolveDefault(fs.trimmed(path), null))),
			this.wirelessConfigError ? L.resolveDefault(callWirelessConfig('wireless'), null) : null,
			this.wirelessConfigError ? L.resolveDefault(callWirelessHardware(), null) : null,
			read('后台历史速率', () => this.readTrafficHistory()),
			read('协议流量统计', async () => objectReply(await callProtocol()))
		]);
		const rawWireless = data[4], hardware = data[13];
		// A missing configuration and missing netifd object are normal only when
		// iwinfo independently confirms that it detects no wireless devices.
		const noWireless = this.wirelessConfigError && data[12] === 4 && hardware &&
			Array.isArray(hardware.devices) && hardware.devices.length === 0 &&
			(rawWireless === 4 || (rawWireless && typeof rawWireless === 'object' && !Array.isArray(rawWireless) && !Object.keys(rawWireless).length));
		if (this.wirelessConfigError && !noWireless) errors.push('wireless 配置');
		let wireless = null;
		if (noWireless) wireless = {};
		else {
			try { wireless = objectReply(rawWireless); }
			catch (error) { errors.push('无线状态'); }
		}
		const associations = {};
		if (data[14] && (!data[14].last_sample || Date.now() / 1000 - data[14].last_sample > 25)) errors.push('后台速率采集已中断');
		if (wireless) {
			// Disabled APs may be absent from netifd's runtime interface array.
			for (const config of uci.sections('wireless', 'wifi-iface')) {
				if (!config.device || !/^ap(?:_|$)/.test(config.mode || '')) continue;
				const radio = wireless[config.device] || (wireless[config.device] = { up: false, interfaces: [] });
				if (!(radio.interfaces || []).some(iface => iface.section === config['.name'])) {
					radio.interfaces = (radio.interfaces || []).concat({ section: config['.name'], config, ifname: null });
				}
			}
			await Promise.all(Object.values(wireless).flatMap(radio => (radio.interfaces || []).filter(iface => iface.ifname && /^ap(?:_|$)/.test((iface.config || {}).mode || '')).map(async iface => {
				const result = await read('无线终端 ' + iface.ifname, async () => {
					const response = objectReply(await callAssociations(iface.ifname));
					if (!Array.isArray(response.results)) throw new Error('Missing associations');
					return response.results;
				});
				associations[iface.ifname] = result;
			})));
		}
		return {
			time: Date.now() / 1000, board: data[0], info: data[1], interfaces: data[2], devices: data[3], wireless,
			leases: data[5], hints: data[6], connections: data[7], cpu: data[8], connectionCount: data[9], accounting: data[10], temperatures: data[11],
			associations, zones: uci.sections('firewall', 'zone'), dhcp: uci.sections('dhcp', 'dhcp'),
			staticLeases: uci.sections('dhcp', 'host'), configUnavailable: !!this.configErrors.length, trafficHistory: data[14],
			protocol: data[15], errors
		};
	},

	async load() {
		this.state = model.createState();
		// Only prime the counters needed for rates, alongside the other prerequisites.
		// Avoid two complete snapshots and an artificial delay before first paint.
		let counters;
		const baseline = Promise.all([ fs.trimmed('/proc/stat'), callDevices(), callInterfaces(), this.readConnections() ]).then(([cpu, devices, interfaces, connections]) => {
			objectReply(devices); objectReply(interfaces);
			if (!Array.isArray(interfaces.interface) || !Array.isArray(connections)) return;
			counters = { time: Date.now() / 1000, cpu, devices, interfaces: interfaces.interface, connections, wireless: null, configUnavailable: true };
		}).catch(() => {});
		await Promise.all([ this.loadConfig(), temperaturePaths().then(paths => { this.temperaturePaths = paths; }),
			L.resolveDefault(ui.menu.load(), null).then(tree => { this.menuTree = tree; }), baseline ]);
		if (counters) {
			counters.zones = uci.sections('firewall', 'zone');
			model.ingest(this.state, counters);
		}
		return this.readSnapshot();
	},

	async refresh() {
		if (this.busy) { this.refreshQueued = true; return; }
		this.busy = true;
		this.lastRefresh = Date.now();
		try {
			if (this.configErrors.length || this.wirelessConfigError) await this.loadConfig();
			const snapshot = await this.readSnapshot();
			dashboard.update(this.refs, model.ingest(this.state, snapshot), this.options);
			if (this.paused) this.refs.updated.append(' · 已暂停');
		}
		finally {
			this.busy = false;
			if (this.refreshQueued) { this.refreshQueued = false; this.refresh(); }
		}
	},

	render(snapshot) {
		if (!document.getElementById('ow-console-css')) document.head.append(E('link', { id: 'ow-console-css', rel: 'stylesheet', href: L.resource('console/dashboard.css') + '?v=4' }));
		this.options = {
			onHistoryPeriod: seconds => { this.historySeconds = seconds; return this.refresh(); },
			url: (...parts) => L.url('admin', ...parts),
			menu: this.menuTree && this.menuTree.children && this.menuTree.children.admin ? ui.menu.getChildren(this.menuTree.children.admin).filter(node => !!node.title && node.name !== 'console' && node.name !== 'logout').map(node => ({
				name: node.name, title: _(node.title), children: ui.menu.getChildren(node).filter(child => !!child.title).map(child => ({
					name: child.name, title: _(child.title), children: ui.menu.getChildren(child).filter(grandchild => !!grandchild.title).map(grandchild => ({ name: grandchild.name, title: _(grandchild.title) }))
				}))
			})) : null,
			routes: {
				home: L.url('admin', 'console'), system: L.url('admin', 'system', 'system'),
				network: L.url('admin', 'network', 'console-net'), dhcp: L.url('admin', 'network', 'console-dhcp'),
				wireless: L.url('admin', 'network', 'wireless'), firewall: L.url('admin', 'security', 'zones'),
				flow: L.url('admin', 'flow', 'steer', 'load'),
				bandwidth: L.url('admin', 'status', 'realtime', 'bandwidth'), connections: L.url('admin', 'status', 'realtime', 'connections'),
				logs: L.url('admin', 'status', 'logs', 'syslog'), logout: L.url('admin', 'logout')
			},
			onRefresh: () => this.refresh(),
			onPause: button => {
				this.paused = !this.paused;
				button.replaceChildren(dashboard.icon(this.paused ? 'play' : 'pause'), document.createTextNode(this.paused ? '继续刷新' : '暂停刷新'));
				button.setAttribute('aria-pressed', String(this.paused));
				if (this.paused) this.refs.updated.append(' · 已暂停');
				else this.refresh();
			}
		};
		this.refs = dashboard.createShell(this.options);
		dashboard.update(this.refs, model.ingest(this.state, snapshot), this.options);
		this.pollFn = () => {
			// LuCI starts polling synchronously, before render() has been mounted.
			if (!this.refs.root.isConnected) {
				if (this.pollMounted) poll.remove(this.pollFn);
				return;
			}
			this.pollMounted = true;
			// The mount-time refresh below already covered this poll cycle.
			if (this.lastRefresh && Date.now() - this.lastRefresh < 4000) return;
			if (!this.paused && !document.hidden) return this.refresh();
		};
		poll.add(this.pollFn, 5);
		this.refreshAfterMount();
		this.bindResumeEvents();
		return this.refs.root;
	},

	// Polling runs from page initialization, and an entry added later only runs on a
	// tick that is a multiple of its interval, so the first refresh could be almost
	// five seconds after the page opened. Refresh as soon as the view is in the
	// document, then once more a second later so CPU and rate counters span a usable
	// interval instead of a single first sample.
	refreshAfterMount() {
		const deadline = Date.now() + 10000;
		const step = () => {
			if (!this.refs || !this.refs.root || !this.refs.root.isConnected) {
				if (Date.now() < deadline) window.setTimeout(step, 16);
				return;
			}
			if (!this.paused && !document.hidden) this.refresh();
			window.clearTimeout(this.catchupTimer);
			this.catchupTimer = window.setTimeout(() => {
				if (this.refs.root.isConnected && !this.paused && !document.hidden) this.refresh();
			}, 1000);
		};
		step();
	},

	// A page restored from the back/forward cache or a background tab would otherwise
	// keep showing the numbers from before until the next poll tick.
	bindResumeEvents() {
		if (this.resumeBound) return;
		this.resumeBound = true;
		const resume = () => {
			if (!document.hidden && this.refs && this.refs.root.isConnected && !this.paused) this.refresh();
		};
		window.addEventListener('pageshow', event => { if (event.persisted) resume(); });
		document.addEventListener('visibilitychange', resume);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
