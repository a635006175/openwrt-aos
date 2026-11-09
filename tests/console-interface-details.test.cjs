const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const base=path.resolve(__dirname,'../package/luci-app-console/htdocs/luci-static/resources/console');
const model=Function('baseclass',fs.readFileSync(path.join(base,'model.js'),'utf8'))({extend:x=>x});
const dashboard=Function('baseclass','model',fs.readFileSync(path.join(base,'dashboard.js'),'utf8'))({extend:x=>x},model);
const {snapshot}=require('../tools/console-preview/fixtures.js');
test('all interface rates include LAN while WAN upload/download remain independent',()=>{
 const state=model.createState(),a=snapshot(0),b=snapshot(1);
 const initial=model.ingest(state,a); assert.equal(initial.interfaceRates['br-lan'],null);
 const actual=model.ingest(state,b);
 assert.equal(actual.interfaceRates['br-lan'].rx,(b.devices['br-lan'].stats.rx_bytes-a.devices['br-lan'].stats.rx_bytes)/5);
 assert.equal(actual.upload,actual.interfaceRates.eth1.tx);
 assert.deepEqual(actual.interfaceRates.eth2,{rx:0,tx:0});
 const reset=snapshot(2); reset.devices['br-lan'].stats.rx_bytes=0;
 assert.equal(model.ingest(state,reset).interfaceRates['br-lan'],null);
 assert.equal(model.ingest(state,snapshot(3,reset.time+60)).interfaceRates['br-lan'],null);
});
test('details preserve all addresses, DNS, gateway, member links and device counters',()=>{
 const iface={interface:'lan',role:'LAN',deviceName:'br-lan',proto:'static',up:true,autostart:true,uptime:600,
  'ipv4-address':[{address:'192.168.1.1',mask:24},{address:'192.168.2.1',mask:24}],
  'ipv6-address':[{address:'2001:db8::1',mask:64}],
  'ipv6-prefix-assignment':[{address:'fd00::',mask:64,'local-address':{address:'fd00::1',mask:64}}],
  'dns-server':['1.1.1.1','2001:db8::53'],'dns-search':['example.test'],
  route:[{target:'0.0.0.0',mask:0,nexthop:'192.168.1.254'}]};
 const data={devices:{'br-lan':{bridge:true,ports:['eth0','eth2'],link:{carrier:true,speed:-1},mac:'02:00:00:00:00:01',mtu:1500,stats:{rx_bytes:1024,tx_bytes:2048,rx_errors:0,tx_errors:2},ip6addrs:[{address:'fe80::1'}]},
  eth0:{link:{carrier:true,speed:1000,duplex:'full'}},eth2:{link:{carrier:false,speed:1000}}},interfaceRates:{'br-lan':{rx:1024,tx:512}}};
 const details=Object.fromEntries(dashboard.interfaceDetails(iface,data));
 assert.match(details['IPv4 地址'],/192\.168\.1\.1\/24\n192\.168\.2\.1\/24/);
 assert.match(details['IPv6 地址'],/fd00::1\/64/); assert.match(details['IPv6 地址'],/fe80::1/);
 assert.equal(details['接口 DNS'],'1.1.1.1\n2001:db8::53');
 assert.equal(details['默认网关'],'192.168.1.254');
 assert.match(details['协商速率'],/桥接/);
 assert.match(details['成员网口'],/eth0 · 已连接 · 1,000 Mbps · 全双工/);
 assert.match(details['成员网口'],/eth2 · 未连接/);
 assert.equal(details['实时接收 / 发送'],'1.00 KB/s / 512 B/s');
 assert.equal(details['接收 / 发送错误'],'0 / 2');
});
test('unavailable and disconnected facts never become fabricated zero or negative rates',()=>{
 const iface={interface:'wan',role:'WAN',deviceName:'eth1',up:false,available:false};
 const details=Object.fromEntries(dashboard.interfaceDetails(iface,{devices:{eth1:{link:{carrier:false,speed:1000}}}}));
 assert.equal(details['接口状态'],'设备不可用'); assert.equal(details['物理链路'],'未连接');
 assert.equal(details['协商速率'],'未连接'); assert.equal(details['实时接收 / 发送'],'— / —');
 assert.equal(details['接口 DNS'],'未提供接口 DNS'); assert.equal(details['MAC / MTU'],'未提供 / 未提供');
});
