# 「流控分流」——已有插件/开源实现调研与选型结论

日期：2026-11-08　执行：Lead　设备：192.168.1.1（OpenWrt SNAPSHOT / kernel 6.18.55 / x86_64）

## 一、用户诉求（对照参考图）

参考图是爱快（iKuai）左侧栏的「流控分流」一级菜单，其下为：

- **分流设置**（可再展开）：多线负载、协议分流、端口分流、域名分流、上下行分离
- **智能流控**
- **终端限速**

用户明确要求：**先搜索有没有已实现的插件或开源代码，优先使用。**

## 二、候选实现逐项核查（结论：全部不可直接复用）

| 候选 | 能覆盖的功能 | 在本机可用性核查结果 | 结论 |
|---|---|---|---|
| **mwan3** 2.12.2（feeds/packages/net/mwan3） | 多线负载、故障切换 | 依赖 `iptables`、`iptables-mod-conntrack-extra`、`iptables-mod-ipopt`、`ipset`；实现是 `iptables-restore` + `libwrap_mwan3_sockopt.so`。**本机是 firewall4/nftables，无 iptables、无 ipset**（实测 `opkg/apk list --installed` 与 `nft list tables` 均确认） | ✗ 不可用。硬装 iptables 会与 fw4 双栈打架，属于严重退步 |
| **pbr** 1.2.2（策略路由） | 协议/端口/域名分流 | 依赖 `ip-full`（本机是 ip-tiny）、`resolveip`、`nftables-json`。**域名走 dnsmasq nftset，而本机 dnsmasq 编译选项为 `no-nftset`** | ✗ 不可用 |
| **sqm-scripts** | 智能流控、终端限速 | 强依赖 `tc` + CAKE/HTB + `kmod-ifb`。**本机无 tc 二进制，内核仅内建 CONFIG_NET_SCH_FQ_CODEL=y，htb/cake/ifb/cls_fw 全部未编译**（已核对 build_dir 的 kernel .config 与实机 /lib/modules） | ✗ 不可用。要装必须重编内核，违反「不改内核」前提 |
| **qosify**（eBPF + CAKE） | 分流 + 整形 | 需 `kmod-sched-cake`、`tc-bpf`、eBPF 支持；本机 `CONFIG_PACKAGE_qosify is not set`，内核无对应模块 | ✗ 不可用 |
| **nft-qos**（rosywrt） | 终端限速 | 上游已并入 packages，但本仓库 `.config` 未选；且它只做 per-IP 简单限速，**没有多线负载、没有分流、没有 dnsmasq nftset 可用** | △ 仅「终端限速」单点可用，功能覆盖不到 1/8，且需新增包依赖 |
| **luci-app-qos-legacy / qos-scripts** | 简单 QoS | 依赖 tc；本机不可用 | ✗ |
| **trafficshaper 1.0.0**（feeds） | 按 LAN 地址整形 | 依赖 `tc + kmod-sched-core + kmod-sched-cake + kmod-ifb + kmod-sched-connmark` | ✗ 依赖不满足 |
| **tcfilter 1.0**（feeds） | 持久化 tc 过滤 | 依赖 `tc-full + kmod-sched-flower`；且定位是硬件 offload 前端，不做业务抽象 | ✗ |
| **OpenAppFilter / oaf**（本仓库已装 7.0.2） | 七层应用识别、应用过滤、上网控制 | 源码核查（`oaf/src/*.c`）**只做 DPI 匹配与丢包/放行，无任何限速、无 packet mark 设置**（grep `skb->mark`/`fwmark`/`limit` 均无业务命中）。可作为「协议分流」的应用识别数据源，但它本身不实现分流与限速 | △ 只能当数据源，不能当实现 |
| **WanBlendr**（GitHub 239626，nftables-only 多线负载） | 多线负载/故障切换 | **源码未公开**（README 明确 "Parts of the source are intentionally withheld"），只有 UCI 配置片段与固件；无 license | ✗ 不可复用（授权与可用性都不成立） |
| **DualWiFI**（GitHub，Linux nftables 连接级负载均衡） | 多线负载 | 面向通用 Linux（Python + TUI），非 OpenWrt 包结构，无 LuCI 集成 | ✗ 只能借鉴思路 |

