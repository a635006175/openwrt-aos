// SPDX-License-Identifier: Apache-2.0
// 解析 OpenVPN 客户端配置文件（.ovpn）。
// 只提取可以安全落地的字段：未知指令一律忽略，不会原样写进生成的客户端配置，
// 避免配置文件里的脚本钩子、插件或管理接口被当作配置执行。

import { popen } from 'fs';

const MAX_PROFILE_BYTES = 262144;

function fail(message) { die(message + '\n'); }

function hasKey(object, key) {
	for (let name in keys(object)) if (name == key) return true;
	return false;
}

function tail(list) {
	const result = [];
	for (let index = 1; index < length(list); index++) push(result, list[index]);
	return result;
}

function arg(args, position) {
	return length(args) > position ? args[position] : '';
}

// 证书、密钥等参数只允许安全的字符集，避免把指令拆散成新的配置行。
function safeToken(value) {
	return type(value) == 'string' && length(value) > 0 && length(value) <= 128 && match(value, /^[A-Za-z0-9_.:+-]+$/) != null;
}

function safeNumber(value) { return match(value, /^[0-9]{1,10}$/) != null; }
function safeFlag(value) { return value == '0' || value == '1'; }
function safeName(value) { return match(value, /^[A-Za-z_][A-Za-z0-9_]{0,63}$/) != null; }
// route 指令的地址/网关参数：点分 IPv4 或字面量主机名，不接受配置文件里的其它控制字符。
function safeRouteArg(value) {
	return match(value, /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}(\/[0-9]{1,2})?$/) != null || match(value, /^(\d{1,3}\.){3}\d{1,3}$/) != null;
}
// 支持算法列表只在首次解析时取一次：openvpn --show-ciphers 是子进程调用，不适合重复执行。
let cipherCache = null;
function cipherSupported(name) {
	const token = match(trim(name || ''), /^[A-Za-z0-9_-]{1,64}$/);
	if (token == null) return false;
	if (cipherCache == null) {
		cipherCache = {};
		const output = popen('/usr/sbin/openvpn --show-ciphers 2>/dev/null')?.read?.('all') || '';
		for (let line in split(output, '\n')) {
			const words = split(trim(line), /[ \t]+/);
			if (length(words) > 0) cipherCache[uc(words[0])] = true;
		}
	}
	return cipherCache[uc(token[0])] == true;
}

// 可以原样带进客户端配置的选项及其参数校验。
const COPY_OPTIONS = {
	'cipher': { min: 1, max: 1, check: safeToken },
	'auth': { min: 1, max: 1, check: safeToken },
	'data-ciphers': { min: 1, max: 1, check: safeToken },
	'data-ciphers-fallback': { min: 1, max: 1, check: safeToken },
	'tls-cipher': { min: 1, max: 1, check: safeToken },
	'tls-version-min': { min: 1, max: 1, check: v => match(v, /^1\.[0-3]$/) != null },
	'tun-mtu': { min: 1, max: 1, check: safeNumber },
	'resolv-retry': { min: 1, max: 1, check: v => v == 'infinite' || safeNumber(v) },
	'connect-retry': { min: 1, max: 1, check: safeNumber },
	'explicit-exit-notify': { min: 1, max: 1, check: safeFlag },
	'verify-x509-name': { min: 1, max: 2, check: v => match(v, /^[A-Za-z0-9._-]{1,128}$/) != null },
	'setenv': { min: 1, max: 3, check: safeName },
	'sndbuf': { min: 1, max: 1, check: safeNumber },
	'rcvbuf': { min: 1, max: 1, check: safeNumber },
	'txqueuelen': { min: 1, max: 1, check: safeNumber },
	'nice': { min: 1, max: 1, check: v => match(v, /^-?[0-9]{1,3}$/) != null },
	'shaper': { min: 1, max: 1, check: safeNumber },
	'mute': { min: 1, max: 1, check: v => match(v, /^[0-9]{1,4}$/) != null },
	'verb': { min: 1, max: 1, check: v => match(v, /^[0-9]{1,2}$/) != null }
};

