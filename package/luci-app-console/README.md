# OpenWrt Console：系统概况

新增的「防火墙」一级菜单、地区访问控制与逐设备流量采集见 [SECURITY.md](SECURITY.md)。

「流控分流」一级菜单（多线负载、协议/端口/域名分流、上下行分离、智能流控、终端限速）见本文的[流控分流](#流控分流)一节。

目前实现爱快参考页面的系统概况：蓝色顶栏、深色侧栏、路由状态、速率、物理连接、接口、AC/无线区域、协议流量环图及近五分钟上下行曲线。品牌使用 OpenWrt，图标、样式和代码独立实现，未复制爱快图片或闭源代码。

参考：[爱快系统概况功能说明](https://www.ikuai8.com/support/ymgn/lyym.html)。

## 在 OpenWrt 中的入口

包名：`luci-app-console`，依赖 `luci-theme-console`。安装后 `/cgi-bin/luci/admin/console` 为系统概况；该菜单排序早于默认状态菜单，因此访问管理首页时会进入系统概况。主题为 LuCI 管理页面提供统一顶栏、按设备能力生成的侧栏、表单和移动端样式；各管理页面仍使用 LuCI 原生组件及配置逻辑。首页侧栏也根据 LuCI 的权限和设备条件列出已安装页面。

源码位于本仓库的 `package/luci-app-console/`，可以被 Git 跟踪。开发时下载到 `feeds/luci/` 的 LuCI 官方源码是被忽略的依赖，不要把二开文件仅保存在该目录。

## 当前数据和功能

页面响应优化：概况页在加载依赖期间并行读取 CPU、网卡和连接计数建立采样基线，再读取一次完整快照，取消固定等待与重复完整查询。系统版本信息在页面内缓存 5 分钟，图表历史数据未变化时复用已有绘图节点；刷新期间切换历史范围会排队更新。接口增强轮询在页面隐藏或上次请求未完成时跳过。网络、DHCP 和 VPN 的主要保存、连接操作立即显示处理状态并阻止重复提交，菜单切换即时显示加载提示。原生 LuCI 页继续使用自身的保存与应用机制。

接口管理页现提供内外网分组选择、连接概览及所选接口的绑定、协议、地址、网关、DNS、链路和流量信息。内网接口固定使用静态地址；外网接口可选静态地址、DHCP 客户端或 PPPoE。内网接口地址与 DHCP 服务器分配给终端的地址由不同设置管理。通过 `luci-theme-console` 的增强模块接入现有页面，编辑、新增、重连、停止和删除入口委托原生 LuCI 控件，配置仍使用原生验证、暂存和应用机制；状态数据读取失败时退回原生列表。设备和全局网络配置标签页仍可使用。接口计数包含独立的 IPv4/IPv6 逻辑接口，不等于物理网卡数量。

绑定了网桥的内网接口，行内直接显示「成员 eth2 / eth3 …」，操作区多出「桥成员」按钮。该弹框用勾选框管理成员口：只有物理网卡可加入，已被其它接口独占或已属于其它网桥的网卡置灰并标注占用者，至少保留一个成员。保存走 `console-net` 的 `bridge_check`（只校验）与 `bridge_apply`（写入并 reload），只改 `config device` 段的 `ports`，不动接口段的地址配置；成员无变化时直接返回 `changed:false`，不写盘、不 reload。LAN 角色的桥成员变更套用与地址修改相同的 120 秒确认窗口，超时未确认由守候进程自动还原备份。此前页面文案让人去原生「设备」页改成员，但那个入口被 ACL 隐藏且没有其它入口，现在不再需要。

可选网卡列表按 `/sys/class/net/<dev>/device` 是否为物理设备判定：物理网卡与已建立的 `br-*` 网桥保留，TUN/TAP 隧道（`cmihomo`、`cvpns`、`cvpnc`）一律排除。桥成员列表解析 `uci show` 的多值输出时先去掉引号再按空白切分——`network.@device[0].ports='eth2' 'eth3'` 这种格式若按单个空格直接切，得到的是带引号的碎片，一个成员也对不上。

### 接口编辑弹框的「当前连接信息」

点接口「编辑」时，弹框上半部分是只读的「当前连接信息」区块，把该接口真实生效的连接状态一次摊开，不必再切到概览页比对参数：网卡与 MAC、链路状态（载波、速率、双工）、生效 MTU、IP 地址、子网掩码（`255.255.254.0（/23）` 形式）、默认网关、是否默认路由、DNS 服务器（按「静态配置 / 上游下发 / 写入 resolv」分源）、连接状态（拨号状态 + 在线时长 + 协议辅助进程名），桥接口另列成员口。接口行本身也改用后端直出的状态文案（`已获取地址` / `正在拨号` / `静态地址，无需拨号` / `已停用`），承担系统默认路由的那一行带「默认」徽标。

数据来源与边界：

| 信息 | 来源 | 说明 |
| --- | --- | --- |
| 生效 MTU、加载波、速率、双工、MAC | `ubus call network.device status`（按 `l3_device` 优先取设备） | 整个 `state` 只调用一次，全部接口复用。虚拟网卡上内核返回 `speed=-1`、`duplex=unknown`，统一归一化为「未知」显示 `—`，不当成 0 或原样透出。 |
| IP / 掩码 / 网关 / DNS / 在线时长 | `ubus call network.interface.<name> status` | 掩码同时给出前缀长度与点分十进制。网关取真实 nexthop；直连默认路由的 `0.0.0.0` 归一化为「未设置」，避免把 `0.0.0.0` 当成真实下一跳。 |
| 是否默认路由 | `/proc/net/route` 中 `RTF_UP` 且目标 `0.0.0.0/0` 的表项 | 多默认路由取 metric 最小。三态文案：`是（当前系统默认路由）` / `否（默认路由由 <接口> 承担）` / `否（系统无默认路由）`。 |
| 拨号状态 | 扫 `/proc/<pid>/cmdline` 识别 `pppd` / `udhcpc` / `odhcp6c` | 不通过 `ps`。设备名去 `nic-` 前缀后在 `/sys/class/net` 命中即归属该接口，并按 proto 过滤期望的进程类型——否则同设备上的 `wan`/`wan6` 会互相误报。取值 `static` / `connected` / `dialing` / `idle` / `disabled`，文案由后端直出，前端不再二次加工。 |
| DNS 写入情况 | `/tmp/resolv.conf.d/resolv.conf.auto` | 按 `# Interface <name>` 注释分段归到各接口。文件不存在时返回空表而非编造。 |

弹框同时提供可写的 **MTU** 输入框：初值取 `uci network.<name>.mtu` 原值，留空表示不配置（用系统默认），合法范围 68–9000 的整数，前端即时校验、后端再校验一次。提交语义是「缺省不触碰该选项、空串删除、数字写入」，因此不会在用户只是改 IP 时顺手清掉已有的 MTU。`runtime.ipv6` 作为 IPv4 地址行的附注展示——`wan6` 这类只有 IPv6 的接口，这是它能看出「活着」的唯一证据。

所有字段读不到时一律显示 `—`，渲染结果里不会出现 `undefined` / `NaN` / `null`。`tests/console-net-detail.cjs` 用合成样本覆盖四种接口形态、MTU 边界与「字段全缺失」降级；`tests/console-net-live-render.cjs` 用 2026-11-06 从真实设备抓取的 `ubus call console-net state` 返回值（`tests/fixtures/net-state-live.json`）逐项核对弹框文案与真实设备事实是否一致，两项各 33 / 47 条断言。

接口编辑弹框展示的全部字段都来自只读查询；这些新增读取不扩大 ACL，仍走既有的 `luci-app-console-net` 权限。

| 区域 | 数据来源与行为 |
| --- | --- |
| 路由状态 | `system.board/info` 与 `network.interface.dump`；显示主机名、版本、运行时间及 WAN 地址。已连接代表外网接口获取了地址，不代表已验证互联网可达性。 |
| CPU / 内存 | `/proc/stat` 两次采样间的 CPU 使用率；优先用可用内存计算使用率，iowait 作为空闲，避免重复计入 guest。 |
| CPU 温度 | 识别 CPU/SoC thermal zone 及 coretemp/k10temp 等 hwmon 传感器；没有对应传感器显示 `—`。 |
| 上下行速率 | 实时指标使用 WAN 三层设备字节计数差；后台 `console-traffic` 服务每5秒独立采集并持久保存最近15天的速率曲线，同一设备上的 IPv4/IPv6只计一次。支持多 WAN 汇总、单线路及5分钟/1小时/1天/15天曲线。计数重置、服务重启及超过15秒的采样间隔不会产生假速率。 |
| 连接设备 | 观测到数据包/字节计数变化的内网终端，保留120秒；利用主机信息和 DHCP 租约按 MAC 合并 IPv4/IPv6；可点击查看终端快照，有线/无线可分别查看。仅有 DHCP 租约不等于在线。 |
| 连接数 | 内核连接跟踪总数；点击进入 LuCI 实时连接监控。 |
| 接口 | 当前接口和链路状态；WAN/LAN 分类优先使用防火墙同名 zone，其次使用默认路由及常见接口名。详情进入原生接口设置。 |
| DHCP 池剩余 | 当前 IPv4 池范围减去有效租约、静态保留和池内路由器地址。只有在实际观测到 IPv4 租约（或调用方明确给出启用状态）时才显示数量；**地址池已配置但未在分配地址时改为显示“未生效”，不再给出看似健康的剩余数量**，无法判断时显示“状态未知”。不覆盖 DHCPv6、特殊 dnsmasq 地址标签、重叠地址池及外部 DHCP 服务。 |
| 无线 | 本机 AP 运行/停用、2.4GHz 和 5GHz 已关联终端；有6GHz终端时另行显示。无线配置不存在、无线状态接口不存在且 iwinfo 确认没有无线设备时，显示未检测到设备并禁用无线详情链接；检测或权限异常仍显示错误。 |
| 协议流量 | 采集器每60秒把转发流量的协议字节增量写入本机数据库（protocol 表），按 TCP、UDP、ICMP、其他汇总近30分钟/1小时/1天的累计值；页面刷新、重开浏览器不清零，保留最近1天。首次升级会用设备明细表回填历史（ICMP 无历史数据，从升级后开始统计）。 |
| 更新 | 前台每5秒读取；支持暂停、继续、立即刷新。浏览器标签页隐藏时暂停页面读取；后台速率采集持续运行。失败数据显示不可用和原因，下次重试，不填充虚构数据。 |

自定义 RPC ACL 只有读取权限，不执行命令或修改路由器配置。`conntrack` 为 LuCI 读取连接跟踪提供无 procfs 时的后备工具；流量计数要求内核 `nf_conntrack_acct=1`，OpenWrt 本仓库的默认 sysctl 已开启它。

“DHCP 池剩余”显示“未生效”时，含义是 uci 里配了地址池、但 dnsmasq 事实上没有在该接口提供 DHCPv4。最常见的原因是 OpenWrt 自带的安全检查：`/etc/init.d/dnsmasq` 在生成 `dhcp-range` 之前会调用 `dhcp_check()`，用 `udhcpc -n -q -s /bin/true -t 1 -i <接口>` 探测一次；如果收到 OFFER，就把 `1` 写入 `/tmp/run/dnsmasq.<实例>.<接口>.dhcp`，并放弃在该接口启动地址池（日志为 `found already running DHCP-server on interface ... use 'option force 1' to override`）。因此生成的 `/var/etc/dnsmasq.conf.*` 中没有任何 `dhcp-range`，`/tmp/dhcp.leases` 始终为空。这是同网段存在第二个 DHCP 服务器时的保护行为，不是 dnsmasq 故障：应先移除上游那个多余的 DHCP 服务器；确认要覆盖保护时，在「网络 → DHCP/DNS」对应接口上显式设置 `option force 1`。本页面只读取状态，不会代用户启用 DHCP，也不会写入 `/etc/config/dhcp`。

协议环图是连接跟踪**采样估算**，不含采样间已经结束的连接，且流量卸载可能降低计数精度。记录保留在当前页面内存中，最长一天；关闭/离开页面后不再记录，刷新页面重新建立基线。它不是后台24小时历史采集系统，也不能把 HTTPS 流量可靠识别为“视频、游戏、下载”等应用分类。

上下行速率历史与协议环图独立：数据位于 `/srv/console-history/`，由 procd 管理的开机自启服务写入按小时命名的 JSONL 文件，读取接口为只读 `console-traffic.history`。查询限于最近15天，输出不超过602个点；长时段按实际采样时长加权平均，无记录的区间保持空白。每小时清理完全过期的文件；最旧的边界小时文件会保留到整小时过期，接口始终只返回15天范围内的样本。浏览器关闭、页面切换、服务重启不删除历史；机器关机期间无法采集，断档不会补成0。新功能启用前的历史无法补录。此持久化范围只覆盖上下行速率，不包括 CPU、终端列表和协议环图。

可通过 `/etc/init.d/console-traffic status` 查看服务，`ubus call console-traffic history '{"seconds":300}'` 读取最近5分钟。单 WAN 按目前记录大小估算，15天原始数据约数十 MB，具体取决于线路数量和数值长度。持久化验证包含浏览器完全关闭后继续写入、采集服务重启保留原数据，以及隔离测试目录下的15天边界、零速率、断档、部分写入和过期清理。

速率曲线支持鼠标悬停联动：上下行图同时标出同一记录的时间和速率，缺失记录显示无记录；长时段标注区间平均并显示日期。触摸可点选，键盘聚焦图表后可用左右方向键、Home/End 浏览，Esc 关闭提示。

爱快云绑定、升级推送、集中 AC、当日 Web 认证和 DPI 应用分类需要额外服务；目前未接入。侧栏只列出设备上已安装且可访问的 LuCI 入口；菜单读取失败时显示基础入口和未接入提示。

## OpenVPN 虚拟组网

设备安装 OpenVPN 后，导航栏的“VPN”下显示“OpenVPN 状态”“OpenVPN 服务端”“OpenVPN 客户端”和“OpenVPN 账号”；依赖缺失或无权限时对应入口隐藏。服务端首次启用时生成本机 CA 和服务端证书，客户端使用现有账号密码认证；账号密码仅在路由器上以加盐 SHA-512 crypt 哈希保存。客户端还可填写固定 VPN 地址和后端 LAN 网段。服务端给所有站点推送服务端 LAN 与其他站点 LAN 路由，并用 `route`/`iroute` 将流量送到正确客户端；VPN 与 LAN 双向转发由独立防火墙区域管理。

“OpenVPN 状态”页面读取 OpenVPN 自身每 10 秒写出的状态文件，展示在线账号、分配到的虚拟 IP、来源地址、连接时刻、在线时长与空闲时长、累计收发字节，并按两次刷新之间的字节差计算实时速率。速率是该页面的本地计算：首次刷新、计数器重置或状态文件时间未前进时显示 `—`，不会给出负数或凭空的数值。已启用但未连接的账号一并列出并标记离线。状态文件缺失时明确提示服务端可能未启用，不填充虚构数据。该页面只读，权限与其他 VPN 页面一致。

服务端 WAN 入站默认关闭。启用时只放行配置的 OpenVPN 端口；仅在 LAN 使用时保留 LAN 入站规则。VPN 区域对客户端到本机的入站为 ACCEPT——客户端是已通过账号认证的受信对端，需要能访问路由器自身的服务（LuCI、SSH、DNS、ping），否则会出现“能连上 VPN、也能访问 LAN 设备，却打不开 192.168.1.1”。该区域同时启用 `mtu_fix`，由 fw4 对穿越隧道的 TCP 连接做 MSS 钳制，避免封装开销导致大包被丢弃。客户端凭据存入 root-only 文件，浏览器导出的 `.ovpn` 不含账号密码；客户端页面验证 CA 后启动 procd 管理的连接。两端均默认为停用，只有点按页面的启用/连接操作后才写入专属转发规则并启动。停止时删除此功能自己的防火墙规则，不触碰现有 WAN/LAN 配置。账号调整会重新生成服务端 CCD 并重启 OpenVPN 进程，已连接的 VPN 会短暂重连。

“OpenVPN 客户端”页面现支持直接导入 `.ovpn` 配置文件：选择文件后先解析并给出摘要（服务端地址、端口、协议、CA 证书、是否含客户端证书、是否需要账号密码、已采用的选项与未采纳的选项），服务端地址、端口、协议与 CA 自动带入表单，CA 转为只读；确认后点击“导入并连接”即按导入结果建立连接。导入支持内嵌 `<ca>`、`<cert>`、`<key>`、`<tls-auth>`、`<tls-crypt>`；客户端证书与私钥直接写入 root 专属文件，账号密码仍需在页面填写（证书认证的配置不需要账号密码）。仅采纳经过校验的加密、压缩与保活类选项；脚本钩子（`up`/`down`）、`script-security`、`management`、插件等一律忽略并在摘要中列出，外部文件引用（`ca file.crt`）在路由器上无法读取，只使用内嵌内容。文件内容只保留在页面内存中，最大 256 KB，不落盘持久保存。导入与手工填写两条路径生成的配置都会为覆盖本机直连网段的推送路由生成 `pull-filter ignore`，避免服务端推送同网段路由把路由器自身 LAN 流量引进隧道，导致管理地址失联。配置中的 `redirect-gateway` 需在页面显式勾选后才会生效，并会在断线期间影响本机自身上网路径。导入与断开连接都会重启 OpenVPN 服务，已连接的 VPN 会短暂重连。

站点互访要求各站点 LAN 网段、VPN 网段彼此不重叠，并在中心服务端为每个站点账号填写该客户端 LAN；客户端侧本机 LAN 填相同网段。服务端“客户端连接地址”填写公网 IP 或 DDNS 域名，客户端配置导出需要服务端启用并生成 CA。WAN 入站是否能从互联网连通、路由器上游端口转发及真实异地链路由设备管理员实际验证；本仓库验证覆盖配置校验、路由生成、认证和本机回环 TLS，不会擅自启用真实组网。

“客户端连接地址”只在导出客户端配置时必需，其余开关与保存不依赖它；未填写时账号页的导出按钮会保持禁用并给出提示。该地址必须是公网客户端可达的 IPv4 或 DDNS 域名：本机位于双层 NAT 之后（例如光猫拨号、路由器自身做二次 NAT）时，还需在上游路由器把对应端口转发到本机 WAN 地址（例如 TCP 1194 → 本机 WAN 地址），否则客户端拿到配置也无法建立连接。如果填写上游路由器的私有地址，导出会成功，但生成的配置只能在上游内网使用，无法从公网接入。

## Clash / Mihomo

VPN 菜单的“Clash / Mihomo”复用控制台 LuCI 样式，运行官方 Mihomo v1.19.33 内核。支持完整 YAML / JSON 配置链接、文件及粘贴导入，服务启停、规则 / 全局 / 直连模式、节点选择、单节点和全部延迟测试。js-yaml 4.1.1 随包提供，许可证见 `JS-YAML-LICENSE`。

启用服务后，所有以本机为网关、属于 `lan` 防火墙区域的内网设备自动进入 Clash，无需设置系统代理。当前覆盖 `br-lan`（192.168.1.0/24）和 `eth2`（192.168.2.0/24）。规则模式保留导入配置的规则和代理组，由规则决定 DIRECT、REJECT 或节点出口；局域网、RFC1918 私网、ULA 和现有 OpenVPN 私网路径不经代理。仍可使用路由器 LAN 地址的 7890 端口作为显式 HTTP / SOCKS5 代理。默认固件不带订阅且停用；已部署设备按用户要求启用，当前使用台湾节点和规则模式。

`mihomo-network.uc` 从防火墙和 netifd 识别 LAN 设备。每次启动准备受管理的 TUN（cmihomo，gvisor，自动路由和重定向），只接管 LAN 入站，排除 root 发起的本机流量以避免管理、DNS 和代理回环。内核负责创建和撤销 IPv4/IPv6 策略路由，DNS 使用独立的 TCP/UDP 1053 监听和 redir-host 模式。自有 nftables 表 `console_mihomo_dns` 将两个 LAN 的普通 53 端口查询重定向到内核；`.lan`/反向查询转回本机 dnsmasq。不会修改 DHCP、dnsmasq 或现有 UCI 防火墙配置。fw4 自动 include 保持自有 DNS 和 LAN→TUN 转发规则在防火墙重载后有效。导入配置中的其他监听器不直接启用。

procd 管理 `console-mihomo-run`，等待 TUN 就绪后应用 DNS/转发规则，页面显示“内网自动代理”就绪状态。停止时结束内核，撤销 TUN、策略路由和自有 DNS 接管，恢复原上网路径并关闭自启；启动开启自启。网络和防火墙配置变更会触发服务重载，重新识别 LAN。原有 OpenVPN 不随 Clash 启停。

HTTP(S) 订阅链接可以选择路由器下载或当前浏览器下载。浏览器方式需要订阅服务器允许跨域，否则可在电脑下载后上传文件。配置上限 2 MB，路由器下载最长 12 秒，浏览器下载最长 20 秒，内核校验最长 10 秒；失败保留原配置。更新配置须先停止服务。链接不持久保存，成功后清空；不支持单节点分享链接、Base64 节点列表或定时订阅更新。引用的外部规则和 GeoIP 等资源仍须完整准备。当前设备的 geoip.metadb 已在电脑下载，对照官方 release asset SHA-256 验证后传入，避免路由器下载不完整导致校验超时。

API 固定在 127.0.0.1:9097，随机密钥和配置目录权限为 0700，敏感文件为 0600。页面不回显节点凭据。节点切换后读取内核确认当前选择，下拉框与内核同步并可正确刷新；切换影响新连接。测速通过各节点访问固定 HTTPS 测试地址，单节点超时 4 秒，显示实测毫秒数或“超时或失败”及测试时间，不保证所有网站可达。结果仅缓存于 /var/run，导入新配置时清除。

“导入配置”区块底部的“清除配置”按钮可一次性清空已载入的配置与节点：先判运行状态并停用、停止服务，再调 `console-mihomo-network stop` 兜底撤销透明代理 nft 规则与策略路由，删除 `config.json`、`config.previous.json`、`candidate.json`、`vpn-candidate.json`、`lan-devices.json`、`api-body.json`、`cache.db`、`providers/` 下的 yaml 订阅缓存，以及 `/var/run` 里的站点测试、延迟、透明代理三个标记文件，最后 `fw4 reload`。保留 `secret`（控制密钥）、`geoip.metadb`（地理库）、`source-policy.json`、`vpn-proxy.json` 和 `providers/` 目录本身。无配置且服务未启动时按钮自动禁用；重复执行幂等，返回 `{"ok":true,"stopped":false}`。清除操作不写 `dns.nft` / `forward.nft`——这两个文件归 `console-mihomo-network` 模块管理，写它们会报“无法保存配置文件”。

x86_64 构建自动选择 `console-mihomo`，使用固定 SHA-256 的官方 amd64-compatible 二进制（GPL-3.0-only）。其他架构需要对应内核。运行依赖已有的 kmod-tun、firewall4、nftables 和 ucode 模块；本次为直接 SSH 部署，未重新编译完整固件。

验证包括 `tests/console-mihomo.uc`（监听和 LAN 范围）、`tests/console-mihomo-browser.cjs`（新配置导入、切换及刷新、启停）、`tests/console-mihomo-link-browser.cjs`（链接导入与失败保留）、`tests/console-mihomo-validation-timeout.uc`（校验超时清理）以及 `tests/console-mihomo-transparent.uc`（停用时移除 DNS 接管、TUN、IPv4/IPv6 策略路由，启用时恢复两个 LAN）。2026-11-02 在内网电脑上用无显式代理的请求确认 gstatic 走 EEVPN 节点并返回 204、百度按规则 DIRECT 返回 200，IPv4/IPv6 DNS 查询均成功，OpenVPN 仍运行；桌面和手机页面无横向溢出。第二个 LAN 的规则和接口已纳入，未在该接口另接实体终端验证。

“网站连通性测试”提供 GitHub、Google、ChatGPT、YouTube 四个可点击链接，以及单站测试和全部测试。探测由路由器上的 curl 显式经过当前混合代理端口，遵守现有模式、规则及节点选择，使用 HTTPS HEAD 请求并跟随最多三次 HTTPS 重定向，单站最长 8 秒，不发送用户账号或浏览器 Cookie。结果显示最终 HTTP 状态码、首字节响应耗时（含连接和 TLS）及测试时间；HTTP 401/403/429 明确显示访问受限，超时和 TLS/连接失败不会标为可访问。入口成功不代表登录、聊天或视频播放一定可用。结果仅缓存于 /var/run，切换节点、模式或导入配置时清空。RPC 只接受四个固定站点标识并要求写权限，不支持任意目标。新增 curl 构建依赖；部署设备的 curl 及依赖由本机从 OpenWrt 官方软件仓库下载后经 SCP 安装。`tests/console-mihomo-sites.uc` 覆盖响应分类，`tests/console-mihomo-sites-browser.cjs` 验证真实四站请求、刷新保留结果、模式和节点不变以及桌面/手机布局。

## 本地预览（不需要编译）

在仓库根目录执行：

```sh
node tools/console-preview/server.cjs
```

打开 `http://127.0.0.1:8788`。预览复用生产页面、数据模型和渲染代码，RPC/文件读取替换成明确标注的示例数据。预览不是正在运行的路由器管理后台；导航到其他管理页面会说明这一点。

可设置 `CONSOLE_PREVIEW_PORT` 更改端口。预览服务仅监听本机回环地址。

## 后续纳入固件

在 Linux 构建环境准备 feeds 后，在 `make menuconfig` 中选择 `LuCI → Applications → luci-app-console`；也可把 `config/console-ui.config` 合并进目标配置，再执行 `make defconfig`。此片段只选择界面包和简体中文，不指定硬件目标。

该包通过 `feeds/luci/luci.mk` 使用标准 LuCI 安装流程，依赖包含 Web 服务、默认 Bootstrap 主题和 RPC 模块。内核/镜像构建及 ISO 安装程序属于后续阶段，本轮没有编译固件。

## 验证

```sh
node --test tests/console-dashboard.test.cjs
node tests/console-net-detail.cjs
node tests/console-net-live-render.cjs
node tests/console-browser.cjs
```

`tests/console-net-detail.cjs` 与 `tests/console-net-live-render.cjs` 不需要路由器也不需要浏览器：它们用 LuCI 运行时桩把 `net-server.js` 真实渲染一遍，前者跑合成样本（含字段全缺失的降级场景），后者跑真实设备抓取的状态 fixture。后者在设备配置变更、重新抓取 fixture 之后需要同步更新文件内的 `EXPECT` 表。

`tests/console-browser.cjs` 要求安装或配置 Playwright 的模块搜索路径，并启动预览服务。Windows 默认使用已安装的 Edge；其他环境可用 `CONSOLE_BROWSER_EXECUTABLE` 指定浏览器。

浏览器检查覆盖1440、1024、768、375宽度、默认 Bootstrap 主题共存、刷新、终端弹窗、线路和时段选择、无无线硬件、离线、RPC失败及文本注入。截图输出在被忽略的 `tmp/console-qa/`。

OpenVPN 导入另有 `tests/console-vpn-profile.uc`（路由器端 Ucode：解析、选项白名单、危险指令拦截、生成配置内容与本机网段识别）、`tests/console-vpn-import-browser.cjs` 与 `tests/fixtures/vpn-import-sample.ovpn`（浏览器端：导入区块、解析摘要、表单回填与 CA 只读）。设备端 Ucode 测试的运行方式：`ucode -L /usr/share/ucode /tmp/console-vpn-profile-test.uc`。

已在测试设备上验证 SSH 部署、16 个网络/防火墙/系统/监控页面、接口编辑弹窗和手机宽度导航；测试不保存或应用配置。当前测试设备没有检测到无线设备，首页显示相应状态而不是读取失败；固件镜像需要重新编译后才能包含后续改动。

端口映射：参见 [PORTMAP.md](PORTMAP.md)，包含爱快3.X对照、兼容边界、部署和验证说明。

## 流控分流

在侧栏新增一级菜单「流控分流」，结构与参考图一致：「分流设置」下挂多线负载、协议分流、端口分流、域名分流、上下行分离，另有「智能流控」与「终端限速」，共 7 个页面。三级页面直接展开在侧栏（`luci-theme-console` 的 `menu-console.js` 支持三层渲染），无需先点进二级才能看到。

### 为什么自研而不直接装现成插件

选型结论是**能力替代**而非硬装现成包，原因是本机（OpenWrt SNAPSHOT / kernel 6.18.55 / x86_64，仅 firewall4）的约束：

| 候选 | 不可用原因 |
| --- | --- |
| mwan3 | 依赖 `iptables` + `ipset`；本机只有 nftables，无 iptables/ipset |
| pbr | 依赖 `ip-full`、`resolveip`，域名走 dnsmasq nftset；本机 dnsmasq 编译为 `no-nftset` |
| sqm-scripts / qosify / trafficshaper | 依赖 `tc` + CAKE/HTB/`kmod-ifb`；本机无 tc 二进制，内核只内建 `CONFIG_NET_SCH_FQ_CODEL` |
| nft-qos | 只做逐 IP 简单限速，覆盖不到多线与分流，且本仓库 `.config` 未选 |
| OpenAppFilter（已装） | 源码只做 DPI 匹配，无任何限速或 packet mark，不能承担分流 |
| WanBlendr（nftables 多线） | 源码未公开、无 license，不可复用 |

因此实现方式照搬上游 nftables 方案（mwan3/pbr/mihomo 同构的 fwmark + 策略路由），并把「整形」降级为 nftables 丢包限速，同时在页面上如实标注这一边界。

### 生效机制

- 线路标签：`fwmark = 0x46460000 | (i+1)`，掩码 `0xffff00ff`；路由表 `300+i`；`ip rule prio 10400+i`。与 mihomo 占用的 `0x434d`/table 201/prio 10390 完全错开；清理时只动 `300-319` 与 `10400-10499` 区间，不做宽泛 flush。
- 独立 nft 表 `inet console_flow`，只挂 `prerouting(-150)`、`forward(-5)`、`postrouting(srcnat)`，不修改 `fw4`，也不动 `console_guard`/`console_meter`/`console_threat`。
- 多线负载按权重 + 五元组 `jhash` 铺开：`jhash ip saddr . ip daddr . meta l4proto . th dport mod <总权重> vmap { ... jump line_x }`，ICMP 等无传输层头的流量走不带端口的兜底分支。**同一连接/同一流恒定走同一条线路，UDP 也稳定**（hash 输入与 conntrack 是否存在无关），权重即区间长度。用 `ct mark` 回写保证已建立的连接不因权重变化或线路抖动而换线。
- 限速用 nftables `limit rate over ... counter drop`（丢包式），单位换算 Kbps → `bytes/second = kbps*1000/8`。
- 域名分流：因 dnsmasq 无 nftset，由后台用 `nslookup` 自行解析 A 记录写入 `interval` 集合；解析失败保留旧地址，不清空集合以避免跳线。
- 终端限速可绑定 MAC：有 MAC 时上行追加 `ether saddr`、下行追加 `ether daddr`。

### 安全与回滚

与 `SECURITY.md`、`PORTMAP.md` 同一套手法：

1. mkdir 写锁（含 owner pid/start，异常退出可自动清理）。
2. 生成文本先 `nft -c -f` 预检，失败不落盘、不生效。
3. 生效前把 config 与 nft 文本备份到 `/etc/console-backup/flow.{config,nft}.last-good` 与 `.previous`。
4. 先写 `/etc/console-flow/pending.json`（含 `boot_id` 与单调 `uptime` 截止时间，避免校时干扰）再生效，进入 **120 秒确认窗口**；未确认则自动回滚。三层兜底：延迟计时进程、procd 守护每分钟巡检、开机 `restore()` 检测残留 pending 直接回滚。
5. `apply` 失败立即 `restorePrevious()` 并清 pending，不进入确认窗口。

### 能力边界（页面已标注，不假装支持）

- **限速是丢包不是整形**：内核未编译 tc 调度模块（无 `sch_htb`/`sch_cake`/`kmod-ifb`），超速报文直接丢弃，会有重传，不做队列调度与延迟控制。终端限速与智能流控页常驻提示该限制（`caps.shaping=false`）。
- 多线负载是连接级哈希分配，不是逐包带宽比例；`failover` 模式只用第一条可用线路，掉线后由守护进程顺延。
- 域名分流只处理 IPv4 A 记录。
- 终端列表来自 DHCP 租约 + `/etc/config/dhcp` 静态保留 + `/proc/net/arp`（只认 `Flags 0x2` 为在线）+ 采集器快照；智能流控依赖该列表，采集器未运行时只覆盖有租约的设备。缺数据的字段整条省略，不填 0。

### 部署与验证

```sh
# 部署（设备无 sftp-server，用 SSH stdin 传输）
node .stage/flow-deploy.mjs --apply
/etc/init.d/rpcd restart          # ucode 模块会被 rpcd 缓存，必须重启

# 接口
ubus call console-flow state      # 只读聚合
ubus call console-flow check '{"config":{}}'   # 只校验，返回 plan.nftText / plan.warnings
ubus call console-flow apply '{"config":{...}}' # 生效并进入 120 秒确认窗口
ubus call console-flow confirm / rollback / reset
```

2026-11-09 在开发实机（192.168.1.1）完成的验证：`state`/`check` 均在 1 秒内返回；`apply` 后 `nft list tables` 出现 `inet console_flow`、`ip rule` 出现 `10400/10401`、路由表 `300/301` 有默认网关、SNAT 按线路生成；`ping`/`curl` 外网正常且 SSH 未断；`rollback` 与 `reset` 后表、rule、路由表全部清空且原有 4 张 nft 表完好；7 条校验规则（端口范围/端口格式/来源网段/线路引用/域名格式/终端 IP/MAC 格式）逐一被拒绝并给出中文原因；浏览器（headless Edge）打开 7 个页面无 console 错误、无页面异常，侧栏层级与参考图一致。

