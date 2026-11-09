// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';

const PROTOCOLS = [ 'TCP', 'UDP', 'ICMP', '其他' ];
const MAX_GAP = 15;
const MAX_HISTORY = 17281; // One day at a five-second polling interval.

function number(value) {
	return value !== null && value !== undefined && value !== '' && Number.isFinite(Number(value)) ? Number(value) : null;
}

function ipv4(address) {
	const parts = String(address || '').split('.');
	if (parts.length !== 4 || parts.some(part => !/^\d+$/.test(part) || +part > 255)) return null;
	return parts.reduce((n, part) => n * 256 + +part, 0);
}

function ipWords(address) {
	const text = String(address || '').toLowerCase().split('%')[0];
	if (!text.includes(':')) return null;
	let normalized = text;
	if (text.includes('.')) {
		const offset = text.lastIndexOf(':');
		const v4 = ipv4(text.slice(offset + 1));
		if (v4 === null) return null;
		normalized = text.slice(0, offset + 1) + Math.floor(v4 / 65536).toString(16) + ':' + (v4 % 65536).toString(16);
	}
	const halves = normalized.split('::');
	if (halves.length > 2) return null;
	const left = halves[0] ? halves[0].split(':') : [];
	const right = halves[1] ? halves[1].split(':') : [];
	const missing = 8 - left.length - right.length;
	if ((halves.length === 1 && missing !== 0) || missing < (halves.length === 2 ? 1 : 0)) return null;
	const words = left.concat(Array(missing).fill('0'), right);
	if (words.some(word => !/^[0-9a-f]{1,4}$/.test(word))) return null;
	return words.map(word => parseInt(word, 16));
}

// 组播/广播目标（IGMP、mDNS、IPTV 发现等）不是互联网流量；[UNREPLIED] 的组播
// 条目还会长期累积字节数，计入后「其他」占比会一直往上涨。
function isGroupAddress(address) {
	const text = String(address || '');
	if (text.startsWith('ff')) return true;
	const first = +text.split('.')[0];
	return Number.isFinite(first) && first >= 224;
}

// /proc/net/nf_conntrack 把 IPv6 写成 4 位一组的完整形式（fd00:1234:5678:0000:…），
// 而接口、租约和主机名提示用的是压缩形式（fd00:1234:5678::…）。不统一的话
// 同一台 IPv6 终端会被当成两个地址，路由器自己的地址也认不出来。
function formatIPv6(text) {
	const words = ipWords(text);
	if (!words) return text;
	const hex = word => word.toString(16);
	let bestStart = -1, bestLength = 0;
	for (let i = 0; i < words.length;) {
		if (words[i] !== 0) { i++; continue; }
		let j = i;
		while (j < words.length && words[j] === 0) j++;
		if (j - i > bestLength) { bestStart = i; bestLength = j - i; }
		i = j;
	}
	if (bestLength < 2) return words.map(hex).join(':');
	return words.slice(0, bestStart).map(hex).join(':') + '::' + words.slice(bestStart + bestLength).map(hex).join(':');
}

function canonicalAddress(address) {
	const text = String(address || '').split('%')[0];
	return text.includes(':') ? formatIPv6(text) : text;
}

function inSubnet(address, subnet) {
	const mask = number(subnet.mask);
	const ip = ipv4(address), base = ipv4(subnet.address);
	if (ip !== null && base !== null && mask !== null && mask >= 0 && mask <= 32) {
		const size = Math.pow(2, 32 - mask);
		return Math.floor(ip / size) === Math.floor(base / size);
	}
	const a = ipWords(address), b = ipWords(subnet.address);
	if (!a || !b || mask === null || mask < 0 || mask > 128) return false;
	for (let i = 0, bits = mask; bits > 0; i++, bits -= 16) {
		const divisor = Math.pow(2, 16 - Math.min(16, bits));
		if (Math.floor(a[i] / divisor) !== Math.floor(b[i] / divisor)) return false;
	}
	return true;
}

function cpuCounters(text) {
	const line = String(text || '').match(/^cpu\s+(.+)$/m);
	if (!line) return null;
	const values = line[1].trim().split(/\s+/).slice(0, 8).map(Number);
	if (values.length < 4 || values.some(value => !Number.isFinite(value) || value < 0)) return null;
	return { total: values.reduce((sum, n) => sum + n, 0), idle: values[3] + (values[4] || 0) };
}

