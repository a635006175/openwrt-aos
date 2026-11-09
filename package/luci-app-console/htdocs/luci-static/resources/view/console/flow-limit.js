// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 终端限速：逐设备（IPv4，可选绑定 MAC）限制上行/下行速率。
// 本机无 tc，限速为 nftables 丢包限速。

function targetLabel(rule, devices) {
	const device = devices.filter(item => item.ip === rule.ip)[0];
	return device && device.hostname ? device.hostname : '';
}

return flow.createView({
	title: '终端限速',
	intro: '为指定内网终端单独设置上行 / 下行速率上限。规则按 IPv4 地址匹配，可同时绑定 MAC 地址以防地址变化。',
	requiresLines: false,
	footnote: '限速通过 nftables 的 limit 直接丢弃超速报文实现，会出现丢包与重传，不做整形与队列调度。规则条数上限 256。',

	build(page) {
		const output = [flow.shapingNote(page)];
		page.ruleTable = flow.table(['名称 / 目标', '上行', '下行', '备注', '状态', '操作']);
		output.push(flow.panel('终端限速规则', [
			flow.node('p', 'flow-note', '启用的规则必须至少填写上行或下行之一；两个都为 0 时该规则不产生任何限制。'),
			E('div', { class: 'flow-inline flow-toolbar-inline' }, [
				page.button('添加规则', () => editRule(page, null), 'cbi-button-add'),
				page.button('从在线终端添加', () => pickDevice(page))
			]),
			page.ruleTable.element
		]));
		page.paintRules();
		return output;
	},

	paintRules() {
		const page = this;
		const devices = page.devices();
		const rules = page.draft.limit || [];
		const body = page.ruleTable && page.ruleTable.body;
		if (!body) return;
		if (!rules.length) {
			flow.empty(body, 6, '尚无终端限速规则。可点击「从在线终端添加」快速选择设备。');
			return;
		}
		body.replaceChildren(...rules.map((rule, index) => flow.row([
			E('div', {}, [
				flow.node('strong', '', rule.name),
				flow.node('div', 'cs-note', rule.ip + (rule.mac ? ' · ' + rule.mac : '') + (targetLabel(rule, devices) ? ' · ' + targetLabel(rule, devices) : ''))
			]),
			flow.formatKbps(rule.upKbps),
			flow.formatKbps(rule.downKbps),
			rule.comment || '—',
			rule.enabled ? E('span', { class: 'flow-badge ok' }, '已启用') : E('span', { class: 'flow-badge off' }, '已停用'),
			E('div', { class: 'flow-actions' }, [
				page.button('编辑', () => editRule(page, index)),
				page.button(rule.enabled ? '停用' : '启用', () => { rules[index].enabled = !rules[index].enabled; page.markDirty(); page.paintRules(); }),
				page.button('删除', () => { rules.splice(index, 1); page.markDirty(); page.rebuild(); }, 'cbi-button-remove')
			])
		])));
	},

	paint() { this.paintRules(); }
});

function pickDevice(page) {
	const devices = page.devices();
	if (!devices.length) { ui.addNotification(null, E('p', {}, '暂未发现内网终端，请先让设备通过本路由器上网。'), 'warning'); return; }
	const query = E('input', { type: 'search', placeholder: '搜索名称、MAC 或 IP', 'aria-label': '搜索终端' });
	const list = E('div', { class: 'flow-devices' });
	const render = () => {
		const keyword = query.value.trim().toLowerCase();
		const matched = devices.filter(item => [item.hostname, item.mac, item.ip].join(' ').toLowerCase().includes(keyword));
		if (!matched.length) { list.replaceChildren(flow.node('p', 'flow-note', '没有符合筛选条件的终端。')); return; }
		list.replaceChildren(...matched.slice(0, 64).map(device => E('div', { class: 'flow-device' }, [
			E('div', { class: 'flow-device-name' }, [
				flow.node('strong', '', device.hostname || device.mac || '未命名设备'),
				E('small', {}, [device.ip, device.mac ? ' · ' + device.mac : ''].join(''))
			]),
			page.button('选择', () => { ui.hideModal(); editRule(page, null, device); }, 'cbi-button-add')
		])));
	};
	query.addEventListener('input', render);
	render();
	flow.modal('从在线终端添加', [E('div', { class: 'flow-editor' }, [
		flow.node('p', 'flow-note', '终端来自 DHCP 租约与主机信息。选择后会自动填入 IP 与 MAC，可再修改速率。'),
		flow.field('搜索', query),
		list,
		E('div', { class: 'button-row' }, [page.button('取消', () => ui.hideModal())])
	])]);
}

