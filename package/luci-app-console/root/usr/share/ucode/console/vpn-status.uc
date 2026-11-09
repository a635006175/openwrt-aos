// SPDX-License-Identifier: Apache-2.0
// OpenVPN 服务端状态文件解析。
//
// 本模块故意只依赖 fs：parseStatus() / buildDetail() 是纯函数，可以在普通
// `ucode` 环境下直接单元测试，不需要 luci.core 或 rpcd。
// console-vpn-service / console-vpn-accounts 的数据由 RPC 层组装后传入
// buildDetail()，避免模块导入顺序和 rpcd 缓存带来的耦合。

import { readfile, stat, unlink } from 'fs';

const defaultRuntimeDir = '/var/run/console-vpn';

// 超过 10 年的时间戳只可能是坏数据（例如 1970 年），按上限钳制而不是溢出到界面。
const maxDuration = 315360000;
const maxBytes = 9007199254740991;

/* ------------------------------------------------------------------ */
/* 数值工具                                                            */
/* ------------------------------------------------------------------ */

function isNum(value) { return type(value) == 'int' || type(value) == 'double'; }
function isNaNNum(value) { return value != value; }

// 统一成非负整数：NaN、负数、非数字一律回退到 0，绝不把坏数据透给前端。
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
/* CSV（OpenVPN status 会用双引号包裹含逗号的字段）                     */
/* ------------------------------------------------------------------ */

function splitCsv(line) {
	const fields = [];
	let value = '', quoted = false;
	for (let i = 0; i < length(line); i++) {
		const ch = substr(line, i, 1);
		if (quoted) {
			if (ch != '"') { value += ch; continue; }
			// 双引号内的 "" 表示一个字面量引号
			if (substr(line, i + 1, 1) == '"') { value += '"'; i++; continue; }
			quoted = false;
			continue;
		}
		if (ch == '"') { quoted = true; continue; }
		if (ch == ',') { push(fields, value); value = ''; continue; }
		value += ch;
	}
	push(fields, value); // 引号未闭合时也把已经读到的内容交出去，绝不丢行
	return fields;
}

/* ------------------------------------------------------------------ */
/* 时间戳                                                              */
/* ------------------------------------------------------------------ */

// 公历 -> 1970-01-01 起的天数（Howard Hinnant 算法，不依赖 mktime）。
function daysFromCivil(year, month, day) {
	let y = year;
	if (month <= 2) y -= 1;
	const era = (y >= 0) ? int(y / 400) : int((y - 399) / 400);
	const yoe = y - era * 400;
	const doy = int((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1;
	const doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
	return era * 146097 + doe - 719468;
}

// 把「年月日时分秒」当成 UTC 字段换算成秒（即 timegm 的替代品）。
function fieldsToEpoch(f) {
	return daysFromCivil(f.year, f.mon, f.mday) * 86400 + f.hour * 3600 + f.min * 60 + f.sec;
}

// ucode 没有 timegm/mktime：status 文件里的时间戳是本地时间（无时区），
// 先按 UTC 算一遍，再补上「此刻」的本地偏移量。
// zoneOffset = epoch(gmtime(now)) - epoch(localtime(now)) = -off（东八区为 -28800），
// 所以 epoch = 字段按 UTC 折算 + zoneOffset 正好得到本地时间对应的真实 epoch。
// 同一个 now 只算一次：一次解析要换算多行时间戳。
let offsetMemo = { at: null, offset: 0 };

function zoneOffset(now) {
	if (offsetMemo.at == now) return offsetMemo.offset;
	const utc = gmtime(now), local = localtime(now);
	let offset = 0;
	if (type(utc) == 'object' && type(local) == 'object') offset = fieldsToEpoch(utc) - fieldsToEpoch(local);
	offsetMemo = { at: now, offset };
	return offset;
}

// "YYYY-MM-DD HH:MM:SS"（本地时间）-> epoch 秒。
// 无法解释的时间戳（格式错、年份越界）返回 null；比 now 还晚的钳到 now，
// 这样前端永远不会看到 "未来" 的时间或负数时长。
function timestampToEpoch(text, now) {
	if (type(text) != 'string') return null;
	const m = match(trim(text), /^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2}):(\d{1,2})$/);
	if (!m) return null;
	const year = +m[1], mon = +m[2], mday = +m[3], hour = +m[4], min = +m[5], sec = +m[6];
	// status 文件只能由近期生成，窗口外的年份只能是坏数据。
	if (year < 1970 || year > 2100) return null;
	if (mon < 1 || mon > 12 || mday < 1 || mday > 31 || hour > 23 || min > 59 || sec > 60) return null;
	const at = isNum(now) ? now : time();
	const epoch = fieldsToEpoch({ year, mon, mday, hour, min, sec }) + zoneOffset(at);
	if (epoch <= 0) return null;
	if (epoch > at) return int(at);
	return int(epoch);
}

