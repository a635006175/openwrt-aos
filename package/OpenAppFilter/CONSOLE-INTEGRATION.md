# OpenAppFilter 行为管理集成

上游来源：<https://github.com/destan19/OpenAppFilter>，固定提交 `0814b87f57181ef238b9a21604c999e98de73cf2`（2026-10-28）。此目录保留上游许可证和源码，包含本系统的兼容与权限修改。

入口为「行为管理」：管理概览、设备管理、应用过滤、上网控制、白名单、应用记录、特征库及设置。首次生成配置时应用过滤和 MAC 过滤默认关闭；记录功能由上游默认开启。服务通过 procd 管理并自动启动。启动时必须先成功加载内核模块，不通过进程名全局终止其他服务。

2026-11-03 已使用 `/home/openwrt/openwrt-console-build` 原构建树编译，目标路由器为 OpenWrt SNAPSHOT `r0-29cf002`，内核包 `6.18.55~6989ebace8ca6b48ae315baa2f7db7d3-r1`。已在 192.168.1.1 安装 kmod-oaf、appfilter 和 luci-app-oaf，APK 经原构建签名密钥验证。完整固件镜像未重新构建。

安全修改：`fwx.common` 包含读写混合 API，不授予只读权限；Lua 写操作要求 POST、LuCI 会话令牌及 fwx UCI 写权限，jQuery 请求自动附带会话令牌。特征库订阅密钥改用独立请求字段，避免与 CSRF 令牌重名。已实测只读会话 GET 返回 200、POST 返回 403；无令牌 POST 返回 403；管理员通过受保护接口创建并删除禁用规则成功。

真实网络验证：测试机 192.168.1.5 对 GitHub 的流量经 Mihomo TUN 接管，OAF 能识别其 GitHub 特征；单设备规则启用后新建 GitHub 连接失败，控制网站仍可访问；删除规则并关闭过滤后连接恢复。单设备 MAC 上网控制也曾限时启用并验证连接被阻断、关闭后恢复。测试期间 Mihomo 服务保持运行，测试后网络、防火墙和 Mihomo 配置的 SHA-256 与安装前一致。上述测试有独立超时回滚，临时规则已删除，应用过滤与 MAC 过滤均恢复关闭。

上游引擎一次只识别一个接口，当前配置为 `br-lan`。其他 LAN 接口（例如本机的 `eth2`）与 VPN 客户端不能视为已受保护，尚未对它们进行过滤验证。识别能力取决于流量是否提供可识别特征；内置特征库当前加载 48 项（2026-11-03 已扩充为 358 项，见下）。客户端自身使用其他加密代理或 VPN 时，可能无法识别内部应用。保持流量卸载关闭；本设备测试时未启用 flowtable。

2026-11-03 特征库扩充：原内置 `feature.bin` 仅 48 项（version `26.01.01`）。已从上游免费渠道安装 id `2609101`（Lite `26.09.10`，358 项 / 12 分类 / 507 图标），实机 `/etc/fwxd/feature.bin` 由 2385 B 换为 18499 B，md5 `01602a7c86a33c2f50a3dc661971a4cf`，原库备份为 `feature.bin.bak`。经 `ubus call fwx common '{"api":"get_feature_info"}'` 确认 `app_count` 48→358、`loaded=1`，服务与内核模块正常，服务重启后仍生效。安装包 md5 与官方公布值 `3d6eade2d53c15b232433d052e07e6f6` 校验一致。源码树 `open-app-filter/files/feature.bin` 已同步，后续编译固件将自动包含。免费版无需订阅 token；付费 Plus 版需 `fwx.global.feature_token`，无 token 时接口返回 `50003`。详见 FEATURE-LIBRARY.md。

`tools/console-build/build-oaf.sh /绝对路径/原OpenWrt构建树` 验证源码提交、目标内核包版本、内核 `.vermagic` 和 `Module.symvers` 后编译插件，不会安装；为避免覆盖现有源码，构建树已有 `package/OpenAppFilter` 时停止。`config/console-x86_64.config` 及常规构建脚本已选择并同步该软件包，未来固件构建仍需实际完成并验证。
