// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require console.feedback as feedback';

const getClient = rpc.declare({ object: 'console-vpn', method: 'client_get', reject: true });
const applyClient = rpc.declare({ object: 'console-vpn', method: 'client_apply', params: ['host', 'port', 'protocol', 'username', 'password', 'localSubnet', 'ca'], reject: true });
const stopClient = rpc.declare({ object: 'console-vpn', method: 'client_stop', reject: true });
const inspectClient = rpc.declare({ object: 'console-vpn', method: 'client_inspect', params: ['profile'], reject: true });
const importClient = rpc.declare({ object: 'console-vpn', method: 'client_import', params: ['profile', 'username', 'password', 'localSubnet', 'host', 'port', 'protocol', 'redirectGateway'], reject: true });

const MAX_PROFILE = 256 * 1024;

return view.extend(feedback.decorate({
	load() { return getClient(); },
	field(label, control, help) {
		const id = 'console-vpn-client-' + (++this.fieldIndex); control.id = id;
		return E('div', { class: 'cbi-value' }, [E('label', { class: 'cbi-value-title', for: id }, label), E('div', { class: 'cbi-value-field' }, [control, help ? E('div', { class: 'cbi-value-description' }, help) : ''])]);
	},
	async refresh() {
		try {
			const result = await getClient(); this.state = result;
			this.status.className = 'badge ' + (result.status.running ? 'label-success' : result.status.configured ? 'label-warning' : 'label-info');
			this.status.replaceChildren(result.status.running ? '客户端进程运行中；链路状态见系统日志' : result.status.configured ? '已启用但进程未运行' : '未连接');
		}
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '读取客户端状态失败'), 'error'); }
	},
	// 导入的配置文件只保留在页面内存中，不写入路由器存储；连接时一次性提交。
	async readProfile(file) {
		if (!file) return;
		if (file.size > MAX_PROFILE) { ui.addNotification(null, E('p', {}, '配置文件最大支持 256 KB'), 'error'); return; }
		let text = '';
		try { text = await file.text(); }
		catch (error) { ui.addNotification(null, E('p', {}, '读取文件失败：' + (error.message || '未知错误')), 'error'); return; }
		try {
			const result = await inspectClient(text);
			if (result.error || !result.ok) throw new Error(result.error || '解析配置文件失败');
			this.profile = text;
			this.inputs.host.value = result.parsed.host || '';
			this.inputs.port.value = result.parsed.port || 1194;
			this.inputs.protocol.value = result.parsed.protocol || 'udp';
			this.inputs.ca.value = result.parsed.ca || '';
			this.inputs.ca.disabled = true;
			this.redirectGateway.checked = result.parsed.redirectGateway ? true : null;
			this.profileNote.textContent = '已读取 ' + file.name + '，确认参数后点击“导入并连接”。';
			this.paintSummary(result.parsed);
		}
		catch (error) {
			this.profile = null;
			this.paintSummary(null);
			ui.addNotification(null, E('p', {}, error.message || '解析配置文件失败'), 'error');
		}
	},
	paintSummary(parsed) {
		const rows = [];
		if (parsed) {
			rows.push(['服务端', parsed.host + ' : ' + parsed.port + '（' + (parsed.protocol === 'tcp-client' ? 'TCP' : 'UDP') + '）']);
			rows.push(['CA 证书', parsed.ca ? '配置内已包含' : '未包含']);
			rows.push(['客户端证书', parsed.hasCert ? '配置内已包含证书与私钥' : '未包含']);
			rows.push(['账号密码', parsed.requiresCredentials ? '需要填写账号密码' : '不需要（使用证书认证）']);
			rows.push(['已采用的选项', parsed.extra.length ? parsed.extra.join('、') : '无']);
			if (parsed.ignored.length) rows.push(['未采纳的选项', parsed.ignored.join('、')]);
			if (parsed.warnings.length) rows.push(['提示', parsed.warnings.join('；')]);
		}
		this.summaryBox.replaceChildren(...(rows.length ? rows.map(row => E('div', { class: 'cbi-value' }, [E('div', { class: 'cbi-value-title' }, row[0]), E('div', { class: 'cbi-value-field' }, row[1])])) : [E('p', { class: 'cbi-value-description' }, '尚未载入配置文件。')]));
	},
	clearProfile() {
		this.profile = null;
		this.inputs.ca.disabled = false;
		this.profileNote.textContent = '';
		this.paintSummary(null);
	},
	async apply() {
		try {
			let result;
			if (this.profile) {
				result = await importClient(this.profile, this.inputs.username.value.trim(), this.inputs.password.value, this.inputs.localSubnet.value.trim(), this.inputs.host.value.trim(), +this.inputs.port.value, this.inputs.protocol.value, this.redirectGateway.checked);
			} else {
				result = await applyClient(this.inputs.host.value.trim(), +this.inputs.port.value, this.inputs.protocol.value, this.inputs.username.value.trim(), this.inputs.password.value, this.inputs.localSubnet.value.trim(), this.inputs.ca.value.trim());
			}
			if (result.error || !result.ok) throw new Error(result.error || '配置失败');
			this.inputs.password.value = '';
			if (result.settings) {
				this.inputs.host.value = result.settings.host || '';
				this.inputs.port.value = result.settings.port || 1194;
				this.inputs.protocol.value = result.settings.protocol || 'udp';
				this.inputs.ca.value = result.settings.ca || '';
				this.inputs.username.value = result.settings.username || '';
			}
			this.clearProfile();
			ui.addNotification(null, E('p', {}, '客户端配置已保存并启动。'), 'info');
			await this.refresh();
		} catch (error) { ui.addNotification(null, E('p', {}, error.message || '应用客户端配置失败'), 'error'); }
	},
	async disconnect() {
		try { const result = await stopClient(); if (result.error || !result.ok) throw new Error(result.error || '断开失败'); ui.addNotification(null, E('p', {}, '客户端已断开。'), 'info'); await this.refresh(); }
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '断开客户端失败'), 'error'); }
	},
	render(data) {
		this.state = data; this.fieldIndex = 0; this.profile = null;
		const s = data.settings || {}, canWrite = L.hasViewPermission();
		this.status = E('span', { class: 'badge ' + (data.status.running ? 'label-success' : data.status.configured ? 'label-warning' : 'label-info') }, data.status.running ? '客户端进程运行中；链路状态见系统日志' : data.status.configured ? '已启用但进程未运行' : '未连接');
		this.inputs = {
			host: E('input', { type: 'text', value: s.host || '', placeholder: '服务端公网 IPv4 或 DDNS 域名' }),
			port: E('input', { type: 'number', min: '1', max: '65535', value: s.port || 1194 }),
			protocol: E('select', {}, [E('option', { value: 'udp', selected: (s.protocol || 'udp') == 'udp' }, 'UDP'), E('option', { value: 'tcp-client', selected: s.protocol == 'tcp-client' }, 'TCP')]),
			username: E('input', { type: 'text', value: s.username || '', autocomplete: 'username' }),
			password: E('input', { type: 'password', autocomplete: 'new-password', placeholder: '已保存时留空可继续使用原密码' }),
			localSubnet: E('input', { type: 'text', value: s.localSubnet || '192.168.1.0/24', placeholder: '192.168.1.0/24' }),
			ca: E('textarea', { rows: '10', spellcheck: 'false', placeholder: '粘贴服务端导出的 CA 证书（-----BEGIN CERTIFICATE-----）' }, s.ca || '')
		};
		this.redirectGateway = E('input', { type: 'checkbox' });
		this.summaryBox = E('div', {});
		this.profileNote = E('div', { class: 'cbi-value-description', role: 'status' });
		const file = E('input', { type: 'file', accept: '.ovpn,.conf,.txt', change: ev => this.readProfile(ev.target.files[0]) });
		return E('div', { class: 'cbi-map' }, [E('h2', {}, 'OpenVPN 客户端'),
			E('p', {}, '将本机接入另一台 OpenVPN 服务端。账号密码与该服务端的 OpenVPN 账号一致。'),
			E('div', { class: 'cbi-section' }, [E('h3', {}, '导入 .ovpn 配置'),
				E('p', {}, '可直接选择第三方或本系统导出的 .ovpn 客户端配置文件。路由器会解析服务端地址、端口、协议、CA 证书、客户端证书与可安全采用的选项，然后按导入结果连接。'),
				this.field('选择配置文件', file, '支持 .ovpn / .conf 文本文件，最大 256 KB。文件内容只保存在当前页面内存中。'),
				this.summaryBox, this.profileNote,
				this.field('全流量路由', this.redirectGateway, '对应配置中的 redirect-gateway：勾选后本机默认路由改走 VPN，断线期间本机自身上网可能受影响。仅在导入配置要求时勾选。'),
				E('div', { class: 'button-row' }, [E('button', { type: 'button', class: 'cbi-button cbi-button-apply', disabled: !canWrite || null, click: () => this.apply() }, '导入并连接'), ' ', E('button', { type: 'button', class: 'cbi-button cbi-button-reset', disabled: !canWrite || null, click: () => this.clearProfile() }, '清除导入')])
			]),
			E('div', { class: 'cbi-section' }, [E('h3', {}, '连接状态'), E('div', { class: 'cbi-value' }, [E('div', { class: 'cbi-value-title' }, '客户端'), E('div', { class: 'cbi-value-field' }, this.status)]),
				this.field('服务端地址', this.inputs.host), this.field('端口', this.inputs.port), this.field('协议', this.inputs.protocol),
				this.field('账号', this.inputs.username), this.field('密码', this.inputs.password, '仅发送至当前路由器；以 root 专属权限文件保存，不会返回到页面。'),
				this.field('本机内网', this.inputs.localSubnet, '本机作为网关时填写 LAN 网段，并在服务端账号的“客户端内网”处填写相同网段。'),
				this.field('CA 证书', this.inputs.ca, '从服务端页面下载 openwrt-vpn-ca.crt 后粘贴。客户端会校验服务端证书。'),
				E('p', { class: 'alert-message warning' }, '连接会为 LAN 与 VPN 添加专属双向转发规则。只有点击“保存并连接”后才启动 OpenVPN。'),
				E('div', { class: 'button-row' }, [E('button', { type: 'button', class: 'cbi-button cbi-button-apply', disabled: !canWrite || null, click: () => this.apply() }, '保存并连接'), ' ', E('button', { type: 'button', class: 'cbi-button cbi-button-reset', disabled: !canWrite || !s.enabled || null, click: () => this.disconnect() }, '断开连接')])
			])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
}));
