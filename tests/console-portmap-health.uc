// SPDX-License-Identifier: Apache-2.0
import { cursor } from 'uci';
import { stat } from 'fs';
import { state } from 'console.portmap';
import { output } from 'console.security';
function assert(v,m){if(!v)die(m+'\n');}
function native(c){let result={};c.foreach('firewall',null,s=>{if(match(s['.name'],/^cpm_/)||s['.name']=='console_portmap')return;delete s['.index'];result[s['.name']]=s;});return result;}
assert(sprintf('%J',native(cursor()))==sprintf('%J',native(cursor('/root/console-portmap-install-backup'))),'all preexisting firewall sections preserved');
const s=state();assert(!length(s.rules)&&!length(s.groups),'test mappings and groups removed');assert(!stat('/etc/console-backup/portmap.pending'),'no unfinished transaction');assert(stat('/etc/rc.d/S18console-portmap'),'boot recovery enabled');
const sets=json(output(['/usr/sbin/nft','-j','list','sets']));assert(!length(filter(sets.nftables||[],i=>i.set?.table=='fw4'&&match(i.set.name,/^cpm_src_/))),'obsolete source sets removed');
assert(index(output(['/bin/netstat','-lnt']),':1194')>=0,'VPN listener present');assert(index(output(['/sbin/ip','route','get','203.0.113.177']),'via 172.16.10.1')>=0,'WAN return route present');
print('PASS original firewall preserved, test cleanup, boot recovery, VPN listener and WAN route\n');
