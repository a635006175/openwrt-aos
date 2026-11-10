# x86_64 本地构建准备

## OpenVPN 组件准备

`config/console-x86_64.config` 已选择 `openvpn-openssl`、`openvpn-easy-rsa`、`luci-proto-openvpn` 和 `kmod-tun`；构建脚本会检查展开配置和固件清单。

当前测试路由器运行的内核为 `6.18.55~6989ebace8ca6b48ae315baa2f7db7d3-r1`。已从原内核构建树单独编译并安装匹配的 `kmod-tun`，并从同一构建环境编译安装 OpenVPN 2.7.7（关闭可选 DCO 加速）、`luci-proto-openvpn`、Easy-RSA 和 OpenSSL。回环测试通过 TLS、临时测试账号认证和 TUN 设备打开。VPN 菜单包含服务端、客户端和账号管理；账号密码以加盐 SHA-512 crypt 保存并由 OpenVPN 调用的认证助手校验。服务端生成本地 CA/证书、分配虚拟地址并支持分支 LAN 路由；客户端保存 CA 和 root-only 凭据并连接另一台服务端；procd 管理两端进程，独立防火墙区域管理 LAN↔VPN 转发，WAN 入站默认关闭。服务端/客户端默认停用，只有在页面提交配置后才启用。配置模型和路由器 Ucode 校验均有逻辑测试；用户要求由自己做实际异地连接验证。

相关实现位于 `package/luci-app-console/`：`vpn-service.uc` 负责后端网段检查、证书生成、OpenVPN 配置、CCD 路由、持久配置、状态读取及专属防火墙区域；`vpn-profile.uc` 解析导入的 `.ovpn` 客户端配置（只采纳校验过的选项，脚本钩子与管理接口一律忽略），并为覆盖本机直连网段的推送路由生成 `pull-filter ignore`，避免隧道把路由器自身 LAN 流量带走；`console-openvpn` 通过 procd 分别管理服务端和客户端；LuCI 的三个 VPN 页面调用受 ACL 约束的 RPC，客户端页可直接选择 `.ovpn` 文件预览解析摘要并导入连接。账号逻辑及认证测试为 `tests/console-vpn-accounts.uc`、`tests/console-vpn-auth-test.sh` 和 `tests/console-vpn-accounts-browser.cjs`；服务器端路由校验也有设备 Ucode 测试 `tests/console-vpn-service.uc`，导入解析与本机网段识别为 `tests/console-vpn-profile.uc`，导入界面为 `tests/console-vpn-import-browser.cjs`。

目标为普通 Intel/AMD 64 位电脑/软路由，包含系统概况页面、简体中文 LuCI、常见 Intel/Realtek PCI 网卡和部分 USB 网卡。具体硬件仍需实机确认。

OpenWrt 源码固定为 `29cf0022eb3f030d538ba452487c44611b106ed2`，LuCI、packages feed 也已锁定提交。配置位于 `config/console-x86_64.config`，不会修改当前 Windows 源码目录下的 `.config`。

## 当前构建与发布入口

编译环境为10.0.0.10，源码开发目录为/home/openwrt/console-sync，OpenWrt编译目录为/home/openwrt/openwrt-console-build。开发期间只同步代码，不自动重编镜像。

完整源码编译仍使用build.sh，OAF包使用build-oaf.sh。原生编译目录下的ISO/IMG是中间固件产物，不作为最终安装器交付入口。

安装器只维护带网口选择的一套实现：`.dsh/skills/openwrt-installer-image/`。打包、静态检查、四场景验证分别使用其scripts/build-iso.sh、scripts/check-iso.py、scripts/verify-e2e.sh。

最终发布路径固定为`/home/openwrt/console-sync/openwrt-console-installer.iso`，附同名SHA256和manifest。新版本验证后替换这一文件，不再保留历史安装器副本或并列版本目录。

当前公开发行版本为 AOS-20261110-V2，已重新生成 BIOS/UEFI 载荷和 ISO，替换为思源黑体，并清除设备密钥、运行历史与开发备份。安装步骤见[README-INSTALL.md](README-INSTALL.md)。

## 开发与编译同步约定

开发实机192.168.1.1当前部署代码是基准。修改完成后同时核对本地package源码、编译机console-sync/package、openwrt-console-build/package和router-build/rootfs中的对应部署代码；包括主题模板、OAF资源及基础启动脚本，不能只同步本轮改动的几个文件后声称全量一致。通过SHA256清单确认差异为0，差异覆盖前保留备份。

源码同步不自动编译镜像。同步后由router-build/development-sync-state.json标记载荷及ISO待更新；build-iso.sh拒绝使用待更新的旧载荷，正式发布前必须完整生成载荷。公开发行不得继承设备主机私钥、用户配置、运行历史或开发备份；只保留符合许可要求的公共 GeoIP、威胁情报等资源。
