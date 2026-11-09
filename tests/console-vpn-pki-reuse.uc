// SPDX-License-Identifier: Apache-2.0
// Safe runtime check: reuse the existing PKI without enabling the VPN service.
import { ensurePki, fileExists } from 'console.vpn-service';
import { readfile } from 'fs';
const files = [
	'/etc/console-vpn/pki/ca.crt',
	'/etc/console-vpn/pki/issued/server.crt',
	'/etc/console-vpn/pki/private/server.key'
];
for (let path in files) if (!fileExists(path)) die('Expected existing PKI file missing: ' + path + '\n');
const before = map(files, path => readfile(path));
ensurePki();
const after = map(files, path => readfile(path));
for (let i = 0; i < length(files); i++) if (before[i] != after[i]) die('ensurePki unexpectedly replaced an existing certificate/key\n');
print('PASS: the deployed Easy-RSA CA and server certificate/key are detected and reused without starting OpenVPN.\n');
