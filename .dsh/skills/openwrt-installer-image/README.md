# 技能说明（维护者用）

这个目录是给「下次快速检测有无错误，不用重新开发」用的。它把两轮实机排障
得出的全部结论固化成了可执行检查。

## 目录结构

```
openwrt-installer-image/
├── SKILL.md                      # 主文档：约束表、流程、排障对照表
├── NIC-SPEC.md                   # 网口选择功能的接口契约（改这块先读它）
├── README.md                     # 本文件，维护者视角的背景与决策记录
└── scripts/
    ├── preflight.sh              # 环境体检（30s）
    ├── check-iso.py              # 静态体检（3s，跨平台，纯标准库）
    ├── selftest-nic.py           # check-iso 网口断言的反向自测（2s）
    ├── build-payload.sh          # 生成 bios/uefi 载荷 + 网卡驱动 bundle
    ├── build-iso.sh              # 组装混合引导 ISO
    ├── verify-e2e.sh             # 四场景真装 + 装后网络配置断言（20min）
    ├── init-installer.sh         # initramfs 的 /init（含网卡驱动加载）
    └── installer.sh              # 安装到 /usr/sbin/openwrt-install
```

## 为什么是「技能」不是「插件」

| | 技能（本方案） | 插件 |
|---|---|---|
| 形式 | 目录 + Markdown + 脚本 | 需要 npm 包 + cordis 配置 |
| 生效 | 放进 `.dsh/skills/` 即被自动发现 | 需要改 `cordis.patch.yml` 并重载 |
| 版本管理 | 就是普通文件，可直接 git 提交 | 涉及包依赖与构建 |
| 适用场景 | 操作流程 + 检查清单 + 脚本 | 需要拦截运行时行为、提供 UI |

需求是「把检查流程固化下来复用」，属于前者。插件在这里是过度设计。
将来若要把它做成 GUI 里的按钮，再考虑包成 `dsh-client-ui-*` 插件。

## 关键设计决策

**1. 静态检查必须剥掉注释再匹配。**
第一版直接对全文做正则，结果 v6 明明全对却报了 3 项 FAIL ——
因为脚本注释里写着「不要再用 root=/dev/sr0」「不要写 for x in (cd0) (hd0)」，
这些反例注释本身被当成缺陷。现在 `strip_comments()` 只保留可执行内容，
而「非 ASCII 检查」仍然看全文（因为注释里的中文确实会让 GRUB 崩）。

**2. 静态检查必须能报出「已知坏镜像」的问题。**
用 v5（同时有 MBR 全零和 root=/dev/sr0）做反向测试：它准确报出 4 项 FAIL。
v6 正向测试：全部 PASS。两个方向都过，规则才算可信。
改了检查规则后**两个方向都要重测**。

**3. 端到端不能替代静态检查。**
用户那次卡死，QEMU 四个场景全 PASS 却照样复现 —— QEMU 光驱总提供 `sr0`，
而 Ventoy 文件拷贝模式没有。所以「载荷必须内置」是静态检查里的硬性 FAIL，
不能因为端到端过了就放过。

**4. 端到端必须回读整盘比哈希。**
只看到 `Installation complete` 不够，那可能只是安装器自己打印的。
`verify-e2e.sh` 把目标盘整盘读出来，与 `raw-sha256` 逐字节比对，
才算证明写入真的正确。

**5. 网口选择：为什么不能只在安装器里加个提示。**
用户需求是「先识别网口，再手动选一个当 LAN」。看似只是加几行交互，实际是
一条完整链路，缺任何一环都等于没做：

```
rootfs 的驱动模块集  ──depmod──▶  nicbundle.tar.gz
        │                              │
        │ 按 modules.d 文件名序         │ 打进 initramfs
        ▼                              ▼
   etc/nic-load.order  ──────▶  /init 按序 modprobe  ──▶ 列出 ethN
                                                          │
                          写盘后挂载新 rootfs 改写 ◀──── 用户选 LAN/WAN/地址
                                                          │
                          只读复验（7+12 项断言）◀────────┘
```

四个必须同时成立的点，每个都对应一个会静默失效的坑：

- **rootfs 里没有 `modules.dep`**：只有 `modules.builtin`。不现跑 `depmod`
  就没有依赖图，`modprobe` 一个模块都解析不了。
- **加载顺序必须与装后一致**：`ethN` 按驱动加载顺序分配。若安装器里按字母序
  加载、装好后系统按 `etc/modules.d` 顺序加载，同一个物理口在两边的名字不同，
  用户选了 `eth1` 作 LAN，装完 `eth1` 变成 WAN，一重启就失联。
- **必须打进 `/lib/firmware`**：部分网卡 `probe` 时要固件，缺了就枚举不出来。
- **`blkid` 在 busybox 里没有**：`build-payload.sh` 里 `APPLETS` 列了也不会被
  链接（silently skipped）。所以把构建机真实的 `blkid` 连同 `libblkid.so.1`、
  `libc`、`ld-linux` 一起打进 initramfs —— 已 chroot 实测可运行。
  安装器本身还做了三级兜底（`blkid` → `findfs` → 按分区名试挂载）。

**6. 静态检查的正则必须反向自测。**
新增 14 个网口断言后，写错正则会有两种都很难察觉的坏结果：对任何镜像都 FAIL
（看着严格，实际永远通不过），或对任何镜像都 OK（等于没检查）。`selftest-nic.py`
喂「理想实现」要求全通过、再逐项破坏要求对应项报错。第一版就靠它抓出 3 个
真问题（其中一个是 `strip_comments` 把 `$#`/`${#var}` 当注释截断，导致真实代码
被漏判成缺失）。

**7. 回读口径必须随改写功能一起改。**
装完系统会改写 rootfs 里的网络配置，整盘不再逐字节等于载荷。判据改成
「rootfs 分区以外逐字节等于载荷，rootfs 由装后 12 项断言单独校验」。
这不是放水：被改的每个文件都有显式断言，且反向注入错误能准确变红。

## 本目录代码的来源

`init-installer.sh` 和 `installer.sh` 是从实际交付的 v6 镜像里提取的原文，
不是重写的。`build-iso.sh` / `build-payload.sh` 由 `build-installer3.sh`
和 `build-images6.sh` 整理而成，增加了参数化、更严格的断言和更详细的注释。

**改动这些脚本后，必须重跑**：`bash build-iso.sh` → `check-iso.py` →
`verify-e2e.sh`（至少 `usb-bios` 一个场景）。三者全过才算改对。

## 已知局限

- `check-iso.py` 只认识本项目的布局（`/boot/{vmlinuz,initrd.gz,grub/grub.cfg}`）。
  换布局要改路径常量。
- 它不验证内核能否驱动目标硬件的磁盘控制器。C3558 走 AHCI，
  实机内核里 ahci/libata/sd_mod 都是 builtin，所以没问题；
  换成需要额外驱动的平台，得加模块或改判据。
- `verify-e2e.sh` 依赖 QEMU 的 IDE/AHCI 控制器，覆盖不到真实 USB 控制器
  的枚举时机差异。所以 init 里那段「等设备集合稳定」是必需的保险，
  不能因为 QEMU 过了就删掉。
- 未覆盖 NVMe 路径（`valid_disk` 支持 `nvme*n*`，但没有对应 QEMU 场景）。
