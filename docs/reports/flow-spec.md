# 流控分流（console-flow）实现规格 v1

> 本文件是 Lead 与两名实现者的契约。任何接口字段改名必须先通知 Lead。
> 目标：在 `luci-app-console` 内新增一级菜单「流控分流」，包含 分流设置（多线负载 / 协议分流 / 端口分流 / 域名分流 / 上下行分离）、智能流控、终端限速。

## 1. 已核实的运行环境（2026-11-08，实机 192.168.1.1）

| 事实 | 值 |
|---|---|
| 系统 | OpenWrt SNAPSHOT，kernel 6.18.55，x86_64，virtio 网卡 |
| 网卡 | eth0→br-lan(192.168.1.1/24)，eth1→wan(dhcp, 172.16.10.13, gw 172.16.10.1)，eth2→lan2(192.168.2.1/24)，cvpnc/cvpns 为 VPN tun |
| 防火墙 | 仅 firewall4 / nftables 1.1.6（**无 iptables**、无 ipset） |
| nft | `meta mark set`、`ct mark set`、`meta mark & mask ==`、`jhash ... mod N`、`numgen inc mod N vmap{...jump}`、命名 `limit`、`quota`、interval 集合、`nft -j` 全部实测可用 |
| ip | iproute2-7.3.0（ip-tiny 二进制，`ip rule add fwmark`、`ip route replace table N default via ...`、**multipath nexthop weight** 实测可用）；无 `ip-full` |
| tc / 调度 | **无 tc 二进制；内核无 htb/cake/ifb/cls_fw**（仅内建 CONFIG_NET_SCH_FQ_CODEL=y）。→ 限速只能用 nftables `limit`／`quota` 丢包方式，不能做整形。 |
| dnsmasq | 2.93，**no-ipset / no-nftset / no-DHCPv6 选项未编入**（`no-nftset`）→ 域名分流必须自己解析域名并写 nft 集合 |
| ucode | 支持 fs/uci/ubus/uloop/math/sqlite；rpcd ucode 模块位于 `/usr/share/rpcd/ucode/`，**修改需重启 rpcd** |
| 现有 nft 表 | `inet fw4`、`inet console_guard`、`inet console_meter`、`inet console_threat`（勿改名/勿冲突） |
| 现有 fwmark | mihomo 用 `fwmark 0x434d` + table 201 + prio 10390 → **本功能避开** |
| 备份目录 | `/etc/console-backup/`（已有 network.last-good、portmap.firewall.last-good 等） |
| 磁盘 | / 剩余约 155 MB |

约束：
- **不得修改内核、不得要求重新编译内核或 tc 模块**。
- 纯 nft + ip route/rule 实现，与 fw4 共存（自建独立表 `inet console_flow`，不复用 fw4 链）。
- 现有代码风格：文件头 `// SPDX-License-Identifier: Apache-2.0`，中文 UI 文案，UTF-8 无 BOM。

## 2. 文件与职责（互不重叠）

### 引擎侧（teammate `flow-engine`）
- `package/luci-app-console/root/usr/share/ucode/console/flow.uc`（主引擎，可拆 `flow-*.uc`）
- `package/luci-app-console/root/usr/share/rpcd/ucode/console-flow`
- `package/luci-app-console/root/usr/share/rpcd/acl.d/luci-app-console-flow.json`
- `package/luci-app-console/root/etc/init.d/console-flow`
- `package/luci-app-console/root/etc/uci-defaults/98_console-flow`
- `package/luci-app-console/Makefile`（只允许追加依赖，见 §7）
- 自测脚本放 `package/luci-app-console/tests/flow-*.uc`（可选）

### 前端侧（teammate `flow-ui`）
- `package/luci-app-console/htdocs/luci-static/resources/view/console/flow-*.js`
- `package/luci-app-console/htdocs/luci-static/resources/console/flow*.js`（共享 model/图表）
- `package/luci-app-console/htdocs/luci-static/resources/console/flow.css`
- `package/luci-app-console/root/usr/share/luci/menu.d/luci-app-console-flow.json`
- `package/luci-theme-console/htdocs/luci-static/resources/menu-console.js`（只加一个 `flow` 图标）
- `package/luci-app-console/htdocs/luci-static/resources/console/dashboard.js`（把 `[ 'flow', '流控分流' ]` 改成带 routes 的链接）

