// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

const callState=rpc.declare({object:'console-security',method:'state',reject:true});
const callApply=rpc.declare({object:'console-security',method:'apply',params:['config'],reject:true});
const callConfirm=rpc.declare({object:'console-security',method:'confirm',reject:true});
const callRollback=rpc.declare({object:'console-security',method:'rollback',reject:true});
const callUpdate=rpc.declare({object:'console-security',method:'geo_update',reject:true});
const callHistory=rpc.declare({object:'console-security',method:'history',params:['device','seconds'],reject:true});
const callLogs=rpc.declare({object:'console-security',method:'logs',reject:true});
const callBlocked=rpc.declare({object:'console-security',method:'blocked',reject:true});
const callPreview=rpc.declare({object:'console-security',method:'preview',params:['config','ip','direction','protocol','port','device'],reject:true});
const DIR={input:'外网 → 路由器',incoming:'外网 → 内网服务',outgoing:'内网 → 外网'};
const PAGES={overview:['安全总览','查看设备流量、规则命中和采集状态。'],regions:['地区访问控制','按国家或地区管理新建连接。允许通过地区检查后，仍需通过原有防火墙。'],blocked:['阻止详情','按外网来源分组统计被地区规则阻止的访问，可查看最近阻止记录。'],devices:['设备流量','统计经过本机的内网上网流量；同交换机直连互访和下级 NAT 后的终端无法逐台完整观测。'],analysis:['流量分析','协议总量来自内核计数；目的 IP 和地区排行来自会话采样，不代表完整流量分布。'],logs:['拦截事件与数据库','查看数据库中的拦截事件、国家库版本及历史存储。']};
const ISO='AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW ZZ'.split(' ').filter(code=>code!=='ZZ');
const displayNames=typeof Intl.DisplayNames==='function'?new Intl.DisplayNames(['zh-CN'],{type:'region'}):null;
function region(code) { if(code==='LAN')return '内部网络'; if(!code || code==='ZZ')return '未知地区'; try{return displayNames?displayNames.of(code):code;}catch(e){return code;} }
function bytes(n) { if(n==null || !Number.isFinite(+n))return '—';const units=['B','KB','MB','GB','TB'];let v=+n,i=0;while(v>=1024&&i<4){v/=1024;i++;}return v.toFixed(i?2:0)+' '+units[i]; }
function rate(n) { return n==null?'采集中':bytes(n)+'/s'; }
function time(n) { return n?new Date(n*1000).toLocaleString('zh-CN'):'未采集'; }
function navTo(page){location.href=L.url('admin/security',page);}
function node(tag,cls,text) { return E(tag,{class:cls},text==null?'':String(text)); }
function text(el,value) { const next=String(value==null?'—':value);if(el.textContent!==next)el.textContent=next; }
function field(label,input,help) { const id=input.id || ('cs-'+Math.random().toString(36).slice(2));input.id=id;return E('div',{class:'cbi-value'},[E('label',{class:'cbi-value-title',for:id},label),E('div',{class:'cbi-value-field'},[input,help?node('div','cbi-value-description',help):''])]); }
function select(options,value) { return E('select',{},options.map(([key,label])=>E('option',{value:key,selected:String(key)===String(value)||null},label))); }
function panel(title,children) { return E('section',{class:'cbi-section cs-panel'},[E('h3',{},title),...children]); }
function table(headers) { const body=E('tbody');return {body,element:E('div',{class:'cs-scroll'},E('table',{class:'table'},[E('thead',{},E('tr',{class:'tr table-titles'},headers.map(h=>E('th',{class:'th'},h)))),body]))}; }
function row(cells) {return E('tr',{class:'tr'},cells.map(c=>E('td',{class:'td'},c)));}
function empty(body,columns,message) {body.replaceChildren(E('tr',{class:'tr'},E('td',{class:'td',colspan:columns},message)));}
function checked(result) {if(!result || result.error)throw new Error(result?.error || '服务无响应');return result;}
function svg(tag,attributes) {const el=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const [key,value]of Object.entries(attributes||{}))el.setAttribute(key,value);return el;}
let chartSequence = 0;
function chart(data) {
	if (!data.points?.length) return node('p','cs-note','所选时段尚无历史记录。后台每分钟保存一次，关闭页面后继续采集。');
	const points=data.points, end=Date.now()/1000, start=end-data.seconds, max=Math.max(1,...points.flatMap(p=>[p.upload,p.download]).filter(Number.isFinite));
	const graph=svg('svg',{viewBox:'0 0 800 190',role:'img','aria-label':'历史上传和下载流量曲线，按区间统计'});
	const defs=svg('defs'), id='cs-area-'+(++chartSequence), directions=[['upload','#328ac5','上传'],['download','#19a992','下载']];
	for(const [key,color] of directions){const gradient=svg('linearGradient',{id:id+'-'+key,x1:'0',y1:'0',x2:'0',y2:'1'});gradient.append(svg('stop',{offset:'0%','stop-color':color,'stop-opacity':'.24'}),svg('stop',{offset:'100%','stop-color':color,'stop-opacity':'.015'}));defs.append(gradient);}graph.append(defs);
	for(const y of [15,63,111,160])graph.append(svg('path',{d:'M45 '+y+'H780',stroke:'#e3e9ee',fill:'none'}));
	const lines=[];
	for(const [key,color,label] of directions){
		const segments=[];let segment=[];
		for(const p of points){if(!Number.isFinite(p[key])||(segment.length && p.time-segment[segment.length-1].time>data.bucket*1.5)){if(segment.length)segments.push(segment);segment=[];}if(Number.isFinite(p[key]))segment.push(p);}if(segment.length)segments.push(segment);
		const px=p=>Math.max(45,Math.min(780,45+(p.time-start)/data.seconds*735)),py=p=>160-(p[key]/max)*145;
		for(const part of segments){let d='M'+px(part[0]).toFixed(1)+' '+py(part[0]).toFixed(1);for(let i=1;i<part.length;i++){const m=((px(part[i-1])+px(part[i]))/2).toFixed(1);d+='C'+m+' '+py(part[i-1]).toFixed(1)+' '+m+' '+py(part[i]).toFixed(1)+' '+px(part[i]).toFixed(1)+' '+py(part[i]).toFixed(1);}
			if(part.length>1){graph.append(svg('path',{class:'cs-chart-area',d:d+'L'+px(part[part.length-1]).toFixed(1)+' 160L'+px(part[0]).toFixed(1)+' 160Z',fill:'url(#'+id+'-'+key+')',stroke:'none'}));const line=svg('path',{d,stroke:color,fill:'none','stroke-width':2.3,'stroke-linecap':'round','stroke-dasharray':key==='upload'?'7 3':'none'});lines.push(line);}
			for(const p of part){const dot=svg('circle',{cx:px(p),cy:py(p),r:part.length===1?3:2,fill:color});const detail=svg('title');detail.textContent=label+' '+time(p.time)+' · '+bytes(p[key]);dot.append(detail);lines.push(dot);}
		}
	}
	graph.append(...lines);
	for(const [x,y,value] of [[46,184,new Date(start*1000).toLocaleString('zh-CN')],[560,184,new Date(end*1000).toLocaleString('zh-CN')],[48,20,bytes(max)]]){const t=svg('text',{x,y,fill:'#64798a','font-size':11});t.textContent=value;graph.append(t);}
	return E('div',{class:'cs-chart'},[E('div',{class:'cs-chart-legend'},[node('span','cs-chart-up','上传'),node('span','cs-chart-down','下载')]),graph,node('p','cs-note','按时间区间显示已记录流量；首尾区间可能不足完整周期。空档表示无记录，不补成 0。')]);
}

