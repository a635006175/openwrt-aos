// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 多线负载：线路（WAN 候选）管理 + 负载模式 + 线路探测，并承载流控分流的总开关。

const PROTOCOL_NOTE = '按权重分配：逐连接用权重轮询选线，同一连接固定线路；故障切换：只用优先级最高的可用线路。';

function stateBadge(line) {
	if (!line || !line.enabled) return E('span', { class: 'flow-badge off' }, '已停用');
	if (line.up && !line.degraded) return E('span', { class: 'flow-badge ok' }, '在线');
	if (line.up && line.degraded) return E('span', { class: 'flow-badge wait', title: '接口已上线但缺少默认网关或设备名，无法建立路由表' }, '降级');
	return E('span', { class: 'flow-badge error', title: '接口未上线或未获取地址' }, '离线');
}

return flow.createView({
	title: '多线负载',
	intro: '把多条外网线路合成一个出口：按权重逐连接分配，或只使用优先级最高的可用线路。线路来自「内外网设置」中已获取默认网关的外网接口。',
	footnote: '线路标识用于 fwmark 与路由表，创建后建议不要修改；停用线路不会删除其规则，只是不再参与分流。线路降级（无网关/未上线）时自动跳过，不会导致断网。',

	build(page) {
		const draft = page.draft;
		const output = [];
		output.push(flow.lineGuide(page));

		const master = E('input', { type: 'checkbox', checked: draft.enabled || null, change: event => {
			draft.enabled = event.target.checked;
			page.markDirty();
			page.paintStatus();
		} });
		output.push(flow.panel('总开关', [
			flow.field('启用流控分流', E('label', { class: 'flow-switch' }, [ master, '保存后按下方线路与各分流页面生成规则' ]),
				'总开关关闭时，所有分流与限速规则都不会下发，配置仍然保留。'),
			flow.node('p', 'flow-note', '本功能使用 nftables 独立表 inet console_flow 与编号 300 起的策略路由表，不影响原有防火墙与 mihomo 的标记。')
		]));

		// 先建表再放入面板：flow.table() 返回 { body, element }，
		// 直接把返回值当节点塞进 children 会被 E() 渲染成 "[object Object]"。
		page.lineTable = flow.table(['名称 / 标识', '接口', '权重', '上行带宽', '下行带宽', '运行状态', '操作']);
		output.push(flow.panel('线路', [
			flow.node('p', 'flow-note', '权重只影响「按权重分配」模式；权重为 0 的线路不参与分配。上下行带宽用于上下行分离与提示，填 0 表示不限速。'),
			E('div', { class: 'flow-toolbar-inline' }, [ page.button('添加线路', () => editLine(page, null), 'cbi-button-add') ]),
			page.lineTable.element
		]));

		const mode = flow.option([['weighted', '按权重分配（逐连接）'], ['failover', '故障切换（只用最高优先级线路）']], draft.load.mode);
		mode.addEventListener('change', () => { draft.load.mode = mode.value; page.markDirty(); });
		const sticky = E('input', { type: 'checkbox', checked: draft.load.sticky !== false || null, change: event => { draft.load.sticky = event.target.checked; page.markDirty(); } });
		const loadSwitch = E('input', { type: 'checkbox', checked: draft.load.enabled || null, change: event => { draft.load.enabled = event.target.checked; page.markDirty(); page.paintStatus(); } });
		output.push(flow.panel('多线负载', [
			flow.field('启用多线负载', E('label', { class: 'flow-switch' }, [ loadSwitch, '未启用时只有线路 1 承载新建连接' ])),
			flow.field('分配模式', mode, PROTOCOL_NOTE),
			flow.field('连接粘滞', E('label', { class: 'flow-switch' }, [ sticky, '同一连接固定使用原线路（conntrack 标记回写）' ]),
				'开启后已建立的连接不会因权重变化或线路抖动而换线，避免下载、视频中断。')
		]));

		const check = draft.load.check;
		const checkSwitch = E('input', { type: 'checkbox', checked: check.enabled !== false || null, change: event => { check.enabled = event.target.checked; page.markDirty(); } });
		const interval = E('input', { type: 'number', min: 5, max: 300, value: check.interval || 10 });
		interval.addEventListener('input', () => { check.interval = Math.max(5, Math.min(300, Number(interval.value) || 10)); page.markDirty(); });
		const fail = E('input', { type: 'number', min: 1, max: 10, value: check.fail || 3 });
		fail.addEventListener('input', () => { check.fail = Math.max(1, Math.min(10, Number(fail.value) || 3)); page.markDirty(); });
		const up = E('input', { type: 'number', min: 1, max: 10, value: check.up || 2 });
		up.addEventListener('input', () => { check.up = Math.max(1, Math.min(10, Number(up.value) || 2)); page.markDirty(); });
		const targets = E('input', { type: 'text', value: (check.targets || []).join(' '), placeholder: '223.5.5.5 119.29.29.29' });
		targets.addEventListener('input', () => {
			check.targets = targets.value.split(/[\s,;]+/).map(item => item.trim()).filter(Boolean).slice(0, 4);
			page.markDirty();
		});
		output.push(flow.panel('线路探测', [
			flow.field('启用探测', E('label', { class: 'flow-switch' }, [ checkSwitch, '定期探测各线路的默认网关' ]),
				'关闭后不再判定线路存活，线路按接口状态直接可用。'),
			flow.field('探测间隔', E('div', { class: 'flow-inline' }, [ interval, flow.node('span', 'flow-note', '秒') ]), '5 到 300 秒。'),
			flow.field('连续失败次数', E('div', { class: 'flow-inline' }, [ fail, flow.node('span', 'flow-note', '次后判定为故障') ]), '1 到 10 次。'),
			flow.field('恢复成功次数', E('div', { class: 'flow-inline' }, [ up, flow.node('span', 'flow-note', '次后恢复使用') ]), '1 到 10 次。'),
			flow.field('探测目标', targets, '1 到 4 个 IPv4 地址，用空格分隔。建议使用运营商 DNS 或公共 DNS。')
		]));

		page.paintLines();
		return output;
	},

	paintLines() {
		const page = this;
		const draft = page.draft || {};
		const runtime = (page.data && page.data.lines) || [];
		const lines = draft.lines || [];
		const body = page.lineTable && page.lineTable.body;
		if (!body) return;
		if (!lines.length) {
			flow.empty(body, 7, '尚未添加线路。请点击「添加线路」选择一条已获取默认网关的外网接口。');
			return;
		}
		body.replaceChildren(...lines.map((line, index) => {
			const live = runtime.filter(item => item.id === line.id)[0] || {};
			const runtimeCell = E('div', { class: 'flow-line-state' }, [
				stateBadge(Object.assign({ enabled: line.enabled }, live, { enabled: line.enabled })),
				flow.node('span', '', live.gateway ? '网关 ' + live.gateway : '无默认网关'),
				flow.node('span', '', live.device ? live.device : '无设备'),
				flow.node('span', '', (live.addresses || []).join('、') || '无地址')
			]);
			return flow.row([
				E('div', {}, [ flow.node('strong', '', line.name), flow.node('div', 'cs-note', line.id) ]),
				line.interface,
				String(line.weight == null ? 1 : line.weight),
				flow.formatKbps(line.upKbps),
				flow.formatKbps(line.downKbps),
				runtimeCell,
				E('div', { class: 'flow-actions' }, [
					page.button('编辑', () => editLine(page, index)),
					page.button(line.enabled ? '停用' : '启用', () => toggleLine(page, index)),
					page.button('删除', () => removeLine(page, index), 'cbi-button-remove')
				])
			]);
		}));
	},

	paint() { this.paintLines(); }
});

