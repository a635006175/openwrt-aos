// SPDX-License-Identifier: Apache-2.0
import { ports,source,validate,entries,resolvedSources,topology } from 'console.portmap';
function assert(v,m){if(!v)die(m+'\n');}
function rejects(fn,m){let ok=false;try{fn();}catch(e){ok=true;}assert(ok,m);}
const top={wans:[{name:'wan',zone:'wan',up:true,addresses:['172.16.10.81']}],lans:[{name:'lan',zone:'lan',addresses:['192.168.1.1'],subnets:['192.168.1.1/24']}]};
const rule={id:'test',internalIP:'192.168.1.5',internalPorts:'80',externalPorts:'48080',protocol:'tcp',type:'interface',external:'wan',allowIPs:[],groups:[],comment:'test',enabled:true};
function data(r){return {revision:0,rules:[{...rule,...r}],groups:[]};}
assert(length(ports('80-100,443'))==2,'multi ports');rejects(()=>ports('80-100,90'),'overlap');rejects(()=>ports('0'),'zero');rejects(()=>ports('65536'),'overflow');rejects(()=>source('1.2.3.4; touch /tmp/bad'),'injection');assert(source('1.2.3.4-1.2.3.9')=='1.2.3.4-1.2.3.9','source range');
let d=validate(data({internalPorts:'80-82',externalPorts:'48080-48082',protocol:'tcp+udp'}),top),e=entries(d,top);assert(length(e)==3 && e[0].options.dest_port=='80'&&e[2].options.src_dport=='48082'&&e[2].options.dest_port=='82','offset sequential mapping');assert(e[0].options.src_dip=='172.16.10.81'&&length(e[0].options.proto)==2,'network selector + both protocols');
e=entries(validate(data({internalPorts:'80-100,443',externalPorts:'80-100,443'}),top),top);assert(length(e)==2&&!e[0].options.dest_port,'same range preserves original port');
rejects(()=>validate(data({internalPorts:'80-81',externalPorts:'48080-48082'}),top),'range cardinality');rejects(()=>validate(data({internalPorts:'80,443',externalPorts:'8080,8443'}),top),'multiple remapped segments');rejects(()=>validate(data({internalIP:'192.168.1.1'}),top),'router target');rejects(()=>validate(data({internalIP:'8.8.8.8'}),top),'non-LAN target');rejects(()=>validate(data({groups:['missing']}),top),'missing group');
d=data({groups:['office']});d.groups=[{id:'office',name:'office',addresses:['8.8.8.8','1.1.1.1/32']}];e=entries(validate(d,top),top);assert(e[0].options.ipset=='cpm_src_test','group source restriction');
assert(length(topology().wans)>0,'live topology');print('PASS ports, ranges, protocol, source/group restrictions, input validation, topology\n');
assert(source('192.168.1.5/24')=='192.168.1.0/24','canonical CIDR');rejects(()=>validate(data({internalIP:'192.168.1.255'}),top),'broadcast target');
