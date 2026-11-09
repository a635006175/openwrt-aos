// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';
'require console.model as model';

const ICONS = {
	menu: [ 'M4 6h16M4 12h16M4 18h16' ],
	dashboard: [ 'M3 13a9 9 0 1 1 18 0', 'M12 13l4-5M5 17h14M7 6l1 2M17 6l-1 2' ],
	monitor: [ 'M3 3h18v18H3z', 'M4 13h4l3-7 3 12 3-5h3' ],
	settings: [ 'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0' ],
	network: [ 'M9 3h6v5H9zM2 16h6v5H2zM9 16h6v5H9zM16 16h6v5h-6z', 'M12 8v8M5 16v-4h14v4' ],
	flow: [ 'M3 4h18v16H3zM8 7v10M12 7v10M16 7v10M6 11h4M10 14h4M14 9h4' ],
	wifi: [ 'M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0M8 16a6 6 0 0 1 8 0M11 20h2' ],
	users: [ 'M3 4h18v16H3zM15 8h3M15 12h3M15 16h3', 'M10 9a2 2 0 1 1-4 0 2 2 0 0 1 4 0M5 17v-1a3 3 0 0 1 6 0v1' ],
	arrows: [ 'M4 7h16M15 2l5 5-5 5M20 17H4M9 12l-5 5 5 5' ],
	shield: [ 'M12 2l9 4v6c0 6-9 10-9 10S3 18 3 12V6z', 'M7 12l3 3 7-7' ],
	apps: [ 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z' ],
	check: [ 'M3 4h18v16H3zM7 12l3 3 7-7' ],
	checked: [ 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20', 'M7.6 12.4l3.1 3.1 5.8-6' ],
	tools: [ 'M4 4h5v5H4zM15 4h5v5h-5zM4 15h5v5H4zM15 15h5v5h-5zM11 6h2M6 11v2M18 11v2M11 18h2' ],
	logs: [ 'M5 2h10l4 4v16H5zM15 2v5h4M8 11h8M8 15h8M8 19h5' ],
	user: [ 'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0M4 22v-3a8 8 0 0 1 16 0v3' ],
	home: [ 'M2 11L12 2l10 9M5 9v13h14V9M9 22v-8h6v8' ],
	cloud: [ 'M6 19a5 5 0 0 1-1-10 7 7 0 0 1 13-2 6 6 0 0 1 0 12H6' ],
	cpu: [ 'M6 6h12v12H6zM9 9h6v6H9zM9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4' ],
	memory: [ 'M2 7h20v10H2zM5 10h3v4H5zM10 10h3v4h-3zM15 10h3v4h-3zM5 17v3M9 17v3M13 17v3M17 17v3' ],
	temperature: [ 'M9 14V5a3 3 0 0 1 6 0v9a5 5 0 1 1-6 0M12 8v10' ],
	up: [ 'M12 22V3M5 10l7-7 7 7' ],
	down: [ 'M12 2v19M5 14l7 7 7-7' ],
	detail: [ 'M3 6h18M3 12h12M3 18h16' ],
	port: [ 'M6 3h12v5h4v13H2V8h4zM6 14v7M9 14v7M12 14v7M15 14v7M18 14v7' ],
	ap: [ 'M2 10c0-9 20-9 20 0v4c0 8-20 8-20 0z', 'M2 10c0 8 20 8 20 0M8 9c0-3 8-3 8 0s-8 3-8 0M18 17v5' ],
	close: [ 'M5 5l14 14M19 5L5 19' ],
	refresh: [ 'M20 7V2l-4 4M20 7A9 9 0 1 0 21 15M20 7h-5' ],
	pause: [ 'M8 4v16M16 4v16' ],
	play: [ 'M7 3l14 9-14 9z' ]
};
const COLORS = [ '#328ac5', '#19a992', '#7aaec4', '#97a8b9' ];

function svg(tag, attrs, children) {
	const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	Object.entries(attrs || {}).forEach(([ key, value ]) => node.setAttribute(key, value));
	(children || []).forEach(child => node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child));
	return node;
}

function icon(name, className) {
	return svg('svg', { viewBox: '0 0 24 24', class: 'ow-icon ' + (className || ''), fill: 'none', stroke: 'currentColor', 'stroke-width': '1.4', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' },
		(ICONS[name] || ICONS.dashboard).map(d => svg('path', { d })));
}

function text(node, value) { const next = value === null || value === undefined ? '—' : String(value); if (node.textContent !== next) node.textContent = next; }
function span(className, value) { return E('span', { class: className || '' }, value === undefined ? '' : String(value)); }
function count(value) { return value === null || value === undefined ? '—' : String(value); }
function percent(value) { return value === null ? '—' : value.toFixed(1) + '%'; }
function timeLabel(time) { return new Date(time * 1000).toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
function uptime(value) {
	if (!Number.isFinite(value)) return '—';
	const days = Math.floor(value / 86400), hours = Math.floor(value % 86400 / 3600), minutes = Math.floor(value % 3600 / 60);
	return (days ? days + '天 ' : '') + hours + '小时 ' + minutes + '分钟';
}

function interfaceDetails(iface, data) {
	const device = data.devices[iface.deviceName] || {}, link = device.link || {}, stats = device.stats || {};
	const rate = (data.interfaceRates || {})[iface.deviceName];
	const unique = list => Array.from(new Set(list.filter(Boolean))).join('\n');
	const address = a => a.address ? a.address + (a.mask != null ? '/' + a.mask : a.netmask && !a.netmask.includes(':') ? '/' + a.netmask : '') : '';
	const ipv4 = unique((iface['ipv4-address'] || []).length ? iface['ipv4-address'].map(address) : (device.ipaddrs || []).map(address));
	const ipv6 = unique([...(iface['ipv6-address'] || []), ...(iface['ipv6-prefix-assignment'] || []).map(a => a['local-address']).filter(Boolean)].map(address)
		.concat((device.ip6addrs || []).filter(a => ![...(iface['ipv6-address'] || []), ...(iface['ipv6-prefix-assignment'] || []).map(a => a['local-address']).filter(Boolean)].some(b => b.address === a.address)).map(address)));
	const speed = value => Number(value) > 0 ? Number(value).toLocaleString('zh-CN') + ' Mbps' : '未提供';
	const duplex = value => value === 'full' ? '全双工' : value === 'half' ? '半双工' : '未提供';
	const carrier = value => value === true ? '已连接' : value === false ? '未连接' : '未知';
	const physical = (device.ports || []).map(name => {
		const member = data.devices[name]?.link || {};
		return name + ' · ' + carrier(member.carrier) + (member.carrier === false ? '' : ' · ' + speed(member.speed) + ' · ' + duplex(member.duplex));
	});
	const rows = [
		['接口 / 设备', iface.interface + ' / ' + iface.deviceName],
		['角色 / 协议', iface.role + ' / ' + (iface.proto || '未知')],
		['接口状态', iface.pending ? '正在连接' : iface.available === false ? '设备不可用' : iface.up ? '已启动' : '未启动'],
		['物理链路', carrier(link.carrier)],
		['自动启动', iface.autostart === true ? '启用' : iface.autostart === false ? '禁用' : '未提供'],
		['协商速率', link.carrier === false ? '未连接' : Number(link.speed) > 0 ? speed(link.speed) : device.bridge ? '桥接接口，见成员网口' : '未提供'],
		['双工模式', duplex(link.duplex)],
		['成员网口', physical.join('\n') || '无 / 不适用'],
		['实时接收 / 发送', model.formatBytes(rate?.rx, true) + ' / ' + model.formatBytes(rate?.tx, true)],
		['IPv4 地址', ipv4 || '无'], ['IPv6 地址', ipv6 || '无'],
		['IPv6 委派前缀', unique((iface['ipv6-prefix'] || []).map(address)) || '无'],
		['默认网关', unique((iface.route || []).filter(r => +r.mask === 0 && (r.target === '0.0.0.0' || r.target === '::')).map(r => r.nexthop)) || '无'],
		['接口 DNS', unique(iface['dns-server'] || []) || '未提供接口 DNS'],
		['DNS 搜索域', unique(iface['dns-search'] || []) || '无'],
		['MAC / MTU', (device.mac || '未提供') + ' / ' + (device.mtu ?? '未提供')],
		['连接时长', iface.up && Number.isFinite(iface.uptime) ? uptime(iface.uptime) : '—'],
		['接收 / 发送累计', model.formatBytes(stats.rx_bytes) + ' / ' + model.formatBytes(stats.tx_bytes)],
		['接收 / 发送包数', count(stats.rx_packets) + ' / ' + count(stats.tx_packets)],
		['接收 / 发送丢包', count(stats.rx_dropped) + ' / ' + count(stats.tx_dropped)],
		['接收 / 发送错误', count(stats.rx_errors) + ' / ' + count(stats.tx_errors)]
	];
	const priority = ['接口 / 设备', '接口状态', '物理链路', 'IPv4 地址', 'IPv6 地址', '接口 DNS', '默认网关', '协商速率', '实时接收 / 发送'];
	return priority.map(label => rows.find(row => row[0] === label)).concat(rows.filter(row => !priority.includes(row[0])));
}

function closePortDetails(refs) {
	if (!refs.openPort) return;
	refs.openPort.panel.hidden = true;
	refs.openPort.element.setAttribute('aria-expanded', 'false');
	refs.openPort.pinned = false; refs.openPort = null;
}

function positionPortDetails(item) {
	if (item.panel.hidden) return;
	const anchor = item.element.getBoundingClientRect();
	const below = innerHeight - anchor.bottom - 20, above = anchor.top - 20;
	const showBelow = below >= Math.min(item.panel.scrollHeight, 650, innerHeight * .7) || below >= above;
	item.panel.style.maxHeight = Math.max(100, Math.min(650, innerHeight * .7, showBelow ? below : above)) + 'px';
	const panel = item.panel.getBoundingClientRect();
	item.panel.style.left = Math.max(12, Math.min(innerWidth - panel.width - 12, anchor.left - 12)) + 'px';
	item.panel.style.top = Math.max(12, showBelow ? anchor.bottom + 8 : anchor.top - panel.height - 8) + 'px';
}

function createPortDetails(refs, key, options) {
	const status = span('ow-port-status'), name = span('ow-port-name'), kind = span('ow-port-kind');
	const id = 'ow-port-detail-' + encodeURIComponent(key);
	const element = E('button', { type: 'button', class: 'ow-port', 'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-controls': id }, [icon('port'), name, kind, status]);
	const heading = E('strong', { id: id + '-heading' }, key + ' · 接口详情');
	const dismiss = E('button', { type: 'button', class: 'ow-port-dismiss', 'aria-label': '关闭接口详情' }, icon('close'));
	const list = E('dl', { class: 'ow-port-detail-list' });
	const panel = E('div', { id, class: 'ow-port-details', role: 'dialog', 'aria-labelledby': id + '-heading', hidden: true }, [
		E('div', { class: 'ow-port-details-heading' }, [heading, dismiss]), list,
		E('p', { class: 'ow-port-details-note' }, '实时收发为设备视角，每5秒更新；协商速率为链路容量。'),
		E('a', { href: options.routes.network, class: 'ow-port-settings' }, '查看接口设置')
	]);
	const wrapper = E('div', { class: 'ow-port-wrap' }, [element, panel]);
	const item = { element, wrapper, panel, status, name, kind, fields: new Map(), list, pinned: false };
	const show = () => {
		clearTimeout(item.hideTimer);
		if (refs.openPort !== item) closePortDetails(refs);
		refs.openPort = item; panel.hidden = false; element.setAttribute('aria-expanded', 'true'); positionPortDetails(item);
	};
	wrapper.addEventListener('pointerenter', event => { if (event.pointerType !== 'touch') show(); });
	wrapper.addEventListener('pointerleave', () => {
		item.hideTimer = setTimeout(() => { if (refs.openPort === item && !item.pinned && !wrapper.contains(document.activeElement)) closePortDetails(refs); }, 180);
	});
	wrapper.addEventListener('focusin', show);
	wrapper.addEventListener('focusout', event => { if (!wrapper.contains(event.relatedTarget)) closePortDetails(refs); });
	element.addEventListener('click', () => { if (item.pinned) closePortDetails(refs); else { show(); item.pinned = true; } });
	const dismissAndFocus = () => { element.focus({ preventScroll: true }); closePortDetails(refs); };
	dismiss.addEventListener('click', dismissAndFocus);
	wrapper.addEventListener('keydown', event => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); dismissAndFocus(); } });
	return item;
}

