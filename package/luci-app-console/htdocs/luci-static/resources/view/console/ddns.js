// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

const callState = rpc.declare({ object: 'console-ddns', method: 'state', reject: true });
const callApply = rpc.declare({ object: 'console-ddns', method: 'apply', params: ['config'], reject: true });
const callLog = rpc.declare({ object: 'console-ddns', method: 'log', params: ['section'], reject: true });
const callProbe = rpc.declare({ object: 'console-ddns', method: 'probe', reject: true });

function checked(result) { if (!result || result.error) throw new Error(result?.error || '服务未响应'); return result; }
function node(tag, cls, text) { return E(tag, { class: cls }, text == null ? '' : String(text)); }
function field(title, input, help) {
	const id = 'ddns-' + Math.random().toString(36).slice(2, 9);
	input.id = id;
	return E('div', { class: 'cbi-value' }, [
		E('label', { class: 'cbi-value-title', for: id }, title),
		E('div', { class: 'cbi-value-field' }, [ input, help ? E('div', { class: 'cbi-value-description' }, help) : '' ])
	]);
}
function option(values, current) { return E('select', {}, values.map(([v, t]) => E('option', { value: v, selected: v === current || null }, t))); }
function time(n) { return n ? new Date(n * 1000).toLocaleString('zh-CN') : '—'; }
function copy(value) { return JSON.parse(JSON.stringify(value)); }

