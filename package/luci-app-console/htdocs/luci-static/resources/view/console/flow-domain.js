// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require ui';
'require console.flow as flow';

// 域名分流：按域名解析出的 IPv4 地址 → nft 集合 → 指定线路。
// 本机 dnsmasq 未编译 nftset，因此由后台按 ttl 自行解析 A 记录写入集合。

return flow.createView({
	title: '域名分流',
	intro: '把指定域名解析出的 IPv4 地址写入 nft 集合，并把访问这些地址的新建连接固定到某条线路。适用于视频、下载等按域名区分的流量。',
	footnote: '域名只解析 A 记录（IPv4）。解析失败的域名保留上一次结果并在状态中提示，不会阻断页面。集合按解析间隔在后台刷新，页面上的「立即解析」只做预览，不写入配置。',

	build(page) {
		const output = [flow.lineGuide(page)];
		page.ruleTable = flow.table(['名称', '域名数', '目标线路', '解析间隔', '解析状态', '状态', '操作']);
		page.resolveBox = E('div', { class: 'flow-resolve' });
		output.push(flow.panel('域名分流规则', [
			flow.node('p', 'flow-note', '每条规则最多 256 个域名，单条规则对应一个 nft 集合。解析间隔 60 到 86400 秒，默认 600 秒。'),
			E('div', { class: 'flow-toolbar-inline' }, [ page.button('添加规则', () => editRule(page, null), 'cbi-button-add') ]),
			page.ruleTable.element,
			page.resolveBox
		]));
		page.paintRules();
		page.paintRuntime();
		return output;
	},

	paintRules() {
		const page = this;
		const rules = page.draft.domain || [];
		const body = page.ruleTable && page.ruleTable.body;
		if (!body) return;
		if (!rules.length) {
			flow.empty(body, 7, '尚无域名分流规则，点击「添加规则」创建。');
			return;
		}
		body.replaceChildren(...rules.map((rule, index) => flow.row([
			E('div', {}, [ flow.node('strong', '', rule.name), flow.node('div', 'cs-note', (rule.domains || []).slice(0, 3).join('、') + ((rule.domains || []).length > 3 ? ' 等' : '')) ]),
			String((rule.domains || []).length),
			flow.lineLabel(page.draft, rule.line),
			String(rule.ttl || 600) + ' 秒',
			resolveState(page, rule),
			rule.enabled ? E('span', { class: 'flow-badge ok' }, '已启用') : E('span', { class: 'flow-badge off' }, '已停用'),
			E('div', { class: 'flow-actions' }, [
				page.button('编辑', () => editRule(page, index)),
				page.button('解析预览', () => previewDomains(page, rule)),
				page.button(rule.enabled ? '停用' : '启用', () => { rules[index].enabled = !rules[index].enabled; page.markDirty(); page.paintRules(); }),
				page.button('删除', () => { rules.splice(index, 1); page.markDirty(); page.rebuild(); }, 'cbi-button-remove')
			])
		])));
	},

	paintRuntime() {
		const page = this;
		if (!page.resolveBox) return;
		const runtime = (page.data && page.data.runtime) || {};
		const groups = runtime.domainGroups || runtime.domains || [];
		if (!groups.length) { page.resolveBox.replaceChildren(); return; }
		page.resolveBox.replaceChildren(flow.node('p', 'flow-note', '运行态集合：' + groups.map(group => {
			const name = (page.draft.domain || []).filter(rule => rule.id === group.id)[0];
			const count = Array.isArray(group.addresses) ? group.addresses.length : (Number(group.count) || 0);
			return (name ? name.name : group.id) + ' ' + count + ' 个地址' + (group.unresolved && group.unresolved.length ? '（' + group.unresolved.length + ' 个域名未解析）' : '');
		}).join('；')));
	},

	paint() { this.paintRules(); this.paintRuntime(); }
});

function resolveState(page, rule) {
	const runtime = (page.data && page.data.runtime) || {};
	const groups = runtime.domainGroups || runtime.domains || [];
	const group = groups.filter(item => item.id === rule.id)[0];
	if (!group) return flow.node('span', 'flow-note', rule.enabled ? '等待首次解析' : '未生效');
	const unresolved = (group.unresolved || []).length;
	if (unresolved) return E('span', { class: 'flow-badge wait', title: (group.unresolved || []).join('、') }, unresolved + ' 个未解析');
	const count = Array.isArray(group.addresses) ? group.addresses.length : (Number(group.count) || 0);
	if (!count) return E('span', { class: 'flow-badge wait' }, '无解析结果');
	return E('span', { class: 'flow-badge ok' }, count + ' 个地址');
}

