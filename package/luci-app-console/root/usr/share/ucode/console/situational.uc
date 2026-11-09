// SPDX-License-Identifier: Apache-2.0
// 态势感知后端：威胁情报黑名单 + 自动阻断 + 攻击统计。
// - 威胁情报源：Spamhaus DROP/EDROP、DShield TOP、Feodo C2、URLhaus 域名（均可开关）。
// - 自动阻断：nftables console_threat 表（set + counter），支持临时黑名单（到期自动移除）。
// - 行为识别：扫描 CSG:/CST: 内核日志，同一来源短时高频命中即自动拉黑。
import { open, readfile, rename, unlink, stat, chmod, popen, mkdir, lsdir, rmdir } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import { ROOT, DATA, config as secConfig, geoMeta, geoPath, geoLookup, ipKey, command, output, exec, query, sqlExec, readJson, writeText, writeJson, ensure } from 'console.security';

const TROOT = '/etc/console-situational';
const TDATA = '/srv/console-situational';
const TCONF = TROOT + '/config.json';
const NFT = '/tmp/console-threat.nft';
const HOSTS = '/tmp/console-threat.hosts';
const LOCK = '/tmp/console-situational-write.lock';
// 内核环形缓冲实测只有约 128KiB / 576 行（不是 1MiB），所以原来的 4000
// 是个永远触不到的假保护。这里取 1000：足够覆盖整环，又不会让 shell
// 管道白白处理超量数据。真正的解决办法是同时读 logread，见 kernelEvents()。
const LOG_TAIL = 1000;
const RETENTION = 30 * 86400;
const EVENT_HEALTH = TDATA + '/event-health.json';
const COUNTRIES = {
	'CN':[104.1,35.9],'US':[-98.5,39.8],'RU':[100.0,61.5],'DE':[10.4,51.2],'FR':[2.5,46.6],
	'GB':[-1.5,52.9],'NL':[5.3,52.1],'BR':[-53.2,-10.8],'IN':[79.0,21.8],'JP':[139.7,36.2],
	'KR':[127.8,36.5],'KP':[127.2,40.0],'VN':[106.3,16.6],'TH':[101.0,15.1],'ID':[118.0,-5.1],
	'MY':[102.0,4.2],'SG':[103.8,1.35],'PH':[122.9,11.8],'TW':[121.0,23.7],'HK':[114.2,22.3],
	'MO':[113.5,22.2],'UA':[31.2,49.0],'PL':[19.4,52.1],'RO':[25.0,45.9],'BG':[25.5,42.8],
	'MD':[28.5,47.2],'BY':[28.0,53.7],'TR':[35.2,39.0],'IR':[53.7,32.4],'IQ':[43.8,33.2],
	'SA':[45.1,24.0],'AE':[54.3,23.9],'IL':[34.9,31.4],'EG':[30.8,26.8],'ZA':[25.1,-29.0],
	'NG':[8.7,9.1],'KE':[37.9,0.2],'MA':[-6.8,31.9],'DZ':[2.6,28.2],'TN':[9.5,34.0],
	'MX':[-102.5,23.6],'AR':[-64.0,-34.0],'CL':[-71.4,-35.7],'CO':[-74.3,4.6],'PE':[-75.0,-9.2],
	'VE':[-66.6,7.1],'EC':[-78.5,-1.4],'AU':[134.5,-25.7],'NZ':[172.8,-41.5],'CA':[-106.3,56.1],
	'ES':[-3.7,40.2],'PT':[-8.2,39.6],'IT':[12.6,42.5],'CH':[8.2,46.8],'AT':[14.1,47.6],
	'BE':[4.5,50.6],'SE':[15.6,60.1],'NO':[9.5,60.5],'DK':[9.4,56.0],'FI':[26.0,62.0],
	'IE':[-8.0,53.2],'GR':[22.9,39.1],'CZ':[15.3,49.8],'SK':[19.5,48.7],'HU':[19.4,47.2],
	'LT':[24.0,55.3],'LV':[25.2,56.9],'EE':[25.7,58.7],'KZ':[67.3,48.0],'PK':[69.4,30.4],
	'BD':[90.4,23.7],'LK':[80.7,7.9],'NP':[84.1,28.3],'KH':[105.0,12.6],'MM':[96.5,21.2],
	'LA':[103.8,18.2],'MN':[103.1,46.8],'UZ':[63.2,41.4],'AZ':[47.6,40.3],'GE':[43.5,42.2],
	'AM':[45.0,40.3],'SY':[38.5,35.0],'JO':[36.8,31.3],'LB':[35.9,33.9],'YE':[47.5,15.6],
	'LY':[17.2,27.0],'SD':[30.2,15.5],'ET':[39.6,8.6],'TZ':[34.9,-6.4],'GH':[-1.0,7.9],
	'CI':[-5.6,7.6],'SN':[-14.5,14.5],'CM':[12.7,5.7],'CD':[23.7,-2.9],'AO':[17.5,-12.3],
	'ZM':[27.8,-13.1],'ZW':[29.9,-19.0],'MZ':[35.5,-18.7],'MG':[46.7,-19.4],'BW':[24.7,-22.3]
};
function fail(s) { die(s + '\n'); }
function sh(s) { return "'" + replace('' + s, /'/g, "'\\''") + "'"; }
function sq(s) { return "'" + replace('' + s, "'", "''") + "'"; }
function tCommand(args) { return join(' ', map(args, sh)); }
function tOutput(args) { const p = popen(tCommand(args)); if (!p) return ''; const s = p.read('all') || ''; p.close(); return s; }
// 带退出码的命令执行：rpcd 子进程里全局 system() 会报 Operation not permitted，改走 popen
function tRun(args) {
	const p = popen(tCommand(args) + ' 2>/dev/null; echo RC=$?');
	if (!p) return -1;
	const out = p.read('all') || '';
	p.close();
	const m = match(trim(out), /RC=(\d+)$/);
	return m ? +m[1] : -1;
}
function tWriteText(path, text) { writeText(path, text); }
function tReadJson(path, fallback) { try { return json(readfile(path) || ''); } catch (e) { return fallback; } }
function tWriteJson(path, data) { writeJson(path, data); }
function ensureT() { mkdir(TROOT); mkdir(TDATA); chmod(TROOT, 0700); chmod(TDATA, 0700); }
function threatConfig() { const c = tReadJson(TCONF, null) || {}; if (c.feeds == null) c.feeds = {}; // 默认开启全部源（含新增 FireHOL）
	for (let k in ['drop', 'dshield', 'feodo', 'firehol1', 'firehol2', 'urlhaus']) if (c.feeds[k] == null) c.feeds[k] = true;
	return { autoBlock:true, threatFeed:true, dnsSink:true, feeds:c.feeds, scanWindow:600, scanThreshold:10, banHours:24, maxDynamic:512, revision:0, ...c };
}
function saveThreatConfig(next) {
	ensureT();
	const current = threatConfig();
	next.revision = (+(current.revision || 0)) + 1;
	writeJson(TCONF, next);
	return next;
}
function threatLock() {
	ensureT();
	if (!mkdir(LOCK)) {
		const owner = tReadJson(LOCK + '/owner.json', null), live = owner ? split(readfile('/proc/' + owner.pid + '/stat') || '', ' ') : [];
		if ((owner && (!length(live) || live[21] != owner.start)) || (!owner && time() - (stat(LOCK)?.mtime || time()) > 10)) {
			unlink(LOCK + '/owner.json'); unlink(LOCK + '/owner.json.new');
			if (!rmdir(LOCK)) fail('态势感知任务正在执行');
			if (!mkdir(LOCK)) fail('态势感知任务正在执行');
		} else fail('另一个态势感知任务正在执行');
	}
	const me = split(readfile('/proc/self/stat') || '', ' ');
	writeJson(LOCK + '/owner.json', { pid: +me[0], start: me[21] });
}
function threatUnlock() { if (stat(LOCK)) { unlink(LOCK + '/owner.json'); unlink(LOCK + '/owner.json.new'); rmdir(LOCK); } }
function withThreatLock(fn) {
	threatLock();
	try { const r = fn(); threatUnlock(); return r; }
	catch (e) { threatUnlock(); die(e.message || '态势感知任务失败'); }
}
/* ---------------- 日志解析（CSG: 地区规则 / CST: 威胁黑名单） ---------------- */
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
function logStamp(when) {
	const m = match(when, /^(\w{3}) (\w{3}) +(\d{1,2}) (\d{1,2}):(\d{2}):(\d{2})$/);
	if (!m) return null;
	const mon = index(MONTHS, m[2]); if (mon < 0) return null;
	const now = time(), days = int(now / 86400);
	const g = gmtime(now), l = localtime(now);
	const tz = (l.year * 31536000 + l.mon * 2592000 + l.mday * 86400 + l.hour * 3600 + l.min * 60 + l.sec) - (g.year * 31536000 + g.mon * 2592000 + g.mday * 86400 + g.hour * 3600 + g.min * 60 + g.sec);
	for (let back = 1; back >= -1; back--) {
		const base = (days - back) * 86400, day = gmtime(base);
		if (day.mon != mon + 1 || day.mday != +m[3]) continue;
		// syslog 的时间戳是本地时间，换算 epoch 要减去时区偏移。原先加了偏移，
		// 在东八区会把每条记录推到 16 小时之后，随即被下面的未来时间保护丢弃，
		// 于是所有统计都变成 0（时区为 UTC 时才会正常）。
		const stamp = base + (+m[4]) * 3600 + (+m[5]) * 60 + (+m[6]) - tz;
		return stamp > now + 120 ? null : stamp;
	}
	return null;
}
// ucode 的函数没有声明提升，eventDir() 会用到 isPrivateIP()，
// 所以必须把它定义在前面，否则 overview() 一调用就报
// "access to undeclared variable isPrivateIP"。
function isPrivateIP(ip) {
	if (match(ip, /^10\./) || match(ip, /^192\.168\./) || match(ip, /^127\./) || match(ip, /^169\.254\./) || match(ip, /^172\.(1[6-9]|2[0-9]|3[01])\./)) return true;
	if (match(ip, /^fe80:/i) || match(ip, /^fc/i) || match(ip, /^fd/i) || match(ip, /^::1$/)) return true;
	return false;
}
// 日志里的规则名同时编码了方向：tin=input / tfi=fwd_in / tfo=fwd_out。
// 旧格式（只有 "threat"）没有方向信息，退回按地址推断。
const THREAT_DIR = { tin: 'input', tfi: 'fwd_in', tfo: 'fwd_out' };
function eventDir(rule, src, dst) {
	const d = THREAT_DIR[rule];
	if (d) return d;
	// 兼容历史数据：两侧都私网视为内网互访，其余按哪一侧是私网判断。
	const s = isPrivateIP(src), t = isPrivateIP(dst);
	if (s && t) return 'input';
	if (s) return 'fwd_out';
	if (t) return 'fwd_in';
	return 'input';
}
// input 钩子的日志里 OUT= 是**空值**（"OUT= MAC=..."），只有 forward 才有出接口。
// 旧正则写成 OUT=\S+ 要求至少一个非空白字符，于是 input 方向（外网→路由器）
// 的每一条记录都匹配失败、被静默丢弃，这个方向的统计永远是 0。
const CS_LOG_RE = /(CS[GT]):([a-z0-9]+) IN=\S* OUT=\S* +(MAC=\S+ +)?SRC=([0-9A-Fa-f:.]+) DST=([0-9A-Fa-f:.]+)/;
const CS_LOG_RE_SIMPLE = /(CS[GT]):([a-z0-9]+) .*SRC=([0-9A-Fa-f:.]+) DST=([0-9A-Fa-f:.]+)/;
function parseKernelLog(line) {
	const head = match(line, /^(\w{3} \w{3} +\d{1,2} \d{1,2}:\d{2}:\d{2}) /);
	if (!head) return null;
	const tag = match(line, CS_LOG_RE);
	const stamp = logStamp(head[1]);
	if (tag) {
		// 逐字段提取端口：PROTO=\S+ 贪婪匹配会吞掉后面的 SPT/DPT
		const proto = match(line, /PROTO=([A-Za-z0-9]+)/), spt = match(line, / SPT=(\d+)/), dpt = match(line, / DPT=(\d+)/);
		return { kind: tag[1] == 'CSG' ? 'region' : 'threat', rule: tag[2], src: tag[4], dst: tag[5], proto: proto ? proto[1] : '', spt: spt ? spt[1] : '', dport: dpt ? dpt[1] : '', stamp };
	}
	const simple = match(line, CS_LOG_RE_SIMPLE);
	if (simple) {
		const dpt = match(line, / DPT=(\d+)/);
		return { kind: simple[1] == 'CSG' ? 'region' : 'threat', rule: simple[2], src: simple[3], dst: simple[4], proto: '', spt: '', dport: dpt ? dpt[1] : '', stamp };
	}
	return null;
}
function parseDmesgLog(line, stamp) {
	const tag = match(line, CS_LOG_RE);
	if (!tag) return null;
	const proto = match(line, /PROTO=([A-Za-z0-9]+)/), spt = match(line, / SPT=(\d+)/), dpt = match(line, / DPT=(\d+)/);
	return { kind: tag[1] == 'CSG' ? 'region' : 'threat', rule: tag[2], src: tag[4], dst: tag[5], proto: proto ? proto[1] : '', spt: spt ? spt[1] : '', dport: dpt ? dpt[1] : '', stamp };
}
function kernelEvents() {
	const events = [], seen = {};
	const boot = trim(readfile('/proc/sys/kernel/random/boot_id') || '');
	const bm = match(readfile('/proc/stat') || '', /btime\s+(\d+)/);
	if (!bm) fail('无法读取内核启动时间');
	for (let cmd in ["dmesg 2>/dev/null", "logread 2>/dev/null"]) {
		const raw = tOutput(['/bin/sh', '-c', cmd + " | grep -E 'CS[GT]:' | tail -n " + LOG_TAIL]);
		for (let line in split(trim(raw), '\n')) {
			const m = match(line, /\[\s*(\d+\.\d+)\]/);
			// Require the kernel timestamp: userspace logger messages are not evidence of a drop.
			if (!m) continue;
			const ev = parseDmesgLog(line, int(+bm[1] + +m[1]));
			if (!ev) continue;
			ev.id = join(':', [boot, m[1], ev.kind, ev.rule, ev.src, ev.dst, ev.proto, ev.spt, ev.dport]);
			if (seen[ev.id]) continue;
			seen[ev.id] = true;
			push(events, ev);
		}
	}
	return events;
}
const EVENTS_SCHEMA = 'CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,ts INTEGER NOT NULL,kind TEXT,rule TEXT,src TEXT,dst TEXT,proto TEXT,spt TEXT,dport TEXT) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS events_ts ON events(ts);';
function migrateEvents() {
	sqlExec('CREATE TABLE IF NOT EXISTS events_quarantine(id TEXT PRIMARY KEY,ts INTEGER,kind TEXT,rule TEXT,src TEXT,dst TEXT,proto TEXT,spt TEXT,dport TEXT,reason TEXT) WITHOUT ROWID;');
	const sql = query("SELECT sql FROM sqlite_master WHERE type='table' AND name='events';")[0]?.sql || '';
	if (!length(sql)) { sqlExec(EVENTS_SCHEMA); return; }
	if (index(sql, 'id TEXT PRIMARY KEY') >= 0) return;
	// Transactional copy preserves every existing record and rolls back on any failure.
	sqlExec('BEGIN IMMEDIATE;' +
		'CREATE TABLE events_new(id TEXT PRIMARY KEY,ts INTEGER NOT NULL,kind TEXT,rule TEXT,src TEXT,dst TEXT,proto TEXT,spt TEXT,dport TEXT) WITHOUT ROWID;' +
		"INSERT INTO events_new SELECT 'legacy:' || ROW_NUMBER() OVER (),ts,kind,rule,src,dst,COALESCE(proto,''),COALESCE(spt,''),COALESCE(dport,'') FROM events;" +
		'DROP TABLE events; ALTER TABLE events_new RENAME TO events; CREATE INDEX events_ts ON events(ts); COMMIT;');
}
function collectEvents(now, since) {
	try {
		migrateEvents();
		const events = kernelEvents(), st = ['BEGIN IMMEDIATE;'];
		let last = 0;
		for (let ev in events) {
			if (ev.stamp < now - RETENTION || ev.stamp > now + 120) continue;
			last = max(last, ev.stamp);
			// Suppress replay of pre-migration records without collapsing new same-second packets.
			push(st, 'INSERT OR IGNORE INTO events SELECT ' + sq(ev.id) + ',' + int(ev.stamp) + ',' + sq(ev.kind) + ',' + sq(ev.rule) + ',' + sq(ev.src) + ',' + sq(ev.dst) + ',' + sq(ev.proto) + ',' + sq(ev.spt) + ',' + sq(ev.dport) +
				' WHERE NOT EXISTS(SELECT 1 FROM events_quarantine WHERE id=' + sq(ev.id) + ')' +
				" AND NOT EXISTS(SELECT 1 FROM events WHERE id LIKE 'legacy:%' AND ts BETWEEN " + int(ev.stamp-1) + ' AND ' + int(ev.stamp+1) + ' AND src=' + sq(ev.src) + ' AND dst=' + sq(ev.dst) + ' AND rule=' + sq(ev.rule) + ' AND proto=' + sq(ev.proto) + ' AND spt=' + sq(ev.spt) + ' AND dport=' + sq(ev.dport) + ');');
		}
		// Expiration runs even when no new packets arrive.
		push(st, 'DELETE FROM events WHERE ts<' + int(now - RETENTION) + ';', 'DELETE FROM events_quarantine WHERE ts<' + int(now-RETENTION) + ';', 'COMMIT;');
		sqlExec(join('\n', st));
		tWriteJson(EVENT_HEALTH, { time: now, ok: true, count: length(events), retentionDays: 30 });
		return { count: length(events), last };
	} catch (e) {
		tWriteJson(EVENT_HEALTH, { time: now, ok: false, error: e.message || '事件写库失败' });
		die(e.message || '事件写库失败');
	}
}
function storedEvents(seconds) {
	// No arbitrary row cap: aggregate in SQLite before feeding the dashboard.
	return query("SELECT MAX(ts) AS stamp,(ts/300)*300 AS bucket,kind,rule,src,dst,proto,dport,COUNT(*) AS n,SUM(CASE WHEN id LIKE 'legacy:%' THEN 1 ELSE 0 END) AS legacyCount FROM events WHERE ts>=" + int(time()-seconds) + ' AND ts<=' + int(time()) + ' GROUP BY bucket,kind,rule,src,dst,proto,dport ORDER BY stamp DESC;');
}
/* ---------------- 动态黑名单 ---------------- */
function dynPath() { return TDATA + '/dynamic.json'; }
function dynamicList() { return tReadJson(dynPath(), { items: {} }); }
function dynamicSave(list) { writeJson(dynPath(), list); }
function dynamicActive(list) {
	const now = time(), items = {};
	for (let ip, item in list.items || {}) if (item.until > now) items[ip] = item;
	return items;
}
function dynamicAdd(ip, reason, hours, max) {
	const list = dynamicList(), now = time();
	const active = dynamicActive(list);
	if (length(keys(active)) >= max && !active[ip]) return { added: false, full: true };
	active[ip] = { until: now + hours * 3600, reason, added: now };
	list.items = active;
	dynamicSave(list);
	return { added: active[ip].added == now && active[ip].until == now + hours * 3600 ? true : false, full: false };
}
function dynamicPrune() { const list = dynamicList(); list.items = dynamicActive(list); dynamicSave(list); }
/* ---------------- 行为自动阻断扫描 ---------------- */
function clampInt(value, low, high) { const n = int(+value || 0); return n < low ? low : n > high ? high : n; }
function behaviorScan(cfg) {
	const window = clampInt(cfg.scanWindow, 60, 86400), threshold = clampInt(cfg.scanThreshold, 3, 1000), hours = clampInt(cfg.banHours, 1, 720), max = clampInt(cfg.maxDynamic, 16, 2048);
	const now = time(), counters = {}, bindings = tReadJson('/tmp/console-security-bindings.json', {});
	const stateDevices = tReadJson('/tmp/console-security-state.json', {}).devices || [];
	const events = kernelEvents();
	let scanned = 0;
	for (let ev in events) {
		if (ev.kind != 'region' || ev.stamp == null || now - ev.stamp > window) continue;
		scanned++;
		if (!counters[ev.src]) counters[ev.src] = 0;
		counters[ev.src]++;
	}
	const list = dynamicList(), activeBefore = dynamicActive(list);
	let added = 0;
	const actions = [];
	for (let ip, n in counters) {
		if (n >= threshold && !activeBefore[ip]) {
			const r = dynamicAdd(ip, '高频命中地区规则 ' + n + ' 次/' + int(window / 60) + ' 分钟', hours, max);
			if (r.added || !r.full) { added++; push(actions, { ip, hits: n, action: 'banned' }); }
			else push(actions, { ip, hits: n, action: 'list-full' });
		}
	}
	return { scanned, added, actions };
}
/* ---------------- 威胁情报表编译 ---------------- */
function nftList(values) { return '{ ' + join(', ', map(values, v => sprintf('%J', v))) + ' }'; }
function networkDevices() {
	const bus = connect(); const dump = bus?.call('network.interface', 'dump'); bus?.disconnect();
	const c = cursor(), roles = { lan: [], wan: [] }, devices = { lan: [], wan: [] };
	c.foreach('firewall', 'zone', z => { if (z.name == 'lan' || z.name == 'wan') roles[z.name] = type(z.network) == 'array' ? z.network : split(z.network || '', /\s+/); });
	for (let iface in dump?.interface || []) for (let role in ['lan', 'wan']) if (index(roles[role], iface.interface) >= 0) {
		const name = iface.l3_device || iface.device;
		if (name && match(name, /^[A-Za-z0-9_.:@-]{1,64}$/) && index(devices[role], name) < 0) push(devices[role], name);
	}
	return devices;
}
// 拦截规则的日志速率上限：dmesg 环形缓冲实测只有几百行，日志不封顶会在
// 一次攻击里把缓冲整个刷掉，连带把地区规则事件挤出缓冲（表现为"统计忽然归零"）。
const LOG_RATE = 'limit rate 10/second burst 20 packets';
// 方向编码写进日志前缀，采集器据此判定 input / fwd_in / fwd_out。
// 不能靠地址推断：本机 WAN 地址本身可能是私网（上级 NAT），input 事件的目的
// 地址就是私网地址，会被误判成 fwd_in。
function gateRules(lines, match, setExpr, counter, tag) {
	// 两条规则：先记录（独立限速），再无条丢弃。
	//
	// 旧写法是一条：
	//   ... counter name X ip saddr @blacklist4 log prefix "CST:threat " limit rate 2/second burst 4 packets drop
	// 这里有两个致命问题：
	//   1. counter 在匹配之前 —— 统计的是"所有 WAN 新连接"，不是被拦截的包；
	//   2. limit 是匹配表达式且位于 drop 之前 —— 超出速率的包不匹配整条规则，
	//      既不丢弃也不记录，实测 burst=1 时 121 个包只挡下 1 个，黑名单形同虚设。
	push(lines, match + ' ' + setExpr + ' ' + LOG_RATE + ' log prefix "CST:' + tag + ' "');
	push(lines, match + ' ' + setExpr + ' counter name ' + counter + ' drop');
}
function compileThreatNft(cfg, counts) {
	const net = networkDevices(), lines = ['destroy table inet console_threat', 'table inet console_threat {', 'counter threats_in { comment \"' + trim(readfile('/proc/sys/kernel/random/uuid')) + '\"; }', 'counter threats_fwd_in { }', 'counter threats_fwd_out { }'];
	for (let role in ['lan', 'wan']) push(lines, 'set ' + role + ' { type ifname;' + (length(net[role]) ? ' elements = ' + nftList(net[role]) + ';' : '') + ' }');
	// 情报黑名单：IPv4/IPv6 各一个 set，入站与出站都匹配
	for (let f in [4, 6]) push(lines, 'set blacklist' + f + ' { type ' + (f == 4 ? 'ipv4_addr' : 'ipv6_addr') + '; flags interval; auto-merge;' + (counts['blacklist' + f] ? ' elements = ' + counts['blacklist' + f] + ';' : '') + ' }');
	push(lines, 'chain input_gate { type filter hook input priority -6; policy accept;');
	gateRules(lines, 'iifname @wan ct state { new, untracked }', 'ip saddr @blacklist4', 'threats_in', 'tin');
	gateRules(lines, 'iifname @wan ct state { new, untracked }', 'ip6 saddr @blacklist6', 'threats_in', 'tin');
	push(lines, '}');
	push(lines, 'chain forward_gate { type filter hook forward priority -6; policy accept;');
	gateRules(lines, 'iifname @wan oifname @lan ct state { new, untracked }', 'ip saddr @blacklist4', 'threats_fwd_in', 'tfi');
	gateRules(lines, 'iifname @wan oifname @lan ct state { new, untracked }', 'ip6 saddr @blacklist6', 'threats_fwd_in', 'tfi');
	gateRules(lines, 'iifname @lan oifname @wan ct state { new, untracked }', 'ip daddr @blacklist4', 'threats_fwd_out', 'tfo');
	gateRules(lines, 'iifname @lan oifname @wan ct state { new, untracked }', 'ip6 daddr @blacklist6', 'threats_fwd_out', 'tfo');
	push(lines, '}');
	push(lines, '}');
	return join('\n', lines) + '\n';
}
function tExec(args) { const rc = tRun(args); if (rc != 0) fail('执行失败：' + args[0]); }
function guardExistsThreat() { return match(tOutput(['/usr/sbin/nft', 'list', 'tables']), /table inet console_threat(\n|$)/) != null; }
/* ---------------- 状态与统计 ---------------- */
// 每次威胁情报刷新都会 destroy 整表重建，nft 计数器随之归零。
// 页面写的是"24小时拦截"，如果直接读 nft 计数器，刷新后就掉回 0，
// 与数据库口径必然打架。所以把每次重建前的读数累加到一个基准值里，
// 页面显示 = 基准值 + 当前表内读数。
const COUNTER_BASE = TDATA + '/counter-base.json';
function counterBase() { return tReadJson(COUNTER_BASE, { inPkts: 0, fwdInPkts: 0, fwdOutPkts: 0 }); }
function counterSave(base) { try { tWriteJson(COUNTER_BASE, base); } catch (e) { warn('保存计数器基准失败\n'); } }
// 在 destroy 重建之前调用，把当前表里的累计值折算进基准。
function threatCounters() {
	const base = counterBase();
	const out = guardExistsThreat() ? tOutput(['/usr/sbin/nft', '-j', 'list', 'counters', 'table', 'inet', 'console_threat']) : '';
	let inPkts = 0, outPkts = 0, fwdInPkts = 0, fwdOutPkts = 0;
	// The JSON list also contains a "metainfo" record without a counter object;
	// dereferencing e.counter.packets on it threw and silently zeroed every value.
	try { for (let e in json(out)?.nftables || []) {
		const counter = e.counter;
		if (!counter) continue;
		const n = counter.name, p = +counter.packets || 0;
		if (n == 'threats_in') inPkts += p;
		else if (n == 'threats_fwd_in') fwdInPkts += p;
		else if (n == 'threats_fwd_out') fwdOutPkts += p;
		else if (n == 'threats_out') outPkts += p; // 兼容旧表
	} } catch (e) {}
	// 三个方向各管一摊，不能互相相加：页面把它们分列显示。
	// 旧实现把 fwd_in 加进 inPkts、fwd_out 加进 outPkts，显示必然重复计数。
	return {
		inPkts: inPkts + (+base.inPkts || 0),
		outPkts: outPkts,
		fwdInPkts: fwdInPkts + (+base.fwdInPkts || 0),
		fwdOutPkts: fwdOutPkts + (+base.fwdOutPkts || 0)
	};
}
function counterAccumulate() {
	const cur = threatCounters(), base = {};
	base.inPkts = (+base.inPkts || 0) + (+cur.inPkts || 0);
	base.fwdInPkts = (+base.fwdInPkts || 0) + (+cur.fwdInPkts || 0);
	base.fwdOutPkts = (+base.fwdOutPkts || 0) + (+cur.fwdOutPkts || 0);
	counterSave(base);
}
// Packet totals are independent of rate-limited event logs. Baselines and deltas
// commit together, so collector restarts and retries cannot double-count.
function withPacketLock(fn) {
	const path = '/tmp/console-threat-packets.lock';
	if (!mkdir(path)) {
		const owner = tReadJson(path+'/owner.json', null);
		const live = owner ? split(readfile('/proc/'+owner.pid+'/stat') || '', ' ') : [];
		if ((owner && (!length(live) || live[21]!=owner.start)) || (!owner && time()-(stat(path)?.mtime || time())>10)) {
			unlink(path+'/owner.json'); unlink(path+'/owner.json.new'); rmdir(path);
			if (!mkdir(path)) fail('黑名单计数正在采集');
		} else fail('黑名单计数正在采集');
	}
	const me = split(readfile('/proc/self/stat') || '', ' ');
	writeJson(path+'/owner.json', {pid:+me[0],start:me[21]});
	try { const result=fn(); unlink(path+'/owner.json'); rmdir(path); return result; }
	catch(e) { unlink(path+'/owner.json'); rmdir(path); die(e.message || '计数写库失败'); }
}
function persistPacketsUnlocked(now) {
	const raw = tOutput(['/usr/sbin/nft', '-j', 'list', 'counters', 'table', 'inet', 'console_threat']);
	if (!length(trim(raw)) && guardExistsThreat()) fail('无法读取威胁计数器');
	const counters = length(trim(raw)) ? filter(json(raw).nftables || [], e => e.counter) : [];
	const boot = trim(readfile('/proc/sys/kernel/random/boot_id'));
	const gen = boot + ':' + (filter(counters, e=>e.counter.name=='threats_in')[0]?.counter?.comment || 'legacy');
	const st = ['BEGIN IMMEDIATE;',
		'CREATE TABLE IF NOT EXISTS threat_baseline(name TEXT PRIMARY KEY,generation TEXT,raw INTEGER,updated INTEGER);',
		'CREATE TABLE IF NOT EXISTS threat_packets(ts INTEGER,name TEXT,packets INTEGER,PRIMARY KEY(ts,name)) WITHOUT ROWID;',
		'CREATE TABLE IF NOT EXISTS threat_meta(id INTEGER PRIMARY KEY,since INTEGER,updated INTEGER);',
		];
	if (length(counters)) push(st, 'INSERT OR IGNORE INTO threat_meta VALUES(1,'+int(now)+','+int(now)+');');
	for (let item in counters) {
		const c = item.counter;
		if (!match(c.name || '', /^threats_(in|fwd_in|fwd_out)$/)) continue;
		const p = int(c.packets), name = sq(c.name), generation = sq(gen);
		// First observation is a baseline; its pre-upgrade age is unknown.
		push(st, 'INSERT INTO threat_packets SELECT '+int(now)+','+name+', CASE WHEN generation='+generation+' AND raw<='+p+' THEN '+p+'-raw ELSE '+p+' END FROM threat_baseline WHERE name='+name+' AND (generation!='+generation+' OR raw!='+p+') ON CONFLICT(ts,name) DO UPDATE SET packets=packets+excluded.packets;');
		push(st, 'INSERT INTO threat_baseline VALUES('+name+','+generation+','+p+','+int(now)+') ON CONFLICT(name) DO UPDATE SET generation=excluded.generation,raw=excluded.raw,updated=excluded.updated;');
	}
	push(st, 'UPDATE threat_meta SET updated='+int(now)+' WHERE id=1;', 'DELETE FROM threat_packets WHERE ts<'+int(now-RETENTION)+';', 'COMMIT;');
	sqlExec(join('\n',st));
}
function persistThreatPackets(now) { return withPacketLock(() => persistPacketsUnlocked(now)); }
function packetHistory(now) {
	const meta = query('SELECT since,updated FROM threat_meta WHERE id=1;')[0] || {};
	const totals = query('SELECT COALESCE(SUM(CASE WHEN ts>='+int(now-86400)+' THEN packets ELSE 0 END),0) AS total24,COALESCE(SUM(packets),0) AS total30 FROM threat_packets WHERE ts>='+int(now-RETENTION)+' AND ts<='+int(now)+';')[0];
	return { ...meta, ...totals };
}
function installThreat(text) {
	tWriteText(NFT, text);
	tExec(['/usr/sbin/nft', '-c', '-f', NFT]);
	withPacketLock(() => {
		persistPacketsUnlocked(time());
		tExec(['/usr/sbin/nft', '-f', NFT]);
	});
}
/* ---------------- 威胁情报下载 ---------------- */
function fetchFeed(url, limit) {
	const archive = '/tmp/console-threat-feed.tmp';
	// 网络不稳时重试 3 次
	for (let attempt = 0; attempt < 3; attempt++) {
		unlink(archive);
		if (tRun(['/usr/bin/wget', '-q', '-T', '30', '-O', archive, url]) == 0) {
			const text = readfile(archive) || '';
			if (length(trim(text))) { unlink(archive); return text; }
		}
		if (attempt < 2) tRun(['/bin/sleep', '3']);
	}
	unlink(archive);
	return null;
}
// FireHOL Level1 aggregates FullBogons, which contains private, loopback,
// link-local, CGNAT and multicast ranges. Blocking those would drop the
// router's own LAN/WAN neighbours (e.g. 10.0.0.0/8, 192.168.0.0/16) and also
// flood the dashboard with "threats" whose source/destination is internal.
function isLocalRange(ip) {
	const base = split(ip, '/')[0];
	if (index(base, ':') >= 0)
		return match(base, /^(::1?|::|f[cd][0-9a-f]{2}:|fe[89ab][0-9a-f]:)/i) != null;
	const octets = map(split(base, '.'), value => +value);
	if (length(octets) != 4 || octets[0] == null) return false;
	const a = octets[0], b = octets[1];
	if (a == 0 || a == 10 || a == 127 || a >= 224) return true;
	if (a == 172 && b >= 16 && b <= 31) return true;
	if (a == 192 && b == 168) return true;
	if (a == 169 && b == 254) return true;
	if (a == 100 && b >= 64 && b <= 127) return true;
	return false;
}
function parseFeedLines(text, kind) {
	const ips4 = [], ips6 = [];
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		let ip = line;
		if (kind == 'dshield') { // 格式：起始IP<TAB>结束IP<TAB>前缀长度<TAB>...
			const p = split(line, /\s+/);
			if (length(p) < 3) continue;
			ip = p[0] + '/' + p[2];
			if (!match(p[2], /^\d{1,2}$/)) continue;
		}
		if (kind == 'feodo') { ip = trim(line); }
		if (kind == 'drop') { const p = split(line, /\s*;\s*/); ip = p[0]; }
		if (kind == 'netset') { const p = split(line, /\s+/); ip = p[0]; } // FireHOL netset：每行一个 IP/CIDR
		if (isLocalRange(ip)) continue;
		if (match(ip, /^[0-9.]+\/\d{1,2}$/) || match(ip, /^[0-9.]+$/)) push(ips4, index(ip, '/') < 0 ? ip + '/32' : ip);
		else if (match(ip, /^[0-9a-fA-F:]+\/\d{1,3}$/) || match(ip, /^[0-9a-fA-F:]+$/)) push(ips6, index(ip, '/') < 0 ? ip + '/128' : ip);
	}
	return { ips4, ips6 };
}
const FEEDS = {
	drop: { url: 'https://www.spamhaus.org/drop/drop.txt', kind: 'drop', label: 'Spamhaus DROP' },
	dshield: { url: 'https://www.dshield.org/block.txt', kind: 'dshield', label: 'DShield TOP' },
	feodo: { url: 'https://feodotracker.abuse.ch/downloads/ipblocklist.txt', kind: 'feodo', label: 'Feodo C2' },
	firehol1: { url: 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset', kind: 'netset', label: 'FireHOL Level1（DROP+DShield+Feodo+FullBogons 聚合）' },
	firehol2: { url: 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset', kind: 'netset', label: 'FireHOL Level2（近48小时活跃攻击）' }
};
function applyDnsmasq(hostsFile) {
	const UCI_HOSTS = '/etc/dnsmasq.d/console-threat.conf';
	if (hostsFile) {
		tWriteText(UCI_HOSTS, 'addn-hosts=' + hostsFile + '\n');
	} else unlink(UCI_HOSTS);
	if (tOutput(['/bin/sh', '-c', 'ls /var/etc/dnsmasq.conf.* 2>/dev/null']) != '') tRun(['/etc/init.d/dnsmasq', 'reload']);
}
const DNS_SINK_URL = 'https://urlhaus.abuse.ch/downloads/hostfile/';
function updateThreatFeeds() {
	return withThreatLock(() => {
		ensureT();
		const cfg = threatConfig();
		const meta = tReadJson(TDATA + '/feeds.json', { sources: {} });
		const merged4 = [], merged6 = [], hosts = [], status = {};
		for (let key, feed in FEEDS) {
			if (!cfg.threatFeed || !cfg.feeds?.[key]) { status[key] = { ok: true, enabled: false, label: feed.label, count: 0 }; continue; }
			const cache = TDATA + '/feed-' + key + '.txt';
			const text = fetchFeed(feed.url, feed.kind);
			let fresh = text != null;
			let body = text;
			if (!fresh) {
				// 下载失败：回退到上次成功的数据缓存，保证黑名单不缩水
				try { const cached = readfile(cache); if (cached && length(trim(cached))) body = cached; } catch (e) {}
			}
			if (body == null) { status[key] = { ok: false, enabled: true, label: feed.label, error: '下载失败且无缓存' }; continue; }
			const parsed = parseFeedLines(body, feed.kind);
			if (!length(parsed.ips4) && !length(parsed.ips6)) { status[key] = { ok: false, enabled: true, label: feed.label, error: '内容解析为空' }; continue; }
			if (fresh) tWriteText(cache, body);
			for (let ip in parsed.ips4) push(merged4, ip);
			for (let ip in parsed.ips6) push(merged6, ip);
			status[key] = { ok: true, enabled: true, label: feed.label, count: length(parsed.ips4) + length(parsed.ips6), updated: time(), cached: !fresh };
		}
		if (cfg.threatFeed && cfg.feeds?.urlhaus) {
			const text = fetchFeed(DNS_SINK_URL, 'hosts');
			if (text != null) {
				let n = 0;
				for (let line in split(text, '\n')) {
					line = trim(line);
					if (!length(line) || substr(line, 0, 1) == '#') continue;
					const p = split(line, /\s+/);
					const host = p[1] || '';
					if (p[0] == '0.0.0.0' && match(host, /^[a-zA-Z0-9.-]+$/) && length(hosts) < 20000) { push(hosts, host); n++; }
				}
				status.urlhaus = { ok: true, enabled: true, label: 'URLhaus 恶意域名', count: n, updated: time() };
			} else status.urlhaus = { ok: false, enabled: true, label: 'URLhaus 恶意域名', error: 'abuse.ch 现要求 Auth-Key，匿名下载已停用（410）' };
		} else status.urlhaus = { ok: true, enabled: false, label: 'URLhaus 恶意域名', count: 0 };
		// 去重合并并限制规模
		const uniq4 = uniq(merged4), uniq6 = uniq(merged6);
		if (length(uniq4) > 100000) fail('IPv4 黑名单超过10万条，拒绝加载');
		if (length(uniq6) > 20000) fail('IPv6 黑名单超过2万条，拒绝加载');
		// 生成 nft
		const counts = {
			blacklist4: length(uniq4) ? '{ ' + join(', ', uniq4) + ' }' : '',
			blacklist6: length(uniq6) ? '{ ' + join(', ', uniq6) + ' }' : ''
		};
		// 动态黑名单并入同一批 set
		dynamicPrune();
		const dyn = dynamicActive(dynamicList());
		const dyn4 = [], dyn6 = [];
		for (let ip, item in dyn) {
			if (match(ip, /^[0-9.]+$/)) push(dyn4, ip + '/32');
			else if (match(ip, /:/)) push(dyn6, ip + '/128');
		}
		for (let ip in dyn4) counts.blacklist4 = length(counts.blacklist4) ? substr(counts.blacklist4, 0, length(counts.blacklist4) - 2) + ', ' + ip + ' }' : '{ ' + join(', ', dyn4) + ' }';
		for (let ip in dyn6) counts.blacklist6 = length(counts.blacklist6) ? substr(counts.blacklist6, 0, length(counts.blacklist6) - 2) + ', ' + ip + ' }' : '{ ' + join(', ', dyn6) + ' }';
		let installed = false;
		try {
			// 重建会把 nft 计数器清零，先把已有读数累加进基准再动手。
			counterAccumulate();
			if (cfg.threatFeed && (length(uniq4) || length(dyn4) || length(dyn6))) { installThreat(compileThreatNft(cfg, counts)); installed = true; }
			else if (guardExistsThreat()) { withPacketLock(() => { persistPacketsUnlocked(time()); tExec(['/usr/sbin/nft', 'delete', 'table', 'inet', 'console_threat']); }); installed = false; }
		} catch (e) {
			status.nft = { ok: false, error: e.message || '规则加载失败' };
			writeJson(TDATA + '/feeds.json', { sources: status, updated: time() });
			die('威胁规则加载失败：' + (e.message || '未知错误'));
		}
		// dnsmasq 恶意域名拦截
		if (cfg.dnsSink && length(hosts)) {
			let hostText = '';
			for (let h in hosts) hostText += '0.0.0.0 ' + h + '\n';
			tWriteText(HOSTS, hostText);
		} else unlink(HOSTS);
		applyDnsmasq(cfg.dnsSink && length(hosts) ? HOSTS : null);
		writeJson(TDATA + '/feeds.json', { sources: status, updated: time(), installed, ip4: length(uniq4) + length(dyn4), ip6: length(uniq6) + length(dyn6), domains: length(hosts), dynamic: length(dyn4) + length(dyn6) });
		return { ok: true, status };
	});
}
function overview() {
	ensureT();
	const cfg = threatConfig(), feeds = tReadJson(TDATA + '/feeds.json', null), geo = geoMeta();
	const dyn = dynamicActive(dynamicList());
	const dynItems = [];
	for (let ip, item in dyn) push(dynItems, { ip, reason: item.reason, added: item.added, until: item.until });
	// 统计只读数据库：采集器负责把内核拦截事件落库，页面不再依赖日志缓冲。
	const now = time(), events = storedEvents(86400);
	const packetStats = packetHistory(now);
	const health = tReadJson(EVENT_HEALTH, null);
	const warnings = [];
	if (!health || !health.ok || now-health.time>60) push(warnings, health?.error || '事件采集停止或尚未完成');
	if (!packetStats.since || now-packetStats.updated>60) push(warnings, '黑名单包计数采集停止或尚未完成');
	const byCountry = {}, bySource = {}, timeline = [];
	const rules = {}, ruleDir = {};
	for (let r in secConfig().rules || []) { rules[r.id] = r.name; ruleDir[r.id] = r.direction; }
	const geoCache = {};
	let regionBlocked = 0, threatBlocked = 0, last24 = 0, legacy24 = 0;
	// 内网设备识别：IP → MAC/设备名（绑定表 + 在线设备状态）
	const bindings = readJson('/tmp/console-security-bindings.json', {});
	const stateDevices = readJson('/tmp/console-security-state.json', {}).devices || [];
	const devCache = {};
	function deviceNameOf(ip) {
		if (ip in devCache) return devCache[ip];
		let out = { ip: ip, mac: '', name: '' };
		const parsed = ipKey(ip);
		if (parsed) {
			for (let mac, ips in bindings) {
				for (let addr in ips) {
					const p = ipKey(addr);
					if (p && p.family == parsed.family && p.key == parsed.key) {
						out.mac = mac;
						const d = filter(stateDevices, v => v.mac == mac || v.id == mac)[0];
						out.name = (d && (d.name || d.mac)) || mac;
						break;
					}
				}
				if (out.mac) break;
			}
		}
		devCache[ip] = out;
		return out;
	}
	// 三个方向：外网→路由器（input） / 外网→内网设备（fwd_in） / 内网设备→外网（fwd_out）
	// 三个方向：外网→路由器（input） / 外网→内网设备（fwd_in） / 内网设备→外网（fwd_out）
	const dirs = { input: {}, fwd_in: {}, fwd_out: {} };
	for (let k in dirs) dirs[k] = { count: 0, sources: {} };
	for (let ev in events) {
		if (ev.stamp == null || ev.stamp > now || now - ev.stamp > 86400) continue;
		const n = +ev.n || 1;
		// 方向判定必须先于任何过滤：判据来自日志前缀里的方向编码，
		// 不用地址推断。本机 WAN 地址可能是私网（上级 NAT），按地址判断会把
		// 外网→路由器的拦截误判成内网互访而丢弃。
		const dir = ev.kind == 'threat' ? eventDir(ev.rule, ev.src, ev.dst) : ((ruleDir[ev.rule] == 'outgoing') ? 'fwd_out' : (ruleDir[ev.rule] == 'incoming') ? 'fwd_in' : 'input');
		// 内外网两侧都私网的威胁事件才是脏数据（早期版本按地址猜方向留下的），
		// 单侧私网是正常的 fwd_in / fwd_out，绝不能丢。
		if (ev.kind == 'threat' && !THREAT_DIR[ev.rule] && isPrivateIP(ev.src) && isPrivateIP(ev.dst)) continue;
		last24 += n;
		legacy24 += +ev.legacyCount || 0;
		if (ev.kind == 'region') { regionBlocked += n; if (!byCountry[ev.rule]) byCountry[ev.rule] = 0; byCountry[ev.rule] += n; }
		else threatBlocked += n;
		dirs[dir].count += n;
		// 列表要显示的是"外部那一侧"的地址，不能用 ev.src 一概而论：
		//   fwd_out（内网设备→外网黑名单）：外部是对端 dst，ev.src 是发起访问的内网设备
		//   fwd_in （外网→内网设备）       ：外部是来源 src，ev.dst 是被访问的内网设备
		//   input   （外网→路由器）        ：外部是来源 src
		// 旧实现一律用 ev.src 当"来源"，于是 fwd_out 的表里"外网来源"列显示的是
		// 内网设备 IP（192.168.1.x），和"内网设备"列是同一个地址，
		// 真正被拦截的外部目标（如 203.0.113.143）反而完全看不到。
		let remoteIp = ev.src, devIp = null;
		if (dir == 'fwd_out') { remoteIp = ev.dst; devIp = ev.src; }
		else if (dir == 'fwd_in') { devIp = ev.dst; }
		const dev = devIp ? deviceNameOf(devIp) : null;
		const sourceKey = join('|', [remoteIp, ev.kind, devIp || '']);
		if (!dirs[dir].sources[sourceKey]) dirs[dir].sources[sourceKey] = { src: remoteIp, kind: ev.kind, count: 0, last: 0, devIp: devIp || '', devMac: '', devName: '', ports: {} };
		dirs[dir].sources[sourceKey].count += n;
		dirs[dir].sources[sourceKey].last = max(dirs[dir].sources[sourceKey].last, ev.stamp);
		if (dev && dev.mac) { dirs[dir].sources[sourceKey].devIp = dev.ip; dirs[dir].sources[sourceKey].devMac = dev.mac; dirs[dir].sources[sourceKey].devName = dev.name; }
		if (ev.dport) dirs[dir].sources[sourceKey].ports[ev.dport] = (dirs[dir].sources[sourceKey].ports[ev.dport] || 0) + n;
		if (!bySource[remoteIp]) bySource[remoteIp] = { src: remoteIp, kind: ev.kind, count: 0, last: 0 };
		bySource[remoteIp].count += n;
		bySource[remoteIp].last = max(bySource[remoteIp].last, ev.stamp);
		push(timeline, { t: int(ev.stamp / 300) * 300, kind: ev.kind, n });
	}
	const dirTop = {};
	for (let k in dirs) {
		const list = sort(values(dirs[k].sources), (a, b) => b.count - a.count);
		for (let s in list) {
			const ports = keys(s.ports || {});
			s.port = length(ports) == 1 ? ports[0] : (length(ports) > 1 ? length(ports) + '个端口' : '');
			delete s.ports;
		}
		dirTop[k] = { count: dirs[k].count, top: slice(list, 0, 8) };
	}
	// 地图同时统计地区规则与威胁黑名单拦截。定位要用"外部那一侧"的地址：
	// fwd_out 事件的来源是内网设备，对着内网 IP 查国家只会全部落到 LAN，
	// 地图就一直是空的。外网地址优先取 src，src 是内网时改取 dst。
	const countryAgg = {};
	for (let ev in events) {
		if (ev.stamp == null || now - ev.stamp > 86400) continue;
		const n = +ev.n || 1;
		if (ev.kind == 'threat' && !THREAT_DIR[ev.rule] && isPrivateIP(ev.src) && isPrivateIP(ev.dst)) continue;
		const remote = !isPrivateIP(ev.src) ? ev.src : (!isPrivateIP(ev.dst) ? ev.dst : null);
		if (!remote) continue;
		if (!(remote in geoCache)) geoCache[remote] = geoLookup(remote);
		const cc = geoCache[remote].country || 'ZZ';
		if (!countryAgg[cc]) countryAgg[cc] = { cc, count: 0, sources: {} };
		countryAgg[cc].count += n;
		countryAgg[cc].sources[remote] = (countryAgg[cc].sources[remote] || 0) + n;
	}
	const mapPoints = [];
	for (let cc, agg in countryAgg) if (COUNTRIES[cc]) push(mapPoints, { cc, lat: COUNTRIES[cc][1], lon: COUNTRIES[cc][0], count: agg.count, sources: length(keys(agg.sources)) });
	const topSources = sort(values(bySource), (a, b) => b.count - a.count);
	const counters = threatCounters();
	// 24h 时间线（5分钟粒度）
	const buckets = {};
	for (let item in timeline) { if (!buckets[item.t]) buckets[item.t] = { t: item.t, region: 0, threat: 0 }; buckets[item.t][item.kind == 'region' ? 'region' : 'threat'] += item.n; }
	const series = sort(values(buckets), (a, b) => a.t - b.t);
	if (legacy24) push(warnings, '近24小时包含' + legacy24 + '条旧格式历史记录，无法逐包校验；列表按日志条数展示，不代表独立连接数或感染次数');
	return {
		ok: true,
		time: now,
		config: cfg,
		installed: guardExistsThreat(),
		feeds,
		counters,
		geo: geo ? { version: geo.version } : null,
		warnings,
		packetStats,
		retentionDays: 30,
		stats: { threatPackets24: packetStats.total24, threatPackets30: packetStats.total30, legacy24, region24: regionBlocked, threat24: threatBlocked, total24: last24, dynamic: length(dynItems), dnsEnabled: !!feeds?.domains },
		map: sort(mapPoints, (a, b) => b.count - a.count),
		top: slice(topSources, 0, 20),
		dirTop,
		series,
		dynamic: sort(dynItems, (a, b) => b.added - a.added)
	};
}
function setAutoBlock(input) {
	return withThreatLock(() => {
		const cfg = threatConfig();
		if (type(input) == 'object') {
			if (type(input.autoBlock) == 'bool') cfg.autoBlock = input.autoBlock;
			if (type(input.threatFeed) == 'bool') cfg.threatFeed = input.threatFeed;
			if (type(input.dnsSink) == 'bool') cfg.dnsSink = input.dnsSink;
			if (type(input.scanWindow) == 'num') cfg.scanWindow = clampInt(input.scanWindow, 60, 86400);
			if (type(input.scanThreshold) == 'num') cfg.scanThreshold = clampInt(input.scanThreshold, 3, 1000);
			if (type(input.banHours) == 'num') cfg.banHours = clampInt(input.banHours, 1, 720);
			if (type(input.feeds) == 'object') for (let k in ['drop', 'dshield', 'feodo', 'firehol1', 'firehol2', 'urlhaus']) if (type(input.feeds[k]) == 'bool') cfg.feeds[k] = input.feeds[k];
		}
		const next = saveThreatConfig(cfg);
		return { ok: true, config: next };
	});
}
function unban(ip) {
	return withThreatLock(() => {
		if (!match('' + ip, /^[0-9a-fA-F.:]+$/)) fail('IP 无效');
		const list = dynamicList();
		if (!list.items[ip]) fail('该 IP 不在动态黑名单中');
		delete list.items[ip];
		dynamicSave(list);
		return { ok: true };
	});
}
function manualBan(ip, hours) {
	return withThreatLock(() => {
		if (!match('' + ip, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/)) fail('仅支持 IPv4 地址');
		const cfg = threatConfig();
		// hours 为 0 = 长期拉黑（10 年，等效不过期）；null/未传 = 使用默认时长
		const h = hours == null ? null : +(hours);
		const permanent = h != null && h <= 0;
		const r = dynamicAdd(ip, permanent ? '手动拉黑（长期）' : '手动拉黑', permanent ? 87600 : clampInt(h == null ? cfg.banHours : h, 1, 720), clampInt(cfg.maxDynamic, 16, 2048));
		if (r.full) fail('动态黑名单已满');
		return { ok: true, added: r.added, permanent };
	});
}
function forceRefresh() { return updateThreatFeeds(); }
export { TROOT, TDATA, threatConfig, saveThreatConfig, overview, setAutoBlock, unban, manualBan, forceRefresh, updateThreatFeeds, behaviorScan, kernelEvents, parseKernelLog, collectEvents, storedEvents, dynamicList, dynamicActive, dynamicSave, dynamicAdd, dynamicPrune, compileThreatNft, installThreat, guardExistsThreat, applyDnsmasq, threatCounters, fetchFeed, parseFeedLines, FEEDS, DNS_SINK_URL, eventDir, isPrivateIP, persistThreatPackets, packetHistory };