function toggleLine(page, index) {
	const line = page.draft.lines[index];
	if (!line) return;
	line.enabled = !line.enabled;
	page.markDirty();
	page.paintLines();
	page.paintStatus();
}

function removeLine(page, index) {
	const line = page.draft.lines[index];
	if (!line) return;
	const draft = page.draft;
	const usage = [];
	const scan = (list, key, label) => (list || []).forEach(rule => { if (rule.line === line.id) usage.push(label + '「' + rule.name + '」'); });
	scan(draft.proto, 'line', '协议分流');
	scan(draft.port, 'line', '端口分流');
	scan(draft.domain, 'line', '域名分流');
	if (draft.updown && (draft.updown.upload === line.id || draft.updown.download === line.id)) usage.push('上下行分离');
	ui.showModal('删除线路', [
		E('p', {}, '确定删除线路「' + line.name + '」（' + line.interface + '）？'),
		usage.length ? E('p', { class: 'alert-message warning' }, '以下规则正在引用该线路，删除后需要改为「自动分配」：' + usage.join('、')) : E('p', { class: 'flow-note' }, '当前没有规则引用该线路。'),
		E('div', { class: 'button-row flow-editor' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('删除', () => {
				draft.lines.splice(index, 1);
				for (const rule of [].concat(draft.proto, draft.port, draft.domain)) if (rule.line === line.id) rule.line = 'auto';
				if (draft.updown) {
					if (draft.updown.upload === line.id) draft.updown.upload = '';
					if (draft.updown.download === line.id) draft.updown.download = '';
				}
				page.markDirty();
				ui.hideModal();
				page.rebuild();
			}, 'cbi-button-remove')
		])
	]);
}

