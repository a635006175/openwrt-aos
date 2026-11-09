# 端口映射

入口：网络 → 端口映射（`admin/network/console-portmap`）。

## 对照基线与兼容范围

按用户指定的爱快 **3.X**，参考官方页面的字段顺序、列表列和批量操作：

- [官方端口映射说明](https://www.ikuai8.com/support/ymgn/lyym/wlsz/feqs.html)
- [官方列表截图](https://www.ikuai8.com/images/support/dkys111.png)
- [官方编辑表单](https://www.ikuai8.com/images/dk1.png)
- [官方常见问题](https://www.ikuai8.com/support/cjwt/jcpz/dkys.html)
- [3.X版本记录](https://www.ikuai8.com/index.php?id=331&option=com_content&view=article)

可核对的配置与生效行为：

| 项目 | 实现 |
| --- | --- |
| 字段顺序 | 内网地址、内网端口、协议、映射类型、外网地址、外网端口、允许访问IP、备注 |
| 协议 | tcp、udp、tcp+udp |
| 映射类型 | 外网接口（任意或指定WAN）、外网IP |
| 端口 | 1–65535，最多16个单端口或连续范围；多段必须保持内外网相同 |
| 单连续异号范围 | 内外网数量一致，逐端口对应，不随机分配后端端口 |
| 允许访问IP | 空表示所有来源；支持IPv4、CIDR、起止IP、命名IP分组，合并为并集 |
| 页面 | 排序、搜索、状态筛选、分页、多选、编辑、复制、批量启用/停用/删除 |
| 生效 | 保存或批量操作后立即校验、加载，失败恢复之前配置；不需要另点保存应用 |
| 回访 | NAT loopback，且同样受允许访问IP约束 |

**没有声称与所有3.X小版本完全等价**：

- 当前无指定小版本的运行实例用于逐项黑盒对照；使用本系统现有主题和模态编辑，未保证像素级一致。
- 导入导出为本页面版本化 JSON；不宣称兼容爱快私有导出/备份文件。导入为追加，展示校验数量，确认后直接生效。
- 本页面IP分组仅供端口映射使用，没有爱快全系统共享的地址对象库。
- 为避免巨大异号范围产生数万条规则，展开前预算4096个端口项，生成后最多8192个redirect，最多256条页面规则。大范围同号映射不逐端口展开。
- 对本机监听服务、其他原生转发和启用映射的端口冲突采取保守拒绝；不按来源IP拆分重叠端口规则。
- IPv4 DNAT；不包含DMZ、UPnP、繁星或NAT1，不新增这些产品的优先级链。
- **停用、删除或改指向会同时清除对应的连接跟踪**：`apply()` 在 `fw4 reload` 成功后，对"旧模型暴露但新模型不再暴露"的外网绑定逐条执行 `conntrack -D -p <proto> -d <外网地址> --dport <外网端口>`，因此已经建立的连接会立即中断，而不只是拦住新连接。清理按 `协议|外网地址|外网端口|内网地址|内网端口` 五元组比对，端口、外网地址或后端目标任一变化都算新绑定。目标地址过滤保证只影响入站映射流量，不会误删本机普通出站连接。返回值的 `flushed` 字段给出删除条数与具体绑定。
- 若系统缺少 `/usr/sbin/conntrack`，清理会记为 `skipped`，此时行为退回"只拦新连接"，旧连接可继续沿用原 NAT。
- 配置保存成功表示本路由器规则已加载，不代表上游端口映射、运营商放行或目标服务已经可用。

## 实现和恢复

`console.portmap` 用 UCI `console_portmap` 段保存模型，并生成 `cpm_*` redirect、ipset和nftables include。模型和原生redirect在同一个firewall文件提交；保留所有其他段。

单个等号范围只改地址，保留原端口。异号连续范围生成确定性的单端口redirect。每个WAN接口使用当前IPv4地址作匹配，接口hotplug在DHCP/PPPoE变更时重新生成；离线接口保留页面配置但停用对应内核redirect。

允许来源使用interval nft set。原生fw4会保留集合旧元素，故在同一nft事务末尾先flush再填充完整目标集合，确保移除来源立即影响新连接。原生reflection不沿用redirect的ipset，故通过chain-pre include在回访路径先排除不允许来源。全部规则加载在同一个nft事务中。

事务备份为 `/etc/console-backup/portmap.firewall.last-good`，pending标记同时记录旧的来源集合和回访文件。`fw4 check`还检查跳过/无效映射警告；失败恢复之前配置并重新加载。开机S18在防火墙启动前恢复未完成事务。后台操作使用进程锁、模型revision和firewall内容检查，避免覆盖过期页面或未提交的原生配置。

部署文件：

- `root/usr/share/ucode/console/portmap.uc`
- RPC `console-portmap`（state/check/apply）及专用ACL
- `view/console/portmap.js`、`console/portmap.css`
- `root/etc/hotplug.d/iface/95-console-portmap`
- `root/etc/init.d/console-portmap`、`root/etc/uci-defaults/97_console-portmap`

## 验证

- `tests/console-portmap.uc`：端口与地址校验、不同范围的对应关系、来源分组、WAN/LAN拓扑。
- `tests/console-portmap-live.uc` + `console-portmap-live.py`：源IP限定的临时规则，TCP/UDP三端口映射、回访、来源收紧、停用、删除、保护VPN1194监听。仅在空映射列表运行，finally清理。
- `tests/console-portmap-browser.cjs`：真实页面导入、校验、编辑、复制、筛选、批量启停/删除、导出、分组、多终端布局、脚本错误。
- `tests/console-portmap-recovery.uc`：未完成事务恢复，精确还原配置和两个include文件。

真实数据包测试使用工作站192.168.1.5访问本机WAN地址172.16.10.81，经NAT loopback进入内网45080–45082端口。未更改上级路由，未把测试服务暴露给任意外部来源；这不等同于从互联网完成全链路访问验证。

### 连接跟踪清理实测（2026-11-03）

针对"停用后已在跟踪的连接是否被切断"做了对照实验，结论明确：

| 场景 | conntrack 残留 | 已建立连接的表现 |
| --- | --- | --- |
| 停用映射，不清 conntrack（修复前） | 1 条 | 存活，持续收发到实验结束 |
| 停用映射，清 conntrack（修复后） | 0 条 | 立即断开（SSH 会话返回 255） |

修复前用真实长连接验证：删除 DNAT 规则后 `dstnat` 链归零，但该会话仍完整跑完 12 个心跳周期，证明 nftables 规则删除不会影响已入表连接。修复后用同样的真实会话，停用后连接在下一个数据面事件即断开。

`apply()` 返回值新增 `flushed` 字段，实测输出：

```json
{"deleted": 1, "flushed": ["tcp 192.168.1.1 2222"], "skipped": false}
```

同时确认停用后**新连接立即被阻断**（`nc` 直接返回 `Connection refused`），无需重启防火墙或等待超时。

单元测试覆盖绑定键推导：启用态生成单一绑定、停用态不产生绑定、`tcp+udp` 生成两条、端口变更/后端变更产生不同键、规则未变时键保持稳定、`type=ip` 只绑定配置的外网地址。
