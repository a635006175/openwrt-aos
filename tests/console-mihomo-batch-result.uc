// SPDX-License-Identifier: Apache-2.0
// Read-only verification after the browser starts a batch and leaves the page.
import { job } from 'console.mihomo-delay';
import { state } from 'console.mihomo';
import { readfile } from 'fs';
function check(v,m){if(!v)die(m+'\n');}
const j=job();check(j&&!j.running&&!j.error,'batch completed without coordinator error');check(j.completed==j.total,'every node completed');check(j.concurrency==6,'bounded concurrency');
const names=json(readfile(j.dir+'/names.json')),delays=json(readfile('/var/run/console-mihomo-delay.json'));
for(let name in names)check(delays[name]?.testedAt>=j.startedAt,'fresh result for '+name);
const s=state();check(s.running&&s.transparent,'proxy still running');check(s.delayJob.id==j.id,'state restores same job');
print('PASS '+j.total+' background results persisted, '+(j.finishedAt-j.startedAt)+' seconds, '+j.failed+' failed/timeout results, proxy still running\n');