// 无参数开关，直接带进客户端配置。
const COPY_FLAGS = {
	'auth-nocache': 1, 'nobind': 1, 'float': 1, 'persist-key': 1, 'persist-tun': 1,
	'mute-replay-warnings': 1, 'tls-client': 1, 'tls-server': 1, 'remote-random-hostname': 1,
	'comp-noadapt': 1, 'fast-io': 1, 'opt-verify': 1
};

// 这些指令已在 clientConfigText() 里统一生成，配置文件里重复带入会让同一选项出现两次。
const DUPLICATED = { 'nobind': 1, 'persist-key': 1, 'persist-tun': 1, 'verb': 1, 'auth-nocache': 1 };

// 能识别但不采纳的指令，页面会提示原因，避免用户误以为已经生效。
const UNSUPPORTED = {
	'ca': '外部证书文件无法读取',
	'cert': '外部证书文件无法读取',
	'key': '外部私钥文件无法读取',
	'tls-auth': '外部密钥文件无法读取',
	'tls-crypt': '外部密钥文件无法读取',
	'pkcs12': '不支持 PKCS#12 证书',
	'dh': 'Diffie-Hellman 参数由服务端提供',
	'script-security': '脚本安全级别',
	'up': '脚本钩子',
	'down': '脚本钩子',
	'up-delay': '脚本钩子',
	'route-up': '脚本钩子',
	'route-pre-down': '脚本钩子',
	'ipchange': '脚本钩子',
	'learn-address': '脚本钩子',
	'client-connect': '脚本钩子',
	'client-disconnect': '脚本钩子',
	'auth-user-pass-verify': '服务端校验脚本',
	'management': '管理接口',
	'plugin': '插件',
	'askpass': '交互式密码程序',
	'tls-verify': 'TLS 校验脚本',
	'tls-export-cert': '证书导出',
	'ifconfig': '服务端下发地址',
	'ifconfig-ipv6': '服务端下发地址',
	'iroute': '服务端下发路由',
	'push': '服务端推送配置',
	'pull-filter': '服务端推送配置',
	'route-gateway': '服务端下发网关',
	'topology': '服务端拓扑',
	'port': '本地监听端口',
	'lport': '本地监听端口',
	'rport': '本地监听端口',
	'local': '本地地址绑定',
	'keepalive': '保活参数',
	'ping': '保活参数',
	'ping-restart': '保活参数',
	'ping-exit': '保活参数',
	'inactive': '保活参数',
	'hand-window': '握手参数',
	'server-poll-timeout': '服务端轮询',
	'max-routes': '路由数量限制',
	'reneg-sec': '重协商周期',
	'reneg-bytes': '重协商阈值',
	'reneg-pkts': '重协商阈值',
	'ecdh-curve': '曲线参数',
	'ecdh-f': '曲线参数',
	'engine': '加密引擎',
	'auth-nocache-file': '凭据文件'
};

const KNOWN_BLOCKS = { 'ca': 1, 'cert': 1, 'key': 1, 'tls-auth': 1, 'tls-crypt': 1, 'pkcs12': 1 };

