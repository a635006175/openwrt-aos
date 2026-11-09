// SPDX-License-Identifier: Apache-2.0
// Import a test copy of console.mihomo with root=/tmp/mihomo-validation-qa,
// a private lock, and the validation binary replaced by a script sleeping 30s.
import { save } from '/tmp/mihomo-validation-isolated.uc';
import { mkdir, readfile, writefile, stat } from 'fs';
mkdir('/tmp/mihomo-validation-qa', 0700);
writefile('/tmp/mihomo-validation-qa/config.json', 'sentinel');
const started = time(); let message = '';
try { save('{"proxies":[{"name":"qa","type":"socks5","server":"127.0.0.1","port":9}]}', 'rule'); }
catch (e) { message = e.message; }
if (time() - started < 9 || time() - started > 15 || index(message, '10 秒') < 0) die('Timeout guard failed');
if (readfile('/tmp/mihomo-validation-qa/config.json') != 'sentinel' || stat('/tmp/mihomo-validation-qa/candidate.json') || stat('/tmp/mihomo-validation-qa.lock')) die('Rollback or cleanup failed');
print('Passed: validation bounded to 10 seconds, previous config preserved, candidate and lock cleaned\n');
