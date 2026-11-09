// SPDX-License-Identifier: Apache-2.0
// 在路由器上运行：ucode tests/console-vpn-status.uc
// 复用 /usr/share/ucode/console/vpn-status.uc 的纯解析函数，不依赖 rpcd 或 luci。
//
// 注意：status 文件里的时间戳是「本地时间（无时区）」。为了在任何 TZ 下都能跑，
// 下面的 fixture 全部用 localtime() 反向生成，而不是写死某个时区的字面量。
//
// 重要：本测试绝不修改 /var/run/console-vpn 下的任何文件。删掉正在被 OpenVPN
// 打开的 status 文件会让它继续写一个已删除的 inode（状态页数据永久冻结），
// 所以「文件缺失」路径一律用 /tmp 下不存在的目录来模拟。
import { open, stat, unlink, mkdir, rmdir } from 'fs';
import { parseStatus, readServerStatus, readServerPid, buildDetail, splitCsv, parseRealAddress, timestampToEpoch, elapsed, byteCount } from 'console.vpn-status';

let checks = 0;
function check(value, message) { checks++; if (!value) die(message + '\n'); }
function eq(actual, expected, message) {
	checks++;
	if (actual !== expected) die(sprintf('%s (got %J, want %J)\n', message, actual, expected));
}

// 固定 now：2026-10-31 14:00:00 UTC
const now = 1793455200;

// 把「now 往前 delta 秒」格式化成 status 文件里那种本地时间字面量。
function ts(delta) {
	const f = localtime(now - delta);
	return sprintf('%d-%02d-%02d %02d:%02d:%02d', f.year, f.mon, f.mday, f.hour, f.min, f.sec);
}
// 直接格式化任意 epoch（用于未来时间等异常值）。
function tsOf(epoch) {
	const f = localtime(epoch);
	return sprintf('%d-%02d-%02d %02d:%02d:%02d', f.year, f.mon, f.mday, f.hour, f.min, f.sec);
}

/* 1) 正常两客户端 ------------------------------------------------- */
const full = 'OpenVPN CLIENT LIST\n' +
	'Updated,' + ts(243) + '\n' +                                   // 4 分 3 秒前
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'testuser,tcp4-server:203.0.113.177:12014,197512,2749186,' + ts(380) + '\n' +
	'branch_b,udp4-server:203.0.113.9:51820,1024,2048,' + ts(7200) + '\n' +
	'ROUTING TABLE\n' +
	'Virtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.2,testuser,tcp4-server:203.0.113.177:12014,' + ts(251) + '\n' +
	'10.8.0.3,branch_b,udp4-server:203.0.113.9:51820,' + ts(30) + '\n' +
	'GLOBAL STATS\n' +
	'Max bcast/mcast queue length,0\n' +
	'END\n';

const r = parseStatus(full, now);
eq(length(r.clients), 2, 'two clients should be parsed');
eq(r.totals.online, 2, 'totals.online should be 2');
eq(r.totals.bytesReceived, 197512 + 1024, 'totals.bytesReceived mismatch');
eq(r.totals.bytesSent, 2749186 + 2048, 'totals.bytesSent mismatch');

const testuser = r.clients[0];
eq(testuser.username, 'testuser', 'first client username');
eq(testuser.virtualAddress, '10.8.0.2', 'virtualAddress join failed');
eq(testuser.realAddress, '203.0.113.177', 'realAddress split failed');
eq(testuser.realPort, '12014', 'realPort split failed');
eq(testuser.protocol, 'tcp4-server', 'protocol split failed');
eq(testuser.bytesReceived, 197512, 'bytesReceived mismatch');
eq(testuser.bytesSent, 2749186, 'bytesSent mismatch');
eq(testuser.connectedFor, 380, 'connectedFor mismatch');
eq(testuser.idleFor, 251, 'idleFor mismatch');
eq(testuser.connectedSince, now - 380, 'connectedSince epoch mismatch');
eq(testuser.lastRef, now - 251, 'lastRef epoch mismatch');
eq(r.clients[1].username, 'branch_b', 'second client username');
eq(r.clients[1].virtualAddress, '10.8.0.3', 'second virtualAddress join failed');
eq(r.clients[1].protocol, 'udp4-server', 'second protocol mismatch');
eq(r.clients[1].connectedFor, 7200, 'second connectedFor mismatch');
eq(r.updatedAt, now - 243, 'updatedAt mismatch');

