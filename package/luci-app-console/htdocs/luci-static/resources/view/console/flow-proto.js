// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 协议分流：按 L4 协议 + 目的端口 + 源网段指定线路。

const PROTOCOLS = [['tcp', 'TCP'], ['udp', 'UDP'], ['tcp+udp', 'TCP + UDP']];

return flow.createView({
	title: '协议分流',
	intro: '按传输层协议与目的端口把新建连接指定到某条线路。规则从上到下匹配，命中第一条后不再继续。',
	footnote: '规则只作用于新建连接，已建立的会话保持原线路；停用或删除规则不会切断现有连接。留空目的端口表示该协议的全部端口。',

	build(page) {
		const output = [flow.lineGuide(page)];
		page.ruleTable = flow.table(['名称', '协议 / 端口', '源网段', '目标线路', '状态', '操作']);
		output.push(flow.panel('协议分流规则', [
			flow.node('p', 'flow-note', '最多 512 条（含端口分流与域名分流）。端口写法与「端口映射」一致：80,443,8000-8100，单条最多 16 段。'),
			E('div', { class: 'flow-toolbar-inline' }, [ page.button('添加规则', () => editRule(page, null), 'cbi-button-add') ]),
			page.ruleTable.element
		]));
		page.paintRules();
		return output;
	},

	paintRules() {
		const page = this;
		const rules = page.draft.proto || [];
		const body = page.ruleTable && page.ruleTable.body;
		if (!body) return;
		if (!rules.length) {
			flow.empty(body, 6, '尚无协议分流规则，点击「添加规则」创建。');
			return;
		}
		body.replaceChildren(...rules.map((rule, index) => flow.row([
			E('div', {}, [ flow.node('strong', '', rule.name), flow.node('div', 'cs-note', rule.id) ]),
			(rule.protocol || 'tcp').toUpperCase() + ' · ' + (rule.ports || '全部端口'),
			rule.src || '任意来源',
			flow.lineLabel(page.draft, rule.line),
			rule.enabled ? E('span', { class: 'flow-badge ok' }, '已启用') : E('span', { class: 'flow-badge off' }, '已停用'),
			E('div', { class: 'flow-actions' }, [
				page.button('编辑', () => editRule(page, index)),
				page.button('复制', () => copyRule(page, index)),
				page.button(rule.enabled ? '停用' : '启用', () => { rules[index].enabled = !rules[index].enabled; page.markDirty(); page.paintRules(); }),
				page.button('删除', () => { rules.splice(index, 1); page.markDirty(); page.rebuild(); }, 'cbi-button-remove')
			])
		])));
	},

	paint() { this.paintRules(); }
});

function copyRule(page, index) {
	const copy = flow.clone(page.draft.proto[index]);
	copy.id = flow.uid();
	copy.name = (copy.name + ' 副本').slice(0, 64);
	copy.enabled = false;
	page.draft.proto.splice(index + 1, 0, copy);
	page.markDirty();
	page.rebuild();
}

function editRule(page, index) {
	const original = index == null ? null : page.draft.proto[index];
	const rule = original ? flow.clone(original) : {
		id: flow.uid(), name: '', enabled: false, protocol: 'tcp', ports: '', src: '', dst: '', line: 'auto'
	};
	const name = E('input', { type: 'text', value: rule.name, maxlength: 64, placeholder: '例如 UDP 游戏走线路 2' });
	const protocol = flow.option(PROTOCOLS, rule.protocol);
	const ports = E('input', { type: 'text', value: rule.ports, placeholder: '例如 80,443,8000-8100；留空表示全部端口' });
	const src = E('input', { type: 'text', value: rule.src, placeholder: '例如 192.168.1.0/24，留空表示任意来源' });
	const dst = E('input', { type: 'text', value: rule.dst || '', placeholder: '留空表示任意目标' });
	const line = flow.lineSelect(page.draft, rule.line || 'auto');
	const enabled = E('input', { type: 'checkbox', checked: rule.enabled || null });
	const error = E('div', { role: 'alert' });

	const editor = E('div', { class: 'flow-editor' }, [
		error,
		flow.field('名称', name, '用于页面与告警中标识这条规则。'),
		flow.field('协议', protocol),
		flow.field('目的端口', ports, '逗号分隔的数字或「起始-结束」，单条最多 16 段，端口段之间不能重叠。'),
		flow.field('源网段', src, 'IPv4 地址或 CIDR，多个用逗号分隔；留空表示内网全部来源。'),
		flow.field('目标网段', dst, '可留空。填写后只对访问该网段的新连接生效。'),
		flow.field('目标线路', line, '选「自动分配」时按多线负载策略决定。'),
		flow.field('启用规则', E('label', { class: 'flow-switch' }, [ enabled, '保存到草稿后仍需点击「保存并应用」' ])),
		E('div', { class: 'button-row' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('保存到草稿', () => {
				error.replaceChildren();
				try {
					if (!name.value.trim()) throw Error('请填写规则名称');
					const value = {
						id: rule.id, name: name.value.trim(), enabled: enabled.checked,
						protocol: protocol.value, ports: ports.value.trim(), src: src.value.trim(),
						dst: dst.value.trim(), line: line.value
					};
					if (index == null) page.draft.proto.push(value);
					else page.draft.proto[index] = value;
					page.markDirty();
					ui.hideModal();
					page.rebuild();
				}
				catch (e) { error.replaceChildren(flow.node('p', 'alert-message error', e.message)); }
			}, 'cbi-button-save')
		])
	]);
	flow.modal(original ? '编辑协议分流规则' : '添加协议分流规则', [editor]);
}