function classifyInterfaces(interfaces, zones) {
	const zoneNetworks = name => (zones || []).filter(zone => zone.name === name).flatMap(zone =>
		Array.isArray(zone.network) ? zone.network : String(zone.network || '').split(/\s+/));
	const wan = new Set(zoneNetworks('wan')), lan = new Set(zoneNetworks('lan'));
	return (interfaces || []).filter(iface => iface.interface !== 'loopback').map(iface => {
		const role = wan.has(iface.interface) ? 'WAN' : lan.has(iface.interface) ? 'LAN' :
			!wan.size && (/^wan\d*6?$/.test(iface.interface) || (iface.route || []).some(route =>
				(route.target === '0.0.0.0' || route.target === '::') && +route.mask === 0)) ? 'WAN' :
			!lan.size && /^lan\d*$/.test(iface.interface) ? 'LAN' : '其他';
		return Object.assign({}, iface, { role, deviceName: iface.l3_device || iface.device || iface.interface });
	});
}

// A configured address pool is not the same thing as a pool that is actually serving.
// Before writing `dhcp-range` for an interface, /etc/init.d/dnsmasq runs dhcp_check(),
// a one-shot `udhcpc -n -q -s /bin/true -t 1` probe. When that probe receives an OFFER
// it records the decision by writing 1 to /tmp/run/dnsmasq.<instance>.<ifname>.dhcp and
// then refuses to serve the pool on that interface ("found already running DHCP-server,
// use 'option force 1' to override"). Generated configs therefore contain no dhcp-range,
// /tmp/dhcp.leases stays empty, and yet uci keeps reporting dhcp.lan start/limit, so the
// range arithmetic below would advertise a full, healthy pool that never handed out an
// address. The one liveness fact this page can read with the permissions it already has
// is an actual dhcpv4 lease: luci-rpc getDHCPLeases is already fetched, and dnsmasq only
// writes a lease after it really served a client, so it is evidence rather than a guess
// about the configuration. Absence of leases is ambiguous on the very first sample (an
// idle pool is normal), so the first sample reports 'unknown' and a later sample that
// still shows no lease reports 'inactive'. Callers that can state the fact directly may
// pass snapshot.dhcpEnabled (true/false) and it takes precedence; anything unreadable
// degrades to 'unavailable' so the card can say the data is missing rather than guess.
function dhcpAvailability(snapshot, interfaces, state) {
	if (!snapshot.dhcp || !snapshot.leases || snapshot.configUnavailable) return { remaining: null, state: 'unavailable' };
	let count = 0, pools = 0, serving = 0;
	const leases = snapshot.leases.dhcp_leases || [];
	const occupied = new Set(leases.filter(lease => lease.expires !== 0).map(lease => lease.ipaddr));
	(snapshot.staticLeases || []).forEach(lease => { if (lease.ip) occupied.add(lease.ip); });
	const ranges = new Set();
	for (const pool of snapshot.dhcp) {
		if (String(pool.ignore) === '1' || String(pool.dynamicdhcp) === '0') continue;
		const iface = interfaces.find(iface => iface.interface === pool.interface && iface.role === 'LAN');
		const address = iface && (iface['ipv4-address'] || [])[0];
		const ip = address && ipv4(address.address), mask = address && number(address.mask);
		if (ip === null || ip === undefined || mask === null || mask > 30 || mask < 1) continue;
		pools++;
		if (String(pool.dhcpv4) !== 'disabled') serving++;
		const size = Math.pow(2, 32 - mask), base = Math.floor(ip / size) * size;
		const start = Math.max(1, number(pool.start) === null ? 100 : +pool.start);
		const limit = Math.max(0, number(pool.limit) === null ? 150 : +pool.limit);
		const end = Math.min(size - 2, start + limit - 1);
		const key = base + ':' + start + ':' + end;
		if (ranges.has(key)) continue;
		ranges.add(key);
		const used = new Set([ ip ]);
		for (const address of occupied) {
			const value = ipv4(address);
			if (value !== null) used.add(value);
		}
		const taken = Array.from(used).filter(value => value >= base + start && value <= base + end).length;
		count += Math.max(0, end - start + 1 - taken);
	}
	if (!pools) return { remaining: null, state: 'unavailable' };
	if (snapshot.dhcpEnabled === false) return { remaining: null, state: 'inactive' };
	if (snapshot.dhcpEnabled === true) return { remaining: count, state: 'active' };
	// A lease already on disk proves the pool served at least one client since boot.
	// Remember it, so a pool whose single lease expires does not flip back to 未生效.
	if (leases.some(lease => lease && lease.expires !== 0)) {
		if (state) state.leaseSeen = true;
		return { remaining: count, state: 'active' };
	}
	if (state && state.leaseSeen) return { remaining: count, state: 'active' };
	if (!serving) return { remaining: null, state: 'inactive' };
	return { remaining: null, state: state && state.time !== null ? 'inactive' : 'unknown' };
}

