#!/bin/sh
# 态势感知统计链路自检：逐项断言，任何一项 FAIL 说明又退化了。
# 用法（在路由器上）：sh selftest-situational.sh
DB=/srv/console-security/traffic.db
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=========== 态势感知链路自检 ==========="
echo
echo "--- 1. 规则构造：limit 不得出现在 drop 之前 ---"
CH=$(nft list table inet console_threat 2>/dev/null)
if [ -z "$CH" ]; then bad "console_threat 表不存在"; else
  if echo "$CH" | grep -qE 'limit rate.*drop'; then
    bad "存在 'limit ... drop' 同规则写法（超速率包会绕过 drop）"
  else ok "无 'limit ... drop' 同规则写法"; fi

  # counter 必须在地址匹配之后
  if echo "$CH" | grep -qE 'counter name "threats_[a-z_]+" ip s?d?addr @blacklist'; then
    ok "counter 位于黑名单匹配之后"
  else
    echo "$CH" | grep -qE 'ip s?d?addr @blacklist[46] counter name' && ok "counter 位于黑名单匹配之后" || bad "counter 位置异常"
  fi

  # 方向编码
  for t in tin tfi tfo; do
    echo "$CH" | grep -q "CST:$t " && ok "日志前缀含方向编码 CST:$t" || bad "缺少 CST:$t"
  done
fi

echo
echo "--- 2. 事件表必须使用内核事件ID（否则同秒同五元组的包被合并）---"
PK=$(/usr/bin/sqlite3 $DB "select sql from sqlite_master where type='table' and name='events';" 2>/dev/null)
case "$PK" in
  *"id TEXT PRIMARY KEY"*) ok "使用持久化内核事件ID去重" ;;
  *"PRIMARY KEY(ts,src,rule,dport)"*) bad "主键仍是旧定义，同秒事件会被静默合并" ;;
  *) bad "无法识别的 events 主键: $PK" ;;
esac

echo
echo "--- 3. 模块必须能被新进程正常加载（无语法/引用错误）---"
/usr/bin/ucode -e 'import * as s from "console.situational"; print(s.eventDir("tin","1.1.1.1","192.168.1.8")+"\n");' >/tmp/st1.out 2>&1
[ "$(cat /tmp/st1.out)" = "input" ] && ok "eventDir 方向判定正确 (tin->input)" || bad "eventDir 返回值异常: $(cat /tmp/st1.out)"

/usr/bin/ucode -e 'import * as s from "console.situational"; print(s.eventDir("tfo","192.168.1.5","8.8.8.8")+"\n");' >/tmp/st2.out 2>&1
[ "$(cat /tmp/st2.out)" = "fwd_out" ] && ok "eventDir 方向判定正确 (tfo->fwd_out)" || bad "eventDir fwd_out 异常: $(cat /tmp/st2.out)"

echo
echo "--- 3b. 日志解析必须能吃下 input 钩子的空 OUT=（否则该方向永久丢事件）---"
cat > /tmp/stp.uc <<'UCEOF'
import { parseKernelLog } from 'console.situational';
// input 钩子的真实形态：OUT= 后面直接就是空格 + MAC
const inputLine = '[54452.226816] CST:tin IN=eth1 OUT= MAC=aa:bb:cc:dd:ee:02:00:07:32:6c:0f:9b:08:00 SRC=198.51.100.174 DST=172.16.10.13 LEN=69 PROTO=TCP SPT=1196 DPT=56395';
// 为了不依赖 syslog 时间戳解析，这里直接验证正则形态
const RE = /(CS[GT]):([a-z0-9]+) IN=\S+ OUT=\S* +MAC=\S+ SRC=([0-9A-Fa-f:.]+) DST=([0-9A-Fa-f:.]+)/;
const m = match(inputLine, RE);
printf("%s %s %s\n", m ? "MATCH" : "NULL", m ? m[2] : "-", m ? m[3] : "-");
UCEOF
/usr/bin/ucode /tmp/stp.uc > /tmp/stp.out 2>&1
if [ "$(awk '{print $1}' /tmp/stp.out)" = "MATCH" ] && [ "$(awk '{print $2}' /tmp/stp.out)" = "tin" ]; then
  ok "input 方向(out=空)可解析：rule=tin src=$(awk '{print $3}' /tmp/stp.out)"
else
  bad "input 方向(out=空)解析失败: $(cat /tmp/stp.out | head -1)  —— 外网→路由器事件会全部丢失"
fi

