// SPDX-License-Identifier: Apache-2.0
import { readfile } from 'fs';
import { state,query,geoPath } from 'console.security';
function assert(v,m){if(!v)die(m);}
const health=state();
assert(!health.stale,'collector is stale');
assert(!health.snapshot.error,'collector runtime error');
assert(health.snapshot.accurate,'counter accuracy warning');
assert(!health.pending && !length(health.config.rules),'unexpected live restriction');
assert(health.geo.records==710834,'incomplete initial country database');
assert(query('PRAGMA quick_check;',geoPath())[0].quick_check=='ok','country database integrity');
assert(query('PRAGMA quick_check;')[0].quick_check=='ok','traffic database integrity');
const before=json(readfile('/tmp/console-security-before-fw4.json')).nftables;
const after=json(readfile('/tmp/console-security-after-fw4.json')).nftables;
const a=filter(before,v=>v.table)[0].table.handle,b=filter(after,v=>v.table)[0].table.handle;
assert(a==b,'fw4 reload reset device meter table');
assert(length(filter(after,v=>v.set && match(v.set.name,/^(up|down)[46]$/) && index(v.set.flags,'timeout')>=0))==4,'meter counter expiry configuration');
print('PASS: service health, SQLite integrity, complete geography, empty restrictions, timeout counters and fw4 reload counter preservation\n');
