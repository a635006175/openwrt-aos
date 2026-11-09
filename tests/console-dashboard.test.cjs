// SPDX-License-Identifier: Apache-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const { snapshot } = require('../tools/console-preview/fixtures.js');
const source = fs.readFileSync(path.join(root, 'package/luci-app-console/htdocs/luci-static/resources/console/model.js'), 'utf8');
const model = Function('baseclass', source)({ extend: value => value });

test('CPU utilization uses interval counters, excludes guest accounting and treats iowait as idle', () => {
	const state = model.createState();
	assert.equal(model.ingest(state, snapshot(0)).cpuUsage, null);
	const result = model.ingest(state, snapshot(1));
	assert.ok(Math.abs(result.cpuUsage - 7.4) < 0.000001);
	assert.equal(model.cpuCounters('cpu  10 2 3 20 5 1 1 0 10 2').total, 42);
	assert.equal(model.cpuCounters('cpu  10 2 3 20 5 1 1 0 10 2').idle, 25);
	assert.equal(model.cpuCounters('invalid'), null);
});

test('dual-stack WAN counters and enabled interfaces are counted once', () => {
	const state = model.createState(), first = snapshot(0), second = snapshot(1);
	model.ingest(state, first);
	const result = model.ingest(state, second);
	assert.equal(result.upload, (second.devices.eth1.stats.tx_bytes - first.devices.eth1.stats.tx_bytes) / 5);
	assert.equal(result.download, (second.devices.eth1.stats.rx_bytes - first.devices.eth1.stats.rx_bytes) / 5);
	assert.equal(result.wanCount, 1);
	assert.equal(result.lanCount, 1);
	assert.equal(result.connected, true);
});

test('multi-WAN rates are summed and retained independently for chart selection', () => {
	const state = model.createState();
	function multi(index) {
		const data = snapshot(index);
		data.interfaces.find(iface => iface.interface === 'wan2').up = true;
		data.devices.eth2.stats = { tx_bytes: 1000 + index * 10000, rx_bytes: 2000 + index * 20000 };
		return data;
	}
	model.ingest(state, multi(0));
	const result = model.ingest(state, multi(1));
	assert.equal(result.upload, result.history[1].rates.eth1.upload + 2000);
	assert.equal(result.download, result.history[1].rates.eth1.download + 4000);
	assert.equal(result.wanCount, 2);
});

test('counter resets, a reboot and sampling gaps do not create fake rate spikes', () => {
	const state = model.createState();
	model.ingest(state, snapshot(8));
	const reset = snapshot(9);
	reset.devices.eth1.stats.tx_bytes = 1;
	reset.devices.eth1.stats.rx_bytes = 1;
	assert.equal(model.ingest(state, reset).upload, null);
	const gap = snapshot(10, reset.time + 60);
	assert.equal(model.ingest(state, gap).upload, null);
	assert.equal(state.latest.connection.protocols, null);
	const reboot = snapshot(0, gap.time + 5);
	reboot.info.uptime = 2;
	model.ingest(state, reboot);
	assert.equal(state.history.length, 1);
	assert.equal(state.latest.upload, null);
});

test('API failure is unknown and recoveries establish new baselines', () => {
	const state = model.createState();
	model.ingest(state, snapshot(0));
	const failure = snapshot(1);
	failure.interfaces = null; failure.devices = null; failure.connections = null;
	const result = model.ingest(state, failure);
	assert.equal(result.connected, null);
	assert.equal(result.wanCount, null);
	assert.equal(result.upload, null);
	assert.equal(result.connection.clients, null);
	const recovered = model.ingest(state, snapshot(2));
	assert.equal(recovered.upload, null);
	assert.equal(recovered.connection.protocols, null);
});

test('DHCP availability accounts for pool boundaries, router address and reservations without double-counting', () => {
	const data = snapshot(0);
	assert.equal(model.ingest(model.createState(), data).dhcpRemaining, 135); // 150 - 14 leases - one reservation.
	data.staticLeases.push({ ip: '192.168.10.100' });
	data.leases.dhcp_leases.push({ ipaddr: '192.168.10.150', expires: 0 }, { ipaddr: '192.168.10.251', expires: 10 });
	assert.equal(model.ingest(model.createState(), data).dhcpRemaining, 135);
	data.dhcp = [ { interface: 'lan', start: '1', limit: '400' } ];
	assert.equal(model.ingest(model.createState(), data).dhcpRemaining, 237); // 254 usable, router, 15 live leases and reservation.
	data.leases = null;
	assert.equal(model.ingest(model.createState(), data).dhcpRemaining, null);
});