function card(title, className, action) {
	const body = E('div', { class: 'ow-card-body' });
	return { body, element: E('section', { class: 'ow-card ' + (className || '') }, [
		E('div', { class: 'ow-card-heading' }, [ E('h2', {}, title), action || E('span') ]), body
	]) };
}

function detailLink(url, label) {
	return E('a', { class: 'ow-detail', href: url, 'aria-label': label, title: label }, [ icon('detail'), span('ow-detail-label', '详情') ]);
}

function metric(valueNode, label, action, hint) {
	return E(action ? 'button' : 'div', action ? { class: 'ow-metric ow-metric-button', type: 'button', click: action, title: hint || label } : { class: 'ow-metric', title: hint || label }, [ valueNode, span('ow-metric-label', label) ]);
}

function lineChart(history, line, now, seconds, interval, onHover) {
	seconds = seconds || 300;
	const width = 1000, height = 172, left = 50, right = 16, top = 10, bottom = 24;
	const directions = [ { key: 'upload', label: '上行', color: '#1677E8' }, { key: 'download', label: '下行', color: '#16A36A' } ];
	const series = history.filter(entry => entry.time >= now - seconds && entry.time <= now).map(entry => {
		const rates = line === 'all' ? entry : ((entry.rates || {})[line] || {});
		return { time: entry.time, upload: rates.upload, download: rates.download };
	});
	const values = series.flatMap(point => directions.map(dir => point[dir.key])).filter(Number.isFinite);
	const maximum = Math.max(1024, ...values) * 1.15;
	const unit = maximum >= 1024 * 1024 ? 1024 * 1024 : 1024;
	const unitName = unit === 1024 ? 'KB/s' : 'MB/s';
	const x = time => left + Math.max(0, Math.min(1, (time - (now - seconds)) / seconds)) * (width - left - right);
	const y = value => top + (1 - value / maximum) * (height - top - bottom);
	const nodes = [ svg('title', {}, [ '上下行历史速率，共用刻度（' + unitName + '）' ]) ];
	for (let i = 0; i <= 3; i++) {
		const value = maximum * i / 3, py = y(value);
		nodes.push(svg('path', { d: 'M' + left + ',' + py + 'H' + (width - right), stroke: '#e3e9ee', 'stroke-width': 1 }));
		nodes.push(svg('text', { x: left - 9, y: py + 4, 'text-anchor': 'end', class: 'ow-axis' }, [ (value / unit).toFixed(value ? 1 : 0) ]));
	}
	for (let i = 0; i <= 5; i++) {
		const time = now - seconds + i * seconds / 5;
		const date = seconds > 86400 ? new Date(time * 1000).toLocaleDateString('zh-CN', { month: '2-digit', day: '2-digit' }) + ' ' : '';
		nodes.push(svg('text', { x: x(time), y: height - 5, 'text-anchor': i === 0 ? 'start' : i === 5 ? 'end' : 'middle', class: 'ow-axis' }, [ date + timeLabel(time).slice(0, 5) ]));
	}
	const defs = svg('defs');
	for (const dir of directions) {
		const gradient = svg('linearGradient', { id: 'ow-fill-' + dir.key, x1: '0', y1: '0', x2: '0', y2: '1' }, [
			svg('stop', { offset: '0%', 'stop-color': dir.color, 'stop-opacity': '.24' }),
			svg('stop', { offset: '100%', 'stop-color': dir.color, 'stop-opacity': '.015' })
		]);
		defs.appendChild(gradient);
	}
	nodes.push(defs);
	const lines = [];
	for (const dir of directions) {
		const segments = []; let segment = [];
		for (const point of series) {
			if (!Number.isFinite(point[dir.key]) || (segment.length && point.time - segment[segment.length - 1].time > Math.max(15, (interval || 5) * 2))) {
				if (segment.length) segments.push(segment);
				segment = [];
			}
			if (Number.isFinite(point[dir.key])) segment.push(point);
		}
		if (segment.length) segments.push(segment);
		for (const part of segments) {
			const first = part[0], last = part[part.length - 1];
			let path = 'M' + x(first.time).toFixed(2) + ',' + y(first[dir.key]).toFixed(2);
			for (let i = 1; i < part.length; i++) {
				const prev = part[i - 1], point = part[i], mid = ((x(prev.time) + x(point.time)) / 2).toFixed(2);
				path += 'C' + mid + ',' + y(prev[dir.key]).toFixed(2) + ' ' + mid + ',' + y(point[dir.key]).toFixed(2) + ' ' + x(point.time).toFixed(2) + ',' + y(point[dir.key]).toFixed(2);
			}
			if (part.length > 1) {
				nodes.push(svg('path', { class: 'ow-area ow-area-' + dir.key, d: path + 'L' + x(last.time).toFixed(2) + ',' + y(0) + 'L' + x(first.time).toFixed(2) + ',' + y(0) + 'Z', fill: 'url(#ow-fill-' + dir.key + ')', stroke: 'none' }));
				lines.push(svg('path', { class: 'ow-series ow-series-' + dir.key, d: path, fill: 'none', stroke: dir.color, 'stroke-width': 2.3, 'stroke-linejoin': 'round', 'stroke-linecap': 'round', ...(dir.key === 'upload' ? { 'stroke-dasharray': '7 3' } : {}) }));
			} else lines.push(svg('circle', { class: 'ow-series ow-series-' + dir.key, cx: x(first.time), cy: y(first[dir.key]), r: 3, fill: dir.color }));
		}
	}
	nodes.push(...lines);
	if (!values.length) nodes.push(svg('text', { x: width / 2, y: height / 2, 'text-anchor': 'middle', class: 'ow-axis ow-chart-wait' }, [ '该时段暂无速率记录' ]));
	const cursor = svg('line', { class: 'ow-chart-cursor', y1: top, y2: height - bottom, stroke: '#83919c', 'stroke-width': 1, visibility: 'hidden', 'pointer-events': 'none' });
	const dots = directions.map(dir => svg('circle', { class: 'ow-chart-point', r: 4, fill: '#fff', stroke: dir.color, 'stroke-width': 2, visibility: 'hidden', 'pointer-events': 'none' }));
	const graph = svg('svg', { viewBox: '0 0 ' + width + ' ' + height, role: 'slider', tabindex: 0, 'aria-label': '上下行历史速率，左右方向键查看记录，Esc关闭提示', 'aria-valuemin': 0, 'aria-valuemax': Math.max(0, series.length - 1), 'aria-valuenow': Math.max(0, series.length - 1), class: 'ow-line-chart' }, nodes.concat([cursor], dots));
	const tipTime = span('ow-chart-tip-time'), tipRates = directions.map(() => span('ow-chart-tip-rate'));
	const tooltip = E('div', { class: 'ow-chart-tooltip', role: 'tooltip', hidden: true }, [tipTime].concat(tipRates));
	const labels = directions.map(dir => {
		const valid = series.filter(point => Number.isFinite(point[dir.key]));
		const latest = valid[valid.length - 1];
		return E('span', { class: 'ow-chart-series-label' }, [span('ow-color-dot ' + dir.key), span('ow-chart-name', dir.label), span('ow-chart-latest', latest ? model.formatBytes(latest[dir.key], true) + ' · ' + timeLabel(latest.time) : '暂无记录')]);
	});
	const element = E('div', { class: 'ow-chart' }, [ E('div', { class: 'ow-chart-label' }, labels.concat([span('ow-chart-unit', '刻度 ' + unitName)])), graph, tooltip ]);
	let selected = Math.max(0, series.length - 1);
	function nearest(time) {
		let index = 0;
		for (let i = 1; i < series.length; i++) if (Math.abs(series[i].time - time) < Math.abs(series[index].time - time)) index = i;
		return index;
	}
	function pointAt(event) {
		if (!series.length) return;
		const matrix = graph.getScreenCTM();
		if (!matrix) return;
		const point = graph.createSVGPoint(); point.x = event.clientX; point.y = event.clientY;
		const local = point.matrixTransform(matrix.inverse());
		if (local.x < left || local.x > width - right || local.y < top || local.y > height - bottom) { if (event.pointerType !== 'touch') onHover(null); return; }
		selected = nearest(now - seconds + (local.x - left) / (width - left - right) * seconds);
		onHover(series[selected].time);
	}
	graph.addEventListener('pointermove', pointAt);
	graph.addEventListener('pointerdown', pointAt);
	graph.addEventListener('pointerleave', event => { if (graph.isConnected && event.pointerType !== 'touch') onHover(null); });
	graph.addEventListener('focus', () => { if (series.length) onHover(series[selected].time); });
	graph.addEventListener('blur', () => { if (graph.isConnected) onHover(null); });
	graph.addEventListener('keydown', event => {
		if (event.key === 'Escape') { onHover(null); return; }
		if (!series.length || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
		event.preventDefault();
		selected = event.key === 'Home' ? 0 : event.key === 'End' ? series.length - 1 : Math.max(0, Math.min(series.length - 1, selected + (event.key === 'ArrowLeft' ? -1 : 1)));
		onHover(series[selected].time);
	});
	return { element, show(time) {
		if (time === null || !series.length || time < series[0].time || time > series[series.length - 1].time) {
			tooltip.hidden = true; cursor.setAttribute('visibility', 'hidden'); dots.forEach(dot => dot.setAttribute('visibility', 'hidden')); return;
		}
		selected = nearest(time);
		const point = series[selected];
		cursor.setAttribute('x1', x(point.time)); cursor.setAttribute('x2', x(point.time)); cursor.setAttribute('visibility', 'visible');
		const date = seconds > 86400 ? new Date(point.time * 1000).toLocaleDateString('zh-CN') + ' ' : '';
		text(tipTime, '时间：' + date + timeLabel(point.time));
		directions.forEach((dir, i) => {
			const valid = Number.isFinite(point[dir.key]);
			dots[i].setAttribute('visibility', valid ? 'visible' : 'hidden');
			if (valid) { dots[i].setAttribute('cx', x(point.time)); dots[i].setAttribute('cy', y(point[dir.key])); }
			text(tipRates[i], dir.label + '：' + (valid ? (point[dir.key] / unit).toFixed(2) + ' ' + unitName + (interval > 5 ? '（区间平均）' : '') : '无记录'));
		});
		tooltip.dataset.time = String(point.time); tooltip.hidden = false;
		graph.setAttribute('aria-valuenow', selected); graph.setAttribute('aria-valuetext', tipTime.textContent + '，' + tipRates.map(node => node.textContent).join('，'));
	} };
}

function createShell(options) {
	const refs = {}, routes = options.routes;
	const button = (name, label, callback) => E('button', { type: 'button', class: 'ow-icon-button', 'aria-label': label, title: label, click: callback }, icon(name));
	refs.version = span('ow-version');
	refs.cpu = span(); refs.memory = span(); refs.temperature = span(); refs.uploadHeader = span(); refs.downloadHeader = span();
	refs.updated = span('ow-updated');
	refs.pause = E('button', { type: 'button', class: 'ow-control', click: () => options.onPause(refs.pause) }, [ icon('pause'), '暂停刷新' ]);
	const menuItems = [
		[ 'dashboard', '系统概况', routes.home ], [ 'monitor', '状态监控', routes.bandwidth ],
		[ 'settings', '系统设置', routes.system ], [ 'network', '网络设置', routes.network ],
		[ 'flow', '流控分流', routes.flow ], [ 'wifi', 'AC管理' ], [ 'users', '认证计费' ],
		[ 'arrows', '行为管控' ], [ 'shield', '安全设置', routes.firewall ],
		[ 'check', '高级应用' ], [ 'tools', '应用工具' ], [ 'logs', '日志中心', routes.logs ]
	];
	const fallbackItems = menuItems.map(([ name, label, href ], index) => href ? E('a', {
			href, class: 'ow-nav-item' + (index === 0 ? ' is-active' : ''), 'aria-current': index === 0 ? 'page' : null,
			click: () => { refs.root.classList.remove('ow-mobile-open'); refs.toggle.setAttribute('aria-expanded', 'false'); }
		}, [ icon(name), span('ow-nav-label', label) ]) : E('button', { type: 'button', class: 'ow-nav-item is-pending', disabled: true, title: label + '页面将在后续阶段接入' }, [ icon(name), span('ow-nav-label', label), span('ow-pending-dot', '待接入') ]));
	const icons = { status: 'monitor', system: 'settings', network: 'network', services: 'apps', vpn: 'shield' };
	const groups = (options.menu || []).map(group => E('details', { class: 'ow-nav-group' }, [
		E('summary', { class: 'ow-nav-item' }, [ icon(icons[group.name] || 'apps'), span('ow-nav-label', group.title), span('ow-nav-chevron', '›') ]),
		E('div', { class: 'ow-nav-children' }, group.children.flatMap(child => {
			const url = options.url(group.name, child.name);
			const link = E('a', { href: url, class: 'ow-nav-child' }, child.title);
			return [ link ].concat(child.children.map(sub => E('a', { href: options.url(group.name, child.name, sub.name), class: 'ow-nav-grandchild' }, sub.title)));
		}))
	]));
	const items = options.menu ? [ fallbackItems[0] ].concat(groups) : fallbackItems.filter(item => item.tagName === 'A');
	refs.sidebar = E('aside', { class: 'ow-sidebar', id: 'ow-navigation', 'aria-label': '管理导航' }, [
		E('nav', {}, items),
		E('div', { class: 'ow-sidebar-note' }, [ span('', 'AOS CONSOLE'), span('', options.menu ? '管理页面' : '菜单加载失败') ])
	]);
	refs.toggle = E('button', { type: 'button', class: 'ow-menu-toggle', 'aria-label': '展开或收起导航', 'aria-expanded': 'true', 'aria-controls': 'ow-navigation', click: () => {
		if (window.matchMedia('(max-width: 700px)').matches) {
			refs.root.classList.toggle('ow-mobile-open');
			refs.toggle.setAttribute('aria-expanded', String(refs.root.classList.contains('ow-mobile-open')));
		}
		else {
			refs.root.classList.toggle('ow-nav-collapsed');
			refs.toggle.setAttribute('aria-expanded', String(!refs.root.classList.contains('ow-nav-collapsed')));
		}
	} }, icon('menu'));
	if (window.matchMedia('(max-width: 700px)').matches) refs.toggle.setAttribute('aria-expanded', 'false');
	const telemetry = (name, label, value) => E('div', { class: 'ow-telemetry' }, [ icon(name), span('', label + ' '), value ]);
	refs.routeHostname = E('div', { class: 'ow-route-host' });
	refs.routeState = E('div', { class: 'ow-route-state' });
	refs.routeLabel = E('div', { class: 'ow-route-label' }, '外网接口状态');
	refs.routeUptime = span(); refs.routeAddress = span();
	refs.routeCard = E('section', { class: 'ow-route-card' }, [
		E('div', { class: 'ow-route-main' }, [ refs.routeHostname, refs.routeState, refs.routeLabel ]),
		E('span', { class: 'ow-route-badge', 'aria-hidden': 'true' }, icon('checked'))
	]);
	const speed = card('实时速率', 'ow-speed-card');
	refs.upload = span('ow-rate-value'); refs.download = span('ow-rate-value');
	refs.rateNote = E('div', { class: 'ow-card-note' });
	speed.body.append(
		E('div', { class: 'ow-rate-pair' }, [
			E('div', { class: 'ow-rate-row upload' }, [ E('span', { class: 'ow-rate-icon' }, icon('up')), E('span', { class: 'ow-rate-text' }, [ refs.upload, span('ow-rate-label', '上行速率') ]) ]),
			E('div', { class: 'ow-rate-row download' }, [ E('span', { class: 'ow-rate-icon' }, icon('down')), E('span', { class: 'ow-rate-text' }, [ refs.download, span('ow-rate-label', '下行速率') ]) ])
		]),
		refs.rateNote);
	const connection = card('物理连接', 'ow-connection-card');
	refs.clients = span('ow-number'); refs.connections = span('ow-number');
	refs.wired = span(); refs.wireless = span(); refs.unknown = span('ow-unknown-clients');
	connection.body.append(E('div', { class: 'ow-connection-grid' }, [
		metric(refs.clients, '连接设备', () => showClients(refs, 'all'), '近两分钟有流量的内网终端；按 MAC 地址合并 IPv4 和 IPv6'),
		E('a', { class: 'ow-metric', href: routes.connections }, [ refs.connections, span('ow-metric-label', '连接数') ]),
		E('div', { class: 'ow-client-types' }, [
			E('button', { type: 'button', click: () => showClients(refs, '有线') }, [ E('i', { class: 'ow-type-dot wired' }), '有线: ', refs.wired ]),
			E('button', { type: 'button', click: () => showClients(refs, '无线') }, [ E('i', { class: 'ow-type-dot wireless' }), '无线: ', refs.wireless ]), refs.unknown
		])
	]), E('div', { class: 'ow-card-note' }, '连接设备统计近2分钟活跃终端'));
	const ports = card('接口状态', 'ow-interfaces-card', detailLink(routes.network, '查看内外网接口设置'));
	refs.wanCount = span('ow-number'); refs.lanCount = span('ow-number'); refs.poolCount = span('ow-number');
	refs.poolMetric = E('a', { href: routes.dhcp, class: 'ow-metric', title: '根据当前 IPv4 地址池配置、有效租约和静态保留地址估算' }, [ refs.poolCount, span('ow-metric-label', 'DHCP 池剩余') ]);
	refs.poolNote = E('div', { class: 'ow-card-note' }, '绿色：已连接　红色：已断开 · DHCP 池按 IPv4 配置和实际租约估算');
	refs.ports = E('div', { class: 'ow-ports' }); refs.portNodes = new Map();
	const escapePort = event => {
		if (!refs.root.isConnected) { document.removeEventListener('keydown', escapePort); return; }
		if (event.key === 'Escape' && refs.openPort) {
			event.preventDefault(); refs.openPort.element.focus({ preventScroll: true }); closePortDetails(refs);
		}
	};
	const outsidePort = event => {
		if (!refs.root.isConnected) { document.removeEventListener('pointerdown', outsidePort); return; }
		if (refs.openPort && !refs.openPort.wrapper.contains(event.target)) closePortDetails(refs);
	};
	const repositionPort = event => {
		if (!refs.root.isConnected) { window.removeEventListener('resize', repositionPort); document.removeEventListener('scroll', repositionPort, true); return; }
		if (refs.openPort && !refs.openPort.panel.contains(event.target)) positionPortDetails(refs.openPort);
	};
	document.addEventListener('pointerdown', outsidePort);
	document.addEventListener('keydown', escapePort);
	window.addEventListener('resize', repositionPort);
	document.addEventListener('scroll', repositionPort, true);
	ports.body.append(E('div', { class: 'ow-interface-metrics' }, [ metric(refs.wanCount, 'WAN 已启用'), metric(refs.lanCount, 'LAN 已启用'),
		refs.poolMetric
	]), refs.ports, refs.poolNote);
	const wifi = card('AC / 无线状态', 'ow-wireless-card', detailLink(routes.wireless, '查看本机无线设置'));
	refs.apUp = span('ow-wireless-number'); refs.apDown = span('ow-wireless-number'); refs.band24 = span('ow-wireless-number'); refs.band5 = span('ow-wireless-number');
	const wifiMetric = (name, label, value, state) => E('a', { href: routes.wireless, class: 'ow-wireless-metric ' + (state || '') }, [ E('span', { class: 'ow-wireless-ring' }, [ icon(name), name === 'wifi' ? span('ow-band-tag', label.startsWith('2.4') ? '2.4G' : '5G') : E('span') ]), span('ow-wireless-label', label), value ]);
	refs.wifiNote = E('div', { class: 'ow-card-note' });
	wifi.body.append(E('div', { class: 'ow-wireless-grid' }, [ wifiMetric('ap', '本机 AP 运行', refs.apUp, 'is-up'), wifiMetric('ap', '本机 AP 停用', refs.apDown, 'is-down'), wifiMetric('wifi', '2.4G 接入', refs.band24), wifiMetric('wifi', '5G 接入', refs.band5) ]), refs.wifiNote);
	refs.wifiLinks = Array.from(wifi.element.querySelectorAll('a'));
	refs.wifiCard = wifi.element;
	refs.period = E('select', { id: 'ow-period', 'aria-label': '协议流量统计时段', change: () => updateCharts(refs) }, [ E('option', { value: '1800' }, '近30分钟'), E('option', { value: '3600' }, '近1小时'), E('option', { value: '86400' }, '近1天') ]);
	const protocol = card('协议流量分布', 'ow-protocol-card', refs.period);
	refs.donut = E('div', { class: 'ow-donut', role: 'img', 'aria-label': '正在采集协议流量' });
	refs.totalTraffic = span('ow-donut-value');
	refs.donut.append(E('div', { class: 'ow-donut-center' }, [ refs.totalTraffic, span('', '采样流量') ]));
	refs.legend = E('div', { class: 'ow-legend' });
	refs.protocolNote = E('p', { class: 'ow-card-note' });
	protocol.body.append(E('div', { class: 'ow-protocol-layout' }, [ refs.donut, refs.legend ]), refs.protocolNote);
	refs.line = E('select', { id: 'ow-line', 'aria-label': '速率图线路', change: () => { refs.hoverTime = null; updateCharts(refs); } }, [ E('option', { value: 'all' }, '所有外网线路') ]);
	refs.historyPeriod = E('select', { id: 'ow-history-period', 'aria-label': '速率历史时段', change: () => { refs.hoverTime = null; return options.onHistoryPeriod && options.onHistoryPeriod(+refs.historyPeriod.value); } }, [ E('option', { value: '300' }, '近5分钟'), E('option', { value: '3600' }, '近1小时'), E('option', { value: '86400' }, '近1天'), E('option', { value: '1296000' }, '近15天') ]);
	const graphs = card('上下行速率记录', 'ow-graphs-card', E('div', { class: 'ow-chart-controls' }, [ refs.historyPeriod, refs.line, detailLink(routes.bandwidth, '查看实时带宽监控') ]));
	refs.graphs = E('div', { class: 'ow-graphs' });
	graphs.body.append(refs.graphs, E('div', { class: 'ow-card-note' }, '后台每5秒采集 · 本机持久保存15天 · 关闭浏览器仍记录 · 空白区间为未记录或采集中断'));
	refs.error = E('div', { class: 'ow-error', role: 'status', hidden: true });
	refs.main = E('main', { class: 'ow-main', id: 'ow-main', tabindex: '-1' }, [
		refs.error,
		E('div', { class: 'ow-dashboard-grid' }, [ refs.routeCard, speed.element, connection.element, ports.element, wifi.element, protocol.element, graphs.element ]),
		E('footer', { class: 'ow-page-footer' }, [ span('', 'AOS Console'), span('', options.preview ? '界面预览 · 以下为示例数据' : '本地设备管理 · 每5秒刷新') ])
	]);
	refs.stripDot = E('i', { class: 'ow-strip-dot' });
	refs.stripState = span('ow-strip-state-text', '状态未知');
	refs.stripUptime = span(); refs.stripAddress = span();
	const stripItem = (label, value) => E('span', { class: 'ow-strip-item' }, [ span('ow-strip-label', label), value ]);
	refs.strip = E('div', { class: 'ow-strip' }, [
		E('div', { class: 'ow-strip-left' }, [
			E('span', { class: 'ow-strip-state' }, [ refs.stripDot, refs.stripState ]),
			stripItem('外网接口: ', refs.stripUptime),
			stripItem('IP: ', refs.stripAddress)
		]),
		E('div', { class: 'ow-strip-right' }, [
			telemetry('temperature', 'CPU温度:', refs.temperature),
			telemetry('cpu', 'CPU:', refs.cpu),
			telemetry('memory', '内存:', refs.memory),
			span('ow-strip-sep'),
			refs.updated, refs.pause, button('refresh', '立即刷新数据', options.onRefresh)
		])
	]);
	refs.root = E('div', { class: 'ow-shell', id: 'ow-console' }, [
		E('a', { class: 'ow-skip-link', href: '#ow-main' }, '跳到系统概况'),
		E('header', { class: 'ow-topbar' }, [
			E('a', { class: 'ow-brand', href: routes.home }, [ span('ow-brand-name', 'AOS'), refs.version ]),
			E('div', { class: 'ow-header-actions' }, [
				options.preview ? span('ow-preview-badge', '示例数据 · 预览') : E('div', { class: 'ow-local-label', title: '本地设备管理；云绑定服务尚未接入' }, [ icon('cloud'), '本地管理' ]),
				E('a', { class: 'ow-icon-button', href: routes.home, 'aria-label': '系统概况首页', title: '首页' }, icon('home')),
				E('a', { class: 'ow-icon-button', href: routes.logs, 'aria-label': '查看系统日志', title: '系统日志' }, icon('logs')),
				E('a', { class: 'ow-session-link', href: routes.logout, title: '退出当前登录会话' }, [ icon('user'), '退出' ]), span('ow-language', '简体')
			])
		]),
		E('div', { class: 'ow-subbar' }, [ refs.toggle, E('h1', {}, '系统概况') ]),
		refs.sidebar,
		E('button', { type: 'button', class: 'ow-mobile-scrim', 'aria-label': '关闭导航', click: () => { refs.root.classList.remove('ow-mobile-open'); refs.toggle.setAttribute('aria-expanded', 'false'); refs.toggle.focus(); } }),
		E('div', { class: 'ow-workspace' }, [ refs.strip, refs.main ])
	]);
	// Hosted layout: lift the status strip into the persistent top bar so it
	// costs no extra vertical space above the dashboard grid.
	const hostHeader = document.querySelector('.console-header');
	if (hostHeader) {
		refs.root.classList.add('ow-hosted');
		const anchor = hostHeader.querySelector('#indicators') || hostHeader.querySelector('.console-logout');
		hostHeader.insertBefore(refs.strip, anchor || null);
	}
	window.matchMedia('(max-width: 700px)').addEventListener('change', event => {
		refs.toggle.setAttribute('aria-expanded', String(event.matches ? refs.root.classList.contains('ow-mobile-open') : !refs.root.classList.contains('ow-nav-collapsed')));
	});
	refs.root.addEventListener('keydown', event => {
		if (event.key === 'Escape' && refs.root.classList.contains('ow-mobile-open')) {
			refs.root.classList.remove('ow-mobile-open'); refs.toggle.setAttribute('aria-expanded', 'false'); refs.toggle.focus();
		}
	});
	return refs;
}

function ipFamily(address) { return String(address || '').indexOf(':') >= 0 ? 'ipv6' : 'ipv4'; }

function showClients(refs, filter) {
	const dialog = E('dialog', { class: 'ow-dialog', 'aria-labelledby': 'ow-dialog-title' });
	const close = E('button', { type: 'button', class: 'ow-icon-button', 'aria-label': '关闭终端列表', click: () => dialog.close() }, icon('close'));
	const rows = ((refs.latest || {}).connection || {}).clients;
	const pending = rows === null || rows === undefined;
	const matched = (rows || []).filter(row => filter === 'all' || row.type === filter);
	// 同一台双栈终端同时出现在两个分组里，但每个分组只展示对应地址族的地址。
	const groups = { ipv4: [], ipv6: [] };
	for (const row of matched) {
		const families = new Set((row.ips || []).map(ipFamily));
		for (const family of families) groups[family].push(row);
	}
	const familyAddresses = (row, family) => (row.ips || []).filter(ip => ipFamily(ip) === family);
	const labels = { ipv4: 'IPv4 设备', ipv6: 'IPv6 设备' };
	const empty = family => pending ? '正在采集活跃终端，请等待下一次刷新。'
		: '近两分钟未观测到带 ' + (family === 'ipv4' ? 'IPv4' : 'IPv6') + ' 地址的活跃终端。';
	const table = E('table', { class: 'ow-client-table' }, [ E('thead', {}, E('tr', {}, [ '设备名称', 'IP 地址', 'MAC 地址', '连接方式', '最近活动' ].map(label => E('th', {}, label)))),
		E('tbody') ]);
	const body = table.tBodies[0];
	const render = family => {
		const list = groups[family];
		body.replaceChildren(...(list.length ? list.slice(0, 200).map(row => E('tr', {}, [
			E('td', {}, row.name || '未命名设备'),
			E('td', {}, familyAddresses(row, family).map(ip => span('ow-client-ip', ip))),
			E('td', {}, row.mac || '未知'),
			E('td', {}, row.type),
			E('td', {}, timeLabel(row.lastSeen))
		])) : [ E('tr', {}, E('td', { colspan: '5' }, empty(family))) ]));
	};
	const tabs = [ 'ipv4', 'ipv6' ].map(family => E('button', { type: 'button', class: 'ow-client-tab', 'data-family': family, 'aria-pressed': 'false', click: () => select(family) }, [
		labels[family] + ' ', span('ow-client-tab-count', pending ? '—' : String(groups[family].length))
	]));
	function select(family) {
		tabs.forEach(tab => {
			const active = tab.dataset.family === family;
			tab.classList.toggle('is-active', active);
			tab.setAttribute('aria-pressed', String(active));
		});
		render(family);
	}
	select(!groups.ipv4.length && groups.ipv6.length ? 'ipv6' : 'ipv4');
	dialog.append(E('div', { class: 'ow-dialog-header' }, [ E('h2', { id: 'ow-dialog-title' }, filter === 'all' ? '连接设备' : filter + '终端'), close ]),
		E('p', { class: 'ow-card-note' }, '近2分钟连接跟踪采样快照 · 仅统计观测到流量的内网终端 · 按地址族区分，双栈终端在两个标签页均会出现 · 每个标签页最多展示200台'),
		E('div', { class: 'ow-client-tabs', role: 'group', 'aria-label': '按 IP 地址族筛选' }, tabs), E('div', { class: 'ow-table-scroll' }, table));
	refs.root.append(dialog);
	dialog.addEventListener('close', () => dialog.remove(), { once: true });
	dialog.addEventListener('click', event => { if (event.target === dialog) { const box = dialog.getBoundingClientRect(); if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) dialog.close(); } });
	dialog.showModal();
	close.focus();
}

