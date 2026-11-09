// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const getStatus = rpc.declare({ object: 'console-vpn', method: 'status_detail', reject: true });

/* 本页只做展示：所有格式化与速率计算都在浏览器本地完成。
   后端不提供速率字段，速率由本页两次采样（现在 - 上次）的字节差除以经过的秒数得出。 */

const DASH = '—';

function finiteNumber(value) {
	if (value === null || value === undefined || value === '') return null;
	if (typeof value === 'boolean') return null;
	const number = Number(value);
	return Number.isFinite(number) ? number : null;
}

function byteCount(value) {
	const count = finiteNumber(value);
	return count === null || count < 0 ? null : Math.floor(count);
}

function formatBytes(value) {
	const count = byteCount(value);
	if (count === null) return DASH;
	const units = [ 'B', 'KiB', 'MiB', 'GiB' ];
	let number = count, unit = 0;
	while (number >= 1024 && unit < units.length - 1) { number /= 1024; unit++; }
	return (unit ? number.toFixed(1) : String(number)) + ' ' + units[unit];
}

function formatRate(value) {
	const rate = finiteNumber(value);
	return rate === null || rate < 0 ? DASH : formatBytes(rate) + '/s';
}

function formatDuration(value) {
	const seconds = finiteNumber(value);
	if (seconds === null || seconds < 0) return DASH;
	const total = Math.floor(seconds), days = Math.floor(total / 86400), hours = Math.floor(total % 86400 / 3600),
		minutes = Math.floor(total % 3600 / 60), rest = total % 60;
	if (days) return days + ' 天 ' + hours + ' 小时';
	if (hours) return minutes ? hours + ' 小时 ' + minutes + ' 分' : hours + ' 小时';
	if (minutes) return rest ? minutes + ' 分 ' + rest + ' 秒' : minutes + ' 分';
	return rest + ' 秒';
}

function formatClock(value) {
	const stamp = finiteNumber(value);
	if (stamp === null || stamp <= 0) return DASH;
	const date = new Date(stamp * 1000);
	if (Number.isNaN(date.getTime())) return DASH;
	const pad = part => String(part).padStart(2, '0');
	return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' +
		pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

function protocolLabel(value) {
	const text = String(value || '').toLowerCase();
	if (text === '') return '';
	if (text.indexOf('tcp') === 0) return 'TCP';
	if (text.indexOf('udp') === 0) return 'UDP';
	return text.toUpperCase();
}

/* 后端约定 realAddress 是纯地址、realPort 是端口；这里也容忍 realAddress 里
   带着 "proto:ip:port" 的整串形式，以及 IPv6 的方括号形式。 */
function sourceText(client) {
	let host = String(client.realAddress || '').trim(), port = String(client.realPort || '').trim(),
		protocol = String(client.protocol || '').trim();
	const packed = host.match(/^([A-Za-z][A-Za-z0-9_-]*):(\[[^\]]*\]|[^:\s]+):(\d+)$/);
	if (packed) { protocol = protocol || packed[1]; host = packed[2]; port = port || packed[3]; }
	if (host === '') return DASH;
	if (host.charAt(0) === '[' && host.charAt(host.length - 1) === ']') host = host.slice(1, -1);
	const address = host.indexOf(':') >= 0 ? '[' + host + ']' : host;
	const label = protocolLabel(protocol);
	return (port !== '' ? address + ':' + port : address) + (label !== '' ? ' · ' + label : '');
}

/* 计数器回退（客户端重连、服务端重启）或缺少基线时返回 null，页面显示“—”，
   绝不产生负数或 Infinity。 */
function deltaRate(previous, current, elapsedSeconds) {
	const before = finiteNumber(previous), after = finiteNumber(current), span = finiteNumber(elapsedSeconds);
	if (before === null || after === null || span === null || !(span > 0)) return null;
	if (after < before) return null;
	const rate = (after - before) / span;
	return Number.isFinite(rate) && rate >= 0 ? rate : null;
}

function clientKey(client) {
	return [ String(client.username || ''), String(client.realAddress || ''), String(client.realPort || '') ].join('\u0000');
}

/* 客户端链路状态机的显示文案。后端只给出 phase 与 label，
   这里负责把“进程是否在跑”和“隧道是否真的通了”区分开，避免误报为已连接。 */