test('DHCP pool availability follows real IPv4 leases instead of the uci configuration alone', () => {
	assert.equal(model.ingest(model.createState(), snapshot(0)).dhcpState, 'active'); // A live lease proves the pool serves.
	assert.equal(model.ingest(model.createState(), snapshot(0)).dhcpRemaining, 135);
	const state = model.createState(), first = snapshot(0);
	first.leases.dhcp_leases = [];
	assert.equal(model.ingest(state, first).dhcpState, 'unknown'); // First sample cannot tell idle from dead.
	const silent = snapshot(1, first.time + 5);
	silent.leases.dhcp_leases = [];
	const result = model.ingest(state, silent);
	assert.equal(result.dhcpState, 'inactive'); // Configured pool, no dhcpv4 lease, already sampled once.
	assert.equal(result.dhcpRemaining, null);
});

test('a pool that stops serving is signalled as inactive and never keeps a fake remaining count', () => {
	const state = model.createState(), first = snapshot(0);
	first.leases.dhcp_leases = [];
	model.ingest(state, first);
	const second = snapshot(1);
	second.leases.dhcp_leases = [];
	const result = model.ingest(state, second);
	assert.equal(result.dhcpState, 'inactive');
	assert.equal(result.dhcpRemaining, null); // 150 is withheld: dnsmasq refused the range.
	assert.equal(result.wanCount, 1); // Classification is unaffected by the DHCP signal.
	assert.equal(result.lanCount, 1);
	assert.equal(result.connected, true);
});

test('an observed lease stays active after it expires so the card does not flap back to 未生效', () => {
	const state = model.createState();
	model.ingest(state, snapshot(0));
	const expired = snapshot(1);
	expired.leases.dhcp_leases = expired.leases.dhcp_leases.map(lease => Object.assign({}, lease, { expires: 0 }));
	const result = model.ingest(state, expired);
	assert.equal(result.dhcpState, 'active');
	assert.equal(result.dhcpRemaining, 149); // Existing math drops expired leases: 150 - router address - one reservation.
});

test('an explicit dhcpEnabled fact overrides lease inference, and unreadable pool data is unavailable', () => {
	const enabled = snapshot(0);
	enabled.leases.dhcp_leases = [];
	enabled.dhcpEnabled = true;
	assert.equal(model.ingest(model.createState(), enabled).dhcpState, 'active');
	assert.equal(model.ingest(model.createState(), enabled).dhcpRemaining, 149); // 150 - one static reservation in the fixture.
	const disabled = snapshot(0);
	disabled.dhcpEnabled = false;
	const inactive = model.ingest(model.createState(), disabled);
	assert.equal(inactive.dhcpState, 'inactive'); // Also wins on the very first sample.
	assert.equal(inactive.dhcpRemaining, null);
	const missing = snapshot(0);
	missing.dhcp = null;
	assert.equal(model.ingest(model.createState(), missing).dhcpState, 'unavailable');
	const noPools = snapshot(0);
	noPools.dhcp = [ { interface: 'wan', ignore: '1', start: '100', limit: '150' } ];
	assert.equal(model.ingest(model.createState(), noPools).dhcpState, 'unavailable'); // No usable LAN pool at all.
	const noIfaces = snapshot(0);
	noIfaces.interfaces = null;
	assert.equal(model.ingest(model.createState(), noIfaces).dhcpState, 'unavailable');
});

test('a LAN pool whose dhcpv4 is explicitly disabled is never reported as an empty healthy pool', () => {
	const data = snapshot(0), state = model.createState();
	data.leases.dhcp_leases = [];
	data.dhcp = [ { interface: 'lan', start: '100', limit: '150', dhcpv4: 'disabled' } ];
	model.ingest(state, data);
	const second = snapshot(1, data.time + 5);
	second.leases.dhcp_leases = [];
	second.dhcp = data.dhcp;
	const result = model.ingest(state, second);
	assert.equal(result.dhcpState, 'inactive'); // dhcpv4=disabled means the range is never written.
	assert.equal(result.dhcpRemaining, null);
});