function updateCharts(refs) {
	const data = refs.latest;
	if (!data) return;
	// 优先用采集器持久化的区间合计（刷新页面不清零），没有时退回本页内存采样。
	const served = data.protocolTotals && Array.isArray(data.protocolTotals[+refs.period.value]) ? data.protocolTotals[+refs.period.value] : null;
	const totals = served || model.protocolTotals(data.history, +refs.period.value, data.time), total = totals.reduce((sum, n) => sum + n, 0);
	const hasSample = served ? true : data.history.some(sample => sample.time > data.time - +refs.period.value && sample.protocols);
	let start = 0;
	const slices = totals.map((value, i) => { const end = start + (total ? value / total * 100 : 0); const slice = COLORS[i] + ' ' + start + '% ' + end + '%'; start = end; return slice; });
	refs.donut.style.background = total ? 'conic-gradient(' + slices.join(',') + ')' : '#e9edf2';
	text(refs.totalTraffic, hasSample ? model.formatBytes(total) : '—');
	refs.donut.setAttribute('aria-label', hasSample ? '协议采样流量 ' + model.formatBytes(total) + '，' + model.PROTOCOLS.map((name, i) => name + ' ' + model.formatBytes(totals[i])).join('，') : '尚无协议流量采样数据');
	refs.legend.replaceChildren(...model.PROTOCOLS.map((name, i) => E('div', { class: 'ow-legend-row' }, [ E('span', { class: 'ow-legend-swatch', style: 'background:' + COLORS[i] }), span('ow-legend-name', name), span('ow-legend-value', hasSample ? (total ? (totals[i] / total * 100).toFixed(1) : '0.0') + '%' : '—') ])));
	text(refs.protocolNote, served
		? '近30分钟 / 1小时 / 1天累计 · 本机每60秒采集并持久保存 · 采样估算，不含两次采样之间结束的连接'
		: (!data.accounting ? '连接流量计数不可用，无法计算协议流量。' : hasSample ? '自页面打开起采集 · TCP/UDP 等传输层协议 · 采样估算，不含采样间已结束的连接' : '正在采集协议流量，首个采样仅建立基线。'));
	const archive = data.trafficHistory;
	const history = archive ? archive.samples : [];
	if (refs.chartArchive === archive && refs.chartLine === refs.line.value) return;
	refs.chartArchive = archive; refs.chartLine = refs.line.value;
	const onHover = time => { refs.hoverTime = time; plots.forEach(plot => plot.show(time)); };
	const plots = [lineChart(history, refs.line.value, data.time, archive && archive.seconds, archive && archive.interval, onHover)];
	refs.graphs.replaceChildren(...plots.map(plot => plot.element));
	plots.forEach(plot => plot.show(refs.hoverTime == null ? null : refs.hoverTime));
}