function parseProfile(text) {
	if (type(text) != 'string') fail('配置文件内容无效');
	if (!length(trim(text))) fail('配置文件内容为空');
	if (length(text) > MAX_PROFILE_BYTES) fail('配置文件超过 256 KB 上限');
	const blocks = {}, directives = [];
	let block = null;
	for (let raw in split(text, '\n')) {
		const line = trim(raw);
		if (block != null) {
			if (match(line, /^<\/([A-Za-z0-9_-]+)>$/) != null) { block = null; continue; }
			push(blocks[block], line);
			continue;
		}
		const open = match(line, /^<([A-Za-z0-9_-]+)>$/);
		if (open != null) {
			const name = open[1];
			if (hasKey(KNOWN_BLOCKS, name)) { block = name; blocks[name] = []; }
			continue;
		}
		if (match(line, /^<\/([A-Za-z0-9_-]+)>$/) != null) continue;
		if (line == '') continue;
		if (substr(line, 0, 1) == '#' || substr(line, 0, 1) == ';') continue;
		const tokens = split(line, /\s+/);
		push(directives, { name: tokens[0], args: tail(tokens) });
	}
	const result = {
		host: '', port: 0, protocol: '', ca: '', cert: '', key: '', tlsAuth: '', tlsCrypt: '',
		keyDirection: 1, authUserPass: false, remoteCertTls: false, redirectGateway: false,
		compression: '', dataCiphers: '', routeNopull: false,
		extra: [], ignored: [], warnings: []
	};
	const seen = {};
	for (let directive in directives) {
		const name = directive.name, args = directive.args;
		if (name == 'remote') {
			if (result.host == '') {
				result.host = arg(args, 0);
				result.port = length(args) > 1 ? +arg(args, 1) : 1194;
			} else {
				push(result.warnings, '配置中存在多个 remote，仅使用第一个');
			}
			continue;
		}
		if (name == 'proto') {
			const value = arg(args, 0);
			// 只指定 udp / tcp 时，OpenVPN 会同时尝试 AAAA 与 A 记录。
			// 本机多数只有 IPv4 出口，DNS 一旦先返回 IPv6 就会以
			// "write UDPv6 []: Network unreachable" 反复重连，因此统一固定到 v4：
			// 需要 IPv6 的场景由 udp6/tcp6 显式声明（当前明确不支持）。
			if (value == 'udp' || value == 'udp4') result.protocol = 'udp4';
			else if (value == 'tcp' || value == 'tcp4' || value == 'tcp-client' || value == 'tcp4-client') result.protocol = 'tcp4-client';
			else if (value == 'udp6' || value == 'udp6-client' || value == 'tcp6' || value == 'tcp6-client') fail('暂不支持 IPv6 隧道协议：' + value);
			else fail('无法识别的隧道协议：' + (value == '' ? '(空)' : value));
			continue;
		}
		if (name == 'dev') {
			// 隧道设备名由本功能统一指派为 cvpnc，这里只判断配置要求的隧道类型：
			// tunx / tun0 / tun / TUN 等价（OpenVPN 自身把 tunx 视为 tun 的自动命名形式）。
			const value = arg(args, 0), lower = lc(value);
			if (match(lower, /^tun[a-z0-9_-]*$/) != null) continue;
			if (match(lower, /^tap[a-z0-9_-]*$/) != null) fail('仅支持 tun 隧道，配置中要求的是 tap 二层隧道：' + value);
			fail('仅支持 tun 隧道，配置中的设备为 ' + value);
		}
		if (name == 'dev-type') {
			const value = arg(args, 0), lower = lc(value);
			if (lower != 'tun') fail('仅支持 tun 隧道类型，配置中为 ' + value);
			continue;
		}
		if (name == 'auth-user-pass') {
			result.authUserPass = true;
			if (length(args) > 0) push(result.warnings, '配置中的凭据文件路径已忽略，改用路由器内置账号密码');
			continue;
		}
		if (name == 'remote-cert-tls') { result.remoteCertTls = arg(args, 0) == 'server'; continue; }
		if (name == 'redirect-gateway') { result.redirectGateway = true; continue; }
		if (name == 'key-direction') { result.keyDirection = length(args) > 0 ? +arg(args, 0) : 1; continue; }
		if (name == 'client') continue;
		// 压缩：固件已启用 LZO（openvpn --version 含 [LZO]），按配置原样下发 comp-lzo。
		// 这是数据面能否通的关键：服务端启用 comp-lzo 时，客户端若只协商压缩桩
		// （compress stub-v2），收到的 LZO 压缩帧无法解压，写入 tun 时按 IPv4 校验
		// 失败，表现为 write to TUN/TAP: Invalid argument 且隧道完全不通。
		if (name == 'comp-lzo' || name == 'compress') {
			const value = arg(args, 0);
			if (name == 'comp-lzo') {
				// comp-lzo [yes|no|adaptive]，缺省 yes
				if (length(args) > 1) { push(result.ignored, name + '（参数数量不符）'); continue; }
				if (value == 'no') { result.compression = 'no'; continue; }
				if (length(args) == 1 && value != 'yes' && value != 'adaptive') { push(result.ignored, 'comp-lzo（取值无效）'); continue; }
				result.compression = 'yes';
				continue;
			}
			// compress [lzo|lzo-no|stub|stub-v2]，缺省 lzo
			if (length(args) > 1) { push(result.ignored, name + '（参数数量不符）'); continue; }
			if (length(args) == 0 || value == 'lzo') { result.compression = 'yes'; continue; }
			if (value == 'lzo-no' || value == 'no') { result.compression = 'no'; continue; }
			if (value == 'stub' || value == 'stub-v2') {
				// 服务端并未要求压缩时，桩模式足够且更省带宽
				result.compression = 'stub';
				push(result.warnings, 'compress ' + value + ' 已保留为压缩桩，本机不做压缩');
				continue;
			}
			push(result.ignored, name + '（取值无效）');
			continue;
		}
		if (name == 'allow-compression') {
			const value = arg(args, 0);
			// 2.7 仅接受 yes|no|asym
			if (value == 'no') { result.compression = 'no'; continue; }
			if (value == 'yes' || value == 'asym') { result.compression = 'yes'; continue; }
			push(result.ignored, name + '（参数不安全或不完整）');
			continue;
		}
		// 静态路由：route-nopull 场景下这些是用户显式指定的隧道路由，必须保留，
		// 否则导入后会连一个业务网段都访问不到。地址统一校验，避免注入。
		if (name == 'route') {
			if (length(args) < 2 || !safeRouteArg(arg(args, 0)) || !safeRouteArg(arg(args, 1))) { push(result.ignored, 'route（地址格式无效）'); continue; }
			if (length(args) > 3) { push(result.ignored, 'route（不支持 gateway 之外的额外参数）'); continue; }
			let line = 'route ' + arg(args, 0) + ' ' + arg(args, 1);
			if (length(args) == 3) { if (!safeRouteArg(arg(args, 2))) { push(result.ignored, 'route（网关格式无效）'); continue; } line += ' ' + arg(args, 2); }
			push(result.extra, line);
			continue;
		}
		if (name == 'route-nopull') { result.routeNopull = true; continue; }
		if (name == 'ca' || name == 'cert' || name == 'key' || name == 'tls-auth' || name == 'tls-crypt') {
			// 只有内嵌 <ca> / <cert> / <key> 段才会被采用，外部文件路径在路由器上不存在。
			if (length(args) > 0) push(result.warnings, '配置引用的外部文件 ' + arg(args, 0) + ' 无法读取，仅采用内嵌内容');
			continue;
		}
		if (hasKey(COPY_FLAGS, name)) {
			if (hasKey(DUPLICATED, name)) continue;
			if (!seen[name]) { seen[name] = true; push(result.extra, name); }
			continue;
		}
		if (hasKey(COPY_OPTIONS, name)) {
			const spec = COPY_OPTIONS[name], count = length(args);
			if (count < spec.min || count > spec.max) { push(result.ignored, name + '（参数数量不符）'); continue; }
			let valid = true;
			for (let value in args) if (!spec.check(value)) valid = false;
			if (!valid) { push(result.ignored, name + '（参数不安全或不完整）'); continue; }
			if (name == 'setenv' && count == 3 && arg(args, 0) != 'opt') { push(result.ignored, name + '（不支持的参数形式）'); continue; }
			// 客户端配置里已统一写入 verb 3 / mute 10，无需从文件里重复带入。
			if (name == 'verb' || name == 'mute') continue;
			// cipher 只写进 --cipher；OpenVPN 2.5+ 的协商看 --data-ciphers，
			// 传统算法（BF-CBC/DES-CBC 等）在本机构建里可能已不可用，逐项确认后再决定是否采纳。
			if (name == 'cipher') {
				const value = arg(args, 0);
				if (!cipherSupported(value)) {
					push(result.ignored, 'cipher ' + value + '（本机 OpenVPN 不支持该算法）');
					continue;
				}
				if (!result.dataCiphers) result.dataCiphers = value;
				push(result.extra, 'cipher ' + value);
				continue;
			}
			if (name == 'data-ciphers' || name == 'data-ciphers-fallback') {
				result.dataCiphers = arg(args, 0);
			}
			push(result.extra, count > 0 ? name + ' ' + join(' ', args) : name);
			continue;
		}
		if (hasKey(UNSUPPORTED, name)) { push(result.ignored, name + '（' + UNSUPPORTED[name] + '）'); continue; }
		push(result.ignored, name);
	}
	result.ca = hasKey(blocks, 'ca') ? join('\n', blocks['ca']) : '';
	result.cert = hasKey(blocks, 'cert') ? join('\n', blocks['cert']) : '';
	result.key = hasKey(blocks, 'key') ? join('\n', blocks['key']) : '';
	result.tlsAuth = hasKey(blocks, 'tls-auth') ? join('\n', blocks['tls-auth']) : '';
	result.tlsCrypt = hasKey(blocks, 'tls-crypt') ? join('\n', blocks['tls-crypt']) : '';
	if (hasKey(blocks, 'pkcs12')) push(result.ignored, 'pkcs12（不支持 PKCS#12 证书）');
	if (result.ca == '' || index(result.ca, '-----BEGIN CERTIFICATE-----') < 0) fail('配置中没有内嵌 CA 证书，请使用包含 <ca> 段的文件');
	if (index(result.ca, 'PRIVATE KEY') >= 0) fail('配置中的 CA 段包含私钥，拒绝导入');
	if ((result.cert == '') != (result.key == '')) fail('客户端证书与私钥必须成对提供');
	if (result.cert != '' && index(result.cert, '-----BEGIN CERTIFICATE-----') < 0) fail('内嵌客户端证书格式无效');
	if (result.key != '' && index(result.key, 'PRIVATE KEY') < 0) fail('内嵌客户端私钥格式无效');
	if (result.host == '') fail('配置中没有 remote 服务端地址');
	if (!result.protocol) result.protocol = 'udp';
	if (result.port < 1 || result.port > 65535) fail('配置中的服务端端口无效');
	// 服务端协商出来的算法若不在 data-ciphers 里，OpenVPN 2.5+ 会直接握手失败。
	// 配置没指定算法时不写死，交给内置默认列表。
	if (result.dataCiphers && !hasOption(result.extra, 'data-ciphers') && !hasOption(result.extra, 'data-ciphers-fallback')) {
		if (cipherSupported(result.dataCiphers)) push(result.extra, 'data-ciphers ' + result.dataCiphers);
	}
	return result;
}

// 供页面展示的摘要：不返回私钥内容，只说明是否检测到。
function profileSummary(parsed) {
	return {
		host: parsed.host, port: parsed.port, protocol: parsed.protocol, ca: parsed.ca,
		hasCert: parsed.cert != '', hasKey: parsed.key != '', hasTlsAuth: parsed.tlsAuth != '',
		hasTlsCrypt: parsed.tlsCrypt != '', authUserPass: parsed.authUserPass,
		remoteCertTls: parsed.remoteCertTls, redirectGateway: parsed.redirectGateway,
		compression: parsed.compression || '', dataCiphers: parsed.dataCiphers || '',
		routeNopull: parsed.routeNopull == true,
		requiresCredentials: parsed.cert == '' || parsed.authUserPass,
		extra: parsed.extra, ignored: parsed.ignored, warnings: parsed.warnings
	};
}

export { parseProfile, profileSummary, MAX_PROFILE_BYTES };
