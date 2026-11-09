#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Local control-plane smoke test, using temporary interfaces and no route changes.
set -eu
umask 077
test_dir=$(mktemp -d /tmp/console-openvpn-test.XXXXXX)
server_pid=''
client_pid=''
cleanup() {
	[ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
	[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
	case "$test_dir" in /tmp/console-openvpn-test.*) rm -rf "$test_dir";; esac
}
trap cleanup EXIT INT TERM
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj '/CN=console-test-ca' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout "$test_dir/ca.key" -out "$test_dir/ca.crt" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj '/CN=console-test-server' -keyout "$test_dir/server.key" -out "$test_dir/server.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$test_dir/extensions.cnf"
openssl x509 -req -in "$test_dir/server.csr" -CA "$test_dir/ca.crt" -CAkey "$test_dir/ca.key" -CAcreateserial -days 1 -extfile "$test_dir/extensions.cnf" -out "$test_dir/server.crt" >/dev/null 2>&1
cat > "$test_dir/auth.sh" <<'EOF'
#!/bin/sh
IFS= read -r user < "$1"
pass=$(sed -n '2p' "$1")
[ "$user" = console-test ] && [ "$pass" = local-test-only ]
EOF
chmod 700 "$test_dir/auth.sh"
printf 'console-test\nlocal-test-only\n' > "$test_dir/client.auth"
cat > "$test_dir/server.conf" <<EOF
local 127.0.0.1
port 11944
proto udp
dev tunct0
server 10.254.247.0 255.255.255.0
topology subnet
ifconfig-noexec
route-noexec
ca $test_dir/ca.crt
cert $test_dir/server.crt
key $test_dir/server.key
dh none
verify-client-cert none
username-as-common-name
script-security 2
auth-user-pass-verify $test_dir/auth.sh via-file
keepalive 5 20
verb 3
EOF
cat > "$test_dir/client.conf" <<EOF
client
dev tunct1
proto udp
remote 127.0.0.1 11944
nobind
ifconfig-noexec
route-noexec
ca $test_dir/ca.crt
remote-cert-tls server
auth-user-pass $test_dir/client.auth
auth-nocache
verb 3
EOF
openvpn --config "$test_dir/server.conf" > "$test_dir/server.log" 2>&1 & server_pid=$!
sleep 2
openvpn --config "$test_dir/client.conf" > "$test_dir/client.log" 2>&1 & client_pid=$!
i=0
while [ "$i" -lt 20 ]; do
	if grep -q 'Initialization Sequence Completed' "$test_dir/client.log" && grep -q 'Peer Connection Initiated' "$test_dir/server.log"; then
		echo 'PASS: local OpenVPN server/client TLS and username/password authentication; both TUN devices opened.'
		exit 0
	fi
	kill -0 "$server_pid" 2>/dev/null && kill -0 "$client_pid" 2>/dev/null || break
	i=$((i + 1)); sleep 1
done
cat "$test_dir/server.log" "$test_dir/client.log"
exit 1
