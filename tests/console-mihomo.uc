// Run on router: ucode -L /tmp/mihomo-test /tmp/console-mihomo-test.uc
import { normalize } from 'console.mihomo';
function check(v, msg) { if (!v) die(msg); }
const input = { proxies: [{ name: 'test', type: 'socks5', server: '127.0.0.1', port: 9 }],
	'external-controller': '0.0.0.0:9999', listeners: [{ port: 53 }], tun: { enable: true }, dns: { enable: true },
	'proxy-providers': { example: { type: 'http', url: 'https://example.com/sub', path: '/etc/config/network' } } };
const out = normalize(input, 'rule');
check(out['external-controller'] == '127.0.0.1:9097', 'API must be loopback');
check(out['mixed-port'] == 7890 && out.tun.enable && out.dns.enable && !out.listeners, 'must normalize listeners and enable LAN takeover');
check(out.tun.device == 'cmihomo' && length(out.tun['include-interface']) > 0 && out.dns.listen == '[::]:1053', 'LAN-only TUN and separate DNS listener');
check(out['proxy-providers'].example.path == './providers/proxy-providers-example.yaml', 'provider paths must stay in data directory');
for (let mode in ['invalid', 'RULE', '']) {
	let rejected = false; try { normalize(input, mode); } catch (e) { rejected = true; }
	check(rejected, 'reject invalid mode');
}
let rejected = false; try { normalize({}, 'rule'); } catch (e) { rejected = true; }
check(rejected, 'reject empty config');
print('Passed Mihomo config isolation and validation\n');
