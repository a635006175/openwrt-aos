// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require console.yaml as yaml';

const status = rpc.declare({ object: 'console-mihomo', method: 'status', reject: true });
const save = rpc.declare({ object: 'console-mihomo', method: 'save', params: ['config', 'mode'], reject: true });
const action = rpc.declare({ object: 'console-mihomo', method: 'action', params: ['action'], reject: true });
const select = rpc.declare({ object: 'console-mihomo', method: 'select', params: ['group', 'name'], reject: true });
const mode = rpc.declare({ object: 'console-mihomo', method: 'mode', params: ['mode'], reject: true });
const fetchConfig = rpc.declare({ object: 'console-mihomo', method: 'fetch_config', params: ['url'], reject: true });
const measureDelay = rpc.declare({ object: 'console-mihomo', method: 'delay', params: ['name'], reject: true });
const testSite = rpc.declare({ object: 'console-mihomo', method: 'site_test', params: ['id'], reject: true });
const vpnProxy = rpc.declare({ object: 'console-mihomo', method: 'vpn_proxy', params: ['enabled'], reject: true });
const clearConfig = rpc.declare({ object: 'console-mihomo', method: 'clear', reject: true });
function latencyClass(result,pending){
	if(pending||!result)return '';
	if(result.delay==null||!Number.isFinite(+result.delay)||+result.delay<0)return 'cm-latency-slow';
	return +result.delay<100?'cm-latency-fast':+result.delay<300?'cm-latency-medium':'cm-latency-slow';
}
const startDelayBatch = rpc.declare({object:'console-mihomo',method:'delay_start',reject:true});
const applySourcePolicy = rpc.declare({object:'console-mihomo',method:'source_policy',params:['policy'],reject:true});
const websites = [
	{ id: 'github', name: 'GitHub', url: 'https://github.com/' },
	{ id: 'google', name: 'Google（谷歌）', url: 'https://www.google.com/' },
	{ id: 'chatgpt', name: 'ChatGPT', url: 'https://chatgpt.com/' },
	{ id: 'youtube', name: 'YouTube', url: 'https://www.youtube.com/' }
];

