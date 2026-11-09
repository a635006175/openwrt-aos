// SPDX-License-Identifier: Apache-2.0
import { readfile } from 'fs';
import { history,query,parseConnection } from 'console.security';
function assert(v,m) {if(!v) die(m);}
const path='/tmp/console-security-history-benchmark.db';
assert(query('SELECT count(*) AS n FROM samples;',path)[0].n==316800,'fixture record count');
for(let seconds in [3600,86400,604800]) {
	const start=+split(readfile('/proc/uptime'),' ')[0];
	const all=history('all',seconds,path), single=history('02:00:00:00:00:05',seconds,path);
	assert(length(all.points)>0 && length(all.points)<=600,'bounded history response');
	assert(length(single.points)==length(all.points),'device history bucket count');
	let a=0,b=0;for(let p in all.points)a+=p.upload;for(let p in single.points)b+=p.upload;
	assert(a==b*100,'per-device history sum');
	print('PASS history '+seconds+'s, '+length(all.points)+' points, '+sprintf('%.0f',(+split(readfile('/proc/uptime'),' ')[0]-start)*1000)+'ms for two queries\n');
}
const nat=parseConnection('ipv4 2 tcp 6 400 ESTABLISHED src=8.8.8.8 dst=203.0.113.1 sport=50000 dport=8443 packets=2 bytes=100 src=192.168.1.20 dst=8.8.8.8 sport=443 dport=50000 packets=3 bytes=200 mark=0 zone=0 use=1');
assert(nat.replySrc=='192.168.1.20' && nat.bytes==300 && nat.dport=='8443','NAT original/reply tuples and bidirectional bytes');
print('PASS bidirectional/NAT connection decoder\n');