function clientPhaseClass(link) {
	if (!link || link.running !== true) return 'label-info';
	if (link.connected === true) return 'label-success';
	if (link.phase === 'RECONNECTING' || link.phase === 'EXITING') return 'label-warning';
	return 'label-warning';
}

function kvRow(title, value) {
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td', style: 'width:30%' }, title),
		E('td', { class: 'td' }, value)
	]);
}

/* 采样间隔过大（暂停、标签页隐藏、请求超时）时平均值已无参考意义，按“无基线”处理。 */
const MAX_RATE_SPAN = 30;

/* 已连接客户端在前，未连接的已启用账号在后；两组都按账号名排序，保证轮询时行序稳定。 */
function mergeRows(accounts, clients) {
	const enabled = (accounts || []).filter(account => account && account.enabled && account.username);
	const connected = new Set((clients || []).map(client => String(client.username || '')));
	const online = (clients || []).map(client => ({
		username: String(client.username || DASH), online: true, client,
		account: enabled.filter(account => account.username === String(client.username || ''))[0] || null
	}));
	const offline = enabled.filter(account => !connected.has(String(account.username))).map(account => ({
		username: String(account.username), online: false, client: null, account
	}));
	const order = (left, right) => left.username.localeCompare(right.username, 'zh-Hans-CN');
	return online.sort(order).concat(offline.sort(order));
}

