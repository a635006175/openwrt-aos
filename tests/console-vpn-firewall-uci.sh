#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Exercise VPN UCI sections against a temporary copy; never commit live firewall config.
set -eu
umask 077
test_dir=$(mktemp -d /tmp/console-vpn-fw-test.XXXXXX)
probe_package="console_vpn_fw_probe_$$"
cleanup() {
	case "$probe_package" in console_vpn_fw_probe_*) rm -f "/var/run/uci/$probe_package";; esac
	case "$test_dir" in /tmp/console-vpn-fw-test.*) rm -rf "$test_dir";; esac
}
trap cleanup EXIT INT TERM
mkdir -p "$test_dir/config" "$test_dir/overrides" "$test_dir/changes"
cp /etc/config/firewall "$test_dir/config/firewall"
uci_test() { /sbin/uci -c "$test_dir/config" -C "$test_dir/overrides" -P "$test_dir/changes" "$@"; }
set_option() { uci_test set "firewall.$1.$2=$3"; }
create_section() { uci_test set "firewall.$1=$2"; }

# The live config may already contain these sections when the VPN is enabled, which
# would make add_list append a duplicate device. Remove them so the fixture is hermetic.
for existing in $(uci_test show firewall | sed -n "s/^firewall\.\(console_vpn_[A-Za-z0-9_]*\)=.*/\1/p"); do
	uci_test delete "firewall.$existing"
done
uci_test commit firewall

create_section console_vpn_server_zone zone
set_option console_vpn_server_zone name console_vpn_server
set_option console_vpn_server_zone input ACCEPT
set_option console_vpn_server_zone output ACCEPT
set_option console_vpn_server_zone forward ACCEPT
set_option console_vpn_server_zone mtu_fix 1
uci_test add_list firewall.console_vpn_server_zone.device=cvpns
create_section console_vpn_server_to_lan forwarding
set_option console_vpn_server_to_lan src lan
set_option console_vpn_server_to_lan dest console_vpn_server
create_section console_vpn_server_from_lan forwarding
set_option console_vpn_server_from_lan src console_vpn_server
set_option console_vpn_server_from_lan dest lan
create_section console_vpn_server_to_wan forwarding
set_option console_vpn_server_to_wan src console_vpn_server
set_option console_vpn_server_to_wan dest wan
create_section console_vpn_server_lan_input rule
set_option console_vpn_server_lan_input name 'OpenVPN server lan'
set_option console_vpn_server_lan_input src lan
set_option console_vpn_server_lan_input proto tcp
set_option console_vpn_server_lan_input dest_port 1194
set_option console_vpn_server_lan_input family ipv4
set_option console_vpn_server_lan_input target ACCEPT
uci_test commit firewall

[ "$(uci_test get firewall.console_vpn_server_zone.name)" = console_vpn_server ]
[ "$(uci_test get firewall.console_vpn_server_zone.device)" = cvpns ]
# VPN clients are authenticated peers: router-local services must not be rejected,
# otherwise clients reach the LAN but cannot open 192.168.1.1.
[ "$(uci_test get firewall.console_vpn_server_zone.input)" = ACCEPT ]
[ "$(uci_test get firewall.console_vpn_server_zone.mtu_fix)" = 1 ]
[ "$(uci_test get firewall.console_vpn_server_to_lan.dest)" = console_vpn_server ]
[ "$(uci_test get firewall.console_vpn_server_to_wan.src)" = console_vpn_server ]
[ "$(uci_test get firewall.console_vpn_server_to_wan.dest)" = wan ]
[ "$(uci_test get firewall.console_vpn_server_lan_input.dest_port)" = 1194 ]
uci_test show firewall | grep "name='wan'" >/dev/null

for section in console_vpn_server_zone console_vpn_server_to_lan console_vpn_server_from_lan console_vpn_server_to_wan console_vpn_server_lan_input; do
	uci_test delete "firewall.$section"
done
uci_test commit firewall
if uci_test get firewall.console_vpn_server_zone.name >/dev/null 2>&1; then
	echo 'VPN firewall cleanup left a managed UCI section behind' >&2
	exit 1
fi

# Confirm the standard UCI commit path writes its chosen config tree, without
# using the live firewall package name or touching /etc/config/firewall.
if [ -e "/var/run/uci/$probe_package" ]; then
	echo 'UCI commit probe name unexpectedly exists' >&2
	exit 1
fi
printf "config defaults 'main'\n\toption marker 'before'\n" > "$test_dir/config/$probe_package"
uci_default() { /sbin/uci -c "$test_dir/config" -C "$test_dir/overrides" "$@"; }
uci_default set "$probe_package.main.marker=committed"
uci_default commit "$probe_package"
grep "option marker 'committed'" "$test_dir/config/$probe_package" >/dev/null
[ ! -e "/var/run/uci/$probe_package" ]

echo 'PASS: VPN zone, forwarding, LAN input rule and isolated cleanup use valid UCI sections.'
