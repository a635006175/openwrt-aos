// SPDX-License-Identifier: Apache-2.0
// Run after the five documented, genuine LAN->connected-WAN UDP probes.
import { state,history } from 'console.security';
const s=state().snapshot;
const device=filter(s.devices,d=>index(d.ips,'192.168.1.5')>=0)[0];
if(!device || device.total.udpup!=285) die('Expected five actual LAN->WAN UDP packets totaling 285 L3 bytes');
if(device.total.otherdown!=425) die('Expected five 85-byte ICMP unreachable replies');
if(device.total.up!=285 || device.total.down!=425) die('Protocol sums do not match device totals');
if(ARGV[0]=='history') {
	const h=history(device.id,3600);let up=0,down=0;for(let p in h.points){up+=p.upload;down+=p.download;}
	if(up!=285 || down!=425) die('Persisted device history did not match real kernel accounting');
}
print('PASS: actual routed LAN->WAN probes, MAC attribution, protocol counters, 285-byte upload and 425-byte download'+(ARGV[0]=='history'?', persisted history':'')+'\n');
