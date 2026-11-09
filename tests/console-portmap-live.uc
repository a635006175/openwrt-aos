// SPDX-License-Identifier: Apache-2.0
// Temporary test rule uses high ports and only the test workstation as a source.
import { state,apply } from 'console.portmap';
import { readfile } from 'fs';
function assert(v,m){if(!v)die(m+'\n');}
const mode=ARGV[0],s=state(),base={revision:s.revision,rules:s.rules,groups:s.groups};
if(index(['start','start_ip','start_any'],mode)>=0){
	assert(!length(s.rules),'start requires no existing console mappings');
	const r={id:'live_test',internalIP:'192.168.1.5',internalPorts:'45080-45082',externalPorts:'48080-48082',protocol:'tcp+udp',type:'interface',external:'wan',allowIPs:['192.168.1.5'],groups:[],comment:'temporary integration test',enabled:true};
	if(mode=='start_ip'){r.type='ip';r.external='172.16.10.81';}if(mode=='start_any')r.external='any';
	const before=readfile('/etc/config/firewall');let rejected=false;try{apply({...base,rules:[{...r,internalPorts:'1194',externalPorts:'1194',protocol:'tcp'}]});}catch(e){rejected=index(e.message,'本机服务冲突')>=0;}assert(rejected,'protect OpenVPN listener');assert(readfile('/etc/config/firewall')==before,'conflict leaves firewall unchanged');
	const after=apply({...base,rules:[r]});assert(length(after.rules)==1&&after.rules[0].enabled,'live rule saved');print('PASS listener protection + save/reload\n');
}else if(mode=='hotplug'){
	assert(system('ACTION=ifupdate INTERFACE=wan /etc/hotplug.d/iface/95-console-portmap')==0,'hotplug command');assert(state().revision>s.revision,'hotplug regenerated interface match');print('PASS WAN interface hotplug\n');
}else if(mode=='deny'){
	for(let r in base.rules)if(r.id=='live_test')r.allowIPs=['192.168.1.99'];apply(base);print('PASS source whitelist changed\n');
}else if(mode=='disable'){
	for(let r in base.rules)if(r.id=='live_test')r.enabled=false;apply(base);print('PASS disable\n');
}else if(mode=='stop'){
	base.rules=filter(base.rules,r=>r.id!='live_test');apply(base);print('PASS remove\n');
}else die('start/disable/stop\n');
