# OpenVPN 双内网互通改动说明

> 交给编译机对话使用。本文件描述 `luci-app-console` 中 OpenVPN 服务端的一处功能缺陷修复。

## 零、如何在编译机上应用

交付目录内文件：

| 文件 | 用途 |
|---|---|
| `01-vpn-service-peer-route.patch` | 标准 unified diff，`-p1` 可用 |
| `02-vpn-service.uc.ORIGINAL` | 改动前的原始文件（校验用） |
| `03-vpn-service.uc.PATCHED` | 改动后的完整文件（可直接覆盖） |
| `README-改动说明.md` | 本说明 |

**目标路径（相对仓库根目录）：**

```
package/luci-app-console/root/usr/share/ucode/console/vpn-service.uc
```

**方式 A：打补丁（推荐）**

```sh
cd <openwrt 仓库根目录>
patch -p1 < 01-vpn-service-peer-route.patch
```

**方式 B：直接覆盖**

```sh
cp 03-vpn-service.uc.PATCHED \
   package/luci-app-console/root/usr/share/ucode/console/vpn-service.uc
```

**应用后自检：**

```sh
# 应输出 ddb3cc1767090e1bfcc48c90fb78edd8
md5sum package/luci-app-console/root/usr/share/ucode/console/vpn-service.uc

# 应能匹配到 4 处新增内容
grep -c 'tunnelRoutes\|console_vpn_server_to_client\|console_vpn_server_tunnel_nat' \
     package/luci-app-console/root/usr/share/ucode/console/vpn-service.uc
```

> 补丁已做严格验证：以原始文件为基准应用 4 个 hunk 后，
> 与实机已验证版本**逐字节完全一致**（MD5 一致）。

## 一、问题现象

网络拓扑：

```
B 设备 ──OpenVPN(tcp/1194)──> 192.168.1.1 (OpenWrt) ──OpenVPN客户端(udp/1196, cvpnc)──> C 服务端内网
                                    │
                                    └── LAN 192.168.1.0/24, 192.168.2.0/24
```

- **192 本机能正常访问 C 的内网**（`10.10.10.0/24`、`10.7.0.0/16`、`192.168.33.0/24`）
- **B 设备连上 192 的 OpenVPN 服务端后**：
  - 可以访问 192 的内网 ✅
  - 无法访问 C 的内网 ❌

需求：B 连上 192 的服务端时，**同时**能访问 192 的内网和 C 的内网。

## 二、根因（三点，均已实测确认）

### 1. 防火墙缺少 `VPN服务端区 → VPN客户端区` 的 forwarding

`cvpns`（B 的入口）和 `cvpnc`（去 C 的出口）是两个独立 firewall zone。
`forward` 链默认策略是 `drop`，两者之间原本没有 forwarding，
所以 B 发往 C 内网的包在这里被丢弃。

### 2. 缺少 SNAT，回包无法返回（最隐蔽的一点）

C 只认识本机 `cvpnc` 的地址（`10.7.7.x`），**不认识** VPN 地址池 `10.8.0.0/24`。

实机验证：

```
ping -I 10.8.0.1 -c1 10.0.0.10   ->  NO-REPLY     # 用 VPN 池地址作源
ping -I 10.7.7.4 -c1 10.0.0.10   ->  REPLY-OK     # 用 cvpnc 地址作源
```

即：即使包能出去，C 的回包也找不到 `10.8.0.x` 的返回路由。
临时加 masquerade 规则后立刻变为 `REPLY-OK`，确认这是关键因素。

### 3. 服务端没有把 C 的网段推送给客户端

原 `server.conf` 只推送了 `192.168.1.0/24` 和 `192.168.2.0/24`。
B 上没有到 C 内网的路由，包被送到 B 自己的默认网关，根本没进隧道。

## 三、改动内容

**唯一修改的文件：**

```
package/luci-app-console/root/usr/share/ucode/console/vpn-service.uc
```

### 改动 1 — 新增对端网段自动探测

在 `localSubnets()` 之后新增 `tunnelRoutes()` / `peerRouteCache()` / `saveTunnelRoutes()`：

