// SPDX-License-Identifier: Apache-2.0
// OpenVPN 客户端链路状态采集。
//
// 客户端和服务端不同：服务端有整张 CLIENT LIST 表，客户端只关心"自己这条链路"。
// 链路状态有两个可靠来源，按可信度组合使用：
//   1. management 接口的 state 命令 —— 唯一能拿到真实连接状态机的地方
//      （CONNECTING / AUTH / GET_CONFIG / ASSIGN_IP / CONNECTED / RECONNECTING / EXITING）；
//   2. --status 写出的统计文件 —— 累计收发字节。
// 隧道接口地址优先取接口实际生效值：服务端下发的地址在 CONNECTED 之前不会落地。
//
// 本模块只依赖 fs：parseState() / parseStatistics() / buildClientLink() 是纯函数，
// 可以在普通 `ucode` 环境下直接单测，不需要 rpcd。

import { readfile, stat, unlink } from 'fs';

const defaultRuntimeDir = '/var/run/console-vpn';
const tunnelDevice = 'cvpnc';

// 超过 10 年的时间跨度只可能是坏数据，钳制而不是溢出到界面。
const maxDuration = 315360000;
const maxBytes = 9007199254740991;

function isNum(value) { return type(value) == 'int' || type(value) == 'double'; }
function isNaNNum(value) { return value != value; }

function byteCount(value) {
	const n = (value == null) ? 0 : +value;
	if (isNaNNum(n) || n <= 0) return 0;
	if (n > maxBytes) return maxBytes;
	return int(n);
}

function positiveInt(value, fallback) {
	const n = (value == null) ? 0 : +value;
	if (isNaNNum(n) || n < 0) return fallback;
	return int(n);
}

/* ------------------------------------------------------------------ */
/* 连接状态机                                                          */
/* ------------------------------------------------------------------ */

// management state 命令输出的状态名。未列出的原样透出，绝不臆造。
const STATE_LABELS = {
	CONNECTING: '正在连接服务端',
	RESOLVE: '正在解析服务端域名',
	TCP_CONNECT: '正在建立 TCP 连接',
	WAIT: '等待服务端响应',
	AUTH: '正在验证账号密码',
	GET_CONFIG: '正在获取服务端配置',
	ASSIGN_IP: '正在分配隧道地址',
	ADD_ROUTES: '正在添加路由',
	CONNECTED: '已连接',
	RECONNECTING: '连接中断，正在重连',
	EXITING: '正在退出',
	EXIT: '已退出'
};

// 只有 CONNECTED 才算"握手完成、数据可通"。
function stateIsConnected(state) { return type(state) == 'string' && uc(state) == 'CONNECTED'; }

function stateLabel(state) {
	if (type(state) != 'string' || !length(state)) return '';
	const key = uc(state);
	return STATE_LABELS[key] ?? state;
}

// 解析 management `state` 命令的输出。
// 每行格式：时间戳,状态,描述,本地IP,远端IP,远端端口,本地IP6,远端IP6
// 取最后一条（最新）事件；空输出返回 null 而不是编造假状态。
function parseState(text) {
	if (type(text) != 'string') return null;
	let latest = null;
	for (let raw in split(text, '\n')) {
		const line = trim(raw);
		if (!length(line) || line == 'END') continue;
		if (substr(line, 0, 1) == '>') continue; // >INFO / >HOLD 之类的提示行
		const fields = split(line, ',');
		if (length(fields) < 2) continue;
		const at = +trim(fields[0]);
		if (isNaNNum(at) || at <= 0) continue;
		const name = trim(fields[1]);
		if (!length(name)) continue;
		latest = {
			since: int(at),
			state: name,
			label: stateLabel(name),
			detail: trim(fields[2] ?? ''),
			localAddress: trim(fields[3] ?? ''),
			remoteAddress: trim(fields[4] ?? ''),
			remotePort: trim(fields[5] ?? ''),
			localAddress6: trim(fields[6] ?? ''),
			remoteAddress6: trim(fields[7] ?? '')
		};
	}
	return latest;
}

/* ------------------------------------------------------------------ */
/* 统计文件                                                            */
/* ------------------------------------------------------------------ */