function editRule(page, index, device) {
	const original = index == null ? null : page.draft.limit[index];
	const rule = original ? flow.clone(original) : {
		id: flow.uid(), name: device ? (device.hostname || device.ip) : '', enabled: false,
		ip: device ? device.ip : '', mac: device && device.mac ? device.mac : '',
		upKbps: 0, downKbps: 0, comment: ''
	};
	const name = E('input', { type: 'text', value: rule.name, maxlength: 64, placeholder: '例如 会议室电视' });
	const ip = E('input', { type: 'text', value: rule.ip, placeholder: '例如 192.168.1.50' });
	const mac = E('input', { type: 'text', value: rule.mac || '', placeholder: '可选，例如 aa:bb:cc:dd:ee:ff' });
	const up = flow.mbpsInput(rule.upKbps, '上行限速，0 表示不限速');
	const down = flow.mbpsInput(rule.downKbps, '下行限速，0 表示不限速');
	const comment = E('input', { type: 'text', value: rule.comment || '', maxlength: 120, placeholder: '可选备注' });
	const enabled = E('input', { type: 'checkbox', checked: rule.enabled || null });
	const error = E('div', { role: 'alert' });

	// 在线终端可以一键填入 IP / MAC
	const devices = page.devices();
	const picker = flow.option([['', '从在线终端选择…']].concat(devices.slice(0, 64).map(item => [item.ip, item.ip + (item.hostname ? ' · ' + item.hostname : '') + (item.mac ? ' · ' + item.mac : '')])), '');
	picker.addEventListener('change', () => {
		const device = devices.filter(item => item.ip === picker.value)[0];
		if (!device) return;
		ip.value = device.ip;
		if (device.mac) mac.value = device.mac;
		if (!name.value.trim()) name.value = device.hostname || device.ip;
	});

	const editor = E('div', { class: 'flow-editor' }, [
		error,
		flow.field('终端地址', E('div', { class: 'flow-picker' }, [ E('div', { class: 'flow-picker-row' }, [ picker ]), ip ]),
			'必须是被限速终端的 IPv4 地址，且该终端经过本路由器上网。'),
		flow.field('MAC 地址', mac, '可选。绑定 MAC 后只对同时匹配 IP 与 MAC 的报文限速；留空表示只按 IP。'),
		flow.field('名称', name, '用于页面与状态展示。'),
		flow.field('上行限速', E('div', { class: 'flow-inline' }, [ up, flow.node('span', 'flow-note', 'Mbps') ]), '单位是比特率，超出部分直接丢弃。'),
		flow.field('下行限速', E('div', { class: 'flow-inline' }, [ down, flow.node('span', 'flow-note', 'Mbps') ]), '单位是比特率，超出部分直接丢弃。'),
		flow.field('备注', comment),
		flow.field('启用规则', E('label', { class: 'flow-switch' }, [ enabled, '保存到草稿后仍需点击「保存并应用」' ])),
		E('div', { class: 'button-row' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('保存到草稿', () => {
				error.replaceChildren();
				try {
					if (!name.value.trim()) throw Error('请填写名称');
					if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip.value.trim())) throw Error('终端地址必须是 IPv4 地址');
					const upKbps = flow.kbpsOf(up), downKbps = flow.kbpsOf(down);
					if (enabled.checked && !upKbps && !downKbps) throw Error('启用规则时上行和下行至少要填写一项');
					const value = {
						id: rule.id, name: name.value.trim(), enabled: enabled.checked, ip: ip.value.trim(),
						upKbps, downKbps, comment: comment.value.trim()
					};
					if (mac.value.trim()) {
						const normalized = mac.value.trim().toLowerCase();
						if (!/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/.test(normalized)) throw Error('MAC 地址格式应为 aa:bb:cc:dd:ee:ff');
						value.mac = normalized;
					}
					const duplicate = (page.draft.limit || []).some((item, position) => position !== index && item.ip === value.ip && (item.mac || '') === (value.mac || ''));
					if (duplicate) throw Error('已存在相同地址的限速规则：' + value.ip);
					if (index == null) page.draft.limit.push(value);
					else page.draft.limit[index] = value;
					page.markDirty();
					ui.hideModal();
					page.rebuild();
				}
				catch (e) { error.replaceChildren(flow.node('p', 'alert-message error', e.message)); }
			}, 'cbi-button-save')
		])
	]);
	flow.modal(original ? '编辑终端限速' : '添加终端限速', [editor]);
}
