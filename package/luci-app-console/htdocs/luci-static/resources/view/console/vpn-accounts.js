// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require console.feedback as feedback';

const listAccounts = rpc.declare({ object: 'console-vpn-accounts', method: 'list', reject: true });
const saveAccount = rpc.declare({ object: 'console-vpn-accounts', method: 'save', params: ['username', 'password', 'address', 'remoteSubnet', 'description', 'enabled'], reject: true });
const removeAccount = rpc.declare({ object: 'console-vpn-accounts', method: 'remove', params: ['username'], reject: true });

return view.extend(feedback.decorate({
	load() { return listAccounts(); },
	async refreshList() {
		const data = await listAccounts();
		this.accounts = data.accounts || [];
		this.renderRows();
	},
	async save(values) {
		try {
			const data = await saveAccount(values.username.value, values.password.value, values.address.value, values.remoteSubnet.value, values.description.value, values.enabled.checked);
			if (data.error || !data.account) throw new Error(data.error || '保存失败');
			ui.hideModal();
			await this.refreshList();
		} catch (error) { ui.addNotification(null, E('p', {}, error.message || '保存失败'), 'error'); }
	},
	edit(account) {
		const existing = !!account;
		account = account || { username: '', address: '', remoteSubnet: '', description: '', enabled: true };
		const values = {
			username: E('input', { type: 'text', maxlength: '48', value: account.username, disabled: existing || null, autocomplete: 'off' }),
			password: E('input', { type: 'password', maxlength: '128', autocomplete: 'new-password', placeholder: existing ? '留空则保持原密码' : '8 至 128 个英文字符' }),
			address: E('input', { type: 'text', value: account.address, placeholder: '例如 10.8.0.10' }),
			remoteSubnet: E('input', { type: 'text', value: account.remoteSubnet, placeholder: '可选，例如 192.168.2.0/24' }),
			description: E('input', { type: 'text', maxlength: '120', value: account.description }),
			enabled: E('input', { type: 'checkbox', checked: account.enabled || null })
		};
		let fieldIndex = 0;
		const field = (title, input, help) => { input.id = 'vpn-account-field-' + (++fieldIndex); return E('div', { class: 'cbi-value' }, [E('label', { class: 'cbi-value-title', for: input.id }, title), E('div', { class: 'cbi-value-field' }, [input, help ? E('div', { class: 'cbi-value-description' }, help) : ''])]); };
		ui.showModal(existing ? '编辑 VPN 账号' : '新增 VPN 账号', [
			field('账号', values.username, '仅限字母、数字、下划线和短横线。'),
			field('密码', values.password, '密码仅以加盐哈希保存。'),
			field('固定 VPN IP', values.address, '站点互访时填写服务端 VPN 网段内的固定地址；填写后该账号仅允许1端在线，多端共享账号请留空。'),
			field('客户端内网', values.remoteSubnet, '站点互访时填写该客户端后方的 IPv4 网段；填写后该账号仅允许1端在线。'),
			field('备注', values.description), field('启用', values.enabled),
			E('div', { class: 'button-row' }, [E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ', E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.save(values) }, '保存')])
		]);
	},
	confirmRemove(account) {
		ui.showModal('删除 VPN 账号', [E('p', {}, '确定删除账号“' + account.username + '”？'), E('div', { class: 'button-row' }, [
			E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
			E('button', { type: 'button', class: 'cbi-button cbi-button-remove', click: async () => {
				try { const result = await removeAccount(account.username); if (result.error || !result.ok) throw new Error(result.error || '删除失败'); ui.hideModal(); await this.refreshList(); }
				catch (error) { ui.addNotification(null, E('p', {}, error.message || '删除失败'), 'error'); }
			} }, '删除')
		])]);
	},
	renderRows() {
		const rows = this.accounts.map(account => E('tr', { class: 'tr' }, [
			E('td', { class: 'td', 'data-title': '账号' }, account.username), E('td', { class: 'td', 'data-title': '状态' }, account.enabled ? '启用' : '停用'),
			E('td', { class: 'td', 'data-title': '固定 VPN IP' }, account.address || '—'), E('td', { class: 'td', 'data-title': '客户端内网' }, account.remoteSubnet || '—'),
			E('td', { class: 'td', 'data-title': '备注' }, account.description || '—'),
			E('td', { class: 'td cbi-section-actions' }, [E('button', { type: 'button', class: 'cbi-button cbi-button-edit', disabled: !L.hasViewPermission() || null, click: () => this.edit(account) }, '编辑'), ' ', E('button', { type: 'button', class: 'cbi-button cbi-button-remove', disabled: !L.hasViewPermission() || null, click: () => this.confirmRemove(account) }, '删除')])
		]));
		this.table.replaceChildren(...(rows.length ? rows : [E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: '6' }, '暂无账号'))]));
	},
	render(data) {
		this.accounts = data.accounts || [];
		this.table = E('tbody', { class: 'tbody' });
		const root = E('div', { class: 'cbi-map' }, [E('h2', {}, 'OpenVPN 账号管理'), E('div', { class: 'cbi-section' }, [
			E('p', {}, '创建虚拟组网账号，配置固定 VPN 地址和客户端内网网段。'),
			E('p', { class: 'alert-message info' }, '启用的账号可用于服务端拨入。固定 VPN IP 和客户端内网网段为可选项；填写客户端内网即可建立双向站点互访。账号变更会同步服务端并短暂重连。'),
			E('table', { class: 'table cbi-section-table' }, [E('thead', {}, E('tr', { class: 'tr table-titles' }, ['账号', '状态', '固定 VPN IP', '客户端内网', '备注', '操作'].map(title => E('th', { class: 'th' }, title)))), this.table]),
			E('button', { type: 'button', class: 'cbi-button cbi-button-add', disabled: !L.hasViewPermission() || null, click: () => this.edit(null) }, '新增账号')
		])]);
		this.renderRows(); return root;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
}));