return view.extend({
	load(){return callState().then(checked);},
	button(label,task,primary){return E('button',{type:'button',class:'cbi-button'+(primary?' cbi-button-apply':''),click:event=>this.action(event.currentTarget,task)},label);},
	async action(button,task){if(button.disabled)return;const notice=node('span','', ' · 处理中…');button.disabled=true;button.setAttribute('aria-busy','true');button.append(notice);try{await task();}catch(e){ui.addNotification(null,E('p',{},e.message||'操作失败'),'error');}finally{notice.remove();button.disabled=button===this.applyButton?(!this.dirty||!L.hasViewPermission()):false;button.removeAttribute('aria-busy');}},
	async refresh(force){if((this.loading&&!force) || document.hidden)return;const seq=(this.refreshSequence||0)+1;this.refreshSequence=seq;this.loading=true;try{const data=checked(await callState());if(seq===this.refreshSequence){this.data=data;this.update();}}catch(e){if(seq===this.refreshSequence){text(this.warning,'刷新失败，保留上次数据：'+e.message);this.warning.hidden=false;}}finally{if(seq===this.refreshSequence)this.loading=false;}},
	markDirty(){this.dirty=true;text(this.draftNote,'有未应用的修改');this.applyButton.disabled=!L.hasViewPermission();},
	async apply(){this.refreshSequence=(this.refreshSequence||0)+1;this.loading=false;const result=checked(await callApply(this.draft));this.dirty=false;await this.refresh(true);ui.addNotification(null,E('p',{},'规则已应用，请在120秒内确认；超时自动回滚。'),'info');},
	async history(device,seconds,target){const seq=(target.csRequest||0)+1;target.csRequest=seq;target.setAttribute('aria-busy','true');try{const result=checked(await callHistory(device,+seconds));if(target.csRequest===seq)target.replaceChildren(chart(result));}catch(e){if(target.csRequest===seq)target.replaceChildren(node('p','alert-message error',e.message));}finally{if(target.csRequest===seq)target.removeAttribute('aria-busy');}},
	render(data){
		this.data=checked(data);this.page=(L.env.requestpath||[])[2] || 'overview';if(!PAGES[this.page])this.page='overview';this.draft=JSON.parse(JSON.stringify(data.config));this.draft.revision=this.draft.revision||0;this.dirty=false;this.devicePage=0;
		if(!document.getElementById('console-security-css'))document.head.append(E('link',{id:'console-security-css',rel:'stylesheet',href:L.resource('console/security.css')}));
		this.warning=node('div','alert-message warning','');this.pending=E('div',{class:'alert-message warning',hidden:true});this.updated=node('span','cs-note','');
		this.root=E('div',{class:'cbi-map cs-security'},[E('div',{class:'cs-heading'},[E('div',{},[E('h2',{},PAGES[this.page][0]),node('p','cs-note',PAGES[this.page][1])]),this.button('立即刷新',()=>this.refresh())]),this.pending,this.warning]);
		if(this.page==='overview')this.buildOverview();
		if(this.page==='regions')this.buildRegions();
		if(this.page==='blocked')this.buildBlocked();
		if(this.page==='devices')this.buildDevices();
		if(this.page==='analysis')this.buildAnalysis();
		if(this.page==='logs')this.buildLogs();
		this.root.append(E('div',{class:'cs-footer'},[this.updated,E('span',{},['IP 归属数据：',E('a',{href:'https://db-ip.com',target:'_blank',rel:'noreferrer'},'DB-IP Country Lite'),' · CC BY 4.0'])]));
		this.update();
		this.pollFn=()=>{if(!this.root.isConnected){if(this.mounted)poll.remove(this.pollFn);return;}this.mounted=true;return this.refresh();};poll.add(this.pollFn,2);
		return this.root;
	},
	buildOverview(){
		this.metrics={};const cards=[];for(const [key,label]of [['upload','实时上传'],['download','实时下载'],['online','有流量设备'],['blocked','规则阻止包数']]){this.metrics[key]=node('strong','','—');const card=E('div',{class:'cs-metric'+(key==='blocked'?' cs-metric-link':''),role:key==='blocked'?'link':null,tabindex:key==='blocked'?0:null,title:key==='blocked'?'查看阻止详情':null},[node('span','',label),this.metrics[key]]);if(key==='blocked'){card.addEventListener('click',()=>navTo('blocked'));card.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();navTo('blocked');}});}cards.push(card);}this.root.append(E('div',{class:'cs-metrics'},cards));
		this.health=E('div');this.topTable=table(['设备','IP 地址','上传','下载','今日流量']);this.root.append(panel('运行状态',[this.health]),panel('实时设备排行',[this.topTable.element]));
		this.historyRange=3600;this.lastHistoryRefresh=Date.now();this.chartContainer=E('div');const range=select([[3600,'近1小时'],[86400,'近24小时'],[604800,'近7天']],3600);range.addEventListener('change',()=>{this.historyRange=+range.value;this.lastHistoryRefresh=Date.now();this.history('all',range.value,this.chartContainer);});this.root.append(panel('上网流量历史',[range,this.chartContainer]));this.history('all',3600,this.chartContainer);
	},
	buildRegions(){
		this.applyButton=this.button('应用变更',()=>this.apply(),true);this.applyButton.disabled=true;this.draftNote=node('span','cs-note','规则已同步');
		this.ruleTable=table(['顺序','名称 / 方向','动作 / 范围','地区','状态','操作']);
		this.root.append(panel('地区规则',[E('div',{class:'cs-toolbar'},[this.button('新增规则',()=>this.editRule(),true),this.applyButton,this.button('放弃草稿',()=>{this.draft=JSON.parse(JSON.stringify(this.data.config));this.dirty=false;this.allowIPs.value=(this.draft.allowIPs||[]).join('\n');this.blockIPs.value=(this.draft.blockIPs||[]).join('\n');this.renderRules();text(this.draftNote,'规则已同步');this.applyButton.disabled=true;}),this.draftNote]),node('p','cs-note','规则从上到下匹配。允许规则是限定范围的白名单，不匹配的地区会被阻止；未知地区也不在白名单中。规则作用于新建连接，已建立会话保持；IPv6邻居发现与错误控制报文保留。'),this.ruleTable.element]));
		this.allowIPs=E('textarea',{rows:3,placeholder:'每行一个 IP 或 CIDR'});this.blockIPs=E('textarea',{rows:3,placeholder:'每行一个 IP 或 CIDR'});this.allowIPs.value=(this.draft.allowIPs||[]).join('\n');this.blockIPs.value=(this.draft.blockIPs||[]).join('\n');for(const [el,key]of [[this.allowIPs,'allowIPs'],[this.blockIPs,'blockIPs']])el.addEventListener('input',()=>{this.draft[key]=el.value.split(/[\s,]+/).filter(Boolean);this.markDirty();});
		this.root.append(panel('IP 例外',[field('优先允许',this.allowIPs,'填写远端IP：入站来源或出站目标。先匹配允许例外，再匹配阻止例外及地区规则；仍受原有防火墙约束。'),field('明确阻止',this.blockIPs)]));
		this.previewResult=E('div');const ip=E('input',{type:'text',placeholder:'例如 8.8.8.8 或 2001:4860:4860::8888'}),direction=select(Object.entries(DIR),'input'),protocol=select([['tcp','TCP'],['udp','UDP']],'tcp'),port=E('input',{type:'number',min:1,max:65535,value:443}),device=select([['all','全部设备'],...(this.data.snapshot.devices||[]).filter(d=>d.mac).map(d=>[d.mac,d.name||d.mac])],'all');
		this.root.append(panel('IP 归属与规则命中预览',[field('远端 IP',ip),field('连接方向',direction),field('协议',protocol),field('目标端口',port),field('内网设备',device),this.button('预览草稿规则',async()=>{const r=checked(await callPreview(this.draft,ip.value.trim(),direction.value,protocol.value,+port.value,device.value));this.previewResult.replaceChildren(node('p',r.action==='block'?'alert-message warning':'alert-message success',region(r.country)+' · '+(r.action==='block'?'地区层阻止':'地区层通过')+' · '+r.reason));}),this.previewResult]));this.renderRules();
	},
	renderRules(){
		if(!this.ruleTable)return;const rules=this.draft.rules||[];
		if(!rules.length){empty(this.ruleTable.body,6,'尚无地区规则。新增后先预览，再应用。');return;}
		this.ruleTable.body.replaceChildren(...rules.map((r,index)=>{
			const enabled=E('input',{type:'checkbox','aria-label':'启用 '+r.name,change:event=>{r.enabled=event.target.checked;this.markDirty();}});enabled.checked=!!r.enabled;
			const counter=E('a',{href:L.url('admin/security/blocked'),'data-rule-count':r.id,class:'cs-note cs-blocked-link',title:'查看阻止详情'},'');
			return row([String(index+1),E('div',{},[node('strong','',r.name),node('div','cs-note',DIR[r.direction])]),(r.action==='allow'?'仅允许':'阻止')+' · '+r.protocol.toUpperCase()+' '+(r.ports||'全部端口')+(r.device==='all'?'':' · '+r.device),E('span',{title:r.countries.map(region).join('、')},r.countries.slice(0,3).map(region).join('、')+(r.countries.length>3?' 等'+r.countries.length+'地区':'')),E('div',{},[enabled,counter]),E('div',{class:'cs-actions'},[this.button('编辑',()=>this.editRule(r)),this.button('复制',()=>this.copyRule(r)),this.button('上移',()=>{if(index){[rules[index-1],rules[index]]=[rules[index],rules[index-1]];this.markDirty();this.renderRules();}}),this.button('移除',()=>{rules.splice(index,1);this.markDirty();this.renderRules();})])]);
		}));
	},
	copyRule(original){
		const copy=JSON.parse(JSON.stringify(original));
		copy.id=Date.now().toString(36)+Math.random().toString(36).slice(2,5);
		copy.name=(copy.name+' 副本').slice(0,80);
		copy.enabled=false;
		this.draft.rules.push(copy);
		this.markDirty();
		this.renderRules();
		ui.addNotification(null,E('p',{},'已复制规则「'+original.name+'」到草稿，默认停用，请编辑后应用。'),'info');
	},
	editRule(original){
		const r=original||{id:Date.now().toString(36)+Math.random().toString(36).slice(2,5),name:'',enabled:false,direction:'input',action:'block',protocol:'tcp',ports:'',device:'all',countries:[]};
		const name=E('input',{type:'text',value:r.name,maxlength:80}),direction=select(Object.entries(DIR),r.direction),action=select([['block','阻止选中地区'],['allow','只允许选中地区（其他地区阻止）']],r.action),protocol=select([['all','全部协议'],['tcp','TCP'],['udp','UDP']],r.protocol),ports=E('input',{type:'text',value:r.ports,placeholder:'全部端口留空；例如80,443,1000-2000'}),device=select([['all','全部设备'],...(this.data.snapshot.devices||[]).filter(d=>d.mac).map(d=>[d.mac,d.name?d.name+' · '+d.mac:d.mac])],r.device),enabled=E('input',{type:'checkbox'}),search=E('input',{type:'search',placeholder:'搜索地区名称或代码','aria-label':'搜索地区'});enabled.checked=!!r.enabled;
		const countryCodes=Array.from(new Set([...ISO,...(this.data.countries||[]).map(c=>c.cc)])).filter(code=>code!=='ZZ'),selectedCountries=new Set(r.countries||[]),countryCount=node('span','cs-note',''),countryList=E('div',{class:'cs-region-country-list',role:'group','aria-label':'国家和地区'}),countryEmpty=node('p','cs-note cs-region-country-empty','没有匹配的国家或地区。'),countryRows=[];countryCount.setAttribute('role','status');countryCount.setAttribute('aria-live','polite');countryEmpty.hidden=true;
		const updateCountryCount=()=>text(countryCount,'已选 '+selectedCountries.size+' 个地区');
		for(const code of countryCodes){
			const checkbox=E('input',{type:'checkbox','aria-label':region(code)+' ('+code+')'});checkbox.checked=selectedCountries.has(code);checkbox.disabled=!!this.data.geo&&!(this.data.countries||[]).some(c=>c.cc===code);
			const label=E('label',{class:'cs-region-country-option'},[checkbox,E('span',{},region(code)+' ('+code+')')]);
			checkbox.addEventListener('change',()=>{if(checkbox.checked)selectedCountries.add(code);else selectedCountries.delete(code);updateCountryCount();});
			countryRows.push({code,checkbox,label});countryList.append(label);
		}
		const filterCountries=()=>{const query=search.value.trim().toLocaleLowerCase();let matches=0;for(const item of countryRows){item.label.hidden=!item.label.textContent.toLocaleLowerCase().includes(query);if(!item.label.hidden)matches++;}countryEmpty.hidden=matches>0;};
		search.addEventListener('input',filterCountries);
		const selectFiltered=E('button',{type:'button',class:'cbi-button',click:()=>{for(const item of countryRows)if(!item.label.hidden&&!item.checkbox.disabled){item.checkbox.checked=true;selectedCountries.add(item.code);}updateCountryCount();}},'选中当前筛选');
		const clearCountries=E('button',{type:'button',class:'cbi-button',click:()=>{selectedCountries.clear();for(const item of countryRows)item.checkbox.checked=false;updateCountryCount();}},'清空已选');
		const countryActions=E('div',{class:'cs-region-country-actions'},[selectFiltered,clearCountries,countryCount]),countryPicker=E('div',{class:'cs-region-country-picker'},[E('div',{class:'cs-region-country-toolbar'},[search,countryActions]),countryList,countryEmpty]);updateCountryCount();
		const formError=E('div'),form=E('div',{class:'cs-region-rule-form'},[formError,field('名称',name),field('方向',direction),field('动作',action),field('协议',protocol),field('目标端口',ports,'外网访问内网服务时，填写端口映射后的内部目标端口。'),field('内网设备',device,'访问路由器时应选全部设备；设备限定依赖已识别的IP/MAC关系。'),field('国家 / 地区',countryPicker,'勾选即可多选。允许规则会阻止未选地区和未知地区。'),field('启用规则',enabled,'新规则默认关闭，保存到草稿后再应用。')]);
		ui.showModal(original?'编辑地区规则':'新增地区规则',[form,E('div',{class:'button-row'},[this.button('取消',()=>ui.hideModal()),this.button('保存到草稿',()=>{const codes=countryCodes.filter(code=>selectedCountries.has(code));if(!name.value.trim()||!codes.length){formError.replaceChildren(node('p','alert-message error','请填写名称并选择地区。'));return;}const next={id:r.id,name:name.value.trim(),direction:direction.value,action:action.value,protocol:protocol.value,ports:ports.value.trim(),device:device.value,enabled:enabled.checked,countries:codes};if(original)this.draft.rules[this.draft.rules.indexOf(original)]=next;else this.draft.rules.push(next);this.markDirty();this.renderRules();ui.hideModal();},true)])]);
		document.querySelector('#modal_overlay > .modal')?.classList.add('cs-region-rule-modal');
	},
	buildBlocked(){
		this.blockedTable=table(['外网来源','地区','访问次数','首次访问','最近访问','访问内网地址','命中规则']);
		this.recentTable=table(['访问时间','外网来源','访问内网地址','端口 / 协议','命中规则']);
		this.blockedNote=node('p','cs-note','正在读取阻止记录…');
		this.root.append(panel('最近阻止记录',[this.blockedNote,this.recentTable.element]));
		this.root.append(panel('按外网来源分组统计',[this.blockedTable.element,node('p','cs-note','基于数据库中的拦截事件统计，每来源每秒最多记录 2 条，因此次数为下限；最多统计最近 500 条记录。内网地址列出 IP 与 MAC。')]));
		this.loadBlocked();
	},
	async loadBlocked(){
		try{
			const r=checked(await callBlocked()),groups=r.groups||[];
			text(this.blockedNote,'共 '+r.total+' 条阻止记录 · '+groups.length+' 个来源 · 规则累计阻止 '+(r.packets||0)+' 个包（内核日志限速，记录数为下限）');
			if(!groups.length){empty(this.blockedTable.body,7,'暂无阻止记录。地区规则命中后会写入数据库。');empty(this.recentTable.body,5,'');return;}
			this.blockedTable.body.replaceChildren(...groups.map(g=>row([
				E('div',{},[node('strong','',g.src)]),
				g.internal?'内部网络':region(g.country),
				node('strong','',''+g.count),
				g.first?new Date(g.first*1000).toLocaleString('zh-CN'):'—',
				g.last?new Date(g.last*1000).toLocaleString('zh-CN'):'—',
				E('div',{},(g.targets||[]).map(t=>node('div','cs-note',(t.ip||'—')+(t.mac?' · '+t.mac:'')+(t.count?'（'+t.count+'次）':'')))),
				(g.rules||[]).join('、')||'—'
			])));
			this.recentTable.body.replaceChildren(...(r.recent||[]).map(e=>row([
				e.stamp?new Date(e.stamp*1000).toLocaleString('zh-CN'):(e.when||'—'),
				e.src,
				e.dst,
				(e.dport?e.dport+' / ':e.proto.toUpperCase()+' / ')+(e.dport?e.proto.toUpperCase():'—'),
				this.data.config.rules.find(v=>v.id===e.rule)?.name||e.rule
			])));
		}catch(e){
			this.blockedNote.textContent='';
			this.blockedTable.body.replaceChildren(E('tr',{class:'tr'},E('td',{class:'td',colspan:7},node('p','alert-message error',e.message||'读取失败'))));
		}
	},
	buildDevices(){
		this.search=E('input',{type:'search',placeholder:'搜索名称、MAC 或 IP','aria-label':'搜索设备',input:()=>{this.devicePage=0;this.renderDevices();}});this.deviceTable=table(['设备 / MAC','IP 地址','状态','上传','下载','今日上 / 下','累计上 / 下','外网连接','操作']);this.pageInfo=node('span','cs-note','');this.root.append(panel('全部设备',[E('div',{class:'cs-toolbar'},[this.search,this.button('上一页',()=>{this.devicePage=Math.max(0,this.devicePage-1);this.renderDevices();}),this.pageInfo,this.button('下一页',()=>{this.devicePage++;this.renderDevices();})]),this.deviceTable.element,node('p','cs-note','有流量表示最近120秒内观察到上网转发流量；外网连接数为最多30秒前的转发会话样本。今日按路由器时区统计。累计自本功能启用后开始，不补录过去流量。')]));
	},
	renderDevices(){
		if(!this.deviceTable || this.deviceTable.body.contains(document.activeElement))return;
		const q=(this.search.value||'').trim().toLowerCase(),all=(this.data.snapshot.devices||[]).filter(d=>[d.name,d.mac,...d.ips].join(' ').toLowerCase().includes(q)),pages=Math.max(1,Math.ceil(all.length/20));this.devicePage=Math.max(0,Math.min(this.devicePage,pages-1));text(this.pageInfo,(this.devicePage+1)+' / '+pages+' 页 · '+all.length+' 台');const devices=all.slice(this.devicePage*20,this.devicePage*20+20);
		if(!devices.length){empty(this.deviceTable.body,9,'暂无可识别的终端，等待经过路由器的流量。');return;}
		this.deviceTable.body.replaceChildren(...devices.map(d=>row([E('div',{},[node('strong','',d.name||'未命名设备'),node('div','cs-note',d.mac||'未识别MAC')]),d.ips.join('\n'),d.online?'有流量':'未观测到流量',rate(d.upload),rate(d.download),bytes(d.today.up)+' / '+bytes(d.today.down),bytes(d.total.up)+' / '+bytes(d.total.down),String(d.connections||0),this.button('详情',()=>this.deviceDetail(d))])));
	},
	deviceDetail(device){const container=E('div'),range=select([[3600,'近1小时'],[86400,'近24小时'],[604800,'近7天']],3600);range.addEventListener('change',()=>this.history(device.id,range.value,container));ui.showModal(device.name||device.mac||device.id,[node('p','cs-note',(device.mac||'未识别MAC')+' · '+device.ips.join('、')),node('p','', '累计上传 '+bytes(device.total.up)+' · 累计下载 '+bytes(device.total.down)),range,container,E('div',{class:'button-row'},this.button('关闭',()=>ui.hideModal()))]);this.history(device.id,3600,container);},
	buildAnalysis(){
		this.connectionDirection=select([['all','全部方向'],['outgoing','内网发起 → 外网'],['incoming','外网发起 → 内网'],['router','访问路由器本机']],'all');this.connectionDirection.setAttribute('aria-label','连接方向筛选');this.connectionDirection.addEventListener('change',()=>this.renderConnections());
		this.connectionIP=E('input',{type:'search',placeholder:'搜索本地或远端 IP','aria-label':'连接 IP 筛选',input:()=>this.renderConnections()});this.connectionCount=node('span','cs-note','');
		this.connectionToolbar=E('div',{class:'cs-toolbar'},[E('label',{},['连接方向 ',this.connectionDirection]),E('label',{},['IP 地址 ',this.connectionIP]),this.button('清空筛选',()=>{this.connectionDirection.value='all';this.connectionIP.value='';this.renderConnections();}),this.connectionCount]);
		this.protocols=E('div');this.destTable=table(['设备','连接方向','本地 IP','远端 IP','目标端口 / 协议','地区','观测字节增量','连接']);this.regionTable=table(['地区','热门连接采样字节']);this.analysisNote=node('p','cs-note','');this.alerts=E('div');this.root.append(panel('今日协议流量',[this.protocols,node('p','cs-note','协议总量按 LAN 设备的上网转发流量统计；访问路由器本机的会话只列在下方热门连接中。')]),panel('热门连接（会话采样）',[this.analysisNote,this.connectionToolbar,this.destTable.element,node('p','cs-note','筛选当前最多30条热门会话采样，支持部分 IP 匹配；下方地区分布保留全部采样。')]),panel('热门连接的地区分布（采样）',[this.regionTable.element]),panel('流量提醒',[this.alerts,node('p','cs-note','提醒基于流量和连接数阈值，不等同于攻击判定。')]));},
	renderConnections(){
		const all=this.data?.snapshot?.analysis?.destinations||[],direction=this.connectionDirection.value,q=this.connectionIP.value.trim().toLowerCase(),devices=this.data?.snapshot?.devices||[];
		const items=all.filter(item=>(direction==='all'||item.direction===direction)&&(!q||[item.localIP,item.ip].some(ip=>String(ip||'').toLowerCase().includes(q))));
		text(this.connectionCount,'显示 '+items.length+' / '+all.length+' 条采样');
		if(items.length)this.destTable.body.replaceChildren(...items.map(item=>row([item.device==='router'?'路由器本机':devices.find(v=>v.id===item.device)?.name||item.device,item.direction==='outgoing'?'内网发起 → 外网':item.direction==='incoming'?'外网发起 → 内网':item.direction==='router'?'其他设备 → 路由器':'等待采样',item.localIP||'—',item.ip,(item.port||'—')+' / '+item.protocol,region(item.country),bytes(item.bytes),String(item.connections)])));
		else empty(this.destTable.body,8,all.length?'没有符合筛选条件的会话。':'尚无可分析的会话样本。');
	},

	buildLogs(){
		this.database=E('div');this.logBody=node('pre','cs-log','读取中…');this.root.append(panel('地区数据库',[this.database,this.button('更新国家库',async()=>{checked(await callUpdate());await this.refresh();},true),node('p','cs-note','每月自动检查新版本；失败保留现有库。免费库存在覆盖与定位误差，代理、VPN和CDN出口会影响判断。')]),panel('历史存储',[node('p','cs-note','7天分层历史：近24小时按分钟保存，更早按5分钟聚合；查询最多600个点。历史库预算100MiB，空间紧张时优先清理旧数据。'),this.storageInfo=E('div')]),panel('拦截事件',[this.button('刷新记录',()=>this.loadLogs()),node('p','cs-note','拦截事件已持久化到数据库，最多展示最近 200 条；完整命中次数请看规则计数。'),this.logBody]));this.loadLogs();
	},
	async loadLogs(){const r=checked(await callLogs());text(this.logBody,r.lines.filter(Boolean).join('\n')||'暂无拦截事件。');},
	update(){
		const d=this.data,s=d.snapshot||{},warnings=[...(s.warnings||[]),...(d.stale?['采集数据已过期或服务尚未就绪']:[]),...(s.error?[s.error]:[])];this.warning.hidden=!warnings.length;text(this.warning,warnings.join('；'));text(this.updated,'采集时间：'+time(s.time)+' · 每2秒刷新');
		if(d.pending){this.pending.hidden=false;this.pending.replaceChildren(node('p','', '规则尚未确认，'+d.pending.secondsLeft+'秒后自动回滚。请确认当前访问正常。'),this.button('确认生效',async()=>{checked(await callConfirm());await this.refresh();},true),this.button('立即回滚',async()=>{checked(await callRollback());this.dirty=false;await this.refresh();}));}else this.pending.hidden=true;
		if(!this.dirty&&this.page==='regions'&&JSON.stringify(this.draft)!==JSON.stringify(d.config)){this.draft=JSON.parse(JSON.stringify(d.config));this.draft.revision=this.draft.revision||0;this.renderRules();this.allowIPs.value=(this.draft.allowIPs||[]).join('\n');this.blockIPs.value=(this.draft.blockIPs||[]).join('\n');this.applyButton.disabled=true;text(this.draftNote,'规则已同步');}
		if(this.chartContainer && Date.now()-this.lastHistoryRefresh>=60000){this.lastHistoryRefresh=Date.now();this.history('all',this.historyRange,this.chartContainer);}
		for(const el of this.root.querySelectorAll('[data-rule-count]')){const counter=(s.ruleCounters||[]).find(c=>c.name==='b'+el.dataset.ruleCount);el.textContent=' 阻止 '+((counter?.packets||0))+' 包 ›';}
		const devices=s.devices||[],blocked=(s.ruleCounters||[]).filter(c=>c.name.startsWith('b')).reduce((n,c)=>n+(c.packets||0),0);
		if(this.metrics){text(this.metrics.upload,rate(s.upload));text(this.metrics.download,rate(s.download));text(this.metrics.online,devices.filter(v=>v.online).length+' 台');text(this.metrics.blocked,blocked);this.health.replaceChildren(node('p','', '采集模式：'+(s.accurate?'准确计数（未启用流量卸载）':'请检查采集警告')),node('p','', '地区规则：'+d.config.rules.filter(r=>r.enabled).length+' 条启用 · 国家库：'+(d.geo?.version||'尚未下载')),node('p','cs-note','计数包含通过本机转发并获原有防火墙允许的上网流量。规则阻止数统计新建连接数据包，自规则加载后开始并持久保存。'));if(devices.length)this.topTable.body.replaceChildren(...devices.slice(0,10).map(v=>row([v.name||v.mac||v.id,(v.ips||[]).join('\n')||'—',rate(v.upload),rate(v.download),bytes(v.today.up+v.today.down)])));else empty(this.topTable.body,5,'等待设备流量。');}
		this.renderDevices();
		if(this.protocols){const totals={tcp:0,udp:0,other:0};for(const v of devices)for(const p of Object.keys(totals))totals[p]+=(v.today[p+'up']||0)+(v.today[p+'down']||0);this.protocols.replaceChildren(...Object.entries(totals).map(([p,n])=>E('div',{class:'cs-protocol'},[node('strong','',p.toUpperCase()),node('span','',bytes(n))])));const a=s.analysis||{},items=a.destinations||[];text(this.analysisNote,'采样时间：'+time(a.time)+' · '+(!a.available?'尚无有效样本':a.limited?'已限量采样':'已读取当前会话')+(a.message?' · '+a.message:'')+'；方向按连接最初发起方划分，回复流量沿用原方向；包含访问路由器本机的会话。172.16.10.0–172.16.50.255 按自定义内部网段归类。会话约每30秒采样一次；采到连接尝试不代表服务已接受，短连接可能漏采。字节不等于完整设备流量。');const byRegion={};for(const item of items)byRegion[item.country||'ZZ']=(byRegion[item.country||'ZZ']||0)+item.bytes;this.renderConnections();if(Object.keys(byRegion).length)this.regionTable.body.replaceChildren(...Object.entries(byRegion).sort((a,b)=>b[1]-a[1]).map(([cc,n])=>row([region(cc),bytes(n)])));else empty(this.regionTable.body,2,'暂无地区样本。');const alerts=devices.flatMap(v=>(v.alerts||[]).map(a=>(v.name||v.mac||v.id)+'：'+a));this.alerts.replaceChildren(...(alerts.length?alerts.map(a=>node('p','alert-message warning',a)):[node('p','cs-note','未发现超过提醒阈值的设备。')]));}
		if(this.database){const g=d.geo,j=d.geoJob||{};this.database.replaceChildren(node('p','',g?'版本 '+g.version+' · '+g.records+' 个IPv4/IPv6网段 · '+bytes(g.bytes):'尚未安装国家库，不能启用地区规则。'),node('p','cs-note','更新于 '+time(g?.updated)),node('p',j.ok===false?'alert-message warning':'cs-note',(j.running?'更新中：':'')+(j.message||'尚无更新任务')+(j.running&&j.records?' · '+j.records+'条':'')));text(this.storageInfo,'历史库 '+bytes(d.storage.historyBytes)+' · 根盘可用 '+bytes(d.storage.freeBytes));}
	},
	handleSaveApply:null,handleSave:null,handleReset:null
});
