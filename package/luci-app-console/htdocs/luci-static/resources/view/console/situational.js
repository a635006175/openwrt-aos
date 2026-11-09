// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require console.world-map as worldPaths';

const callOverview=rpc.declare({object:'console-situational',method:'overview',reject:true});
const callSet=rpc.declare({object:'console-situational',method:'set',params:['options'],reject:true});
const callUnban=rpc.declare({object:'console-situational',method:'unban',params:['ip'],reject:true});
const callBan=rpc.declare({object:'console-situational',method:'ban',params:['ip','hours'],reject:true});
const callRefresh=rpc.declare({object:'console-situational',method:'refresh',reject:true});

const displayNames=typeof Intl.DisplayNames==='function'?new Intl.DisplayNames(['zh-CN'],{type:'region'}):null;
function region(code){if(code==='LAN')return '内部网络';if(!code||code==='ZZ')return '未知地区';try{return displayNames?displayNames.of(code):code;}catch(e){return code;}}
function node(tag,cls,text){return E(tag,{class:cls},text==null?'':String(text));}
function text(el,value){const next=String(value==null?'—':value);if(el.textContent!==next)el.textContent=next;}
function panel(title,children){return E('section',{class:'cbi-section cs-panel'},[E('h3',{},title),...children]);}
function table(headers){const body=E('tbody');return {body,element:E('div',{class:'cs-scroll'},E('table',{class:'table'},[E('thead',{},E('tr',{class:'tr table-titles'},headers.map(h=>E('th',{class:'th'},h)))),body]))};}
function row(cells){return E('tr',{class:'tr'},cells.map(c=>E('td',{class:'td'},c)));}
function empty(body,columns,message){body.replaceChildren(E('tr',{class:'tr'},E('td',{class:'td',colspan:columns},message)));}
function checked(result){if(!result||result.error)throw new Error(result?.error||'服务无响应');return result;}
function time(n){return n?new Date(n*1000).toLocaleString('zh-CN'):'—';}
/* 三列表格用的短时间：MM-DD HH:mm */
function shortTime(n){if(!n)return '—';const d=new Date(n*1000),p=v=>String(v).padStart(2,'0');return (d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());}
function svg(tag,attributes){const el=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const [key,value]of Object.entries(attributes||{}))el.setAttribute(key,value);return el;}

