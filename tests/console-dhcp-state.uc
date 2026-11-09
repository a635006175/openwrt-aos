// SPDX-License-Identifier: Apache-2.0
// DHCP 地址池换算与校验逻辑测试。只测纯函数与只读路径，不写入 /etc/config/dhcp。
import { validate, normalizeMac, validIPv4, prefixToMask, maskToPrefix, leaseTimeSeconds, lanNetwork, currentState } from 'console.dhcp-state';

function check(value, message) { if (!value) die(message + '\n'); }
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }

// ---- IPv4 与掩码 ----
check(validIPv4('192.168.1.1'), 'validIPv4 拒绝了合法地址');
check(!validIPv4('192.168.1.256'), 'validIPv4 接受了越界地址');
check(!validIPv4('192.168.1.0 1'), 'validIPv4 接受了含空格的地址');
check(maskToPrefix('255.255.255.0') == 24, 'maskToPrefix /24 计算错误');
check(maskToPrefix('255.255.254.0') == 23, 'maskToPrefix /23 计算错误');
check(maskToPrefix('255.255.255.128') == 25, 'maskToPrefix /25 计算错误');
check(maskToPrefix('255.0.255.0') == null, 'maskToPrefix 接受了非连续掩码');
check(prefixToMask(24) == '255.255.255.0', 'prefixToMask /24 错误');
check(prefixToMask(23) == '255.255.254.0', 'prefixToMask /23 错误');

// ---- MAC 规范化 ----
check(normalizeMac('aa:bb:cc:dd:ee:ff') == 'AA:BB:CC:DD:EE:FF', 'MAC 大写规范化失败');
check(normalizeMac('AA-BB-CC-DD-EE-FF') == 'AA:BB:CC:DD:EE:FF', 'MAC 短横线规范化失败');
check(normalizeMac('aabbccddeeff') == 'AA:BB:CC:DD:EE:FF', 'MAC 无分隔符规范化失败');
check(normalizeMac('aa:bb:cc:dd:ee') == null, 'MAC 长度不足却通过');
check(normalizeMac('zz:bb:cc:dd:ee:ff') == null, 'MAC 含非法字符却通过');

// ---- 租期 ----
check(leaseTimeSeconds('12h') == 43200, '租期 12h 解析错误');
check(leaseTimeSeconds('1d') == 86400, '租期 1d 解析错误');
check(leaseTimeSeconds('30m') == 1800, '租期 30m 解析错误');
check(leaseTimeSeconds('120') == 120, '租期纯数字解析错误');
check(leaseTimeSeconds('abc') == null, '非法租期却解析成功');

// ---- 读取当前状态(只读, 不改配置) ----
const state = currentState();
check(type(state) == 'object', 'currentState 未返回对象');
check(type(state.lan) == 'object' && state.lan != null, 'currentState 缺少 LAN 信息');
check(validIPv4(state.lan.address), 'currentState 的 LAN 地址无效');
check(type(state.pool) == 'object' && state.pool != null, 'currentState 缺少地址池');
check(validIPv4(state.pool.startIP), '地址池起始 IP 无效');
check(validIPv4(state.pool.endIP), '地址池结束 IP 无效');
check(type(state.hosts) == 'array', 'currentState 的 hosts 不是数组');
print('当前地址池: ' + state.pool.startIP + ' - ' + state.pool.endIP + ', 租期 ' + state.leasetime + ', 启用=' + state.enabled + '\n');

// ---- 校验: 合法配置 ----
const good = {
	enabled: true, dynamicdhcp: true, force: false,
	startIP: '192.168.1.100', endIP: '192.168.1.249',
	gateway: '192.168.1.1', dns: ['223.5.5.5', '114.114.114.114'],
	leasetime: '12h', hosts: []
};
check(throws(() => validate(good)) == false, '合法配置被拒绝: ' + good.startIP);

function clone(base) { const o = {}; for (let k, v in base) o[k] = v; return o; }
function variant(overrides) { const o = clone(good); for (let k, v in overrides) o[k] = v; return o; }

// ---- 校验: 各类非法输入 ----
const bads = [
	['起始大于结束', variant({ startIP: '192.168.1.249', endIP: '192.168.1.100' })],
	['起始为网络地址', variant({ startIP: '192.168.1.0', endIP: '192.168.1.100' })],
	['结束为广播地址', variant({ startIP: '192.168.1.100', endIP: '192.168.1.255' })],
	['包含路由器地址', variant({ startIP: '192.168.1.1', endIP: '192.168.1.100' })],
	['跨越路由器地址', variant({ startIP: '192.168.1.0', endIP: '192.168.1.200' })],
	['池仅 1 个地址', variant({ startIP: '192.168.1.100', endIP: '192.168.1.100' })],
	['网关越界', variant({ gateway: '10.0.0.1' })],
	['DNS 非法', variant({ dns: ['not-an-ip'] })],
	['DNS 超过 2 个', variant({ dns: ['1.1.1.1', '2.2.2.2', '3.3.3.3'] })],
	['租期过短', variant({ leasetime: '30s' })],
	['租期格式错误', variant({ leasetime: 'forever' })],
	['静态绑定 MAC 非法', variant({ hosts: [{ mac: 'xx', ip: '192.168.1.50' }] })],
	['静态绑定 IP 非法', variant({ hosts: [{ mac: 'AA:BB:CC:DD:EE:FF', ip: '999.1.1.1' }] })],
	['静态绑定越界', variant({ hosts: [{ mac: 'AA:BB:CC:DD:EE:FF', ip: '10.0.0.5' }] })],
	['静态绑定用路由器 IP', variant({ hosts: [{ mac: 'AA:BB:CC:DD:EE:FF', ip: '192.168.1.1' }] })],
	['静态绑定 IP 重复', variant({ hosts: [
		{ mac: 'AA:BB:CC:DD:EE:01', ip: '192.168.1.50' },
		{ mac: 'AA:BB:CC:DD:EE:02', ip: '192.168.1.50' }
	] })],
	['静态绑定 MAC 重复', variant({ hosts: [
		{ mac: 'AA:BB:CC:DD:EE:01', ip: '192.168.1.50' },
		{ mac: 'AA:BB:CC:DD:EE:01', ip: '192.168.1.51' }
	] })]
];
for (let entry in bads) {
	check(throws(() => validate(entry[1])), '应被拒绝但通过了: ' + entry[0]);
}

// ---- 合法: 带静态绑定 ----
const withHosts = variant({ hosts: [{ mac: 'aa-bb-cc-dd-ee-ff', ip: '192.168.1.50', hostname: 'printer' }] });
const result = validate(withHosts);
check(result.hostState[0].mac == 'AA:BB:CC:DD:EE:FF', '静态绑定 MAC 未规范化');
check(result.hostState[0].ip == '192.168.1.50', '静态绑定 IP 丢失');
check(result.hostState[0].hostname == 'printer', '静态绑定主机名丢失');
check(result.limit == 150, '地址池数量计算错误: ' + result.limit);
check(result.startOffset == 100, '起始偏移计算错误: ' + result.startOffset);

// ---- 起始/结束到 start/limit 的反向换算 ----
const r2 = validate(variant({ startIP: '192.168.1.10', endIP: '192.168.1.19' }));
check(r2.limit == 10, '小地址池数量错误: ' + r2.limit);
check(r2.startOffset == 10, '小地址池偏移错误: ' + r2.startOffset);

print('PASS: DHCP 地址池换算、掩码、MAC 规范化、租期解析与 ' + (length(bads) + 1) + ' 项非法输入校验全部符合预期。\n');