return view.extend({
	load() { return status(); },
	field(label, control, help) {
		const id = 'console-mihomo-' + (++this.fieldIndex); control.id = id;
		return E('div', { class: 'cbi-value' }, [E('label', { class: 'cbi-value-title', for: id }, label), E('div', { class: 'cbi-value-field' }, [control, help ? E('div', { class: 'cbi-value-description' }, help) : ''])]);
	},
	async run(fn, message) {
		if (this.pending) return;
		if (this.errorNotice) { this.errorNotice.remove(); this.errorNotice = null; }
		this.pending = true; this.updateButtons(); this.feedback.textContent = '处理中…';
		try {
			const r = await fn(); if (r.error || !r.ok) throw new Error(r.error || '操作失败');
			this.feedback.textContent = message;
			await this.refresh();
		} catch (e) { this.feedback.textContent = e.message; this.errorNotice = ui.addNotification(null, E('p', {}, e.message), 'error'); }
		finally { this.pending = false; this.updateButtons(); }
	},
	updateButtons() {
		if (!this.startButton) return;
		const disabled = this.pending || !L.hasViewPermission();
		this.vpnProxy.disabled = disabled;this.sourceApply.disabled=disabled;this.sourcePanel?.querySelectorAll('button,input,select,textarea').forEach(el=>el.disabled=disabled);
		this.nodePrev.disabled=disabled||this.nodePage===0;this.nodeNext.disabled=disabled||(this.nodePage+1)*20>=this.state.nodes.length;
		this.startButton.disabled = disabled || !this.state.configured || this.state.enabled;
		this.stopButton.disabled = disabled || !this.state.enabled;
		this.saveButton.disabled = disabled || this.state.enabled;
		// 无配置且服务未启动时自动禁用，避免误点
		this.clearButton.disabled = disabled || (!this.state.configured && !this.state.enabled);
		this.linkButton.disabled = disabled || this.state.enabled || !this.link.value.trim();
		this.modeButton.disabled = disabled || !this.state.running;
		this.testButton.disabled = disabled || !!this.state.delayJob?.running || !this.state.running || !(this.state.nodes || []).length;
		this.websiteButton.disabled = disabled || !this.state.running;
		this.groupBox.querySelectorAll('button').forEach(b => b.disabled = disabled || !this.state.running);
		this.delayBox.querySelectorAll('button').forEach(b => b.disabled = disabled || !this.state.running || !!this.state.delayJob?.running);
		this.websiteBox.querySelectorAll('button').forEach(b => b.disabled = disabled || !this.state.running);
	},
	async refresh() {
		if (document.hidden || this.refreshing || this.testing) return;
		this.refreshing = true;
		try { const s = await status(); if (s.error) throw new Error(s.error); this.paint(s); }
		catch (e) { this.badge.className = 'badge label-warning'; this.badge.textContent = '状态读取失败'; }
		finally { this.refreshing = false; }
	},
	confirmClear() {
		const s = this.state || {};
		ui.showModal('清除配置', [
			E('p', {}, '将停止服务、关闭开机自启并撤销透明代理规则，然后删除已导入的配置、临时配置、运行缓存、订阅集合缓存和测速 / 网站测试结果。'),
			E('p', {}, '当前状态：' + (s.running ? '内核正在运行' : s.enabled ? '已启用但内核未响应' : s.configured ? '已配置，服务已停止' : '未导入配置') + '。清除后需重新导入配置并启动服务才能再次使用。'),
			E('p', {}, '保留控制密钥、地理库、来源 IP 策略、OpenVPN 代理开关设置和订阅集合目录。'),
			E('div', { class: 'button-row' }, [
				E('button', { type: 'button', class: 'cbi-button', click: () => ui.hideModal() }, '取消'),
				E('button', { type: 'button', class: 'cbi-button cbi-button-remove', click: () => { ui.hideModal(); this.run(() => clearConfig(), '配置已清除，服务已停止。'); } }, '清除配置')
			])
		]);
	},
	delayLabel(measurement) {
		if (!measurement) return '未测速';
		return measurement.delay == null ? '超时或失败' : measurement.delay + ' ms';
	},
	async testNodes(names) {
		this.testing = true;
		try {
			for (let i = 0; i < names.length; i++) {
				this.testProgress.textContent = '测速中 ' + (i + 1) + '/' + names.length + ' · ' + names[i];
				const r = await measureDelay(names[i]); if (r.error || !r.ok) throw new Error(r.error || '测速失败');
				const node = this.state.nodes.find(n => n.name === names[i]); if (node) node.measurement = r.measurement;
				this.paint(this.state);
			}
			this.testProgress.textContent = '测速完成 · ' + names.length + ' 个节点';
			return { ok: true };
		} finally { this.testing = false; }
	},
	async testWebsites(ids) {
		this.testing = true;
		try {
			for (let i = 0; i < ids.length; i++) {
				this.sitePending = ids[i]; this.paintWebsites(this.state);
				this.websiteProgress.textContent = '正在测试 ' + (i + 1) + '/' + ids.length + ' · ' + websites.find(s => s.id === ids[i]).name;
				const r = await testSite(ids[i]); if (r.error || !r.ok) throw new Error(r.error || '网站测试失败');
				this.state.siteTests = this.state.siteTests || {}; this.state.siteTests[ids[i]] = r.result;
				this.sitePending = null; this.paintWebsites(this.state);
			}
			this.websiteProgress.textContent = '测试完成 · ' + ids.length + ' 个网站';
			return { ok: true };
		} finally { this.testing = false; this.sitePending = null; this.paintWebsites(this.state); }
	},
	paintWebsites(s) {
		const signature = JSON.stringify([s.siteTests || {}, this.sitePending]);
		if (signature === this.websiteSignature) return;
		this.websiteSignature = signature;
		const labels = { success: '可访问', restricted: '访问受限', 'http-error': 'HTTP 异常', timeout: '超时', failed: '连接失败' };
		this.websiteBox.replaceChildren(...websites.map(site => {
			const r = (s.siteTests || {})[site.id], pending = this.sitePending === site.id;
			let label = pending ? '测试中…' : r ? (labels[r.status] || '连接失败') : '未测试';
			if (r && !pending) label += (r.code ? ' · HTTP ' + r.code : '') + (r.delay != null ? ' · ' + r.delay + ' ms' : '');
			const badge = E('span', { class: 'badge ' + (pending || !r ? 'label-info' : r.status === 'success' ? 'label-success' : 'label-warning'), 'data-site-result': site.id, role: 'status' }, label);
			return E('div', { class: 'cbi-value '+latencyClass(r,pending) }, [
				E('div', { class: 'cbi-value-title' }, E('a', { href: site.url, target: '_blank', rel: 'noopener noreferrer' }, site.name)),
				E('div', { class: 'cbi-value-field' }, [badge, ' ', E('button', { type: 'button', class: 'cbi-button', 'aria-label': '测试 ' + site.name, click: () => this.run(() => this.testWebsites([site.id]), site.name + ' 测试已完成。') }, '测试'),
					r && !pending ? E('div', { class: 'cbi-value-description' }, '测试时间：' + new Date(r.testedAt * 1000).toLocaleString() + (r.status === 'restricted' ? '。已收到网站响应，但可能存在地区、登录、限流或访问验证限制。' : '')) : ''])
			]);
		}));
		this.updateButtons();
	},
	async importLink() {
		let url;
		try { url = new URL(this.link.value.trim()); } catch (_) { throw new Error('请输入有效的 HTTP 或 HTTPS 配置链接'); }
		if (!['http:', 'https:'].includes(url.protocol) || url.href.length > 4096) throw new Error('请输入有效的 HTTP 或 HTTPS 配置链接');
		this.feedback.textContent = '正在下载配置…';
		let text;
		if (this.downloadVia.value === 'router') {
			const r = await fetchConfig(url.href); if (r.error || !r.ok) throw new Error(r.error || '路由器下载失败'); text = r.config;
		} else {
			const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 20000);
			try {
				const response = await fetch(url.href, { signal: controller.signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
				if (!response.ok) throw new Error('HTTP ' + response.status);
				const reader = response.body.getReader(), decoder = new TextDecoder(); let size = 0; text = '';
				try {
					for (;;) {
						const chunk = await reader.read(); if (chunk.done) break;
						size += chunk.value.byteLength; if (size > 2097152) throw new Error('配置文件最大支持 2 MB');
						text += decoder.decode(chunk.value, { stream: true });
					}
					text += decoder.decode();
				} finally { await reader.cancel().catch(() => {}); }
			} catch (e) {
				if (e.message === '配置文件最大支持 2 MB') throw e;
				throw new Error('浏览器下载失败：链接可能不可达或不允许跨域访问。请改用路由器下载，或在电脑下载后上传文件。');
			} finally { clearTimeout(timer); }
		}
		let parsed;
		try { parsed = yaml.load(text); } catch (_) { throw new Error('链接未返回有效的 Clash / Mihomo YAML 或 JSON 配置'); }
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('链接必须返回完整的 Clash / Mihomo 配置，不支持节点分享链接或 Base64 节点列表');
		this.feedback.textContent = '下载完成，正在校验配置…（最多 10 秒）';
		const result = await save(JSON.stringify(parsed), this.mode.value);
		if (result.ok) this.link.value = '';
		return result;
	},
	paint(s) {
		s.nodes = s.nodes || []; s.ruleGroups = s.ruleGroups || [];
		this.state = s;
		if(!this.sourceDirty){this.sourceMode.value=s.sourcePolicy?.mode||'all';this.sourceIPs.value=(s.sourcePolicy?.addresses||[]).join('\n');this.sourceRevision=s.sourcePolicy?.revision||0;}
		const job=s.delayJob;if(job)this.testProgress.textContent=job.running?'后台测速中：'+job.completed+' / '+job.total+' · 最多'+job.concurrency+'路并发，可离开页面':job.error||'后台测速完成：'+job.completed+' / '+job.total+' · 失败 '+job.failed+' 个';
		this.vpnProxy.checked = !!s.vpnProxyEnabled;
		this.badge.className = 'badge ' + (s.running ? 'label-success' : s.enabled ? 'label-warning' : 'label-info');
		this.badge.textContent = s.running ? '运行中 · Mihomo ' + s.version : s.enabled ? '已启用，等待内核响应；持续无响应时请查看系统日志' : s.configured ? '已配置 · 已停止' : '待导入配置';
		this.endpoint.textContent = s.address + ':' + s.port + '（HTTP / SOCKS5）';
		this.scope.textContent = s.transparent ? '已启用 · 来源策略：'+({all:'全部接管',include:'仅指定IP接管',exclude:'指定IP不接管',none:'全部直连'}[s.sourcePolicy?.mode||'all'])+'（' + (s.lanDevices || []).join('、') + '）' : s.enabled ? '正在准备内网自动代理；持续未就绪时请查看系统日志' : '已停止 · 内网恢复原有上网路径';
		if (!this.modeDirty) this.mode.value = s.mode;
		this.policyHint.textContent = s.mode === 'rule' ? '当前为规则模式，规则引用的代理组：' + (s.ruleGroups.join('、') || '无') + '。GLOBAL 用于全局模式。' : s.mode === 'global' ? '当前为全局模式，出口由 GLOBAL 组决定。' : '当前为全局直连，选择代理节点不会改变直连出口。';
		const signature = JSON.stringify([s.groups, s.nodes, s.mode]);
		if (signature !== this.groupSignature) {
			this.groupSignature = signature;
			const nodeFor=name=>{const seen=new Set();while(name&&!seen.has(name)){seen.add(name);const node=s.nodes.find(n=>n.name===name);if(node)return node;name=s.groups.find(g=>g.name===name)?.now;}return null;};
			const colorFor=node=>({'cm-latency-fast':'#1f6b3a','cm-latency-medium':'#8a6000','cm-latency-slow':'#b32925'}[latencyClass(node?.measurement,false)]||'#526777');
			const badgeFor=node=>E('span',{class:'cm-choice-delay '+latencyClass(node?.measurement,false),'aria-live':'polite'},this.delayLabel(node?.measurement));
			this.groupBox.replaceChildren(...(s.groups.length ? s.groups.map(g => {
				if (g.type !== 'Selector') return this.field(g.name, E('div',{class:'cm-auto-choice'},[E('span',{},(g.now||'—')+' · 自动选择'),badgeFor(nodeFor(g.now))]));
				const choice = E('select', { 'aria-label': g.name }, g.all.map(n => {
					const node = nodeFor(n);
					return E('option', { value: n,style:'color:'+colorFor(node) }, n + (node ? ' · ' + this.delayLabel(node.measurement) : ''));
				}));
				// LuCI serializes false boolean attributes as present attributes.
				// Set the value explicitly so the last option cannot override .now.
				choice.value = g.now;
				const latency=badgeFor(nodeFor(choice.value));
				const updateChoice=()=>{const node=nodeFor(choice.value);choice.style.color=colorFor(node);latency.className='cm-choice-delay '+latencyClass(node?.measurement,false);latency.textContent=this.delayLabel(node?.measurement);};
				choice.addEventListener('change',updateChoice);updateChoice();
				return this.field(g.name, E('div', {}, [choice,latency,E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(() => select(g.name, choice.value), '节点已切换。') }, '切换')]), '内核当前选择：' + (g.now || '—') + '。切换影响新建连接；已有连接可能继续使用原节点。');
			}) : [E('p', {}, s.running ? '当前配置未提供代理组。' : '启动服务后显示配置中的代理组和节点。')]));
		}
		const nodeSignature = JSON.stringify([s.nodes,this.nodePage]);
		this.nodePageInfo.textContent='第 '+(this.nodePage+1)+' / '+Math.max(1,Math.ceil(s.nodes.length/20))+' 页 · 共 '+s.nodes.length+' 个节点';
		if (nodeSignature !== this.nodeSignature) {
			this.nodeSignature = nodeSignature;
			this.delayBox.replaceChildren(...(s.nodes.length ? s.nodes.slice(this.nodePage*20,this.nodePage*20+20).map(n => E('div', { class: 'cbi-value '+latencyClass(n.measurement,false) }, [
				E('div', { class: 'cbi-value-title' }, n.name),
				E('div', { class: 'cbi-value-field' }, [E('span', { 'data-node-delay': n.name }, this.delayLabel(n.measurement)), ' ',
					E('button', { type: 'button', class: 'cbi-button', 'aria-label': '测速 ' + n.name, click: () => this.run(() => this.testNodes([n.name]), '节点测速已完成。') }, '测速'),
					n.measurement ? E('div', { class: 'cbi-value-description' }, '测试时间：' + new Date(n.measurement.testedAt * 1000).toLocaleString()) : ''])
			])) : [E('p', {}, '启动服务后显示可测速的节点。')]));
		}
		this.updateButtons();
		this.paintWebsites(s);
	},
	render(data) {
		if (data.error) throw new Error(data.error);
		this.fieldIndex = 0; this.state = data;this.nodePage=0;
		this.sourceMode=E('select',{change:()=>{this.sourceDirty=true;}},[['all','全部内网IP接管'],['include','仅指定IP接管'],['exclude','指定IP不接管，其余接管'],['none','全部直连']].map(([value,label])=>E('option',{value},label)));
		this.sourceIPs=E('textarea',{rows:5,style:'width:100%;box-sizing:border-box',placeholder:'192.168.1.5\n192.168.2.0/24\n10.8.0.2',input:()=>{this.sourceDirty=true;}});
		this.sourceDevices=E('div',{class:'cm-source-devices',role:'group','aria-label':'可选LAN和OpenVPN设备'});this.sourceChoices=[];
		const loadDevices=()=>{const selected=new Set(this.sourceChoices.filter(c=>c.checked).map(c=>c.value));this.sourceChoices=[];const rows=(this.state.sourceDevices||[]).map(d=>{const box=E('input',{type:'checkbox',value:d.ip,checked:selected.has(d.ip)||null});this.sourceChoices.push(box);return E('label',{class:'cm-source-device'},[box,E('span',{},[E('strong',{},d.ip),E('small',{},d.name+' · '+d.interface+(d.online?' · 活跃':''))])]);});this.sourceDevices.replaceChildren(...(rows.length?rows:[E('p',{},'暂未发现IPv4设备，可手动输入。')]));};loadDevices();
		const addDevices=()=>{const values=new Set(this.sourceIPs.value.trim().split(/[\s,;]+/).filter(Boolean));for(const o of this.sourceChoices)if(o.checked)values.add(o.value);this.sourceIPs.value=[...values].join('\n');this.sourceDirty=true;};
		const sourceTools=E('div',{class:'button-row'},[E('button',{type:'button',class:'cbi-button',click:()=>{for(const o of this.sourceChoices)o.checked=true;addDevices();}},'加入全部设备IP'),E('button',{type:'button',class:'cbi-button',click:addDevices},'加入选中IP'),E('button',{type:'button',class:'cbi-button',click:async()=>{await this.refresh();loadDevices();}},'刷新设备')]);
		this.sourceApply=E('button',{type:'button',class:'cbi-button cbi-button-apply',click:()=>this.run(async()=>{const r=await applySourcePolicy({mode:this.sourceMode.value,addresses:this.sourceIPs.value.trim().split(/[\s,;]+/).filter(Boolean),revision:this.sourceRevision});if(r.ok){this.sourceDirty=false;this.sourceRevision=r.policy.revision;}return r;},'来源IP策略已应用，新建连接按新策略处理。')},'应用IP策略');
		const sourcePanel=E('div',{class:'cbi-section cm-section cm-source'},[E('h3',{},'内网IP代理控制'),E('p',{},'控制来源IP的透明接管，覆盖LAN及已开启接管的cvpns；应用显式连接手动代理端口不受此策略限制。接管后仍按Clash当前模式和规则选择出口，内网互访保持直连。'),this.field('代理策略',this.sourceMode),this.field('已发现设备',this.sourceDevices,'仅显示IPv4地址。直接勾选多个设备，再点击“加入选中IP”；无需按住Ctrl。未发现的地址可手动补充。'),sourceTools,this.field('指定IP / 网段',this.sourceIPs,'每行一条，支持IPv4、IPv6、CIDR和起止IP范围，最多256条。IP会随DHCP或VPN重连变化；IPv4与IPv6需要分别选择。'),E('div',{class:'button-row'},[this.sourceApply]),E('p',{class:'cm-policy-note'},'“仅指定IP接管”只接管列表地址；“指定IP不接管”让列表地址直连。cvpns仍受上方OpenVPN开关控制。保存不重启OpenVPN；已有连接请重新建立后验证。')]);
		this.sourcePanel=sourcePanel;
		this.nodePageInfo=E('span',{class:'cbi-value-description','aria-live':'polite'});
		this.nodePrev=E('button',{type:'button',class:'cbi-button',click:()=>{this.nodePage=Math.max(0,this.nodePage-1);this.paint(this.state);}},'上一页');
		this.nodeNext=E('button',{type:'button',class:'cbi-button',click:()=>{this.nodePage=Math.min(Math.max(0,Math.ceil(this.state.nodes.length/20)-1),this.nodePage+1);this.paint(this.state);}},'下一页');
		if(!document.getElementById('console-mihomo-layout'))document.head.append(E('link',{id:'console-mihomo-layout',rel:'stylesheet',href:L.resource('console/mihomo.css')}));
		this.vpnProxy = E('input',{type:'checkbox',change:()=>this.run(()=>vpnProxy(this.vpnProxy.checked),'OpenVPN代理开关已生效。')});
		this.badge = E('span', { class: 'badge', role: 'status' });
		this.endpoint = E('span'); this.scope = E('span', { role: 'status' }); this.groupBox = E('div',{class:'cm-grid cm-groups'}); this.delayBox = E('div',{class:'cm-grid cm-delays'}); this.policyHint = E('p');
		this.testProgress = E('p', { role: 'status', style: 'overflow-wrap:anywhere' });
		this.websiteBox = E('div',{class:'cm-grid cm-websites'}); this.websiteProgress = E('p', { role: 'status', 'aria-live': 'polite' });
		this.websiteButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(() => this.testWebsites(websites.map(s => s.id)), '全部网站测试已完成。') }, '测试全部网站');
		this.testButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(() => startDelayBatch(), '后台测速任务已启动，可离开页面。') }, '测速全部节点');
		this.feedback = E('p', { role: 'status', 'aria-live': 'polite' });
		this.mode = E('select', { change: () => { this.modeDirty = true; } }, [E('option', { value: 'rule' }, '规则模式'), E('option', { value: 'global' }, '全局代理'), E('option', { value: 'direct' }, '全局直连')]);
		this.modeButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(async () => { const r = await mode(this.mode.value); if (r.ok) this.modeDirty = false; return r; }, '运行模式已更新。') }, '应用模式');
		this.config = E('textarea', { rows: 12, spellcheck: 'false', placeholder: '粘贴完整的 Clash / Mihomo YAML 或 JSON 配置', style: 'width:100%;box-sizing:border-box' });
		this.link = E('input', { type: 'url', placeholder: 'https://example.com/subscribe?token=…', autocomplete: 'off', spellcheck: 'false', style: 'width:100%;box-sizing:border-box', input: () => this.updateButtons() });
		this.downloadVia = E('select', {}, [E('option', { value: 'router' }, '路由器下载'), E('option', { value: 'browser' }, '当前浏览器下载')]);
		this.linkButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(() => this.importLink(), '链接配置已下载、校验并保存，可启动服务。') }, '从链接导入');
		const file = E('input', { type: 'file', accept: '.yaml,.yml,.json', change: async ev => {
			const f = ev.target.files[0]; if (!f) return;
			if (f.size > 2 * 1024 * 1024) { ui.addNotification(null, E('p', {}, '配置文件最大支持 2 MB'), 'error'); return; }
			this.config.value = await f.text(); this.feedback.textContent = '已读取 ' + f.name + '，点击“校验并保存”导入。';
		} });
		this.saveButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(async () => {
			if (this.config.value.length > 2 * 1024 * 1024) throw new Error('配置文件最大支持 2 MB');
			const parsed = yaml.load(this.config.value);
			const r = await save(JSON.stringify(parsed), this.mode.value); if (r.ok) this.config.value = ''; return r;
		}, '配置已校验并保存，可启动服务。') }, '校验并保存');
		this.clearButton = E('button', { type: 'button', class: 'cbi-button cbi-button-remove', click: () => this.confirmClear() }, '清除配置');
		this.startButton = E('button', { type: 'button', class: 'cbi-button cbi-button-apply', click: () => this.run(() => action('start'), '已提交启动，服务状态将在数秒内更新。') }, '启动服务');
		this.stopButton = E('button', { type: 'button', class: 'cbi-button cbi-button-reset', click: () => this.run(() => action('stop'), '服务已停止，开机启动已关闭。') }, '停止服务');
		this.paint(data); poll.add(() => this.refresh(), 2);
		return E('div', { class: 'cbi-map cm-page' }, [E('h2', {}, 'Clash / Mihomo'),
			E('p', {}, '使用 Clash Verge Rev 同款 Mihomo 内核，在路由器上管理代理配置和节点。'),
			E('div', { class: 'cbi-section cm-section cm-status' }, [E('h3', {}, '服务状态'), this.field('内核状态', this.badge), this.field('内网自动代理', this.scope, '以本机为网关的 LAN 设备自动接入。规则模式按当前配置决定直连或代理；局域网互访和路由器管理保持直接访问。'), this.field('OpenVPN 客户端走 Clash',this.vpnProxy,'开启后cvpns上网流量和普通DNS查询交给Clash，遵循当前运行模式及规则；关闭后经WAN直连。切换会短暂重启Clash，不重启OpenVPN。Clash停止时恢复直连。'), this.field('手动代理地址', this.endpoint, '也可为单个应用手动填写此 HTTP / SOCKS5 代理地址。'),
				this.field('运行模式', this.mode), E('div', { class: 'button-row' }, [this.modeButton, ' ', this.startButton, ' ', this.stopButton]), this.feedback]),
			sourcePanel,
			E('div', { class: 'cbi-section cm-section' }, [E('h3', {}, '代理组与节点'), this.policyHint, this.groupBox]),
			E('div', { class: 'cbi-section cm-section' }, [E('h3', {}, '网站连通性测试'), E('p', {}, '通过当前 Clash 模式、规则和所选节点检测网站入口。延迟为连接建立到收到响应的首字节耗时，单站最多 8 秒。切换节点或模式后需重新测试。卡片延迟配色：低于100ms绿色，100–299ms黄色，300ms及以上或超时红色；访问状态另行标注。'), this.websiteButton, this.websiteProgress, this.websiteBox,
				E('p', {}, '点击站点名称可在浏览器打开。403 / 429 等会显示访问受限；入口可访问不代表登录、聊天或视频播放一定可用。')]),
			E('div', { class: 'cbi-section cm-section' }, [E('h3', {}, '节点延迟'), E('p', {}, '全部测速在后台以最多6路并发执行，离开页面仍会继续；进度和结果自动保存。通过各节点访问 https://www.gstatic.com/generate_204，单节点超时4秒。延迟是本次测试结果，不代表所有网站均可访问。卡片配色：低于100ms绿色，100–299ms黄色，300ms及以上或失败红色。'), this.testButton, this.testProgress, this.delayBox,E('div',{class:'button-row cm-pagination'},[this.nodePrev,this.nodePageInfo,this.nodeNext])]),
			E('div', { class: 'cbi-section cm-section cm-import' }, [E('h3', {}, '导入配置'),
				E('p', {}, '支持 Clash / Mihomo 配置链接、文件上传或粘贴完整配置。更新配置前请先停止服务。'),
				this.field('配置链接', this.link, '填写返回 Clash YAML / JSON 的订阅链接；不支持 ss:// 等单节点分享链接或 Base64 节点列表。链接保存成功后清空，不会持久保存。'),
				this.field('下载方式', this.downloadVia, '路由器无法访问外网时，可选择当前浏览器下载；需订阅服务器允许跨域访问，否则请在电脑下载后上传文件。配置引用的外部订阅和规则仍需路由器能够访问。'),
				E('div', { class: 'button-row' }, [this.linkButton]),
				this.field('选择文件', file), this.field('配置内容', this.config, '节点凭据保存在路由器专属文件中；保存后不回显。更新配置前请先停止服务。'),
				E('p', {}, '启动 Clash 后自动接管 LAN 上网流量及普通 DNS 查询，按所选模式和配置规则处理。默认规则模式；停止后恢复原有上网路径并关闭自启。'), E('div', { class: 'button-row' }, [this.saveButton, ' ', this.clearButton])])
		]);
	},
	handleSaveApply: null, handleSave: null, handleReset: null
});
