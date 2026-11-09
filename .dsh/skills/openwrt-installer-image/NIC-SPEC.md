# 网口手动选择 —— 实现契约（NIC-SPEC）

本文件是 `openwrt-installer-image` 技能本次改动的**唯一接口约定**。
所有脚本（build-payload.sh / build-iso.sh / init-installer.sh / installer.sh /
check-iso.py / verify-e2e.sh）都以本文件为准，不得各自发明字段名或提示语。

改动目标：安装时先识别网口，再由用户手动选择 LAN 口（可再选 WAN 口），
并把选择结果写进**刚刚写入磁盘的 rootfs**；不再依赖镜像里硬编码的 eth0/eth1。

---

## 0. 已确认的产品决策（用户拍板）

| 决策 | 结论 |
|---|---|
| 选择范围 | 列全部网口；先选 LAN，再选 WAN |
| 只剩 1 个候选 WAN 口 | 不提问，直接用它作 WAN |
| 剩余网口 | 不做任何操作（保持未配置） |
| 现有 `lan2`（eth2 / 192.168.2.1） | **完全删除** |
| mihomo `bind-address` | **跟随新的 LAN 地址同步修改** |
| LAN 地址格式 | 接受 `A.B.C.D` 或 `A.B.C.D/前缀`，省略前缀按 `/24` |
| 快速跳过 | 保留「内置默认」，但必须显式选（空回车**不**跳过） |

---

## 1. 载荷目录新增产物（build-payload.sh 生成）

全部写进 `$OUT`（默认 `/home/openwrt/router-build/out`），与 `bios.img.gz` 同级：

### 1.1 `nicbundle.tar.gz`

gzip 后的 tar，解压到 initramfs 的 `/` 后形成：

```
lib/modules/6.18.55/<选中的 *.ko>          # 见 1.2 的筛选规则
lib/modules/6.18.55/modules.dep            # depmod 生成（rootfs 里原本没有）
lib/modules/6.18.55/modules.alias          # depmod 生成
lib/firmware/**                            # 整个 rootfs/lib/firmware 原样
etc/nic-load.order                         # 见 1.3
etc/nic-allowlist                          # 见 1.2，逗号分隔，供 /init 兜底
```

- tar 成员必须是相对路径且无 `./` 前缀歧义；解压用 `tar -xzf -C /`。
- 体积目标：**≤ 8 MiB**（原始约 17 MiB，gzip 后应在 5～7 MiB）。
- 必须用 `mke2fs` 之外的方式保证可重复：打包前 `depmod` 的输出目录要清空重建。

### 1.2 选哪些 .ko

只挑**网络相关**模块（含其依赖）。允许集合 = 下列名字（去掉 `.ko`）加依赖闭包：

```
igb igc ixgbe e1000 e1000e tg3 bnx2 bnx2x forcedeth r8169 realtek atlantic
amd-xgbe stmmac stmmac-platform dwmac-generic dwmac-intel dwmac-sti
ena vmxnet3 usbnet asix ax88179_178a ax88796b r8152 rtl8152
mii libphy mdio mdio-bus mdio_devres pcs_xpcs phylink
libie_fwlog
```

- 依赖闭包用 `depmod` 生成的 `modules.dep` 展开（`libie_fwlog` 是 ixgbe 的依赖）。
- 允许集合里**在 rootfs 中不存在的模块直接跳过**，不报错。
- 允许集合写入 `etc/nic-allowlist`（逗号分隔、单行、无空格），供 `/init` 兜底 `modprobe`。
- **不含** `selftests.ko` / `i915.ko` / `drm*.ko` / `nf_*.ko` 等无关模块。

### 1.3 `etc/nic-load.order`

**这是保证「安装器看到的 ethN」与「装完系统里的 ethN」一致的关键。**
内容为模块名，每行一个，顺序 = rootfs 的 `/etc/modules.d/` 按文件名排序后，
逐文件取每行第一个 token，过滤掉：

- 不在 1.2 允许集合里的；
- 对应 `.ko` 不在 bundle 里的；
- 重复项（保留首次出现）。

例：`19-tg3` → `tg3`；`34-igc` → `igc`；`35-igb` → `igb`；
`40-stmmac-core` 内容为 `dwmac-generic stmmac stmmac-platform` → 三行。

### 1.4 其余元数据

沿用现有 `*.img.gz` / `*.img.bytes` / `*.img.raw-sha256`，**不改动**。

---