// now - since，负数钳到 0，荒谬大值钳到 10 年；since 未知则 null。
function elapsed(now, since) {
	if (!isNum(since)) return null;
	const delta = now - since;
	if (delta < 0) return 0;
	if (delta > maxDuration) return maxDuration;
	return int(delta);
}

/* ------------------------------------------------------------------ */
/* Real Address: "proto:ip:port" / "proto:[ipv6]:port" / "ip:port"     */
/* ------------------------------------------------------------------ */

function parseRealAddress(text) {
	let value = trim(text ?? '');
	let protocol = '', address = '', port = '';
	if (!length(value)) return { protocol: '', address: '', port: '' };

	// 先剥离协议前缀，但只有当剩余部分确实像地址时才剥离（避免吃掉 IPv6 首段）。
	const m = match(value, /^([A-Za-z][A-Za-z0-9_-]{0,23}):(.+)$/);
	if (m) {
		const rest = m[2];
		if (index(rest, '.') >= 0 || index(rest, ':') >= 0 || index(rest, '[') >= 0) {
			protocol = m[1];
			value = rest;
		}
	}

	// [IPv6]:port —— OpenVPN 对 IPv6 一定加方括号，保留方括号方便前端直接拼 :port。
	if (substr(value, 0, 1) == '[') {
		const close = index(value, ']');
		if (close > 0) {
			address = substr(value, 0, close + 1);
			const after = substr(value, close + 1);
			if (substr(after, 0, 1) == ':' && match(substr(after, 1), /^\d{1,5}$/)) port = substr(after, 1);
			return { protocol, address, port };
		}
		return { protocol, address: value, port: '' };
	}

	// IPv4:port 或 proto:host:port。只有当“端口”前面确实是一个主机（IPv4 或域名）
	// 时才拆，否则裸 IPv6 地址会被最后一个冒号切坏。
	const colon = rindex(value, ':');
	if (colon > 0) {
		const head = substr(value, 0, colon), tail = substr(value, colon + 1);
		const headLooksLikeHost = (index(head, ':') < 0)
			&& (match(head, /^(\d{1,3}\.){3}\d{1,3}$/) != null || match(head, /^[A-Za-z0-9][A-Za-z0-9.-]*$/) != null);
		if (headLooksLikeHost && match(tail, /^\d{1,5}$/)) {
			address = head;
			port = tail;
			return { protocol, address, port };
		}
	}

	return { protocol, address: value, port };
}

/* ------------------------------------------------------------------ */
/* status 文件解析                                                     */
/* ------------------------------------------------------------------ */

// 小节标题：不含逗号、以 LIST/TABLE/STATS 结尾的多词行。
// 数据行一定带逗号，所以这条规则既认得出 "OpenVPN CLIENT LIST"，也不会吃掉数据行。
function sectionOf(line) {
	if (index(line, ',') >= 0) return null;
	const words = split(line, ' ');
	if (length(words) < 2) return null;
	const last = words[length(words) - 1];
	if (last != 'LIST' && last != 'TABLE' && last != 'STATS') return null;
	if (index(line, 'CLIENT') >= 0) return 'clients';
	if (index(line, 'ROUTING') >= 0) return 'routing';
	if (index(line, 'GLOBAL') >= 0) return 'global';
	return 'unknown';
}

