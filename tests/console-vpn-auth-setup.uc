// SPDX-License-Identifier: Apache-2.0
import { listAccounts, saveAccount, deleteAccount } from 'console.vpn-accounts';
const username = 'qa_console_auth_isolated';
if (ARGV[0] == 'cleanup') {
	deleteAccount(username);
}
else {
	for (let account in listAccounts()) if (account.username == username) die('Refusing to overwrite an existing account\n');
	saveAccount({ username, password: 'test-password-123', enabled: true });
}
