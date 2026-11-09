---
name: openwrt-installer-image
description: 'Use when building, repairing, or validating the OpenWrt Console installer ISO/USB image (the 192.168.1.1 embedded-router firmware image with situational-awareness and firewall databases, minus VPN keys and regional/port-map rules). Covers the four boot-stage failures that only surface on real hardware — all-zero MBR, root=/dev/sr0 under Ventoy, non-ASCII or invalid-for grub.cfg, and eMMC boot0/rpmb being offered as install targets — plus a seconds-long static check and a four-scene QEMU end-to-end verification that really writes and re-reads a disk.'
---

# OpenWrt Console 安装器镜像：构建与验证

**先说结论性约束，这几条违反一条镜像就废了：**

| 约束 | 违反后的现象 |
|---|---|
| 安装载荷必须内置在 initramfs | 卡在 `Waiting for root device /dev/sr0...`，不报错不超时 |
| 双语 grub.cfg 必须为无 BOM 的有效 UTF-8，并加载覆盖提示字形的 PF2 字库、启用 gfxterm | 编码损坏会解析失败；缺少字库或图形终端会显示问号 |
| grub.cfg 不用 `for x in (cd0) (hd0)` | 同上，整段 menuentry 被丢弃 |
| 内核必须用实机那份 | 启动约 9 秒在 `nf_defrag_ipv6_disable+0x28b` panic |
| rootfs 必须有 `/dev /proc /sys` | preinit 报 `can't create /dev/null: nonexistent directory` |
| UEFI 的 ESP 必须是 vfat | `failed to load Boot0001 ... Not Found`，掉进 EFI Shell |
| 安装器必须排除 `mmcblk*boot0/boot1/rpmb` | 选中 eMMC 保留区即变砖 |
| 网卡驱动必须打进 initramfs，且按 `nic-load.order` 顺序加载 | 安装环境列不出网口，只能退回盲选 eth0 |
| 加载顺序必须与 rootfs 的 `/etc/modules.d` 一致 | 安装器里选的 eth1 ≠ 装好后的 eth1，一重启就失联 |
| 默认入口最后一个 console= 必须是 tty0，本地显示/键盘与串口入口分开 | PVE 无串口时安装界面不可见，stdin EOF 后 shell 退出触发重启 |

## 网口手动选择（v3 新增）

装系统时会先列出真实网口，由装机人员**手动选 LAN 口 → 输 LAN 地址 → 选 WAN 口**，
选择结果在写盘后写进新 rootfs。不再固定 `eth0=LAN / eth1=WAN`。

为什么必须这样做：`ethN` 的编号取决于 PCI 槽位与驱动加载顺序，同一份镜像装到
不同机器上 eth 编号完全不同。固定写死等于装错机器就没网、失联。

细节见 `NIC-SPEC.md`（接口契约）。要点：

- 只剩一个候选口时自动作 WAN；没有候选口则 WAN 留空（整段删掉 wan/wan6）
- 剩余网口不做任何配置
- 原有 `lan2`（eth2 / 192.168.2.1）**整段删除**，firewall 里的引用一并删
- mihomo 的 `bind-address` 跟随新 LAN 地址同步改，`include-interface` 里删掉
  本机不存在的网口名
- 空回车**不**跳过，必须输入编号或 `d`（用内置默认 eth0/eth1）
- 装完会在 `/etc/console-install-ports.json` 留下本次选了哪些口，便于日后排障
- 默认第一项供本地屏幕/键盘及 PVE noVNC 使用，第二项 `(serial console)` 供串口终端使用。不要把串口强制设为默认交互控制台。
- 安装器脚本保持 PID 1 存活，交互 shell 作为子进程，退出后重新启动 shell。完成写盘、sync 和卸载后使用 `poweroff -f` / `reboot -f`。普通命令仅向 init 发信号，在此环境不会关机。BusyBox ash 优先使用内置 applet，不能用同名 PATH 脚本解决；端到端验证必须确认关机退出。

