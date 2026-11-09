// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require console.feedback as feedback';

// 爱快式 DHCP 服务器设置页。
// 与 OpenWrt 原生页的区别（这是本页存在的理由）：
//  - 地址池用"起始 IP / 结束 IP"描述，而不是"偏移量 + 数量"，无需手工换算；
//  - 网关、DNS、租期与地址池在同一屏，按同一条逻辑呈现；
//  - 静态绑定（MAC ↔ IP）以表格直接增删，不必到另一个标签页拼选项字符串。
// 保存前先用后端校验，校验通过后再由用户确认才真正写入。

const getState = rpc.declare({ object: 'console-dhcp', method: 'state', reject: true });
const applyConfig = rpc.declare({ object: 'console-dhcp', method: 'apply', params: [ 'config' ], reject: true });

const LEASE_OPTIONS = [
	[ '30m', '30 分钟' ], [ '1h', '1 小时' ], [ '2h', '2 小时' ], [ '6h', '6 小时' ],
	[ '12h', '12 小时（默认）' ], [ '1d', '1 天' ], [ '7d', '7 天' ]
];

let fieldSeq = 0;
function field(labelText, control, help) {
	const id = 'cn-dhcp-field-' + (++fieldSeq);
	if (!control.id) control.id = id;
	const body = E('div', { class: 'cbi-value-field' }, [ control ]);
	if (help) body.append(E('div', { class: 'cbi-value-description' }, help));
	return E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title', for: control.id }, labelText), body ]);
}

