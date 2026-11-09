// SPDX-License-Identifier: Apache-2.0
import { source,validate,nftPolicy } from 'console.mihomo-policy';
import { writeText } from 'console.security';
function check(v,m){if(!v)die(m+'\n');}
function rejects(fn){let rejected=false;try{fn();}catch(e){rejected=true;}check(rejected,'invalid input accepted');}
check(source('192.168.1.5/24').value=='192.168.1.0/24','IPv4 normalization');
check(source('fdab::123/64').value=='fdab:0000:0000:0000:0000:0000:0000:0000/64','IPv6 normalization');
rejects(()=>source('192.168.1.9-192.168.1.2'));rejects(()=>source('1.2.3.4;reboot'));rejects(()=>source('fdab::/129'));
rejects(()=>validate({mode:'include',addresses:[]}));
const addresses=['192.168.1.5','10.8.0.2','192.168.2.0/24','fdab::/64','192.168.1.20-192.168.1.30'];
for(let mode in ['all','include','exclude','none']){
	const p=validate({mode,addresses,revision:0}),text=nftPolicy(p,['br-lan','eth2','cvpns']);writeText('/tmp/console-mihomo-policy-check.nft',text);
	check(system(['/usr/sbin/nft','-c','-f','/tmp/console-mihomo-policy-check.nft'])==0,'nft validation '+mode);
	check(index(text,'cvpns')>=0&&index(text,'priority -150')>=0,'interfaces and routing hook');
}
print('PASS IPv4/IPv6/CIDR/ranges, validation and all four compiled nft policies\n');