// 纯函数：解析 status 文本，不读任何文件。
// 返回 { updatedAt, clients, totals }；空文本/坏文本只返回空结果，绝不臆造数据。
// 容错策略：
//   - 缺 END、缺 ROUTING TABLE、缺 Updated 行都照常返回已有信息；
//   - 字段不全的行（例如正在被 OpenVPN 重写时的半行）只要能确定是客户端的
//     就把已知字段交出去，未知字段一律 null（而不是丢掉整行或补假值）；
//   - 连「Common Name + Real Address」都凑不齐的行直接忽略。
function parseStatus(text, now) {
	const at = isNum(now) ? now : time();
	const result = {
		updatedAt: null,
		clients: [],
		totals: { online: 0, bytesReceived: 0, bytesSent: 0 }
	};
	if (type(text) != 'string' || !length(trim(text))) return result;

	const clientRows = [], routeRows = [];
	let section = null, updatedText = null;

	for (let raw in split(text, '\n')) {
		const line = trim(raw); // 顺带吃掉 CRLF 的 \r
		if (!length(line)) continue;
		if (line == 'END') break;

		const sec = sectionOf(line);
		if (sec != null) { section = (sec == 'unknown') ? null : sec; continue; }

		const fields = splitCsv(line);
		const first = trim(fields[0] ?? '');

		// 列标题行同时也用来容错地切换小节（文件被截断到只剩标题时也能解析）。
		if (first == 'Common Name') { section = 'clients'; continue; }
		if (first == 'Virtual Address') { section = 'routing'; continue; }
		if (first == 'Updated') { updatedText = fields[1] ?? null; continue; }

		if (section == 'clients') {
			// 只要「Common Name + Real Address」两列成立就算一行客户端；
			// 后面被截断的列按空值处理（bytes -> 0, since -> null），不丢行也不补假时间。
			if (length(fields) < 2 || !length(first)) continue;
			const real = trim(fields[1] ?? '');
			if (index(real, ':') < 0) continue; // 不像 Real Address 的行直接跳过
			push(clientRows, {
				username: first,
				realRaw: real,
				bytesReceived: byteCount(fields[2]),
				bytesSent: byteCount(fields[3]),
				sinceText: fields[4] ?? null
			});
			continue;
		}

		if (section == 'routing') {
			if (length(fields) < 3 || !length(first)) continue;
			const cn = trim(fields[1] ?? ''), real = trim(fields[2] ?? '');
			if (!length(cn) || index(real, ':') < 0) continue;
			push(routeRows, { virtualAddress: first, username: cn, realRaw: real, refText: fields[3] ?? null });
			continue;
		}
		// 未知小节 / GLOBAL STATS：忽略
	}

	// ROUTING TABLE 按 (Common Name, Real Address) 建索引后与 CLIENT LIST 关联。
	const routes = {};
	for (let row in routeRows) {
		const userKey = 'u:' + row.username;
		if (routes[userKey] == null) routes[userKey] = {};
		const realKey = 'r:' + row.realRaw;
		if (routes[userKey][realKey] != null) continue; // 同一连接取第一条
		const virtual = length(row.virtualAddress) ? row.virtualAddress : null;
		routes[userKey][realKey] = { virtualAddress: virtual, lastRef: timestampToEpoch(row.refText, at) };
	}

	let received = 0, sent = 0;
	for (let row in clientRows) {
		const ra = parseRealAddress(row.realRaw);
		const userKey = 'u:' + row.username, realKey = 'r:' + row.realRaw;
		const route = routes[userKey]?.[realKey] ?? null;
		const since = timestampToEpoch(row.sinceText, at);
		const lastRef = route ? route.lastRef : null;
		push(result.clients, {
			username: row.username,
			virtualAddress: route ? route.virtualAddress : null,
			realAddress: ra.address,
			realPort: ra.port,
			protocol: ra.protocol,
			bytesReceived: row.bytesReceived,
			bytesSent: row.bytesSent,
			connectedSince: since,
			connectedFor: elapsed(at, since),
			lastRef: lastRef,
			idleFor: elapsed(at, lastRef)
		});
		received += row.bytesReceived;
		sent += row.bytesSent;
	}

	result.updatedAt = timestampToEpoch(updatedText, at);
	result.totals = { online: length(result.clients), bytesReceived: received, bytesSent: sent };
	return result;
}

