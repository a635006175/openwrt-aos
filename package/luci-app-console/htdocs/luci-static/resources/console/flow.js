// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';
'require rpc';
'require ui';
'require view';

// 流控分流共享模型：rpcd（console-flow）封装、单位换算、通用表单/表格/弹窗，
// 以及全部子页共用的页面骨架（状态条 + 120 秒确认窗口 + 草稿保存）。
// 子页面只负责本页字段，其余字段原样随 draft 回传，revision 由后端校验。

const callState = rpc.declare({ object: 'console-flow', method: 'state', reject: true });
const callCheck = rpc.declare({ object: 'console-flow', method: 'check', params: ['config'], reject: true });
const callApply = rpc.declare({ object: 'console-flow', method: 'apply', params: ['config'], reject: true });
const callConfirm = rpc.declare({ object: 'console-flow', method: 'confirm', reject: true });
const callRollback = rpc.declare({ object: 'console-flow', method: 'rollback', reject: true });
const callResolve = rpc.declare({ object: 'console-flow', method: 'resolve', params: ['config'], reject: true });
const callReset = rpc.declare({ object: 'console-flow', method: 'reset', reject: true });

const SHAPING_NOTE = '内核未编译 tc 调度模块，本页限速为 nftables 丢包限速，不整形队列。';
const NO_LINE_HINT = '尚未添加外网线路。请先在「内外网设置」中添加外网接口（需要能获取默认网关），再回到「多线负载」页添加线路。';
const DEFAULT_TARGETS = ['223.5.5.5', '119.29.29.29'];
const RULE_LIMIT_NOTE = '保存会先整体校验再立即生效，并给出 120 秒确认窗口；窗口内未确认将自动回滚到上一份可用配置。';

function checked(result) { if (!result || result.error) throw Error(result?.error || '流控分流服务未响应'); return result; }
function clone(value) { return JSON.parse(JSON.stringify(value === undefined ? null : value)); }
function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 9); }
function node(tag, cls, content) { return E(tag, { class: cls }, content == null ? '' : content); }
function setting(el, value) { const next = value == null ? '' : String(value); if (el.textContent !== next) el.textContent = next; }
function field(title, input, help) {
	const id = input.id || ('flow-' + uid());
	input.id = id;
	return E('div', { class: 'cbi-value' }, [
		E('label', { class: 'cbi-value-title', for: id }, title),
		E('div', { class: 'cbi-value-field' }, [input, help ? E('div', { class: 'cbi-value-description' }, help) : ''])
	]);
}
function option(values, current) { return E('select', {}, values.map(([value, label]) => E('option', { value, selected: String(value) === String(current) || null }, label))); }
function panel(title, children, action) {
	return E('section', { class: 'cbi-section cs-panel flow-panel' }, [
		E('div', { class: 'flow-panel-head' }, [ E('h3', {}, title), action || E('span') ]),
		...[].concat(children || [])
	]);
}
function table(headers) {
	const body = E('tbody');
	return { body, element: E('div', { class: 'flow-scroll' }, E('table', { class: 'table flow-table' }, [
		E('thead', {}, E('tr', { class: 'tr table-titles' }, headers.map(header => E('th', { class: 'th' }, header)))),
		body
	])) };
}
function row(cells) { return E('tr', { class: 'tr' }, cells.map(cell => E('td', { class: 'td' }, cell))); }
function empty(body, columns, message) { body.replaceChildren(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: columns }, node('p', 'flow-note', message)))); }
function modal(title, children) {
	ui.showModal(title, children);
	const element = document.querySelector('#modal_overlay > .modal');
	if (element) element.classList.add('flow-modal');
}

