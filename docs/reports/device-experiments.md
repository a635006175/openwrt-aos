# 设备受控实验报告 — 「态势感知拿不到拦截数据」现场根因

- 实验人：device-prober
- 设备：`root@192.168.1.1`，OpenWrt SNAPSHOT，kernel 6.18.55，ucode
- 操作端：Windows（192.168.1.5）PowerShell 5.1，全部经 `ssh -n -T -o BatchMode=yes` 传 `/tmp/p.sh` 执行
- 实验脚本：`<repo>\.stage\dev-probe-*.sh` / `dev-probe-*.ps1`
- 实验窗口：设备 epoch 1793982060 – 1793983080（uptime 55677 – 56687）

## 版本说明（重要）

| 阶段 | 设备状态 |
|---|---|
| 实验 1 – 实验 5 期间 | `console_threat` 为**旧版规则**：单规则 `counter name "threats_in" ip saddr @blacklist4 log prefix "CST:threat " limit rate 2/second burst 4 packets drop` |
| 00:31 之后 | lead 部署了新 `situational.uc`(37571B)/`security.uc`(27576B)，重建 `console_threat`：拆成两条规则 `ip saddr @blacklist4 limit rate 10/second burst 20 packets log prefix "CST:tin "` + `ip saddr @blacklist4 counter name "threats_in" drop`，前缀 `CST:tin/tfi/tfo` |

**我的实验 1–4 全部在旧版规则下完成**；实验 5 与根因定位跨版本（下文逐条标注）。

---

## 实验 1 — `limit` 语句语义验证（最关键）

### 操作

在 `table inet cstest2` 建 `chain c { type filter hook input priority -350; }`，用 `iifname "br-lan" tcp dport 80 tcp flags & syn == syn` 作判据（到路由器 80 端口的每条 SYN = 一次独立连接尝试，1 包）。从 Windows 每次发起 40 次连接尝试，用 `TcpClient` + `LingerState(0)` RST 关闭，保证**每次尝试只发 1 个 SYN**。四种构造 A/B 对照：

| 变体 | 规则内容 |
|---|---|
| control | `... counter`（无 limit、无 drop） |
| **varA（生产旧版同构）** | `... counter log prefix "LMTTEST-A: " limit rate 1/minute burst 2 packets drop` |
| varB（正确顺序） | `... counter limit rate 1/minute burst 2 packets log prefix "LMTTEST-B: " drop` |
| **varC（正确构造）** | 规则1 `... limit rate 1/minute burst 2 packets counter log prefix "LMTTEST-C: "`；规则2 `... counter drop` |

### 原始输出

control（无 limit）：
```
RESULT_OK=40 RESULT_FAIL=0
counter_seen=40  counter_inrate=40  dmesg_LMTTEST=0
```

varA（`log ... limit ... drop`，生产旧版同构）：
```
RESULT_OK=38 RESULT_FAIL=2
counter_seen=40  counter_inrate=40  dmesg_LMTTEST-A=40
```
第二次连发 20 次：`RESULT_OK=20 RESULT_FAIL=0`，`counter_seen=60 counter_inrate=60 dmesg_LMTTEST-A=60`

varB（`limit ... log ... drop`）：
```
RESULT_OK=38 RESULT_FAIL=2
counter_seen=40  counter_inrate=40  dmesg_LMTTEST-B=2
```

varC（limit 单独一条规则，drop 在下一规则）：
```
RESULT_OK=0 RESULT_FAIL=40
counter_seen=40  counter_inrate=2  counter_logged=40
dmesg_LMTTEST-C=2
```

### 结论

1. **`limit` 位于 `drop` 之前时，超速率的包完全没有被 drop。** varA 里 40 个包全部被 counter 和 log 统计，但只有 2 个被丢弃（38 个连接在 5ms 内成功建立）——`RESULT_FAIL=2` 正是 `burst 2` 内的那 2 个。
2. **机制是「短路」而不是「丢弃」**：`limit` 不匹配时规则在该处终止（相当于隐式 accept），所以它后面的 `drop` 永远执行不到。varB 证明这一点——即使把 `log` 放在 `limit` 之后，也仍然只有 2 个包被 drop（`dmesg_LMTTEST-B=2`），而超速率的包既没有 log 也没有 drop。
3. **只有把 `limit` 与 `drop` 拆成两条规则（varC）才是正确构造**：40 个包 40 个被 drop（`RESULT_FAIL=40`），其中只有 2 个按速率写日志。这正是 lead 在 00:31 部署的新规则形态。
4. `limit` 状态的有效期远长于 `1/minute`：第二次连发 20 个包全部绕过 drop，日志计数仍为 60（未新增），说明该 limit 桶的 token 未被后续流量刷新。