function wirelessSummary(snapshot) {
	if (snapshot.wireless === null) return { available: false, apUp: null, apDown: null, bands: [ null, null, null ], macs: new Map() };
	const result = { available: true, apUp: 0, apDown: 0, bands: [ 0, 0, 0 ], macs: new Map(), radios: Object.keys(snapshot.wireless || {}).length };
	for (const radio of Object.values(snapshot.wireless || {})) {
		for (const iface of radio.interfaces || []) {
			if (!/^ap(?:_|$)/.test(iface.config && iface.config.mode || '')) continue;
			if (radio.up && !radio.disabled && iface.ifname && ![ true, 1, '1' ].includes(iface.config.disabled)) result.apUp++;
			else result.apDown++;
			const frequency = number((iface.iwinfo || {}).frequency);
			const band = frequency === null ? null : frequency < 3000 ? 0 : frequency < 5925 ? 1 : 2;
			const stations = (snapshot.associations || {})[iface.ifname];
			if (stations === null) {
				if (band !== null) result.bands[band] = null;
				result.associationUnavailable = true;
			}
			for (const station of stations || []) {
				if (!station.mac) continue;
				const mac = station.mac.toLowerCase();
				if (!result.macs.has(mac) && band !== null && result.bands[band] !== null) result.bands[band]++;
				result.macs.set(mac, band);
			}
		}
	}
	return result;
}

function buildHints(snapshot) {
	const byIP = new Map();
	for (const [ mac, hint ] of Object.entries(snapshot.hints || {})) {
		for (const ip of (hint.ipaddrs || []).concat(hint.ip6addrs || [])) byIP.set(canonicalAddress(ip), { mac: mac.toLowerCase(), name: hint.name || '', ip: canonicalAddress(ip) });
	}
	for (const lease of ((snapshot.leases || {}).dhcp_leases || []).concat((snapshot.leases || {}).dhcp6_leases || [])) {
		const ip = lease.ipaddr || lease.ip6addr;
		if (ip && lease.macaddr) byIP.set(canonicalAddress(ip), { mac: lease.macaddr.toLowerCase(), name: lease.hostname || '', ip: canonicalAddress(ip) });
	}
	return byIP;
}