// 解析 --status 写出的 "OpenVPN STATISTICS" 文件。
// 客户端视角：TUN/TAP read = 隧道收到的字节，write = 隧道发出的字节。
function parseStatistics(text) {
	const result = { available: false, updatedText: null, tunRead: 0, tunWrite: 0, linkRead: 0, linkWrite: 0 };
	if (type(text) != 'string' || !length(trim(text))) return result;
	result.available = true;
	for (let raw in split(text, '\n')) {
		const line = trim(raw);
		if (!length(line) || line == 'END') continue;
		const comma = index(line, ',');
		if (comma < 0) continue;
		const key = trim(substr(line, 0, comma)), value = trim(substr(line, comma + 1));
		if (key == 'Updated') { result.updatedText = value; continue; }
		if (!match(value, /^\d+$/)) continue;
		const n = byteCount(value);
		if (key == 'TUN/TAP read bytes') result.tunRead = n;
		else if (key == 'TUN/TAP write bytes') result.tunWrite = n;
		else if (key == 'TCP/UDP read bytes') result.linkRead = n;
		else if (key == 'TCP/UDP write bytes') result.linkWrite = n;
	}
	return result;
}

/* ------------------------------------------------------------------ */
/* 隧道接口                                                            */
/* ------------------------------------------------------------------ */

// `ip -4 -o addr show dev <name>` 单行输出：<idx>: <name>    inet <addr>/<bits> ...
// ucode 的正则引擎不支持 (?:...) 非捕获组与嵌套量词，这里用扁平写法。
function parseInterface(output) {
	if (type(output) != 'string' || !length(trim(output))) return { present: false, address: '', prefix: 0 };
	const line = trim(split(trim(output), '\n')[0]);
	const m = match(line, /^[ \t]*[0-9]+:[ \t]+([^ \t]+)[ \t]+inet[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\/([0-9]+)/);
	if (!m) return { present: false, address: '', prefix: 0 };
	return { present: true, name: m[1], address: m[2], prefix: +m[3] };
}

// 读取接口地址同样走临时文件，避免 rpcd 环境里 popen 管道不稳定。
function interfaceState(name) {
	if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_.-]{1,15}$/)) return { present: false, address: '', prefix: 0 };
	const tmp = '/tmp/.console-vpn-iface.' + substr(name, 0, 8);
	const command = '/sbin/ip -4 -o addr show dev ' + name + ' > ' + tmp + ' 2>/dev/null';
	if (system(command) == null) return { present: false, address: '', prefix: 0 };
	const text = readfile(tmp);
	unlink(tmp);
	return parseInterface(text == null ? '' : text);
}

/* ------------------------------------------------------------------ */
/* management 查询                                                     */
/* ------------------------------------------------------------------ */

// 通过 management socket 取一次 state。
// 设备上的 busybox nc 只接受 `nc IP PORT`（不支持 -w / -U），且只从 stdin 读命令。
// 两个实测坑：
//   1. 喂完 `state` 后必须让管道多保持一会儿（sleep），否则 nc 在 stdin 关闭时
//      立刻断开，只能读到 banner 那一行；
//   2. rpcd 进程里 popen 的管道输出不稳定，改用 system() 落到临时文件再读回。
// 任何失败都返回 null：调用方回退到"进程在跑但状态未知"，不影响页面其它部分。
function queryManagement(port) {
	const p = positiveInt(port, 0);
	if (p < 1 || p > 65535) return null;
	const tmp = '/tmp/.console-vpn-state.' + p;
	const command = "{ printf 'state\\n'; sleep 1; } | timeout 3 /bin/busybox nc 127.0.0.1 " + p + ' > ' + tmp + ' 2>/dev/null';
	if (system(command) == null) return null;
	const text = readfile(tmp);
	unlink(tmp);
	return parseState(text == null ? '' : text);
}

/* ------------------------------------------------------------------ */
/* 时间工具                                                            */
/* ------------------------------------------------------------------ */

function elapsed(now, since) {
	if (!isNum(since)) return null;
	const delta = now - since;
	if (delta < 0) return 0;
	if (delta > maxDuration) return maxDuration;
	return int(delta);
}

function daysFromCivil(year, month, day) {
	let y = year;
	if (month <= 2) y -= 1;
	const era = (y >= 0) ? int(y / 400) : int((y - 399) / 400);
	const yoe = y - era * 400;
	const doy = int((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1;
	const doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	return era * 146097 + doe - 719468;
}
function fieldsToEpoch(f) { return daysFromCivil(f.year, f.mon, f.mday) * 86400 + f.hour * 3600 + f.min * 60 + f.sec; }
let offsetMemo = { at: null, offset: 0 };
function zoneOffset(now) {
	if (offsetMemo.at == now) return offsetMemo.offset;
	const utc = gmtime(now), local = localtime(now);
	let offset = 0;
	if (type(utc) == 'object' && type(local) == 'object') offset = fieldsToEpoch(utc) - fieldsToEpoch(local);
	offsetMemo = { at: now, offset };
	return offset;
}
function timestampToEpoch(text, now) {
	if (type(text) != 'string') return null;
	const m = match(trim(text), /^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2}):(\d{1,2})$/);
	if (!m) return null;
	const year = +m[1], mon = +m[2], mday = +m[3], hour = +m[4], min = +m[5], sec = +m[6];
	if (year < 1970 || year > 2100) return null;
	if (mon < 1 || mon > 12 || mday < 1 || mday > 31 || hour > 23 || min > 59 || sec > 60) return null;
	const at = isNum(now) ? now : time();
	const epoch = fieldsToEpoch({ year, mon, mday, hour, min, sec }) + zoneOffset(at);
	if (epoch <= 0 || epoch > at) return null;
	return int(epoch);
}