return view.extend(feedback.decorate({
	load() { return getState(); },

	async refresh() {
		try {
			const data = await getState();
			if (data.error) throw new Error(data.error);
			this.state = data.state;
			this.fill(this.state);
		}
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '读取 DHCP 配置失败'), 'error'); }
	},

	// 把后端状态回填到表单控件
	fill(state) {
		if (!state || !this.inputs) return;
		const i = this.inputs;
		if (state.pool) {
			i.startIP.value = state.pool.startIP || '';
			i.endIP.value = state.pool.endIP || '';
		}
		i.gateway.value = state.gateway || '';
		i.dns1.value = (state.dns || [])[0] || '';
		i.dns2.value = (state.dns || [])[1] || '';
		i.leasetime.value = state.leasetime || '12h';
		i.enabled.checked = state.enabled !== false;
		i.force.checked = state.force === true;
		this.hosts = (state.hosts || []).map(h => ({ mac: h.mac || '', ip: h.ip || '', hostname: h.hostname || '' }));
		this.renderHosts();
		this.updatePreview();
	},

	// 实时预览：让用户直接看到地址池范围与可用数量，不必等到保存
	updatePreview() {
		const v = name => this.inputs[name].value.trim();
		const start = v('startIP'), end = v('endIP');
		const note = this.preview;
		if (!start || !end) { note.replaceChildren(E('span', { class: 'cn-dhcp-preview-muted' }, '填入起始与结束 IP 后将显示可用地址数。')); return; }
		const toNum = text => {
			const parts = String(text).split('.');
			if (parts.length !== 4 || parts.some(p => !/^\d{1,3}$/.test(p) || +p > 255)) return null;
			return parts.reduce((n, p) => n * 256 + +p, 0);
		};
		const a = toNum(start), b = toNum(end);
		if (a === null || b === null) { note.replaceChildren(E('span', { class: 'cn-dhcp-preview-bad' }, 'IP 格式不正确。')); return; }
		if (a > b) { note.replaceChildren(E('span', { class: 'cn-dhcp-preview-bad' }, '起始 IP 不能大于结束 IP。')); return; }
		const count = b - a + 1;
		note.replaceChildren(
			E('span', {}, '可用地址 '), E('strong', {}, String(count)), E('span', {}, ' 个（' + start + ' – ' + end + '）')
		);
	},

	renderHosts() {
		if (!this.hostBody) return;
		const rows = (this.hosts || []).map((host, index) => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, E('input', {
				type: 'text', value: host.mac, placeholder: 'AA:BB:CC:DD:EE:FF', class: 'cn-dhcp-host-input',
				change: ev => { this.hosts[index].mac = ev.target.value; }
			})),
			E('td', { class: 'td' }, E('input', {
				type: 'text', value: host.ip, placeholder: '192.168.1.10', class: 'cn-dhcp-host-input',
				change: ev => { this.hosts[index].ip = ev.target.value; }
			})),
			E('td', { class: 'td' }, E('input', {
				type: 'text', value: host.hostname, placeholder: '可选', class: 'cn-dhcp-host-input',
				change: ev => { this.hosts[index].hostname = ev.target.value; }
			})),
			E('td', { class: 'td cbi-section-actions' }, E('button', {
				type: 'button', class: 'cbi-button cbi-button-remove',
				click: () => { this.hosts.splice(index, 1); this.renderHosts(); }
			}, '删除'))
		]));
		this.hostBody.replaceChildren(...(rows.length ? rows : [ E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: '4' }, '暂无静态绑定')) ]));
	},

	collect() {
		const v = name => this.inputs[name].value.trim();
		return {
			enabled: this.inputs.enabled.checked,
			force: this.inputs.force.checked,
			startIP: v('startIP'),
			endIP: v('endIP'),
			gateway: v('gateway'),
			dns: [ v('dns1'), v('dns2') ].filter(Boolean),
			leasetime: v('leasetime'),
			hosts: (this.hosts || []).filter(h => h.mac && h.ip)
		};
	},

	async save() {
		const config = this.collect();
		try {
			const result = await applyConfig(config);
			if (result.error) throw new Error(result.error);
			this.state = result.state;
			this.fill(this.state);
			ui.addNotification(null, E('p', {}, result.restarted === false
				? '配置已保存，但 dnsmasq 重启失败，请到“系统 → 系统日志”查看原因。'
				: 'DHCP 配置已保存并生效。'), result.restarted === false ? 'warning' : 'info');
		}
		catch (error) { ui.addNotification(null, E('p', {}, error.message || '保存失败'), 'error'); }
	},

	confirmSave() {
		// 写入前明确告知影响范围，避免误改导致全网断网
		ui.showModal('应用 DHCP 配置', [
			E('p', {}, '将写入 /etc/config/dhcp 并重启 dnsmasq。已连接的客户端保留现有地址直到租约到期，新请求会使用新配置。'),
			E('p', { class: 'cn-dhcp-warn' }, '确认地址池与网关正确，否则内网设备可能拿不到地址。原配置已自动备份到 /etc/console-backup/dhcp.last-good。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'), ' ',
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => { ui.hideModal(); this.save(); } }, '确认应用')
			])
		]);
	},

	render(data) {
		if (!document.getElementById('cn-dhcp-page-css')) {
			document.head.append(E('link', {
				id: 'cn-dhcp-page-css', rel: 'stylesheet', href: '/luci-static/resources/console/dhcp-page.css'
			}));
		}
		if (data && data.error) {
			return E('div', { class: 'cbi-map' }, [ E('h2', {}, 'DHCP 服务器'), E('p', { class: 'alert-message error' }, data.error) ]);
		}
		this.state = data && data.state ? data.state : {};
		const s = this.state || {};

		// 用显式属性代替 { selected/checked: bool }：E() 对 false 值的处理
		// 在不同 LuCI 版本上不一致，容易出现选中项错位。
		const leaseSelect = E('select', {}, LEASE_OPTIONS.map(([ value, title ]) => {
			const option = E('option', { value }, title);
			if ((s.leasetime || '12h') === value) option.setAttribute('selected', 'selected');
			return option;
		}));
		const enabledBox = E('input', { type: 'checkbox' });
		if (s.enabled !== false) enabledBox.setAttribute('checked', 'checked');
		const forceBox = E('input', { type: 'checkbox' });
		if (s.force === true) forceBox.setAttribute('checked', 'checked');

		this.inputs = {
			startIP: E('input', { type: 'text', value: s.pool ? s.pool.startIP : '', placeholder: '192.168.1.100', input: () => this.updatePreview() }),
			endIP: E('input', { type: 'text', value: s.pool ? s.pool.endIP : '', placeholder: '192.168.1.249', input: () => this.updatePreview() }),
			gateway: E('input', { type: 'text', value: s.gateway || '', placeholder: '192.168.1.1' }),
			dns1: E('input', { type: 'text', value: (s.dns || [])[0] || '', placeholder: '223.5.5.5' }),
			dns2: E('input', { type: 'text', value: (s.dns || [])[1] || '', placeholder: '选填' }),
			leasetime: leaseSelect,
			enabled: enabledBox,
			force: forceBox
		};
		this.hosts = (s.hosts || []).map(h => ({ mac: h.mac || '', ip: h.ip || '', hostname: h.hostname || '' }));
		this.hostBody = E('tbody', { class: 'tbody' });
		this.preview = E('div', { class: 'cn-dhcp-preview' });

		const lanText = s.lan ? (s.lan.address + '/' + s.lan.prefix) : '未知';

		// 顶部状态条：明确区分"配置已启用"与"实际正在分配地址"，
		// 避免 uci 写着启用、实际被 dhcp_check 挡住时误导用户。
		const runtime = s.runtime || {};
		let statusBadge, statusText;
		if (s.enabled === false) {
			statusBadge = 'label-info'; statusText = '已停用 —— 配置中关闭了本接口的 DHCP，不会分配地址。';
		}
		else if (runtime.serving) {
			statusBadge = 'label-success'; statusText = '运行中 —— dnsmasq 已加载地址池，当前有 ' + (runtime.leases || 0) + ' 条租约。';
		}
		else if (runtime.blocked) {
			statusBadge = 'label-warning';
			statusText = '配置已启用，但实际未分配地址 —— 检测到同网段有其他 DHCP 服务器，dnsmasq 自动跳过该接口。'
				+ '需要在此启用“强制启用”，或先移除上游那个 DHCP 服务器。';
		}
		else {
			statusBadge = 'label-warning'; statusText = '配置已启用，但 dnsmasq 尚未加载地址池，可尝试重新保存以重启 dnsmasq。';
		}
		const statusBar = E('div', { class: 'cn-dhcp-status' }, [
			E('span', { class: 'badge ' + statusBadge }, s.enabled === false ? '已停用' : runtime.serving ? '运行中' : '未生效'),
			E('span', { class: 'cn-dhcp-status-text' }, statusText)
		]);
		const enabledLabel = s.enabled === false ? '启用 DHCP（当前：已停用）' : runtime.serving ? '启用 DHCP（当前：运行中）' : '启用 DHCP（配置已启用，但未生效）';
		const enabledField = field(enabledLabel, this.inputs.enabled, '关闭后本接口不再分配地址，仅静态配置的设备可用。');

		const panel = E('div', { class: 'cbi-map cn-dhcp-page' }, [
			E('h2', {}, 'DHCP 服务器'),
			E('p', {}, '为局域网设备自动分配 IP 地址。本页按“起始/结束 IP”描述地址池，保存后立即重启 dnsmasq 生效。'),
			statusBar,

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '地址池'),
				E('p', { class: 'cbi-value-description' }, '网关 ' + lanText + '　·　地址池需在同一网段内，且不能包含路由器地址与广播地址。'),
				field('起始 IP', this.inputs.startIP),
				field('结束 IP', this.inputs.endIP),
				this.preview
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '网关与 DNS'),
				field('默认网关', this.inputs.gateway, '留空则使用路由器自身地址。'),
				field('首选 DNS', this.inputs.dns1, '留空表示不额外下发 DNS，由客户端使用路由器地址。'),
				field('备用 DNS', this.inputs.dns2)
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '租期与开关'),
				field('租约时间', this.inputs.leasetime, '客户端续租前可使用该地址的时长。'),
				enabledField,
				field('强制启用', this.inputs.force, '检测到同网段存在其他 DHCP 服务器时仍强制启用。启用前请确认上游没有多余的 DHCP 服务，否则会出现两个服务器争抢客户端。')
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '静态地址绑定'),
				E('p', { class: 'cbi-value-description' }, '按 MAC 固定分配 IP，适合打印机、NAS 等需要固定地址的设备。'),
				E('table', { class: 'table cbi-section-table' }, [
					E('thead', {}, E('tr', { class: 'tr table-titles' }, [ 'MAC 地址', 'IP 地址', '备注', '操作' ].map(t => E('th', { class: 'th' }, t)))),
					this.hostBody
				]),
				E('button', {
					type: 'button', class: 'cbi-button cbi-button-add',
					click: () => { this.hosts.push({ mac: '', ip: '', hostname: '' }); this.renderHosts(); }
				}, '添加绑定')
			]),

			E('div', { class: 'button-row cn-dhcp-actions' }, [
				E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.confirmSave() }, '保存并应用'),
				E('button', { type: 'button', class: 'cbi-button cbi-button-reset', click: () => this.refresh() }, '重新读取')
			])
		]);

		this.renderHosts();
		this.updatePreview();
		return panel;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
}));