/* ------------------------------------------------------------------ */
/* 运行时文件读取（只在这里碰 /var/run）                               */
/* ------------------------------------------------------------------ */

function runtimeDir(dir) {
	return (type(dir) == 'string' && length(dir)) ? dir : defaultRuntimeDir;
}

// 读取 status 文件；文件缺失/不可读时 statusAvailable=false 且结果为空。
function readServerStatus(dir, now) {
	const at = isNum(now) ? now : time();
	const text = readfile(runtimeDir(dir) + '/server.status');
	const parsed = parseStatus(text == null ? '' : text, at);
	return {
		statusAvailable: text != null,
		updatedAt: parsed.updatedAt,
		clients: parsed.clients,
		totals: parsed.totals
	};
}

// 读取守护进程 pid 与已运行秒数（pid 文件 mtime 即进程启动时刻）。
function readServerPid(dir, now) {
	const at = isNum(now) ? now : time();
	const base = runtimeDir(dir);
	const raw = trim(readfile(base + '/server.pid') ?? '');
	if (!match(raw, /^\d+$/)) return { pid: null, uptime: null };
	const pid = int(raw);
	if (pid <= 0 || stat('/proc/' + pid) == null) return { pid: null, uptime: null };
	const info = stat(base + '/server.pid');
	let uptime = null;
	if (type(info) == 'object' && isNum(info.mtime) && info.mtime > 0 && info.mtime <= at) uptime = int(at - info.mtime);
	return { pid, uptime };
}

/* ------------------------------------------------------------------ */
/* 客户端日志                                                          */
/* ------------------------------------------------------------------ */

// 从系统日志里挑出属于 VPN 客户端进程的行。
// 客户端由 procd 拉起并把 stdout/stderr 交给 syslog，所以进程的日志在 logread 里，
// 而不是独立文件；必须按 openvpn[<client pid>] 精确过滤，
// 否则会把同机上的服务端实例（openvpn[<server pid>]）混进来。
// 另外要滤掉本功能自己造成的 management 噪音：页面每 5 秒查一次状态，
// 每次在日志里留下 connected / CMD 'state' / disconnected 三行，
// 不滤掉会把真正有价值的事件（重连、VERIFY 失败、TLS 错误）挤出显示窗口。
const MAX_LOG_LINES = 200;

// 判定是否为 management 轮询噪音。
// 只匹配本模块自己发的 `state` 查询与连接建立/断开这三类，
// 保留 MANAGEMENT 里其余有诊断价值的消息（例如 HOLD、密码错误）。
function isManagementNoise(body) {
	if (index(body, 'MANAGEMENT: Client connected from') >= 0) return true;
	if (index(body, 'MANAGEMENT: Client disconnected') >= 0) return true;
	if (index(body, "MANAGEMENT: CMD 'state'") >= 0) return true;
	if (index(body, "MANAGEMENT: CMD 'status'") >= 0) return true;
	return false;
}

function parseClientLog(text, pid, limit) {
	const lines = [];
	if (type(text) != 'string' || !length(text)) return lines;
	const tag = (type(pid) == 'int' || type(pid) == 'double') && pid > 0 ? 'openvpn[' + pid + ']:' : null;
	const cap = (type(limit) == 'int' && limit > 0) ? limit : MAX_LOG_LINES;
	for (let raw in split(text, '\n')) {
		const line = trim(raw);
		if (!length(line)) continue;
		let body = line;
		if (tag != null) {
			const at = index(line, tag);
			// 没有该 pid 标签的行一律丢弃，避免把服务端日志混进客户端区。
			if (at < 0) continue;
			body = trim(substr(line, at + length(tag)));
		}
		if (!length(body)) continue;
		if (isManagementNoise(body)) continue;
		push(lines, body);
		if (length(lines) > cap) shift(lines);
	}
	return lines;
}

