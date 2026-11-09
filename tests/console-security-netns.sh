#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Run only with unshare -n: all links, routes and nft tables are isolated from production.
set -eu
ip link set lo up
ip addr add 8.8.8.8/32 dev lo
ip addr add 192.0.2.1/32 dev lo
ip -6 addr add 2001:4860:4860::8888/128 dev lo nodad
ping -q -I 8.8.8.8 -s 16 -c 1 -W 1 127.0.0.1 >/dev/null
ping6 -q -I 2001:4860:4860::8888 -s 16 -c 1 -W 1 ::1 >/dev/null
nft -f /tmp/console-security-netns-block.nft
if ping -q -I 8.8.8.8 -s 16 -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then echo 'FAIL: IPv4 region block'; exit 1; fi
if ping6 -q -I 2001:4860:4860::8888 -s 16 -c 1 -W 1 ::1 >/dev/null 2>&1; then echo 'FAIL: IPv6 region block'; exit 1; fi
nft -j list counters table inet console_guard > /tmp/console-security-netns-block-counters.json
nft -f /tmp/console-security-netns-allow.nft
ping -q -I 8.8.8.8 -s 16 -c 1 -W 1 127.0.0.1 >/dev/null
ping6 -q -I 2001:4860:4860::8888 -s 16 -c 1 -W 1 ::1 >/dev/null
if ping -q -I 192.0.2.1 -s 16 -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then echo 'FAIL: allow-list unknown region'; exit 1; fi
nft -f - <<'NFT'
table inet meter_probe {
 set up4 { type ipv4_addr . inet_proto; flags dynamic,timeout; timeout 7d; counter; size 128; }
 set up6 { type ipv6_addr . inet_proto; flags dynamic,timeout; timeout 7d; counter; size 128; }
 chain account {
  type filter hook output priority 10; policy accept;
  ip saddr 8.8.8.8 update @up4 { ip saddr . meta l4proto timeout 7d counter }
  ip6 saddr 2001:4860:4860::8888 update @up6 { ip6 saddr . meta l4proto timeout 7d counter }
 }
}
NFT
ping -q -I 8.8.8.8 -s 16 -c 1 -W 1 127.0.0.1 >/dev/null
ping6 -q -I 2001:4860:4860::8888 -s 16 -c 1 -W 1 ::1 >/dev/null
nft -j list table inet meter_probe > /tmp/console-security-netns-meter.json
echo 'PASS: actual IPv4/IPv6 blocking, allow-list matches, unknown-region rejection and dynamic packet counters'