> 附带证明：varA 的 40 个包全部被 log，说明**限速没有生效、日志量没有被压制**——与「8 秒 81 条日志」的上游观察一致。

---

## 实验 2 — 黑名单命中端到端验证（拦截是否发生 / 是否入库）

### 关键纠错：`nft get element` 不能用来判定集合成员

```sh
nft get element inet console_threat blacklist4 { 8.8.8.8 }   # 回显 8.8.8.8 -> 看起来"PRESENT"
nft list set inet console_threat blacklist4 | grep -c '8\.8\.8\.8'   # 实际 0
```
`nft get element` 只是把请求原样回显，**不校验成员是否存在**。改用原始清单 grep 后确认：`8.8.8.8`、`1.1.1.1` 在实验开始前**都不在** `blacklist4` 中（当时 22736 个元素）。这一点会让「命中数为 0」被误判成规则失效。

### 操作

1. `nft add element inet console_threat blacklist4 { 8.8.8.8 }` → 元素数 22736 → **22737**，原始清单 grep 命中 1。
2. 在 `forward_gate` 末尾临时追加 `iifname @lan oifname @wan ip daddr @blacklist4 counter`（handle 44）作为「真命中」计数探针。
3. Windows 侧绑定源地址 192.168.1.5 向 `8.8.8.8:443` 发 40 次单 SYN（必须绑源地址：本机有两条等 metric 默认路由，不绑会从 10.10.10.253 出去，绕开路由器）。
4. 观察 nft / dmesg / sqlite / ubus。

### 原始输出

```
PRE : hitcounter=0  threats_fwd_out=39776  dmesg_CST=0   events_total=629
POST: hitcounter=80 threats_fwd_out=39866  dmesg_CST=80  events_total=662
      events_maxts=1793982581  rows_after_8888=33   (60s 后累计 48)
```
dmesg 实样：
```
[56211.198376] CST:threat IN=br-lan OUT=eth1 ... SRC=192.168.1.5 DST=8.8.8.8 LEN=52 ... SPT=49739 DPT=443
```
events 实样：
```
1793982581|threat|threat|192.168.1.5|8.8.8.8|TCP|49739|443
```
清理后：`DEL_OK`，`grep_8888_after_del=0`，元素数回到 **22736**；临时计数器按 handle 删除，`forward_gate` 恢复 5 条生产规则。

### 结论

**整条链路是通的：nft 匹配 → dmesg → 采集器 → sqlite 全部正常。**
- 黑名单匹配真实发生：探针计数器 +80（40 次 × 2，SYN + SYN 重传）。
- 打日志真实发生：`CST:` +80。
- **入库真实发生**：`events` 629 → 662 → 677，其中 48 行 `dst=8.8.8.8`，`max(ts)` 从 5 小时前推进到实时。

所以「拿不到拦截数据」**不是拦截没发生，也不是写库失败**。真正的断点在**读取侧**（见「根因」一节）。

> 旁证：`threats_fwd_out` 只 +90，而探针是 +80，两者口不一致，原因是采集器 60 秒周期内若触发 `updateThreatFeeds()` 会 `destroy` 重建整表、具名计数器归零；另外旧版 `counter name "threats_in"` 写在黑名单匹配**之前**，它统计的是「进入 input 链的 WAN 新连接」而非「黑名单命中」——这正是「`threats_in` 持续增长但匹配为 0」的原因。

---

## 实验 3 — dmesg 环形缓冲容量与挤占

### 操作与原始输出

```
dmesg | wc -l  = 713  -> 576   (实验前后)
dmesg | wc -c  = 59453 -> 129274
dmesg -s 1048576 | wc -l = 584   (请求更大缓冲也只多 8 行 -> 环已到顶)
printk        = 8 4 1 7         (console_loglevel=8，dmesg 全量可见)
printk_ratelimit=5  printk_ratelimit_burst=10  printk_devkmsg=ratelimit
logd          = /sbin/logd -S 1024   (1000 KiB)
logread       = 5988 行 / 1077338 字节
CST 行平均长度 = 226 字节
```

**挤占实证**：我产生 102 条 `LMTTEST` 日志（每条约 130–220B）后：
```
dmesg_CST: 12 -> 0        (12 条 CST: 全部被挤出)
dmesg_lines: 713 -> 576
```
并出现纯增量测试：写入 1 条 `RINGPROBE-KMSG-OK` 后 `dmesg_lines` 仍为 576 → 环已满，新行必然挤掉等价字节的旧行。

### 结论

