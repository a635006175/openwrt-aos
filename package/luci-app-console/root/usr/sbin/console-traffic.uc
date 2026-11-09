// SPDX-License-Identifier: Apache-2.0
import { open, readfile, lsdir, unlink } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import * as uloop from 'uloop';

const directory = '/srv/console-history';
let previous = {}, previousTime = null, previousUptime = null;
let cleanedHour = null;

function sample() {
	const bus = connect();
	const dump = bus?.call('network.interface', 'dump');
	bus?.disconnect();
	if (type(dump?.interface) != 'array') die('Cannot read network interfaces\n');
	const config = cursor();
	let names = [];
	config.foreach('firewall', 'zone', zone => {
		if (zone.name == 'wan') names = type(zone.network) == 'array' ? zone.network : split(zone.network || '', /\s+/);
	});
	config.unload('firewall');
	const now = time(), uptime = +split(readfile('/proc/uptime'), ' ')[0];
	const elapsed = previousUptime == null ? 0 : uptime - previousUptime;
	const drift = (now - previousTime) - elapsed;
	const valid = elapsed > 0 && elapsed <= 15 && drift >= -2 && drift <= 2;
	let counters = {}, rates = {};
	// Prefer an up interface when IPv4 and IPv6 share one device.
	const interfaces = sort(dump.interface, (a, b) => (b.up ? 1 : 0) - (a.up ? 1 : 0));
	for (let iface in interfaces) {
		if (length(names) ? index(names, iface.interface) < 0 : !match(iface.interface, /^wan\d*6?$/)) continue;
		const dev = iface.l3_device || iface.device;
		if (!dev || !match(dev, /^[a-zA-Z0-9_.:@-]{1,64}$/) || dev in counters) continue;
		const rxText = readfile(`/sys/class/net/${dev}/statistics/rx_bytes`);
		const txText = readfile(`/sys/class/net/${dev}/statistics/tx_bytes`);
		const rx = rxText == null ? null : +rxText, tx = txText == null ? null : +txText;
		counters[dev] = { rx, tx, up: iface.up };
		const old = previous[dev];
		rates[dev] = !iface.up ? [0, 0] : valid && old?.up && rx != null && tx != null && rx >= old.rx && tx >= old.tx ? [(tx - old.tx) / elapsed, (rx - old.rx) / elapsed] : null;
	}
	const hour = int(now / 3600);
	const fd = open(`${directory}/${hour}.jsonl`, 'a');
	if (!fd) die('Cannot open persistent traffic history\n');
	if (fd.write(sprintf('%J\n', { time: now, duration: valid ? elapsed : 0, rates })) == null) die('Cannot write traffic history\n');
	fd.close();
	previous = counters; previousTime = now; previousUptime = uptime;
	if (cleanedHour != hour) {
		for (let name in lsdir(directory) || [])
			if (match(name, /^\d+\.jsonl$/) && +split(name, '.')[0] < int((now - 1296000) / 3600)) unlink(`${directory}/${name}`);
		cleanedHour = hour;
	}
}

uloop.init();
sample();
const timer = uloop.interval(5000, sample);
uloop.run();
