// SPDX-License-Identifier: Apache-2.0
// Live toggle test; finishes enabled as requested. Does not restart OpenVPN.
import { setVpnProxy,state } from 'console.mihomo';
import { networkConfig } from 'console.mihomo-network';
import { readfile } from 'fs';
import { output } from 'console.security';
function check(v,m){if(!v)die(m+'\n');}
const pid=readfile('/var/run/console-vpn/server.pid');
let c=networkConfig({},['br-lan'],false);check(index(c.tun['include-interface'],'cvpns')<0,'off excludes VPN');
c=networkConfig({},['br-lan'],true);check(index(c.tun['include-interface'],'cvpns')>=0,'on includes VPN');
for(let enabled in [true,false,true]){
	setVpnProxy(enabled);const s=state();check(s.vpnProxyEnabled==enabled&&s.transparent,'toggle saved and service ready');
	const config=json(readfile('/etc/console-mihomo/config.json'));
	check((index(config.tun['include-interface'],'cvpns')>=0)==enabled,'TUN interface toggle');
	check((index(readfile('/etc/console-mihomo/dns.nft'),'cvpns')>=0)==enabled,'DNS interception toggle');
	check((index(readfile('/etc/console-mihomo/forward.nft'),'cvpns')>=0)==enabled,'forward toggle');
	check(index(output(['/sbin/ip','rule','show']),'fwmark 0x434d lookup 201')>=0,'live source routing ready');
	check(readfile('/var/run/console-vpn/server.pid')==pid,'VPN daemon unchanged');
}
print('PASS ON/OFF/ON persistence, TUN, DNS, forwarding, live policy routes; VPN not restarted\n');
