// SPDX-License-Identifier: Apache-2.0
// 流控分流（console-flow）公共基础设施：路径常量、原子写入、写锁、回滚记录、
// nft/ip 命令封装与 IPv4 小工具。
// 手法与 console-portmap / console-security 保持一致：临时文件 + rename 原子替换；
// mkdir 写锁并记录 owner(pid/start)，避免 ucode 异常退出后残留死锁；
// nft 一律先写 /tmp 文本、`nft -c` 预检通过后才真正加载。
import { open, readfile, rename, unlink, mkdir, rmdir, stat, chmod, popen } from 'fs';

const DIR = '/etc/console-flow';
const CONFIG = DIR + '/config.json';
const DOMAINS = DIR + '/domains.json';
const APPLIED = DIR + '/applied.json';
const NFT = DIR + '/flow.nft';
const PENDING = DIR + '/pending.json';
const CHECK = '/tmp/console-flow-check.nft';
const CHECK_LOG = '/tmp/console-flow-check.log';
const LOAD_LOG = '/tmp/console-flow-load.log';
const LOCK = '/tmp/console-flow-write.lock';
const CONTROL_FILE = '/usr/sbin/console-flow-control.uc';
const BACKUP = '/etc/console-backup';
const NFT_TABLE = 'console_flow';
// 线路标签基址与掩码：与 mihomo 的 fwmark 0x434d / table 201 / prio 10390 完全错开，
// 掩码 0xffff00ff 只认高 24 位 + 低 8 位，中 8 位留给其他用途。
const MARK_BASE = 0x46460000;
const MARK_MASK_TEXT = '0xffff00ff';
const TABLE_BASE = 300;
const PRIO_BASE = 10400;
const TABLE_SPAN = 20;
const PRIO_SPAN = 100;
const MAX_LINES = 8;
const MAX_RULES = 512;
const MAX_LIMITS = 256;
const ROLLBACK_SECONDS = 120;
const BOOT = trim(readfile('/proc/sys/kernel/random/boot_id') || '');

