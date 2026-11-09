// SPDX-License-Identifier: Apache-2.0
import { targets, classify } from 'console.mihomo-sites';
function check(value, message) { if (!value) die(message + '\n'); }
check(length(targets) == 4, 'four fixed website targets');
for (let target in targets) check(match(target.url, /^https:\/\//), 'HTTPS-only targets');
check(classify(200, 0) == 'success' && classify(204, 0) == 'success', 'success responses');
for (let code in [401, 403, 429]) check(classify(code, 0) == 'restricted', 'restrictions must not be reported as success');
check(classify(500, 0) == 'http-error', 'server errors');
check(classify(0, 28) == 'timeout' && classify(0, 124) == 'timeout', 'bounded timeouts');
check(classify(0, 35) == 'failed' && classify(200, 60) == 'failed', 'TLS failure must not be reported as success');
print('Passed: fixed targets, success, HTTP restrictions, server errors and timeout classification\n');
