// SPDX-License-Identifier: Apache-2.0
import { ipKey,inCIDR,validate,preview,geoLookup,compileGuard,writeText } from 'console.security';
function assert(value,message) { if(!value) die(message); }
function invalid(fn) { let rejected=false;try {fn();}catch(e){rejected=true;}assert(rejected,'malformed policy accepted'); }
assert(inCIDR('192.168.1.23','192.168.1.0/24'),'IPv4 CIDR match');
assert(!inCIDR('192.168.2.1','192.168.1.0/24'),'IPv4 CIDR exclusion');
assert(inCIDR('192.168.1.127','192.168.1.0/25') && !inCIDR('192.168.1.128','192.168.1.0/25'),'IPv4 partial-byte prefix');
assert(inCIDR('2001:db8:abcd::1','2001:db8::/32'),'IPv6 CIDR match');
assert(!inCIDR('2001:db9::1','2001:db8::/32'),'IPv6 CIDR exclusion');
assert(inCIDR('2001:db8:7fff::1','2001:db8::/33') && !inCIDR('2001:db8:8000::1','2001:db8::/33'),'IPv6 partial-byte prefix');
assert(geoLookup('8.8.8.8').country=='US','IPv4 geography');
assert(match(geoLookup('2001:4860:4860::8888').country || '',/^[A-Z]{2}$/),'IPv6 geography resolution');
const rule={id:'test1',name:'隔离测试规则',enabled:true,direction:'input',action:'block',protocol:'tcp',ports:'443,1000-2000',device:'all',countries:['US']};
const c=validate({rules:[rule],allowIPs:[],blockIPs:[]});
assert(preview({config:c,ip:'8.8.8.8',direction:'input',protocol:'tcp',port:443,device:'all'}).action=='block','block preview');
assert(preview({config:c,ip:'8.8.8.8',direction:'input',protocol:'tcp',port:80,device:'all'}).action=='pass','port scoping');
assert(preview({config:c,ip:'8.8.8.8',direction:'outgoing',protocol:'tcp',port:443,device:'all'}).action=='pass','direction scoping');
c.allowIPs=['8.8.8.8/32'];assert(preview({config:c,ip:'8.8.8.8',direction:'input',protocol:'tcp',port:443,device:'all'}).action=='pass','allow exception');c.allowIPs=[];
c.rules[0].action='allow';assert(preview({config:c,ip:'8.8.8.8',direction:'input',protocol:'tcp',port:443,device:'all'}).action=='pass','allow-list match');
assert(preview({config:c,ip:'192.0.2.1',direction:'input',protocol:'tcp',port:443,device:'all'}).action=='block','allow-list unknown region rejection');
writeText('/tmp/console-security-allow-test.nft',compileGuard(c));
c.rules[0].action='block';c.rules[0].direction='outgoing';c.allowIPs=['192.0.2.0/24','2001:db8::/32'];c.blockIPs=['198.51.100.1'];
writeText('/tmp/console-security-block-test.nft',compileGuard(c));
invalid(()=>validate({rules:[{...rule,countries:['US;drop']}],allowIPs:[],blockIPs:[]}));
invalid(()=>validate({rules:[{...rule,ports:'70000'}],allowIPs:[],blockIPs:[]}));
invalid(()=>validate({rules:[{...rule,device:'bad-mac'}],allowIPs:[],blockIPs:[]}));
invalid(()=>preview({config:c,ip:'8.8.8.8',direction:'input',protocol:'tcp',port:-1,device:'all'}));
print('PASS geography, IPv4/IPv6 prefixes, allow/block, port/direction scopes and malformed input rejection\n');
// Compile against the real database, but replace device bindings for an isolated netns.
c.rules[0].direction='input';c.rules[0].protocol='all';c.rules[0].ports='';c.rules[0].countries=['US','CA'];c.allowIPs=[];c.blockIPs=[];
for(let action in ['allow','block']) {
	c.rules[0].action=action;
	let text=compileGuard(c);
	text=replace(text,/set wan \{[^\n]*\}/g,'set wan { type ifname; elements = { "lo" }; }');
	text=replace(text,/set lan \{[^\n]*\}/g,'set lan { type ifname; }');
	writeText('/tmp/console-security-netns-'+action+'.nft',text);
}
