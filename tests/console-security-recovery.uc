// SPDX-License-Identifier: Apache-2.0
// Run in unshare -n; uses the saved guard file without changing its contents.
import { ensureGuard,output } from 'console.security';
ensureGuard();
if(!match(output(['/usr/sbin/nft','list','tables']),/table inet console_guard/)) die('Guard recovery failed');
print('PASS: saved geography gate recovers when the kernel table is absent\n');
