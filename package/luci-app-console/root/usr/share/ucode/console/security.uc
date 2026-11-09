// SPDX-License-Identifier: Apache-2.0
import { open, readfile, rename, unlink, mkdir, rmdir, stat, chmod, popen } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

const ROOT = '/etc/console-security';
const DATA = '/srv/console-security';
const DB = DATA + '/traffic.db';
const GUARD = ROOT + '/guard.nft';
const PENDING = ROOT + '/pending.json';
const LOCK = '/tmp/console-security-write.lock';
const BOOT = trim(readfile('/proc/sys/kernel/random/boot_id') || '');
function uptime() { return +split(readfile('/proc/uptime') || '0', ' ')[0]; }
function fail(s) { die(s + '\n'); }
function sh(s) { return "'" + replace('' + s, /'/g, "'\\''") + "'"; }
function sq(s) { return "'" + replace('' + s, /'/g, "''") + "'"; }
function command(args) { return join(' ', map(args, sh)); }
function output(args) { const p = popen(command(args)); if (!p) return ''; const s = p.read('all') || ''; p.close(); return s; }
function exec(args) { if (system(args) != 0) fail('执行失败：' + args[0]); }
function readJson(path, fallback) { try { return json(readfile(path) || ''); } catch (e) { return fallback; } }
function writeText(path, text) { const temp = path + '.new'; const f = open(temp, 'w'); if (!f) fail('无法写入 ' + path); f.write(text); f.close(); chmod(temp, 0600); if (!rename(temp, path)) fail('无法保存 ' + path); }
function writeJson(path, data) { writeText(path, sprintf('%J', data)); }
function ensure() { mkdir(ROOT); mkdir(DATA); chmod(ROOT, 0700); chmod(DATA, 0700); }
function query(sql, db) { const p = popen(command(['/usr/bin/sqlite3', '-json', '-cmd', '.timeout 3000', db || DB, sql])); if (!p) fail('数据库不可用'); const raw = p.read('all') || ''; const status = p.close(); if (status != 0) fail('数据库查询失败'); return length(trim(raw)) ? json(raw) : []; }
function sqlExec(sql, db) {
	// Stream transactions over stdin: a busy log batch can exceed Linux's single
	// argument limit (128 KiB), causing exec() to fail before SQLite even starts.
	const p = popen(command(['/usr/bin/sqlite3', '-bail', db || DB]), 'w');
	if (!p) fail('无法启动数据库写入');
	const input = '.timeout 10000\n.output /dev/null\nPRAGMA max_page_count=25600;\n' + sql + '\n';
	const written = p.write(input);
	const status = p.close();
	if (written != length(input) || status != 0) fail('数据库写入失败，请检查空间、锁竞争及数据库完整性');
}
function storage() { const lines = split(trim(output(['/bin/df', '-Pk', DATA])), '\n'); const fields = split(trim(lines[length(lines)-1] || ''), /\s+/); return { freeBytes: (+fields[3] || 0) * 1024, historyBytes: (stat(DB)?.size || 0)+(stat(DB+'-wal')?.size || 0)+(stat(DB+'-shm')?.size || 0) }; }

function ipKey(value) {
	if (type(value) != 'string' || !match(value, /^[0-9a-fA-F:.]+$/)) return null;
	if (index(value, ':') < 0) {
		const p = split(value, '.'); if (length(p) != 4) return null; let n = 0;
		for (let x in p) { if (!match(x, /^\d{1,3}$/) || +x > 255 || (length(x)>1 && substr(x,0,1)=='0')) return null; n = n*256 + +x; }
		return { family: 4, key: sprintf('%08x', n) };
	}
	let source = lc(value);
	if (index(source, '.') >= 0) {
		const parts = split(source, ':'); const v4 = ipKey(pop(parts)); if (!v4 || v4.family != 4) return null;
		source = join(':', parts) + ':' + substr(v4.key, 0, 4) + ':' + substr(v4.key, 4, 4);
	}
	const halves = split(source, '::'); if (length(halves)>2) return null;
	const left = length(halves[0]) ? split(halves[0], ':') : [];
	const right = length(halves)>1 && length(halves[1]) ? split(halves[1], ':') : [];
	const missing = 8-length(left)-length(right);
	if ((length(halves)==1 && missing!=0) || missing<0 || (length(halves)==2 && missing<1)) return null;
	const words = [...left]; for (let i=0; i<missing; i++) push(words, '0'); for (let x in right) push(words,x);
	let key = ''; for (let x in words) { if (!match(x, /^[0-9a-f]{1,4}$/)) return null; key += substr('0000'+x, length(x)); }
	return { family: 6, key };
}
function cidr(value) { const parts = split(trim(value), '/'); const ip = ipKey(parts[0]); if (!ip || length(parts)>2) fail('IP/CIDR 无效：' + value); if (length(parts)>1 && (!match(parts[1], /^\d{1,3}$/) || +parts[1]>(ip.family==4?32:128))) fail('前缀无效：'+value); return { family: ip.family, value: trim(value) }; }
function config() { return readJson(ROOT+'/config.json', { rules: [], allowIPs: [], blockIPs: [], historyDays: 7 }); }
function geoMeta() { return readJson(DATA+'/geo.json', null); }
function geoPath() { const m = geoMeta(); return m && match(m.file || '', /^geo-[0-9-]+\.db$/) ? DATA+'/'+m.file : null; }
const INTERNAL_IPV4_RANGE = { first: '172.16.10.0', last: '172.16.50.255' };
function isInternalIPv4(ip) {
	const parsed=ipKey(ip); if(!parsed || parsed.family!=4) return false;
	const octets=split(ip,'.');
	return +octets[0]==172 && +octets[1]==16 && +octets[2]>=10 && +octets[2]<=50;
}
function geoLookup(ip) {
	const parsed = ipKey(ip), path = geoPath(); if (!parsed) fail('请输入有效 IPv4 或 IPv6 地址');
	if(isInternalIPv4(ip)) return { ip, country: 'LAN', internal: true, available: true };
	if (!path) return { ip, country: null, available: false };
	const row = query('SELECT finish,cc FROM geo WHERE family='+parsed.family+' AND start<='+sq(parsed.key)+' ORDER BY start DESC LIMIT 1;', path)[0];
	return { ip, country: row && row.finish >= parsed.key ? row.cc : null, available: true };
}
function inCIDR(ip, range) {
	const p=ipKey(ip), parts=split(range,'/'), r=ipKey(parts[0]); if(!p || !r || p.family!=r.family) return false;
	const bits=length(parts)>1?+parts[1]:(p.family==4?32:128), chars=int(bits/4), remain=bits%4;
	if(substr(p.key,0,chars)!=substr(r.key,0,chars)) return false;
	if(!remain) return true;
	const a=index('0123456789abcdef',substr(p.key,chars,1)), b=index('0123456789abcdef',substr(r.key,chars,1));
	let div=1; for(let i=0;i<4-remain;i++) div*=2; return int(a/div)==int(b/div);
}
function parseConnection(line) {
	const tokens=split(trim(line),/\s+/); if(index(['ipv4','ipv6'],tokens[0])<0) return null;
	const tuples=[{},{}]; let side=-1, zone='0';
	for(let token in tokens) { const pair=match(token,/^(src|dst|sport|dport|bytes|packets|zone)=(.*)$/); if(!pair) continue; if(pair[1]=='zone') {zone=pair[2];continue;} if(pair[1]=='src') side++; if(side>=0 && side<2) tuples[side][pair[1]]=pair[2]; }
	if(!ipKey(tuples[0].src) || !ipKey(tuples[0].dst)) return null;
	return {src:tuples[0].src,dst:tuples[0].dst,sport:tuples[0].sport,dport:tuples[0].dport,replySrc:tuples[1].src,replyDst:tuples[1].dst,replySport:tuples[1].sport,replyDport:tuples[1].dport,bytes:(+tuples[0].bytes || 0)+(+tuples[1].bytes || 0),layer3:tokens[0],layer4:tokens[2],zone};
}
function networkState() {
	const bus = connect(); const dump = bus?.call('network.interface', 'dump'); bus?.disconnect();
	if (type(dump?.interface) != 'array') fail('无法读取网络接口');
	const c = cursor(), roles = { lan: [], wan: [] }, devices = { lan: [], wan: [], defaultRoute:false };
	c.foreach('firewall', 'zone', z => { if (z.name=='lan' || z.name=='wan') roles[z.name] = type(z.network)=='array' ? z.network : split(z.network || '', /\s+/); });
	const defaults=[]; c.foreach('firewall','defaults', d=>push(defaults,d));
	for (let iface in dump.interface) for (let role in ['lan','wan']) if (index(roles[role],iface.interface)>=0) {
		const name=iface.l3_device || iface.device; if (name && match(name,/^[A-Za-z0-9_.:@-]{1,64}$/) && index(devices[role],name)<0) push(devices[role],name);
		if(role=='wan' && iface.up) for(let route in iface.route || []) if((route.target=='0.0.0.0' || route.target=='::') && +route.mask==0) devices.defaultRoute=true;
	}
	devices.offloading = defaults[0]?.flow_offloading=='1' || defaults[0]?.flow_offloading_hw=='1';
	return devices;
}
function lock() {
	if (!mkdir(LOCK)) {
		const owner=readJson(LOCK+'/owner.json',null), live=owner ? split(readfile('/proc/'+owner.pid+'/stat') || '', ' ') : [];
		if ((owner && (!length(live) || live[21]!=owner.start)) || (!owner && time()-(stat(LOCK)?.mtime || time())>10)) { unlink(LOCK+'/owner.json'); unlink(LOCK+'/owner.json.new'); rmdir(LOCK); if(!mkdir(LOCK)) fail('安全配置任务正在执行'); }
		else fail('另一个安全配置任务正在执行，请稍后重试');
	}
	const me=split(readfile('/proc/self/stat') || '', ' '); writeJson(LOCK+'/owner.json',{pid:+me[0],start:me[21]});
}
function unlock() { unlink(LOCK+'/owner.json'); rmdir(LOCK); }
function withLock(callback) { lock(); try { const result=callback(); unlock(); return result; } catch (e) { unlock(); die(e.message || '安全配置任务失败'); } }
function validate(input) {
	if (type(input)!='object' || type(input.rules)!='array' || length(input.rules)>100) fail('最多支持100条地区规则');
	const result = { rules: [], allowIPs: [], blockIPs: [], historyDays: 7 }, ids={}, known=map(geoMeta()?.countries || [],c=>c.cc);
	for (let key in ['allowIPs','blockIPs']) {
		if (type(input[key])!='array' || length(input[key])>256) fail('IP例外最多256项');
		for (let ip in input[key]) push(result[key],cidr(ip).value);
	}
	for (let r in input.rules) {
		if (!match(''+r.id,/^[a-z0-9]{1,20}$/) || ids[r.id]) fail('规则标识无效或重复'); ids[r.id]=true;
		if (type(r.name)!='string' || !length(trim(r.name)) || length(r.name)>80) fail('规则名称应为1至80字');
		if (index(['input','incoming','outgoing'],r.direction)<0 || index(['allow','block'],r.action)<0 || index(['all','tcp','udp'],r.protocol)<0) fail('方向、动作或协议无效');
		if (r.device!='all' && !match(r.device || '',/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) fail('设备MAC无效');
		if (r.direction=='input' && r.device!='all') fail('访问路由器规则不能限定内网设备');
		if (type(r.countries)!='array' || !length(r.countries) || length(r.countries)>250) fail('请选择国家或地区');
		for (let code in r.countries) if (!match(code,/^[A-Z]{2}$/)) fail('地区代码无效');
		if(r.enabled) for(let code in r.countries) if(index(known,code)<0) fail('当前地区库不包含地区：'+code);
		const ports = trim(r.ports || ''); if (length(ports)>120 || (length(ports) && r.protocol=='all')) fail('指定端口时请选择TCP或UDP');
		for (let part in length(ports)?split(ports,','):[]) { const p=split(trim(part),'-'); if (length(p)>2 || !match(trim(p[0]),/^\d{1,5}$/) || +p[0]<1 || +p[0]>65535 || (length(p)>1 && (!match(trim(p[1]),/^\d{1,5}$/) || +p[1]<+p[0] || +p[1]>65535))) fail('端口格式应为80,443或1000-2000'); }
		push(result.rules,{ id:r.id,name:trim(r.name),enabled:r.enabled===true,direction:r.direction,action:r.action,protocol:r.protocol,ports:replace(ports,/\s/g,''),device:r.device,countries:uniq(r.countries) });
	}
	return result;
}
function deviceAddresses(mac) {
	return readJson('/tmp/console-security-bindings.json',{})[mac] || [];
}
function nftList(values) { return '{ '+join(', ',map(values,v=>sprintf('%J',v)))+' }'; }
function compileGuard(settings, db) {
	const net=networkState(), lines=['destroy table inet console_guard','table inet console_guard {','limit audit { rate 10/second burst 20 packets; }'];
	for (let role in ['lan','wan']) push(lines,'set '+role+' { type ifname;'+(length(net[role])?' elements = '+nftList(net[role])+';':'')+' }');
	push(lines,'set internal4 { type ipv4_addr; flags interval; elements = { '+INTERNAL_IPV4_RANGE.first+'-'+INTERNAL_IPV4_RANGE.last+' }; }');
	const path=db || geoPath(), groups={}, ruleSets={}; let groupCount=0, rangeCount=0;
	for (let r in settings.rules) if (r.enabled) {
		if (!path) fail('请先下载地区数据库，再启用地区规则');
		const signature=join(',',sort([...r.countries]));
		if(groups[signature]) {ruleSets[r.id]=groups[signature];push(lines,'counter b'+r.id+' { }','counter a'+r.id+' { }');continue;}
		const prefix='geo'+(++groupCount); groups[signature]=prefix; ruleSets[r.id]=prefix;
		for (let family in [4,6]) {
			const ranges=query('SELECT a,b FROM geo WHERE family='+family+' AND cc IN ('+join(',',map(r.countries,sq))+');',path);
			rangeCount+=length(ranges); if(rangeCount>500000) fail('地区集合超过50万网段，请合并规则或缩小地区范围');
			const elements=join(', ',map(ranges,v=>v.a==v.b?v.a:v.a+'-'+v.b));
			push(lines,'set '+prefix+'v'+family+' { type '+(family==4?'ipv4_addr':'ipv6_addr')+'; flags interval; auto-merge;'+(length(elements)?' elements = { '+elements+' };':'')+' }');
		}
		push(lines,'counter b'+r.id+' { }','counter a'+r.id+' { }');
	}
	for (let direction in ['input','incoming','outgoing']) {
		const addr=direction=='outgoing'?'daddr':'saddr'; push(lines,'chain '+direction+'_rules {');
		for (let key in ['allowIPs','blockIPs']) for (let family in [4,6]) {
			const ips=filter(settings[key],v=>cidr(v).family==family); if (length(ips)) push(lines,(family==4?'ip ':'ip6 ')+addr+' { '+join(', ',ips)+' } '+(key=='allowIPs'?'return':'drop'));
		}
		push(lines,'ip '+addr+' @internal4 return');
		for (let r in settings.rules) if (r.enabled && r.direction==direction) {
			let base=r.protocol=='all'?'':'meta l4proto '+r.protocol+' ';
			if (length(r.ports)) base+=r.protocol+' dport { '+r.ports+' } ';
			for (let family in [4,6]) {
				const ip=family==4?'ip':'ip6'; let matchText=base;
				if (r.device!='all') {
					const ips=filter(deviceAddresses(r.device),v=>ipKey(v)?.family==family); if (!length(ips)) continue;
					matchText+=ip+' '+(direction=='outgoing'?'saddr':'daddr')+' { '+join(', ',ips)+' } ';
				}
				const region=ip+' '+addr+' @'+ruleSets[r.id]+'v'+family+' ';
				if (r.action=='allow') {
					push(lines,matchText+region+'counter name a'+r.id+' return');
					// 记录与丢弃拆成两条规则：limit 是匹配表达式，写在 drop 前面
					// 会让超出速率的包直接跳过整条规则 —— 既不丢也不记。
					// drop 保持无条件，作为"不在允许地区内"的兜底，不要加地址条件。
					push(lines,matchText+'meta nfproto '+(family==4?'ipv4':'ipv6')+' '+ip+' '+addr+' != @'+ruleSets[r.id]+'v'+family+' limit rate 10/second burst 20 packets limit name audit log prefix "CSG:'+r.id+' "');
					push(lines,matchText+'meta nfproto '+(family==4?'ipv4':'ipv6')+' counter name b'+r.id+' drop');
				} else {
					push(lines,matchText+region+'limit rate 10/second burst 20 packets limit name audit log prefix "CSG:'+r.id+' "');
					push(lines,matchText+region+'counter name b'+r.id+' drop');
				}
			}
		}
		push(lines,'}');
	}
	push(lines,'chain input_gate { type filter hook input priority -5; policy accept;');
	const control='meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } return';
	push(lines,control,'udp sport 67 udp dport 68 return');
	push(lines,'iifname @wan ct state { new, untracked } jump input_rules','}');
	push(lines,'chain forward_gate { type filter hook forward priority -5; policy accept;');
	push(lines,control,'iifname @lan oifname @wan ct state { new, untracked } jump outgoing_rules','iifname @wan oifname @lan ct state { new, untracked } jump incoming_rules','}','}');
	return join('\n',lines)+'\n';
}
function installGuard(text) { writeText('/tmp/console-security-check.nft',text); exec(['/usr/sbin/nft','-c','-f','/tmp/console-security-check.nft']); exec(['/usr/sbin/nft','-f','/tmp/console-security-check.nft']); writeText(GUARD,text); }
function guardExists() { return match(output(['/usr/sbin/nft','list','tables']),/table inet console_guard(\n|$)/)!=null; }
function pending() { const p=readJson(PENDING,null); if(!p) return null;const remaining=p.boot==BOOT && p.uptimeDeadline ? p.uptimeDeadline-uptime() : p.deadline-time();return { deadline:p.deadline,secondsLeft:int(max(0,remaining)+0.999) }; }
function applyPolicy(input) {
	ensure(); return withLock(() => {
		if (pending()) fail('请先确认或回滚上一项变更');
		if (+input.revision!=(+(config().revision || 0))) fail('规则已被其他页面修改，请刷新后重试');
		const validated=validate(input), text=compileGuard(validated);
		validated.revision=(+(config().revision || 0))+1;
		writeText('/tmp/console-security-check.nft',text); exec(['/usr/sbin/nft','-c','-f','/tmp/console-security-check.nft']);
		writeJson(ROOT+'/previous.json',config()); writeText(ROOT+'/previous.nft',readfile(GUARD) || compileGuard(config()));
		// Persist rollback intent before applying, so service/browser failure is recoverable.
		writeJson(PENDING,{deadline:time()+120,boot:BOOT,uptimeDeadline:uptime()+120});
		installGuard(text); writeJson(ROOT+'/config.json',validated);
		system(['/bin/sh','-c','(sleep 121; /usr/bin/ucode /usr/sbin/console-security-control.uc expire) >/tmp/console-security-guard.log 2>&1 &']);
		return {ok:true,pending:pending()};
	});
}
function confirmPolicy() { return withLock(() => { const p=pending(); if (p && p.secondsLeft<=0) fail('确认窗口已过期，请等待回滚'); unlink(PENDING); return {ok:true}; }); }
function rollbackPolicy(expiredOnly) {
	const p=pending(); if (!p || (expiredOnly && p.secondsLeft>0)) return {ok:true};
	return withLock(() => { installGuard(readfile(ROOT+'/previous.nft') || compileGuard({rules:[],allowIPs:[],blockIPs:[]})); writeJson(ROOT+'/config.json',readJson(ROOT+'/previous.json',{rules:[],allowIPs:[],blockIPs:[]})); unlink(PENDING); return {ok:true}; });
}
function refreshGuard(db) { return withLock(() => { if (pending()) fail('网络规则待确认，暂不更新数据库或接口绑定'); const text=compileGuard(config(),db); if (text!=readfile(GUARD) || !guardExists()) installGuard(text); }); }
function ensureGuard() { if(guardExists()) return; return withLock(()=>{if(!guardExists()) installGuard(readfile(GUARD) || compileGuard(config()));}); }
function activateGeo(meta) {
	return withLock(() => {
		if(pending()) fail('规则正在确认，请稍后更新数据库');
		if(!match(meta.file || '',/^geo-[0-9-]+\.db$/)) fail('地区库文件名无效');
		const previous=readfile(GUARD), text=compileGuard(config(),DATA+'/'+meta.file);
		installGuard(text);
		try {writeJson(DATA+'/geo.json',meta);} catch(e) {if(previous) installGuard(previous);die(e.message);}
	});
}
function startGeo() {
	ensure(); if (pending()) fail('请先确认网络规则变更');
	const job=readJson('/tmp/console-geo-job.json',{}), proc=job.pid?split(readfile('/proc/'+job.pid+'/stat') || '', ' '):[];
	if (job.running && ((length(proc) && proc[21]==job.processStart) || (!job.pid && time()-job.started<15))) return {ok:true,alreadyRunning:true};
	writeJson('/tmp/console-geo-job.json',{running:true,started:time(),message:'正在下载地区数据库'});
	system(['/bin/sh','-c','/usr/bin/ucode /usr/sbin/console-geo-update.uc >/tmp/console-geo-update.log 2>&1 &']);
	return {ok:true};
}
function initializeDatabase() {
	ensure(); sqlExec('PRAGMA journal_mode=WAL; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA max_page_count=25600; CREATE TABLE IF NOT EXISTS samples(step INTEGER,ts INTEGER,device TEXT,up INTEGER,down INTEGER,tcpup INTEGER,tcpdown INTEGER,udpup INTEGER,udpdown INTEGER,otherup INTEGER,otherdown INTEGER,PRIMARY KEY(step,ts,device)) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS samples_device ON samples(device,step,ts); CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY,data TEXT); CREATE TABLE IF NOT EXISTS protocol(step INTEGER,ts INTEGER,tcp INTEGER,udp INTEGER,icmp INTEGER,other INTEGER,PRIMARY KEY(step,ts)) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS protocol_ts ON protocol(ts); CREATE TABLE IF NOT EXISTS events(ts INTEGER,kind TEXT,rule TEXT,src TEXT,dst TEXT,proto TEXT,spt TEXT,dport TEXT,PRIMARY KEY(ts,src,rule,dport)) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS events_ts ON events(ts);');
}
function state() {
	const snap=readJson('/tmp/console-security-state.json',{}), meta=geoMeta(), job=readJson('/tmp/console-geo-job.json',{});
	if(job.running && job.pid) {const p=split(readfile('/proc/'+job.pid+'/stat') || '', ' ');if(!length(p) || p[21]!=job.processStart) {job.running=false;job.ok=false;job.message='数据库更新任务已中断，可以重新更新';}}
	const cfg=config(); const countries=meta?.countries || [];
	return {ok:true,config:cfg,pending:pending(),geo:meta,geoJob:job,countries,storage:storage(),snapshot:snap,stale:!snap.time || time()-snap.time>20};
}
function history(device, seconds, db) {
	if (device!='all' && !match(device || '',/^(ip:[0-9a-fA-F:.]+|[0-9a-f]{2}(:[0-9a-f]{2}){5})$/)) fail('设备标识无效');
	seconds=int(+seconds); if (index([3600,86400,604800],seconds)<0) fail('历史范围无效');
	const bucket=seconds==3600?60:seconds==86400?300:1800;
	const where='ts>='+int(time()-seconds)+(device=='all'?'':' AND device='+sq(device));
	const rows=query('SELECT (ts/'+bucket+')*'+bucket+' AS time,SUM(up) AS upload,SUM(down) AS download,SUM(tcpup+tcpdown) AS tcp,SUM(udpup+udpdown) AS udp,SUM(otherup+otherdown) AS other FROM samples WHERE '+where+' GROUP BY time ORDER BY time LIMIT 600;',db);
	return {ok:true,points:rows,bucket,seconds};
}
// 协议流量合计：采集器每 60 秒把 TCP/UDP/ICMP/其他的字节增量写入 protocol 表，
// 这里按 30 分钟、1 小时、1 天三个窗口求和，页面刷新、重开浏览器都不会清零。
function protocol(db) {
	const now = time(), totals = {};
	for (let seconds in [1800, 3600, 86400]) {
		const row = query('SELECT SUM(tcp) AS tcp,SUM(udp) AS udp,SUM(icmp) AS icmp,SUM(other) AS other FROM protocol WHERE ts>=' + int(now - seconds) + ';', db)[0] || {};
		totals['' + seconds] = [ int(row.tcp || 0), int(row.udp || 0), int(row.icmp || 0), int(row.other || 0) ];
	}
	return { ok: true, updated: now, totals };
}
function stampText(ts) {
	const t = localtime(+ts); return sprintf('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}
function logs() {
	let rows = [];
	try { rows = query('SELECT ts,kind,rule,src,dst,proto,spt,dport FROM events ORDER BY ts DESC LIMIT 200;'); } catch (e) { rows = []; }
	const lines = [];
	for (let r in rows) push(lines, stampText(r.ts) + ' ' + (r.kind == 'threat' ? 'CST' : 'CSG') + ':' + (r.rule || '') + ' SRC=' + (r.src || '') + ' DST=' + (r.dst || '') + ' PROTO=' + (r.proto || '') + (r.dport ? ' DPT=' + r.dport : ''));
	return { ok: true, lines };
}
const BLOCKED_LIMIT = 500;
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
function logStamp(when) {
	const m = match(when, /^(\w{3}) (\w{3}) +(\d{1,2}) (\d{1,2}):(\d{2}):(\d{2})$/);
	if (!m) return null;
	const mon = index(MONTHS, m[2]); if (mon < 0) return null;
	const now = time(), days = int(now / 86400);
	// syslog 时间不含年份和时区：按昨天/今天/明天的月日匹配 UTC 日，再用 localtime 与 gmtime 的差值修正时区。
	const g = gmtime(now), l = localtime(now);
	const tzOffset = (l.year * 31536000 + l.mon * 2592000 + l.mday * 86400 + l.hour * 3600 + l.min * 60 + l.sec) - (g.year * 31536000 + g.mon * 2592000 + g.mday * 86400 + g.hour * 3600 + g.min * 60 + g.sec);
	for (let back = 1; back >= -1; back--) {
		const base = (days - back) * 86400, day = gmtime(base);
		if (day.mon != mon + 1 || day.mday != +m[3]) continue;
		const stamp = base + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]) + tzOffset;
		return stamp > now + 120 ? null : stamp;
	}
	return null;
}
function blockedEntries() {
	let rows = [];
	try { rows = query('SELECT ts AS stamp,rule,src,dst,proto,dport FROM events WHERE kind=' + sq('region') + ' ORDER BY ts DESC LIMIT ' + BLOCKED_LIMIT + ';'); } catch (e) { rows = []; }
	const entries = [];
	for (let r in rows) push(entries, { when: stampText(r.stamp), stamp: r.stamp, rule: r.rule || '', src: r.src || '', dst: r.dst || '', proto: lc(r.proto || ''), dport: r.dport || '' });
	return entries;
}
function blocked() {
	const entries = blockedEntries();
	const groups = {}, bindings = readJson('/tmp/console-security-bindings.json', {});
	const stateDevices = readJson('/tmp/console-security-state.json',{}).devices || [];
	const rules = {};
	for (let r in config().rules || []) rules[r.id] = r.name;
	const geoCache = {}, nameCache = {};
	function nameOf(mac) { if (!(mac in nameCache)) { const d = filter(stateDevices, v=>v.mac==mac || v.id==mac)[0]; nameCache[mac] = (d && (d.name || d.mac)) || mac; } return nameCache[mac]; }
	function deviceForIP(ip) {
		const parsed = ipKey(ip); if (!parsed) return null;
		for (let mac, ips in bindings) for (let addr in ips) { const p = ipKey(addr); if (p && p.family == parsed.family && p.key == parsed.key) return mac; }
		return null;
	}
	const list = [];
	for (let e in entries) {
		if (!groups[e.src]) groups[e.src] = {src: e.src, count: 0, first: null, last: null, country: null, internal: false, targets: {}, rules: {}};
		const g = groups[e.src];
		g.count++;
		if (e.stamp != null) { if (g.first == null || e.stamp < g.first) g.first = e.stamp; if (g.last == null || e.stamp > g.last) g.last = e.stamp; }
		if (!(e.src in geoCache)) geoCache[e.src] = geoLookup(e.src);
		g.country = geoCache[e.src].country;
		g.internal = geoCache[e.src].internal;
		const mac = deviceForIP(e.dst);
		if (!g.targets[e.dst]) g.targets[e.dst] = {ip: e.dst, mac: mac || '', count: 0};
		g.targets[e.dst].count++;
		g.rules[e.rule] = (g.rules[e.rule] || 0) + 1;
	}
	for (let src, g in groups) {
		const ruleNames = [];
		for (let id, n in g.rules) push(ruleNames, rules[id] || id);
		const targetList = [];
		for (let ip, t in g.targets) push(targetList, {ip: t.ip, mac: t.mac, name: t.mac ? nameOf(t.mac) : '', count: t.count});
		push(list, {src, count: g.count, first: g.first, last: g.last, country: g.country, internal: g.internal, targets: sort(targetList, (a,b)=>b.count-a.count), rules: ruleNames});
	}
	const sorted = sort(list, (a,b)=>b.count-a.count);
	let packets = 0;
	try { packets = +(query('SELECT SUM(total) AS n FROM rule_hits;')[0]?.n || 0); } catch (e) {}
	return {ok:true, groups: sorted, total: length(entries), packets, recent: slice(entries, 0, 100)};
}
function preview(input) {
	const cfg=validate(input.config || config()), lookup=geoLookup(input.ip);
	if(!lookup.available) fail('请先完成地区库下载');
	if(index(['input','incoming','outgoing'],input.direction)<0 || index(['tcp','udp','icmp','ipv6-icmp'],input.protocol)<0) fail('预览方向或协议无效');
	if((input.protocol=='tcp' || input.protocol=='udp') && (+input.port<1 || +input.port>65535)) fail('目标端口必须在1至65535之间');
	for(let range in cfg.allowIPs) if(inCIDR(input.ip,range)) return {...lookup,action:'pass',reason:'命中优先允许IP例外'};
	for(let range in cfg.blockIPs) if(inCIDR(input.ip,range)) return {...lookup,action:'block',reason:'命中阻止IP例外'};
	if(lookup.internal) return {...lookup,action:'pass',reason:'属于配置的内部网络，跳过地区规则'};
	for(let r in cfg.rules) if(r.enabled && r.direction==input.direction && (r.device=='all' || r.device==input.device) && (r.protocol=='all' || r.protocol==input.protocol)) {
		let portMatch=!length(r.ports);
		for(let p in length(r.ports)?split(r.ports,','):[]) { const range=split(p,'-'); if(+input.port>=+range[0] && +input.port<=+(range[1] || range[0])) portMatch=true; }
		if(!portMatch) continue;
		const matches=index(r.countries,lookup.country)>=0;
		if(r.action=='allow') return {...lookup,action:matches?'pass':'block',reason:'命中白名单规则：'+r.name,rule:r.id};
		if(matches) return {...lookup,action:'block',reason:'命中阻止规则：'+r.name,rule:r.id};
	}
	return {...lookup,action:'pass',reason:'未命中地区阻止规则；仍需通过原有防火墙'};
}

export { ROOT,DATA,DB,GUARD,config,geoMeta,geoPath,geoLookup,isInternalIPv4,ipKey,inCIDR,parseConnection,sh,sq,command,output,exec,query,sqlExec,readJson,writeText,writeJson,ensure,storage,networkState,validate,compileGuard,installGuard,applyPolicy,confirmPolicy,rollbackPolicy,pending,refreshGuard,ensureGuard,activateGeo,startGeo,initializeDatabase,state,history,protocol,logs,blocked,preview };