// The pool number is only meaningful while dnsmasq actually serves DHCPv4 on that LAN.
// /etc/init.d/dnsmasq skips the range when its dhcp_check() probe sees another DHCP
// server answering on the same L2 segment (it records that in /tmp/run/dnsmasq.*.dhcp
// and refuses with "use 'option force 1' to override"), so a configured pool can sit at
// zero served clients forever. Showing the uci-derived number there would claim a
// healthy empty pool that does not exist, so withhold it and say why.
const DHCP_HINT = {
	active: '根据当前 IPv4 地址池配置、有效租约和静态保留地址估算',
	inactive: '地址池已在配置中启用，但 dnsmasq 没有在服务 DHCPv4：已配置地址池，却始终没有任何 IPv4 租约。常见原因是 AOS 的 dhcp_check() 探测到同一网段已有其他 DHCP 服务器应答，于是拒绝在该接口启动地址池，并把 /tmp/run/dnsmasq.<实例>.<接口>.dhcp 记为 1（日志：found already running DHCP-server，use \'option force 1\' to override）。可信的处理是先移除同网段多余的那台 DHCP 服务器；确认要覆盖此保护时，再到「网络 → DHCP/DNS」显式设置 option force 1。因此这里不显示剩余数量，避免把未生效的地址池显示成健康的空池。',
	unknown: '已配置 IPv4 地址池，但暂未观测到 IPv4 租约，还无法确认是否真的在分配地址；下一次刷新后重新判断。',
	unavailable: '未读取到 DHCP 配置或租约数据，无法估算地址池。'
};
const DHCP_TEXT = { active: 'DHCP 池剩余', inactive: '未生效', unknown: '状态未知', unavailable: '—' };