**任何人不得写对方目录。** Lead 负责 `.stage/` 文档、部署、实机验证、README 更新。

## 3. 配置模型（/etc/console-flow/config.json）

单一 JSON 文件，原子写入（temp+rename），`revision` 递增用于乐观锁。缺省全禁用。

```jsonc
{
  "revision": 0,
  "enabled": false,

  // 线路：WAN 候选。id 固定 alnum/_/-，line = 接口逻辑名（wan/wan2/...）
  "lines": [
    { "id": "wan",  "name": "默认线路", "interface": "wan", "weight": 1, "enabled": true, "upKbps": 0, "downKbps": 0 }
  ],

  // 多线负载
  "load": {
    "enabled": false,
    "mode": "weighted",        // weighted | failover
    "sticky": true,            // 同源同目标固定线路（connmark 粘滞）
    "check": { "enabled": true, "interval": 10, "fail": 3, "up": 2, "targets": ["223.5.5.5", "119.29.29.29"] }
  },

  // 协议分流（按 L4 协议/端口 → 线路）
  "proto": [
    { "id": "p1", "name": "UDP 走线路2", "enabled": false, "protocol": "udp", "ports": "", "src": "", "dst": "", "line": "auto" }
  ],

  // 端口分流（按目的端口段/源网段 → 线路）
  "port": [
    { "id": "t1", "name": "80/443 走线路1", "enabled": false, "protocol": "tcp", "ports": "80,443,8000-8100", "src": "", "line": "auto" }
  ],

  // 域名分流（域名 → 解析出的 IPv4 集合 → 线路）
  "domain": [
    { "id": "d1", "name": "视频走线路2", "enabled": false, "domains": ["youtube.com"], "line": "auto", "ttl": 600 }
  ],

  // 上下行分离：上行（内网→外网 新建连接）与下行（外网→内网）分别指定的线路 + 各自限速
  "updown": { "enabled": false, "upload": "", "download": "", "uploadKbps": 0, "downloadKbps": 0 },

  // 智能流控：按内网 IP 公平限速（丢包式）
  "smart": {
    "enabled": false, "perIpUpKbps": 0, "perIpDownKbps": 0,
    "totalUpKbps": 0, "totalDownKbps": 0,
    "exempt": [], "maxDevices": 256
  },

  // 终端限速：逐设备（IP 或 MAC-IP 绑定）
  "limit": [
    { "id": "l1", "name": "会议室 TV", "enabled": false, "ip": "192.168.1.50", "upKbps": 512, "downKbps": 2048, "comment": "" }
  ]
}
```

规则限制：`rules` 总数 ≤ 512；`limit` ≤ 256；单个端口串 ≤ 400 字符且最多 16 段；域名 ≤ 256/组。

## 4. rpcd 契约（object `console-flow`）

全部返回对象；失败返回 `{ error: "中文错误信息" }`（rpcd 层捕获 ucode 异常）。

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `state` | — | `{ config, lines, devices, topology, runtime, pending, caps }` | 只读聚合；`runtime` 含各线路 up/ip/gateway/degraded、nft 计数、命中的 set 元素数 |
| `check` | `{ config }` | `{ ok:true, config: <规范化>, plan:{ nftRules, ipRules, tables, warnings:[] } }` | 只校验 + 生成计划，**不落盘不改系统** |
| `apply` | `{ config }` | `{ ok:true, state, pending:{ secondsLeft } }` | 校验 → `nft -c` → 备份 → 原子生效 → 120 秒确认窗口 |
| `confirm` | — | `{ ok:true }` | 取消回滚计时 |
| `rollback` | — | `{ ok:true }` | 立即回滚到上一份可用配置 |
| `resolve` | `{ config }` | `{ ok:true, groups:[{ id, domains:[{name, addresses:[], error }] }] }` | 解析域名（不落盘），UI「立即解析」用 |
| `reset` | — | `{ ok:true, config }` | 清空全部配置并卸载 nft 表/ip rule |

