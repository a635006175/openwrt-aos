// SPDX-License-Identifier: Apache-2.0
// Simulate interrupted config write with no kernel change, then restore the exact snapshot.
import { readfile,stat } from 'fs';
import { writeText } from 'console.security';
import { state,recover } from 'console.portmap';
function assert(v,m){if(!v)die(m+'\n');}
assert(!length(state().rules),'requires empty console mappings');assert(!stat('/etc/console-backup/portmap.pending'),'no existing transaction');
const old=readfile('/etc/config/firewall'),reflection=readfile('/etc/console-portmap-reflection.nft')||'',sets=readfile('/etc/console-portmap-sets.nft')||'';
writeText('/etc/console-backup/portmap.firewall.last-good',old);
writeText('/etc/console-backup/portmap.pending',sprintf('%J',{reflection,sets}));
writeText('/etc/config/firewall','# Simulated interrupted transaction\n');
assert(recover(),'recovered');assert(readfile('/etc/config/firewall')==old,'exact firewall restored');assert(readfile('/etc/console-portmap-reflection.nft')==reflection,'reflection restored');assert(readfile('/etc/console-portmap-sets.nft')==sets,'sources restored');assert(!stat('/etc/console-backup/portmap.pending'),'marker removed');
print('PASS interrupted transaction recovery restores config, source sets and reflection\n');