/* 2) 无客户端 ------------------------------------------------------ */
const empty = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'GLOBAL STATS\nMax bcast/mcast queue length,0\nEND\n';
const re = parseStatus(empty, now);
eq(length(re.clients), 0, 'no clients expected');
eq(re.totals.online, 0, 'totals.online should be 0');
eq(re.totals.bytesReceived, 0, 'totals.bytesReceived should be 0');
eq(re.totals.bytesSent, 0, 'totals.bytesSent should be 0');
eq(re.updatedAt, now - 243, 'updatedAt should still parse without clients');

/* 3) 截断文件：没有 END、没有 ROUTING TABLE ------------------------ */
const truncated = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'testuser,tcp4-server:203.0.113.177:12014,197512,2749186,' + ts(380) + '\n';
const rt = parseStatus(truncated, now);
eq(length(rt.clients), 1, 'truncated file should still yield the client row');
eq(rt.clients[0].virtualAddress, null, 'virtualAddress must be null without ROUTING TABLE');
eq(rt.clients[0].lastRef, null, 'lastRef must be null without ROUTING TABLE');
eq(rt.clients[0].idleFor, null, 'idleFor must be null without ROUTING TABLE');
eq(rt.clients[0].connectedFor, 380, 'connectedFor should still work when truncated');

/* 4) 带逗号的引号字段 ---------------------------------------------- */
const quoted = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'"branch,weird",tcp4-server:198.51.100.7:443,10,20,' + ts(3600) + '\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.9,"branch,weird",tcp4-server:198.51.100.7:443,' + ts(60) + '\n' +
	'END\n';
const rq = parseStatus(quoted, now);
eq(length(rq.clients), 1, 'quoted row should parse');
eq(rq.clients[0].username, 'branch,weird', 'quoted username must keep the comma');
eq(rq.clients[0].virtualAddress, '10.8.0.9', 'quoted join must still work');
eq(rq.clients[0].bytesReceived, 10, 'quoted row bytesReceived');
eq(rq.clients[0].idleFor, 60, 'quoted row idleFor');
const csv = splitCsv('a,"b,c",d');
eq(length(csv), 3, 'CSV splitter field count');
eq(csv[1], 'b,c', 'CSV splitter quoted comma');
eq(splitCsv('a,"b""c",d')[1], 'b"c', 'CSV splitter escaped quote');

/* 5) IPv6 真实地址 ------------------------------------------------- */
const ipv6 = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'v6user,tcp6-server:[2001:db8::1]:1194,5,6,' + ts(3600) + '\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.4,v6user,tcp6-server:[2001:db8::1]:1194,' + ts(60) + '\n' +
	'END\n';
const r6 = parseStatus(ipv6, now);
eq(length(r6.clients), 1, 'IPv6 row should parse');
eq(r6.clients[0].protocol, 'tcp6-server', 'IPv6 protocol mismatch');
eq(r6.clients[0].realAddress, '[2001:db8::1]', 'IPv6 address must keep brackets');
eq(r6.clients[0].realPort, '1194', 'IPv6 port mismatch');
eq(r6.clients[0].virtualAddress, '10.8.0.4', 'IPv6 routing join failed');
eq(r6.clients[0].idleFor, 60, 'IPv6 idleFor mismatch');
const bare6 = parseRealAddress('tcp6-server:2001:db8::1');
eq(bare6.address, '2001:db8::1', 'bare IPv6 must not be split at a colon');
eq(bare6.port, '', 'bare IPv6 must not invent a port');
eq(parseRealAddress('60.1.2.3:1194').protocol, '', 'address without proto must parse');
eq(parseRealAddress('60.1.2.3:1194').address, '60.1.2.3', 'bare IPv4:port address');
eq(parseRealAddress('60.1.2.3:1194').port, '1194', 'bare IPv4:port port');