`state.lines[]`：`{ id, name, interface, weight, enabled, upKbps, downKbps, up, degraded, addresses[], gateway, device, ifname }`
`state.devices[]`：`{ mac, ip, hostname, iface, up, down }`（来自 DHCP 租约 + host hints + console_meter 计数，取不到就省略字段，**禁止编造 0**）
`state.pending`：`null` 或 `{ secondsLeft }`
`state.caps`：`{ nft:true, shaping:false, shapingNote:'内核未编译 tc 调度模块，限速为 nftables 丢包限速' }`

## 5. 生效方式（nft / ip）

标签与路由表：
- 线路 fwmark 基址 `0x46460000`，第 i 条启用线路 `mark = 0x46460000 | (i+1)`，掩码 `0xffff00ff`（同时保留 mihomo 的 0x434d 不受影响）。
- 每线路一个路由表：`table = 300 + i`，内容 `default via <gateway> dev <ifname>`；`ip rule add fwmark <mark>/0xffff00ff table <300+i> prio <10400+i>`。
- 线路网关从 `network.interface.<iface>` 的 ubus status 取（route/ipv4-address）；无网关或未上线则整条线路禁用并降级。

nft 表 `inet console_flow`（独立，不自建 hook 冲突：仅在 `prerouting`/`forward`/`postrouting` 上以 loopback 之外的条件工作；不得改动 fw4 规则）：

```
table inet console_flow {
  set lan { type ifname; elements = { "br-lan", "eth2" } }
  set wan { type ifname; elements = { "eth1" } }
  set domain_<groupId> { type ipv4_addr; flags interval; }   // 域名解析结果
  chain prerouting {            // priority -150 (mangle)
    type filter hook prerouting priority -150; policy accept;
    // 1) 已建立连接还原 mark（粘滞），保证同一连接不跨线路抖动
    ct state established,related meta mark set ct mark
    // 2) 逐规则打分：协议/端口/域名 → 指定线路
    ...
    // 3) 多线负载：未命中规则的 new 连接按权重分配
    meta mark & 0xffff0000 == 0x46460000 numgen inc mod <N> vmap { 0: meta mark set 0x46460001, ... }
    // 4) 写回 conntrack，供回程与后续包使用
    ct state new ct mark set meta mark
  }
  chain forward { type filter hook forward priority -5; ... 限速/丢包 ... }
  chain postrouting { type nat hook postrouting priority srcnat; ... 按线路 SNAT（masquerade） ... }
}
```

限速：
- 终端限速：`forward` 链中每条启用规则生成两条（上行 `ip saddr X limit rate over U/second counter drop`，下行 `ip daddr X limit rate over D/second counter drop`）。
- 智能流控：为 `state.devices` 中的内网 IP（最多 `maxDevices`）生成同样的两条规则，速率取 perIp 值；同时生成总速率规则（对 LAN 汇总 `limit rate over total/...`）。
- 单位换算：Kbps → nft 用 `kbytes/second` 时按 `kbps*1000/8` 字节数（整数，最小 1）。**Kbps 指比特率。**

域名分流：`resolve` 与后台服务每分钟（按组 ttl）用 `/usr/bin/nslookup <name> 127.0.0.1` 解析 A 记录，写入 `domain_<groupId>` 集合；解析失败保留旧值并在 `state.runtime` 报 `unresolved`，不阻断页面。

安全与一致性（沿用 console-portmap / console-security 的既有做法）：
1. 本地加锁 `/tmp/console-flow-write.lock`（`mkdir` 法）。
2. 先生成 `/tmp/console-flow-check.nft`，`nft -c -f` 通过后才生效。
3. 生效前把当前 config 与当前 nft 文本备份到 `/etc/console-backup/flow.{config,nft}.last-good`、`/etc/console-backup/flow.{config,nft}.previous`。
4. 先写 `/etc/console-flow/pending.json`（含 boot_id + 单调 uptime 截止时间）再生效；120 秒未 `confirm` 自动回滚（后台 `console-flow-stop` 式延迟进程，参照 console-security 的实现）。
5. 服务 `console-flow`（procd，START=97）开机恢复：读 config → 重建表/规则/路由；无 config 则只清理。
6. 线路热插拔：`/etc/hotplug.d/iface/20-console-flow` 调用 `/usr/sbin/console-flow-refresh.uc`（可选实现，逻辑简单时并入 init 脚本 reload）。