function editLine(page, index) {
	const original = index == null ? null : page.draft.lines[index];
	const draft = page.draft;
	const line = original ? flow.clone(original) : {
		id: 'wan' + ((draft.lines || []).length + 1), name: '线路 ' + ((draft.lines || []).length + 1),
		interface: page.candidates()[0] ? page.candidates()[0].name : '', weight: 1, enabled: true, upKbps: 0, downKbps: 0
	};
	const candidates = page.candidates();
	const id = E('input', { type: 'text', value: line.id, maxlength: 32, placeholder: '例如 wan2' });
	if (original) { id.disabled = true; id.title = '线路标识参与 fwmark 与路由表编号，创建后不可修改'; }
	const name = E('input', { type: 'text', value: line.name, maxlength: 64, placeholder: '例如 电信 500M' });
	const interfaceValues = candidates.map(item => [item.name, item.name + (item.device ? ' · ' + item.device : '') + (item.gateway ? ' · 网关 ' + item.gateway : ' · 无网关')]);
	const iface = flow.option(interfaceValues, line.interface);
	if (line.interface && !interfaceValues.some(([value]) => value === line.interface))
		iface.append(E('option', { value: line.interface, selected: true }, line.interface + '（已移除）'));
	const weight = E('input', { type: 'number', min: 0, max: 100, value: line.weight == null ? 1 : line.weight });
	const up = flow.mbpsInput(line.upKbps, '上行带宽，0 表示不限速');
	const down = flow.mbpsInput(line.downKbps, '下行带宽，0 表示不限速');
	const enabled = E('input', { type: 'checkbox', checked: line.enabled !== false || null });
	const error = E('div', { role: 'alert' });

	const editor = E('div', { class: 'flow-editor' }, [
		error,
		candidates.length ? '' : flow.node('p', 'alert-message warning', flow.NO_LINE_HINT),
		flow.field('线路标识', id, '只能包含字母、数字、下划线和减号，以字母或数字开头；创建后不可修改。'),
		flow.field('线路名称', name, '显示在规则与状态中的名称。'),
		flow.field('接口', iface, '列表来自已获取默认网关的外网接口；接口未上线时线路会被自动降级。'),
		flow.field('权重', weight, '0 到 100，仅「按权重分配」模式使用；权重越大分配到的连接越多。'),
		flow.field('上行带宽', up, '单位 Mbps，填 0 表示不限速；仅用于上下行分离与页面对照。'),
		flow.field('下行带宽', down, '单位 Mbps，填 0 表示不限速。'),
		flow.field('启用线路', E('label', { class: 'flow-switch' }, [ enabled, '保存后参与分流' ])),
		E('div', { class: 'button-row' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('保存到草稿', () => {
				error.replaceChildren();
				try {
					const value = {
						id: id.value.trim() || line.id, name: name.value.trim(), interface: iface.value,
						weight: Math.max(0, Math.min(100, Number(weight.value) || 0)),
						enabled: enabled.checked, upKbps: flow.kbpsOf(up), downKbps: flow.kbpsOf(down)
					};
					if (!value.name) throw Error('请填写线路名称');
					if (!value.interface) throw Error('请选择线路接口，若列表为空请先在「内外网设置」中添加外网接口');
					if (original) draft.lines[index] = value;
					else {
						if (draft.lines.some(item => item.id === value.id)) throw Error('线路标识已存在：' + value.id);
						draft.lines.push(value);
					}
					page.markDirty();
					ui.hideModal();
					page.rebuild();
				}
				catch (e) { error.replaceChildren(flow.node('p', 'alert-message error', e.message)); }
			}, 'cbi-button-save')
		])
	]);
	flow.modal(original ? '编辑线路' : '添加线路', [editor]);
}
