// SPDX-License-Identifier: Apache-2.0
import { open, mkdir, chmod, lsdir, readfile, rename, unlink, stat, popen } from 'fs';
import { listAccounts } from 'console.vpn-accounts';
import { parseProfile, profileSummary } from 'console.vpn-profile';
import { readClientLink, readClientRuntime } from 'console.vpn-client-status';

const root = '/etc/console-vpn';
// 客户端 management 端口固定在本机回环：只给 console 页面读链路状态用。
// 7505 是 OpenVPN 示例里常用的端口，避开它并放在高位段，减少与其它插件冲突。
const CLIENT_MANAGEMENT_PORT = 17655;
const CLIENT_STATUS_INTERVAL = 5;
function managementPort() { return CLIENT_MANAGEMENT_PORT; }
function statusInterval() { return CLIENT_STATUS_INTERVAL; }
function fail(message) { die(message + '\n'); }
function validName(name) { return type(name) == 'string' && !!match(name, /^[A-Za-z0-9_-]{1,48}$/); }
function validIPv4(value) {
	const m = type(value) == 'string' && match(value, /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
	if (!m) return false;
	for (let i = 1; i <= 4; i++) if (+m[i] > 255 || (length(m[i]) > 1 && substr(m[i], 0, 1) == '0')) return false;
	return true;
}
function ipNumber(text) { let n = 0; for (let part in split(text, '.')) n = n * 256 + +part; return n; }
function ipText(n) { return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255); }
function subnet(text, label) {
	const m = type(text) == 'string' && match(text, /^([^/]+)\/(\d{1,2})$/);
	if (!m || !validIPv4(m[1]) || +m[2] < 1 || +m[2] > 30) fail(label + '须为有效 IPv4 网段，例如 192.168.2.0/24');
	const bits = +m[2]; let size = 1;
	for (let i = bits; i < 32; i++) size *= 2;
	const start = int(ipNumber(m[1]) / size) * size;
	return { start, end: start + size - 1, prefix: bits, network: ipText(start), mask: ipText(4294967296 - size), text: ipText(start) + '/' + bits };
}
function overlaps(a, b) { return a.start <= b.end && b.start <= a.end; }
// 本机所有直连网段：客户端若接受覆盖这些网段的推送路由，会把路由器自身的 LAN 流量引进隧道。
function localSubnets() {
	const result = [], seen = {};
	const output = popen('/sbin/ip -4 route show 2>/dev/null')?.read?.('all') || popen('/usr/sbin/ip -4 route show 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const text = trim(line);
		if (text == '' || index(text, 'scope link') < 0) continue;
		const cidr = split(text, /\s+/)[0];
		const m = match(cidr, /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})$/);
		if (!m) continue;
		const bits = +m[2];
		if (bits < 8 || bits > 30) continue;
		const lan = subnet(m[1] + '/' + bits, '本机网段');
		if (seen[lan.text]) continue;
		seen[lan.text] = true;
		push(result, { network: lan.network, mask: lan.mask, text: lan.text });
	}
	return result;
}
// 对端内网：本机作为客户端连出去时，隧道对端（例如 C）宣告给我们的网段。
// 服务端启用时必须把这些网段随本机 LAN 一起推送，否则接入的 B 设备只拿到本机
// LAN 的路由，发往对端内网的报文在 B 上就被送到默认网关，根本进不了隧道。
// 隧道接口自身的直连网段（proto kernel）跳过：那是 cvpnc 的地址段，不是对端内网。
// 注意：ucode 不提升模块级函数声明，这里的读写只能依赖已导入的 fs 接口，
// 不能调用文件后面才定义的 readJson / writeAtomic。
function peerRouteCache() { return root + '/peer-routes.json'; }
function tunnelRoutes() {
	const result = [], seen = {};
	const output = popen('/sbin/ip -4 route show 2>/dev/null')?.read?.('all') || popen('/usr/sbin/ip -4 route show 2>/dev/null')?.read?.('all') || '';
	for (let line in split(output, '\n')) {
		const text = trim(line);
		if (text == '' || index(text, 'dev cvpnc') < 0 || index(text, 'proto kernel') >= 0) continue;
		const cidr = split(text, /\s+/)[0];
		const m = match(cidr, /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\/(\d{1,2})$/);
		if (!m) continue;
		const bits = +m[2];
		if (bits < 8 || bits > 30) continue;
		const lan = subnet(m[1] + '/' + bits, '对端网段');
		if (seen[lan.text]) continue;
		seen[lan.text] = true;
		push(result, { network: lan.network, mask: lan.mask, text: lan.text, start: lan.start, end: lan.end });
	}
	// 链路此刻恰好断开时隧道路由会消失。若直接用空列表重算，已下发给 B 的对端路由
	// 会被一起清掉，B 就会突然访问不到 C 的内网。这里退回最近一次探测到的结果。
	if (!length(result)) {
		let cached = null;
		try { cached = json(readfile(peerRouteCache())); } catch (e) { cached = null; }
		for (let item in (type(cached) == 'array' ? cached : [])) {
			const lan = subnet(item, '对端网段');
			if (seen[lan.text]) continue;
			seen[lan.text] = true;
			push(result, { network: lan.network, mask: lan.mask, text: lan.text, start: lan.start, end: lan.end });
		}
	}
	return result;
}
function saveTunnelRoutes(routes) {
	const texts = map(routes, r => r.text);
	if (!length(texts)) return;
	const tmp = peerRouteCache() + '.new';
	const fd = open(tmp, 'w');
	if (!fd) return;
	chmod(tmp, 0600);
	fd.write(sprintf('%J\n', texts));
	fd.close();
	rename(tmp, peerRouteCache());
}
function ensureDir(path) { mkdir(path, 0700); chmod(path, 0700); }
function fileExists(path) { return stat(path) != null; }
function removeFile(path) { if (fileExists(path)) unlink(path); }
function writeAtomic(path, value, mode) {
	const tmp = path + '.new';
	const fd = open(tmp, 'w');
	if (!fd) fail('无法创建配置文件');
	chmod(tmp, mode ?? 0600);
	if (fd.write(value) == false) { fd.close(); unlink(tmp); fail('无法写入配置文件'); }
	fd.close();
	if (!rename(tmp, path)) { unlink(tmp); fail('无法保存配置文件'); }
	chmod(path, mode ?? 0600);
}
function readJson(path, fallback) {
	const text = readfile(path);
	if (text == null) return fallback;
	try { return json(text); } catch (e) { fail('VPN 配置文件损坏：' + path); }
}
function run(args) { return system(args) == 0; }
function syncAutostart() {
	const action = fileExists(root + '/server.enabled') || fileExists(root + '/client.enabled') ? 'enable' : 'disable';
	if (!run(['/etc/init.d/console-openvpn', action])) fail('更新 VPN 开机启动状态失败');
}
function uci(args) {
	const command = ['/sbin/uci', '-c', '/etc/config'];
	for (let arg in args) push(command, arg);
	return run(command);
}
function uciSectionExists(section) {
	return length(trim(popen('/sbin/uci -c /etc/config get firewall.' + section + ' 2>/dev/null')?.read?.('all') || '')) > 0;
}
function checkNoPendingFirewallChanges() {
	const pending = trim(popen('/sbin/uci -c /etc/config changes firewall 2>/dev/null')?.read?.('all') || '');
	if (pending) fail('检测到尚未应用的防火墙配置；请先保存或撤销其他防火墙修改，再重试');
}
function endpointValid(host) {
	if (validIPv4(host)) return true;
	if (type(host) != 'string' || !length(host) || length(host) > 253 || !match(host, /^[A-Za-z0-9.-]+$/)) return false;
	for (let label in split(host, '.')) if (!length(label) || length(label) > 63 || !match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/)) return false;
	return true;
}
function validateServer(input, accounts) {
	if (type(input) != 'object') fail('服务端配置格式无效');
	const vpn = subnet(input.vpnSubnet, 'VPN 网段');
	if(type(input.localSubnet)!='string'||length(input.localSubnet)>4096)fail('服务端内网配置无效');
	const routes=filter(split(trim(input.localSubnet),/[ \t\r\n,;]+/),v=>length(v));
	if(!length(routes)||length(routes)>64)fail('请填写1至64条服务端内网推送路由');
	let lans=[];for(let route in routes){const lan=subnet(route,'服务端内网');if(!length(filter(lans,l=>l.text==lan.text)))push(lans,lan);}
	const lan=lans[0];
	if (vpn.prefix > 24) fail('VPN 网段至少使用 /24（256 个地址）');
	if (length(filter(lans,l=>overlaps(vpn,l)))) fail('VPN 网段与服务端内网重叠');
	const port = +input.port;
	if (port < 1 || port > 65535 || int(port) != port) fail('端口须为 1 至 65535 的整数');
	if (input.protocol != 'udp' && input.protocol != 'tcp-server') fail('服务端协议无效');
	if (input.endpoint && !endpointValid(input.endpoint)) fail('客户端连接地址无效');
	if (type(input.allowWan) != 'bool') fail('WAN 入站选项无效');
	const names = {}, addresses = {}, peers = [];
	for (let account in accounts) {
		if (!account.enabled) continue;
		if (!validName(account.username) || names[account.username]) fail('启用账号重复或名称无效');
		names[account.username] = true;
		if (account.address) {
			if (!validIPv4(account.address)) fail('账号 ' + account.username + ' 的固定 VPN IP 无效');
			const n = ipNumber(account.address);
			if (n <= vpn.start + 1 || n >= vpn.end) fail('账号 ' + account.username + ' 的固定 VPN IP 必须在客户端地址池内');
			if (addresses[account.address]) fail('启用账号固定 VPN IP 重复：' + account.address);
			addresses[account.address] = true;
		}
		if (account.remoteSubnet) {
			const peer = subnet(account.remoteSubnet, '账号 ' + account.username + ' 的客户端内网');
			if (overlaps(peer, vpn) || length(filter(lans,l=>overlaps(peer,l)))) fail('账号 ' + account.username + ' 的客户端内网网段与已有网段重叠');
			for (let other in peers) if (overlaps(peer, other)) fail('账号 ' + account.username + ' 的客户端内网网段与已有网段重叠');
			push(peers, peer);
		}
	}
	return { vpn, lan, lans, port, peers };
}
function serverConfig(input, accounts) {
	const v = validateServer(input, accounts), proto = input.protocol;
	const active = filter(accounts, a => a.enabled);
	const lines = [
		'port ' + v.port, 'proto ' + proto, 'dev cvpns', 'dev-type tun', 'topology subnet',
		'server ' + v.vpn.network + ' ' + v.vpn.mask, 'ca ' + root + '/pki/ca.crt',
		'cert ' + root + '/pki/issued/server.crt', 'key ' + root + '/pki/private/server.key', 'dh none',
		'verify-client-cert none', 'username-as-common-name', 'script-security 2',
		'auth-user-pass-verify /usr/libexec/console-vpn-auth via-file',
		'client-config-dir ' + root + '/ccd', 'ccd-exclusive', 'client-to-client',
		'duplicate-cn', 'max-clients 99', 'client-connect /usr/libexec/console-vpn-session', 'client-disconnect /usr/libexec/console-vpn-session',
		'keepalive 10 60', 'persist-key', 'persist-tun', 'writepid /var/run/console-vpn/server.pid',
		'status /var/run/console-vpn/server.status 10', 'verb 3', 'mute 10',
		'tls-version-min 1.2', 'allow-compression no'
	];
	for (let lan in v.lans) push(lines, 'push "route ' + lan.network + ' ' + lan.mask + '"');
	// 本机作为客户端接入的另一条内网（例如 C 的内网）：B 要同时访问两侧，
	// 必须把对端网段一并推送下去，否则 B 只有本机 LAN 的路由。
	const peerRoutes = tunnelRoutes();
	saveTunnelRoutes(peerRoutes);
	for (let tunnel in peerRoutes) {
		if (overlaps(tunnel, v.vpn)) continue;
		if (length(filter(v.lans, l => overlaps(tunnel, l)))) continue;
		if (length(filter(v.peers, p => overlaps(tunnel, p)))) continue;
		push(lines, 'push "route ' + tunnel.network + ' ' + tunnel.mask + '"');
	}
	for (let peer in v.peers) push(lines, 'route ' + peer.network + ' ' + peer.mask);
	const ccd = {};
	for (let account in active) {
		const rules = [];
		if (account.address) push(rules, 'ifconfig-push ' + account.address + ' ' + v.vpn.mask);
		if (account.remoteSubnet) {
			const ownPeer = subnet(account.remoteSubnet, '客户端内网');
			push(rules, 'iroute ' + ownPeer.network + ' ' + ownPeer.mask);
		}
		for (let peer in v.peers) {
			if (account.remoteSubnet && peer.text == subnet(account.remoteSubnet, '客户端内网').text) continue;
			push(rules, 'push "route ' + peer.network + ' ' + peer.mask + '"');
		}
		ccd[account.username] = join('\n', rules) + '\n';
	}
	return { config: join('\n', lines) + '\n', ccd, validation: v };
}
function pkiReady() { return fileExists(root + '/pki/ca.crt') && fileExists(root + '/pki/issued/server.crt') && fileExists(root + '/pki/private/server.key'); }
function ensurePki() {
	ensureDir(root); ensureDir(root + '/pki');
	if (!fileExists(root + '/pki/pkiindex.txt') && !fileExists(root + '/pki/index.txt')) {
		if (run(['/bin/sh', '-c', 'EASYRSA_PKI=/etc/console-vpn/pki EASYRSA_BATCH=1 easyrsa init-pki']) == false) fail('Easy-RSA 初始化失败');
	}
	if (!fileExists(root + '/pki/ca.crt') && run(['/bin/sh', '-c', 'EASYRSA_PKI=/etc/console-vpn/pki EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenWrt Console VPN CA" easyrsa build-ca nopass']) == false) fail('生成 VPN 根证书失败');
	if (!fileExists(root + '/pki/issued/server.crt') || !fileExists(root + '/pki/private/server.key')) {
		if (run(['/bin/sh', '-c', 'EASYRSA_PKI=/etc/console-vpn/pki EASYRSA_BATCH=1 EASYRSA_REQ_CN="OpenWrt Console VPN Server" easyrsa build-server-full server nopass']) == false) fail('生成 VPN 服务端证书失败');
	}
	if (!pkiReady()) fail('VPN 根证书或服务端证书缺失');
	chmod(root + '/pki', 0700); chmod(root + '/pki/private/ca.key', 0600); chmod(root + '/pki/private/server.key', 0600);
}
function updateFirewall(kind, enabled, input) {
	const suffix = kind == 'server' ? 'server' : 'client', device = kind == 'server' ? 'cvpns' : 'cvpnc';
	const zone = 'console_vpn_' + suffix + '_zone', to = 'console_vpn_' + suffix + '_to_lan', from = 'console_vpn_' + suffix + '_from_lan';
	const rules = ['console_vpn_' + suffix + '_lan_input', 'console_vpn_' + suffix + '_wan_input'];
	const wanForward = 'console_vpn_' + suffix + '_to_wan';
	// 服务端还要把 B 的流量送到本机作为客户端接入的那条隧道（console_vpn_client zone）。
	// 掩码是必需的：对端（C）只认本机 cvpnc 地址 10.7.7.4，不认识 10.8.0.0/24，
	// 不加 NAT 时 B 到 C 内网的报文能出去但回不来，表现为能访问 LAN 却打不开 C 内网。
	const toClient = 'console_vpn_server_to_client', clientZone = 'console_vpn_client';
	const natSection = 'console_vpn_server_tunnel_nat';
	// 本机没有启用客户端（没有 cvpnc 隧道与 console_vpn_client zone）时不能引用该 zone：
	// fw4 会因目的 zone 不存在而告警，且这种转发本身没有意义。
	// 这里直接读 client.json 而不是调用 currentClient()：后者定义在文件更靠后的位置，
	// 函数提升不覆盖 ucode 的模块作用域，提前引用会报 undeclared variable。
	const linkPeer = kind == 'server' && readJson(root + '/client.json', { enabled: false }).enabled == true;
	const forwards = linkPeer ? [to, from, wanForward, toClient] : [to, from, wanForward];
	const nats = linkPeer ? [natSection] : [];
	checkNoPendingFirewallChanges();
	if (!enabled) {
		for (let key in [zone, ...rules, ...forwards, ...nats]) if (uciSectionExists(key)) uci(['delete', 'firewall.' + key]);
		if (!uci(['commit', 'firewall'])) { uci(['revert', 'firewall']); fail('清理 OpenVPN 防火墙配置失败'); }
		if (!run(['/etc/init.d/firewall', 'reload'])) fail('重新载入防火墙失败');
		return;
	}
	const vpnZone = 'console_vpn_' + suffix;
	for (let key in [zone, ...rules, ...forwards, ...nats]) if (uciSectionExists(key)) uci(['delete', 'firewall.' + key]);
	function create(section, sectionType) { if (!uci(['set', 'firewall.' + section + '=' + sectionType])) { uci(['revert', 'firewall']); fail('创建 OpenVPN 防火墙 section 失败'); } }
	function set(section, key, value) { if (!uci(['set', 'firewall.' + section + '.' + key + '=' + value])) { uci(['revert', 'firewall']); fail('写入 OpenVPN 防火墙配置失败'); } }
	// VPN 客户端是已认证的受信对端：必须放行其到本机（DNS、LuCI、SSH、ping）的入站，
	// 否则客户端能访问 LAN 却打不开 192.168.1.1。转发两侧已由 forwarding 单独控制。
	create(zone, 'zone'); set(zone, 'name', vpnZone); set(zone, 'input', 'ACCEPT'); set(zone, 'output', 'ACCEPT'); set(zone, 'forward', 'ACCEPT');
	if (!uci(['add_list', 'firewall.' + zone + '.device=' + device])) { uci(['revert', 'firewall']); fail('写入 OpenVPN 防火墙接口失败'); }
	// 隧道封装会占用额外包头，fw4 需要为穿越该区域的流量做 MSS 钳制，避免大包被丢弃导致网页打不开。
	set(zone, 'mtu_fix', '1');
	create(to, 'forwarding'); set(to, 'src', 'lan'); set(to, 'dest', vpnZone);
	create(from, 'forwarding'); set(from, 'src', vpnZone); set(from, 'dest', 'lan');
	// Let clients opt into full-tunnel routing; WAN masquerading provides return NAT.
	if(kind=='server'){create(wanForward,'forwarding');set(wanForward,'src',vpnZone);set(wanForward,'dest','wan');}
	// LAN 与对端内网的返回流量由 conntrack 放行，但"服务端 zone → 客户端 zone"这一跳
	// 必须先有 forwarding，否则 B 发往 C 内网的报文在 forward 链被默认 drop。
	if(kind=='server'&&linkPeer){create(toClient,'forwarding');set(toClient,'src',vpnZone);set(toClient,'dest',clientZone);}
	const natCount = length(nats);
	for (let i = 0; i < natCount; i++) {
		create(natSection,'nat'); set(natSection,'name','OpenVPN server to peer tunnel');
		set(natSection,'src',clientZone); set(natSection,'family','ipv4');
		set(natSection,'src_ip',input.vpnSubnet); set(natSection,'target','masquerade');
	}
	const protocol = kind == 'server' ? input.protocol : null;
	const port = kind == 'server' ? '' + input.port : '';
	const ruleCount = kind == 'server' ? 1 + (input.allowWan ? 1 : 0) : 0;
	for (let i = 0; i < ruleCount; i++) {
		const section = rules[i], source = i == 0 ? 'lan' : 'wan';
		create(section, 'rule'); set(section, 'name', 'OpenVPN ' + suffix + ' ' + source);
		set(section, 'src', source); set(section, 'proto', protocol == 'tcp-server' ? 'tcp' : 'udp'); set(section, 'dest_port', port); set(section, 'family', 'ipv4'); set(section, 'target', 'ACCEPT');
	}
	if (!uci(['commit', 'firewall'])) { uci(['revert', 'firewall']); fail('保存 OpenVPN 防火墙配置失败'); }
	if (!run(['/etc/init.d/firewall', 'reload'])) fail('重新载入防火墙失败');
}
function syncCcd(result) {
	ensureDir(root); ensureDir(root + '/ccd');
	for (let filename in lsdir(root + '/ccd') || []) if (match(filename, /^[A-Za-z0-9_-]{1,48}$/)) unlink(root + '/ccd/' + filename);
	for (let name, value in result.ccd) writeAtomic(root + '/ccd/' + name, value, 0600);
}
function currentServer() { return readJson(root + '/server.json', { enabled: false, vpnSubnet: '10.8.0.0/24', localSubnet: '192.168.1.0/24', port: 1194, protocol: 'udp', endpoint: '', allowWan: false }); }
function saveServer(input) {
	const normalized = { enabled: input.enabled == true, vpnSubnet: input.vpnSubnet, localSubnet: input.localSubnet, port: +input.port, protocol: input.protocol, endpoint: input.endpoint || '', allowWan: input.allowWan == true };
	const accounts = listAccounts(), result = serverConfig(normalized, accounts);
	normalized.localSubnet=join('\n',map(result.validation.lans,l=>l.text));
	ensureDir(root);
	if (normalized.enabled) ensurePki();
	syncCcd(result);
	writeAtomic(root + '/server.conf', result.config, 0600);
	writeAtomic(root + '/server.json', sprintf('%J\n', normalized), 0600);
	if (!normalized.enabled) unlink(root + '/server.enabled');
	updateFirewall('server', normalized.enabled, normalized);
	if (normalized.enabled) writeAtomic(root + '/server.enabled', '1\n', 0600);
	syncAutostart();
	if (!run(['/etc/init.d/console-openvpn', 'restart'])) fail('VPN 服务重启失败；请检查系统日志');
	return normalized;
}
function clientDefaults() {
	return { enabled: false, host: '', port: 1194, protocol: 'udp', username: '', password: '', localSubnet: '192.168.1.0/24', ca: '', source: 'manual', redirectGateway: false, clientCert: false };
}
function currentClient() { return readJson(root + '/client.json', clientDefaults()); }
// 客户端的 udp/tcp-client 一律规范化为 udp4/tcp4-client。
// 服务端域名同时有 A 与 AAAA 记录时，裸 udp 会随机尝试 IPv6，
// 表现为 write UDPv6: Network unreachable，链路无法建立。
function normalizeClientProtocol(value) {
	if (value == 'tcp-client' || value == 'tcp4-client') return 'tcp4-client';
	return 'udp4';
}
// 客户端密码不再限制长度与字符集，只排除会破坏 auth 文件结构（用户名\n密码\n）的字节。
function validClientPassword(value) {
	if (type(value) != 'string' || !length(value)) return false;
	return index(value, '\n') < 0 && index(value, '\r') < 0 && index(value, chr(0)) < 0;
}
function validateClient(input) {
	if (!endpointValid(input.host)) fail('服务端地址须为 IPv4 或有效域名');
	const port = +input.port;
	if (port < 1 || port > 65535 || int(port) != port) fail('端口须为 1 至 65535 的整数');
	if (input.protocol != 'udp' && input.protocol != 'udp4' && input.protocol != 'tcp-client' && input.protocol != 'tcp4-client') fail('客户端协议无效');
	// 统一规范化为强制 IPv4：服务端域名常常同时返回 AAAA 记录，
	// 用裸 udp/tcp-client 会让 OpenVPN 尝试 IPv6 并报 Network unreachable。
	const protocol = normalizeClientProtocol(input.protocol);
	if (!validName(input.username)) fail('账号名称无效');
	if (type(input.password) != 'string') fail('客户端密码格式无效');
	if (length(input.password) && !validClientPassword(input.password)) fail('客户端密码不能包含换行或空字符');
	const lan = subnet(input.localSubnet, '客户端内网');
	if (type(input.ca) != 'string' || length(input.ca) < 100 || length(input.ca) > 32768 || index(input.ca, '-----BEGIN CERTIFICATE-----') < 0 || index(input.ca, '-----END CERTIFICATE-----') < 0 || index(input.ca, 'PRIVATE KEY') >= 0) fail('请填写有效的服务端 CA 证书');
	return { port, lan, protocol };
}
function hasOption(options, name) {
	for (let option in options) if (option == name || index(option, name + ' ') == 0) return true;
	return false;
}
// 对外暴露的客户端设置：不包含密码。
function publicClient(config) {
	return {
		enabled: config.enabled, host: config.host, port: config.port, protocol: config.protocol,
		username: config.username, localSubnet: config.localSubnet, ca: config.ca || '',
		source: config.source || 'manual', redirectGateway: config.redirectGateway ? true : false,
		clientCert: config.clientCert ? true : false,
		compression: config.compression || '', remoteCertTls: config.remoteCertTls == true,
		verifyName: config.verifyName || '', routeNopull: config.routeNopull == true
	};
}
// 生成客户端配置：只写入本功能自己的字段与经过校验的配置项。
function clientConfigText(config) {
	const lines = [
		'client', 'dev cvpnc', 'dev-type tun', 'proto ' + config.protocol,
		'remote ' + config.host + ' ' + config.port, 'nobind', 'persist-key', 'persist-tun'
	];
	// 服务端证书校验。CA 校验（ca 指令）始终生效，保证对端由受信 CA 签发。
	// 注意：remote-cert-tls server 会同时要求 EKU 与 Key Usage 扩展，
	// 而 iKuai 等设备的服务端证书两者都没有，硬开会让握手在 VERIFY 阶段失败
	// （VERIFY KU ERROR / VERIFY EKU ERROR），链路完全起不来。
	// 因此这里优先用 verify-x509-name 锚定对端主体名（不含扩展要求），
	// 只有拿不到主体名时才退回 remote-cert-tls 的显式配置。
	if (config.verifyName) push(lines, 'verify-x509-name "' + config.verifyName + '" name');
	else if (config.remoteCertTls) push(lines, 'remote-cert-tls server');
	if (config.useAuth) push(lines, 'auth-user-pass ' + root + '/client/auth', 'auth-nocache');
	push(lines, 'ca ' + root + '/client/ca.crt');
	if (config.cert) push(lines, 'cert ' + root + '/client/client.crt');
	if (config.key) push(lines, 'key ' + root + '/client/client.key');
	if (config.tlsAuth) push(lines, 'tls-auth ' + root + '/client/tls-auth.key ' + config.keyDirection);
	if (config.tlsCrypt) push(lines, 'tls-crypt ' + root + '/client/tls-crypt.key');
	// 忽略覆盖本机直连网段的推送路由，避免隧道把路由器自身的 LAN 流量带走。
	// 配置里写了 route-nopull 时服务端不会推送任何路由，本机直连网段自然也不会被覆盖，
	// 此时再下发 pull-filter ignore 只会把用户在配置里显式声明的静态路由一并丢掉。
	if (config.routeNopull != true) for (let filter in config.pullIgnore || []) push(lines, 'pull-filter ignore "' + filter + '"');
	for (let option in config.extra) push(lines, option);
	if (config.redirectGateway) push(lines, 'redirect-gateway def1 bypass-dhcp');
	push(lines, 'writepid /var/run/console-vpn/client.pid', 'verb 3', 'mute 10');
	// 链路状态采集：management 提供真实连接状态机，status 提供累计收发字节。
	// 两者都只监听/写入本机，不对外暴露；页面读不到时降级为"状态未知"而不报错。
	push(lines, 'management 127.0.0.1 ' + managementPort(), 'management-log-cache 50');
	push(lines, 'status /var/run/console-vpn/client.status ' + statusInterval());
	if (!hasOption(config.extra, 'tls-version-min')) push(lines, 'tls-version-min 1.2');
	// 压缩：固件已编译 LZO 支持，服务端启用 comp-lzo 时必须原样协商，
	// 否则收到的 LZO 压缩帧无法解压，写入 tun 会报 Invalid argument、隧道不通。
	//  - compression = 'yes'  → comp-lzo yes（真正收发压缩帧）
	//  - compression = 'stub' → compress stub-v2（仅协商标记，不解压）
	//  - compression = 'no'   → allow-compression no（显式拒绝压缩）
	if (config.compression == 'yes') push(lines, 'comp-lzo yes');
	else if (config.compression == 'stub') push(lines, 'compress stub-v2');
	else if (!hasOption(config.extra, 'allow-compression') && !hasOption(config.extra, 'compress') && !hasOption(config.extra, 'comp-lzo')) push(lines, 'allow-compression no');
	// 显式数据算法：老服务端只支持 CBC 或在协商后才定算法时，靠这里对齐。
	if (config.dataCiphers && !hasOption(config.extra, 'data-ciphers')) push(lines, 'data-ciphers ' + config.dataCiphers);
	return join('\n', lines) + '\n';
}
function installCa(text) {
	const pendingCa = root + '/client/ca.crt.pending';
	writeAtomic(pendingCa, text + (substr(text, -1) == '\n' ? '' : '\n'), 0600);
	const constraints = trim(popen('/usr/bin/openssl x509 -in /etc/console-vpn/client/ca.crt.pending -noout -ext basicConstraints')?.read?.('all') || '');
	if (!run(['/usr/bin/openssl', 'verify', '-CAfile', pendingCa, pendingCa]) || index(constraints, 'CA:TRUE') < 0) { unlink(pendingCa); fail('服务端 CA 证书无效、不是 CA 或已经过期'); }
	if (!rename(pendingCa, root + '/client/ca.crt')) { unlink(pendingCa); fail('无法保存服务端 CA 证书'); }
	chmod(root + '/client/ca.crt', 0600);
}
// 需要忽略的推送路由：本机直连网段与本页配置的 LAN 网段。
function pullIgnoreList(localSubnet) {
	const filters = [], seen = {};
	function add(network, mask) {
		const text = 'route ' + network + ' ' + mask;
		if (seen[text]) return;
		seen[text] = true;
		push(filters, text);
	}
	for (let item in localSubnets()) add(item.network, item.mask);
	if (type(localSubnet) == 'string' && length(localSubnet)) {
		const lan = subnet(localSubnet, '客户端内网');
		add(lan.network, lan.mask);
	}
	return filters;
}
function installClient(config) {
	ensureDir(root); ensureDir(root + '/client');
	config.pullIgnore = pullIgnoreList(config.localSubnet);
	installCa(config.ca);
	if (config.cert) writeAtomic(root + '/client/client.crt', config.cert + '\n', 0600); else removeFile(root + '/client/client.crt');
	if (config.key) writeAtomic(root + '/client/client.key', config.key + '\n', 0600); else removeFile(root + '/client/client.key');
	if (config.tlsAuth) writeAtomic(root + '/client/tls-auth.key', config.tlsAuth + '\n', 0600); else removeFile(root + '/client/tls-auth.key');
	if (config.tlsCrypt) writeAtomic(root + '/client/tls-crypt.key', config.tlsCrypt + '\n', 0600); else removeFile(root + '/client/tls-crypt.key');
	if (config.useAuth) writeAtomic(root + '/client/auth', config.username + '\n' + config.password + '\n', 0600); else removeFile(root + '/client/auth');
	writeAtomic(root + '/client/client.conf', clientConfigText(config), 0600);
	const stored = {
		enabled: true, host: config.host, port: config.port, protocol: config.protocol,
		username: config.useAuth ? config.username : '', localSubnet: config.localSubnet, ca: config.ca,
		source: config.source || 'manual', redirectGateway: config.redirectGateway ? true : false,
		clientCert: config.cert ? true : false, remoteCertTls: config.remoteCertTls == true,
		verifyName: config.verifyName || '',
		compression: config.compression || '', routeNopull: config.routeNopull == true
	};
	writeAtomic(root + '/client.json', sprintf('%J\n', stored), 0600);
	updateFirewall('client', true, stored);
	writeAtomic(root + '/client.enabled', '1\n', 0600);
	syncAutostart();
	if (!run(['/etc/init.d/console-openvpn', 'restart'])) fail('VPN 客户端重启失败；请检查系统日志');
	return stored;
}
function saveClient(input) {
	const checked = validateClient(input);
	// 手填表单没有压缩/证书校验选项：沿用已保存的值。否则会把导入时得到的
	// comp-lzo 覆盖成 allow-compression no，数据面直接断掉；
	// 也不能硬开 remote-cert-tls（缺 KU/EKU 的服务端会 VERIFY 失败）。
	const existing = currentClient();
	const config = {
		enabled: true, host: input.host, port: checked.port, protocol: checked.protocol,
		username: input.username, password: input.password, localSubnet: checked.lan.text, ca: input.ca,
		source: 'manual', redirectGateway: false, remoteCertTls: existing.remoteCertTls == true, useAuth: true,
		cert: '', key: '', tlsAuth: '', tlsCrypt: '', keyDirection: 1, extra: [],
		verifyName: existing.verifyName || '',
		compression: existing.compression || '', routeNopull: existing.routeNopull == true
	};
	ensureDir(root); ensureDir(root + '/client');
	if (!config.password) {
		const auth = readfile(root + '/client/auth');
		const saved = auth == null ? [] : split(auth, '\n');
		if (existing.username != config.username || !saved[1]) fail('请输入客户端账号密码');
		config.password = saved[1];
	}
	const stored = installClient(config);
	return publicClient(stored);
}
// 解析 .ovpn 配置文件但不落盘，用于页面预览。
function inspectProfile(text) { return profileSummary(parseProfile(text)); }
// 直接导入 .ovpn 配置文件：解析、落盘并启动客户端。
function saveClientFromProfile(input) {
	const parsed = parseProfile(input.profile), summary = profileSummary(parsed);
	const host = input.host ? input.host : parsed.host;
	const port = input.port ? +input.port : parsed.port;
	const protocolRaw = input.protocol ? input.protocol : parsed.protocol;
	if (!endpointValid(host)) fail('服务端地址须为 IPv4 或有效域名');
	if (port < 1 || port > 65535 || int(port) != port) fail('端口须为 1 至 65535 的整数');
	if (protocolRaw != 'udp' && protocolRaw != 'udp4' && protocolRaw != 'tcp-client' && protocolRaw != 'tcp4-client') fail('客户端协议无效');
	// 同 validateClient：强制 IPv4，避免域名 AAAA 记录导致的 IPv6 不可达。
	const protocol = normalizeClientProtocol(protocolRaw);
	const lan = subnet(input.localSubnet ? input.localSubnet : currentClient().localSubnet, '客户端内网');
	const useAuth = summary.requiresCredentials;
	let username = input.username || '', password = input.password || '';
	if (useAuth) {
		if (!validName(username)) fail('请填写客户端账号');
		if (!password) {
			const existing = currentClient(), auth = readfile(root + '/client/auth');
			const saved = auth == null ? [] : split(auth, '\n');
			if (existing.username != username || !saved[1]) fail('请输入客户端账号密码');
			password = saved[1];
		}
		if (!validClientPassword(password)) fail('客户端密码不能包含换行或空字符');
	}
	const config = {
		enabled: true, host, port, protocol, username, password, localSubnet: lan.text, ca: parsed.ca,
		source: 'profile', redirectGateway: input.redirectGateway == true, remoteCertTls: parsed.remoteCertTls,
		useAuth, cert: parsed.cert, key: parsed.key, tlsAuth: parsed.tlsAuth, tlsCrypt: parsed.tlsCrypt,
		keyDirection: parsed.keyDirection, extra: parsed.extra,
		compression: parsed.compression || '', dataCiphers: parsed.dataCiphers || '', routeNopull: parsed.routeNopull == true
	};
	const stored = installClient(config);
	return { settings: publicClient(stored), summary };
}
function stopClient() {
	const config = currentClient(); config.enabled = false;
	writeAtomic(root + '/client.json', sprintf('%J\n', config), 0600); removeFile(root + '/client.enabled');
	updateFirewall('client', false, config);
	syncAutostart();
	if (!run(['/etc/init.d/console-openvpn', 'restart'])) fail('VPN 客户端断开失败');
	return publicClient(config);
}
function syncServerAccounts() {
	const config = currentServer();
	if (!config.enabled) return { restarted: false };
	const result = serverConfig(config, listAccounts());
	syncCcd(result); writeAtomic(root + '/server.conf', result.config, 0600);
	if (!run(['/etc/init.d/console-openvpn', 'restart'])) fail('VPN 服务重启失败；请检查系统日志');
	return { restarted: true };
}
function exportClientProfile(username) {
	if (!validName(username)) fail('账号名称无效');
	const config = currentServer();
	if (!config.enabled) fail('请先启用服务端');
	if (!config.endpoint) fail('请先填写服务端公网 IP 或 DDNS 域名');
	const result = serverConfig(config, listAccounts());
	if (!result.ccd[username]) fail('此账号未启用或不存在');
	const ca = readfile(root + '/pki/ca.crt');
	if (!ca) fail('请先启用服务端并生成根证书');
	const proto = config.protocol == 'tcp-server' ? 'tcp-client' : 'udp';
	// Interactive desktop clients need credentials again at TLS renegotiation.
	// Retain them in process memory (OpenVPN default), never embed them in the profile.
	return { filename: 'openwrt-' + username + '.ovpn', content: join('\n', [
		'client', 'dev tun', 'proto ' + proto, 'remote ' + config.endpoint + ' ' + config.port,
		'nobind', 'persist-key', 'persist-tun', 'remote-cert-tls server', 'auth-user-pass',
		'verb 3', '<ca>', trim(ca), '</ca>', ''
	]) };
}
function exportCa() {
	const ca = readfile(root + '/pki/ca.crt');
	if (!ca) fail('请先启用服务端并生成根证书');
	return { filename: 'openwrt-vpn-ca.crt', content: ca };
}
function status() {
	const server = currentServer(), client = currentClient();
	function running(path, configPath) {
		const pid = trim(readfile(path) || '');
		if (!match(pid, /^\d+$/) || !fileExists('/proc/' + pid)) return false;
		const cmdline = readfile('/proc/' + pid + '/cmdline') || '';
		return index(cmdline, configPath) >= 0;
	}
	return { server: { configured: server.enabled, running: running('/var/run/console-vpn/server.pid', root + '/server.conf'), endpoint: server.endpoint, port: server.port, protocol: server.protocol, allowWan: server.allowWan }, client: { configured: client.enabled, running: running('/var/run/console-vpn/client.pid', root + '/client/client.conf'), host: client.host, port: client.port, protocol: client.protocol, username: client.username, localSubnet: client.localSubnet, source: client.source || 'manual', redirectGateway: client.redirectGateway ? true : false, clientCert: client.clientCert ? true : false } };
}
// 运行时目录：pid / status / management 都固定在这里。
function runtimeDirectory() { return '/var/run/console-vpn'; }
// 客户端链路状态：以进程实际是否在跑为准（而不是 enabled 标记文件），
// 否则"已启用但进程未运行"和"运行中但配置被标记停用"都会误判成未连接。
function clientLink() {
	const client = currentClient(), runtime = readClientRuntime(runtimeDirectory());
	return readClientLink(runtimeDirectory(), client, runtime.running ? managementPort() : 0);
}
export { currentServer, saveServer, currentClient, saveClient, stopClient, exportClientProfile, exportCa, status, validateServer, validateClient, serverConfig, syncServerAccounts, fileExists, ensurePki, inspectProfile, saveClientFromProfile, clientConfigText, localSubnets, pullIgnoreList, clientLink, managementPort };
