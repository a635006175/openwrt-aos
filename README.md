# openwrt-aos

基于 OpenWrt 的自定义软路由系统（**AOS**）。本仓库包含完整的 OpenWrt 源码树，以及在其上开发的控制台
（LuCI 主题 + 应用）、安装器和构建脚本，`git clone` 后可直接编译。

- 上游基线：`openwrt/openwrt` @ `29cf0022eb3f030d538ba452487c44611b106ed2`
- 目标平台：`x86/64`（`x86_64/DEVICE_generic`），内核 6.18.55
- 当前系统版本标识：`AOS-20261110-V2`
- 许可：OpenWrt 自身及各 package 沿用其原有许可（见各子目录 LICENSE）；本项目新增代码为 Apache-2.0

---

## 一、这套系统做了什么

上游 OpenWrt 是通用固件，本仓库在此之上补了一个面向家庭/小型办公软路由的完整控制台：

| 模块 | 位置 | 说明 |
|---|---|---|
| 控制台主题 | `package/luci-theme-console/` | 独立的 LuCI 主题，中文界面、自定义导航与版式，含系统字体子集 |
| 控制台应用 | `package/luci-app-console/` | 系统概况、网络接口、DHCP、端口映射、DDNS、VPN（服务端/客户端/账号）、态势感知、流控分流、终端限速 |
| 安装器 | `.dsh/skills/openwrt-installer-image/` | 独立安装盘：图形+串口双启动项、网口选择（LAN/WAN）、BIOS+UEFI 双引导、装后自动配置 |
| 构建脚本 | `tools/console-build/` | 固定上游 revision 的编译脚本，含 OAF 单独编译脚本 |
| 页面预览 | `tools/console-preview/` | 不依赖路由器，用示例数据本地渲染控制台页面 |
| 测试 | `tests/` | ucode 单元/集成测试、无头浏览器页面测试、真机与 OpenVPN 环回测试 |

### 控制台里的功能菜单

- **系统概况**：接口悬停详情、实时速率、在线终端、运行时长
- **网络**：接口配置（静态/PPPoE/DHCP）、DHCP 服务与静态租约、多 WAN
- **流控分流**：多线负载、协议分流、端口分流、域名分流、上下行分离、智能流控、终端限速
- **端口映射**、**DDNS**
- **VPN**：OpenVPN 服务端、客户端（支持 `.ovpn` 导入）、账号管理（加盐哈希保存）
- **态势感知**：连接与拦截统计、地区规则（db-ip 国家库）、威胁情报阻断（URLhaus / DShield / Spamhaus / Feodo）
- **行为管理**：集成 OpenAppFilter（OAF）

### 安装器

标准 OpenWrt 镜像直接 `dd` 到盘时不会询问网口和 LAN 地址，装完经常起不来。本仓库的安装器把
`/init` 换成带交互的安装界面：

1. 列出所有网口（含驱动、PCI 地址、链路状态），要求**必须手动选择** LAN 口与 WAN 口
2. 要求输入 LAN IPv4/前缀（默认 `192.168.1.1/24`，空回车不跳过）
3. 选择安装目标盘（自动排除 eMMC `boot0`/`rpmb`、光驱、安装介质本身）
4. 写入后按选择结果生成 `/etc/config/network`、`/etc/installer-nic.json`

构建产物为单一 `openwrt-console-installer.iso`：BIOS（MBR + El Torito）与 UEFI 双启动，
引导菜单为中文+英文双语，可直接刻盘、写 U 盘或挂到 PVE/ESXi。

---

## 二、目录结构（只看本项目新增部分）

```
package/
  luci-app-console/        # 控制台主应用（ucode 后端 + LuCI JS 前端）
  luci-theme-console/      # 控制台主题
  console-mihomo/          # mihomo 二进制包封装
  OpenAppFilter/           # 第三方行为管理（见第四节）
config/
  console-feeds.conf       # 锁定的 feeds 提交
  console-x86_64.config    # x86_64 编译配置
  console-ui.config        # UI 包选择片段
tools/
  console-build/           # 编译脚本
  console-preview/         # 页面预览与抓包小工具
tests/                     # 测试用例
.dsh/skills/
  openwrt-installer-image/ # 安装器源码、字体资源、静态检查与四场景验证脚本
docs/reports/              # 开发过程中的设计、审计与验证报告
```

其余目录（`target/`、`toolchain/`、`tools/`、`include/`、`scripts/` …）是上游 OpenWrt 原样内容。

---

## 三、编译

### 3.1 环境

Linux（Ubuntu 22.04 及以上验证过），磁盘 ≥ 40 GB，
已安装 `git make gcc g++ gawk rsync sha256sum xorriso mkfs.fat mcopy`。

