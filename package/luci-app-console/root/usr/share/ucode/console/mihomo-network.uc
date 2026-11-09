// SPDX-License-Identifier: Apache-2.0
import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, open, chmod, rename, mkdir } from 'fs';
import { policy, nftPolicy } from 'console.mihomo-policy';
import { output,command } from 'console.security';
function fail(message) { die(message + '\n'); }
function write(path, text) {
	const f = open(path + '.new', 'w'); if (!f) fail('无法写入透明代理配置');
	chmod(path + '.new', 0600); const n = f.write(text); f.close();
	if (n != length(text) || !rename(path + '.new', path)) fail('无法保存透明代理配置');
}
function lanDevices() {
	const c = cursor(), names = [], devices = []; c.load('firewall');
	c.foreach('firewall', 'zone', z => {
		if (z.name != 'lan') return;
		for (let n in (type(z.network) == 'array' ? z.network : split(z.network || '', ' '))) if (n && index(names, n) < 0) push(names, n);
	});
	if (!length(names)) fail('未找到 LAN 防火墙区域');
	const bus = connect(); if (!bus) fail('无法读取内网接口');
	const dump = bus.call('network.interface', 'dump', {}); bus.disconnect();
	for (let i in (dump?.interface || [])) if (index(names, i.interface) >= 0 && i.up && match(i.l3_device || '', /^[A-Za-z0-9_.:-]{1,15}$/) && index(devices, i.l3_device) < 0) push(devices, i.l3_device);
	if (!length(devices)) fail('没有可接管的内网接口');
	return devices;
}
function vpnProxyEnabled(){try{return json(readfile('/etc/console-mihomo/vpn-proxy.json')||'{}').enabled===true;}catch(e){fail('OpenVPN代理开关配置损坏');}}
function networkConfig(config, devices, vpnEnabled) {
	devices=[...devices];if((vpnEnabled??vpnProxyEnabled())&&index(devices,'cvpns')<0)push(devices,'cvpns');
	config.ipv6 = true;
	// The router has no IPv6 WAN default route. Keep the local IPv6 listeners,
	// but make DNS answers and every configured proxy-server connection IPv4-only.
	for (let proxy in config.proxies || []) if (type(proxy) == 'object' && proxy.server) proxy['ip-version'] = 'ipv4';
	config.tun = { enable: true, device: 'cmihomo', stack: 'gvisor', mtu: 1500,
		'auto-route': false, 'auto-redirect': false, 'auto-detect-interface': true,
		'include-interface': devices, 'exclude-uid': [0], 'strict-route': false,
		'dns-mode': 'disabled', 'dns-hijack': ['any:53', 'tcp://any:53'],
		'route-exclude-address': ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7'],
		'inet6-address': ['fdfe:dcba:9876::1/126'], 'iproute2-table-index': 10410, 'iproute2-rule-index': 10410 };
	config.dns = { enable: true, listen: '[::]:1053', ipv6: false, 'enhanced-mode': 'redir-host',
		'default-nameserver': ['223.5.5.5', '119.29.29.29'],
		'proxy-server-nameserver': ['223.5.5.5', '119.29.29.29'],
		nameserver: ['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query'],
		'nameserver-policy': { '+.lan': '127.0.0.1:53', '+.arpa': '127.0.0.1:53' } };
	config.sniffer = { enable: true, 'force-dns-mapping': true, 'parse-pure-ip': true,
		sniff: { HTTP: { ports: [80, '8080-8880'], 'override-destination': true }, TLS: { ports: [443, 8443] }, QUIC: { ports: [443, 8443] } } };
	return config;
}
function prepare() {
	const devices = lanDevices(), config = json(readfile('/etc/console-mihomo/config.json'));
	networkConfig(config, devices);
	write('/etc/console-mihomo/config.json', sprintf('%J', config));
	write('/etc/console-mihomo/lan-devices.json', sprintf('%J', config.tun['include-interface']));
}
function syncRoutes(enabled){
	for(let family in ['-4','-6']){
		const rules=output(['/sbin/ip',family,'rule','show']);
		if(length(filter(split(rules,'\n'),line=>match(line,/^10390:/)&&index(line,'fwmark 0x434d')<0)))fail('策略路由优先级10390已被占用');
		if(enabled){const routes=trim(output(['/sbin/ip',family,'route','show','table','201']));if(routes&&index(routes,'dev cmihomo')<0)fail('策略路由表201已被其他功能占用');if(system(['/sbin/ip',family,'route','replace','table','201','default','dev','cmihomo'])!=0)fail('写入Clash策略路由失败');if(index(rules,'fwmark 0x434d lookup 201')<0&&system(['/sbin/ip',family,'rule','add','pref','10390','fwmark','0x434d','lookup','201'])!=0)fail('写入Clash来源规则失败');}
		else{system(command(['/sbin/ip',family,'rule','del','pref','10390','fwmark','0x434d','lookup','201'])+' 2>/dev/null');system(command(['/sbin/ip',family,'route','del','table','201','default','dev','cmihomo'])+' 2>/dev/null');}
	}
}
function firewall(enabled) {
	const devices = json(readfile('/etc/console-mihomo/lan-devices.json') || '[]');
	const set = '{ ' + join(', ', map(devices, d => sprintf('%J', d))) + ' }';
	let dns = 'destroy table inet console_mihomo_dns\n', forward = '';
	if (enabled) {
		if (!length(devices)) fail('没有可接管的内网接口');
		dns = nftPolicy(policy(),devices);
		forward = 'iifname ' + set + ' oifname "cmihomo" counter accept comment "console-mihomo LAN to TUN"\n' +
			'iifname "cmihomo" oifname ' + set + ' ct state { established, related } counter accept comment "console-mihomo TUN reply"\n';
	}
	write('/etc/console-mihomo/dns.nft', dns); write('/etc/console-mihomo/forward.nft', forward);
	if (system(['/usr/sbin/nft', '-c', '-f', '/etc/console-mihomo/dns.nft']) != 0 || system(['/sbin/fw4', 'check']) != 0) fail('透明代理防火墙校验失败');
	syncRoutes(enabled);
	if (system(['/sbin/fw4', 'reload']) != 0) fail('透明代理防火墙应用失败');
	if (enabled) write('/var/run/console-mihomo-transparent', sprintf('%J', { devices }));
}
export { lanDevices, networkConfig, prepare, firewall, vpnProxyEnabled };
