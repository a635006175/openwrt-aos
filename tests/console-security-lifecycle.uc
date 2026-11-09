// SPDX-License-Identifier: Apache-2.0
import { config,applyPolicy,confirmPolicy,rollbackPolicy,pending,writeJson,readJson } from 'console.security';
function assert(value,message) { if(!value) die(message); }
if(ARGV[0]=='start') {
	const c=config(); if(length(c.rules) || length(c.allowIPs) || length(c.blockIPs)) die('Lifecycle test requires an empty initial policy');
	writeJson('/tmp/console-security-lifecycle-before.json',c);
	const result=applyPolicy(c); assert(result.pending.secondsLeft>110,'missing confirmation window');
	print('PASS: unchanged empty policy applied; automatic rollback deadline '+result.pending.deadline+'\n');
} else {
	const before=readJson('/tmp/console-security-lifecycle-before.json',null);
	assert(before && !pending(),'automatic rollback not completed');
	assert(sprintf('%J',before)==sprintf('%J',config()),'automatic rollback did not restore saved config');
	applyPolicy(config());
	const marker=readJson('/etc/console-security/pending.json',{}), seconds=pending().secondsLeft;
	assert(marker.uptimeDeadline && marker.boot,'missing monotonic rollback deadline');
	marker.deadline-=3600;writeJson('/etc/console-security/pending.json',marker);
	assert(pending().secondsLeft>=seconds-1,'wall clock change altered confirmation window');
	confirmPolicy(); assert(!pending(),'confirmation did not clear rollback');
	const confirmed=config(); applyPolicy(config()); rollbackPolicy(false);
	assert(sprintf('%J',confirmed)==sprintf('%J',config()),'manual rollback did not restore config');
	print('PASS: 120-second automatic rollback, confirmation and manual rollback; policy remains empty\n');
}
