// SPDX-License-Identifier: Apache-2.0
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../package/luci-app-console/htdocs/luci-static/resources/console/vpn-model.js'), 'utf8');
const vpn = Function('baseclass', source)({ extend: value => value });
const server = () => ({ vpnSubnet: '10.8.0.0/24', localSubnet: '192.168.1.0/24', port: 1194, protocol: 'udp', accounts: [{ username: 'branch', address: '10.8.0.10', remoteSubnet: '192.168.2.0/24' }] });
test('builds server routes and client-specific routing for bidirectional access', () => {
	const result = vpn.serverConfig(server());
	assert.match(result.config, /dev cvpns/);
	assert.match(result.config, /cert \/etc\/console-vpn\/pki\/issued\/server\.crt/);
	assert.match(result.config, /key \/etc\/console-vpn\/pki\/private\/server\.key/);
	assert.match(result.config, /push "route 192\.168\.1\.0 255\.255\.255\.0"/);
	assert.match(result.config, /route 192\.168\.2\.0 255\.255\.255\.0/);
	assert.match(result.ccd.branch, /ifconfig-push 10\.8\.0\.10 255\.255\.255\.0/);
	assert.match(result.ccd.branch, /iroute 192\.168\.2\.0 255\.255\.255\.0/);
	assert.doesNotMatch(result.config, /redirect-gateway/);
});
test('routes separate branch LANs to every peer and excludes disabled accounts', () => {
	const config = server();
	config.accounts.push({ username: 'branch_two', enabled: true, remoteSubnet: '192.168.3.0/24' });
	config.accounts.push({ username: 'inactive', enabled: false, remoteSubnet: '192.168.4.0/24' });
	const result = vpn.serverConfig(config);
	assert.match(result.config, /route 192\.168\.3\.0 255\.255\.255\.0/);
	assert.match(result.ccd.branch, /iroute 192\.168\.2\.0 255\.255\.255\.0/);
	assert.match(result.ccd.branch, /push "route 192\.168\.3\.0 255\.255\.255\.0"/);
	assert.match(result.ccd.branch_two, /push "route 192\.168\.2\.0 255\.255\.255\.0"/);
	assert.equal(result.ccd.inactive, undefined);
});
test('allows dynamically assigned VPN addresses and canonicalizes peer routes', () => {
	const config = server(); config.accounts[0].address = ''; config.accounts[0].remoteSubnet = '192.168.2.17/24';
	const result = vpn.serverConfig(config);
	assert.doesNotMatch(result.ccd.branch, /ifconfig-push/);
	assert.match(result.ccd.branch, /iroute 192\.168\.2\.0 255\.255\.255\.0/);
});
test('rejects overlapping networks, repeated identities and unusable VPN addresses', () => {
	for (const mutate of [x => x.localSubnet = '10.8.0.0/24', x => x.accounts[0].remoteSubnet = '192.168.1.128/25', x => x.accounts[0].address = '10.8.0.1', x => x.accounts[0].username = '../unsafe', x => x.accounts.push({ username: 'branch', address: '10.8.0.11' }), x => x.accounts.push({ username: 'other', address: '10.8.0.10' })]) {
		const config = server(); mutate(config); assert.throws(() => vpn.serverConfig(config));
	}
});
test('validates client endpoint and keeps credentials in a separate file', () => {
	const conf = vpn.clientConfig({ host: 'vpn.example.com', port: 1194, protocol: 'udp' });
	assert.match(conf, /remote vpn\.example\.com 1194/);
	assert.match(conf, /auth-user-pass \/etc\/console-vpn\/client\/auth/);
	assert.throws(() => vpn.clientConfig({ host: 'good\nscript-security 3', port: 1194, protocol: 'udp' }));
	assert.throws(() => vpn.clientConfig({ host: 'vpn.example.com', port: 70000, protocol: 'udp' }));
});

test('pushes multiple server LANs and validates every route',()=>{
 const config=server();config.localSubnet='192.168.1.7/24\n192.168.4.0/24,192.168.4.9/24';
 const result=vpn.serverConfig(config);assert.match(result.config,/push "route 192\.168\.4\.0 255\.255\.255\.0"/);assert.equal(result.config.split('push "route 192.168.4.0').length-1,1);
 config.localSubnet='192.168.1.0/24\n10.8.0.0/24';assert.throws(()=>vpn.serverConfig(config));
 config.localSubnet='192.168.1.0/24\n192.168.2.0/24';assert.throws(()=>vpn.serverConfig(config));
});
