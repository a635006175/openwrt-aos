// SPDX-License-Identifier: Apache-2.0
// 在路由器上运行：ucode -L /usr/share/ucode /tmp/console-vpn-profile-test.uc
// 校验 .ovpn 解析结果、生成配置内容与危险指令的拦截。
import { parseProfile, profileSummary } from 'console.vpn-profile';
import { clientConfigText, localSubnets, pullIgnoreList } from 'console.vpn-service';

function check(value, message) { if (!value) die(message + '\n'); }
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }
function contains(list, text) { for (let item in list) if (item == text) return true; return false; }

const CA = join('\n', [
	'-----BEGIN CERTIFICATE-----',
	'MIIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
	'-----END CERTIFICATE-----'
]);

const profile = join('\n', [
	'client', 'dev tun', 'proto udp', 'remote vpn.example.com 1194',
	'resolv-retry infinite', 'nobind', 'persist-key', 'persist-tun', 'remote-cert-tls server',
	'cipher AES-256-GCM', 'auth SHA256', 'data-ciphers AES-256-GCM:AES-128-GCM', 'auth-nocache',
	'connect-retry 5', 'verb 3', 'redirect-gateway def1',
	'up /bin/sh -c "echo injected"', 'down /bin/sh -c "echo injected"', 'script-security 2',
	'management 127.0.0.1 7505', 'plugin /usr/lib/openvpn/plugin.so', 'ifconfig 10.8.0.5 255.255.255.0',
	'<ca>', CA, '</ca>'
]);

const parsed = parseProfile(profile);
check(parsed.host == 'vpn.example.com', 'remote host not parsed');
check(parsed.port == 1194, 'remote port not parsed');
check(parsed.protocol == 'udp', 'proto not parsed');
check(parsed.ca == CA, 'inline CA not parsed');
check(parsed.remoteCertTls, 'remote-cert-tls not detected');
check(parsed.redirectGateway, 'redirect-gateway not detected');
check(parsed.authUserPass == false, 'auth-user-pass must not be implied');
check(contains(parsed.extra, 'cipher AES-256-GCM'), 'cipher not adopted');
check(contains(parsed.extra, 'auth SHA256'), 'auth not adopted');
check(contains(parsed.extra, 'data-ciphers AES-256-GCM:AES-128-GCM'), 'data-ciphers not adopted');
check(contains(parsed.extra, 'nobind'), 'nobind not adopted');
check(contains(parsed.extra, 'resolv-retry infinite'), 'resolv-retry not adopted');
check(contains(parsed.extra, 'connect-retry 5'), 'connect-retry not adopted');
check(!contains(parsed.extra, 'up /bin/sh -c "echo injected"'), 'script hook adopted');
check(!contains(parsed.extra, 'script-security 2'), 'script-security adopted');
check(!contains(parsed.extra, 'management 127.0.0.1 7505'), 'management adopted');
check(contains(parsed.ignored, 'up（脚本钩子）'), 'up not reported');
check(contains(parsed.ignored, 'script-security（脚本安全级别）'), 'script-security not reported');
check(contains(parsed.ignored, 'management（管理接口）'), 'management not reported');
check(contains(parsed.ignored, 'ifconfig（服务端下发地址）'), 'ifconfig not reported');
print('PASS: profile parsing and option whitelist.\n');

const summary = profileSummary(parsed);
check(summary.requiresCredentials, 'credentials must be requested without client certificate');
check(summary.hasCert == false, 'client certificate must not be reported');
check(summary.host == 'vpn.example.com', 'summary host missing');

const config = clientConfigText({
	host: parsed.host, port: parsed.port, protocol: parsed.protocol, remoteCertTls: parsed.remoteCertTls,
	useAuth: true, ca: parsed.ca, cert: '', key: '', tlsAuth: '', tlsCrypt: '', keyDirection: 1,
	extra: parsed.extra, redirectGateway: true
});
check(index(config, 'remote vpn.example.com 1194') >= 0, 'generated config misses remote');
check(index(config, 'proto udp') >= 0, 'generated config misses proto');
check(index(config, 'ca /etc/console-vpn/client/ca.crt') >= 0, 'generated config misses ca path');
check(index(config, 'auth-user-pass /etc/console-vpn/client/auth') >= 0, 'generated config misses auth path');
check(index(config, 'redirect-gateway def1 bypass-dhcp') >= 0, 'generated config misses redirect-gateway');
check(index(config, 'cipher AES-256-GCM') >= 0, 'generated config misses adopted option');
check(index(config, 'up /bin/sh') < 0, 'generated config contains script hook');
check(index(config, 'script-security') < 0, 'generated config contains script-security');
check(index(config, 'management ') < 0, 'generated config contains management interface');
check(index(config, 'ifconfig ') < 0, 'generated config contains server pushed address');
print('PASS: generated client config contains only adopted options.\n');

