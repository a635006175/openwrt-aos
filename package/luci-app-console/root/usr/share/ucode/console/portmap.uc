// SPDX-License-Identifier: Apache-2.0
// Console model and generated fw4 redirects share one atomic UCI file.
import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, open, rename, unlink, mkdir, rmdir, stat, chmod } from 'fs';
import { ipKey, inCIDR, output, writeText, command } from 'console.security';
const CONFIG='/etc/config/firewall', LOCK='/tmp/console-portmap.lock', BACKUP='/etc/console-backup/portmap.firewall.last-good', PENDING='/etc/console-backup/portmap.pending', REFLECTION='/etc/console-portmap-reflection.nft', SETS='/etc/console-portmap-sets.nft';
function fail(s){die(s+'\n');}
function array(v){return type(v)=='array'?v:v?[v]:[];}
function ipv4(s){return ipKey(s)?.family==4;}
function number(s){let n=0;for(let p in split(s,'.'))n=n*256+(+p);return n;}
function textIP(n){return join('.',map([16777216,65536,256,1],d=>''+(int(n/d)%256)));}
function address(s){let n=number(s);return n>0 && n<3758096384 && substr(s,0,4)!='127.';}
function ports(value){
	if(type(value)!='string'||length(value)>400)fail('端口格式不正确');let parts=[];
	for(let s in split(replace(value,/\s/g,''),',')){const m=match(s,/^(\d{1,5})(-(\d{1,5}))?$/);if(!m)fail('端口支持单个数字或起始-结束，多个用英文逗号分隔');const a=+m[1],b=m[3]?+m[3]:a;if(a<1||b>65535||a>b)fail('端口范围必须在1-65535内，起始不能大于结束');for(let p in parts)if(a<=p.end&&b>=p.start)fail('同一规则的端口段不能重叠');push(parts,{start:a,end:b,text:a==b?''+a:a+'-'+b});}
	if(!length(parts)||length(parts)>16)fail('最多支持16个端口或连续端口范围');return parts;
}
function source(value){
	if(type(value)!='string')fail('允许访问IP格式不正确');const s=trim(value),range=split(s,'-'),cidr=split(s,'/');
	if(length(range)==2&&ipv4(range[0])&&ipv4(range[1])&&number(range[0])<=number(range[1]))return s;
	if(length(cidr)==2&&ipv4(cidr[0])&&match(cidr[1],/^\d{1,2}$/)&&+cidr[1]<=32){let size=1;for(let i=+cidr[1];i<32;i++)size*=2;return textIP(int(number(cidr[0])/size)*size)+'/'+(+cidr[1]);}
	if(ipv4(s))return s;fail('允许访问IP仅支持IPv4、CIDR或起始IP-结束IP：'+s);
}
function topology(){
	const u=cursor(),bus=connect(),dump=bus?.call('network.interface','dump',{})?.interface||[];bus?.disconnect();let zones=[],wans=[],lans=[];
	u.foreach('firewall','zone',z=>push(zones,{name:z.name,network:array(z.network),masq:z.masq=='1'}));
	for(let d in dump){if(d.interface=='loopback')continue;let zone=null;for(let z in zones)if(index(z.network,d.interface)>=0)zone=z; if(!zone)continue;
		const item={name:d.interface,zone:zone.name,up:!!d.up,addresses:map(d['ipv4-address']||[],a=>a.address),subnets:map(d['ipv4-address']||[],a=>a.address+'/'+a.mask)};
		if(zone.name=='wan'||zone.masq){if(d.proto!='dhcpv6'&&(length(item.addresses)||index(['dhcp','pppoe','static'],d.proto)>=0))push(wans,item);}else if(zone.name=='lan'||match(d.interface,/^lan/))push(lans,item);
	}return {wans,lans};
}
function model(u){let data={revision:0,rules:[],groups:[]};const raw=u.get('firewall','console_portmap','model');if(raw){try{data=json(raw);}catch(e){fail('端口映射配置损坏，请恢复备份');}}return data;}
function validate(data,top){
	if(type(data)!='object'||type(data.rules)!='array'||type(data.groups)!='array'||length(data.rules)>256||length(data.groups)>128)fail('最多支持256条映射、128个IP分组');
	let groups=[],ids={},rules=[];
	for(let g in data.groups){if(type(g.id)!='string'||!match(g.id,/^[a-zA-Z0-9_-]{1,48}$/)||ids[g.id]||type(g.name)!='string'||!length(trim(g.name))||length(g.name)>64||type(g.addresses)!='array'||!length(g.addresses)||length(g.addresses)>256)fail('IP分组格式不正确或ID重复');ids[g.id]=true;push(groups,{id:g.id,name:trim(g.name),addresses:uniq(map(g.addresses,source))});}
	ids={};let generated=0;
	for(let r in data.rules){
		if(type(r.id)!='string'||!match(r.id,/^[a-zA-Z0-9_-]{1,48}$/)||ids[r.id])fail('规则ID不正确或重复');ids[r.id]=true;
		if(!ipv4(r.internalIP)||!address(r.internalIP))fail('内网地址必须是有效单播IPv4');let dest=null;for(let lan in top.lans)for(let subnet in lan.subnets)if(inCIDR(r.internalIP,subnet)){const parts=split(subnet,'/');let size=1;for(let i=+parts[1];i<32;i++)size*=2;const n=number(r.internalIP),network=int(n/size)*size;if(+parts[1]<=30&&(n==network||n==network+size-1))fail('内网地址不能是网段地址或广播地址');dest=lan;} if(!dest||index(dest.addresses,r.internalIP)>=0)fail('内网地址必须属于本机内网网段，且不能是路由器自身地址');
		if(index(['tcp','udp','tcp+udp'],r.protocol)<0)fail('协议必须是TCP、UDP或TCP+UDP');if(index(['interface','ip'],r.type)<0)fail('映射类型不正确');
		if(r.type=='interface' && r.external!='any'&&!length(filter(top.wans,w=>w.name==r.external)))fail('外网接口不存在');if(r.type=='ip'&&(!ipv4(r.external)||!address(r.external)))fail('外网地址必须是有效IPv4');
		const inside=ports(r.internalPorts),outside=ports(r.externalPorts);
		if(length(inside)!=length(outside))fail('内外网端口段数量必须一致');if(length(inside)>1&&join(',',map(inside,p=>p.text))!=join(',',map(outside,p=>p.text)))fail('多段端口必须保持内外网端口一致');
		for(let i=0;i<length(inside);i++){if(inside[i].end-inside[i].start!=outside[i].end-outside[i].start)fail('内外网端口数量必须一致');generated+=inside[i].start==outside[i].start?1:inside[i].end-inside[i].start+1;}
		if(type(r.allowIPs)!='array'||length(r.allowIPs)>256||type(r.groups)!='array')fail('允许访问IP格式不正确');for(let g in r.groups)if(!length(filter(groups,x=>x.id==g)))fail('引用的IP分组不存在');
		if(type(r.comment)!='string'||length(r.comment)>120)fail('备注最多120个字符');if(type(r.enabled)!='bool')fail('启用状态不正确');
		push(rules,{id:r.id,internalIP:r.internalIP,internalPorts:join(',',map(inside,p=>p.text)),externalPorts:join(',',map(outside,p=>p.text)),protocol:r.protocol,type:r.type,external:r.external,allowIPs:uniq(map(r.allowIPs,source)),groups:uniq(r.groups),comment:r.comment,enabled:r.enabled});
	}
	if(generated>4096)fail('异号连续端口展开后最多4096条；大范围请使用内外网同号端口');return {revision:data.revision,rules,groups};
}
function resolvedSources(r,data){let a=[...r.allowIPs];for(let id in r.groups)for(let g in data.groups)if(g.id==id)a=[...a,...g.addresses];return uniq(a);}
function entries(data,top){let out=[];
	for(let r in data.rules){let dest=null;for(let l in top.lans)for(let s in l.subnets)if(inCIDR(r.internalIP,s))dest=l;
		let wans=r.type=='interface'&&r.external!='any'?filter(top.wans,w=>w.name==r.external):top.wans;const a=ports(r.internalPorts),b=ports(r.externalPorts),sources=resolvedSources(r,data);let bindings=[];for(let w in wans)for(let ip in r.type=='ip'?[r.external]:length(w.addresses)?w.addresses:['0.0.0.0'])push(bindings,{...w,selectedIP:ip});wans=bindings;
		// No zone-wide interface matching: explicitly bind each WAN logical network.
		for(let w in wans)for(let i=0;i<length(a);i++){
			const identical=a[i].start==b[i].start;for(let j=0;j<(identical?1:a[i].end-a[i].start+1);j++){
				let options={name:'Console portmap '+r.id,enabled:r.enabled?'1':'0',target:'DNAT',family:'ipv4',src:w.zone,dest:dest.zone,dest_ip:r.internalIP,proto:r.protocol=='tcp+udp'?['tcp','udp']:r.protocol,src_dport:identical?b[i].text:''+(b[i].start+j),reflection:'1',reflection_src:'internal',reflection_zone:uniq(map(top.lans,l=>l.zone))};
				if(!identical||a[i].start==a[i].end)options.dest_port=''+(a[i].start+j);if(r.type=='ip')options.src_dip=r.external;
				// Interface hotplug regenerates address matches after DHCP/PPPoE changes.
				else {options.src_dip=w.selectedIP;if(!length(w.addresses)||!w.up)options.enabled='0';}if(length(sources))options.ipset='cpm_src_'+r.id;
				push(out,{section:'cpm_'+length(out),options,rule:r.id});
			}
		}
	}if(length(out)>8192)fail('生成规则过多，请减少范围或外网接口');return out;
}
function conflicts(data,top,u){
	let listeners=[];for(let proto in ['tcp','udp'])for(let line in split(output(['/bin/netstat',proto=='tcp'?'-lnt':'-lnu']), '\n')){const f=split(trim(line),/\s+/);if(f[0]!=proto)continue;const m=match(f[3]||'',/^(\d+\.\d+\.\d+\.\d+):(\d+)$/);if(m)push(listeners,{protocol:proto,ip:m[1],port:+m[2]});}
	let existing=[];u.foreach('firewall','redirect',r=>{if(!match(r['.name'],/^cpm_/) && r.enabled!='0')push(existing,r);});
	for(let r in data.rules){if(!r.enabled)continue;const ranges=ports(r.externalPorts),protos=r.protocol=='tcp+udp'?['tcp','udp']:[r.protocol];let selected=r.type=='interface'&&r.external!='any'?filter(top.wans,w=>w.name==r.external):top.wans;
		for(let p in listeners)if(index(protos,p.protocol)>=0&&length(filter(ranges,v=>p.port>=v.start&&p.port<=v.end))&&(p.ip=='0.0.0.0'||r.type=='ip'&&r.external==p.ip||length(filter(selected,w=>index(w.addresses,p.ip)>=0))))fail('外网端口与路由器本机服务冲突：'+p.protocol+'/'+p.port+'，请更换端口');
		for(let old in existing){if(index(map(selected,w=>w.zone),old.src)<0)continue;const ps=array(old.proto);if(!length(filter(protos,p=>index(ps,p)>=0||index(ps,'tcp udp')>=0||!length(ps))))continue;try{for(let p in ports(replace(join(',',array(old.src_dport)),/:/g,'-')))for(let q in ranges)if(p.start<=q.end&&q.start<=p.end)fail('与原有端口转发冲突：'+(old.name||old['.name']));}catch(e){if(index(e.message,'与原有')>=0)die(e.message);}}
	}
	for(let i=0;i<length(data.rules);i++)for(let j=i+1;j<length(data.rules);j++){const a=data.rules[i],b=data.rules[j];if(!a.enabled||!b.enabled||a.protocol!=b.protocol&&a.protocol!='tcp+udp'&&b.protocol!='tcp+udp')continue;if(a.type=='interface'&&b.type=='interface'&&a.external!='any'&&b.external!='any'&&a.external!=b.external)continue;if(a.type=='ip'&&b.type=='ip'&&a.external!=b.external)continue;for(let x in ports(a.externalPorts))for(let y in ports(b.externalPorts))if(x.start<=y.end&&y.start<=x.end)fail('启用的规则外网端口重叠，请修改或先停用原规则');}
}
function state(){const u=cursor(),data=model(u),top=topology();let foreign=[];u.foreach('firewall','redirect',r=>{if(!match(r['.name'],/^cpm_/))push(foreign,{name:r.name||r['.name'],enabled:r.enabled!='0'});});return {...data,...top,foreign};}
function reflectionFilter(data,top){let lines=['# Generated source restrictions for NAT loopback.'];for(let r in data.rules){if(!r.enabled||!length(resolvedSources(r,data)))continue;let ips=r.type=='ip'?[r.external]:[];if(r.type=='interface')for(let w in top.wans)if(r.external=='any'||r.external==w.name)ips=[...ips,...w.addresses];if(!length(ips))continue;for(let proto in r.protocol=='tcp+udp'?['tcp','udp']:[r.protocol])for(let port in ports(r.externalPorts))push(lines,'ip daddr { '+join(', ',uniq(ips))+' } '+proto+' dport '+port.text+' ip saddr != @cpm_src_'+r.id+' counter return');}return join('\n',lines)+'\n';}
function sourceSets(data){let lines=['# Replace static source sets atomically; fw4 otherwise retains removed entries.'],wanted=[];for(let r in data.rules){const sources=resolvedSources(r,data);if(!length(sources))continue;const name='cpm_src_'+r.id;push(wanted,name);push(lines,'flush set inet fw4 '+name);push(lines,'add element inet fw4 '+name+' { '+join(', ',sources)+' }');}let existing={};try{existing=json(output(['/usr/sbin/nft','-j','list','sets']));}catch(e){}for(let item in existing.nftables||[]){const s=item.set;if(s?.family=='inet'&&s.table=='fw4'&&match(s.name,/^cpm_src_[a-zA-Z0-9_-]+$/)&&index(wanted,s.name)<0)push(lines,'destroy set inet fw4 '+s.name);}return join('\n',lines)+'\n';}
// Enumerate the external bindings an enabled model actually exposes, keyed so
// that a change of external port, external address or backend target all count
// as a different binding. Only used to decide which conntrack entries to drop.
function exposed(data,top){
	let out=[];
	for(let r in data.rules){
		if(!r.enabled)continue;
		let ips=r.type=='ip'?[r.external]:[];
		if(r.type!='ip'){const wans=r.external!='any'?filter(top.wans,w=>w.name==r.external):top.wans;for(let w in wans)for(let ip in w.addresses)push(ips,ip);}
		ips=uniq(ips);if(!length(ips))continue;
		const a=ports(r.internalPorts),b=ports(r.externalPorts),protos=r.protocol=='tcp+udp'?['tcp','udp']:[r.protocol];
		for(let i=0;i<length(a);i++)for(let j=0;j<=a[i].end-a[i].start;j++){
			const inside=a[i].start+j,outside=a[i].start==b[i].start?inside:b[i].start+j;
			for(let ip in ips)for(let proto in protos)
				push(out,{key:proto+'|'+ip+'|'+outside+'|'+r.internalIP+'|'+inside,proto,ip,outside});
		}
	}
	return out;
}
// Drop connections that were established through bindings which the new model no
// longer exposes, so that disabling or repointing a rule takes effect for
// already-established flows too. The destination filter keeps this precise:
// outbound flows carry a remote destination and are therefore never touched.
function flushStale(before,after){
	if(!stat('/usr/sbin/conntrack'))return {deleted:0,flushed:0,skipped:true};
	const keep={};for(let t in after)keep[t.key]=true;
	const done={},flushed=[];let deleted=0;
	for(let t in before){
		if(keep[t.key])continue;
		const name=t.proto+' '+t.ip+' '+t.outside;
		if(done[name])continue;
		done[name]=true;push(flushed,name);
		output(['/usr/sbin/conntrack','-D','-p',t.proto,'-d',t.ip,'--dport',''+t.outside]);
		deleted++;
	}
	return {deleted,flushed,skipped:false};
}
// Best-effort wrapper: a malformed previous model must never break an apply.
function flushModelChange(old,next,top){
	let before=[];try{before=exposed(old,top);}catch(e){return {deleted:0,flushed:[],skipped:true};}
	return flushStale(before,exposed(next,top));
}
function recover(){if(!stat(PENDING))return false;const old=readfile(BACKUP);if(!old)fail('端口映射恢复备份缺失');let pending={};try{pending=json(readfile(PENDING));}catch(e){}writeText(REFLECTION,pending.reflection||'# Empty\n');writeText(SETS,pending.sets||'# Empty\n');writeText(CONFIG,old);chmod(CONFIG,0600);if(stat('/var/run/fw4.state')&&system(['/sbin/fw4','reload'])!=0)fail('端口映射恢复失败');unlink(PENDING);return true;}
function apply(data){
	if(!mkdir(LOCK,0700)){const pid=+(readfile(LOCK+'/pid')||'0');if(pid>0&&stat('/proc/'+pid))fail('其他端口映射操作正在进行');unlink(LOCK+'/pid');rmdir(LOCK);if(!mkdir(LOCK,0700))fail('端口映射配置被锁定');}writeText(LOCK+'/pid',split(readfile('/proc/self/stat'),' ')[0]);
	try{
		recover();if(length(trim(output(['/sbin/uci','changes','firewall']))))fail('原防火墙有尚未提交的修改，请先保存或放弃');const before=readfile(CONFIG),u=cursor(),old=model(u),top=topology();if(data.revision!=old.revision)fail('配置已被其他页面修改，请刷新后重试');const next=validate(data,top);conflicts(next,top,u);const generated=entries(next,top);
		let remove=[];for(let type in ['redirect','ipset','include'])u.foreach('firewall',type,r=>{if(match(r['.name'],/^cpm_/))push(remove,r['.name']);});for(let id in remove)u.delete('firewall',id);
		for(let r in next.rules){const sources=resolvedSources(r,next);if(!length(sources))continue;const id='cpm_src_'+r.id;u.set('firewall',id,'ipset');u.set('firewall',id,'name',id);u.set('firewall',id,'family','ipv4');u.set('firewall',id,'match','src_net');}
		for(let e in generated){u.set('firewall',e.section,'redirect');for(let key,value in e.options)if(type(value)=='array'?length(value):value!=null)u.set('firewall',e.section,key,value);}
		next.revision=old.revision+1;u.set('firewall','console_portmap','console_portmap');u.set('firewall','console_portmap','model',sprintf('%J',next));
		for(let zone in uniq(map(top.lans,l=>l.zone))){const id='cpm_reflect_'+zone;u.set('firewall',id,'include');for(let k,v in {type:'nftables',position:'chain-pre',chain:'dstnat_'+zone,path:REFLECTION})u.set('firewall',id,k,v);}
		u.set('firewall','cpm_source_sync','include');for(let k,v in {type:'nftables',position:'ruleset-post',path:SETS})u.set('firewall','cpm_source_sync',k,v);
		if(readfile(CONFIG)!=before)fail('防火墙被其他操作修改，请重试');mkdir('/etc/console-backup',0700);writeText(BACKUP,before);writeText(PENDING,sprintf('%J',{time:time(),revision:next.revision,reflection:readfile(REFLECTION)||'',sets:readfile(SETS)||''}));writeText(REFLECTION,reflectionFilter(next,top));writeText(SETS,sourceSets(next));
		if(!u.commit('firewall'))fail('保存防火墙配置失败');
		if(system('/sbin/fw4 check >/tmp/console-portmap-check.log 2>&1')!=0)fail('防火墙校验失败：'+substr(readfile('/tmp/console-portmap-check.log')||'',0,800));
		if(match(readfile('/tmp/console-portmap-check.log')||'',/Section cpm_.*(invalid|skipped|unknown|ignoring invalid)/))fail('生成的映射未通过防火墙解析');
		if(system('/sbin/fw4 reload >/tmp/console-portmap-check.log 2>&1')!=0)fail('加载防火墙失败：'+substr(readfile('/tmp/console-portmap-check.log')||'',0,800));const flushed=flushModelChange(old,next,top);unlink(PENDING);unlink(LOCK+'/pid');rmdir(LOCK);const result=state();result.flushed=flushed;return result;
	}catch(e){try{recover();}catch(rollback){unlink(LOCK+'/pid');rmdir(LOCK);fail(e.message+'；'+rollback.message);}unlink(LOCK+'/pid');rmdir(LOCK);die(e.message);}
}
export { ports,source,validate,entries,resolvedSources,topology,state,apply,recover,exposed,flushModelChange };