/* 世界地图：equirectangular 投影，经度 -180..180 → x 0..1000，纬度 85..-60 → y 0..420 */
const MAP_W=1000,MAP_H=420;
function project(lon,lat){return [ (lon+180)/360*MAP_W, (85-lat)/145*MAP_H ];}
function buildMap(){
	const wrap=E('div',{class:'sa-map'});
	const box=E('div',{class:'sa-map-box'});
	const graph=svg('svg',{viewBox:'0 0 '+MAP_W+' '+MAP_H,role:'img','aria-label':'攻击来源世界地图'});
	// 经纬网格
	for(let lon=-180;lon<=180;lon+=30){const [x]=project(lon,0);graph.append(svg('line',{x1:x,y1:0,x2:x,y2:MAP_H,stroke:'rgba(90,140,190,.10)','stroke-width':1}));}
	for(let lat=-60;lat<=80;lat+=20){const [,y]=project(0,lat);graph.append(svg('line',{x1:0,y1:y,x2:MAP_W,y2:y,stroke:'rgba(90,140,190,.10)','stroke-width':1}));}
	const [ex]=project(0,0),[eq]=project(0,0);
	graph.append(svg('line',{x1:0,y1:eq,x2:MAP_W,y2:eq,stroke:'rgba(36,117,174,.22)','stroke-width':1,'stroke-dasharray':'6 4'}));
	// 真实国家轮廓（Natural Earth 110m 简化数据）
	const land=svg('g',{class:'sa-map-land'});
	for(const [cc,d] of Object.entries(worldPaths.SA_WORLD_PATHS||{}))land.append(svg('path',{d,fill:'rgba(120,165,205,.28)',stroke:'rgba(150,190,225,.55)','stroke-width':.7}));	graph.append(land);
	const layer=svg('g');
	graph.append(layer);
	box.append(graph);
	wrap.append(box,node('p','cs-note','基于 Natural Earth 110m 世界轮廓渲染（等距圆柱投影）。气泡位置为国家代表坐标，大小与颜色深浅表示近24小时拦截次数；仅显示可定位的国家。'));
	return {wrap,layer};
}
function renderMap(layer,points,max){
	layer.replaceChildren();
	if(!points.length){const t=svg('text',{x:MAP_W/2,y:MAP_H/2,fill:'#64798a','font-size':22,'text-anchor':'middle'});t.textContent='近24小时暂无攻击数据';layer.append(t);return;}
	for(const p of points){
		const [x,y]=project(p.lon,p.lat);
		const r=6+18*Math.sqrt(max?Math.min(1,p.count/max):0);
		const circle=svg('circle',{cx:x.toFixed(1),cy:y.toFixed(1),r:r.toFixed(1),fill:'rgba(220,69,69,.55)',stroke:'#dc4545','stroke-width':1.2});
		const label=svg('text',{x:x.toFixed(1),y:(y-r-4).toFixed(1),fill:'#b23c3c','font-size':11,'text-anchor':'middle'});
		label.textContent=region(p.cc)+' · '+p.count;
		const detail=svg('title');
		detail.textContent=region(p.cc)+'（'+p.cc+'）：'+p.count+' 次拦截，'+p.sources+' 个来源';
		circle.append(detail);
		layer.append(circle,label);
	}
}
/* 24h 时间线 */
function buildTimeline(){
	const box=E('div',{class:'sa-timeline'});
	const graph=svg('svg',{viewBox:'0 0 1000 150',role:'img','aria-label':'近24小时拦截时间线'});
	const layer=svg('g');graph.append(layer);box.append(graph);
	return {box,layer};
}
function renderTimeline(layer,series){
	layer.replaceChildren();
	if(!series.length){const t=svg('text',{x:500,y:80,fill:'#64798a','font-size':16,'text-anchor':'middle'});t.textContent='近24小时暂无拦截记录';layer.append(t);return;}
	const now=Math.floor(Date.now()/1000),start=now-86400;
	const W=1000,H=130,bucket=300;
	const max=Math.max(1,...series.map(s=>s.region+s.threat));
	for(const s of series){
		const x=(s.t-start)/86400*W,w=Math.max(2,W/(86400/bucket)-1);
		const hR=s.region/max*(H-20),hT=s.threat/max*(H-20);
		if(s.region){const r=svg('rect',{x:x.toFixed(1),y:(H-hR).toFixed(1),width:w.toFixed(1),height:hR.toFixed(1),fill:'#328ac5',opacity:.85});const t=svg('title');t.textContent=time(s.t)+' 地区规则拦截 '+s.region;r.append(t);layer.append(r);}
		if(s.threat){const r=svg('rect',{x:x.toFixed(1),y:(H-hT).toFixed(1),width:w.toFixed(1),height:hT.toFixed(1),fill:'#dc4545',opacity:.85});const t=svg('title');t.textContent=time(s.t)+' 威胁黑名单拦截 '+s.threat;r.append(t);layer.append(r);}
	}
	for(const hour of [0,6,12,18,24]){const x=hour/24*W;const line=svg('line',{x1:x,y1:0,x2:x,y2:H,stroke:'rgba(80,120,160,.15)'});const t=svg('text',{x:x+2,y:H+14,fill:'#64798a','font-size':10});t.textContent='-'+(24-hour)+'h';layer.append(line,t);}
}

