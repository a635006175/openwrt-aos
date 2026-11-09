// SPDX-License-Identifier: Apache-2.0
import { connect } from 'ubus';
import { cursor } from 'uci';
import { ipKey,readJson,inCIDR } from 'console.security';
import { readServerStatus } from 'console.vpn-status';
const PATH='/etc/console-mihomo/source-policy.json';
function fail(s){die(s+'\n');}
function textIP(key,family){if(family==4)return join('.',map([0,2,4,6],i=>''+int(substr(key,i,2),16)));return join(':',map([0,4,8,12,16,20,24,28],i=>substr(key,i,4)));}
function source(value){
	if(type(value)!='string'||length(value)>160)fail('IP格式不正确');value=trim(value);
	const range=split(value,'-');if(length(range)==2){const a=ipKey(range[0]),b=ipKey(range[1]);if(!a||!b||a.family!=b.family||a.key>b.key)fail('IP范围不正确：'+value);return {family:a.family,value:lc(value)};}
	const parts=split(value,'/'),ip=ipKey(parts[0]);if(!ip||length(parts)>2)fail('请输入IPv4、IPv6、CIDR或IP范围：'+value);
	if(length(parts)==1)return {family:ip.family,value:lc(value)};
	const bits=+parts[1];if(!match(parts[1],/^[0-9]{1,3}$/)||bits>(ip.family==4?32:128))fail('IP前缀不正确：'+value);
	let key='';for(let i=0;i<length(ip.key);i++){const keep=min(4,max(0,bits-i*4)),n=int(substr(ip.key,i,1),16),size=1<<(4-keep);key+=sprintf('%x',int(n/size)*size);}
	return {family:ip.family,value:textIP(key,ip.family)+'/'+bits};
}
function validate(input){
	if(type(input)!='object'||index(['all','include','exclude','none'],input.mode)<0||type(input.addresses)!='array'||length(input.addresses)>256)fail('来源策略格式不正确，最多256条地址');
	const addresses=uniq(map(input.addresses,a=>source(a).value));if(input.mode=='include'&&!length(addresses))fail('请至少选择或输入一个接管地址');
	return {mode:input.mode,addresses,revision:input.revision};
}
function policy(){return validate(readJson(PATH,{mode:'all',addresses:[],revision:0}));}
function devices(){
	const snapshot=readJson('/tmp/console-security-state.json',{}),items=[],names=[],ranges=[],own=[];let seen={};
	const c=cursor();c.foreach('firewall','zone',z=>{if(z.name=='lan')for(let name in type(z.network)=='array'?z.network:split(z.network||'',' '))push(names,name);});
	const bus=connect(),dump=bus?.call('network.interface','dump',{});bus?.disconnect();for(let d in dump?.interface||[])if(index(names,d.interface)>=0){for(let a in [...(d['ipv4-address']||[]),...(d['ipv6-address']||[]),...(d['ipv6-prefix-assignment']||[])])try{push(ranges,source(a.address+'/'+a.mask).value);push(own,a.address);}catch(e){}}

	for(let d in snapshot.devices||[])for(let ip in d.ips||[])if(ipKey(ip)?.family==4&&!seen[ip]&&index(own,ip)<0&&length(filter(ranges,r=>inCIDR(ip,r)))){seen[ip]=true;push(items,{ip,name:d.name||d.mac||'内网设备',interface:'LAN',online:!!d.online});}
	for(let c in readServerStatus('/var/run/console-vpn',time()).clients||[])if(c.virtualAddress&&ipKey(c.virtualAddress)?.family==4&&!seen[c.virtualAddress]){seen[c.virtualAddress]=true;push(items,{ip:c.virtualAddress,name:c.username,interface:'cvpns',online:true});}
	return items;
}
function localSubnets(){const bus=connect(),dump=bus?.call('network.interface','dump',{});bus?.disconnect();let result=[];
	for(let d in dump?.interface||[])if(d.up){for(let a in [...(d['ipv4-address']||[]),...(d['ipv6-address']||[]),...(d['ipv6-prefix-assignment']||[])])try{push(result,source(a.address+'/'+a.mask));}catch(e){}}
	return result;
}
function selectionRules(p){
	if(p.mode=='none')return 'return\n';if(p.mode=='all')return '';
	const op=p.mode=='include'?' != ':' ';
	return 'ip saddr'+op+'@sources4 return\nip6 saddr'+op+'@sources6 return\n';
}
function nftPolicy(p,interfaces){
	const set='{ '+join(', ',map(interfaces,d=>sprintf('%J',d)))+' }',parsed=map(p.addresses,source);let declarations='';
	for(let family in [4,6]){const values=map(filter(parsed,a=>a.family==family),a=>a.value);declarations+='set sources'+family+' { type ipv'+family+'_addr; flags interval; auto-merge;'+(length(values)?' elements = { '+join(', ',values)+' };':'')+' }\n';}
	const guard=selectionRules(p),locals=localSubnets();let exclude='fib daddr type local return\nip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return\nip6 daddr { ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 } return\n';
	for(let family in [4,6]){const values=uniq(map(filter(locals,a=>a.family==family),a=>a.value));if(length(values))exclude+=(family==4?'ip':'ip6')+' daddr { '+join(', ',values)+' } return\n';}
	return 'destroy table inet console_mihomo_dns\ntable inet console_mihomo_dns {\n'+declarations+
		'chain source_route { type filter hook prerouting priority -150; policy accept;\niifname != '+set+' return\nct status dnat ct direction reply counter return\n'+guard+exclude+'meta l4proto { tcp, udp } counter meta mark set 0x434d\n}\n'+
		'chain dns_lan { type nat hook prerouting priority -110; policy accept;\niifname != '+set+' return\nct status dnat ct direction reply counter return\n'+guard+'meta l4proto { tcp, udp } th dport 53 counter redirect to :1053\n}\n}\n';
}
export { PATH,source,validate,policy,devices,nftPolicy };