### 网口名对齐是怎么保证的（最容易做错的地方）

安装环境里 `modprobe` 的顺序决定了 `ethN` 的分配。若与装好后系统开机时的加载
顺序不同，用户看到的网口编号就和实际物理口错位。所以：

1. `build-payload.sh` 生成 `etc/nic-load.order`：按 rootfs `etc/modules.d/`
   的**文件名排序**逐文件取模块名 —— 这正是装好后 `/sbin/kmodloader` 的加载顺序
2. `/init` 严格按这个顺序 `modprobe`，自己不做任何排序
3. `modules.dep` 必须随 bundle 带上：rootfs 里原本没有这文件，要现用 `depmod` 生成

## 什么时候用

- 实机 rootfs 更新了（改 UI、加数据库、换配置）→ 重建载荷 + 重建 ISO
- 只改安装器本身（`init-installer.sh` / `installer.sh`）→ 直接重建 ISO，载荷复用
- 怀疑镜像有问题 → 先跑静态检查（秒级），再决定要不要跑端到端（20 分钟）
- 真实机器装不上 → 按「真机排障」一节的对照表定位

**不适用**：其它 OpenWrt 版本号的镜像、非 x86 目标、以及不需要 initramfs 内置载荷的场景。

## 脚本职责

都在 `scripts/` 下，全部可独立运行：

| 脚本 | 作用 | 耗时 |
|---|---|---|
| `preflight.sh` | 构建环境体检：缺包、缺 KVM、磁盘满、残留 QEMU | 30 秒 |
| `check-iso.py` | **静态体检**：编码了全部已踩过的启动级故障 + 网口链路检查 | 3 秒 |
| `selftest-nic.py` | check-iso 网口检查项的**反向自测**（防止断言写错永远通过/永远失败） | 2 秒 |
| `build-payload.sh` | 从实机快照生成 `bios.img.gz` / `uefi.img.gz` + `nicbundle.tar.gz` | 5 分钟（`--nic-only` 1 秒） |
| `build-iso.sh` | 组装混合引导 ISO（initramfs 内置载荷 + 网卡驱动） | 2 分钟 |
| `brand-rootfs.py` | 给发行 rootfs 副本写系统名/版本（可 `--check` 复核） | 1 秒 |
| `verify-e2e.sh` | 四场景真装 + 回读比对 + 装后网络配置断言 | 20 分钟 |
| `init-installer.sh` | 进 initramfs 后运行的 `/init`（含网卡驱动加载） | — |
| `installer.sh` | 安装到 `/usr/sbin/openwrt-install`（含网口选择与 rootfs 改写） | — |

## 唯一发布入口

固定发布文件为`/home/openwrt/console-sync/openwrt-console-installer.iso`，配套同名.sha256及.installer-manifest.txt。本地交付只使用`tmp/delivery\openwrt-console-installer.iso`。构建和验证的默认路径必须一致；不要再生成并列的历史版本安装器。唯一维护的脚本目录为本技能scripts/，编译机同步至`/home/openwrt/console-sync/.dsh/skills/openwrt-installer-image/`。

开发代码同步到`router-build/rootfs`后，`router-build/development-sync-state.json`标记载荷和ISO待更新。`build-iso.sh`会拒绝复用该状态下的旧载荷；完整运行`build-payload.sh`成功后才清除载荷标记，`--nic-only`不会清除。ISO成功发布后才清除ISO标记，manifest同时记录代码签名。开发同步不等于已更新现存ISO，禁止把文件名相同当成版本一致。