/* 6) statusAvailable = false（parseStatus('') 路径） ----------------- */
const rn = parseStatus('', now);
eq(length(rn.clients), 0, 'empty status must yield no clients');
eq(rn.updatedAt, null, 'empty status must yield null updatedAt');
eq(rn.totals.online, 0, 'empty status totals.online');
const rw = parseStatus(null, now);
eq(length(rw.clients), 0, 'null status must yield no clients');
// 注：readServerStatus 的「文件缺失」路径在第 10 节用不存在的目录覆盖，
// 那里是唯一一处碰文件系统的地方，且完全不涉及 /var/run。
// 存在但内容垃圾
const garbage = parseStatus('not a status file at all\n<<<>>>\n', now);
eq(length(garbage.clients), 0, 'garbage status must yield no clients');
eq(garbage.updatedAt, null, 'garbage status must yield null updatedAt');

/* 7) 荒谬时间戳钳制 ------------------------------------------------ */
// 未来时间：connectedSince 被钳到 now，时长 0 而不是负数
const futureText = tsOf(now + 2000000000);
const future = 'OpenVPN CLIENT LIST\nUpdated,' + futureText + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'future,tcp4-server:192.0.2.1:1194,1,2,' + futureText + '\n' +
	'END\n';
const rf = parseStatus(future, now);
eq(rf.clients[0].connectedFor, 0, 'future timestamp must clamp to 0 seconds');
eq(rf.clients[0].connectedSince, now, 'future connectedSince must clamp to now');
eq(rf.updatedAt, now, 'future updatedAt must clamp to now');

// 1970 年前 / 格式错 / 字段越界 -> null
eq(timestampToEpoch('1969-12-31 23:59:59', now), null, 'pre-epoch timestamp must be null');
eq(timestampToEpoch('garbage', now), null, 'garbage timestamp must be null');
eq(timestampToEpoch('2026-13-45 99:99:99', now), null, 'out-of-range fields must be null');
eq(timestampToEpoch(null, now), null, 'null timestamp must be null');
eq(timestampToEpoch('2026-10-31', now), null, 'date without time must be null');