- 从 `ip -4 route` 中提取 `dev cvpnc` 的路由作为「对端内网」
- **排除** `proto kernel` 条目（那是 cvpnc 自身的地址段 `10.7.7.0/24`，不是对端内网）
- 结果持久化到 `/etc/console-vpn/peer-routes.json`
- 链路恰好断开时路由会消失，此时回退到缓存，避免把已下发的对端路由清空

> 注意：ucode **不会提升模块级函数声明**。这段代码只能依赖文件顶部已导入的
> `fs` 接口，不能调用文件后面才定义的 `readJson` / `writeAtomic`，
> 否则运行时报 `undeclared variable`。

### 改动 2 — `serverConfig()` 推送对端网段

在推送完 LAN 网段后追加对端网段，并做三项去重保护：
跳过与 `vpnSubnet` 重叠、与 `v.lans` 重叠、与 `v.peers` 重叠的条目。

### 改动 3 — `updateFirewall()` 增加 forwarding + masquerade

新增两个 uci section（仅在服务端启用 **且** 本机客户端也启用时创建）：

| section | 类型 | 内容 |
|---|---|---|
| `console_vpn_server_to_client` | `forwarding` | `src=console_vpn_server` `dest=console_vpn_client` |
| `console_vpn_server_tunnel_nat` | `nat` | `src=console_vpn_client` `src_ip=<vpnSubnet>` `family=ipv4` `target=masquerade` |

masquerade 实际生成到 `oifname "cvpnc"` 的 srcnat 链，
因此**只影响经 cvpnc 隧道出去的流量**。

同时把这两个 section 名加入 `forwards` / `nats` 数组，
保证禁用服务端时能一并清理干净。

## 四、关于 clash / mihomo 流量（重要，不可回归）

该设备同时运行 mihomo（clash）透明代理。本次改动**不触碰** VPN→clash 的流向：

1. mihomo 的 `source_route` 链（prerouting/mangle）对 `10.0.0.0/8`、`192.168.0.0/16`
   直接 `return`，C 的内网永远不会被 mihomo 打标劫持。
2. 新增的 masquerade 规则挂在 `oifname "cvpnc"`，`srcnat` 链中 `cmihomo` 出现次数为 **0**。
3. 实测计数器持续增长（观察 12s：LAN→TUN 6495→7524 包，TUN reply 7729→8942 包）。

**回归测试必须确认 clash 转发链计数器仍在增长。**

## 五、部署后的期望状态

`/etc/console-vpn/server.conf` 应包含：

```
push "route 192.168.1.0 255.255.255.0"
push "route 192.168.2.0 255.255.255.0"
push "route 10.7.0.0 255.255.0.0"        # 新增（自动探测）
push "route 10.10.10.0 255.255.255.0"    # 新增（自动探测）
push "route 192.168.33.0 255.255.255.0"  # 新增（自动探测）
```

`uci show firewall` 应包含上文表格中的两个 section，且 nft 中可见：

```
chain forward_console_vpn_server {
    ...
    jump accept_to_console_vpn_client   # 新增
}

chain srcnat_console_vpn_client {
    ip saddr 10.8.0.0/24 masquerade     # 新增
}
```

## 六、实测验证结果（已完成）

实机接入设备 `testuser`（VPN 地址 `10.8.0.2`）的 conntrack 记录：

```
出向: src=10.8.0.2    dst=10.10.10.253:80
回向: src=10.10.10.253 dst=10.7.7.6      # 回包回到 cvpnc 地址，证明 NAT 生效
```

VPN→C 内网 15 条连接、VPN→LAN 7 条连接 **同时存在**，两侧均可访问。

## 七、附带说明

- 修改仅涉及一个 `.uc` 脚本，不新增/删除文件，无 Makefile 或依赖变化。
- 源码已同步到实机 `/usr/share/ucode/console/vpn-service.uc`，
  MD5：`ddb3cc1767090e1bfcc48c90fb78edd8`
- 原始文件 MD5：`adf442fcb69823eb3ba9d14aee4ede24`
- 实机备份：`/root/vpn-fix-backup-20261105-102109/`