发行载荷在独立rootfs副本上自动运行`sanitize-rootfs.py`：清除OpenVPN全部账号/用户配置/证书密钥，Mihomo配置/订阅/控制密钥及两者的备份，清空DDNS已保存服务商实例，禁用OpenVPN和Mihomo自启动。保留GeoIP等程序数据库及威胁统计数据库，清理前后校验保留数据库哈希。禁止在开发实机直接执行该清理脚本。载荷自检及四场景装后检查必须运行`sanitize-rootfs.py --check`，首次硬盘启动再核验账号数、配置状态、进程及自启动状态。

菜单与安装提示均中英文双语。字体资源位于assets/，由`make-installer-font.py --font <NotoSansCJKsc-Regular.otf>`生成Linux控制台PSF字体，GRUB采用编译机`/usr/share/grub/unicode.pf2`原版等宽Unifont（字体名`Unifont Regular 16`），许可见assets/README.md。中文提示变更后重新生成控制台字库；check-iso.py核对Linux控制台提示的字形覆盖。无串口时`terminal_output gfxterm serial`可能失败，必须回退到单独gfxterm，不能退回不支持中文的BIOS文字控制台。交付前必须检查BIOS/UEFI菜单、安装界面的实际截图与键盘输入。

指定发行版本时，先在独立的rootfs工作副本更新`etc/openwrt_release`、`etc/os-release`和`etc/console-version`，再用该副本完整生成载荷。`build-iso.sh --version <版本号>`只设置安装器显示与清单，不能代替系统内部版本更新。候选包可设置`PUBLISH_RELEASE=0`，通过验证并替换固定发布文件后再清除ISO待更新标记。`verify-e2e.sh`可用`RELEASE_VERSION`和`EXPECTED_CODE_MANIFEST`校验安装盘内版本及每个部署文件的哈希；清单格式沿用开发同步的expected.json。

### 改系统名称（引导菜单 + 系统内部版本）

引导时看到的系统名有三处，必须同一个名字，否则装完重启就「换了名字」：

| 位置 | 由谁写 |
|---|---|
| 安装盘 GRUB 菜单 | `build-iso.sh`（读载荷记录的 `out/os-name.txt`）|
| 装好后磁盘的 GRUB 菜单 | `build-payload.sh` 生成的 `grub-bios.cfg` / `grub-uefi.cfg` |
| 装好后系统自报的版本 | `brand-rootfs.py` 写 `etc/console-version`、`etc/os-release`、`etc/openwrt_release`、`etc/banner` |

统一入口是 `build-payload.sh --os-name`（或 `OS_NAME=` 环境变量），一次写两处并落 `out/os-name.txt`，`build-iso.sh` 只核对不再各写一份：

```bash
OS_NAME=AOS-20261109-V1 bash build-payload.sh --os-name AOS-20261109-V1
bash build-iso.sh                     # 自动读载荷记录的名字，无需再传
python3 brand-rootfs.py <装好的rootfs> --name AOS-20261109-V1 --check   # 可单独复核
```

刻意**不改**的三项及理由：`DISTRIB_ID` / os-release 的 `NAME`、`ID` 保持 `OpenWrt`（apk 源、attended sysupgrade 与按发行版名分支的脚本都看它）；`etc/openwrt_version`（上游快照号，OpenAppFilter 的 dashboard.htm 拿它和 `'SNAPSHOT'` 比较）；`VERSION_ID` 保持 `snapshot`。只改面向人的显示字段。

`--os-name` **必须显式传**：不传就不动 rootfs 的版本标识（常规重建不该顺带改变系统身份），此时 `os-name.txt` 里 `branded=0`，`check-iso.py` 会据实报告「只改了菜单显示名」而不是谎称一致。`brand-rootfs.py` 会跟随 `/etc/os-release -> ../usr/lib/os-release` 符号链接写到真实文件，否则 procd（读 `/usr/lib`）与 luci dispatcher（读 `/etc`）会显示两个版本。

## 标准流程

