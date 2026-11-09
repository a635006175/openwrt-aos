// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';

// IPv4-only routed site-to-site topology. No configuration is applied here.
function ipv4(text) {
	if (typeof text !== 'string' || !/^(?:\d{1,3}\.){3}\d{1,3}$/.test(text)) return null;
	const parts = text.split('.').map(Number);
	if (parts.some(part => part > 255)) return null;
	return parts.reduce((value, part) => value * 256 + part, 0);
}
function formatIP(value) { return [24, 16, 8, 0].map(shift => Math.floor(value / Math.pow(2, shift)) % 256).join('.'); }
function subnet(value) {
	const match = typeof value === 'string' && value.match(/^([^/]+)\/(\d{1,2})$/);
	if (!match) return null;
	const address = ipv4(match[1]), prefix = Number(match[2]);
	if (address === null || prefix < 1 || prefix > 30) return null;
	const size = Math.pow(2, 32 - prefix), start = Math.floor(address / size) * size;
	return { start, end: start + size - 1, prefix, network: formatIP(start), mask: formatIP(4294967296 - size) };
}
function intersects(a, b) { return a.start <= b.end && b.start <= a.end; }
function fail(message) { throw new Error(message); }
function requiredSubnet(value, label) { const result = subnet(value); if (!result) fail(label + '必须为有效的 IPv4 网段，例如 192.168.2.0/24'); return result; }
function validateServer(config) {
	const vpn = requiredSubnet(config.vpnSubnet, 'VPN 网段');
	const routes=String(config.localSubnet||'').trim().split(/[\s,;]+/).filter(Boolean);
	if(!routes.length||routes.length>64)fail('请填写1至64条服务端内网推送路由');
	const locals=[...new Map(routes.map(r=>{const l=requiredSubnet(r,'服务端内网');return [l.network+'/'+l.prefix,l];})).values()],local=locals[0];
	if (vpn.prefix > 24) fail('VPN 网段至少需要 256 个地址（/24 或更大）');
	if (locals.some(l=>intersects(vpn,l))) fail('VPN 网段与服务端内网重叠');
	const port = Number(config.port);
	if (!Number.isInteger(port) || port < 1 || port > 65535) fail('端口必须在 1 到 65535 之间');
	if (!['udp', 'tcp-server'].includes(config.protocol)) fail('隧道协议无效');
	const names = new Set(), addresses = new Set(), peers = [];
	for (const account of config.accounts || []) {
		if (account.enabled === false) continue;
		if (!/^[A-Za-z0-9_-]{1,48}$/.test(account.username || '')) fail('账号只能包含字母、数字、下划线和短横线');
		if (names.has(account.username)) fail('账号名称重复：' + account.username);
		names.add(account.username);
		if (account.address) {
			const ip = ipv4(account.address);
			if (ip === null || ip <= vpn.start + 1 || ip >= vpn.end) fail('账号 ' + account.username + ' 的固定 IP 不在可用地址范围内');
			if (addresses.has(ip)) fail('账号固定 IP 重复：' + account.address);
			addresses.add(ip);
		}
		let peer = null;
		if (account.remoteSubnet) {
			peer = requiredSubnet(account.remoteSubnet, '账号 ' + account.username + ' 的远端网段');
			if (intersects(peer, vpn) || locals.some(l=>intersects(peer,l)) || peers.some(other => intersects(peer, other))) fail('账号 ' + account.username + ' 的远端网段与已有网段重叠');
			peers.push(peer);
		}
	}
	return { vpn, local, locals, port, peers };
}
function serverConfig(config) {
	const { vpn, local, locals, port, peers } = validateServer(config);
	const lines = [
		'port ' + port, 'proto ' + config.protocol, 'dev cvpns', 'dev-type tun', 'topology subnet',
		'server ' + vpn.network + ' ' + vpn.mask, 'ca /etc/console-vpn/pki/ca.crt',
		'cert /etc/console-vpn/pki/issued/server.crt', 'key /etc/console-vpn/pki/private/server.key', 'dh none',
		'verify-client-cert none', 'username-as-common-name', 'script-security 2',
		'auth-user-pass-verify /usr/libexec/console-vpn-auth via-file', 'client-config-dir /etc/console-vpn/ccd',
		'ccd-exclusive', 'client-to-client', 'duplicate-cn', 'max-clients 99', 'keepalive 10 60', 'persist-key', 'persist-tun', 'status /var/run/console-vpn/server.status'
	];
	for (const lan of locals) lines.push('push "route ' + lan.network + ' ' + lan.mask + '"');
	for (const peer of peers) lines.push('route ' + peer.network + ' ' + peer.mask);
	const ccd = {};
	for (const account of (config.accounts || []).filter(item => item.enabled !== false)) {
		const entries = [];
		if (account.address) entries.push('ifconfig-push ' + formatIP(ipv4(account.address)) + ' ' + vpn.mask);
		if (account.remoteSubnet) {
			const peer = requiredSubnet(account.remoteSubnet, '远端网段');
			entries.push('iroute ' + peer.network + ' ' + peer.mask);
		}
		for (const peer of peers) if (!account.remoteSubnet || subnet(account.remoteSubnet).network !== peer.network) entries.push('push "route ' + peer.network + ' ' + peer.mask + '"');
		ccd[account.username] = entries.join('\n') + '\n';
	}
	return { config: lines.join('\n') + '\n', ccd };
}
function clientConfig(config) {
	const host = String(config.host || '');
	if (!/^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(host) || host.includes('..')) fail('服务端地址无效');
	const port = Number(config.port);
	if (!Number.isInteger(port) || port < 1 || port > 65535) fail('端口必须在 1 到 65535 之间');
	if (!['udp', 'tcp-client'].includes(config.protocol)) fail('隧道协议无效');
	return ['client', 'dev cvpnc', 'dev-type tun', 'proto ' + config.protocol, 'remote ' + host + ' ' + port,
		'nobind', 'persist-key', 'persist-tun', 'remote-cert-tls server', 'auth-nocache',
		'ca /etc/console-vpn/client/ca.crt', 'auth-user-pass /etc/console-vpn/client/auth'].join('\n') + '\n';
}
return baseclass.extend({ ipv4, subnet, intersects, validateServer, serverConfig, clientConfig });