## 2. initramfs 改动（build-iso.sh）

1. 把 `$BODY/nicbundle.tar.gz` 解压进 `$IR`（即 initramfs 根）。
2. `$IR/installer/` 与 `$IR/init`、`$IR/usr/sbin/openwrt-install` 的既有布局**不变**。
3. 必须新增 `tar` 到 applet 列表（`modprobe`、`blockdev`、`mount`、`umount`、
   `losetup`、`od`、`awk`、`sed`、`tr`、`cut`、`sleep`、`mkdir`、`sync` 已在或需确认）。
4. 打包后自校验（缺一即 `die`）：

   - `$IR/lib/modules/$KVER/modules.dep` 存在且非空
   - `$IR/etc/nic-load.order` 存在且行数 ≥ 1
   - `$IR/lib/firmware` 存在
   - 回读 initramfs（解 cpio）后上述文件仍在
   - initramfs 体积上限从 400 MiB 放宽判断仍成立（目前约 158 MiB，加 ~7 MiB 无风险），
     但**下限检查保持 100 MB** 不变

5. `--check-only` 也必须校验 `$BODY/nicbundle.tar.gz` 存在。

---

## 3. `/init` 改动（init-installer.sh）

在既有「块设备稳定等待」之后、执行 `openwrt-install` 之前，插入网卡阶段：

```
1) 若 /etc/nic-load.order 存在：
     while read -r m; do modprobe "$m" 2>/dev/null || true; done < /etc/nic-load.order
2) 兜底：对 /etc/nic-allowlist 里的每个名字再 modprobe 一次（已加载则 no-op）
3) 等待网口集合稳定：/sys/class/net 下非 lo 的接口连续 4 次（间隔 0.5s）不变，
   上限 15 秒
4) 打印：
     Network interfaces detected:
       eth0  aa:bb:cc:dd:ee:ff  link=up    driver=igb   pci=0000:01:00.0
     （无网口时打印：  (none)）
5) export NIC_COUNT=<数量>；export NIC_BUNDLE=1
```

约束：

- **任何一步失败都不得中断安装**（`|| true`）。装不上网卡驱动只是少一个选项，
  不能让用户装不了系统。
- 不得改动既有 `Whole disks detected:` 段落与 `PAYLOAD_DIR` 逻辑。
- 保持 `sh -n` 通过（busybox ash 语法）。

---

## 4. `openwrt-install` 交互（installer.sh）

### 4.1 顺序（严格）

```
a. 列磁盘（现有格式不变）
b. 提示 Enter the full target disk path ...（现有字符串不变）
c. 【新】网口阶段：
     c1. 列网口（格式见 4.2）
     c2. 选 LAN
     c3. 输入 LAN 地址
     c4. 选 WAN（仅当候选 ≥2 时提问；==1 自动；==0 跳过）
d. 打印配置摘要（见 4.4）
e. 载荷校验（现有）
f. WARNING + Press Enter to erase ...（现有字符串不变）
g. 写盘 + 回读校验（现有）
h. 【新】挂载新 rootfs 分区 → 应用配置 → 只读复验 → 卸载
i. 完成信息（现有 + 新的管理地址）
```

**网口阶段必须排在写盘之前**，让用户能在破坏性操作前看到完整摘要并反悔。

### 4.2 网口列表格式（逐字节，供 check-iso 与 e2e 解析）

无网口时：

```
Network interfaces detected: (none) — network configuration is left at the built-in default.
```

有网口时（先一行标题，再每个网口一行，编号从 1 开始，序号用 **2 空格缩进 + `[n]`**）：

```
Network interfaces detected:
  [1] eth0  aa:bb:cc:dd:ee:ff  link=up    driver=igb   pci=0000:01:00.0
  [2] eth1  aa:bb:cc:dd:ee:00  link=down  driver=igb   pci=0000:01:00.1
```

列宽固定：网口名左对齐 6 → MAC 17 字符 → `link=` 后 7 → `driver=` 后 12 → `pci=`。
未知驱动/PCI 时分别写 `driver=?` / `pci=?`。`link` 取值只能是 `up` / `down`。

### 4.3 提问（逐字节）

选 LAN：

```
Select the LAN port by number (or "d" for the built-in default eth0=LAN / eth1=WAN):
```
（行尾无空格；空回车 → 重问，并在重问前打印一行
`A choice is required; press "d" to accept the built-in default.`）

输入地址：