// Kbps 是比特率：页面用 Mbps 输入（1 Mbps = 1000 Kbps），配置里存整数 Kbps。
function mbps(value) { const number = Number(value); return Number.isFinite(number) && number > 0 ? String(Math.round(number / 1000 * 1000) / 1000) : ''; }
function mbpsInput(value, placeholder) { return E('input', { type: 'number', min: 0, step: 0.001, value: mbps(value) || null, placeholder: placeholder || '0 表示不限速' }); }
function kbpsOf(input) {
	const value = Number(String(input.value == null ? '' : input.value).replace(/[^\d.]/g, ''));
	if (!Number.isFinite(value) || value <= 0) return 0;
	return Math.min(10000000, Math.round(value * 1000));
}
function formatKbps(value) {
	const number = Number(value) || 0;
	if (number <= 0) return '不限速';
	if (number < 1000) return number + ' Kbps';
	return (number / 1000).toFixed(number % 1000 ? 1 : 0) + ' Mbps';
}
function bytes(value) {
	if (value == null || !Number.isFinite(Number(value))) return '无数据';
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	let number = Number(value), index = 0;
	while (number >= 1024 && index < 4) { number /= 1024; index++; }
	return number.toFixed(index ? 2 : 0) + ' ' + units[index];
}
function time(value) { return value ? new Date(Number(value) * 1000).toLocaleString('zh-CN') : '—'; }

function draftConfig(config) {
	const draft = clone(config || {});
	draft.revision = Number(draft.revision) || 0;
	draft.enabled = draft.enabled === true;
	draft.lines = Array.isArray(draft.lines) ? draft.lines : [];
	draft.proto = Array.isArray(draft.proto) ? draft.proto : [];
	draft.port = Array.isArray(draft.port) ? draft.port : [];
	draft.domain = Array.isArray(draft.domain) ? draft.domain : [];
	draft.limit = Array.isArray(draft.limit) ? draft.limit : [];
	draft.load = Object.assign({ enabled: false, mode: 'weighted', sticky: true }, draft.load || {});
	draft.load.check = Object.assign({ enabled: true, interval: 10, fail: 3, up: 2, targets: DEFAULT_TARGETS.slice() }, draft.load.check || {});
	draft.updown = Object.assign({ enabled: false, upload: '', download: '', uploadKbps: 0, downloadKbps: 0 }, draft.updown || {});
	draft.smart = Object.assign({ enabled: false, perIpUpKbps: 0, perIpDownKbps: 0, totalUpKbps: 0, totalDownKbps: 0, exempt: [], maxDevices: 256 }, draft.smart || {});
	return draft;
}

function lineValues(draft, auto) {
	const values = auto === false ? [] : [['auto', '自动分配（按多线负载策略）']];
	for (const line of draft.lines || [])
		values.push([line.id, line.name + '（' + line.interface + '）' + (line.enabled ? '' : ' · 已停用')]);
	return values;
}
function lineSelect(draft, current, auto) {
	const values = lineValues(draft, auto);
	const select = option(values, current || (auto === false ? '' : 'auto'));
	if (current && !values.some(([value]) => String(value) === String(current)))
		select.append(E('option', { value: current, selected: true }, current + '（已移除）'));
	return select;
}
function lineLabel(draft, id) {
	if (!id || id === 'auto') return '自动分配';
	const line = (draft.lines || []).filter(item => item.id === id)[0];
	return line ? line.name : id + '（已移除）';
}
function lineGuide(page) {
	if ((page.draft.lines || []).length) return E('div', { class: 'flow-hidden' });
	return node('p', 'alert-message warning', NO_LINE_HINT + ' 在添加线路前，保存按钮保持禁用。');
}
function shapingNote(page) {
	const caps = (page.data && page.data.caps) || {};
	if (caps.shaping !== false) return E('div', { class: 'flow-hidden' });
	return E('div', { class: 'flow-shaping' }, [
		node('p', 'alert-message warning', SHAPING_NOTE),
		caps.limitNote ? node('p', 'flow-note', caps.limitNote + '。') : ''
	]);
}