```bash
cd <skill>/scripts
bash preflight.sh --fix                  # 环境不通就先修，别往下走
bash build-payload.sh                    # 仅当 rootfs / 内核 / 分区大小有变
bash build-iso.sh
python3 check-iso.py /path/to/out.iso    # 必须先过这一步
python3 selftest-nic.py                  # 改过 check-iso 的网口检查就跑
bash verify-e2e.sh                       # 交付前跑
```

只改安装器时跳过 `build-payload.sh`，其余照做。
只改网卡驱动集合时用 `bash build-payload.sh --nic-only`（1 秒，不动 6GiB 镜像）。

`check-iso.py` 返回非零就**不要**往下跑端到端 —— 它会准确指出问题，改完重来。

### 只想快速查一下有没有问题

大多数时候用户只是想确认「这个镜像能不能用」，不需要重建。这时候
**不要**上构建机，直接在 Windows 上跑静态检查即可（3 秒）：

```
<repo>\.dsh\skills\openwrt-installer-image\check-iso.cmd <image.iso>
```

`check-iso.cmd` 会自动找到 DSH 自带的 python，不需要装任何东西，
也不需要构建机、QEMU 或 Linux。它覆盖了全部已知的启动级故障，
是「下次快速检测有无错误」最快的路径。

只有静态检查报 PASS 但用户仍装不上时，才需要上构建机跑 `verify-e2e.sh`。

## 静态检查覆盖什么

`check-iso.py` 直接解析 ISO9660 结构、MBR/GPT、El Torito、grub.cfg 和 initramfs 内容，
不依赖外部工具，Windows / Linux 都能跑：

- MBR 的 55AA 签名、440 字节引导代码是否全零、分区表是否为空
- GPT 保护表与 `EFI PART` 头是否配套
- El Torito 校验条目，以及 BIOS(非 0xEF) 与 UEFI(0xEF) 两条链是否都在
- grub.cfg：有效 UTF-8 及 PF2 中文字库/图形终端、非法 `for` 设备列表、有无 linux/initrd、
  `root=/dev/sr*`、介质定位方式、引用路径是否真实存在
- initramfs：`/init` 可执行位、安装器程序、**载荷是否内置**、SHA256SUMS
- init 脚本：块设备稳定等待是否存在（防漏盘）、是否仍依赖 `/dev/sr*`
- 安装器：第二次确认是否为回车、是否排除 eMMC 保留区、是否检查 4Kn、是否回读校验
- **网卡驱动包**：`lib/modules/*/modules.dep` 是否存在、`etc/nic-load.order` 是否非空、
  `lib/firmware` 是否在、是否含真实 `.ko`
- **网口链路**：init 是否读 `nic-load.order` 并 `modprobe`、安装器是否列网口 /
  提示选 LAN / 要求输地址 / 可写挂载 rootfs / 有复验标志 / 处理 lan2 /
  不再硬编码 `ports 'eth0'` / 同步 mihomo `bind-address`
- 可选：`--expect-kernel-sha` 比对内核

**它只在代码里找问题，会剥掉注释。** 否则注释里写的反例（"不要再用 root=/dev/sr0"）
会被误判成缺陷 —— 实测会误报 3 项。剥离时要避开 `$#`、`${#var}` 这类 shell 语法，
否则会把真实代码后半截也切掉、把缺陷漏判成通过。

### 网口检查项必须反向自测

新增的 14 个网口断言如果正则写错，会出现两种都很难察觉的坏情况：对任何镜像
都 FAIL（看起来很严格但永远通不过），或对任何镜像都 OK（等于没检查）。

`selftest-nic.py` 就是防这个的：它喂一份「理想实现」要求全 OK，再逐项破坏要求
对应检查变 FAIL，最后验证「注释里的反例不误判、且注释不能掩盖真实缺陷」。
改过 `check-iso.py` 的网口部分就跑一次，2 秒。

## 端到端验证覆盖什么

`verify-e2e.sh` 对每个场景真装一块 `TARGET_MIB`（默认 8192）的空盘，每场景挂
**3 块 e1000 网卡**，然后：

