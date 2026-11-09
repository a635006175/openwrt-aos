// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';
'require uci';
'require ui';
'require poll';

// 把 LuCI 原生的 DHCP/DNS 页重排成可读性更好的布局：
// 顶部为地址池与租约概览，中间把 IPv4/IPv6 租约重绘成易读的明细卡片，
// 下方原生表单完整保留，页面底部按钮统一成一条固定在底部的操作条。
// 本模块只重排 DOM、不读不写配置，也不改变任何 cbi 表单的提交行为。

const LEASE_V4 = 'lease_status_table';
const LEASE_V6 = 'lease6_status_table';
const PLACEHOLDER = /没有已分配的租约|尚无任何配置/;

function secondsFromLease(value) {
	// LuCI 渲染的剩余时间是 "1h 17m 1s" / "3d 2h" 这类格式
	const m = String(value || '').trim().match(/^(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?$/i);
	if (!m) return null;
	const parts = m.slice(1).map(v => (v == null ? 0 : +v));
	if (parts.every(v => !v)) return null;
	return parts[0] * 86400 + parts[1] * 3600 + parts[2] * 60 + parts[3];
}

function friendlyRemain(value) {
	const n = secondsFromLease(value);
	if (n == null) return { text: value || '—', urgent: false };
	const urgent = n < 900;
	const d = Math.floor(n / 86400), h = Math.floor(n % 86400 / 3600), mi = Math.floor(n % 3600 / 60), s = n % 60;
	let text;
	if (d) text = d + ' 天 ' + h + ' 小时';
	else if (h) text = h + ' 小时 ' + mi + ' 分';
	else if (mi) text = mi + ' 分 ' + s + ' 秒';
	else text = s + ' 秒';
	return { text, urgent };
}

// 读取 LuCI 租约表：表头是第一行 tr.table-titles 里的 th，占位行是 tr.placeholder。
function readLeaseTable(table) {
	if (!table) return { headers: [], rows: [] };
	const headerRow = table.querySelector('tr.table-titles');
	const headers = headerRow ? Array.from(headerRow.children).map(th => th.textContent.trim()) : [];
	const rows = Array.from(table.querySelectorAll('tr'))
		.filter(tr => !tr.classList.contains('table-titles'))
		.filter(tr => !tr.classList.contains('placeholder'))
		.map(tr => Array.from(tr.children).map(td => td.textContent.trim()))
		.filter(cells => cells.length > 1 && !PLACEHOLDER.test(cells.join('')));
	return { headers, rows };
}

function metric(labelText, valueText, tone) {
	return E('div', { class: 'cn-dhcp-metric' }, [
		E('strong', { class: 'cn-dhcp-value' + (tone ? ' ' + tone : '') }, valueText),
		E('span', { class: 'cn-dhcp-label' }, labelText)
	]);
}

// 把一行租约数据变成 "标签 / 值" 列表，跳过大同小异的内部标识。
function leaseCard(headers, cells, addressIndex) {
	const address = cells[addressIndex] || '—';
	const remainIndex = headers.findIndex(h => /剩余时间/.test(h));
	const remain = remainIndex >= 0 ? friendlyRemain(cells[remainIndex]) : null;
	const pairs = [];
	for (let i = 0; i < cells.length; i++) {
		if (i === addressIndex || i === remainIndex) continue;
		if (!cells[i] || cells[i] === '—') continue;
		pairs.push(E('dt', {}, headers[i] || '—'), E('dd', {}, cells[i]));
	}
	return E('article', { class: 'cn-dhcp-lease' }, [
		E('div', { class: 'cn-dhcp-lease-head' }, [
			E('strong', { class: 'cn-dhcp-lease-ip' }, address),
			remain ? E('span', { class: 'cn-dhcp-lease-remain' + (remain.urgent ? ' urgent' : '') }, remain.text) : null
		].filter(Boolean)),
		pairs.length ? E('dl', { class: 'cn-dhcp-lease-fields' }, pairs) : null
	].filter(Boolean));
}

return baseclass.extend({
	start() {
		if (this.tick) return;
		this.tick = () => {
			const section = document.getElementById('cbi-dhcp');
			if (!section) return;
			try {
				this.mount(section);
				this.update(section);
			}
			catch (error) {
				const root = section.querySelector('.cn-dhcp');
				if (root) root.remove();
				section.classList.remove('cn-dhcp-native');
			}
		};
		poll.add(this.tick, 5);
		// 立即渲染一次；随后若容器尚未生成，用短间隔补几帧，避免等满一个 poll 周期。
		this.tick();
		let attempts = 0;
		const kick = () => {
			if (document.getElementById('cbi-dhcp')) { this.tick(); return; }
			if (++attempts < 80) window.setTimeout(kick, 50);
		};
		if (!document.getElementById('cbi-dhcp')) window.setTimeout(kick, 50);
	},

	mount(section) {
		// 样式由模块自行注入，避免依赖主题模板的逐页条件渲染。
		// 注意用固定静态路径：L.resource() 会加上构建期哈希前缀，主题的
		// 静态资源不在该前缀下，会 404。
		if (!document.getElementById('cn-dhcp-css')) {
			document.head.append(E('link', {
				id: 'cn-dhcp-css', rel: 'stylesheet', href: '/luci-static/console/dhcp.css'
			}));
		}
		section.classList.add('cn-dhcp-native');
		if (!section.querySelector('.cn-dhcp')) section.prepend(E('div', { class: 'cn-dhcp' }));
	},

	update(section) {
		const root = section.querySelector('.cn-dhcp');
		if (!root) return;
		// 正在编辑原生表单时不要重绘，避免打断输入或丢失焦点。
		if (root.contains(document.activeElement)) return;

		const v4Table = document.getElementById(LEASE_V4);
		const v6Table = document.getElementById(LEASE_V6);
		const v4 = readLeaseTable(v4Table);
		const v6 = readLeaseTable(v6Table);

		const pool = uci.sections('dhcp', 'dhcp').find(s => s.interface === 'lan');
		const start = pool && pool.start != null ? +pool.start : null;
		const limit = pool && pool.limit != null ? +pool.limit : null;
		const rangeText = (start != null && limit != null && limit > 0) ? (start + ' – ' + (start + limit - 1)) : '—';
		const staticCount = uci.sections('dhcp', 'host').length;

		const summary = E('section', { class: 'cn-panel cn-dhcp-summary' }, [
			E('div', { class: 'cn-dhcp-metrics' }, [
				metric('地址池范围', rangeText),
				metric('已分配 IPv4', String(v4.rows.length), v4.rows.length ? 'accent' : 'muted'),
				metric('已分配 IPv6', String(v6.rows.length), v6.rows.length ? 'accent' : 'muted'),
				metric('静态租约', String(staticCount))
			]),
			E('p', { class: 'cn-help' }, '以上为当前配置与实际租约。修改请在下方表单中进行，完成后使用页面底部“保存并应用”。')
		]);

		const v4AddrIndex = Math.max(0, v4.headers.findIndex(h => /IPv4 地址/.test(h)));
		const v6AddrIndex = Math.max(0, v6.headers.findIndex(h => /IPv6 地址/.test(h)));

		const v4Body = v4.rows.length
			? E('div', { class: 'cn-dhcp-leases' }, v4.rows.map(cells => leaseCard(v4.headers, cells, v4AddrIndex)))
			: E('p', { class: 'cn-dhcp-empty' }, '当前没有通过 DHCPv4 分配的地址。若内网设备仍能上网，说明它们使用的是手工配置或其他 DHCP 服务。');

		const v6Body = v6.rows.length
			? E('div', { class: 'cn-dhcp-leases' }, v6.rows.map(cells => leaseCard(v6.headers, cells, v6AddrIndex)))
			: E('p', { class: 'cn-dhcp-empty' }, '当前没有 IPv6 租约。');

		root.replaceChildren(
			summary,
			E('section', { class: 'cn-panel cn-dhcp-panel' }, [E('h3', {}, 'IPv4 租约'), v4Body]),
			E('section', { class: 'cn-panel cn-dhcp-panel' }, [E('h3', {}, 'IPv6 租约'), v6Body])
		);
	}
});
