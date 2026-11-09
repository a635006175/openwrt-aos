// SPDX-License-Identifier: Apache-2.0
// Import an isolated copy of the account module with its directory set to /tmp.
import { listAccounts, saveAccount, deleteAccount, verify } from './vpn-accounts-test.uc';
import { readfile, lsdir, unlink, rmdir } from 'fs';
const base = '/tmp/console-vpn-logic-test';
function check(condition, message) { if (!condition) die(message + '\n'); }
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }
saveAccount({ username: 'branch', password: 'test-pass-123', enabled: true, address: '10.8.0.10', remoteSubnet: '192.168.2.0/24' });
check(verify('branch', 'test-pass-123'), 'valid credentials rejected');
check(!verify('branch', 'wrong-password'), 'invalid credentials accepted');
check(!verify('../branch', 'test-pass-123'), 'unsafe username accepted');
check(index(readfile(`${base}/accounts/branch.json`), 'test-pass-123') < 0, 'plaintext password stored');
check(!('hash' in listAccounts()[0]), 'password hash leaked in account list');
check(throws(() => saveAccount({ username: 'other', password: 'test-pass-456', enabled: true, address: '10.8.0.10' })), 'duplicate IP accepted');
check(throws(() => saveAccount({ username: '../unsafe', password: 'test-pass-456', enabled: true })), 'invalid username accepted');
saveAccount({ username: 'branch', password: '', enabled: false, address: '10.8.0.10' });
check(!verify('branch', 'test-pass-123'), 'disabled account accepted');
saveAccount({ username: 'branch', password: '', enabled: true, address: '10.8.0.10' });
check(verify('branch', 'test-pass-123'), 'blank edit changed password');
deleteAccount('branch');
check(!verify('branch', 'test-pass-123'), 'deleted account accepted');
rmdir(`${base}/accounts`); rmdir(base);
print('Passed: salted hash, password verification, disabled/deleted accounts, duplicate IP and validation.\n');
