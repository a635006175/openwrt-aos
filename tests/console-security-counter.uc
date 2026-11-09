// SPDX-License-Identifier: Apache-2.0
import { readfile } from 'fs';
const entries=json(readfile('/tmp/console-security-netns-meter.json')).nftables;
for(let pair in [['up4',44],['up6',64]]) {
	const set=filter(entries,e=>e.set?.name==pair[0])[0]?.set;
	const elem=set?.elem?.[0]?.elem;
	if(elem?.counter?.packets!=1 || elem.counter.bytes!=pair[1]) die('Counter accuracy mismatch: '+pair[0]);
}
const counters=json(readfile('/tmp/console-security-netns-block-counters.json')).nftables;
if(filter(counters,e=>e.counter?.name=='btest1')[0]?.counter?.packets!=2) die('Region block counter mismatch');
print('PASS: exact L3 accounting, IPv4=44 bytes, IPv6=64 bytes, two blocked probes\n');
