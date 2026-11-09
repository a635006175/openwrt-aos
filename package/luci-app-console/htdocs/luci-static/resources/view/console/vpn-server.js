// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require console.feedback as feedback';

const getServer = rpc.declare({ object: 'console-vpn', method: 'server_get', reject: true });
const applyServer = rpc.declare({ object: 'console-vpn', method: 'server_apply', params: ['enabled', 'vpnSubnet', 'localSubnet', 'port', 'protocol', 'endpoint', 'allowWan'], reject: true });
const exportProfile = rpc.declare({ object: 'console-vpn', method: 'profile_export', params: ['username'], reject: true });
const exportCA = rpc.declare({ object: 'console-vpn', method: 'ca_export', reject: true });

return view.extend(feedback.decorate({
	load() { return getServer(); },
	field(label, control, help) {
		const id = 'console-vpn-server-' + (++this.fieldIndex);
		control.id = id;
		const grouped=control.tagName==='DIV';
		if(grouped){control.setAttribute('role','group');control.setAttribute('aria-labelledby',id+'-label');}
		return E('div', { class: 'cbi-value' }, [E(grouped?'div':'label', { class: 'cbi-value-title', id:id+'-label', ...(grouped?{}:{for:id}) }, label), E('div', { class: 'cbi-value-field' }, [control, help ? E('div', { class: 'cbi-value-description' }, help) : ''])]);
	},
	routeEditor(value,canWrite){
		this.routeInputs=[];const rows=E('div'),count=E('span',{class:'cbi-value-description','aria-live':'polite'});
		const sync=()=>{this.routeInputs.forEach((input,i)=>{input.setAttribute('aria-label','推送网段 '+(i+1));const remove=input.parentElement.querySelector('button');remove.disabled=!canWrite||this.routeInputs.length===1;remove.setAttribute('aria-label','删除推送网段 '+(i+1));});add.disabled=!canWrite||this.routeInputs.length>=64;count.textContent=this.routeInputs.length+' / 64 条';};
		const append=(text,focus)=>{const input=E('input',{type:'text',value:text,placeholder:'例如 192.168.2.0/24',disabled:!canWrite||null,style:'flex:1;min-width:0;width:0;box-sizing:border-box'}),row=E('div',{style:'display:flex;align-items:center;gap:8px;margin-bottom:8px'},[input,E('button',{type:'button',class:'cbi-button',style:'min-height:44px;flex-shrink:0',click:()=>{const i=this.routeInputs.indexOf(input);this.routeInputs.splice(i,1);row.remove();sync();this.routeInputs[Math.min(i,this.routeInputs.length-1)].focus();}},'删除')]);this.routeInputs.push(input);rows.append(row);if(focus){sync();input.focus();}};
		const add=E('button',{type:'button',class:'cbi-button cbi-button-add',style:'min-height:44px',click:()=>{if(canWrite&&this.routeInputs.length<64)append('',true);}},'＋新增网段');
		for(const text of String(value||'192.168.1.0/24').trim().split(/[\s,;]+/).filter(Boolean))append(text,false);if(!this.routeInputs.length)append('',false);sync();
		return E('div',{class:'console-vpn-routes',style:'width:100%;max-width:460px'},[rows,E('div',{style:'display:flex;gap:12px;align-items:center;flex-wrap:wrap'},[add,count])]);
	},
	download(name, content) {
		const link = document.createElement('a'), url = URL.createObjectURL(new Blob([content], { type: 'application/octet-stream' }));
		link.href = url; link.download = name; link.click(); window.setTimeout(() => URL.revokeObjectURL(url), 1000);
	},
	async refresh() {
		try { const data = await getServer(); this.state = data; this.updateState(); }
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '读取服务端状态失败'), 'error'); }
	},
	updateState() {
		const state = this.state.status || {}, settings = this.state.settings || {};
		this.status.replaceChildren(E('span', { class: 'badge ' + (state.running ? 'label-success' : state.configured ? 'label-warning' : 'label-info') }, state.running ? '服务进程运行中' : state.configured ? '已启用但进程未运行' : '未启用'));
		/* 只判断是否为空；地址是否合法仍以服务端 RPC 的校验结果为准。 */
		const endpointMissing = !String(settings.endpoint || '').trim();
		this.exportNotice.replaceChildren(...(endpointMissing ? [E('div', { class: 'alert-message warning' }, [
			E('p', {}, '导出客户端配置前，请先在上方“客户端连接地址”填写公网 IPv4 或 DDNS 域名，客户端才能连接到本服务端。'),
			E('button', { type: 'button', class: 'cbi-button cbi-button-action', click: () => this.focusEndpoint() }, '去填写')
		])] : []));
		const accounts = (this.state.accounts || []).filter(account => account.enabled);
		this.accountRows.replaceChildren(...(accounts.length ? accounts.map(account => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, account.username), E('td', { class: 'td' }, account.address || '自动分配'), E('td', { class: 'td' }, account.remoteSubnet || '—'),
			E('td', { class: 'td cbi-section-actions' }, E('button', { type: 'button', class: 'cbi-button cbi-button-action', disabled: endpointMissing ? true : null, click: async () => {
				try { const profile = await exportProfile(account.username); if (profile.error) throw new Error(profile.error); this.download(profile.filename, profile.content); }
				catch (error) { ui.addNotification(null, E('p', {}, error.message || '导出失败'), 'error'); }
			} }, '导出客户端配置'))
		])) : [E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: '4' }, ['暂无已启用账号，先到 ', E('a', { href: L.url('admin/vpn/console-accounts') }, 'OpenVPN 账号'), ' 页面新增。']))]));
	},
	focusEndpoint() {
		if (!this.inputs || !this.inputs.endpoint) return;
		const input = this.inputs.endpoint;
		if (typeof input.scrollIntoView == 'function') input.scrollIntoView({ block: 'center' });
		this.inputs.endpoint.focus();
	},
	async apply(enabled) {
		try {
			if(this.routeInputs.some(input=>!input.value.trim()))throw new Error('请填写新增网段，或删除空白项。');
			const result = await applyServer(enabled, this.inputs.vpnSubnet.value.trim(), this.routeInputs.map(input=>input.value.trim()).join('\n'), +this.inputs.port.value, this.inputs.protocol.value, this.inputs.endpoint.value.trim(), this.inputs.allowWan.checked);
			if (result.error || !result.ok) throw new Error(result.error || '配置失败');
			ui.addNotification(null, E('p', {}, enabled ? '服务端配置已保存并启动。' : '服务端已停止。'), 'info');
			await this.refresh();
		} catch (error) { ui.addNotification(null, E('p', {}, error.message || '应用服务端配置失败'), 'error'); }
	},
	render(data) {
		this.state = data; this.fieldIndex = 0;
		const s = data.settings || {}, canWrite = L.hasViewPermission();
		this.inputs = {
			vpnSubnet: E('input', { type: 'text', value: s.vpnSubnet || '10.8.0.0/24', placeholder: '10.8.0.0/24' }),
			localSubnet: this.routeEditor(s.localSubnet,canWrite),
			port: E('input', { type: 'number', min: '1', max: '65535', value: s.port || 1194 }),
			protocol: E('select', {}, [E('option', { value: 'udp', selected: (s.protocol || 'udp') == 'udp' }, 'UDP'), E('option', { value: 'tcp-server', selected: s.protocol == 'tcp-server' }, 'TCP')]),
			endpoint: E('input', { type: 'text', value: s.endpoint || '', placeholder: '公网 IPv4 或 DDNS 域名' }),
			allowWan: E('input', { type: 'checkbox', checked: s.allowWan || null })
		};
		this.status = E('div', { class: 'cbi-value-field' });
		this.accountRows = E('tbody', { class: 'tbody' });
		this.exportNotice = E('div', { class: 'cbi-value' });
		const panel = E('div', { class: 'cbi-map' }, [
			E('h2', {}, 'OpenVPN 服务端'),
			E('p', {}, '创建中心节点，让手机、电脑或异地 AOS 通过账号加入同一虚拟网络。账号与密码沿用 OpenVPN 账号管理。同一账号可多端同时登录，服务总并发上限99；固定VPN IP或配置客户端内网的账号限1端。'),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '运行状态'), E('div', { class: 'cbi-value' }, [E('div', { class: 'cbi-value-title' }, '服务端'), this.status]),
				this.field('VPN 网段', this.inputs.vpnSubnet, '虚拟地址池；不能与服务端 LAN 或任何客户端 LAN 重叠。'),
				this.field('服务端内网（推送路由）', this.inputs.localSubnet, '每个输入框填写一个IPv4网段，点击“＋新增网段”添加，最多64条。所有客户端重连时接收这些路由。保存会重启VPN服务并断开当前连接；请确保路由器具有对应网络的可达路由和回程路径。'),
				this.field('监听端口', this.inputs.port), this.field('传输协议', this.inputs.protocol),
				this.field('客户端连接地址', this.inputs.endpoint, '填写公网 IPv4 或 DDNS 域名，用于生成客户端配置文件。'),
				this.field('允许 WAN 拨入', this.inputs.allowWan, '启用后只开放上方协议和端口；关闭时仅允许从 LAN 连接。'),
				E('p', { class: 'alert-message warning' }, '启用会写入 OpenVPN 专属防火墙区域，允许 VPN 与 LAN 双向互访及 VPN 经 WAN 上网。是否全局走 VPN 由客户端路由配置决定；不会覆盖现有 LAN/WAN 配置。'),
				E('div', { class: 'button-row' }, [
					E('button', { type: 'button', class: 'cbi-button cbi-button-apply', disabled: !canWrite || null, click: () => this.apply(true) }, '保存并启用'), ' ',
					E('button', { type: 'button', class: 'cbi-button cbi-button-reset', disabled: !canWrite || !s.enabled || null, click: () => this.apply(false) }, '停止服务端'), ' ',
					E('button', { type: 'button', class: 'cbi-button', click: async () => { try { const result = await exportCA(); if (result.error) throw new Error(result.error); this.download('openwrt-vpn-ca.crt', result.content); } catch (error) { ui.addNotification(null, E('p', {}, error.message || '导出 CA 失败'), 'error'); } } }, '下载 CA 证书')
				])
			]),
			E('div', { class: 'cbi-section' }, [E('h3', {}, '可导出的账号'), E('p', {}, '下载的 .ovpn 文件只含服务端地址和 CA，不含账号密码；连接时输入对应账号凭据。'), this.exportNotice,
				E('table', { class: 'table cbi-section-table' }, [E('thead', {}, E('tr', { class: 'tr table-titles' }, ['账号', 'VPN 地址', '客户端内网', '操作'].map(label => E('th', { class: 'th' }, label)))), this.accountRows])
			])
		]);
		this.updateState(); return panel;
	},
	handleSaveApply: null, handleSave: null, handleReset: null
}));