// 共享页面骨架。definition 里的方法（paintXxx 等）会一并挂到视图类上，
// build/paint 由骨架按固定时序调用，页面无需关心状态条与确认窗口。
const core = {
	load() {
		return callState().then(result => {
			// 配置损坏时后端仍返回默认 config 与 error 文本：页面必须能打开并提示重置，
			// 因此这里只拦截“服务完全没有响应”的情况。
			if (!result) throw Error('流控分流服务未响应，请检查 rpcd 与 console-flow 服务状态');
			return result;
		});
	},

	button(label, task, kind) {
		return E('button', { type: 'button', class: 'cbi-button ' + (kind || ''), click: async event => {
			const target = event.currentTarget;
			if (target.disabled || this.busy) return;
			target.disabled = true;
			target.setAttribute('aria-busy', 'true');
			try { await task(); }
			catch (error) { ui.addNotification(null, E('p', {}, (error && error.message) || '操作失败'), 'error'); }
			finally {
				target.removeAttribute('aria-busy');
				if (!target.isConnected) return;
				if (this.guarded && this.guarded.has(target)) this.syncButtons();
				else target.disabled = false;
			}
		} }, label);
	},
	guard(button) { (this.guarded || (this.guarded = new Set())).add(button); return button; },
	saveButton(label, kind) { return this.guard(this.button(label, () => this.save(), kind)); },
	saveBlockReason() {
		if (L.hasViewPermission() !== true) return '当前账号没有写入权限，只能查看配置。';
		if (this.data && this.data.pending) return '上一次变更还在 120 秒确认窗口内，请先点击「确认生效」或「立即回滚」。';
		if (!(this.definition && this.definition.requiresLines === false) && !(this.draft.lines || []).length) return NO_LINE_HINT;
		return '';
	},
	canSave() { return !this.saveBlockReason(); },
	syncButtons() {
		if (!this.guarded) return;
		const blocked = !!this.busy || !this.canSave();
		for (const button of Array.from(this.guarded)) {
			if (!button.isConnected) { this.guarded.delete(button); continue; }
			button.disabled = blocked;
		}
	},
	markDirty() { this.dirty = true; setting(this.dirtyNote, '有未应用的修改'); this.syncButtons(); },
	setStatus(value) { if (this.statusText) setting(this.statusText, value || ''); },
	showError(message) { ui.addNotification(null, E('p', {}, message || '操作失败'), 'error'); },
	resetDraft() {
		if (this.busy) return;
		this.dirty = false;
		this.adoptConfig();
		this.rebuild();
		this.setStatus('已放弃未应用的修改');
	},
	adoptConfig() {
		const next = draftConfig(this.data && this.data.config);
		for (const key of Object.keys(this.draft)) if (!(key in next)) delete this.draft[key];
		Object.assign(this.draft, next);
	},
	candidates() {
		const topology = (this.data && this.data.topology) || {};
		const list = [], known = new Set();
		const add = item => {
			if (!item || !item.name || known.has(item.name)) return;
			known.add(item.name);
			list.push({ name: item.name, device: item.device || '', gateway: item.gateway || '', up: item.up !== false });
		};
		for (const item of [].concat(topology.candidates || [])) add(item);
		for (const item of [].concat(topology.interfaces || [])) add(item);
		return list;
	},
	devices() { return [].concat((this.data && this.data.devices) || []).filter(item => item && item.ip); },

	async save(message) {
		if (this.busy) return false;
		if (!this.canSave()) throw Error(this.saveBlockReason() || '当前无法保存');
		this.busy = true;
		this.syncButtons();
		this.setStatus('正在校验并应用…');
		try {
			const config = clone(this.draft);
			// rpc.declare 的 params:['config'] 表示「参数名 config」，调用时直接传配置本身；
			// 再包一层 { config } 会变成 {"config":{"config":{...}}}，后端拿到空对象。
			const preview = checked(await callCheck(config));
			const warnings = (preview.plan && preview.plan.warnings) || [];
			const result = checked(await callApply(config));
			if (result.state && result.state.config) {
				this.data = result.state;
				if (!this.data.pending && result.pending) this.data.pending = result.pending;
				this.dirty = false;
				this.adoptConfig();
				this.rebuild();
			}
			else {
				this.dirty = false;
				await this.reload(true);
			}
			this.showWarnings(warnings);
			setting(this.dirtyNote, '已应用');
			this.setStatus(message || '已应用，请在 120 秒内确认；超时自动回滚。');
			this.startClock();
			return true;
		}
		catch (error) {
			this.setStatus('应用失败：' + ((error && error.message) || '未知错误'));
			throw error;
		}
		finally { this.busy = false; this.syncButtons(); }
	},
	async reload(quiet) {
		if (this.loading) return;
		this.loading = true;
		try {
			const result = await callState();
			if (!result) throw Error('流控分流服务未响应');
			this.data = result;
			if (result.error) this.showServiceError(result.error);
			if (!this.dirty) { this.adoptConfig(); this.rebuild(); }
			else this.paintStatus();
			if (!quiet) this.setStatus('已刷新');
		}
		catch (error) { if (!quiet) this.showError((error && error.message) || '刷新失败'); }
		finally { this.loading = false; }
	},
	async confirmNow() {
		checked(await callConfirm());
		await this.reload(true);
		ui.addNotification(null, E('p', {}, '已确认生效，回滚计时已取消。'), 'info');
	},
	async rollbackNow() {
		checked(await callRollback());
		this.dirty = false;
		await this.reload(true);
		ui.addNotification(null, E('p', {}, '已回滚到上一份可用配置。'), 'info');
	},
	confirmReset() {
		modal('重置流控分流配置', [
			E('p', {}, '将清空全部线路、分流规则、终端限速规则与智能流控设置，并卸载 nft 表 inet console_flow 与策略路由规则。'),
			E('p', { class: 'flow-note' }, '上一份可用配置仍保留在 /etc/console-backup 中，需要时可手工恢复。'),
			E('div', { class: 'button-row' }, [
				this.button('取消', () => ui.hideModal()),
				this.button('重置', async () => {
					checked(await callReset());
					this.dirty = false;
					ui.hideModal();
					await this.reload(true);
					ui.addNotification(null, E('p', {}, '配置已重置，nft 表与策略路由已卸载。'), 'info');
				}, 'cbi-button-remove')
			])
		]);
	},

	statusArea() {
		this.dirtyNote = node('span', 'flow-note', '');
		this.statusText = node('span', 'flow-status', '');
		this.errorBox = E('div', { role: 'alert' });
		this.banner = E('div', { class: 'alert-message warning flow-banner' });
		this.pendingText = node('span', 'flow-pending-text', '');
		this.confirmButton = this.button('确认生效', () => this.confirmNow(), 'cbi-button-apply');
		this.rollbackButton = this.button('立即回滚', () => this.rollbackNow());
		this.pendingBar = E('div', { class: 'alert-message warning flow-pending', hidden: true }, [
			this.pendingText,
			E('div', { class: 'flow-pending-actions' }, [this.confirmButton, this.rollbackButton])
		]);
		return [this.banner, this.pendingBar, this.errorBox];
	},
	showServiceError(message) {
		if (!this.errorBox || !message) return;
		this.errorBox.replaceChildren(node('p', 'alert-message error', message));
	},
	showWarnings(warnings) {
		if (!this.errorBox) return;
		if (!warnings || !warnings.length) { this.errorBox.replaceChildren(); return; }
		this.errorBox.replaceChildren(node('p', 'alert-message warning', '已应用，但有以下提示：'), ...warnings.map(item => node('p', 'flow-note', '· ' + item)));
	},
	paintStatus() {
		const state = this.data || {}, draft = this.draft || {}, runtime = state.runtime || {}, pending = state.pending;
		if (pending) {
			this.pendingBar.hidden = false;
			if (this.secondsLeft == null) this.secondsLeft = Math.max(0, Math.round(Number(pending.secondsLeft) || 0));
			this.paintPending();
		}
		else { this.pendingBar.hidden = true; this.secondsLeft = null; }
		const lines = state.lines || [], online = lines.filter(line => line.up && !line.degraded).length;
		if (!draft.enabled) {
			this.banner.className = 'alert-message warning flow-banner';
			setting(this.banner, '流控分流尚未启用：本页配置可以保存，但不会产生任何分流或限速规则。打开「多线负载」页的总开关后才会生效。');
		}
		else if (!lines.length) {
			this.banner.className = 'alert-message warning flow-banner';
			setting(this.banner, '流控分流已启用，但没有可用线路：所有分流规则都不会生效。请到「多线负载」页添加外网线路。');
		}
		else if (runtime.tablePresent === false && !pending) {
			this.banner.className = 'alert-message warning flow-banner';
			setting(this.banner, '流控分流已启用，但内核中还没有本功能的 nft 表：可能刚重启或上次应用失败。请重新保存并应用一次。');
		}
		else {
			this.banner.className = (online ? 'alert-message success' : 'alert-message warning') + ' flow-banner';
			setting(this.banner, '流控分流已启用 · 线路 ' + online + '/' + lines.length + ' 在线' + (online < lines.length ? '（离线或降级的线路自动跳过）' : ''));
		}
		this.syncButtons();
	},
	paintPending() {
		if (this.secondsLeft == null || !this.pendingText) return;
		setting(this.pendingText, '新配置已生效，尚未确认：' + this.secondsLeft + ' 秒后自动回滚。请先确认当前上网正常，再点击「确认生效」；确认前暂不能再次保存。');
	},
	startClock() {
		if (this.clock) return;
		this.clock = window.setInterval(() => {
			if (!this.root || !this.root.isConnected) { window.clearInterval(this.clock); this.clock = null; return; }
			if (this.secondsLeft == null) return;
			this.secondsLeft = Math.max(0, this.secondsLeft - 1);
			this.paintPending();
			if (this.secondsLeft === 0) { this.secondsLeft = null; this.reload(true); }
		}, 1000);
	},

	render(data) {
		this.data = data || {};
		this.definition = this.definition || {};
		this.draft = draftConfig(this.data.config);
		this.dirty = false;
		this.busy = false;
		this.secondsLeft = null;
		this.guarded = new Set();
		if (!document.getElementById('console-security-css'))
			document.head.append(E('link', { id: 'console-security-css', rel: 'stylesheet', href: L.resource('console/security.css') }));
		if (!document.getElementById('console-flow-css'))
			document.head.append(E('link', { id: 'console-flow-css', rel: 'stylesheet', href: L.resource('console/flow.css') }));
		const status = this.statusArea();
		this.heading = E('div', { class: 'cs-heading flow-heading' }, [
			E('div', {}, [ E('h2', {}, this.definition.title), node('p', 'cs-note', this.definition.intro || '') ]),
			E('div', { class: 'cs-actions' }, [ this.dirtyNote, this.statusText, this.button('刷新', () => this.reload()) ])
		]);
		this.content = E('div');
		this.toolbar = E('div', { class: 'flow-toolbar' }, [
			this.saveButton('保存并应用', 'cbi-button-apply'),
			this.button('放弃修改', () => this.resetDraft()),
			this.button('重新读取', () => this.reload()),
			this.button('重置配置', () => this.confirmReset(), 'cbi-button-remove')
		]);
		this.root = E('div', { class: 'cbi-map cs-security flow-root' }, [ this.heading, ...status, this.content, this.toolbar ]);
		this.content.replaceChildren(...this.bodies());
		this.root.append(node('p', 'cs-note flow-footnote', (this.definition.footnote || '') + (this.definition.requiresLines === false ? '' : RULE_LIMIT_NOTE)));
		if (this.data.error) this.showServiceError(this.data.error);
		this.paintStatus();
		this.startClock();
		return this.root;
	},
	bodies() {
		if (typeof this.definition.build !== 'function') return [];
		return [].concat(this.definition.build(this) || []).filter(Boolean);
	},
	rebuild() {
		if (!this.content) return;
		this.content.replaceChildren(...this.bodies());
		this.paintStatus();
		if (typeof this.paint === 'function') this.paint();
		this.syncButtons();
	},
	handleSaveApply: null, handleSave: null, handleReset: null
};

function createView(definition) {
	const methods = Object.assign({}, core, definition);
	methods.definition = definition;
	methods.handleSaveApply = null;
	methods.handleSave = null;
	methods.handleReset = null;
	return view.extend(methods);
}

return baseclass.extend({
	state: callState, check: callCheck, apply: callApply, confirm: callConfirm,
	rollback: callRollback, resolve: callResolve, reset: callReset,
	checked, clone, uid, node, setting, field, option, panel, table, row, empty, modal,
	mbps, mbpsInput, kbpsOf, formatKbps, bytes, time,
	draftConfig, lineValues, lineSelect, lineLabel, lineGuide, shapingNote, createView,
	SHAPING_NOTE, NO_LINE_HINT, RULE_LIMIT_NOTE, DEFAULT_TARGETS
});