return view.extend({
	async load() {
		try { return await getStatus(); }
		catch (error) { return { error: error.message || '读取 OpenVPN 状态失败' }; }
	},

	showError(message) {
		this.errorNotice.replaceChildren(E('p', { class: 'alert-message error' }, '读取失败：' + message + '（保留上一次成功读取的数据）'));
		/* 首次读取就失败时不能停留在“读取中”，明确给出未知状态。 */
		if (!this.baseline) {
			this.serverStatus.className = 'badge label-warning';
			this.serverStatus.replaceChildren('状态未知');
			this.serverDetail.replaceChildren('暂时无法读取服务端状态。');
			this.statOnline.replaceChildren(DASH);
			this.statSent.replaceChildren(DASH);
			this.statReceived.replaceChildren(DASH);
			this.statUpdated.replaceChildren('未更新');
			this.table.replaceChildren(this.noticeRow('状态读取失败，暂无可显示的客户端数据。'));
		}
	},

	async refresh(force) {
		if (this.busy) return;
		if (!force && (this.paused || document.hidden)) return;
		this.busy = true;
		try { this.applyData(await getStatus()); }
		catch (error) { this.showError(error.message || '读取 OpenVPN 状态失败'); }
		finally { this.busy = false; }
	},

	togglePause() {
		this.paused = !this.paused;
		this.pauseButton.replaceChildren(this.paused ? '继续刷新' : '暂停刷新');
		this.pauseButton.setAttribute('aria-pressed', String(this.paused));
		/* 暂停期间的采样必然不连续，恢复后重新建立基线，速率先显示“—”。 */
		this.baseline = null;
		this.updated.replaceChildren('本页最近刷新 ' + formatClock(Math.floor(Date.now() / 1000)) + (this.paused ? ' · 已暂停' : ''));
		if (!this.paused) this.refresh(true);
	},

	cell(title, content) {
		return E('td', { class: 'td', 'data-title': title }, content);
	},

	noticeRow(content) {
		return E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: '10' }, content));
	},

	renderRow(row) {
		const client = row.client, account = row.account || {}, online = row.online;
		const address = online ? (client.virtualAddress || '未分配') : (account.address || '未分配');
		const rates = row.rates || {};
		return E('tr', { class: 'tr', style: online ? null : 'opacity:.6' }, [
			this.cell('账号', [ row.username + ' ', E('span', { class: 'badge ' + (online ? 'label-success' : 'label-info') }, online ? '在线' : '离线') ]),
			this.cell('分配 IP', address),
			this.cell('来源地址', online ? sourceText(client) : DASH),
			this.cell('在线时长', online ? formatDuration(client.connectedFor) : DASH),
			this.cell('空闲', online ? formatDuration(client.idleFor) : DASH),
			this.cell('接收', online ? formatBytes(client.bytesReceived) : DASH),
			this.cell('发送', online ? formatBytes(client.bytesSent) : DASH),
			this.cell('接收速率', online ? formatRate(rates.received) : DASH),
			this.cell('发送速率', online ? formatRate(rates.sent) : DASH),
			this.cell('连接时间', online ? formatClock(client.connectedSince) : DASH)
		]);
	},

	/* 客户端区：本机作为 OpenVPN 客户端连出去的那条链路。
	   它与上面的服务端客户列表是两件独立的事，必须分开显示，
	   否则会出现“服务端 0 个在线”却“隧道其实已经通了”的矛盾观感。 */
	paintClient(link, log) {
		const value = link || {};
		const running = value.running === true, connected = value.connected === true;

		this.clientStatus.className = 'badge ' + clientPhaseClass(value);
		this.clientStatus.replaceChildren(connected ? '已连接' : (value.label || (running ? '进程运行中' : '未连接')));
		this.clientDetail.replaceChildren(connected
			? [ '服务端 ' + (value.host || DASH) + ':' + (value.port || DASH),
				'隧道地址 ' + (value.tunnelAddress || DASH) + '/' + (value.tunnelPrefix || DASH),
				'对端 ' + (value.remoteAddress || DASH) + (value.remotePort ? ':' + value.remotePort : ''),
				'已连接 ' + formatDuration(value.phaseDuration) ].filter(Boolean).join(' · ')
			: (running
				? '客户端进程在运行，但隧道尚未打通：' + (value.label || '状态未知')
				: '当前未启用客户端，或客户端进程未运行。'));

		this.clientTable.replaceChildren(
			kvRow('连接状态', [ this.clientStatus ]),
			kvRow('服务端', (value.host || DASH) + (value.port ? ':' + value.port : '') + (value.protocol ? ' · ' + protocolLabel(value.protocol) : '')),
			kvRow('隧道地址', connected ? (value.tunnelAddress || DASH) + '/' + (value.tunnelPrefix || DASH) : DASH),
			kvRow('对端地址', value.remoteAddress ? value.remoteAddress + (value.remotePort ? ':' + value.remotePort : '') : DASH),
			kvRow('已连接时长', connected ? formatDuration(value.phaseDuration) : DASH),
			kvRow('隧道接收', value.statisticsAvailable ? formatBytes(value.bytesReceived) : DASH),
			kvRow('隧道发送', value.statisticsAvailable ? formatBytes(value.bytesSent) : DASH),
			kvRow('链路接收', value.statisticsAvailable ? formatBytes(value.linkBytesReceived) : DASH),
			kvRow('链路发送', value.statisticsAvailable ? formatBytes(value.linkBytesSent) : DASH)
		);

		/* 日志按原始顺序展示，末尾最新；空时给出明确说明而不是留白。 */
		const lines = Array.isArray(log) ? log : [];
		this.clientLog.replaceChildren(...(lines.length
			? lines.map(line => E('div', {}, line))
			: [ E('div', { class: 'cbi-value-description' }, running ? '暂无客户端日志。' : '客户端未运行，没有日志可显示。') ]));
		this.clientLogDetail.replaceChildren(lines.length ? lines.length + ' 行（最新在末尾）' : DASH);
	},

	applyData(data) {
		data = data || {};
		if (data.error) { this.showError(String(data.error)); return; }
		this.errorNotice.replaceChildren();

		const server = data.server || {}, available = data.statusAvailable === true;
		const clients = Array.isArray(data.clients) ? data.clients : [];
		const accounts = Array.isArray(data.accounts) ? data.accounts : [];
		const totals = available ? (data.totals || {}) : {};
		const sample = { at: Date.now(), entries: new Map() };

		for (const client of clients) sample.entries.set(clientKey(client), {
			received: finiteNumber(client.bytesReceived),
			sent: finiteNumber(client.bytesSent),
			connectedSince: finiteNumber(client.connectedSince)
		});

		const rows = mergeRows(accounts, clients).map(row => {
			if (!row.online) return row;
			const previous = this.baseline ? this.baseline.entries.get(clientKey(row.client)) : null;
			const current = sample.entries.get(clientKey(row.client));
			const elapsed = this.baseline ? (sample.at - this.baseline.at) / 1000 : null;
			/* 同一连接才有可比性：重连后连接时间会变化，此时不沿用旧基线。 */
			const comparable = !!previous && !!current && row.client.connectedSince !== null &&
				row.client.connectedSince !== undefined &&
				finiteNumber(previous.connectedSince) === finiteNumber(current.connectedSince) &&
				elapsed !== null && elapsed > 0 && elapsed <= MAX_RATE_SPAN;
			row.rates = comparable ? {
				received: deltaRate(previous.received, current.received, elapsed),
				sent: deltaRate(previous.sent, current.sent, elapsed)
			} : {};
			return row;
		});
		this.baseline = sample;

		const running = server.running === true, configured = server.configured === true;
		const protocol = protocolLabel(server.protocol);
		this.serverStatus.className = 'badge ' + (running ? 'label-success' : configured ? 'label-warning' : 'label-info');
		this.serverStatus.replaceChildren(running ? '服务进程运行中' : configured ? '已启用但进程未运行' : '未启用');
		this.serverDetail.replaceChildren(configured || running
			? [ '监听 ' + (protocol || DASH) + ' ' + (server.port || DASH),
				'连接地址 ' + (server.endpoint || '未填写'),
				server.pid ? 'PID ' + server.pid : null,
				server.uptime ? '已运行 ' + formatDuration(server.uptime) : null ].filter(Boolean).join(' · ')
			: '当前路由器未作为 OpenVPN 服务端启用，状态文件通常不存在。');

		const online = finiteNumber(totals.online);
		this.statOnline.replaceChildren(available ? String(online === null ? DASH : Math.max(0, Math.floor(online))) : DASH);
		this.statSent.replaceChildren(available ? formatBytes(totals.bytesSent) : DASH);
		this.statReceived.replaceChildren(available ? formatBytes(totals.bytesReceived) : DASH);
		const updatedAt = finiteNumber(data.updatedAt), age = updatedAt === null ? null : Math.floor(Date.now() / 1000) - updatedAt;
		this.statUpdated.replaceChildren(...(updatedAt === null ? [ '未更新' ] : [
			formatClock(updatedAt),
			E('div', { class: 'cbi-value-description' }, age !== null && age >= 0 ? '距今 ' + formatDuration(age) : DASH)
		]));

		this.warningNotice.replaceChildren(...(available ? [] : [
			E('p', { class: 'alert-message warning' }, 'OpenVPN 状态文件（/var/run/console-vpn/server.status）不可用，服务端可能未启用或尚未写入状态，因此暂时无法显示客户端连接明细。')
		]));

		const body = rows.map(row => this.renderRow(row));
		if (!available) body.push(this.noticeRow('OpenVPN 状态文件不可用，未列出任何客户端；启用并启动服务端后会显示真实连接。'));
		else if (!body.length) body.push(this.noticeRow([ '暂无已启用的账号，先到 ', E('a', { href: L.url('admin/vpn/console-accounts') }, 'OpenVPN 账号'), ' 页面新增。' ]));
		this.table.replaceChildren(...body);

		/* 客户端链路与日志：即使服务端状态不可用也要照常渲染。 */
		this.paintClient(data.client, data.clientLog);

		this.updated.replaceChildren('本页最近刷新 ' + formatClock(Math.floor(Date.now() / 1000)) + (this.paused ? ' · 已暂停' : ''));
	},

	render(data) {
		this.paused = false;
		this.busy = false;
		this.baseline = null;
		this.errorNotice = E('div');
		this.warningNotice = E('div');
		this.serverStatus = E('span', { class: 'badge label-info' }, '读取中');
		this.serverDetail = E('div', { class: 'cbi-value-description' });
		this.statOnline = E('strong');
		this.statSent = E('strong');
		this.statReceived = E('strong');
		this.statUpdated = E('span');
		this.table = E('tbody', { class: 'tbody' });
		this.clientStatus = E('span', { class: 'badge label-info' }, '读取中');
		this.clientDetail = E('div', { class: 'cbi-value-description' });
		this.clientTable = E('tbody', { class: 'tbody' });
		this.clientLog = E('pre', {
			style: 'max-height:340px;overflow:auto;margin:0;padding:8px 10px;' +
				'background:var(--background-color-low,#f5f5f5);border:1px solid var(--border-color-medium,rgba(0,0,0,.15));' +
				'border-radius:4px;font-size:12px;line-height:1.5;white-space:pre-wrap;word-break:break-all;'
		});
		this.clientLogDetail = E('span', { class: 'cbi-value-description' });
		this.pauseButton = E('button', { type: 'button', class: 'cbi-button', 'aria-pressed': 'false', click: () => this.togglePause() }, '暂停刷新');
		this.updated = E('span', { class: 'cbi-value-description' });

		const panel = E('div', { class: 'cbi-map' }, [
			E('h2', {}, 'OpenVPN 状态'),
			E('p', {}, '展示 OpenVPN 服务端当前已连接的客户端，以及本机作为客户端连出去的那条链路（含客户端日志），还有累计流量与实时速率。页面每 5 秒自动刷新；速率由本页相邻两次采样的字节差计算，首次采样显示“—”。'),
			this.errorNotice,
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '服务端'),
				E('div', { class: 'cbi-value' }, [
					E('div', { class: 'cbi-value-title' }, '服务状态'),
					E('div', { class: 'cbi-value-field' }, [ this.serverStatus, this.serverDetail ])
				]),
				E('table', { class: 'table cbi-section-table' }, [
					E('thead', {}, E('tr', { class: 'tr table-titles' }, [ '在线数', '服务器发出', '服务器接收', '状态文件更新时间' ].map(title => E('th', { class: 'th' }, title)))),
					E('tbody', { class: 'tbody' }, E('tr', { class: 'tr' }, [
						this.cell('在线数', this.statOnline), this.cell('服务器发出', this.statSent),
						this.cell('服务器接收', this.statReceived), this.cell('状态文件更新时间', this.statUpdated)
					]))
				]),
				E('p', { class: 'cbi-value-description' }, '“服务器发出”是服务端发往客户端的数据（对客户端来说是下载），“服务器接收”是客户端发往服务端的数据（对客户端来说是上传）；所以客户端自己的上传计入“服务器接收”。以上数字来自 OpenVPN 状态文件，服务端约每 10 秒重写一次。')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '客户端连接'),
				this.warningNotice,
				E('table', { class: 'table cbi-section-table' }, [
					E('thead', {}, E('tr', { class: 'tr table-titles' }, [ '账号', '分配 IP', '来源地址', '在线时长', '空闲', '接收', '发送', '接收速率', '发送速率', '连接时间' ].map(title => E('th', { class: 'th' }, title)))),
					this.table
				]),
				E('div', { class: 'button-row' }, [
					E('button', { type: 'button', class: 'cbi-button cbi-button-action', click: () => this.refresh(true) }, '立即刷新'), ' ',
					this.pauseButton, ' ', this.updated
				]),
				E('p', { class: 'cbi-value-description' }, '“接收 / 发送”为服务端视角的累计字节数。速率是本页最近两次采样的平均速度：首次采样、暂停后恢复首次采样、或客户端重连导致计数器回退时显示“—”，不会出现负数或无穷大。已启用但当前未连接的账号以灰色显示为“离线”。')
			]),
			/* ---- 本机作为客户端连出去的那条链路（与服务端无关） ---- */
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '本机客户端链路'),
				E('div', { class: 'cbi-value' }, [
					E('div', { class: 'cbi-value-title' }, '链路状态'),
					E('div', { class: 'cbi-value-field' }, [ this.clientDetail ])
				]),
				E('table', { class: 'table cbi-section-table' }, [ this.clientTable ]),
				E('p', { class: 'cbi-value-description' }, '这里显示的是本机作为 OpenVPN 客户端连往服务端的链路，与上方“服务端”的客户列表互相独立。状态来自 OpenVPN management 接口的连接状态机，“隧道接收 / 发送”为隧道口的累计字节，“链路接收 / 发送”为底层 UDP 链路的累计字节。')
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '客户端日志'),
				E('div', { class: 'cbi-value' }, [
					E('div', { class: 'cbi-value-title' }, '最新日志'),
					E('div', { class: 'cbi-value-field' }, this.clientLogDetail)
				]),
				this.clientLog,
				E('p', { class: 'cbi-value-description' }, '取自系统日志中属于客户端进程（openvpn[客户端 PID]）的行，已剔除服务端实例的日志；只显示最近 200 行，随页面每 5 秒刷新。')
			])
		]);

		this.applyData(data || {});

		this.root = panel;
		this.pollFn = () => {
			/* LuCI 在 render() 挂载前就启动轮询，视图卸载后必须自行摘除。 */
			if (!this.root.isConnected) {
				if (this.pollMounted) poll.remove(this.pollFn);
				return;
			}
			this.pollMounted = true;
			if (!this.paused && !document.hidden) return this.refresh();
		};
		poll.add(this.pollFn, 5);
		return panel;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