function updateConnections(state, snapshot, interfaces, wifi, gap) {
	if (!Array.isArray(snapshot.connections)) {
		state.connectionBaseline = false;
		state.connectionCounters = new Map();
		return { protocols: null, clients: null, wired: null, wireless: null };
	}
	const own = new Set(interfaces.flatMap(iface => (iface['ipv4-address'] || []).concat(iface['ipv6-address'] || []).map(address => canonicalAddress(address.address))));
	const subnets = interfaces.filter(iface => iface.role === 'LAN').flatMap(iface =>
		(iface['ipv4-address'] || []).concat(iface['ipv6-address'] || [], (iface['ipv6-prefix-assignment'] || []).map(prefix => ({ address: prefix.address, mask: prefix.mask }))));
	const hints = buildHints(snapshot), protocols = PROTOCOLS.map(() => 0), counters = new Map();
	const canMeasure = state.connectionBaseline && Number(snapshot.accounting) === 1 && gap > 0 && gap <= MAX_GAP;
	for (const conn of snapshot.connections) {
		const src = canonicalAddress(conn.src), dst = canonicalAddress(conn.dst);
		if (own.has(src) || !subnets.some(subnet => inSubnet(src, subnet))) continue;
		if (isGroupAddress(dst)) continue;
		const key = [ conn.layer3, conn.layer4, src, conn.sport, dst, conn.dport, conn.zone || '' ].join('|');
		// conntrack 的 bytes 只统计原方向，回程方向的下载量在 replyBytes 里，
		// 只算原方向会让下载几乎全部漏掉、协议占比严重失真。
		const current = {
			bytes: (number(conn.bytes) || 0) + (number(conn.replyBytes) || 0),
			packets: (number(conn.packets) || 0) + (number(conn.replyPackets) || 0)
		};
		counters.set(key, current);
		if (!canMeasure) continue;
		const previous = state.connectionCounters.get(key);
		const bytes = Math.max(0, current.bytes - (previous ? previous.bytes : 0));
		const packets = Math.max(0, current.packets - (previous ? previous.packets : 0));
		if (bytes || packets) state.activeIPs.set(src, snapshot.time);
		const proto = String(conn.layer4 || '').toLowerCase();
		protocols[proto === 'tcp' ? 0 : proto === 'udp' ? 1 : proto.startsWith('icmp') || proto === 'ipv6-icmp' ? 2 : 3] += bytes;
	}
	state.connectionCounters = counters;
	state.connectionBaseline = true;
	for (const [ ip, time ] of state.activeIPs) if (snapshot.time - time > 120 || snapshot.time < time) state.activeIPs.delete(ip);
	const clients = new Map();
	// A router without wireless radios can only serve LAN clients over Ethernet,
	// so an unresolved MAC there is still known to be wired. Unknown is reserved
	// for hardware that does have radios but whose association list is missing.
	const noRadio = wifi.available && !wifi.radios;
	for (const [ ip, time ] of state.activeIPs) {
		const hint = hints.get(ip) || { name: '', mac: '', ip };
		const type = noRadio ? '有线'
			: (!wifi.available || wifi.associationUnavailable || !hint.mac) ? '未知'
			: wifi.macs.has(hint.mac) ? '无线' : '有线';
		const id = hint.mac || ip;
		if (!clients.has(id)) clients.set(id, { name: hint.name, mac: hint.mac, ips: [], type, lastSeen: time });
		clients.get(id).ips.push(ip);
		clients.get(id).lastSeen = Math.max(clients.get(id).lastSeen, time);
	}
	const rows = Array.from(clients.values());
	return {
		protocols: canMeasure && Number(snapshot.accounting) === 1 ? protocols : null,
		clients: canMeasure ? rows : null,
		wired: canMeasure ? rows.filter(row => row.type === '有线').length : null,
		wireless: canMeasure ? rows.filter(row => row.type === '无线').length : null
	};
}