return view.extend({
	load() { return callState().then(checked); },

	button(label, fn, kind) {
		return E('button', { type: 'button', class: 'cbi-button ' + (kind || ''), click: async ev => {
			const el = ev.currentTarget;
			if (el.disabled) return;
			el.disabled = true;
			try { await fn(); }
			catch (e) { ui.addNotification(null, E('p', {}, e.message || '操作失败'), 'error'); }
			finally { el.disabled = false; }
		} }, label);
	},

	async refresh(silent) {
		if (this.busy) return;
		if (silent && document.querySelector('#modal_overlay > .modal')) return;
		try {
			this.data = checked(await callState());
			this.renderStats();
			this.renderRows();
			this.warning.hidden = true;
		}
		catch (e) {
			if (!silent) { this.warning.textContent = '刷新失败：' + (e.message || e); this.warning.hidden = false; }
		}
	},

	async save(services, global) {
		this.busy = true;
		this.status.textContent = '正在保存并重启 DDNS 服务…';
		try {
			this.data = checked(await callApply({ services, global: global || this.data.global }));
			this.renderStats();
			this.renderRows();
			this.status.textContent = this.data.reloaded ? '已保存并生效' : '已保存，服务重启失败';
			if (!this.data.reloaded)
				ui.addNotification(null, E('p', {}, '已保存，但服务重启失败' + (this.data.warning ? '：' + this.data.warning : '')), 'warning');
			return true;
		}
		catch (e) {
			this.status.textContent = '保存失败';
			throw e;
		}
		finally { this.busy = false; }
	},

	model() {
		return this.data.services.map(s => ({
			id: s.id, enabled: s.enabled, service_name: s.custom_url ? 'custom' : s.service_name, custom_url: s.custom_url,
			domain: s.domain, username: s.username, use_ipv6: s.use_ipv6, ip_source: s.ip_source,
			ip_network: s.ip_network, ip_url: s.ip_url, ip_interface: s.ip_interface,
			check_interval: s.check_interval, check_unit: s.check_unit,
			force_interval: s.force_interval, force_unit: s.force_unit
		}));
	},

	statusOf(s) {
		if (s.error) return ['异常', 'ddns-badge error', s.error];
		if (s.running) return ['运行中', 'ddns-badge ok', ''];
		if (s.enabled) return ['等待启动', 'ddns-badge wait', ''];
		return ['已停用', 'ddns-badge off', ''];
	},

	renderStats() {
		const services = this.data.services;
		const values = {
			total: services.length,
			enabled: services.filter(s => s.enabled).length,
			running: services.filter(s => s.running).length,
			error: services.filter(s => s.error).length
		};
		for (const key of Object.keys(this.metrics)) this.metrics[key].textContent = values[key];
	},

	render(data) {
		this.data = checked(data);
		if (!document.getElementById('console-security-css'))
			document.head.appendChild(E('link', { id: 'console-security-css', rel: 'stylesheet', href: L.resource('console/security.css') }));
		if (!document.getElementById('console-ddns-css'))
			document.head.appendChild(E('link', { id: 'console-ddns-css', rel: 'stylesheet', href: L.resource('console/ddns.css') }));

		this.status = E('span', { class: 'ddns-status-text', 'aria-live': 'polite' }, '');
		this.warning = E('div', { class: 'alert-message warning', hidden: true }, '');
		this.search = E('input', { type: 'search', placeholder: '名称 / 域名 / 服务商', 'aria-label': '搜索 DDNS 服务', input: () => this.renderRows() });

		this.metrics = {};
		const cards = [];
		for (const [key, label] of [['total', '服务总数'], ['enabled', '已启用'], ['running', '运行中'], ['error', '异常']]) {
			this.metrics[key] = node('strong', '', '—');
			cards.push(E('div', { class: 'cs-metric' }, [ node('span', '', label), this.metrics[key] ]));
		}

		this.tbody = E('tbody');
		const headers = ['名称', '服务商', '域名', 'IP 版本', '状态', '最后更新', '操作'];

		const root = E('div', { class: 'cbi-map cs-security ddns-root' }, [
			E('div', { class: 'cs-heading' }, [
				E('div', {}, [
					E('h2', {}, '动态 DNS'),
					node('p', 'cs-note', '把路由器的公网 IPv4/IPv6 地址自动同步到域名服务商。保存后按实例重启 ddns-scripts，已有配置立即生效。')
				]),
				E('div', { class: 'cs-actions' }, [
					this.button('立即更新', async () => { this.data = checked(await callProbe()); this.renderStats(); this.renderRows(); this.status.textContent = '已触发更新'; }),
					this.button('全局设置', () => this.editGlobal()),
					this.button('添加服务', () => this.edit(null), 'cbi-button-add')
				])
			]),
			this.warning,
			E('div', { class: 'cs-metrics' }, cards),
			E('section', { class: 'cbi-section cs-panel' }, [
				E('div', { class: 'cs-toolbar' }, [ this.search, this.status ]),
				E('div', { class: 'cs-scroll' }, E('table', { class: 'table' }, [
					E('thead', {}, E('tr', { class: 'tr table-titles' }, headers.map(h => E('th', { class: 'th' }, h)))),
					this.tbody
				]))
			]),
			node('p', 'cs-note', '服务商列表来自 /usr/share/ddns/default 与 custom；自定义服务需要包含 [DOMAIN] 和 [IP] 占位符的更新 URL。安装 ddns-scripts 自带的 myddns_ipv4 / myddns_ipv6 为示例配置，可直接删除。'),
			node('p', 'cs-note', '“检查间隔”是检测 IP 变化的周期，“强制更新间隔”用于即使 IP 未变也定期上报；公网地址为运营商私网时需在全局设置中允许私有 IP。')
		]);

		if (!this.data.installed) {
			this.warning.textContent = '未检测到 ddns-scripts（/usr/lib/ddns/dynamic_dns_updater.sh），请先安装后再使用本页面。';
			this.warning.hidden = false;
		}

		this.root = root;
		this.renderStats();
		this.renderRows();
		poll.add(() => this.refresh(true), 20);
		return root;
	},

	renderRows() {
		const q = this.search.value.trim().toLowerCase();
		const rows = this.data.services.filter(s => [s.id, s.domain, s.provider_label, s.service_name].join(' ').toLowerCase().includes(q));
		if (!rows.length) {
			this.tbody.replaceChildren(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 7 }, this.data.services.length ? '没有符合筛选条件的服务。' : '暂无 DDNS 服务，点击“添加服务”创建。')));
			return;
		}
		this.tbody.replaceChildren(...rows.map(s => {
			const [label, cls, detail] = this.statusOf(s);
			const badge = E('span', { class: cls, title: detail || null }, label);
			return E('tr', { class: 'tr' }, [
				E('td', { class: 'td' }, [ E('strong', {}, s.id), ...(s.password_set ? [] : [ node('span', 'ddns-hint', ' 未设密码') ]) ]),
				E('td', { class: 'td' }, s.provider_label || s.service_name || '—'),
				E('td', { class: 'td' }, s.domain || '—'),
				E('td', { class: 'td' }, s.use_ipv6 ? 'IPv6' : 'IPv4'),
				E('td', { class: 'td' }, [ badge, s.last_ip ? node('span', 'ddns-ip', ' ' + s.last_ip) : '' ]),
				E('td', { class: 'td' }, time(s.last_update)),
				E('td', { class: 'td' }, E('div', { class: 'cs-actions' }, [
					this.button('编辑', () => this.edit(s)),
					this.button('日志', () => this.showLog(s)),
					this.button(s.enabled ? '停用' : '启用', () => this.toggle(s, !s.enabled)),
					this.button('删除', () => this.remove(s), 'cbi-button-remove')
				]))
			]);
		}));
	},

	async toggle(s, enabled) {
		const services = this.model().map(item => item.id === s.id ? { ...item, enabled } : item);
		await this.save(services, this.data.global);
	},

	remove(s) {
		const services = this.model().filter(item => item.id !== s.id);
		ui.showModal('删除 DDNS 服务', [
			E('p', {}, '确定删除“' + s.id + '”（' + (s.domain || '未填写域名') + '）？'),
			E('div', { class: 'button-row' }, [
				this.button('取消', () => ui.hideModal()),
				this.button('删除', async () => { await this.save(services, this.data.global); ui.hideModal(); }, 'cbi-button-remove')
			])
		]);
	},

	async showLog(s) {
		try {
			const log = checked(await callLog(s.id));
			ui.showModal('DDNS 日志 · ' + s.id, [
				E('pre', { class: 'cs-log' }, log.lines.length ? log.lines.join('\n') : '暂无日志。服务启动并完成一次检测后才会写入。'),
				E('div', { class: 'button-row' }, [
					this.button('刷新', async () => { ui.hideModal(); await this.showLog(s); }),
					this.button('关闭', () => ui.hideModal())
				])
			]);
		}
		catch (e) { ui.addNotification(null, E('p', {}, e.message), 'error'); }
	},

	editGlobal() {
		const priv = E('input', { type: 'checkbox', checked: this.data.global.upd_privateip || null });
		const lines = E('input', { type: 'number', min: 50, max: 2000, value: this.data.global.loglines || 250 });
		ui.showModal('DDNS 全局设置', [
			field('允许私有 IP', priv, '接受 10/172.16/192.168 等私网地址。路由器 WAN 处于运营商 NAT 后面时开启，否则服务商会拒绝私网地址。'),
			field('日志行数', lines, '保留在 /var/log/ddns/<服务>.log 中的行数。'),
			E('div', { class: 'button-row' }, [
				this.button('保存', async () => {
					await this.save(this.model(), { upd_privateip: priv.checked, loglines: +lines.value || 250 });
					ui.hideModal();
				}, 'cbi-button-save'),
				this.button('取消', () => ui.hideModal())
			])
		]);
	},

	edit(original) {
		if (!this.data.installed) { ui.addNotification(null, E('p', {}, 'ddns-scripts 未安装，无法添加服务。'), 'error'); return; }
		const s = copy(original || {
			id: '', enabled: true, service_name: '', custom_url: '', domain: '', username: '',
			use_ipv6: false, ip_source: 'network', ip_network: '', ip_url: '', ip_interface: '',
			check_interval: 10, check_unit: 'minutes', force_interval: 72, force_unit: 'hours', password_set: false
		});
		const editing = !!original;

		const name = E('input', { type: 'text', value: s.id, maxlength: 32, placeholder: '例如 home' });
		if (editing) { name.disabled = true; name.title = '服务名称创建后不可修改'; }

		const providerValues = this.data.providers.map(p => [p.value, p.label + (p.custom ? '（自定义）' : '')]);
		if (!providerValues.some(([v]) => v === s.service_name) && s.service_name)
			providerValues.unshift([s.service_name, s.service_name + '（已移除）']);
		providerValues.push(['custom', '自定义更新 URL']);
		const provider = option(providerValues, s.service_name || (this.data.providers[0] || ['custom'])[0]);

		const customUrl = E('input', { type: 'text', value: s.custom_url, placeholder: 'https://example.com/update?host=[DOMAIN]&ip=[IP]' });
		const domain = E('input', { type: 'text', value: s.domain, placeholder: '例如 home.example.com' });
		const username = E('input', { type: 'text', value: s.username, maxlength: 256 });
		const password = E('input', { type: 'password', value: '', maxlength: 256, placeholder: s.password_set ? '留空保持原密码' : '服务商密码或 API Token' });

		const ipVersion = option([['0', 'IPv4'], ['1', 'IPv6']], s.use_ipv6 ? '1' : '0');
		const source = option([['network', '网络接口（WAN 地址）'], ['web', '互联网获取 IP（多级 NAT）'], ['interface', '物理网卡（直连拨号）']], s.ip_source);
		const netValues = this.data.networks.map(n => [n.name, n.name + (n.up ? '' : '（离线）') + (n.proto ? ' · ' + n.proto : '')]);
		const net = option(netValues, s.ip_network);
		if (!netValues.some(([v]) => v === s.ip_network) && s.ip_network) net.appendChild(E('option', { value: s.ip_network, selected: true }, s.ip_network + '（已移除）'));
		const checkUrl = E('input', { type: 'text', value: s.ip_url, placeholder: 'https://checkip.amazonaws.com' });
		const nic = E('input', { type: 'text', value: s.ip_interface, placeholder: '例如 eth1' });

		const interval = E('input', { type: 'number', min: 1, max: 1440, value: s.check_interval });
		const intervalUnit = option([['minutes', '分钟'], ['hours', '小时']], s.check_unit);
		const force = E('input', { type: 'number', min: 0, max: 8760, value: s.force_interval });
		const forceUnit = option([['hours', '小时'], ['days', '天']], s.force_unit);

		const enabled = E('input', { type: 'checkbox', checked: s.enabled || null });
		const error = E('div', { role: 'alert' });

		const next = () => ({
			id: name.value.trim(), enabled: enabled.checked, service_name: provider.value,
			custom_url: customUrl.value.trim(), domain: domain.value.trim(), username: username.value.trim(),
			password: password.value, use_ipv6: ipVersion.value === '1', ip_source: source.value,
			ip_network: net.value, ip_url: checkUrl.value.trim(), ip_interface: nic.value.trim(),
			check_interval: +interval.value, check_unit: intervalUnit.value,
			force_interval: +force.value, force_unit: forceUnit.value
		});

		const body = E('div', { class: 'ddns-editor' }, [
			error,
			field('服务名称', name, '用于 UCI 段名和日志文件名，创建后不可修改。'),
			field('服务商', provider),
			field('自定义更新 URL', customUrl, '必须包含 [DOMAIN] 和 [IP]，例如 https://api.example.com/update?host=[DOMAIN]&ip=[IP]'),
			field('域名', domain, '要同步的完整域名，同时用于校验解析结果。'),
			field('用户名', username, '多数服务商为账号、邮箱或 AccessKey ID。'),
			field('密码 / Token', password, editing ? '留空表示不修改已保存的凭据。' : '服务商密码、API Token 或 Secret。'),
			field('IP 版本', ipVersion),
			field('获取方式', source, 'WAN 拿到的是私网地址（多级 NAT）时选择“互联网获取 IP”，由公网服务返回真实出口地址。'),
			field('网络接口', net),
			field('在线检测 URL', checkUrl, '返回纯文本公网 IP 的地址，留空时使用 https://checkip.amazonaws.com。'),
			field('物理网卡', nic, '直接读取网卡地址，通常不需要。'),
			field('检查间隔', E('div', { class: 'ddns-inline' }, [ interval, intervalUnit ]), '检测公网地址变化的周期。'),
			field('强制更新间隔', E('div', { class: 'ddns-inline' }, [ force, forceUnit ]), '即使地址未变化也定期上报；0 表示只在变化时更新。'),
			field('启用', E('label', {}, [ enabled, ' 保存后立即启动' ])),
			E('div', { class: 'button-row' }, [
				this.button('保存', async () => {
					error.replaceChildren();
					try {
						const item = next();
						const services = this.model();
						const index = services.findIndex(x => x.id === item.id);
						if (index >= 0) services[index] = item;
						else {
							if (services.some(x => x.id === item.id)) throw new Error('服务名称已存在');
							services.push(item);
						}
						await this.save(services, this.data.global);
						ui.hideModal();
					}
					catch (e) { error.replaceChildren(E('p', { class: 'alert-message error' }, e.message)); }
				}, 'cbi-button-save'),
				this.button('取消', () => ui.hideModal())
			])
		]);

		const row = input => input.closest('.cbi-value');
		const DEFAULT_IP_URL = 'https://checkip.amazonaws.com';
		const showSource = () => {
			const web = source.value === 'web';
			row(net).hidden = source.value !== 'network';
			row(checkUrl).hidden = !web;
			row(nic).hidden = source.value !== 'interface';
			if (web && !checkUrl.value) checkUrl.value = DEFAULT_IP_URL;
		};
		const showCustom = () => { row(customUrl).hidden = provider.value !== 'custom'; };
		const domainHelp = row(domain).querySelector('.cbi-value-description');
		const userHelp = row(username).querySelector('.cbi-value-description');
		const passHelp = row(password).querySelector('.cbi-value-description');
		const CREDS = {
			'aliyun.com': [ '阿里云 AccessKey ID', '阿里云 AccessKey Secret' ],
			'dnspod.cn': [ 'DNSPod Token ID（纯数字）', 'DNSPod Token' ],
			'dnspod.cn-v3': [ '腾讯云 SecretId（通常以 AKID 开头）', '腾讯云 SecretKey' ]
		};
		const syncDomain = () => {
			const atFormat = provider.value === 'aliyun.com' || provider.value === 'dnspod.cn-v3';
			domain.placeholder = atFormat ? '主机记录@域名，例如 home@example.com' : '例如 home.example.com';
			if (domainHelp) domainHelp.textContent = atFormat
				? '该服务商要求“主机记录@域名”格式，例如 home@example.com。'
				: '要同步的完整域名，同时用于校验解析结果。';
			const cred = CREDS[provider.value];
			if (userHelp) userHelp.textContent = cred ? cred[0] : '多数服务商为账号、邮箱或 AccessKey ID。';
			if (passHelp) passHelp.textContent = (editing ? '留空表示不修改已保存的凭据。' : '') + (cred ? ' ' + cred[1] + '。' : ' 服务商密码、API Token 或 Secret。');
		};
		source.addEventListener('change', showSource);
		provider.addEventListener('change', () => { showCustom(); syncDomain(); });
		showSource();
		showCustom();
		syncDomain();

		ui.showModal(editing ? '编辑 DDNS 服务' : '添加 DDNS 服务', [ body ]);
		document.querySelector('#modal_overlay > .modal')?.classList.add('ddns-modal');
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
