// SPDX-License-Identifier: Apache-2.0
// Run on a test router with an enabled, valid config. Briefly stops then
// restarts Clash; restores the enabled state on failure.
import { action, state } from 'console.mihomo';
import { readfile, stat, popen } from 'fs';
function check(v, msg) { if (!v) die(msg + '\n'); }
function output(command) { const p = popen(command, 'r'), text = p.read('all'); p.close(); return text; }
check(state().enabled, 'requires an enabled test service');
try {
	action('stop'); system(['/bin/sleep', '2']);
	check(!stat('/sys/class/net/cmihomo'), 'TUN must disappear after stop');
	check(!stat('/var/run/console-mihomo-transparent'), 'ready marker must disappear after stop');
	check(index(output('nft list tables'), 'console_mihomo_dns') < 0, 'DNS interception must disappear after stop');
	check(index(output('nft list tables'), 'table inet mihomo') < 0, 'native interception must disappear after stop');
	check(index(output('ip rule show'), '10390') < 0, 'IPv4 policy routes must disappear after stop');
	check(index(output('ip -6 rule show'), '10390') < 0, 'IPv6 policy routes must disappear after stop');
	check(!state().enabled, 'stop disables startup');
	action('start'); system(['/bin/sleep', '3']);
	check(state().transparent, 'automatic LAN proxy must be ready after start');
	const config = json(readfile('/etc/console-mihomo/config.json'));
	check(!config.tun['auto-route'] && !config.tun['auto-redirect'], 'source policy owns route selection');
	check(index(output('ip rule show'),'fwmark 0x434d lookup 201')>=0,'source routing restored');
	check(index(config.tun['include-interface'], 'br-lan') >= 0 && index(config.tun['include-interface'], 'eth2') >= 0, 'both current LAN interfaces covered');
	print('Passed: stop removes DNS interception, TUN and IPv4/IPv6 policy routes; start restores both LANs in rule mode\n');
} catch (e) {
	try { action('start'); } catch (ignored) {}
	die(e);
}