function fail(message) { die(message + '\n'); }
function uptime() { return +split(readfile('/proc/uptime') || '0', ' ')[0]; }
function sh(value) { return "'" + replace('' + value, /'/g, "'\\''") + "'"; }
function sq(value) { return "'" + replace('' + value, /'/g, "''") + "'"; }
function command(args) { return join(' ', map(args, sh)); }
function output(args) { const p = popen(command(args)); if (!p) return ''; const text = p.read('all') || ''; p.close(); return text; }
function runSh(script) { return system(['/bin/sh', '-c', script]); }
function readJson(path, fallback) { try { return json(readfile(path) || ''); } catch (e) { return fallback; } }
function writeText(path, text) {
	const temp = path + '.new';
	const handle = open(temp, 'w');
	if (!handle) fail('无法写入 ' + path);
	handle.write(text == null ? '' : text);
	handle.close();
	chmod(temp, 0600);
	if (!rename(temp, path)) fail('无法保存 ' + path);
}
function writeJson(path, data) { writeText(path, sprintf('%J', data)); }
function ensureDir(path) { if (!stat(path)) { mkdir(path); chmod(path, 0700); } }
function ensure() { ensureDir(DIR); }
function ensureBackup() { ensureDir(BACKUP); }

function nftPath() { return stat('/usr/sbin/nft') ? '/usr/sbin/nft' : '/usr/bin/nft'; }
function ipPath() {
	for (let candidate in ['/sbin/ip', '/usr/sbin/ip', '/bin/ip', '/usr/bin/ip'])
		if (stat(candidate)) return candidate;
	return '/sbin/ip';
}
// 返回 null 表示校验通过，否则返回 nft 的中文可读错误（截断）。
function nftCheck(text) {
	writeText(CHECK, text);
	if (runSh(command([nftPath(), '-c', '-f', CHECK]) + ' >' + sh(CHECK_LOG) + ' 2>&1') == 0) return null;
	const message = trim(readfile(CHECK_LOG) || '');
	return length(message) ? message : 'nftables 语法校验失败';
}
// 把 text 写成临时文件后加载。永远自己写文件：早先的 `fromText=false` 复用
// /tmp 里的旧 check 文件，导致“规则集已更新但内核还是上一次”的隐蔽 bug。
function nftLoad(text) {
	writeText(CHECK, text);
	if (runSh(command([nftPath(), '-f', CHECK]) + ' >' + sh(LOAD_LOG) + ' 2>&1') != 0) {
		const message = trim(readfile(LOAD_LOG) || '');
		fail('加载流控规则失败：' + (length(message) ? substr(message, 0, 600) : '未知错误'));
	}
}
// 从已有文件加载（回滚 / 开机恢复时用，文件内容已备份好）。
function nftLoadFile(path) {
	if (runSh(command([nftPath(), '-f', path]) + ' >' + sh(LOAD_LOG) + ' 2>&1') != 0) {
		const message = trim(readfile(LOAD_LOG) || '');
		fail('恢复流控规则失败：' + (length(message) ? substr(message, 0, 600) : '未知错误'));
	}
}
// ucode 没有 RegExp 构造器，表名固定，直接用字面量正则。
function tableExists() {
	return match(output([nftPath(), 'list', 'tables']), /table inet console_flow(\n|$)/) != null;
}
// 表不存在时 `nft -j list table` 会往 stderr 报错，这里先判存在再读，
// 并把 stderr 一并吞掉，避免 rpcd 日志被刷屏。
function tableJson() {
	if (!tableExists()) return [];
	const p = popen(command([nftPath(), '-j', 'list', 'table', 'inet', NFT_TABLE]) + ' 2>/dev/null');
	if (!p) return [];
	const raw = p.read('all') || '';
	p.close();
	if (!length(trim(raw))) return [];
	try { return json(raw).nftables || []; } catch (e) { return []; }
}
function deleteTable() {
	runSh(command([nftPath(), 'delete', 'table', 'inet', NFT_TABLE]) + ' >/dev/null 2>&1');
}

// ip 命令只做一件事：失败返回退出码，由调用方决定是否致命。
function ipRun(args) { return runSh(command([ipPath(), ...args]) + ' >/dev/null 2>&1'); }
function ipText(args) { return output([ipPath(), ...args]); }
function ipAddRule(mark, table, prio) {
	const selector = 'fwmark ' + sprintf('0x%08x', mark) + '/' + MARK_MASK_TEXT;
	return ipRun(['rule', 'add', ...split(selector, ' '), 'table', '' + table, 'prio', '' + prio]);
}
function ipDeleteRule(mark, table, prio) {
	const selector = 'fwmark ' + sprintf('0x%08x', mark) + '/' + MARK_MASK_TEXT;
	return ipRun(['rule', 'del', ...split(selector, ' '), 'table', '' + table, 'prio', '' + prio]);
}
function ipAddRoute(table, gateway, device) {
	return ipRun(['route', 'replace', 'table', '' + table, 'default', 'via', gateway, 'dev', device]);
}
function ipFlushTable(table) { return ipRun(['route', 'flush', 'table', '' + table]); }
function ipRules() {
	const rules = [];
	for (let line in split(ipText(['-4', 'rule', 'show']), '\n')) {
		const parsed = match(trim(line), /^(\d+):\s+from all fwmark (0x[0-9a-f]+)\/(0x[0-9a-f]+) lookup (\d+)$/);
		if (parsed) push(rules, { prio: +parsed[1], mark: parsed[2], mask: parsed[3], table: +parsed[4] });
	}
	return rules;
}
function ipRouteTable(table) {
	const route = match(ipText(['route', 'show', 'table', '' + table]), /default via (\d+\.\d+\.\d+\.\d+) dev ([A-Za-z0-9_.:@-]+)/);
	return route ? { gateway: route[1], device: route[2] } : null;
}

// 精确清理：只动自己的 prio 区间与路由表区间，绝不宽泛 flush。
function cleanupIp() {
	for (let prio in ipRules()) if (prio.prio >= PRIO_BASE && prio.prio < PRIO_BASE + PRIO_SPAN) ipRun(['rule', 'del', 'prio', '' + prio.prio]);
	for (let index = 0; index < TABLE_SPAN; index++) ipFlushTable(TABLE_BASE + index);
}

function lock() {
	if (!mkdir(LOCK)) {
		const owner = readJson(LOCK + '/owner.json', null);
		const live = owner ? split(readfile('/proc/' + owner.pid + '/stat') || '', ' ') : [];
		const stale = owner && (!length(live) || live[21] != owner.start);
		if (stale || (!owner && time() - (stat(LOCK)?.mtime || time()) > 10)) {
			unlink(LOCK + '/owner.json');
			unlink(LOCK + '/owner.json.new');
			rmdir(LOCK);
			if (!mkdir(LOCK)) fail('另一个流控配置任务正在执行，请稍后重试');
		} else fail('另一个流控配置任务正在执行，请稍后重试');
	}
	const me = split(readfile('/proc/self/stat') || '', ' ');
	writeJson(LOCK + '/owner.json', { pid: +me[0], start: me[21] });
}
function unlock() { unlink(LOCK + '/owner.json'); unlink(LOCK + '/owner.json.new'); rmdir(LOCK); }
function withLock(callback) {
	lock();
	try { const result = callback(); unlock(); return result; }
	catch (e) { unlock(); die(e.message || '流控配置任务失败'); }
}
function tryLock(callback) {
	if (stat(LOCK)) return null;
	lock();
	try { const result = callback(); unlock(); return result; }
	catch (e) { unlock(); warn('流控后台任务失败：' + (e.message || '未知错误') + '\n'); return null; }
}

// pending 记录：boot_id + 单调 uptime 截止时间，避免校时导致回滚窗口错乱。
function pendingRecord() { return readJson(PENDING, null); }
function pendingState() {
	const record = pendingRecord();
	if (!record) return null;
	const remaining = record.boot == BOOT && record.uptimeDeadline ? record.uptimeDeadline - uptime() : record.deadline - time();
	return { deadline: record.deadline, secondsLeft: int(max(0, remaining) + 0.999) };
}
function writePending(payload) {
	writeJson(PENDING, { deadline: time() + ROLLBACK_SECONDS, boot: BOOT, uptimeDeadline: uptime() + ROLLBACK_SECONDS, ...payload });
}
function clearPending() { unlink(PENDING); }
// 120 秒确认窗口的后台计时器：与 console-security 相同的做法 —— 独立进程 sleep
// 后自己读 pending.json 判断是否真的过期，再决定回滚。
// 走 console-flow-control.uc 入口而不是内联 import，保证与手动/开机路径共用同一份
// 回滚逻辑。注意 sh() 只给「一个」参数加引号，脚本路径与 `expire` 子命令必须分开拼，
// 否则 ucode 会把整串当成文件名（实测报 Failed to open ".../console-flow-control.uc expire"）。
function spawnRollback() {
	runSh('(sleep ' + (ROLLBACK_SECONDS + 1) + '; /usr/bin/ucode ' + sh(CONTROL_FILE) + ' expire) >/tmp/console-flow-rollback.log 2>&1 &');
}

function ip4(value) {
	if (type(value) != 'string') return null;
	const parts = split(trim(value), '.');
	if (length(parts) != 4) return null;
	let number = 0;
	for (let part in parts) {
		if (!match(part, /^(0|[1-9][0-9]{0,2})$/)) return null;
		const piece = +part;
		if (piece > 255) return null;
		number = number * 256 + piece;
	}
	return number;
}
function ip4Text(number) { return join('.', map([16777216, 65536, 256, 1], step => '' + (int(number / step) % 256))); }
function cidr4(value) {
	if (type(value) != 'string') return null;
	const parts = split(trim(value), '/');
	if (length(parts) > 2) return null;
	const key = ip4(parts[0]);
	if (key == null) return null;
	let bits = 32;
	if (length(parts) > 1) {
		if (!match(parts[1], /^(0|[1-9][0-9]?)$/) || +parts[1] > 32) return null;
		bits = +parts[1];
	}
	let size = 1;
	for (let index = bits; index < 32; index++) size *= 2;
	const base = int(key / size) * size;
	return { key, base, bits, size, value: ip4Text(base) + '/' + bits };
}
function inCidr4(value, range) {
	const key = ip4(value);
	const parsed = cidr4(range);
	if (key == null || !parsed) return false;
	return key >= parsed.base && key < parsed.base + parsed.size;
}

export {
	DIR, CONFIG, DOMAINS, APPLIED, NFT, PENDING, CHECK, CHECK_LOG, LOAD_LOG, LOCK, BACKUP, CONTROL_FILE,
	NFT_TABLE, MARK_BASE, MARK_MASK_TEXT, TABLE_BASE, PRIO_BASE, TABLE_SPAN, PRIO_SPAN,
	MAX_LINES, MAX_RULES, MAX_LIMITS, ROLLBACK_SECONDS, BOOT,
	fail, uptime, sh, sq, command, output, runSh, readJson, writeText, writeJson,
	ensure, ensureDir, ensureBackup,
	nftPath, ipPath, nftCheck, nftLoad, nftLoadFile, tableExists, tableJson, deleteTable,
	ipRun, ipText, ipAddRule, ipDeleteRule, ipAddRoute, ipFlushTable, ipRules, ipRouteTable, cleanupIp,
	lock, unlock, withLock, tryLock,
	pendingRecord, pendingState, writePending, clearPending, spawnRollback,
	ip4, ip4Text, cidr4, inCidr4
};
