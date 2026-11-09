// SPDX-License-Identifier: Apache-2.0
import { readfile,stat,unlink,popen } from 'fs';
import { connect } from 'ubus';
import * as uloop from 'uloop';
import { DB,DATA,config,geoMeta,geoLookup,ipKey,inCIDR,parseConnection,command,output,exec,query,sqlExec,sq,writeText,writeJson,readJson,networkState,initializeDatabase,rollbackPolicy,refreshGuard,ensureGuard,startGeo,storage } from 'console.security';
import { behaviorScan,updateThreatFeeds,threatConfig,guardExistsThreat,dynamicPrune,collectEvents,persistThreatPackets } from 'console.situational';

initializeDatabase();
// 首次升级时用设备明细表回填最近 24 小时的协议流量（ICMP 无历史数据，记 0）。
try { if(!(+(query('SELECT COUNT(*) AS n FROM protocol;')[0]?.n || 0))) sqlExec('INSERT OR REPLACE INTO protocol(step,ts,tcp,udp,icmp,other) SELECT 60,ts,SUM(tcpup+tcpdown),SUM(udpup+udpdown),0,SUM(otherup+otherdown) FROM samples WHERE ts>='+int(time()-86400)+' GROUP BY ts;'); } catch(e) {}
let saved={}; try { saved=json(query('SELECT data FROM state WHERE id=1;')[0]?.data || '{}'); } catch(e) {}
let devices=saved.devices || {}, previous=saved.raw || {}, generation=saved.generation || '', previousTime=saved.time || null, previousUptime=saved.uptime || null;
let buffer={}, bufferTime=int(time()/60)*60, lastPersist=time(), lastTopology=0, lastAnalysis=0, lastGuard=0, lastHousekeeping=0, lastThreat=0, lastThreatRefresh=+(readJson('/srv/console-situational/feeds.json',{}).updated || 0), lastThreatWarn=0, lastEvents=0, lastEventStamp=0;
let topology=null, topologyKey='', identities={}, currentAddresses={}, lanSubnets=[], own={}, analysis={available:false,limited:false,destinations:[]}, flows={}, baseline=false, countryCache={}, countryVersion=null;
let ruleCounters=[], warnings=[], lastError=null, refreshSignature='', historyPaused=false, clockAdjustedUntil=0;
// 协议流量增量缓冲：每分钟跟设备明细一起落库，供概况页读取 30 分钟/1 小时/1 天合计。
let protoBuffer={tcp:0,udp:0,icmp:0,other:0};
const boot=trim(readfile('/proc/sys/kernel/random/boot_id') || '');
const fields=['up','down','tcpup','tcpdown','udpup','udpdown','otherup','otherdown'];
function zero() { const r={}; for(let f in fields) r[f]=0; return r; }
function nft(args) { const text=output(['/usr/sbin/nft','-j',...args]); if (!length(trim(text))) die('无法读取 nftables 计数器'); return json(text).nftables || []; }
// 透明代理（mihomo TUN）接管的内网流量不经过 LAN→WAN 的 forward 路径，
// 需要在 LAN ↔ TUN 设备之间单独计量，否则协议流量分布会漏掉代理流量。
function tunDevices() {
	const cfg=readJson('/etc/console-mihomo/config.json',{});
	const dev=cfg?.tun?.enable ? cfg?.tun?.device : null;
	return type(dev)=='string' && length(dev) ? [dev] : [];
}
function meterText(net) {
	const lines=['destroy table inet console_meter','table inet console_meter {'];
	for (let role in ['lan','wan']) push(lines,'set '+role+' { type ifname;'+(length(net[role])?' elements = { '+join(', ',map(net[role],n=>sprintf('%J',n)))+' };':'')+' }');
	for (let d in ['up','down']) for (let f in [4,6]) push(lines,'set '+d+f+' { type '+(f==4?'ipv4_addr':'ipv6_addr')+' . inet_proto; flags dynamic,timeout; timeout 7d; gc-interval 1h; counter; size 16384; }');
	lines[length(lines)]='chain account { type filter hook forward priority 10; policy accept;';
	const tun=tunDevices();
	for (let f in [4,6]) {
		const ip=f==4?'ip':'ip6', family=f==4?'ipv4':'ipv6';
		push(lines,'iifname @lan oifname @wan meta nfproto '+family+' update @up'+f+' { '+ip+' saddr . meta l4proto timeout 7d counter }');
		push(lines,'iifname @wan oifname @lan meta nfproto '+family+' update @down'+f+' { '+ip+' daddr . meta l4proto timeout 7d counter }');
		for (let dev in tun) {
			push(lines,'iifname @lan oifname "'+dev+'" meta nfproto '+family+' update @up'+f+' { '+ip+' saddr . meta l4proto timeout 7d counter }');
			push(lines,'iifname "'+dev+'" oifname @lan meta nfproto '+family+' update @down'+f+' { '+ip+' daddr . meta l4proto timeout 7d counter }');
		}
	}
	push(lines,'}','}'); return join('\n',lines)+'\n';
}
function updateTopology() {
	const net=networkState(); topology=net;
	const existing=output(['/usr/sbin/nft','list','table','inet','console_meter']);
	const tun=tunDevices(), missingTun=length(tun) && index(existing,'oifname "'+tun[0]+'"')<0;
	if (!length(trim(existing)) || missingTun) {
		writeText('/tmp/console-meter-new.nft',meterText(net)); exec(['/usr/sbin/nft','-c','-f','/tmp/console-meter-new.nft']); exec(['/usr/sbin/nft','-f','/tmp/console-meter-new.nft']);
	} else if (sprintf('%J',net)!=topologyKey) {
		const lines=[]; for(let role in ['lan','wan']) { push(lines,'flush set inet console_meter '+role); if(length(net[role])) push(lines,'add element inet console_meter '+role+' { '+join(', ',map(net[role],n=>sprintf('%J',n)))+' }'); }
		writeText('/tmp/console-meter-net.nft',join('\n',lines)+'\n'); exec(['/usr/sbin/nft','-f','/tmp/console-meter-net.nft']);
	}
	topologyKey=sprintf('%J',net);
	const bus=connect(); const hints=bus?.call('luci-rpc','getHostHints') || {}, dump=bus?.call('network.interface','dump'); bus?.disconnect();
	identities={}; currentAddresses={}; own={}; const subnets=[], visible={};
	for(let iface in dump?.interface || []) for(let a in [...(iface['ipv4-address'] || []),...(iface['ipv6-address'] || [])]) { const p=ipKey(a.address); if(p) own[p.family+':'+p.key]=true; }
	for(let iface in dump?.interface || []) if(index(net.lan,iface.l3_device || iface.device)>=0) for(let a in [...(iface['ipv4-address'] || []),...(iface['ipv6-address'] || []),...(iface['ipv6-prefix-assignment'] || [])]) if(ipKey(a.address) && !inCIDR(a.address,'fe80::/10')) push(subnets,a.address+'/'+a.mask);
	lanSubnets=subnets;
	for(let mac,hint in hints) {
		mac=lc(mac); if(!match(mac,/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) continue;
		const ips=[];
		for(let ip in [...(hint.ipaddrs || []),...(hint.ip6addrs || [])]) { const parsed=ipKey(ip); if(parsed && !own[parsed.family+':'+parsed.key] && length(filter(subnets,s=>inCIDR(ip,s)))) { push(ips,ip); identities[parsed.family+':'+parsed.key]={id:mac,mac,name:hint.name || '',ips}; } }
		if(length(ips)) {
			visible[mac]=true;
			currentAddresses[mac]=ips;
			if(!devices[mac]) devices[mac]={id:mac,mac,name:hint.name || '',ips,total:zero(),today:zero(),day:'',lastSeen:0};
			devices[mac].name=hint.name || devices[mac].name; devices[mac].ips=ips;
		}
	}
	for(let id,d in devices) if(d.mac && !visible[id] && !d.total.up && !d.total.down) delete devices[id];
	writeJson('/tmp/console-security-bindings.json',currentAddresses);
	lastTopology=time();
}
function persist(now) {
	const statements=['BEGIN IMMEDIATE;'];
	for(let id,bytes in buffer) push(statements,'INSERT INTO samples VALUES(60,'+bufferTime+','+sq(id)+','+join(',',map(fields,f=>int(bytes[f])))+') ON CONFLICT(step,ts,device) DO UPDATE SET '+join(',',map(fields,f=>f+'='+f+'+excluded.'+f))+';');
	push(statements,'INSERT INTO protocol(step,ts,tcp,udp,icmp,other) VALUES(60,'+bufferTime+','+int(protoBuffer.tcp)+','+int(protoBuffer.udp)+','+int(protoBuffer.icmp)+','+int(protoBuffer.other)+') ON CONFLICT(step,ts) DO UPDATE SET tcp=tcp+excluded.tcp,udp=udp+excluded.udp,icmp=icmp+excluded.icmp,other=other+excluded.other;');
	push(statements,'INSERT INTO state VALUES(1,'+sq(sprintf('%J',{devices,raw:previous,generation,time:now,uptime:previousUptime}))+') ON CONFLICT(id) DO UPDATE SET data=excluded.data;','COMMIT;');
	sqlExec(join('\n',statements)); buffer={}; protoBuffer={tcp:0,udp:0,icmp:0,other:0}; bufferTime=int(now/60)*60; lastPersist=now;
}
function housekeeping(now) {
	const cutoff=int((now-86400)/300)*300;
	sqlExec('BEGIN; INSERT INTO samples SELECT 300,(ts/300)*300,device,'+join(',',map(fields,f=>'SUM('+f+')'))+' FROM samples WHERE step=60 AND ts<'+cutoff+' GROUP BY (ts/300),device ON CONFLICT(step,ts,device) DO UPDATE SET '+join(',',map(fields,f=>f+'='+f+'+excluded.'+f))+'; DELETE FROM samples WHERE step=60 AND ts<'+cutoff+'; DELETE FROM samples WHERE ts<'+int(now-604800)+'; DELETE FROM protocol WHERE ts<'+int(now-86400-600)+'; COMMIT; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(128);');
	const disk=storage();
	if(disk.historyBytes>80*1024*1024 || disk.freeBytes<100*1024*1024) sqlExec('DELETE FROM samples WHERE ts<'+int(now-86400)+'; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(2048);');
	for(let id,d in devices) if(!d.mac && d.lastSeen && now-d.lastSeen>604800) delete devices[id];
	lastHousekeeping=now;
	const meta=geoMeta(), job=readJson('/tmp/console-geo-job.json',{}), tm=localtime();
	const month=sprintf('%04d-%02d',tm.year,tm.mon);
	if((!meta || meta.version!=month) && now-(job.started || 0)>86400) startGeo();
}
function analyze(now) {
	const previousAnalysis=lastAnalysis; lastAnalysis=now;
	const count=+(readfile('/proc/sys/net/netfilter/nf_conntrack_count') || '0');
	if(count>20000) { analysis={available:false,limited:true,message:'连接数超过20000，已暂停会话分析以保护转发性能',destinations:[]}; return; }
	const stream=popen(command(['/usr/sbin/conntrack','-L','-o','extended'])+' 2>/dev/null');
	if(!stream) { analysis={available:false,limited:false,message:'连接跟踪数据不可用',destinations:[]}; return; }
	let current={}, totals={}, clients={}, processed=0;
	for(let line=stream.read('line');line!=null;line=stream.read('line')) {
		if(processed++>=4096) break; const conn=parseConnection(line); if(!conn) continue;
		const source=ipKey(conn.src), dest=ipKey(conn.dst), reply=ipKey(conn.replySrc); if(!source || !dest) continue;
		const initiator=identities[source.family+':'+source.key], responder=reply?identities[reply.family+':'+reply.key]:null;
		if(initiator && responder) continue;
		const routerService=!!(reply && own[reply.family+':'+reply.key] && !responder);
		const identity=routerService?{id:'router'}:(initiator || responder); if(!identity) continue;
		const direction=routerService?'router':initiator?'outgoing':'incoming';
		const localIP=routerService?conn.replySrc:initiator?conn.src:conn.replySrc;
		const remoteIP=routerService || !initiator?conn.src:conn.dst;
		const targetPort=routerService?(conn.dport || conn.replySport):initiator?conn.dport:(conn.replySport || conn.dport);
		const remote=ipKey(remoteIP); if(!remote || own[remote.family+':'+remote.key] || (!routerService && (identities[remote.family+':'+remote.key] || length(filter(lanSubnets,s=>inCIDR(remoteIP,s)))))) continue;
		const key=join('|',[conn.layer3,conn.layer4,conn.src,conn.sport,conn.dst,conn.dport,conn.zone || '']);
		const bytes=max(0,+conn.bytes || 0); current[key]=bytes;
		const delta=baseline ? max(0,bytes-(flows[key] || 0)) : 0;
		clients[identity.id]=(clients[identity.id] || 0)+1;
		const id=identity.id+'|'+direction+'|'+localIP+'|'+remoteIP+'|'+targetPort+'|'+conn.layer4;
		if(!totals[id]) totals[id]={device:identity.id,direction,localIP,ip:remoteIP,port:targetPort,protocol:conn.layer4,bytes:0,connections:0};
		totals[id].bytes+=delta; totals[id].connections++;
	}
	const status=stream.close();
	if(status!=0 && processed<4096) {analysis={available:false,limited:false,message:'读取连接跟踪失败',destinations:[]};return;}
	const records=sort(values(totals),(a,b)=>b.bytes-a.bytes); const top=slice(records,0,30);
	const meta=geoMeta(); if(meta?.version!=countryVersion) {countryCache={};countryVersion=meta?.version;}
	for(let row in top) { if(!(row.ip in countryCache)) countryCache[row.ip]=geoLookup(row.ip).country; row.country=countryCache[row.ip]; }
	if(length(keys(countryCache))>2048) countryCache={};
	flows=current; baseline=true;
	analysis={available:true,time:now,interval:previousAnalysis?now-previousAnalysis:null,limited:processed>4096,observed:count,processed:min(4096,processed),destinations:top,clients};
}
// 规则命中次数落库：nft 计数器在规则重载/重启后会清零，这里保存累计值。
function persistRuleHits(list) {
	const totals = {};
	const st = ['BEGIN;', 'CREATE TABLE IF NOT EXISTS rule_hits(rule TEXT PRIMARY KEY, total INTEGER, raw INTEGER);'];
	for (let c in list) {
		const name = c.name;
		if (!name || substr(name, 0, 1) != 'b') continue;
		const rule = substr(name, 1), packets = +c.packets || 0;
		let cur = { total: 0, raw: 0 };
		try { cur = query('SELECT total,raw FROM rule_hits WHERE rule=' + sq(rule) + ';')[0] || cur; } catch (e) {}
		const prev = +cur.raw || 0, delta = packets >= prev ? packets - prev : 0;
		const total = (+cur.total || 0) + delta;
		totals[name] = total;
		push(st, 'INSERT INTO rule_hits(rule,total,raw) VALUES(' + sq(rule) + ',' + total + ',' + packets + ') ON CONFLICT(rule) DO UPDATE SET total=excluded.total,raw=excluded.raw;');
	}
	push(st, 'COMMIT;');
	try { sqlExec(join('\n', st)); } catch (e) {}
	return totals;
}
function sample() {
	const now=time(), uptime=+split(readfile('/proc/uptime') || '0',' ')[0];
	try {
		rollbackPolicy(true);
		if(!topology || now-lastTopology>=30) updateTopology();
		const entries=nft(['list','table','inet','console_meter']);
		const saturated=length(filter(entries,e=>e.set && length(e.set.elem || [])>=15000))>0;
		const table=filter(entries,e=>e.table)[0]?.table;
		const epoch=boot+':'+table?.handle;
		if(epoch!=generation) { previous={}; generation=epoch; previousTime=null; previousUptime=null; }
		const gap=previousUptime!=null?uptime-previousUptime:0;
		if(previousTime && gap>0 && ((now-previousTime)-gap>5 || (now-previousTime)-gap < -5)) {
			buffer={}; protoBuffer={tcp:0,udp:0,icmp:0,other:0}; bufferTime=int(now/60)*60; lastPersist=now; lastTopology=0; lastAnalysis=0; lastHousekeeping=0; lastThreat=0; clockAdjustedUntil=now+30;
		}
		const rates={}, raw={};
		const tm=localtime(), day=sprintf('%04d-%02d-%02d',tm.year,tm.mon,tm.mday);
		for(let e in entries) if(e.set && match(e.set.name,/^(up|down)[46]$/)) {
			const direction=substr(e.set.name,0,2)=='up'?'up':'down';
			for(let item in e.set.elem || []) {
				const v=item.elem?.val?.concat, counter=item.elem?.counter;
				if(!v || !counter) continue; const parsed=ipKey(v[0]); if(!parsed) continue;
				const key=e.set.name+':'+parsed.key+':'+v[1], bytes=+counter.bytes || 0; raw[key]=bytes;
				const delta=previous[key]!=null && bytes>=previous[key] ? bytes-previous[key] : 0;
				if(!delta || own[parsed.family+':'+parsed.key]) continue;
				const known=identities[parsed.family+':'+parsed.key], id=known?.id || 'ip:'+v[0];
				if(!devices[id]) devices[id]={id,mac:known?.mac || null,name:known?.name || '',ips:known?.ips || [v[0]],total:zero(),today:zero(),day,lastSeen:now};
				const device=devices[id]; if(device.day!=day) {device.day=day;device.today=zero();}
				device.lastSeen=now;
				if(!rates[id]) rates[id]=zero(); if(!buffer[id]) buffer[id]=zero();
				const kind=v[1]=='tcp'?'tcp':v[1]=='udp'?'udp':(v[1]=='icmp'||v[1]=='ipv6-icmp'||v[1]=='icmpv6')?'icmp':'other';
				// 设备明细仍按 tcp/udp/other 归类（ICMP 计入 other），协议合计单独统计 ICMP。
				const protocol=(kind=='icmp'?'other':kind)+direction;
				for(let field in [direction,protocol]) {device.total[field]+=delta;device.today[field]+=delta;buffer[id][field]+=delta;rates[id][field]+=delta;}
				protoBuffer[kind]+=delta;
			}
		}
		previous=raw; previousTime=now; previousUptime=uptime;
		if(now-lastPersist>=60) {
			const disk=storage();
			if(disk.historyBytes>80*1024*1024 || disk.freeBytes<100*1024*1024) housekeeping(now);
			if(storage().freeBytes<100*1024*1024) {historyPaused=true;buffer={};bufferTime=int(now/60)*60;lastPersist=now;}
			else {historyPaused=false;persist(now);}
		}
		if(now-lastAnalysis>=30) analyze(now);
		if(now-lastEvents>=5) { try { persistThreatPackets(now); const r=collectEvents(now,lastEventStamp); if(r.last>lastEventStamp) lastEventStamp=r.last; } catch(e) { warn('态势采集失败：'+(e.message || '未知错误')+'\n'); } lastEvents=now; }
		if(now-lastGuard>=30) {
			ensureGuard();
			const counterObjects=nft(['list','counters','table','inet','console_guard']);
			const rawCounters=map(filter(counterObjects,e=>e.counter),e=>e.counter);
			const totals=persistRuleHits(rawCounters);
			ruleCounters=map(rawCounters,c=>substr(c.name || '',0,1)=='b'?{name:c.name,packets:totals[c.name] || 0}:c);
			const signature=sprintf('%J',{topology,identities});
			if(signature!=refreshSignature && !readJson('/etc/console-security/pending.json',null)) {refreshGuard();refreshSignature=signature;}
			lastGuard=now;
		}
		// 态势感知：行为自动阻断 + 威胁情报表保活与定时刷新
		if(now-lastThreat>=60) {
			// 这里以前是空 catch，威胁任务一旦抛错就完全静默：情报表会连续几天
			// 不刷新，页面上仍显示"正常"，只有 feeds.json 的 updated 才看得出。
			// 现在至少把失败原因写进日志（限流，避免每 60 秒刷屏）。
			let threatError=null;
			try {
				const tcfg=threatConfig();
				if(tcfg.autoBlock) { behaviorScan(tcfg); dynamicPrune(); }
				// Feed downloads can take minutes. Keep them out of the sampling loop.
				if(tcfg.threatFeed && (!guardExistsThreat() || now-lastThreatRefresh>=21600)) {
					exec(['/bin/sh','-c','/usr/bin/ucode /usr/sbin/console-threat-update.uc >/tmp/console-threat-refresh.log 2>&1 &']);
					lastThreatRefresh=now;
				}
			} catch(e2) { threatError=e2.message || '未知错误'; }
			if(threatError && now-(lastThreatWarn || 0)>=3600) { warn('态势感知任务失败：'+threatError+'\n'); lastThreatWarn=now; }
			lastThreat=now;
		}
		warnings=[];
		if(topology.offloading) push(warnings,'检测到流量卸载：统计可能不完整，请关闭软/硬件流量卸载');
		if(!length(topology.lan) || !length(topology.wan)) push(warnings,'LAN或WAN接口尚未就绪');
		if(!topology.defaultRoute) push(warnings,'未检测到WAN默认路由，可能无法上网；国家库自动下载需要外网连接');
		if(historyPaused) push(warnings,'可用空间低于100MiB，历史写入暂停；实时统计继续');
		if(saturated) push(warnings,'计数集合接近容量上限，统计可能不完整');
		if(now<clockAdjustedUntil) push(warnings,'检测到系统时间调整，历史采样已新建时间窗口');
		const list=[]; let upload=0,download=0;
		for(let id,d in devices) {
			if(d.day!=day) {d.day=day;d.today=zero();}
			const bytes=rates[id] || zero(), valid=gap>0 && gap<=15;
			const up=valid?bytes.up/gap:null, down=valid?bytes.down/gap:null;
			if(up!=null) upload+=up; if(down!=null) download+=down;
			const connections=analysis.clients?.[id] || 0;
			const currentIPs=currentAddresses[id] || [];
			push(list,{...d,currentIPs,upload:up,download:down,online:now-d.lastSeen<=120,connections,alerts:[...(connections>1000?['连接数较多']:[]),...((up || 0)+(down || 0)>50*1024*1024?['流量较高']:[])]});
		}
		writeJson('/tmp/console-security-state.json',{time:now,devices:sort(list,(a,b)=>(b.upload || 0)+(b.download || 0)-(a.upload || 0)-(a.download || 0)),upload:gap>0&&gap<=15?upload:null,download:gap>0&&gap<=15?download:null,accurate:!topology.offloading&&!saturated,analysis,ruleCounters,warnings,interval:2,error:lastError});
		lastError=null;
		if(now-lastHousekeeping>=3600) housekeeping(now);
	} catch(e) {
		lastTopology=0; lastGuard=0; lastThreat=0;
		lastError=e.message || '流量采集失败';
		const old=readJson('/tmp/console-security-state.json',{}); old.error=lastError; writeJson('/tmp/console-security-state.json',old);
		warn(lastError+'\n');
	}
}
uloop.init(); sample(); const timer=uloop.interval(2000,sample); uloop.run();