// 通过 logread 抓取客户端进程日志。
// 与 vpn-client-status.uc 一致：rpcd 里 popen 管道不稳定，改用 system() 落临时文件。
// 抓取时多取一些（轮询噪音要先滤掉再截断），最终仍只保留最近 cap 行。
// pid 缺失（客户端未运行）时返回空数组，不猜测日志来源。
const FETCH_MULTIPLIER = 8;

function readClientLog(dir, limit) {
	const base = runtimeDir(dir);
	const rawPid = trim(readfile(base + '/client.pid') ?? '');
	if (!match(rawPid, /^\d+$/)) return [];
	const pid = int(rawPid);
	if (pid <= 0 || stat('/proc/' + pid) == null) return [];
	const cap = (type(limit) == 'int' && limit > 0) ? limit : MAX_LOG_LINES;
	const fetch = cap * FETCH_MULTIPLIER;
	const tmp = '/tmp/.console-vpn-clog.' + pid;
	const command = '/sbin/logread 2>/dev/null | grep -F "openvpn[' + pid + ']:" | tail -n ' + fetch + ' > ' + tmp;
	if (system(command) == null) return [];
	const text = readfile(tmp);
	unlink(tmp);
	return parseClientLog(text == null ? '' : text, pid, cap);
}

/* ------------------------------------------------------------------ */
/* 组装 RPC 返回结构                                                   */
/* ------------------------------------------------------------------ */

// input: { settings, serverState, accounts, snapshot, runtime, clientLink, clientLog }
// 输出严格遵循 status_detail 契约（字段名不可改动，前端并行开发中）。
function buildDetail(input) {
	const src = (type(input) == 'object') ? input : {};
	const settings = (type(src.settings) == 'object') ? src.settings : {};
	const state = (type(src.serverState) == 'object') ? src.serverState : {};
	const accounts = (type(src.accounts) == 'array') ? src.accounts : [];
	const snapshot = (type(src.snapshot) == 'object') ? src.snapshot : {};
	const runtime = (type(src.runtime) == 'object') ? src.runtime : {};
	const clientLink = (type(src.clientLink) == 'object') ? src.clientLink : null;
	const clientLog = (type(src.clientLog) == 'array') ? src.clientLog : [];

	const running = (state.running == true);
	const clients = (type(snapshot.clients) == 'array') ? snapshot.clients : [];
	const list = [];
	for (let account in accounts) {
		push(list, {
			username: account.username,
			enabled: (account.enabled == true),
			address: account.address ?? '',
			remoteSubnet: account.remoteSubnet ?? '',
			description: account.description ?? ''
		});
	}

	let received = 0, sent = 0;
	for (let client in clients) {
		received += byteCount(client.bytesReceived);
		sent += byteCount(client.bytesSent);
	}

	return {
		server: {
			configured: (state.configured ?? (settings.enabled == true)) == true,
			running: running,
			endpoint: (state.endpoint ?? settings.endpoint) ?? '',
			port: positiveInt(state.port ?? settings.port, 0),
			protocol: (state.protocol ?? settings.protocol) ?? '',
			allowWan: (state.allowWan ?? settings.allowWan) == true,
			pid: running ? (runtime.pid ?? null) : null,
			uptime: running ? (runtime.uptime ?? null) : null
		},
		statusAvailable: (snapshot.statusAvailable == true),
		updatedAt: (snapshot.updatedAt ?? null),
		clients: clients,
		accounts: list,
		totals: { online: length(clients), bytesReceived: received, bytesSent: sent },
		// 本机作为客户端连出去的那条链路。null 表示该项不可用（未导入/未运行），
		// 前端据此显示"未连接"，而不是把它和服务端混为一谈。
		client: clientLink,
		clientLog: clientLog
	};
}

export { parseStatus, readServerStatus, readServerPid, buildDetail, splitCsv, parseRealAddress, timestampToEpoch, elapsed, byteCount, parseClientLog, readClientLog, isManagementNoise, MAX_LOG_LINES };