// 极端旧（1971）时间不应产生天文数字或负数
const ancient = parseStatus('OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'ancient,tcp4-server:192.0.2.2:1194,0,0,1971-01-01 00:00:00\nEND\n', now);
check(ancient.clients[0].connectedFor != null && ancient.clients[0].connectedFor >= 0, 'ancient connectedFor must be a non-negative int');
check(ancient.clients[0].connectedFor <= 315360000, 'ancient connectedFor must be clamped');
eq(elapsed(now, now + 500), 0, 'elapsed must clamp negatives to 0');
eq(elapsed(now, null), null, 'elapsed must be null without a timestamp');

// 时区无关性：任意时刻的 localtime 字段格式化后再解析回来必须还原成同一 epoch。
// 这条在 GMT0 / GMT-8 / GMT-5:30 下都必须成立（RFC 里不带时区的本地时间语义）。
for (let probe in [1793455200, 1798761600, 1700000000, 2000000000]) {
	const text = tsOf(probe);
	eq(timestampToEpoch(text, probe), probe, 'localtime round-trip must be TZ-independent for ' + text);
}

// 坏字节数：负数/NaN/空 一律回退到 0
eq(byteCount('-5'), 0, 'negative byte count must clamp to 0');
eq(byteCount('abc'), 0, 'NaN byte count must fall back to 0');
eq(byteCount(null), 0, 'null byte count must be 0');
eq(byteCount('0'), 0, 'zero byte count');
eq(byteCount('12345'), 12345, 'valid byte count');
const badBytes = parseStatus('OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'bad,tcp4-server:192.0.2.3:1194,-9,notanumber,' + ts(3600) + '\nEND\n', now);
eq(badBytes.clients[0].bytesReceived, 0, 'negative bytes must be sanitised');
eq(badBytes.clients[0].bytesSent, 0, 'NaN bytes must be sanitised');
eq(badBytes.totals.bytesReceived, 0, 'totals must not leak negative bytes');
eq(badBytes.totals.bytesSent, 0, 'totals must not leak NaN bytes');

/* 8) 额外容错：CRLF、未知小节、同名多连接、半行 ------------------- */
const crlf = 'OpenVPN CLIENT LIST\r\nUpdated,' + ts(243) + '\r\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\r\n' +
	'testuser,tcp4-server:1.2.3.4:1194,10,20,' + ts(60) + '\r\n' +
	'ROUTING TABLE\r\nVirtual Address,Common Name,Real Address,Last Ref\r\n' +
	'10.8.0.2,testuser,tcp4-server:1.2.3.4:1194,' + ts(5) + '\r\nEND\r\n';
const rCrlf = parseStatus(crlf, now);
eq(length(rCrlf.clients), 1, 'CRLF status file must parse');
eq(rCrlf.clients[0].virtualAddress, '10.8.0.2', 'CRLF routing join');
eq(rCrlf.clients[0].realAddress, '1.2.3.4', 'CRLF realAddress');
eq(rCrlf.clients[0].idleFor, 5, 'CRLF idleFor');
eq(rCrlf.updatedAt, now - 243, 'CRLF updatedAt');

// 未知小节插入后仍然能解析后面的 ROUTING TABLE
const extraSection = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'a,tcp4-server:1.1.1.1:1,1,2,' + ts(60) + '\n' +
	'SOME OTHER TABLE\nfoo,bar,baz\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.5,a,tcp4-server:1.1.1.1:1,' + ts(5) + '\n' +
	'GLOBAL STATS\nMax bcast/mcast queue length,0\nEND\n';
const rExtra = parseStatus(extraSection, now);
eq(length(rExtra.clients), 1, 'unknown section must not break parsing');
eq(rExtra.clients[0].virtualAddress, '10.8.0.5', 'join must survive an unknown section');

// 同名账号两条连接：(Common Name + Real Address) 必须能分别对上各自的虚拟地址
const dupe = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'same,tcp4-server:1.1.1.1:1,1,2,' + ts(60) + '\n' +
	'same,tcp4-server:2.2.2.2:2,3,4,' + ts(30) + '\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.6,same,tcp4-server:1.1.1.1:1,' + ts(5) + '\n' +
	'10.8.0.7,same,tcp4-server:2.2.2.2:2,' + ts(6) + '\nEND\n';
const rDupe = parseStatus(dupe, now);
eq(length(rDupe.clients), 2, 'two connections for one account');
eq(rDupe.clients[0].virtualAddress, '10.8.0.6', 'duplicate-name join #1');
eq(rDupe.clients[1].virtualAddress, '10.8.0.7', 'duplicate-name join #2');
eq(rDupe.clients[0].idleFor, 5, 'duplicate-name idleFor #1');
eq(rDupe.clients[1].idleFor, 6, 'duplicate-name idleFor #2');

// 只有 ROUTING TABLE、没有 CLIENT LIST：不得凭空造出客户端
const ghost = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'ROUTING TABLE\nVirtual Address,Common Name,Real Address,Last Ref\n' +
	'10.8.0.8,ghost,tcp4-server:9.9.9.9:9,' + ts(5) + '\nEND\n';
eq(length(parseStatus(ghost, now).clients), 0, 'routing-only file must not fabricate clients');

// 半行（OpenVPN 原地重写文件时可能读到）：保留已知字段，未知字段 null
const halfLine = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'trunc,tcp4-server:1.1.1.1:1,10,20,';
const rHalf = parseStatus(halfLine, now);
eq(length(rHalf.clients), 1, 'half-written client row is kept');
eq(rHalf.clients[0].connectedSince, null, 'half-written row must not invent connectedSince');
eq(rHalf.clients[0].connectedFor, null, 'half-written row must not invent connectedFor');
eq(rHalf.clients[0].bytesReceived, 10, 'half-written row keeps known byte counts');

// 完全没有 Updated 行
const noUpdated = 'OpenVPN CLIENT LIST\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	'a,tcp4-server:1.1.1.1:1,1,2,' + ts(60) + '\nEND\n';
const rNoUpd = parseStatus(noUpdated, now);
eq(rNoUpd.updatedAt, null, 'missing Updated line must yield null updatedAt');
eq(length(rNoUpd.clients), 1, 'missing Updated line must still parse clients');

// 二进制垃圾输入
eq(length(parseStatus(chr(0) + chr(1) + chr(255) + 'x', now).clients), 0, 'binary junk must yield no clients');

// 空 Common Name 行跳过
const emptyCn = 'OpenVPN CLIENT LIST\nUpdated,' + ts(243) + '\n' +
	'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since\n' +
	',tcp4-server:1.1.1.1:1,1,2,' + ts(60) + '\nEND\n';
eq(length(parseStatus(emptyCn, now).clients), 0, 'row without Common Name must be skipped');

/* 9) buildDetail 契约字段 ----------------------------------------- */
const detail = buildDetail({
	settings: { enabled: true, endpoint: '203.0.113.139', port: 1194, protocol: 'tcp-server', allowWan: true },
	serverState: { configured: true, running: true, endpoint: '203.0.113.139', port: 1194, protocol: 'tcp-server', allowWan: true },
	accounts: [{ username: 'testuser', enabled: true, address: '', remoteSubnet: '', description: '测试' }],
	snapshot: { statusAvailable: true, updatedAt: r.updatedAt, clients: r.clients, totals: r.totals },
	runtime: { pid: 3909, uptime: 600 }
});
eq(detail.server.configured, true, 'detail.server.configured');
eq(detail.server.running, true, 'detail.server.running');
eq(detail.server.endpoint, '203.0.113.139', 'detail.server.endpoint');
eq(detail.server.port, 1194, 'detail.server.port');
eq(detail.server.protocol, 'tcp-server', 'detail.server.protocol');
eq(detail.server.allowWan, true, 'detail.server.allowWan');
eq(detail.server.pid, 3909, 'detail.server.pid');
eq(detail.server.uptime, 600, 'detail.server.uptime');
eq(detail.statusAvailable, true, 'detail.statusAvailable');
eq(detail.updatedAt, r.updatedAt, 'detail.updatedAt');
eq(length(detail.clients), 2, 'detail.clients length');
eq(detail.totals.online, 2, 'detail.totals.online');
eq(detail.totals.bytesReceived, r.totals.bytesReceived, 'detail.totals.bytesReceived');
eq(detail.totals.bytesSent, r.totals.bytesSent, 'detail.totals.bytesSent');
eq(length(detail.accounts), 1, 'detail.accounts length');
eq(detail.accounts[0].username, 'testuser', 'detail.accounts username');
eq(detail.accounts[0].enabled, true, 'detail.accounts enabled');
eq(detail.accounts[0].address, '', 'detail.accounts address');
eq(detail.accounts[0].remoteSubnet, '', 'detail.accounts remoteSubnet');
eq(detail.accounts[0].description, '测试', 'detail.accounts description');

// 服务未运行时不暴露 pid/uptime
const down = buildDetail({
	settings: { enabled: false, endpoint: '', port: 1194, protocol: 'udp', allowWan: false },
	serverState: { configured: false, running: false },
	accounts: [],
	snapshot: { statusAvailable: false, updatedAt: null, clients: [], totals: { online: 0, bytesReceived: 0, bytesSent: 0 } },
	runtime: { pid: null, uptime: null }
});
eq(down.server.running, false, 'down.server.running');
eq(down.server.pid, null, 'down.server.pid must be null');
eq(down.server.uptime, null, 'down.server.uptime must be null');
eq(down.statusAvailable, false, 'down.statusAvailable must be false');
eq(down.updatedAt, null, 'down.updatedAt must be null');
eq(length(down.clients), 0, 'down.clients must be empty');
eq(down.server.port, 1194, 'down.server.port must come from settings');

// 完全空输入也不能抛异常
const blank = buildDetail(null);
eq(blank.server.running, false, 'blank.server.running');
eq(blank.server.endpoint, '', 'blank.server.endpoint');
eq(blank.server.pid, null, 'blank.server.pid');
eq(blank.statusAvailable, false, 'blank.statusAvailable');
eq(length(blank.clients), 0, 'blank.clients');
eq(length(blank.accounts), 0, 'blank.accounts');

/* 10) 运行时读取：全部指向不存在的目录，绝不触碰 /var/run ========
 * 这条测试必须保持「只读且不依赖路由器真实状态」：
 *   - 绝不创建/删除/改写 /var/run/console-vpn 下的任何文件
 *     （删掉正在被 OpenVPN 打开的 status 文件会让它继续写一个已删除的
 *      inode，导致状态页数据永久冻结——曾经踩过这个坑）；
 *   - readServerStatus/readServerPid 的「文件缺失」路径用不存在的
 *     目录来覆盖即可，检查数量因此是确定的。
 */
const missingDir = '/tmp/console-vpn-status-test-missing-dir';
check(stat(missingDir) == null, 'the fake runtime dir must NOT exist');
const missing = readServerStatus(missingDir, now);
eq(missing.statusAvailable, false, 'missing status file must set statusAvailable=false');
eq(missing.updatedAt, null, 'missing status file must yield null updatedAt');
eq(length(missing.clients), 0, 'missing status file must yield no clients');
eq(missing.totals.online, 0, 'missing status file must yield zero online');
eq(missing.totals.bytesReceived, 0, 'missing status file must yield zero bytesReceived');
eq(missing.totals.bytesSent, 0, 'missing status file must yield zero bytesSent');

const runtimePid = readServerPid(missingDir, now);
eq(runtimePid.pid, null, 'missing pid file must yield null pid');
eq(runtimePid.uptime, null, 'missing pid file must yield null uptime');

// 临时目录里放一个真实文件，验证「读得到」这一侧（只在 /tmp 下建，不碰 /var/run）
const scratchDir = '/tmp/console-vpn-status-test-scratch';
mkdir(scratchDir, 0700);
const scratchFile = scratchDir + '/server.status';
const fd = open(scratchFile, 'w');
check(fd != null, 'must be able to create a scratch status file');
fd.write(full);
fd.close();
const scratch = readServerStatus(scratchDir, now);
eq(scratch.statusAvailable, true, 'readable status file must set statusAvailable=true');
eq(length(scratch.clients), 2, 'readable status file must expose its clients');
eq(scratch.totals.online, 2, 'readable status file totals.online');
eq(scratch.updatedAt, now - 243, 'readable status file updatedAt');
eq(scratch.clients[0].virtualAddress, '10.8.0.2', 'readable status file virtualAddress');
unlink(scratchFile);
rmdir(scratchDir);
check(stat(scratchDir) == null, 'scratch dir must be cleaned up');

print(sprintf('PASS: OpenVPN status parsing — %d checks OK (2-client join, quoted CSV, IPv6, truncated file, no clients, empty/garbage status, future/ancient timestamps, TZ round-trip, byte clamping, missing/readable runtime paths, buildDetail contract).\n', checks));
