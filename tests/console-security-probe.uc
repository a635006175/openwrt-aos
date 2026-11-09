// SPDX-License-Identifier: Apache-2.0
import { ipKey,validate,compileGuard,writeText,initializeDatabase,query,geoLookup } from 'console.security';
function assert(value,message) { if (!value) die(message); }
assert(ipKey('192.168.1.1').key=='c0a80101','IPv4 key');
assert(ipKey('2001:db8::1').key=='20010db8000000000000000000000001','IPv6 key');
assert(ipKey('::ffff:192.0.2.1').key=='00000000000000000000ffffc0000201','IPv4-mapped IPv6');
assert(ipKey('192.168.1.300')==null && ipKey('::1::2')==null,'invalid IP rejection');
const c=validate({rules:[],allowIPs:[],blockIPs:[]});
writeText('/tmp/console-security-empty.nft',compileGuard(c));
initializeDatabase(); assert(query('SELECT 1 AS n;')[0].n==1,'SQLite query');
print('Security utilities and empty policy compile passed\n');
