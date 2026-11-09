#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu
test_file=$(mktemp /tmp/console-vpn-auth.XXXXXX)
created=0
cleanup() {
	if [ "$created" = 1 ]; then ucode /tmp/console-vpn-auth-setup.uc cleanup; fi
	rm -f "$test_file"
}
trap cleanup EXIT INT TERM
ucode /tmp/console-vpn-auth-setup.uc setup
created=1
printf 'qa_console_auth_isolated\ntest-password-123\n' > "$test_file"
/usr/libexec/console-vpn-auth "$test_file"
printf 'qa_console_auth_isolated\nwrong-password\n' > "$test_file"
if /usr/libexec/console-vpn-auth "$test_file"; then echo 'incorrect password accepted'; exit 1; fi
printf '../unsafe\ntest-password-123\n' > "$test_file"
if /usr/libexec/console-vpn-auth "$test_file"; then echo 'unsafe account accepted'; exit 1; fi
echo 'PASS: OpenVPN authentication helper accepts valid accounts and rejects bad credentials.'
