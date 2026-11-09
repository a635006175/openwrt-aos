// SPDX-License-Identifier: Apache-2.0
import { validateServer, validateClient, serverConfig, fileExists } from 'console.vpn-service';

function check(value, message) { if (!value) die(message + '\n'); }
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }
check(fileExists('/dev/null'), 'Ucode fs.stat did not detect an existing file');
check(!fileExists('/tmp/console-vpn-service-test-missing'), 'Ucode fs.stat accepted a missing file');
const settings = { enabled: true, vpnSubnet: '10.8.0.0/24', localSubnet: '192.168.1.0/24', port: 1194, protocol: 'udp', endpoint: 'vpn.example.com', allowWan: false };
const accounts = [
	{ username: 'branch_a', enabled: true, address: '10.8.0.10', remoteSubnet: '192.168.2.0/24' },
	{ username: 'branch_b', enabled: true, address: '', remoteSubnet: '192.168.3.0/24' },
	{ username: 'disabled', enabled: false, address: '10.8.0.10', remoteSubnet: '192.168.1.0/24' }
];
const result = serverConfig(settings, accounts);
check(index(result.config, 'client-to-client') >= 0, 'client-to-client missing');
check(index(result.config, 'cert /etc/console-vpn/pki/issued/server.crt') >= 0, 'Easy-RSA server certificate path is wrong');
check(index(result.config, 'key /etc/console-vpn/pki/private/server.key') >= 0, 'Easy-RSA server key path is wrong');
check(index(result.config, 'push "route 192.168.1.0 255.255.255.0"') >= 0, 'server LAN route missing');
check(index(result.config, 'route 192.168.2.0 255.255.255.0') >= 0, 'site route missing');
check(index(result.ccd.branch_a, 'ifconfig-push 10.8.0.10 255.255.255.0') >= 0, 'static client address missing');
check(index(result.ccd.branch_a, 'iroute 192.168.2.0 255.255.255.0') >= 0, 'client site route missing');
check(index(result.ccd.branch_a, 'push "route 192.168.3.0 255.255.255.0"') >= 0, 'peer LAN route missing');
check(result.ccd.branch_b != null && result.ccd.disabled == null, 'disabled account received a CCD');
check(index(result.config, 'redirect-gateway') < 0, 'internet traffic is unexpectedly redirected');
const overlap = { enabled: true, vpnSubnet: '10.8.0.0/24', localSubnet: '10.8.0.0/24', port: 1194, protocol: 'udp', endpoint: 'vpn.example.com', allowWan: false };
check(throws(() => validateServer(overlap, accounts)), 'overlapping server networks accepted');
const badPeers = [accounts[0], accounts[1], accounts[2], { username: 'branch_c', enabled: true, address: '10.8.0.11', remoteSubnet: '192.168.2.1/24' }];
check(throws(() => validateServer(settings, badPeers)), 'overlapping client LAN accepted');
const injection = { enabled: true, vpnSubnet: '10.8.0.0/24', localSubnet: '192.168.1.0/24', port: 1194, protocol: 'udp', endpoint: 'vpn.example.com script-security 3', allowWan: false };
check(throws(() => validateServer(injection, accounts)), 'config injection accepted');
const client = { host: 'vpn.example.com', port: 1194, protocol: 'udp', username: 'branch_a', password: 'test-password-123', localSubnet: '192.168.2.0/24', ca: '-----BEGIN CERTIFICATE-----\nMIIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-----END CERTIFICATE-----' };
check(validateClient(client).lan.network == '192.168.2.0', 'valid client config rejected');
const badClientHost = { host: 'vpn.example.com remote 10.8.0.1', port: 1194, protocol: 'udp', username: 'branch_a', password: 'test-password-123', localSubnet: '192.168.2.0/24', ca: client.ca };
const badClientCA = { host: 'vpn.example.com', port: 1194, protocol: 'udp', username: 'branch_a', password: 'test-password-123', localSubnet: '192.168.2.0/24', ca: '-----BEGIN PRIVATE KEY-----' };
check(throws(() => validateClient(badClientHost)), 'unsafe client endpoint accepted');
check(throws(() => validateClient(badClientCA)), 'private key accepted as CA');
print('PASS: server/client validation, static/dynamic peers, site routes, disabled accounts and safe default routing.\n');

const multi=serverConfig({...settings,localSubnet:'192.168.1.7/24\n192.168.4.0/24,192.168.4.9/24'},accounts);
check(length(multi.validation.lans)==2,'deduplicated normalized push routes');
check(index(multi.config,'push "route 192.168.4.0 255.255.255.0"')>=0,'second push route missing');
check(throws(()=>serverConfig({...settings,localSubnet:'192.168.1.0/24\n10.8.0.0/24'},accounts)),'second route overlaps VPN');
check(throws(()=>serverConfig({...settings,localSubnet:'192.168.1.0/24\n192.168.2.0/24'},accounts)),'second route overlaps client site');
check(throws(()=>serverConfig({...settings,localSubnet:'192.168.1.0/24\nbad'},accounts)),'invalid second route accepted');
print('PASS multiple push routes, normalization, deduplication and all-route overlap validation.\n');