```
Enter the LAN address as IPv4 or IPv4/prefix, Enter for 192.168.1.1/24:
```

选 WAN（≥2 候选时）：

```
Select the WAN port by number, or "n" to leave WAN unconfigured:
```

自动 WAN（恰好 1 个候选）打印一行：

```
Only one spare port is left: eth2 will be the WAN port.
```

无候选打印：

```
No spare port for WAN; WAN will be left unconfigured.
```

选 `d` 默认时打印：

```
Using the built-in default: LAN eth0, WAN eth1, LAN address 192.168.1.1/24.
```
（默认路径下**不再**追问地址与 WAN；若 eth0/eth1 实际不存在，则退化为「按现有规则能配的
就配，配不了的对应角色留空」并打印一行说明。）

### 4.4 摘要（写在 `Press Enter to erase` 之前，格式固定）

```
Network plan:
  LAN port    : eth0  aa:bb:cc:dd:ee:ff  (igb, pci=0000:01:00.0)
  LAN address : 192.168.1.1/24
  WAN port    : eth1  aa:bb:cc:dd:ee:00  (igb, pci=0000:01:00.1)
```
无 WAN 时该行为 `  WAN port    : (none)`。

### 4.5 地址校验规则

- 必须是 `A.B.C.D` 或 `A.B.C.D/N`，四段十进制 0–255、无前导零（`01` 非法）。
- `N` 取值 8–32（更小的前缀没有实际意义，拒绝）。
- 拒绝 `0.0.0.0`、`127.0.0.0/8`、`224.0.0.0/4` 及以上的组播/保留段。
- 按前缀算出网络号与广播地址，**拒绝等于两者之一**的地址。
- 非法输入：打印 `Invalid address: <输入>` 后**重问**，不退出。

### 4.6 写盘后的应用步骤（installer.sh 的 h 段）

1. `blockdev --rereadpt "$disk"` + `mdev -s` + `sleep 1`，最多重试 3 次。
2. 在 `${disk}2` / `${disk}p2` 以及其余分区中，找 `blkid` 输出含 `LABEL="rootfs"` 的分区。
   找不到即报错退出（退出码非 0），并提示「磁盘已写入但网络配置未应用」。
3. `mount -t ext4 -o rw <part> /mnt/rootfs`；`/etc/config/network` 不存在即报错。
4. 打印 `Applying network configuration...`
5. 按第 5 节逐文件改写。
6. `sync; umount`；再 `mount -o ro` 复验（第 5.3 节），不一致则报错。
7. 打印 `Network configuration applied and verified.`

**关键**：写入前的整盘 sha256 回读校验（现有逻辑）必须在打补丁**之前**完成，
补丁之后的磁盘不再等于载荷，这是设计使然 —— 完成信息要说明这一点。

---

## 5. 要改写的文件与规则

统一使用「挂载点相对路径」，记 `$R` = `/mnt/rootfs`。

### 5.1 `/etc/config/network`

| 目标 | 规则 |
|---|---|
| `config device` 段内 `name 'br-lan'` | `list ports` 全删，只留一行 `list ports '<LAN口>'` |
| `config interface 'lan'` | `list ipaddr` 全删，只留 `list ipaddr '<addr>/<prefix>'`；保留 `proto static`、`ip6assign` |
| `config interface 'wan'` | `option device '<WAN口>'`；无 WAN 时**整段删除** |
| `config interface 'wan6'` | `option device '<WAN口>'`；无 WAN 时**整段删除** |
| `config interface 'lan2'` | **整段删除**（若存在） |

### 5.2 其余文件

| 文件 | 规则 |
|---|---|
| `/etc/config/firewall` | 删除所有 `list network 'lan2'`；无 WAN 时再删除 `list network 'wan'` 与 `list network 'wan6'` |
| `/etc/board.json` | `network.lan.device` = LAN 口；`network.wan.device` = WAN 口；无 WAN 时删除 `network.wan` 整个对象 |
| `/etc/console-mihomo/config.json` | `bind-address` = LAN 地址的 IP 部分；`tun.include-interface` 里删除所有「当前不存在的网口名」，保留 `br-lan`、`cvpns` 等 |
| `/etc/console-mihomo/lan-devices.json` | 同上，保持与 `include-interface` 完全一致的数组内容 |
| `/etc/console-backup/network.last-good` | 若存在，按 5.1 同样规则改写（保证回滚不会退回旧网口） |
| `/etc/fwx` | 若有 `option monitor_device`，改为 WAN 口；无 WAN 时删除该行 |
| `/etc/console-install-ports.json` | **新建**，内容见 5.4 |