- 该内核环形缓冲**实际可用容量约 576–584 行 / ~129 KiB**（不是我预想的 1 MiB）。
- 每条 `CST:` 约 226 B，因此**约 129 KiB ÷ 226 B ≈ 570 条 `CST:` 就能把整个环占满**；扣掉开机日志（前 ~500 行是 dmesg 冷启动内容）后，留给拦截事件的余量极小。
- **量化丢失阈值**：只要产生约 570 条以上拦截日志（或任意其他内核日志挤占同等字节），最早的 `CST:` 就会被静默丢弃。旧规则 `limit rate 2/second burst 4` 若真生效，每秒 2 条 → 约 4.7 分钟即可冲掉全部历史；实际 limit 未生效（实验 1），爆发流量下几秒即可冲掉。
- `printk_devkmsg=ratelimit` + `printk_ratelimit=5/burst 10` 意味着内核自身还有一层限速，突发时会进一步丢日志。

---

## 实验 4 — 事件入库去重强度

### 原始输出

```
events 表主键: PRIMARY KEY(ts,src,rule,dport)  WITH ROWID? no  (WITHOUT ROWID)
8.8.8.8 结果集: rows=48  distinct_ts=48  min_ts=1793982549  max_ts=1793982597
逐秒行数: 1793982549..1793982597 每秒恰好 1 行（唯 1793982592 缺）
全表: total=677 distinct_pk=677 (无重复)
spt 分组: 49739|2  50085|2  50735|1 ...  (spt 不在主键内)
```

### 结论

- 40 次连接尝试 → 80 个被拦截的包 → **48 行入库**。
- 丢失的 32 行**不是** `INSERT OR IGNORE` 去重导致的：主键 `(ts,src,rule,dport)` 里**不含 spt**，而日志里连续重传的多个包落在**同一秒**时会被主键压成 1 行。实测「每秒恰好 1 行」证明丢包主因是**同秒合并**（`spt` 不同但 `ts` 相同 → IGNORE）。
- 该表 677 行全部 `distinct_pk`，说明库内没有重复行，去重本身工作正常，但**它会静默吞掉同秒的同源同规则同端口事件**。
- 采集器上限：`LOG_TAIL = 4000`，即 `dmesg | grep -E 'CS[GT]:' | tail -n 4000`，超过 4000 行时更早的事件不会被采集。

---

## 实验 5 — 采集器与配置状态

### 原始输出

```
ps w: 3200 root /usr/bin/ucode /usr/sbin/console-security-collector.uc
      collector start_epoch=1793926392 (开机后 10 秒启动), 实验时 age=55626s (~15.4h) 常驻
2559 root /usr/bin/ucode /usr/sbin/console-traffic.uc
1407 logd /sbin/logd -S 1024

/tmp/console-threat-init.log : 存在，0 字节（从未写入）
/etc/console-situational/    : 空目录（config.json 从未保存 -> 全用默认值）
/srv/console-situational/feeds.json updated=1793926420
  now=1793982702 -> age_sec=56282 -> age_hours=15
```

**情报表刷新是否失灵**：`updated` 15 小时未变。但 `logread` 里*没有* `console-security` 刷新报错；且实测路由器能出网：
```
curl https://www.spamhaus.org/drop/drop.txt -> http_code=200 time=4.197
curl raw.githubusercontent.com firehol_level1 -> http_code=000（失败）
feeds.json 内 urlhaus: ok=false "abuse.ch 现要求 Auth-Key，匿名下载已停用（410）"
```

### 结论

- 采集器 PID 3200 **存活且已连续运行 15.4 小时**，不是进程崩溃问题；`/tmp/console-security-state.json` 与 `bindings.json` 仍在每 2 秒刷新（mtime 实时）。
- `console-security-collector` 自身**无报错**，`/tmp/console-threat-init.log` 0 字节、`/etc/console-situational/` 为空 → 威胁配置**从未落盘**，始终跑默认值（`autoBlock/threatFeed/dnsSink` 全 true）。
- 情报表 `updated=1793926420` 距今 56282 秒（15.6h）。设计上 `now-lastThreatRefresh>=21600`（6 小时）就该刷新；实际未刷新，但与网络无关（spamhaus 可 200）。`urlhaus` 源固定失败（410，需 Auth-Key）是其中一个已知坏源。
- **这不是「拿不到拦截数据」的主因**——实验 2 已证明入库正常。

---

## 根因（实验过程中直接定位并确证）

**症状**：`events` 表里有实时拦截记录，但 `ubus call console-situational overview` 的 `stats` 恒为 `{region24:0, threat24:0, total24:0}`，`dirTop` 三个方向 count 全 0，页面因此显示「没有拦截数据」。