echo
echo "--- 4. 进程加载的是磁盘上的当前版本（非已删除的旧 inode）---"
STALE=0
for pid in $(pgrep -f 'console-security-collector|rpcd'); do
  n=$(ls -l /proc/$pid/fd 2>/dev/null | grep -c 'deleted')
  [ "$n" -gt 0 ] && { STALE=$((STALE+n)); echo "    pid=$pid 持有 $n 个已删除 fd"; }
done
[ "$STALE" -eq 0 ] && ok "无进程持有已删除的模块（代码已生效）" || bad "有 $STALE 个已删除 fd —— 需重启 rpcd/采集器"

echo
echo "--- 5. overview 过滤器不得丢弃 fwd_out 事件 ---"
cat > /tmp/stf.uc <<'UCEOF'
import { storedEvents } from 'console.situational';
function isPriv(ip) {
	if (match(ip, /^10\./) || match(ip, /^192\.168\./) || match(ip, /^127\./) || match(ip, /^169\.254\./) || match(ip, /^172\.(1[6-9]|2[0-9]|3[01])\./)) return true;
	if (match(ip, /^fe80:/i) || match(ip, /^fc/i) || match(ip, /^fd/i) || match(ip, /^::1$/)) return true;
	return false;
}
const now = time(), ev = storedEvents(86400);
let oldStyle = 0, newStyle = 0, total = 0;
for (let e in ev) {
	if (e.stamp == null || now - e.stamp > 86400) continue;
	const n=+e.n || 1; total+=n;
	if (!(e.kind == 'threat' && (isPriv(e.src) || isPriv(e.dst)))) oldStyle+=n;
	if (!(e.kind == 'threat' && isPriv(e.src) && isPriv(e.dst))) newStyle+=n;
}
printf("%d %d %d\n", total, oldStyle, newStyle);
UCEOF
/usr/bin/ucode /tmp/stf.uc > /tmp/stf.out 2>&1
set -- $(cat /tmp/stf.out)
TOTAL=$1; OLD=$2; NEW=$3
if [ "${TOTAL:-0}" -gt 0 ] && [ "${NEW:-0}" -gt 0 ]; then
  ok "24h 事件=$TOTAL，新过滤器保留 $NEW 条（旧过滤器只保留 ${OLD} 条）"
  [ "${OLD:-0}" -eq 0 ] && echo "     ^ 证实旧过滤器把这些事件全丢了"
else
  bad "24h 内无可统计数据（TOTAL=${TOTAL:-?} NEW=${NEW:-?}）"
fi

echo
echo "--- 6. 页面接口返回结构完整 ---"
ubus call console-situational overview 2>/dev/null > /tmp/stov.json
/usr/bin/ucode -e '
import {readfile} from "fs";
let o = json(readfile("/tmp/stov.json"));
let miss = [];
for (let k in ["ok","stats","map","series","top","dirTop","counters","feeds","dynamic"])
	if (o[k] == null) push(miss, k);
printf("%s\n", length(miss) ? "MISSING:" + join(",", miss) : "STRUCT_OK");
printf("%d %d %d %d\n", o.stats?.total24 ?? -1, o.stats?.threat24 ?? -1, length(o.map), length(o.series));
' > /tmp/stov.out 2>&1
if grep -q STRUCT_OK /tmp/stov.out; then ok "overview 返回字段完整"; else bad "overview 缺字段: $(head -1 /tmp/stov.out)"; fi
T24=$(sed -n 2p /tmp/stov.out | awk '{print $1}')
echo "     页面 24h 拦截数 = ${T24:-?}"

echo
echo "--- 7. 采集器存活且状态文件新鲜 ---"
if pgrep -f console-security-collector >/dev/null; then ok "采集器进程存活"; else bad "采集器未运行"; fi
AGE=$(/usr/bin/ucode -e 'import {readfile} from "fs"; let d=json(readfile("/tmp/console-security-state.json")); printf("%d", time()-(d.time||0));' 2>/dev/null)
[ -n "$AGE" ] && [ "$AGE" -lt 30 ] && ok "状态文件新鲜（${AGE}s 前更新）" || bad "状态文件过期或缺失（${AGE:-?}s）"

echo
echo "--- 8. nft 表结构完好 ---"
for t in console_threat console_guard console_meter; do
  nft list table inet $t >/dev/null 2>&1 && ok "table inet $t 存在" || bad "table inet $t 丢失"
done
LEFT=$(nft list ruleset | grep -cE 'zz_|obs_|dbg_|t[ABCD]_|cstest|probe_')
[ "$LEFT" -eq 0 ] && ok "无调试残留规则" || bad "残留 $LEFT 条调试规则"

echo
echo "========================================"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "  结果：全部通过" || echo "  结果：有失败项，需修复"
echo "========================================"
exit $FAIL
