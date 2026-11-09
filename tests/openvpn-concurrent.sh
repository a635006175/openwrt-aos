#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Local control-plane smoke test, using temporary interfaces and no route changes.
set -eu
umask 077
test_dir=$(mktemp -d /tmp/console-openvpn-test.XXXXXX)
server_pid=''
client_pid=''
client2_pid=''
cleanup() {
 [ -z "$client2_pid" ] || kill "$client2_pid" 2>/dev/null || true
	[ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
	[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
	case "$test_dir" in /tmp/console-openvpn-test.*) rm -rf "$test_dir";; esac
}
trap cleanup EXIT INT TERM
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj '/CN=testuser-ca' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout "$test_dir/ca.key" -out "$test_dir/ca.crt" >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj '/CN=testuser-server' -keyout "$test_dir/server.key" -out "$test_dir/server.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$test_dir/extensions.cnf"
openssl x509 -req -in "$test_dir/server.csr" -CA "$test_dir/ca.crt" -CAkey "$test_dir/ca.key" -CAcreateserial -days 1 -extfile "$test_dir/extensions.cnf" -out "$test_dir/server.crt" >/dev/null 2>&1
cat > "$test_dir/auth.sh" <<'EOF'
#!/bin/sh
IFS= read -r user < "$1"
pass=$(sed -n '2p' "$1")
[ "$user" = testuser ] && [ "$pass" = local-test-only ]
EOF
chmod 700 "$test_dir/auth.sh"
printf 'testuser\nlocal-test-only\n' > "$test_dir/client.auth"
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
duplicate-cn
max-clients 99
client-connect /usr/libexec/console-vpn-session
client-disconnect /usr/libexec/console-vpn-session
status $test_dir/status 1
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
		sed 's/tunct1/tunct2/' "$test_dir/client.conf" > "$test_dir/client2.conf"
 openvpn --config "$test_dir/client2.conf" > "$test_dir/client2.log" 2>&1 & client2_pid=$!
 sleep 4
 grep -q 'Initialization Sequence Completed' "$test_dir/client2.log" || { cat "$test_dir/client2.log"; exit 1; }
 kill -0 "$client_pid"
 [ "$(grep -c '^testuser,' "$test_dir/status")" -eq 2 ] || { cat "$test_dir/status"; exit 1; }
 echo 'PASS: two concurrent same-account OpenVPN clients receive separate IPs without replacing each other.'
		exit 0
	fi
	kill -0 "$server_pid" 2>/dev/null && kill -0 "$client_pid" 2>/dev/null || break
	i=$((i + 1)); sleep 1
done
cat "$test_dir/server.log" "$test_dir/client.log"
exit 1