return view.extend({
	load(){return callOverview().then(checked);},
	async refresh(force){
		if(this.loading&&!force)return;
		this.loading=true;
		try{const data=checked(await callOverview());this.data=data;this.update();}catch(e){text(this.warning,'刷新失败：'+e.message);this.warning.hidden=false;}
		finally{this.loading=false;}
	},
	async action(button,task){if(button && button.disabled)return;if(button)button.disabled=true;try{await task();await this.refresh(true);}catch(e){ui.addNotification(null,E('p',{},e.message||'操作失败'),'error');}finally{if(button)button.disabled=false;}},
	toggle(key,label){
		const cb=E('input',{type:'checkbox','aria-label':label});
		cb.checked=!!this.data.config[key];
		cb.addEventListener('change',async()=>{
			const options={};options[key]=cb.checked;
			try{await callSet(options);await this.refresh(true);ui.addNotification(null,E('p',{},label+(cb.checked?' 已开启':' 已关闭')),'info');}
			catch(e){cb.checked=!cb.checked;ui.addNotification(null,E('p',{},e.message||'设置失败'),'error');}
		});
		return E('label',{class:'sa-switch'},[cb,E('span',{},label)]);
	},
	render(data){
		this.data=checked(data);
		if(!document.getElementById('console-security-css'))document.head.append(E('link',{id:'console-security-css',rel:'stylesheet',href:L.resource('console/security.css')}));
		if(!document.getElementById('console-situational-css'))document.head.append(E('link',{id:'console-situational-css',rel:'stylesheet',href:L.resource('console/situational.css')}));
		this.warning=node('div','alert-message warning','');
		/* 指标 */
		this.metrics={};const cards=[];
		for(const [key,label] of [['threatPackets24','24小时黑名单拦截（包）'],['threatPackets30','30天黑名单拦截（包）'],['total24','24小时事件记录'],['region24','地区事件记录'],['threat24','黑名单事件记录'],['dynamic','动态黑名单']]){
			this.metrics[key]=node('strong','','—');
			cards.push(E('div',{class:'cs-metric'},[node('span','',label),this.metrics[key]]));
		}
		const root=E('div',{class:'cbi-map cs-security sa-root'},[
			E('div',{class:'cs-heading'},[E('div',{},[E('h2',{},'态势感知'),node('p','cs-note','攻击来源地图、威胁情报与自动阻断状态。黑名单命中包数与事件日志分别落库，保留30天。包数按防火墙实际丢包计数；来源、端口、地图与时间线按限速事件日志统计，事件条数可能少于包数。包数从本次升级启用后累计。')]),this.button('立即刷新',()=>this.refresh(true)),this.button('更新威胁情报',()=>this.action(null,async()=>{await callRefresh();}))]),
			this.warning,
			E('div',{class:'cs-metrics'},cards)
		]);
		/* 地图 */
		const map=buildMap();this.mapLayer=map.layer;
		root.append(panel('攻击来源地图',[map.wrap]));
		/* 时间线 */
		const tl=buildTimeline();this.timelineLayer=tl.layer;
		root.append(panel('24小时事件时间线',[tl.box,node('p','cs-note','蓝色为地区规则拦截（CSG），红色为威胁黑名单拦截（CST），5分钟粒度。')]));
		/* Top 来源：两方向同行两列（入站=外网→路由器+内网设备 合并） */
		const mkDir=label=>({src:table([label,'规则类型','内网设备','日志条数','最近','目标端口']),count:E('strong','','—')});
		this.dirCols={inbound:mkDir('外网来源'),fwd_out:mkDir('外网目标')};
		const dirCard=(key,title,hint)=>{
			const c=this.dirCols[key];
			return E('div',{class:'sa-dir-col'},[
				E('div',{class:'sa-dir-head'},[E('h4',{},title),E('span',{class:'sa-dir-count'},[c.count,' 条记录'])]),
				node('p','cs-note',hint),
				c.src.element
			]);
		};
		root.append(panel('拦截事件明细（24小时 · 按方向）',[
			E('div',{class:'sa-dir-grid'},[
				dirCard('inbound','外网 → 内网','外部地址访问路由器或内网设备被拦截'),
				dirCard('fwd_out','内网设备 → 外网','访问命中黑名单的外部地址；条数为限速日志记录，包含重传，不等于独立连接数，不能据此认定设备中毒或被控')
			])
		]));
		/* 威胁情报 */
		this.feedInfo=E('div');
		root.append(panel('威胁情报与自动防护',[
			E('div',{class:'sa-switches'},[
				this.toggle('threatFeed','威胁情报黑名单'),
				this.toggle('dnsSink','恶意域名拦截（DNS）'),
				this.toggle('autoBlock','行为自动阻断')
			]),
			this.feedInfo
		]));
		/* 行为阈值 */
		const win=E('input',{type:'number',min:5,max:1440,value:Math.floor((this.data.config.scanWindow||600)/60)}),thr=E('input',{type:'number',min:3,max:1000,value:this.data.config.scanThreshold||10}),hrs=E('input',{type:'number',min:1,max:720,value:this.data.config.banHours||24});
		this.thresholdInputs={win,thr,hrs};
		root.append(panel('行为识别阈值',[
			E('div',{class:'cs-toolbar'},[
				E('label',{},['统计窗口（分钟） ',win]),
				E('label',{},['触发次数 ≥ ',thr]),
				E('label',{},['封禁时长（小时） ',hrs]),
				this.button('保存阈值',async()=>{await this.action(null,async()=>{await callSet({scanWindow:+win.value*60,scanThreshold:+thr.value,banHours:+hrs.value});ui.addNotification(null,E('p',{},'阈值已保存'),'info');});})
			]),
			node('p','cs-note','同一外网来源在统计窗口内命中地区规则达到阈值后，自动加入动态黑名单并阻断，无需人工确认。')
		]));
		/* 动态黑名单 */
		this.dynTable=table(['IP 地址','原因','加入时间','解禁时间','操作']);
		const banIp=E('input',{type:'text',placeholder:'手动拉黑 IPv4，例如 1.2.3.4'}),banHrs=E('input',{type:'number',min:0,max:720,value:24,style:'width:80px','aria-label':'封禁时长'});
		root.append(panel('动态黑名单',[
			E('div',{class:'cs-toolbar'},[banIp,E('label',{},['时长(小时，0=长期) ',banHrs]),this.button('手动拉黑',async()=>{await this.action(null,async()=>{await callBan(banIp.value.trim(),+banHrs.value||0);banIp.value='';});})]),
			this.dynTable.element,
			node('p','cs-note','动态黑名单与威胁情报共用 nftables console_threat 表，到期自动解封；时长填 0 表示长期拉黑（10 年，需手动解封）。')
		]));
		this.root=root;
		this.update();
		poll.add(()=>{if(!this.root.isConnected)return;return this.refresh();},5);
		return this.root;
	},
	button(label,task,primary){return E('button',{type:'button',class:'cbi-button'+(primary?' cbi-button-apply':''),click:event=>this.action(event.currentTarget,task)},label);},
	update(){
		const d=this.data;
		this.warning.hidden=!(d.warnings||[]).length;
		if(!this.warning.hidden)text(this.warning,d.warnings.join('；'));
		text(this.metrics.threatPackets24,d.stats.threatPackets24);
		text(this.metrics.threatPackets30,d.stats.threatPackets30);
		text(this.metrics.total24,d.stats.total24);
		text(this.metrics.region24,d.stats.region24);
		text(this.metrics.threat24,d.stats.threat24);
		text(this.metrics.dynamic,d.stats.dynamic);
		renderMap(this.mapLayer,d.map||[],Math.max(1,...(d.map||[]).map(p=>p.count)));
		renderTimeline(this.timelineLayer,d.series||[]);
		/* 两方向 Top 列表：入站合并 input+fwd_in */
		const kindLabel=k=>k==='region'?'地区规则':'威胁黑名单';
		const t=(d.dirTop||{});
		const inA=t.input||{count:0,top:[]},inB=t.fwd_in||{count:0,top:[]};
		const merged={};
		for(const s of [...(inA.top||[]),...(inB.top||[])]){
			const sourceKey=[s.src,s.kind,s.devIp||''].join('|');
			if(!merged[sourceKey])merged[sourceKey]={...s,count:0,last:0};
			merged[sourceKey].count+=s.count;
			merged[sourceKey].last=Math.max(merged[sourceKey].last,s.last);
			if(s.devIp){merged[sourceKey].devIp=s.devIp;merged[sourceKey].devMac=s.devMac||'';merged[sourceKey].devName=s.devName||'';}
		}
		const inboundTop=Object.values(merged).sort((a,b)=>b.count-a.count).slice(0,8);
		const cols=[['inbound',{count:inA.count+inB.count,top:inboundTop}],['fwd_out',t.fwd_out||{count:0,top:[]}]];
		for(const [key,info] of cols){
			const col=this.dirCols[key];
			col.count.textContent=''+info.count;
			if(info.top&&info.top.length)col.src.body.replaceChildren(...info.top.map(s=>{
				const td=node('span','',shortTime(s.last));
				td.title=time(s.last);
				let dev=node('span','cs-note','—');
				if(s.devIp){
					const label=s.devIp+(s.devMac?' · '+s.devMac:'');
					dev=node('span','',label);
					dev.title=s.devName&&s.devName!==s.devMac?(s.devName+' · '+label):label;
				}
				const port=s.port?node('span','',s.port):node('span','cs-note','—');
				if(s.port)port.title=s.port.indexOf('个')>0?('多个目标端口：'+s.port):('目标端口 '+s.port);
				return row([node('strong','',s.src),kindLabel(s.kind),dev,''+s.count,td,port]);
			}));
			else empty(col.src.body,6,'暂无记录');
		}
		/* 威胁情报状态 */
		const f=d.feeds||{};
		const rows=[];
		for(const [key,info] of Object.entries(f.sources||{})){
			rows.push(node('p','cs-note',(info.enabled?'':'（未启用）')+info.label+'：'+(info.ok?info.count+' 条'+(info.cached?'（网络失败，使用缓存）':'')+'，更新于 '+time(info.updated):info.error||'失败')));
		}
		rows.push(node('p','cs-note','防火墙累计计数（非24小时）：'+(d.installed?'已加载':'未加载')+' · 外网→路由器 '+d.counters.inPkts+' 包 · 外网→内网 '+(d.counters.fwdInPkts??0)+' 包 · 内网→外网 '+(d.counters.fwdOutPkts??0)+' 包'+(d.geo?' · 国家库 '+d.geo.version:'')));
		rows.push(node('p','cs-note','数据源：Spamhaus DROP、DShield、Feodo C2（IP 黑名单）；FireHOL Level1/2（权威聚合，含 FullBogons 与近48小时活跃攻击 IP，每分钟更新）；URLhaus 恶意域名经 dnsmasq 返回 0.0.0.0（abuse.ch 已改为 Auth-Key 制，匿名下载停用，需在 auth.abuse.ch 免费注册后可用）。情报每6小时自动更新，也可手动更新。'));
		this.feedInfo.replaceChildren(...rows);
		/* 动态黑名单 */
		const dyn=d.dynamic||[];
		if(dyn.length)this.dynTable.body.replaceChildren(...dyn.map(item=>row([
			node('strong','',item.ip),
			item.reason,
			time(item.added),
			time(item.until),
			this.button('解封',()=>this.action(null,async()=>{await callUnban(item.ip);}))
		])));
		else empty(this.dynTable.body,5,'暂无动态拉黑记录。');
	},
	handleSaveApply:null,handleSave:null,handleReset:null
});