### 3.2 一键编译

```sh
git clone https://github.com/a635006175/openwrt-aos.git
cd openwrt-aos
./tools/console-build/build.sh
```

脚本会：克隆一份独立构建树到 `$HOME/openwrt-console-build`、检出固定的上游 revision、
同步本仓库的自定义 package、展开 feeds、套用 `config/console-x86_64.config`、
`make defconfig` 后逐项断言关键配置确实生效，最后完整编译并生成
`bin/targets/x86/64/` 下的 ISO 与磁盘镜像。

可调：

```sh
OPENWRT_BUILD_DIR=/data/build OPENWRT_BUILD_JOBS=8 ./tools/console-build/build.sh
```

编译完成后，`bin/targets/x86/64/` 里的是**中间固件**。要交付带网口选择的安装盘，另用安装器脚本
（需要先准备好该目录产物）：

```sh
.dsh/skills/openwrt-installer-image/scripts/build-payload.sh   # 生成 bios/uefi 载荷
.dsh/skills/openwrt-installer-image/scripts/build-iso.sh       # 组装混合引导 ISO
.dsh/skills/openwrt-installer-image/scripts/check-iso.py <iso> # 秒级静态检查
```

改系统名称（引导菜单 + 系统内部版本标识）：

```sh
build-payload.sh --os-name AOS-20261109-V1 ...
```

不传 `--os-name` 则保持 OpenWrt 原始标识，不会静默改写 `etc/os-release`。

### 3.3 只编译 OAF

```sh
./tools/console-build/build-oaf.sh /absolute/path/to/openwrt-build
```

会先校验目标构建树的内核 ABI 与本项目一致，再编译 `oaf` / `open-app-filter` / `luci-app-oaf`。

### 3.4 编译前自检

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
```

`config/console-feeds.conf` 里的两个 feed 提交是锁定的，改动需同步更新该文件。

---

## 四、关于 package/OpenAppFilter

该目录是第三方项目 [destan19/OpenAppFilter](https://github.com/destan19/OpenAppFilter)
（**GPL-2.0**，见 `package/OpenAppFilter/LICENSE`），不是本项目原创。

保留在此处的原因是需要与自带控制台联动，本仓库对它做了以下修改（其余保持上游原样）：

- `luci-app-oaf/htdocs/luci-static/resources/oaf/console-security.js`（新增，控制台态势感知联动）
- `luci-app-oaf/luasrc/` 下的菜单与 dashboard 适配（见 `CONSOLE-INTEGRATION.md`、`FEATURE-LIBRARY.md`）
- 图标资源与自定义协议库

按 GPL-2.0 要求，修改后的源码随本仓库一并提供。若只需纯自研部分，删除 `package/OpenAppFilter/`
并从 `config/console-x86_64.config` 去掉 `CONFIG_PACKAGE_luci-app-oaf` 即可。

---

## 五、数据与隐私

本仓库**不包含**任何真实设备凭据或个人数据：

- 所有真实 MAC 地址、公网 IP、WAN 网段、IPv6 前缀、内网网段、SSH 账号、构建机地址
  已统一替换为文档保留段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）与
  示例 MAC（`aa:bb:cc:dd:ee:xx`）
- `sanitize-rootfs.py` 会在打载荷时移除 `/root` 下的 VPN 密钥、订阅缓存、DDNS 凭据等用户数据
- 仓库内不含任何私钥、证书、订阅链接或 API Token

`tests/fixtures/` 里的样本是**脱敏后的结构快照**，用于验证页面渲染，不含真实设备信息。

---

## 六、测试

```sh
# ucode 单元/集成测试（需在路由器或具备 ucode 的环境运行）
ucode tests/console-flow-*.uc

# 无头浏览器页面测试（Playwright；默认连 http://192.168.1.1）
node tests/console-live.cjs
```

`tests/` 里多数 `*-browser.cjs` / `*-live.*` 需要一台运行本系统的实机，
`*.test.cjs` 与多数 `.uc` 用例可离线运行。

---

## 七、许可

- OpenWrt 本体及其官方 package：见各目录内 LICENSE，主要为 GPL-2.0
- `package/OpenAppFilter/`：GPL-2.0（第三方，见上）
- 本项目新增的主题、应用、安装器与构建脚本：Apache-2.0；`console-mihomo` 封装为 GPL-3.0-only，各组件以其声明为准
- `luci-theme-console` 内的思源黑体（SIL OFL 1.1）、安装器字体：各自的字体许可，
  见 `package/luci-theme-console/htdocs/luci-static/console/fonts/` 与
  `.dsh/skills/openwrt-installer-image/assets/*-LICENSE.txt`