1. 断言引导成功、列出磁盘、列出 3 个网口
2. 按真实交互发送：LAN 编号 → LAN 地址 → WAN 编号
3. 装机完成后**挂载新 rootfs 分区**，断言 12 项网络配置真的落地
   （br-lan ports / lan ipaddr / wan device / 无 lan2 / firewall 无 lan2 /
   board.json / mihomo bind-address / console-install-ports.json）

四场景：`cdrom-bios`、`cdrom-uefi`、`usb-bios`、`usb-uefi`。失败码能直接定位环节：

| 退出码 | 环节 |
|---|---|
| 3 | 引导失败（安装器界面没出现）|
| 4 | 磁盘枚举失败（没列出盘 / 没找到目标盘）|
| 5 | 安装失败（未到达完成校验）|
| 6 | 回读校验失败（rootfs 以外的数据与载荷不一致）|
| 7 | **装后网络配置校验失败**（网口/地址没写对）|
| 8 | **网口阶段失败**（安装器没能列出网口）|

单跑某几个场景：`ONLY="usb-bios usb-uefi" bash verify-e2e.sh`

**回读口径变了（v3）**：安装器写盘后会改写 rootfs 里的网络配置，所以整盘不再
逐字节等于载荷。现在的判据是「**rootfs 分区以外逐字节等于载荷**，rootfs 由装后
断言单独校验」。这不是放水 —— 被改动的那几个文件全部有显式断言。

**QEMU 通过不代表真机能装。** 用户那次卡死，QEMU 四个场景全 PASS 却照样复现 ——
因为 QEMU 光驱总是提供 `sr0`，而 Ventoy 文件拷贝模式没有。所以静态检查里
「载荷必须内置」这一条是硬性要求，不能靠端到端放行。

四场景串口驱动会在 GRUB 主动选择第二项 `(serial console)`。交付前还必须独立补测默认图形入口：QEMU 明确指定 `-serial none`，模拟 PVE SeaBIOS/i440fx、SATA 光驱、E1000+VirtIO，确认安装界面可见、键盘可输入、退出 shell 不会重启。不能仅凭串口输出判断 PVE noVNC 正常。20261107 的修复证据位于 `/home/openwrt/verify-evidence/pve-20261107/`。

**磁盘空间**：四场景串行各需约 8GB target + 6GB 介质。并发跑会爆盘，且
`build-iso.sh` 会对 `$WORK` 做 `rm -rf`，多人同时构建会互相删掉中间产物
（表现为莫名的「initramfs 缺关键 applet」）。**每次构建用独立 `WORK`。**

## 真机排障对照表

拿到用户屏幕内容，先看有没有 `Whole disks detected:`：

| 现象 | 原因 | 处置 |
|---|---|---|
| 停在 `Waiting for root device /dev/sr0` | 载荷没内置，靠光盘做根 | 重建，载荷进 initramfs |
| SEA BIOS `Boot failed: not a bootable disk` | MBR 全零 | 用 grub-mkrescue 重出；写盘用 Rufus DD 模式 |
| grub 菜单能显示，一引导报 `you need to load the kernel first` | grub.cfg 编码损坏或非法 for | 跑 `check-iso.py` |
| 掉进 `EFI Internal Shell` / PXE | ESP 不是 FAT | `build-payload.sh` 用 vfat |
| 启动约 9 秒 kernel panic | 内核与 rootfs 不配套 | 用实机内核，比对 sha |
| `can't create /dev/null` | rootfs 缺 `/dev` | 补目录和静态设备节点 |
| 磁盘列表里没有目标盘 | 枚举未稳定就列盘 | init 等设备集合稳定；并让用户贴 `Whole disks detected:` |
| 列表里有 `mmcblk0boot0` | 安装器没排除 eMMC 保留区 | 立即停止，补排除逻辑 |
| `Network interfaces detected: (none)` | 网卡驱动没加载 | 查 `lib/modules/$(uname -r)/modules.dep` 是否在 initramfs 里；驱动不在 bundle 里就加进 `NIC_SEEDS` |
| 装了系统但选中的口没网 | ethN 顺序与装后不一致 | 查 `etc/nic-load.order` 是否按 rootfs `etc/modules.d` 文件名序生成 |
| `Applying network configuration` 之后报错 | 找不到 rootfs 分区或没挂上 | 看 `console-install-ports.json` 是否生成；分区 LABEL 是否仍是 `rootfs` |
| 装完 mihomo 不通 | `bind-address` 没跟着 LAN 地址改 | 查 `/etc/console-mihomo/config.json` 的 `bind-address` |