/* ------------------------------------------------------------------ */
/* 组装                                                                */
/* ------------------------------------------------------------------ */

// input: { configured, running, settings, state, statistics, interface, now }
// 输出给前端的链路快照。link 字段始终存在，前端只需看 phase / connected。
function buildClientLink(input) {
	const src = (type(input) == 'object') ? input : {};
	const now = isNum(src.now) ? src.now : time();
	const settings = (type(src.settings) == 'object') ? src.settings : {};
	const running = (src.running == true);
	const stateObj = (type(src.state) == 'object') ? src.state : null;
	const iface = (type(src.interface) == 'object') ? src.interface : {};
	const stats = (type(src.statistics) == 'object') ? src.statistics : {};

	const phase = (stateObj && length(stateObj.state ?? '')) ? stateObj.state : (running ? 'UNKNOWN' : 'STOPPED');
	const connected = running && stateIsConnected(phase);

	// 隧道地址优先取接口实际生效值：CONNECTED 之前服务端下发的地址不会落地。
	const tunnelAddress = iface.present ? (iface.address || '') : (stateObj?.localAddress ?? '');

	let label;
	if (!running) label = src.configured == true ? '已启用但进程未运行' : '未连接';
	else if (phase == 'UNKNOWN') label = '进程运行中，链路状态未知';
	else label = stateLabel(phase) || phase;

	return {
		phase: phase,
		label: label,
		connected: connected,
		running: running,
		configured: src.configured == true,
		tunnelAddress: tunnelAddress,
		tunnelPrefix: positiveInt(iface.prefix, 0),
		remoteAddress: (stateObj?.remoteAddress ?? '') || '',
		remotePort: positiveInt(stateObj?.remotePort, 0),
		host: type(settings.host) == 'string' ? settings.host : '',
		port: positiveInt(settings.port, 0),
		protocol: type(settings.protocol) == 'string' ? settings.protocol : '',
		lastTransitionAt: positiveInt(stateObj?.since, 0),
		phaseDuration: elapsed(now, stateObj?.since),
		statisticsAvailable: stats.available == true,
		bytesReceived: byteCount(stats.tunRead),
		bytesSent: byteCount(stats.tunWrite),
		linkBytesReceived: byteCount(stats.linkRead),
		linkBytesSent: byteCount(stats.linkWrite)
	};
}

/* ------------------------------------------------------------------ */
/* 运行时读取                                                          */
/* ------------------------------------------------------------------ */

function runtimeDir(dir) { return (type(dir) == 'string' && length(dir)) ? dir : defaultRuntimeDir; }

function readStatistics(dir) {
	const text = readfile(runtimeDir(dir) + '/client.status');
	return parseStatistics(text == null ? '' : text);
}

// 进程是否真的在跑：pid 文件存在且 /proc/<pid> 还在。
function readClientRuntime(dir) {
	const base = runtimeDir(dir);
	const raw = trim(readfile(base + '/client.pid') ?? '');
	if (!match(raw, /^\d+$/)) return { running: false, pid: null };
	const pid = int(raw);
	if (pid <= 0 || stat('/proc/' + pid) == null) return { running: false, pid: null };
	return { running: true, pid: pid };
}

// 汇总一次链路快照。settings 由调用方传入（来自 client.json）。
// managementPort 为 0 时跳过 management 查询，状态退化为"未知"。
function readClientLink(dir, settings, managementPort, now) {
	const at = isNum(now) ? now : time();
	const runtime = readClientRuntime(dir);
	const state = runtime.running ? queryManagement(managementPort) : null;
	const stats = readStatistics(dir);
	const iface = interfaceState(tunnelDevice);
	return buildClientLink({
		configured: (type(settings) == 'object'), running: runtime.running,
		settings, state, statistics: stats, interface: iface, now: at
	});
}

export {
	parseState, parseStatistics, parseInterface, buildClientLink,
	readStatistics, readClientLink, readClientRuntime, interfaceState,
	queryManagement, stateLabel, stateIsConnected,
	timestampToEpoch, elapsed, byteCount, tunnelDevice
};