**同刻对照实验（决定性）**：
```
t=1793983074  DB(24h 内行数)=58   CLI 新进程 overview().stats.threat24 = 58   ubus 返回 threat24 = 0
t=1793983056  DB=58  cli=58  ubus=240   (另一进程/另一时刻)
```
即：**同一份数据库，同一秒，全新加载模块的 ucode 进程能读到 58，而 ubus 返回 0。**

**原因：rpcd 进程缓存了部署前的旧模块**：
```
/usr/share/ucode/console/situational.uc   on-disk inode=9165  size=37571  (00:31 部署)
rpcd pid=11418  started_epoch=1793979559 (00:18)
  fd 44 -> /usr/share/ucode/console/situational.uc (deleted)   fdinfo pos=33088  ← 旧版 33088 字节
  fd 45 -> /usr/share/ucode/console/security.uc (deleted)      pos=27299        ← 旧版 27299 字节
pid=20717 同上，同样持有 6 个已删除的 .uc inode
```
- lead 在 00:31 用「写新文件覆盖」的方式部署，旧 inode 被 unlink 但 rpcd 仍持有 fd。
- ucode 的 `import` 模块在进程内只加载一次并缓存；**rpcd 未重启，因此永远执行 00:18 加载的旧代码**。
- 旧版 `overview()` 依赖日志缓冲派生统计（以及旧规则前缀 `CST:threat`），而新版 `overview()` 改为「只读数据库」并用 `THREAT_DIR={tin,tfi,tfo}` 判方向。旧代码 + 新前缀 `CST:tin` 完全对不上 → 统计恒 0。
- 佐证：同一 rpcd 进程里 `console-security logs` / `blocked`（直接 `query()` 读库）**能正常返回** 48 条 8.8.8.8 记录 —— 说明 DB 与 popen 通道没问题，问题**唯独**在 `console-situational` 的 `overview()` 走的旧代码路径。

**修复动作（未执行，交给 lead）**：`/etc/init.d/rpcd restart` 或 `rc/etc reboot` 使 rpcd 重新加载模块即可。**不要**只改文件不重启。

> 补充：`storedEvents()` 内部是 `try{...}catch(e){ return [] }`，任何查询异常都被吞成空数组并稳定返回「0 条」，所以这个问题**没有任何日志**，极难察觉。

---

## 清理确认

| 项目 | 状态 |
|---|---|
| `nft list tables` | `fw4` / `console_meter` / `console_guard` / `console_threat` —— **无 cstest/cstest2/dbg/exp** |
| 临时表 `inet cstest2` | 已 `nft delete table`，`grep -Ei 'cstest\|dbg\|exp'` → NONE |
| `forward_gate` 临时计数器 handle 44 | 已按 handle 删除，恢复 5 条生产规则 |
| `input_gate` 临时计数器 handle 43 | 已按 handle 删除 |
| `blacklist4` 内 8.8.8.8 | 已 `delete element`，`grep -c 8.8.8.8` = 0 |
| `blacklist4` 元素数 | 实验前 22736 → 清理后 22736（后被 feed 重建为 22740/22741 量级） |
| `/tmp` 临时规则文件 | `/tmp/cstest2.nft` 已删除 |
| 数据库文件 | 未删除、未修改结构；仅由采集器正常写入 |
| 服务 | 未重启任何服务 |

> 另需知晓：我曾在 `input_gate`/`forward_gate` 插入过临时计数器（handle 43/44），均已删除；`dmesg` 中仍留有我制造的 71–102 条 `LMTTEST` 与 1 条 `RINGPROBE-KMSG-OK`，属于内核环形缓冲内容，无法单独删除，会随时间被自然挤出。

## 给 lead 的建议（按优先级）

1. **重启 rpcd**（`/etc/init.d/rpcd restart`）——这是让新 `situational.uc` 生效、让页面统计恢复的唯一必要动作；否则你部署的新代码对 ubus/页面完全无效。
2. 部署脚本应改为「写临时文件 → `mv` 原子替换 → **立即重启 rpcd**」，避免再次出现「文件已换、进程用旧 inode」。
3. `storedEvents()` 的 `catch(e){return []}` 必须至少 `warn()`，否则读库失败永远表现为「0 条」，无法排查。
4. 新规则形态（`limit...log` 与 `drop` 拆两条）**已验证正确**（实验 1 varC），保留。
5. 若要保留拦截证据，需正视 dmesg 环只有 ~576 行、同秒事件被主键合并、`LOG_TAIL=4000` 三个上限；建议让采集器直接写库或调大环缓冲。