## 三、结论：自研最小充分实现，但严格复用上游既有做法

没有任何现成插件能同时满足「本机已装组件约束 + 爱快式 7 个子功能」，因此按用户「优先使用已有」的意图，采取**能力替代 + 模式复用**：

1. **技术路线直接照搬上游 nftables 方案**，不发明新机制：
   - fwmark → `ip rule` → 独立路由表：与 mwan3 / pbr / mihomo（本机已用 `0x434d`/table 201/prio 10390）同构，只是把 iptables 换成本机唯一可用的 nftables。
   - 多线负载用 `numgen inc mod N vmap { ... jump }` 做**逐连接**加权分配，用 `ct mark` 做**粘滞**（同一连接不跨线路抖动）——这正是 WanBlendr/DualWiFi/mwan3 共用的连接级负载均衡原理。
   - 限速用 nftables `limit rate over` / `quota` 做**丢包式限速**（本机无 tc，无法整形），这与 nft-qos 的实现方式一致。
   - 域名分流：因 dnsmasq 无 nftset，改为**自解析 A 记录写入 interval 集合**，与 pbr 在无 resolver 时的降级路径等价。
2. **复用本仓库 luci-app-console 已有的工程模式**（不新造轮子）：
   - `console-portmap.uc` 的「模型校验 + `nft -c` 预检 + 原子替换 + `/etc/console-backup` 备份」
   - `console-security.uc` 的「写 pending.json（boot_id + 单调 uptime）→ 120 秒确认窗口 → 超时自动回滚」
   - rpcd ucode 模块 + ACL 分离（read/write 分权）的既有写法
   - LuCI view 复用 `.cbi-*` 与 portmap.css 的表格/弹窗风格
3. **复用已装组件作为数据源**：DHCP 租约、`luci-rpc.getHostHints`、`inet console_meter`（内网设备流量）、OpenAppFilter（可选，应用识别）。不重复造采集器。

## 四、能力边界（必须在 UI 上明示，不得假装支持）

| 功能 | 本机可做到 | 做不到（需重编内核） |
|---|---|---|
| 多线负载 | 逐连接加权分配 + connmark 粘滞 + 故障探测切换 | 逐包/逐流的精确带宽占比（需要 tc） |
| 协议分流 | 按 L4 协议/端口、以及可选的 OAF 应用标识 | 无需 OAF 的纯七层识别 |
| 端口分流 | 按目的端口段 + 源网段 | — |
| 域名分流 | 自行解析 A 记录 → nft interval 集合 → 线路 | 与 dnsmasq 缓存联动的实时 nftset（本机 dnsmasq 无此编译选项） |
| 上下行分离 | 上行/下行分别指定线路 + 各自限速 | — |
| 智能流控 | 每 IP 公平丢包限速 + 总速率上限 | CAKE/fq_codel 的整形队列与延迟控制 |
| 终端限速 | 逐 IP/终端 up/down 丢包限速 | 精确整形（无 tc） |

> 已在 flow-spec.md 要求前端在这两页常驻提示：**「内核未编译 tc 调度模块，本页限速为 nftables 丢包限速，不整形队列。」**

## 五、参考链接

- [openwrt/packages mwan3](https://github.com/openwrt/packages/tree/master/net/mwan3)
- [pbr（Policy Based Routing, nft 版）](https://github.com/mossdef-org/pbr/)
- [tohojo/sqm-scripts](https://github.com/tohojo/sqm-scripts)
- [openwrt/qosify](https://github.com/openwrt/qosify)
- [rosywrt/nft-qos](https://github.com/rosywrt/nft-qos)
- [239626/WanBlendr](https://github.com/239626/WanBlendr)（nftables-only 多线负载，源码未公开）
- [anshukumar2932/DualWiFI](https://github.com/anshukumar2932/DualWiFI)（nftables 连接级负载均衡 + 策略路由）