function renderDhcp(refs, data) {
	const state = DHCP_TEXT[data.dhcpState] ? data.dhcpState : 'unavailable';
	text(refs.poolCount, state === 'active' ? count(data.dhcpRemaining) : DHCP_TEXT[state]);
	// 未生效 is a warning, not a number: shrink and tint it so it is not read as a count.
	refs.poolCount.style.fontSize = state === 'inactive' ? '22px' : '';
	refs.poolCount.style.color = state === 'inactive' ? '#c4495c' : state === 'active' ? '' : '#8795a2';
	refs.poolMetric.setAttribute('title', DHCP_HINT[state]);
	refs.poolNote.textContent = state === 'inactive'
		? '绿色：已连接　红色：已断开 · DHCP 池已配置但未在分配地址，不显示不可信的剩余数量'
		: state === 'unknown' ? '绿色：已连接　红色：已断开 · DHCP 池剩余暂时无法确认'
		: '绿色：已连接　红色：已断开 · DHCP 池按 IPv4 配置和实际租约估算';
}

function update(refs, data, options) {
	refs.latest = data;
	text(refs.version, [ (data.board.release || {}).version, (data.board.release || {}).target ].filter(Boolean).join(' · ') || '版本信息不可用');
	text(refs.cpu, percent(data.cpuUsage)); text(refs.memory, percent(data.memoryUsage));
	text(refs.temperature, data.temperature === null ? '—' : data.temperature.toFixed(1) + '°C');
	refs.temperature.closest('.ow-telemetry').hidden = data.temperature === null;
	text(refs.uploadHeader, model.formatBytes(data.upload, true)); text(refs.downloadHeader, model.formatBytes(data.download, true));
	text(refs.routeHostname, data.board.hostname || 'AOS');
	const connectedText = data.connected === null ? '状态未知' : data.connected ? '已连接' : '未连接';
	text(refs.routeState, connectedText);
	text(refs.routeLabel, data.connected === null ? '正在检测外网状态' : data.connected ? '外网接口状态正常' : '外网接口未连接');
	refs.routeCard.classList.toggle('is-offline', data.connected === false);
	refs.routeCard.classList.toggle('is-unknown', data.connected === null);
	const address = data.wans.filter(iface => iface.up).flatMap(iface => (iface['ipv4-address'] || []).concat(iface['ipv6-address'] || []).map(addr => addr.address))[0];
	text(refs.stripState, connectedText);
	refs.stripDot.classList.toggle('is-offline', data.connected === false);
	refs.stripDot.classList.toggle('is-unknown', data.connected === null);
	text(refs.stripUptime, '已运行 ' + uptime(data.info.uptime));
	text(refs.stripAddress, address || (data.connected === null ? '接口数据不可用' : '等待外网地址'));
	text(refs.upload, model.formatBytes(data.upload, true)); text(refs.download, model.formatBytes(data.download, true));
	text(refs.rateNote, data.upload === null ? '正在采集 / 数据暂不可用' : '所有外网线路汇总');
	text(refs.clients, data.connection.clients === null ? '—' : data.connection.clients.length);
	text(refs.connections, count(data.connectionCount)); text(refs.wired, count(data.connection.wired)); text(refs.wireless, count(data.connection.wireless));
	const unknown = (data.connection.clients || []).filter(row => row.type === '未知').length;
	text(refs.unknown, unknown ? '未知: ' + unknown : '');
	text(refs.wanCount, count(data.wanCount)); text(refs.lanCount, count(data.lanCount));
	renderDhcp(refs, data);
	const keys = new Set();
	for (const iface of data.interfaces) {
		const key = iface.interface; keys.add(key);
		let item = refs.portNodes.get(key);
		if (!item) {
			item = createPortDetails(refs, key, options); refs.portNodes.set(key, item); refs.ports.append(item.wrapper);
		}
		const device = data.devices[iface.deviceName];
		const up = !!iface.up && (!device || !device.link || device.link.carrier !== false);
		item.element.classList.toggle('is-up', up); item.element.classList.toggle('is-down', !up);
		text(item.name, iface.interface); text(item.kind, iface.role + ' · ' + iface.deviceName); text(item.status, up ? '已连接' : '已断开');
		item.element.setAttribute('aria-label', iface.interface + ' · ' + (up ? '已连接' : '已断开') + '，查看接口详情');
		for (const [label, value] of interfaceDetails(iface, data)) {
			if (!item.fields.has(label)) {
				const valueNode = E('dd'); item.list.append(E('dt', {}, label), valueNode); item.fields.set(label, valueNode);
			}
			text(item.fields.get(label), value);
		}
		if (refs.openPort === item) positionPortDetails(item);
	}
	for (const [ key, item ] of refs.portNodes) if (!keys.has(key)) { if (refs.openPort === item) closePortDetails(refs); item.wrapper.remove(); refs.portNodes.delete(key); }
	text(refs.apUp, count(data.wifi.apUp)); text(refs.apDown, count(data.wifi.apDown)); text(refs.band24, count(data.wifi.bands[0])); text(refs.band5, count(data.wifi.bands[1]));
	refs.wifiCard.hidden = data.wifi.available && !data.wifi.radios;
	refs.root.classList.toggle('ow-no-wireless', refs.wifiCard.hidden);
	text(refs.wifiNote, !data.wifi.available ? '无线状态暂不可用 · 集中 AC 管理未接入' : !data.wifi.radios ? '未检测到无线设备 · 集中 AC 管理未接入' : '本机 AP 与已关联终端 · 集中 AC 管理未接入' + (data.wifi.bands[2] ? ' · 6GHz 接入: ' + data.wifi.bands[2] : ''));
	for (const link of refs.wifiLinks) {
		const absent = data.wifi.available && !data.wifi.radios;
		if (absent) { link.removeAttribute('href'); link.setAttribute('aria-disabled', 'true'); link.setAttribute('title', '未检测到无线设备'); }
		else { link.setAttribute('href', options.routes.wireless); link.removeAttribute('aria-disabled'); link.removeAttribute('title'); }
	}
	const devices = Array.from(new Set(data.wans.map(iface => iface.deviceName).concat((data.trafficHistory && data.trafficHistory.samples || []).flatMap(sample => Object.keys(sample.rates || {})))));
	const signature = devices.join('|');
	if (signature !== refs.lineSignature) {
		const selected = refs.line.value;
		refs.line.replaceChildren(E('option', { value: 'all' }, '所有外网线路'), ...devices.map(device => E('option', { value: device }, device)));
		refs.line.value = devices.includes(selected) ? selected : 'all'; refs.lineSignature = signature;
	}
	refs.error.hidden = !data.errors.length;
	text(refs.error, data.errors.length ? '部分数据读取失败：' + data.errors.join('、') + '。页面保留可用数据，将在下次刷新时重试。' : '');
	text(refs.updated, (options.preview ? '示例数据 · ' : '') + '更新于 ' + timeLabel(data.time) + ' · 每5秒刷新');
	updateCharts(refs);
}

return baseclass.extend({ createShell, update, icon, interfaceDetails });