### 5.3 只读复验（必须实现，失败即退出非 0）

挂载后逐一断言：

1. `network` 中 `br-lan` 的 ports 恰好等于 `<LAN口>`；
2. `network` 中 `lan` 的 ipaddr 恰好等于 `<addr>/<prefix>`；
3. 无 WAN 时 `network` 里不存在 `config interface 'wan'`；有 WAN 时其 device 等于 `<WAN口>`；
4. `network` 里不存在 `lan2`；
5. `firewall` 里不存在 `lan2` 字样；
6. `board.json` 能被 `python`/`jsonfilter` 以外的方式确认包含 `<LAN口>`（用 grep 即可）；
7. mihomo `config.json` 的 `bind-address` 等于 `<addr>` 的 IP 部分。

### 5.4 `/etc/console-install-ports.json`

单行 JSON（安装器内用 printf 拼，无需 json 库；字符串只含 `[A-Za-z0-9:._-]`，无需转义）：

```json
{"lan":{"name":"eth0","mac":"aa:bb:cc:dd:ee:ff","driver":"igb","pci":"0000:01:00.0"},"wan":null,"address":"192.168.1.1/24","installed_at":"2026-01-01T00:00:00Z"}
```

`wan` 为对象或 `null`。`installed_at` 取 `date -u +%Y-%m-%dT%H:%M:%SZ`。

---

## 6. check-iso.py 新增检查项（全部为 FAIL 级）

| code | 断言 |
|---|---|
| `INITRD/NICBUNDLE` | initramfs 内含 `lib/modules/<ver>/modules.dep` 且非空 |
| `INITRD/NICORDER` | 含 `etc/nic-load.order` 且至少 1 行 |
| `INITRD/NICFW` | 含 `lib/firmware/` 目录 |
| `INIT/LOADNIC` | `/init` 里出现加载 `nic-load.order` 的逻辑（含 `modprobe`） |
| `INST/LANSELECT` | 安装器含 `Select the LAN port by number` |
| `INST/DEFAULTKEY` | 安装器含 `for the built-in default` 且**不含**「空回车即跳过」的实现 |
| `INST/ADDR` | 安装器含 `Enter the LAN address` 且做前缀/网络号校验 |
| `INST/MOUNTROOT` | 安装器含 `LABEL="rootfs"` 或等价的分区定位 + `mount -t ext4` |
| `INST/APPLYVERIFY` | 安装器含 `Network configuration applied and verified` |
| `INST/LAN2DROP` | 安装器含删除 `lan2` 的逻辑 |
| `INST/NOHARDCODE` | 安装器**不得**再出现写死的 `ports 'eth0'` 之类硬编码 |

`check-iso.py` 现有的「剥注释再检查」机制必须继续生效（注释里的反例不算违规）。

---

## 7. verify-e2e.sh 新增

1. QEMU 每个场景加 **3 块 e1000 网卡**（`-netdev user` + `-device e1000`），保证
   `e1000.ko` 被加载、出现 eth0/eth1/eth2。
2. 驱动脚本按新交互逐步发送：LAN 编号 → LAN 地址 → WAN 编号。
3. 安装完成后，**从 target.img 里解析 rootfs 分区**（第 4.6 节同一算法），断言：
   - `br-lan` ports 是所选网口；
   - `lan` 的 ipaddr 是所选地址；
   - `wan` device 是所选网口；
   - 无 `lan2`；
   - `firewall` 无 `lan2`；
   - 存在 `/etc/console-install-ports.json`。
4. 四场景（cdrom/usb × bios/uefi）都要跑通。
5. 新增退出码 **7 = 安装后网络配置校验失败**，并在汇总里区分显示。

---

## 8. 不许退化的既有能力

- 载荷必须内置在 initramfs（不得回到 `root=/dev/sr0`）。
- grub.cfg 纯 ASCII、无非法 `for` 设备列表。
- eMMC `boot0/boot1/rpmb` 必须继续排除。
- 4Kn（`logical_block_size != 512`）必须继续拒绝。
- 写后整盘 sha256 回读校验必须继续存在。
- 第二次确认必须仍是「按回车」。
- 只改安装器时不得强依赖重新生成载荷（但本次改了 `init-installer.sh` 与载荷产物，
  所以本次必须二者都重建）。