function ingest(state, snapshot) {
	const time = snapshot.time, gap = state.time === null ? 0 : time - state.time;
	if (gap < 0 || state.uptime !== null && snapshot.info && snapshot.info.uptime < state.uptime) {
		Object.assign(state, createState());
	}
	const cpu = cpuCounters(snapshot.cpu), previousCPU = state.cpu;
	let cpuUsage = null;
	if (cpu && previousCPU && cpu.total > previousCPU.total && gap > 0 && gap <= MAX_GAP && cpu.idle >= previousCPU.idle)
		cpuUsage = Math.max(0, Math.min(100, (1 - (cpu.idle - previousCPU.idle) / (cpu.total - previousCPU.total)) * 100));
	state.cpu = cpu;
	const interfaces = classifyInterfaces(snapshot.interfaces, snapshot.zones);
	const wans = interfaces.filter(iface => iface.role === 'WAN');
	const counters = new Map(), rates = {};
	let upload = 0, download = 0, validRates = snapshot.interfaces !== null && snapshot.devices !== null;
	for (const iface of wans.slice().sort((a, b) => Number(b.up) - Number(a.up))) {
		const device = iface.deviceName;
		if (counters.has(device)) continue; // IPv4 and IPv6 may share one WAN device.
		const stats = ((snapshot.devices || {})[device] || {}).stats;
		const current = stats && { rx: number(stats.rx_bytes), tx: number(stats.tx_bytes), up: !!iface.up };
		if (!current || current.rx === null || current.tx === null) { validRates = false; continue; }
		counters.set(device, current);
		const previous = state.deviceCounters.get(device);
		let rate = null;
		if (!iface.up) rate = { upload: 0, download: 0 };
		else if (previous && previous.up && gap > 0 && gap <= MAX_GAP && current.rx >= previous.rx && current.tx >= previous.tx)
			rate = { upload: (current.tx - previous.tx) / gap, download: (current.rx - previous.rx) / gap };
		if (rate) { upload += rate.upload; download += rate.download; }
		else validRates = false;
		rates[device] = rate;
	}
	state.deviceCounters = counters;
	// Per-device RX/TX is independent of WAN upload/download totals. Include LAN,
	// bridge members and virtual devices without adding them to the WAN total.
	const interfaceRates = {}, interfaceCounters = new Map();
	for (const [name, device] of Object.entries(snapshot.devices || {})) {
		const rx = number(device.stats && device.stats.rx_bytes), tx = number(device.stats && device.stats.tx_bytes);
		if (rx === null || tx === null) continue;
		interfaceCounters.set(name, { rx, tx, up: device.up !== false && device.link?.carrier !== false });
		const previous = state.interfaceCounters.get(name);
		if (device.up === false || device.link?.carrier === false) interfaceRates[name] = { rx: 0, tx: 0 };
		else if (previous && previous.up && gap > 0 && gap <= MAX_GAP && rx >= previous.rx && tx >= previous.tx)
			interfaceRates[name] = { rx: (rx - previous.rx) / gap, tx: (tx - previous.tx) / gap };
		else interfaceRates[name] = null;
	}
	state.interfaceCounters = interfaceCounters;
	const wifi = wirelessSummary(snapshot);
	const connection = updateConnections(state, snapshot, interfaces, wifi, gap);
	const memory = snapshot.info && snapshot.info.memory;
	const available = memory && (number(memory.available) !== null ? +memory.available : (+memory.free || 0) + (+memory.buffered || 0) + (+memory.cached || 0));
	const memoryUsage = memory && memory.total > 0 ? Math.max(0, Math.min(100, (1 - available / memory.total) * 100)) : null;
	const temperatures = (snapshot.temperatures || []).map(number).filter(value => value !== null && value > -40000 && value < 150000);
	const sample = { time, upload: validRates ? upload : null, download: validRates ? download : null, rates, protocols: connection.protocols };
	const dhcp = snapshot.interfaces === null ? { remaining: null, state: 'unavailable' } : dhcpAvailability(snapshot, interfaces, state);
	state.history.push(sample);
	state.history = state.history.filter(entry => entry.time >= time - 86400).slice(-MAX_HISTORY);
	state.time = time;
	state.uptime = snapshot.info ? snapshot.info.uptime : null;
	state.latest = {
		board: snapshot.board || {}, info: snapshot.info || {}, time, interfaces, wans, wifi, connection,
		cpuUsage, memoryUsage, temperature: temperatures.length ? Math.max(...temperatures) / 1000 : null,
		upload: sample.upload, download: sample.download, interfaceRates,
		connected: snapshot.interfaces === null ? null : wans.some(iface => iface.up &&
			(iface['ipv4-address'] || []).concat(iface['ipv6-address'] || []).length > 0),
		wanCount: snapshot.interfaces === null ? null : new Set(wans.filter(iface => iface.up).map(iface => iface.deviceName)).size,
		lanCount: snapshot.interfaces === null ? null : new Set(interfaces.filter(iface => iface.role === 'LAN' && iface.up).map(iface => iface.deviceName)).size,
		dhcpRemaining: dhcp.remaining,
		dhcpState: dhcp.state,
		connectionCount: number(snapshot.connectionCount), accounting: Number(snapshot.accounting) === 1,
		errors: snapshot.errors || [], devices: snapshot.devices || {}, history: state.history, trafficHistory: snapshot.trafficHistory || null,
		// 采集器持久化的 30 分钟/1 小时/1 天协议合计；页面刷新后仍然有数据。
		protocolTotals: snapshot.protocol && snapshot.protocol.totals ? snapshot.protocol.totals : null
	};
	return state.latest;
}

function createState() {
	return { time: null, uptime: null, cpu: null, deviceCounters: new Map(), interfaceCounters: new Map(), connectionCounters: new Map(), connectionBaseline: false, activeIPs: new Map(), leaseSeen: false, history: [], latest: null };
}

function formatBytes(value, rate) {
	if (number(value) === null) return '—';
	const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let unit = 0, n = Math.max(0, +value);
	while (n >= 1024 && unit < units.length - 1) { n /= 1024; unit++; }
	return n.toFixed(unit ? 2 : 0) + ' ' + units[unit] + (rate ? '/s' : '');
}

function protocolTotals(history, seconds, now) {
	const samples = history.filter(entry => entry.time > now - seconds && entry.protocols);
	return PROTOCOLS.map((protocol, i) => samples.reduce((sum, entry) => sum + entry.protocols[i], 0));
}

return baseclass.extend({ createState, ingest, formatBytes, protocolTotals, inSubnet, ipv4, cpuCounters, PROTOCOLS });