test('only sampled active LAN clients are counted; IPv4/IPv6 are merged by MAC and expire after two minutes', () => {
	const state = model.createState();
	model.ingest(state, snapshot(0));
	const second = snapshot(1);
	second.hints['02:00:00:00:00:01'].ip6addrs = [ 'fd10:20::100' ];
	second.connections.push({ layer3: 'ipv6', layer4: 'tcp', src: 'fd10:20::100', dst: '2001:db8:200::10', sport: 60000, dport: 443, bytes: 2000, packets: 10 });
	second.connections.push({ layer3: 'ipv4', layer4: 'tcp', src: '203.0.113.23', dst: '192.168.10.100', sport: 60001, dport: 80, bytes: 9999999, packets: 99 });
	const result = model.ingest(state, second);
	assert.equal(result.connection.clients.length, 14);
	assert.equal(result.connection.wired, 12);
	assert.equal(result.connection.wireless, 2);
	assert.equal(result.connection.clients.find(row => row.mac === '02:00:00:00:00:01').ips.length, 2);
	const quiet = snapshot(2, second.time + 121); quiet.connections = [];
	model.ingest(state, quiet);
	quiet.time += 5; model.ingest(state, quiet);
	assert.equal(state.latest.connection.clients.length, 0);
});

test('IPv6 subnet checks handle compression and IPv4-mapped addresses; malformed masks are rejected', () => {
	assert.equal(model.inSubnet('fd10:20::abc', { address: 'fd10:20::1', mask: 64 }), true);
	assert.equal(model.inSubnet('fd10:21::abc', { address: 'fd10:20::1', mask: 64 }), false);
	assert.equal(model.inSubnet('::ffff:192.168.1.10', { address: '::ffff:c0a8:100', mask: 120 }), true);
	assert.equal(model.inSubnet('203.0.113.1', { address: '192.168.10.1' }), false);
	assert.equal(model.inSubnet('invalid', { address: '::', mask: 0 }), false);
});

test('protocol accounting begins with a baseline; disabled accounting remains unavailable', () => {
	const state = model.createState();
	assert.equal(model.ingest(state, snapshot(0)).connection.protocols, null);
	const second = model.ingest(state, snapshot(1));
	assert.equal(second.connection.protocols[0], Array.from({ length: 8 }, (_, i) => 40000 + i * 1700).reduce((a, b) => a + b));
	assert.equal(model.protocolTotals(state.history, 1800, state.time)[0], second.connection.protocols[0]);
	const disabled = snapshot(2); disabled.accounting = '0';
	const unavailable = model.ingest(state, disabled);
	assert.equal(unavailable.connection.protocols, null);
	assert.equal(unavailable.connection.clients, null);
});

test('missing wireless hardware, unavailable associations, disabled APs and 6GHz do not masquerade as managed AC devices', () => {
	const data = snapshot(0);
	const regular = model.ingest(model.createState(), data);
	assert.equal(regular.wifi.apUp, 1); assert.equal(regular.wifi.apDown, 1);
	assert.deepEqual(regular.wifi.bands, [ 2, 0, 0 ]);
	data.wireless.radio0.interfaces[0].iwinfo.frequency = 6115;
	assert.deepEqual(model.ingest(model.createState(), data).wifi.bands, [ 0, 0, 2 ]);
	data.associations['phy0-ap0'] = null;
	assert.equal(model.ingest(model.createState(), data).wifi.bands[2], null);
	data.wireless = {};
	assert.equal(model.ingest(model.createState(), data).wifi.radios, 0);
});

test('memory and temperature use available memory and valid CPU sensors', () => {
	const data = snapshot(0); data.temperatures = [ null, '', '52000', '59000', 'broken', '9999999' ];
	const result = model.ingest(model.createState(), data);
	assert.ok(Math.abs(result.memoryUsage - 40) < 0.000001);
	assert.equal(result.temperature, 59);
	assert.equal(model.formatBytes(null, true), '—');
});

test('the package menu is the first admin page and the custom ACL grants only the required read operations', () => {
	const menu = JSON.parse(fs.readFileSync(path.join(root, 'package/luci-app-console/root/usr/share/luci/menu.d/luci-app-console.json')));
	const acl = JSON.parse(fs.readFileSync(path.join(root, 'package/luci-app-console/root/usr/share/rpcd/acl.d/luci-app-console.json')))['luci-app-console'];
	assert.equal(menu['admin/console'].action.path, 'console/overview');
	assert.ok(menu['admin/console'].order < 10);
	assert.equal(acl.write, undefined);
	assert.deepEqual(acl.read.ubus['luci'], [ 'getConntrackList' ]);
	assert.equal(acl.read.file['/proc/stat'][0], 'read');
});