const withAuth = parseProfile(join('\n', ['client', 'proto tcp-client', 'remote 10.0.0.9 443', 'auth-user-pass', '<ca>', CA, '</ca>']));
check(withAuth.protocol == 'tcp-client', 'tcp proto not mapped');
check(withAuth.port == 443, 'port not parsed');
check(withAuth.authUserPass, 'auth-user-pass not detected');
check(profileSummary(withAuth).requiresCredentials, 'credentials must be requested with auth-user-pass');

const withCert = parseProfile(join('\n', [
	'client', 'proto udp', 'remote 10.0.0.9 1194', '<ca>', CA, '</ca>',
	'<cert>', '-----BEGIN CERTIFICATE-----', 'MIIB', '-----END CERTIFICATE-----', '</cert>',
	'<key>', '-----BEGIN PRIVATE KEY-----', 'MIIB', '-----END PRIVATE KEY-----', '</key>'
]));
check(withCert.cert != '' && withCert.key != '', 'inline client certificate not parsed');
check(profileSummary(withCert).requiresCredentials == false, 'certificate profile must not require credentials');
const certConfig = clientConfigText({
	host: withCert.host, port: withCert.port, protocol: withCert.protocol, remoteCertTls: false,
	useAuth: false, ca: withCert.ca, cert: withCert.cert, key: withCert.key, tlsAuth: '', tlsCrypt: '',
	keyDirection: 1, extra: withCert.extra, redirectGateway: false
});
check(index(certConfig, 'cert /etc/console-vpn/client/client.crt') >= 0, 'generated config misses client certificate');
check(index(certConfig, 'key /etc/console-vpn/client/client.key') >= 0, 'generated config misses client key');
check(index(certConfig, 'auth-user-pass') < 0, 'generated config asks for credentials in certificate mode');
check(index(certConfig, 'remote-cert-tls') < 0, 'generated config forces remote-cert-tls in certificate mode');
print('PASS: tcp mapping, inline certificate and credential detection.\n');

check(throws(() => parseProfile('client\nproto udp\nremote 10.0.0.9 1194')), 'profile without CA accepted');
check(throws(() => parseProfile(join('\n', ['proto udp', 'remote 10.0.0.9 1194', '<ca>', '-----BEGIN PRIVATE KEY-----', 'MIIB', '-----END PRIVATE KEY-----', '</ca>']))), 'private key accepted as CA');
check(throws(() => parseProfile(join('\n', ['proto udp6', 'remote 10.0.0.9 1194', '<ca>', CA, '</ca>']))), 'IPv6 protocol accepted');
check(throws(() => parseProfile(join('\n', ['proto udp', 'dev tap', 'remote 10.0.0.9 1194', '<ca>', CA, '</ca>']))), 'tap device accepted');
check(throws(() => parseProfile(join('\n', ['proto udp', 'remote 10.0.0.9 1194', '<ca>', CA, '</ca>', '<cert>', '-----BEGIN CERTIFICATE-----', 'MIIB', '-----END CERTIFICATE-----', '</cert>']))), 'client certificate without key accepted');
check(throws(() => parseProfile('')), 'empty profile accepted');
check(throws(() => parseProfile('client\nproto udp\nremote 10.0.0.9 70000\n<ca>\n' + CA + '\n</ca>')), 'invalid port accepted');
print('PASS: invalid profiles are rejected.\n');

// 本机直连网段必须被忽略，避免推送路由把路由器自身的 LAN 流量引进隧道。
const subnets = localSubnets();
check(length(subnets) > 0, 'no local subnet detected');
let lanFound = false;
for (let item in subnets) {
	if (item.text == '192.168.1.0/24') lanFound = true;
	check(index(item.network, '.') > 0, 'subnet network is malformed');
	check(index(item.mask, '.') > 0, 'subnet mask is malformed');
}
check(lanFound, 'LAN 192.168.1.0/24 not detected on this device');
const filters = pullIgnoreList('192.168.2.0/24');
check(contains(filters, 'route 192.168.1.0 255.255.255.0'), 'LAN route not ignored');
check(contains(filters, 'route 192.168.2.0 255.255.255.0'), 'configured LAN not ignored');
const guarded = clientConfigText({
	host: '10.0.0.9', port: 1194, protocol: 'udp', remoteCertTls: true, useAuth: true, ca: CA,
	cert: '', key: '', tlsAuth: '', tlsCrypt: '', keyDirection: 1, extra: [], redirectGateway: false,
	pullIgnore: filters
});
check(index(guarded, 'pull-filter ignore "route 192.168.1.0 255.255.255.0"') >= 0, 'generated config misses pull-filter for the LAN');
check(index(guarded, 'pull-filter ignore "route 192.168.2.0 255.255.255.0"') >= 0, 'generated config misses pull-filter for the configured LAN');
print('PASS: pushed routes overlapping local networks are ignored.\n');
