// SPDX-License-Identifier: Apache-2.0
// Execute on the test router. Fixtures remain isolated under /tmp.
import { readfile, open, mkdir, lsdir, unlink, rmdir } from 'fs';
const dir = '/tmp/console-history-test';
mkdir(dir, 0700);
for (let file in lsdir(dir) || []) unlink(`${dir}/${file}`);
const now = time(), hour = int(now / 3600);
function write(name, text) { const fd = open(`${dir}/${name}`, 'w'); fd.write(text); fd.close(); }
function check(condition, message) { if (!condition) die(message + '\n'); }
let rows = [
	{ time: now - 20, duration: 5, rates: { eth1: [100, 200] } },
	{ time: now - 15, duration: 5, rates: { eth1: [200, 400] } },
	{ time: now - 10, duration: 0, rates: { eth1: null } },
	{ time: now - 5, duration: 5, rates: { eth1: [0, 0] } }
];
for (let row in rows) {
	const fd = open(`${dir}/${int(row.time / 3600)}.jsonl`, 'a'); fd.write(sprintf('%J\n', row)); fd.close();
}
const fd = open(`${dir}/${hour}.jsonl`, 'a'); fd.write('{partial'); fd.close();
write(`${int((now - 16 * 86400) / 3600)}.jsonl`, sprintf('%J\n', { time: now - 16 * 86400, duration: 5, rates: { eth1: [9999, 9999] } }));
const api = loadstring(replace(readfile('/usr/share/rpcd/ucode/console-traffic'), '/srv/console-history', dir))();
const recent = api['console-traffic'].history.call({ args: { seconds: 300 } });
check(recent.retention == 1296000, 'retention must be fifteen days');
check(length(filter(recent.samples, row => row.upload == 100)) == 1, 'stored sample missing');
check(length(filter(recent.samples, row => row.upload == 0)) == 1, 'zero traffic must remain valid');
check(length(filter(recent.samples, row => row.upload == null)) > 1, 'missing/restart gaps must remain null');
const long = api['console-traffic'].history.call({ args: { seconds: 999999999 } });
check(long.seconds == 1296000 && length(long.samples) <= 602, 'range and output must be bounded');
check(!length(filter(long.samples, row => row.upload == 9999)), 'expired sample leaked');
check(length(filter(long.samples, row => row.upload > 0)) > 0, 'aggregated samples missing');
// Exercise the real collector retention sweep against the isolated directory.
loadstring(replace(replace(readfile('/usr/sbin/console-traffic.uc'), '/srv/console-history', dir), 'uloop.run();', ''))();
check(index(lsdir(dir), `${int((now - 16 * 86400) / 3600)}.jsonl`) < 0, 'retention sweep failed');
for (let file in lsdir(dir) || []) unlink(`${dir}/${file}`);
rmdir(dir);
print('Passed: durable history reads, zero rates, restart gaps, partial line recovery, bounded 15-day aggregation and expiry sweep.\n');