function previewDomains(page, rule) {
	const domains = E('textarea', { rows: 4, placeholder: '每行一个域名' });
	domains.value = (rule.domains || []).join('\n');
	const result = E('div', { class: 'flow-resolve' }, [ flow.node('p', 'flow-note', '提交当前域名列表做一次解析预览，不写入配置、不改动内核集合。') ]);
	const parse = async () => {
		// 后端 resolve 只解析「已启用」的规则，预览时按已启用处理，否则停用规则永远拿不到结果。
		const config = flow.clone(page.draft);
		config.domain = (page.draft.domain || []).map(item => item.id === rule.id
			? Object.assign({}, item, { enabled: true, domains: domains.value.split(/[\s,;]+/).map(value => value.trim()).filter(Boolean) })
			: item);
		result.replaceChildren(flow.node('p', 'flow-note', '正在解析…'));
		try {
			const response = flow.checked(await flow.resolve(config));
			const groups = response.groups || [];
			const group = groups.filter(item => item.id === rule.id)[0];
			if (!group) { result.replaceChildren(flow.node('p', 'alert-message warning', '后端没有返回解析结果，请检查域名格式与 DNS 是否可用。')); return; }
			const nodes = [flow.node('p', 'flow-note', '解析时间：' + new Date().toLocaleString('zh-CN') + ' · 共 ' + (group.domains || []).length + ' 个域名' + (rule.enabled ? '' : ' · 该规则当前为停用，预览按已启用处理'))];
			for (const entry of group.domains || []) {
				nodes.push(E('div', { class: 'flow-resolve-group' }, [
					E('div', { class: 'flow-resolve-head' }, [
						flow.node('strong', '', entry.name),
						entry.error ? E('span', { class: 'flow-badge error' }, entry.error) : E('span', { class: 'flow-badge ok' }, (entry.addresses || []).length + ' 个地址')
					]),
					(entry.addresses || []).length ? E('div', { class: 'flow-resolve-list' }, (entry.addresses || []).map(address => E('span', { class: 'flow-resolve-ip' }, address))) : flow.node('p', 'flow-note', '没有解析到 IPv4 地址。')
				]));
			}
			result.replaceChildren(...nodes);
		}
		catch (error) { result.replaceChildren(flow.node('p', 'alert-message error', (error && error.message) || '解析失败')); }
	};
	const editor = E('div', { class: 'flow-editor' }, [
		flow.node('p', 'flow-note', '规则「' + rule.name + '」的域名列表（仅用于解析预览，修改后需在编辑窗口保存才会生效）：'),
		domains,
		E('div', { class: 'button-row' }, [page.button('关闭', () => ui.hideModal())]),
		result
	]);
	flow.modal('域名解析预览 · ' + rule.name, [editor]);
	parse();
}

function editRule(page, index) {
	const original = index == null ? null : page.draft.domain[index];
	const rule = original ? flow.clone(original) : { id: flow.uid(), name: '', enabled: false, domains: [], line: 'auto', ttl: 600 };
	const name = E('input', { type: 'text', value: rule.name, maxlength: 64, placeholder: '例如 视频站点走线路 2' });
	const domains = E('textarea', { rows: 6, placeholder: '每行一个域名，例如\nwww.youtube.com\nyoutube.com' });
	domains.value = (rule.domains || []).join('\n');
	const line = flow.lineSelect(page.draft, rule.line || 'auto');
	const ttl = E('input', { type: 'number', min: 60, max: 86400, value: rule.ttl || 600 });
	const enabled = E('input', { type: 'checkbox', checked: rule.enabled || null });
	const error = E('div', { role: 'alert' });

	const editor = E('div', { class: 'flow-editor' }, [
		error,
		flow.field('名称', name, '用于页面与告警中标识这条规则。'),
		flow.field('域名列表', domains, '每行一个域名，支持子域通配写法（写域名本身即可涵盖其子域解析结果）；最多 256 个。不接受 IP 地址。'),
		flow.field('目标线路', line, '选「自动分配」时按多线负载策略决定。'),
		flow.field('解析间隔', E('div', { class: 'flow-inline' }, [ ttl, flow.node('span', 'flow-note', '秒') ]), '60 到 86400 秒，后台按此间隔重新解析并更新 nft 集合。'),
		flow.field('启用规则', E('label', { class: 'flow-switch' }, [ enabled, '保存到草稿后仍需点击「保存并应用」' ])),
		E('div', { class: 'button-row' }, [
			page.button('取消', () => ui.hideModal()),
			page.button('保存到草稿', () => {
				error.replaceChildren();
				try {
					if (!name.value.trim()) throw Error('请填写规则名称');
					const list = domains.value.split(/[\s,;]+/).map(item => item.trim().toLowerCase()).filter(Boolean);
					if (!list.length) throw Error('请至少填写一个域名');
					const value = {
						id: rule.id, name: name.value.trim(), enabled: enabled.checked,
						domains: Array.from(new Set(list)).slice(0, 256), line: line.value,
						ttl: Math.max(60, Math.min(86400, Number(ttl.value) || 600))
					};
					if (index == null) page.draft.domain.push(value);
					else page.draft.domain[index] = value;
					page.markDirty();
					ui.hideModal();
					page.rebuild();
				}
				catch (e) { error.replaceChildren(flow.node('p', 'alert-message error', e.message)); }
			}, 'cbi-button-save')
		])
	]);
	flow.modal(original ? '编辑域名分流规则' : '添加域名分流规则', [editor]);
}