卸载（`reset` 或服务 stop）：`nft delete table inet console_flow`（忽略不存在）、删除本功能添加的所有 `ip rule`（按 prio 10400..10499 精确删）与 `ip route flush table 300..319`。**绝不宽泛 flush，只动自己的编号区间。**

## 6. 菜单与页面

菜单 `root/usr/share/luci/menu.d/luci-app-console-flow.json`：

| path | title | view | order |
|---|---|---|---|
| `admin/flow` | 流控分流 | firstchild | 33 |
| `admin/flow/steer` | 分流设置 | firstchild | 10 |
| `admin/flow/steer/load` | 多线负载 | `console/flow-load` | 10 |
| `admin/flow/steer/proto` | 协议分流 | `console/flow-proto` | 20 |
| `admin/flow/steer/port` | 端口分流 | `console/flow-port` | 30 |
| `admin/flow/steer/domain` | 域名分流 | `console/flow-domain` | 40 |
| `admin/flow/steer/updown` | 上下行分离 | `console/flow-updown` | 50 |
| `admin/flow/smart` | 智能流控 | `console/flow-smart` | 20 |
| `admin/flow/limit` | 终端限速 | `console/flow-limit` | 30 |

ACL：`read` 允许 `state`/`check`/`resolve`；`write` 允许 `apply`/`confirm`/`rollback`/`reset`；另需 `uci` 只读 `network`、`firewall`、`dhcp`。菜单依赖 `acl: ["luci-app-console-flow"]`。

页面要求：
- 复用 `console-system.css` 的 `.cbi-*` 与 portmap.css 风格（表格 + 弹窗编辑 + 行内启停），不引入新框架。
- 所有页面顶部显示「服务未启用/未应用」状态条；`caps.shaping === false` 时在终端限速/智能流控页常驻提示：`内核未编译 tc 调度模块，本页限速为 nftables 丢包限速，不整形队列。`
- 应用走 `check → apply → 120 秒确认/回滚` 流程，与防火墙页面一致（`pending` 存在时顶部显示倒计时与确认按钮）。
- 线路下拉为空时显示引导：「先在 内外网设置 中添加外网接口」，禁用保存。
- 保存失败必须显示后端中文错误，不得静默。
- 页面在 `admin/flow/steer/load` 等 5 个子页共享同一 `config`，保存时只提交本页修改的字段（其余字段原样回传，revision 校验）。

## 7. Makefile

只追加：`LUCI_DEPENDS` 末尾加 `+nftables-json`（`nft`、`ip`、`ucode`、firewall4 已存在）。**不要**加 `tc`、`kmod-sched-*`、`iptables`、`mwan3`、`pbr`、`sqm`。PKG_VERSION 升到 `0.3.0`，PKG_RELEASE `1`。

## 8. 验收

本地：
1. `node --check` 不适用于 ES module view，改用 `node -e "new (require('vm').Script)(...)"` 不行；至少用 `node --input-type=module --check`（无 import 语法时用 `node --check`）。
2. `ucode -c` 或 `ucode -e 'import ...'` 能在编译机上静态检查（编译机 10.0.0.10 有 ucode 吗？没有则用实机 192.168.1.1 验证）。

实机（Lead 统一执行，禁止两人同时改设备）：
1. 部署新增/改动文件（SSH + SFTP），`/etc/init.d/rpcd restart`。
2. `ubus call console-flow state` 返回完整结构。
3. `check` 一个最小配置（1 条线路 + 1 条协议分流）→ `apply` → 验证：`nft list table inet console_flow`、`ip rule`、`ip route show table 300`、从 192.168.1.5 ping/curl 外网仍通（192.168.1.1 本身 SSH 不断）。
4. 120 秒内 `confirm`；再测 `rollback`；再测 `reset` 后 `nft list tables` 不含 console_flow，`ip rule` 无 104xx。
5. 断网保护：apply 一个错误配置必须被 `check` 拒绝且不生效。
6. 恢复：验证结束后按「无配置、服务启用但 disabled」状态收尾，并确认实网可访问。

## 9. 交付物

- 上述源码文件。
- `package/luci-app-console/README.md` 追加「流控分流」章节（Lead 写）。
- `.stage/flow-verify-*.md` 验证报告（Lead 写）。
