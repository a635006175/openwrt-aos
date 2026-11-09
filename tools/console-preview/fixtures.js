// SPDX-License-Identifier: Apache-2.0
// Deliberate sample data for the local preview and telemetry regression tests.
(function(root) {
	function snapshot(index, time) {
		let tx = 0, rx = 0;
		for (let i = 1; i <= index; i++) {
			const burst = Math.max(0, 1 - Math.abs(i % 60 - 39) / 7);
			tx += Math.round((65000 + 55000 * (1 + Math.sin(i / 6)) + burst * 2100000) * 5);
			rx += Math.round((180000 + 70000 * (1 + Math.sin(i / 8)) + burst * 4500000) * 5);
		}
		const names = [ '办公电脑', '会议室平板', '前台工作站', '文件服务器', '财务电脑', '打印机', '研发工作站', '访客终端', '测试电脑', '监控主机', '设计工作站', '会议设备', '仓库终端', '运维笔记本' ];
		const hints = {}, leases = [], connections = [];
		for (let i = 0; i < 14; i++) {
			const mac = '02:00:00:00:00:' + (i + 1).toString(16).padStart(2, '0'), ip = '192.168.10.' + (100 + i);
			hints[mac] = { name: names[i], ipaddrs: [ ip ], ip6addrs: [] };
			leases.push({ hostname: names[i], ipaddr: ip, macaddr: mac, expires: 3400 });
			connections.push({ layer3: 'ipv4', layer4: i < 8 ? 'tcp' : i < 13 ? 'udp' : 'icmp', src: ip, dst: '203.0.113.' + (20 + i), sport: 50000 + i, dport: i < 8 ? 443 : 53, bytes: 100000 + index * (40000 + i * 1700), packets: 200 + index * 28 });
		}
		return {
			time: time === undefined ? 1791210000 + index * 5 : time,
			board: { hostname: 'OpenWrt-Gateway', model: 'Generic x86/64', kernel: '6.18', release: { version: 'SNAPSHOT', target: 'x86/64', description: 'OpenWrt SNAPSHOT' } },
			info: { uptime: 9 * 86400 + 23 * 3600 + index * 5, memory: { total: 2147483648, available: 1288490189, free: 900000000, buffered: 100000000, cached: 288490189 } },
			cpu: 'cpu  ' + (100000 + index * 74) + ' 0 1000 ' + (800000 + index * 926) + ' 0 0 0 0 0 0\n',
			interfaces: [
				{ interface: 'wan', up: true, l3_device: 'eth1', proto: 'dhcp', 'ipv4-address': [ { address: '203.0.113.10', mask: 24 } ], route: [ { target: '0.0.0.0', mask: 0, nexthop: '203.0.113.1' } ] },
				{ interface: 'wan6', up: true, l3_device: 'eth1', proto: 'dhcpv6', 'ipv6-address': [ { address: '2001:db8:100::10', mask: 64 } ] },
				{ interface: 'wan2', up: false, l3_device: 'eth2', proto: 'dhcp', 'ipv4-address': [] },
				{ interface: 'lan', up: true, l3_device: 'br-lan', proto: 'static', 'ipv4-address': [ { address: '192.168.10.1', mask: 24 } ], 'ipv6-address': [ { address: 'fd10:20::1', mask: 64 } ] },
				{ interface: 'lan2', up: false, l3_device: 'eth3', proto: 'static', 'ipv4-address': [ { address: '192.168.20.1', mask: 24 } ] }
			],
			devices: { eth1: { stats: { tx_bytes: 1000000 + tx, rx_bytes: 2000000 + rx }, link: { carrier: true } }, eth2: { stats: { tx_bytes: 0, rx_bytes: 0 }, link: { carrier: false } }, 'br-lan': { stats: { tx_bytes: rx, rx_bytes: tx }, link: { carrier: true } }, eth3: { stats: { tx_bytes: 0, rx_bytes: 0 }, link: { carrier: false } } },
			zones: [ { name: 'wan', network: [ 'wan', 'wan6', 'wan2' ] }, { name: 'lan', network: [ 'lan', 'lan2' ] } ],
			dhcp: [ { interface: 'lan', start: '100', limit: '150' } ], staticLeases: [ { ip: '192.168.10.140' } ],
			leases: { dhcp_leases: leases, dhcp6_leases: [] }, hints, connections, connectionCount: '77', accounting: '1', temperatures: [ '52000' ],
			wireless: {
				radio0: { up: true, disabled: false, interfaces: [ { section: 'default_radio0', ifname: 'phy0-ap0', config: { mode: 'ap', disabled: false }, iwinfo: { frequency: 2437 } } ] },
				radio1: { up: false, disabled: true, interfaces: [ { section: 'default_radio1', ifname: null, config: { mode: 'ap', disabled: true } } ] }
			},
			associations: { 'phy0-ap0': [ { mac: '02:00:00:00:00:01' }, { mac: '02:00:00:00:00:02' } ] }, errors: []
		};
	}
	root.ConsoleFixtures = { snapshot };
	if (typeof module !== 'undefined') module.exports = root.ConsoleFixtures;
})(globalThis);
