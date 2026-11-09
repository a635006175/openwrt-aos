// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 端口分流：按目的端口段 + 源网段指定线路（最常用的分流方式）。

const PROTOCOLS = [['tcp', 'TCP'], ['udp', 'UDP'], ['tcp+udp', 'TCP + UDP']];

return flow.createView({
	title: '端口分流',
	intro: '把指定目的端口或端口段的新建连接固定到某条线路，例如把 BT、游戏、IPTV 的端口分别指向不同出口。',
	footnote: '端口规则比协议规则更直观，两者都启用时按页面顺序匹配；首条命中后不再继续。目的端口为必填项（启用该规则时）。',

	build(page) {
		const output = [flow.lineGuide(page)];
		page.ruleTable = flow.table(['名称', '协议 / 目的端口', '源网段', '目标线路', '状态', '操作']);
		output.push(flow.panel('端口分流规则', [
			flow.node('p', 'flow-note', '多条规则可共用相同端口，此时只有最上面的一条生效。端口段总数与协议分流、域名分流合计不超过 512 条。'),
			E('div', { class: 'flow-toolbar-inline' }, [ page.button('添加规则', () => editRule(page, null), 'cbi-button-add') ]),
			page.ruleTable.element
		]));
		page.paintRules();
		return output;
	},

	paintRules() {
		const page = this;
		const rules = page.draft.port || [];
		const body = page.ruleTable && page.ruleTable.body;
		if (!body) return;
		if (!rules.length) {
			flow.empty(body, 6, '尚无端口分流规则，点击「添加规则」创建。');
			return;
		}
		body.replaceChildren(...rules.map((rule, index) => flow.row([
			E('div', {}, [ flow.node('strong', '', rule.name), flow.node('div', 'cs-note', rule.id) ]),
			(rule.protocol || 'tcp').toUpperCase() + ' · ' + (rule.ports || '未填写'),
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
	const copy = flow.clone(page.draft.port[index]);
	copy.id = flow.uid();
	copy.name = (copy.name + ' 副本').slice(0, 64);
	copy.enabled = false;
	page.draft.port.splice(index + 1, 0, copy);
	page.markDirty();
	page.rebuild();
}

function editRule(page, index) {
	const original = index == null ? null : page.draft.port[index];
	const rule = original ? flow.clone(original) : { id: flow.uid(), name: '', enabled: false, protocol: 'tcp', ports: '', src: '', line: 'auto' };
	const name = E('input', { type: 'text', value: rule.name, maxlength: 64, placeholder: '例如 视频站点走线路 1' });
	const protocol = flow.option(PROTOCOLS, rule.protocol);
	const ports = E('input', { type: 'text', value: rule.ports, placeholder: '例如 80,443 或 8000-8100' });
	const src = E('input', { type: 'text', value: rule.src, placeholder: '例如 192.168.1.50/32，留空表示任意来源' });
	const line = flow.lineSelect(page.draft, rule.line || 'auto');
	const enabled = E('input', { type: 'checkbox', checked: rule.enabled || null });
	const error = E('div', { role: 'alert' });

	const editor = E('div', { class: 'flow-editor' }, [
		error,
		flow.field('名称', name, '用于页面与告警中标识这条规则。'),
		flow.field('协议', protocol),
		flow.field('目的端口', ports, '必填。逗号分隔的数字或「起始-结束」，单条最多 16 段，端口段之间不能重叠。'),
		flow.field('源网段', src, 'IPv4 地址或 CIDR，多个用逗号分隔；留空表示内网全部来源。'),
		flow.field('目标线路', line, '选「自动分配」时按多线负载策略决定。'),
		flow.field('启用规则', E('label', { class: 'flow-switch' }, [ enabled, '保存到草稿后仍需点击「保存并应用」' ])),
		E('div', { class: 'button-row' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('保存到草稿', () => {
				error.replaceChildren();
				try {
					if (!name.value.trim()) throw Error('请填写规则名称');
					if (enabled.checked && !ports.value.trim()) throw Error('启用端口分流规则时必须填写目的端口');
					const value = {
						id: rule.id, name: name.value.trim(), enabled: enabled.checked,
						protocol: protocol.value, ports: ports.value.trim(), src: src.value.trim(), line: line.value
					};
					if (index == null) page.draft.port.push(value);
					else page.draft.port[index] = value;
					page.markDirty();
					ui.hideModal();
					page.rebuild();
				}
				catch (e) { error.replaceChildren(flow.node('p', 'alert-message error', e.message)); }
			}, 'cbi-button-save')
		])
	]);
	flow.modal(original ? '编辑端口分流规则' : '添加端口分流规则', [editor]);
}
