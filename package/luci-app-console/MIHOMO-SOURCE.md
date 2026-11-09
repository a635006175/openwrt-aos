# Clash 内网IP代理控制

入口：VPN → Clash / Mihomo → 内网IP代理控制。

- 全部接管：LAN和已开启接管的cvpns均进入Clash。
- 仅指定IP接管：只有列表匹配的来源进入Clash，其余按原有网络路由直连。
- 指定IP不接管：列表匹配来源直连，其余进入Clash。
- 全部直连：停止这些接口的透明接管，Clash服务和手动代理入口仍可运行。

列表可以从已发现LAN地址与在线OpenVPN客户端中多选加入，也可手动填写IPv4、IPv6、CIDR和起止IP范围，最多256条。地址按来源IP匹配；IPv4和IPv6分别选择，DHCP或VPN动态地址变化后需要调整策略。cvpns还受原有“OpenVPN客户端走Clash”开关控制。

接管不等于所有目的地址强制使用代理节点：流量进入Clash后，仍遵循规则/全局/直连模式。此控制只负责透明接管；应用显式使用混合代理端口不受此列表限制。路由器本机流量、管理地址、私有地址、直连网段和多播不被透明接管。

Mihomo DNS不返回AAAA记录，配置中的代理节点服务器连接强制使用IPv4；路由器其他服务的IPv6设置不受影响。显式访问IPv6字面量时，是否可达取决于代理节点远端。

## 数据平面

Mihomo TUN继续使用cmihomo/gVisor，关闭内核自己的auto-route和auto-redirect，避免全接口规则覆盖来源策略。

独立nft表`inet console_mihomo_dns`使用interval源地址集合，在prerouting按接口和来源策略给TCP/UDP标记`0x434d`；IPv4和IPv6策略路由优先级10390、表201把这些包送入cmihomo。未选中来源不打标，使用主路由。DNS的TCP/UDP 53拦截使用同一来源过滤，未选中IP仍使用原DNS路径。

端口映射等DNAT连接的应答包跳过代理标记和DNS重定向，以便从原WAN路径返回访问者。

表201和优先级10390如被不兼容的其他功能占用，会报错而不覆盖。LAN/cvpns到TUN的转发和返回流量由现有fw4 include管理。停止Clash删除DNS/打标表和专属策略路由，启动时重建；来源列表保存于`/etc/console-mihomo/source-policy.json`并随现有keep.d目录备份。

配置修改会校验地址和revision，应用失败恢复旧策略。日常切换仅重载nft/策略路由，不重启OpenVPN或Clash。修改作用于新建连接；已有连接应重建后验证。首次迁移需重启一次Clash。

## 验证

- `tests/console-mihomo-policy.uc`：IPv4/IPv6规范化、范围和非法参数，四种策略的真实nft编译。
- `tests/console-mihomo-source-packets.py`：工作站192.168.1.5经LAN真实发包，四模式的包标记行为，以及接管后的TLS/HTTP 204。
- 真实DNS查询连接跟踪：接管来源被重定向至1053，排除来源保持53，二者均收到DNS响应。
- 浏览器验证设备列表、手动LAN/VPN地址、保存后重新加载、多屏宽度。
- 停止/启动、cvpns开关ON/OFF/ON验证；VPN进程PID保持不变。