用户语言是中文时用中文回复，如实说哪一步过了、哪一步没过。

## 清理构建文件时不要删掉什么

跑 `verify-e2e.sh` 之后工作目录里会有大量中间镜像，很容易手滑连证据一起删。
**删之前先分清三类**：

| 类别 | 例子 | 能不能删 |
|---|---|---|
| 可重建的产物 | `tmpwork` / `imgwork` / `modchk` / `tv*` / 旧版 ISO / `out-backup` | 能，删了跑一次脚本就回来 |
| 重建链路的**输入** | `router-build/{rootfs,bootsrc,out}`、`keepbin` | **绝对不能删**，删了得从实机重新抓 rootfs 和内核 |
| 验证**证据** | 各场景 `console.log`、`summary.txt` | 按需保留，删了就只剩一句「跑过」 |

实际踩过的坑：清理时把整个 `e2efinal/` 一起删了，导致四场景的串口日志全部丢失，
只剩汇总输出。**要删 e2e 目录时，先把各场景的 `console.log` 捞出来单独存**
（放到 `verify-evidence/` 之类），再删大镜像。

清理前一定要 `du -sh` 看一眼每个目录，并且**先确认它不在重建链路里**。
判断方法：`build-payload.sh` 的输入是 `rootfs`+`bootsrc`，`build-iso.sh` 的输入是
`out/`，这两组之外的中间目录都可以安全删除。

另外注意：清理时若遇到 `Read-only file system` 报错，说明目录里还有**遗留的
loop 挂载**（以前 `mount` 过没 umount）。先 `mount | grep <目录>` 找到，
`umount` 之后再删，否则删不干净还会占着空间。

## 需要向用户确认的

- 分区大小（当前根分区 6 GiB，`--root-mib` 可改）
- 移除范围（已获用户授权：OpenVPN全部账号/配置/证书密钥、Mihomo配置/订阅/密钥及相关备份、DDNS已保存服务商配置；两服务默认关闭。既有地区规则guard.nft和端口映射清理策略继续沿用，其余数据库保留）
- 目标盘设备名（eMMC 还是 SSD，决定第一次确认输入什么路径）
- **网口方案**：LAN 用哪个物理口、LAN 网段地址、WAN 用哪个口
  （装机会现场交互选择，但批量部署前应先明确）

不要自己扩大或缩小移除范围 —— 私钥必须移除，数据库必须保留。

## 环境事实

构建机 `10.0.0.10`（root，Ubuntu，`/dev/kvm` 可用）。实机 `192.168.1.1`
（OpenWrt SNAPSHOT，内核 6.18.55）。两者不同网段、无路由，数据要经 Windows 中转。

实机内核 sha256：`fd30ff912bb85231593f5bed5b34ed06bd4daf1793089437b02b7d5c6be007b2`
（6,964,224 字节）。上游镜像那个是 6,960,128 字节，**不兼容**。

已知路径：`/home/openwrt/router-build/{rootfs,bootsrc,out}`、
`/home/openwrt/keepbin`（上游官方镜像）、`/home/openwrt/console-sync`（输出 ISO）。
