#!/bin/sh
# =============================================================================
# /init —— 安装器 Live 环境的第一个进程（第 3 代：载荷内置）
#
# 为什么改成这样：
#   原版方案 grub 传 root=/dev/sr0，靠光盘做根文件系统。实机日志证明这条路
#   在两种情况下必然失败：
#     · Ventoy「文件拷贝」模式：ISO 只是 exFAT 数据分区里的一个文件，
#       内核看不到 sr0，而且 192 的内核没有 exfat 驱动，也读不到那个分区。
#     · dd 到 U 盘：ISO 的 MBR 是 GPT 保护表，能启动 grub，但同样没有 sr0。
#   两种情况下内核都会永久停在 "Waiting for root device /dev/sr0..."。
#
#   这一代把整块安装载荷直接放进 initramfs：
#     · 内核不需要任何根设备，initramfs 自己就是根；
#     · 不需要读 exfat / iso9660，不存在「找不到介质」的路径；
#     · 光驱、dd 的 U 盘、Ventoy、QEMU 四种情形行为完全一致。
#
#   代价是 initramfs 变大（约 175 MiB，全程在内存里），换来的是不再有任何
#   依赖外部介质枚举的不确定因素。
#
# 第 4 代追加「网卡阶段」（NIC-SPEC 第 3 节）：
#   安装器不再硬编码 eth0=LAN / eth1=WAN，而是列出现有网口让用户手选。
#   列网口的前提是驱动已经加载 —— initramfs 是最小根，内核里只有 builtin
#   驱动，实机的 igb/igc/ixgbe/r8169/tg3 全是模块。所以这里在进安装器之前
#   按 /etc/nic-load.order（顺序照抄 rootfs/etc/modules.d）逐个 modprobe，
#   保证「安装器里看到的 ethN」与「装完系统里的 ethN」一致；否则用户选了
#   eth1=LAN，装完 eth1 变成 WAN，一重启就失联。
#
#   网卡阶段任何一步失败都不允许中断安装（全部 || true）：驱动没加载上最
#   多让用户少一个可选项（还能选内置默认），不能因此让用户装不了系统。
# =============================================================================
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
umask 022

/bin/busybox --install -s /bin 2>/dev/null

mkdir -p /proc /sys /dev /tmp /run /mnt /usr/sbin /etc
mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null
mount -t devtmpfs devtmpfs /dev  2>/dev/null

if [ ! -c /dev/console ]; then mknod /dev/console c 5 1 2>/dev/null; fi
if [ ! -c /dev/null ];    then mknod /dev/null    c 1 3 2>/dev/null; fi

# /dev/console follows the last console= argument. Default to the local
# display; serial-only systems select the serial menu entry explicitly.
installer_tty=/dev/console
preferred_tty=''
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in console=*) preferred_tty=${arg#console=}; preferred_tty=${preferred_tty%%,*} ;; esac
done
case "$preferred_tty" in
    tty0|tty1) [ ! -c /dev/tty1 ] || installer_tty=/dev/tty1 ;;
    ttyS[0-9]*) [ ! -c "/dev/$preferred_tty" ] || installer_tty=/dev/$preferred_tty ;;
esac
exec <"$installer_tty" >"$installer_tty" 2>&1
export LANG=C.UTF-8 LC_ALL=C.UTF-8
case "$preferred_tty" in
    tty0|tty1)
        printf '\033%%G'
        /bin/setfont -C "$installer_tty" /etc/installer-console.psf 2>/tmp/installer-font.log || true
        stty iutf8 2>/dev/null || true
        ;;
esac

# Keep PID 1 alive even when a rescue shell exits or a console disconnects.
installer_shell() {
    while :; do
        /bin/sh -i
        printf '\n终端已退出，正在重新启动救援终端 / Console shell closed; restarting shell.\n'
        sleep 2
    done
}

printf '\n'
printf '==================================================\n'
printf '安装控制台 / Installer console: %s\n' "$installer_tty"
if [ -r /etc/installer-os-name ]; then
    printf ' %s\n' "$(cat /etc/installer-os-name)"
else
    printf ' OpenWrt Console Installer\n'
fi
if [ -r /etc/console-installer-version ]; then
    printf ' 版本 / Release: %s\n' "$(cat /etc/console-installer-version)"
fi
printf ' 安装器启动中 / Starting installer environment\n'
printf '==================================================\n'

mdev -s 2>/dev/null || true

# --------------------------------------------------------------- 等待枚举稳定
# 不能只等「出现第一块盘」就往下走。实机上 USB 与 eMMC 的枚举时刻不同
# （C3558 上 mmc0 约 3.8s、USB 约 3.9~5.4s），如果安装器先启动，打印出来的
# 磁盘列表就会缺少后到的盘，用户看不到自己的目标盘，风险很高。
#
# 这里改为「块设备集合连续 STABLE_CHECKS 次不再变化」才继续，
# 上限 MAX_WAIT 秒。集合一旦稳定，说明快照可以代表真实硬件。
MAX_WAIT=40
STABLE_CHECKS=4        # 每次间隔 0.5s，即连续 2 秒无变化
prev=''
stable=0
waited=0

snapshot() {
    # 用「名字:扇区数」而不是只用名字：块设备可能先以 0 扇区出现，
    # 稍后才报告真实容量。只看名字会误判为已经稳定。
    for e in /sys/class/block/*; do
        printf '%s:%s ' "${e##*/}" "$(cat "$e/size" 2>/dev/null || echo 0)"
    done
}

while [ "$waited" -lt "$MAX_WAIT" ]; do
    cur=$(snapshot)
    if [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge "$STABLE_CHECKS" ] && break
    else
        stable=0
        prev=$cur
    fi
    sleep 0.5
    waited=$((waited + 1))
done
printf '磁盘枚举已稳定 / Block devices stable after %.1fs.\n' "$(awk "BEGIN{print $waited/2}")"

# 打印一次实际看到的整盘，便于现场核对
printf '检测到的整盘设备： / Whole disks detected:\n'
for e in /sys/class/block/*; do
    n=${e##*/}
    [ -f "$e/partition" ] && continue
    case "$n" in
        loop*|ram*|sr*) continue ;;
        mmcblk*boot0|mmcblk*boot1|mmcblk*rpmb) continue ;;
    esac
    sz=$(cat "$e/size" 2>/dev/null || echo 0)
    [ "$sz" -gt 0 ] || continue
    printf '  /dev/%-12s %6s MiB\n' "$n" "$((sz / 2048))"
done
printf '\n'

# --------------------------------------------------------------- 网卡阶段
# NIC-SPEC 第 3 节：在「块设备稳定等待」之后、「执行 openwrt-install」之前。
#
# 为什么顺序要照抄 rootfs：网口名 ethN 是按驱动加载顺序分配的。initramfs 里
# 的模块加载顺序若与 rootfs 的 /etc/modules.d/* 不一致，安装器里看到的
# eth0/eth1/eth2 就和装完之后的对应关系错位，用户选了 eth1 当 LAN，装完
# eth1 成了 WAN，一重启就失联。所以只按 /etc/nic-load.order（构建时从
# rootfs/etc/modules.d 生成）的顺序 modprobe，自己不做任何排序。
#
# 本段所有操作都不许中断安装：网卡加载不出来只是少一个可选项（还能选
# 「内置默认」），绝不能因此让用户装不了系统。所以到处是 || true。
nic_kver=$(uname -r 2>/dev/null || true)
nic_moddir=/lib/modules/$nic_kver

# 模块目录不能只信 uname -r：bundle 里的 lib/modules/<ver> 是构建时装载荷那次
# 的版本号，与 initramfs 内核版本理论上一致，一旦构建侧换了版本就会静默不匹配、
# 一个模块都加载不上。所以优先用「真的有 modules.dep 的那个目录」，uname -r
# 只作为兜底。多个目录时优先名字里带 uname -r 的。
if [ ! -f "$nic_moddir/modules.dep" ]; then
    for nic_d in /lib/modules/*/modules.dep; do
        [ -f "$nic_d" ] || continue
        case "$nic_d" in
            */"$nic_kver"/modules.dep) nic_moddir=/lib/modules/$nic_kver; break ;;
        esac
        nic_moddir=${nic_d%/modules.dep}
    done
fi

export NIC_COUNT=0
export NIC_BUNDLE=0

# modprobe 优先；modules.dep 与本机 uname -r 对不上时退回 insmod。
# 依赖模块都排在被依赖者之前，insmod 单文件也能连起来。
nic_load_module() {
    modprobe "$1" 2>/dev/null && return 0
    if [ -f "$nic_moddir/$1.ko" ]; then
        insmod "$nic_moddir/$1.ko" 2>/dev/null && return 0
    fi
    return 1
}

nic_loaded=0
if [ -f "$nic_moddir/modules.dep" ]; then
    export NIC_BUNDLE=1
    if [ -s /etc/nic-load.order ]; then
        # 用独立的 fd 3 读清单：ash 的 read 循环里如果被调用的程序碰了 stdin，
        # 循环会提前结束、后半段模块就漏加载了。
        while read -r m <&3; do
            [ -n "$m" ] || continue
            case "$m" in '#'*) continue ;; esac
            nic_load_module "$m" && nic_loaded=$((nic_loaded + 1))
        done 3< /etc/nic-load.order
    fi
    # 兜底：nic-load.order 只收了 rootfs/etc/modules.d 里排得到的名字，允许
    # 名单里可能还有没被它覆盖的（例如某个驱动只在硬件上才需要）。把允许
    # 名单整体再 modprobe 一遍，已加载的名字是 no-op，代价很小。
    if [ -s /etc/nic-allowlist ]; then
        nic_allow=$(cat /etc/nic-allowlist 2>/dev/null || true)
        nic_oldifs=$IFS
        IFS=','
        for m in $nic_allow; do
            [ -n "$m" ] || continue
            nic_load_module "$m" >/dev/null 2>&1 || true
        done
        IFS=$nic_oldifs
    fi
fi

# 等网口集合稳定。网卡 probe 是异步的（尤其是 USB 网卡、需要固件的卡），
# 只 sleep 一次就列，会漏掉晚到的口，用户就选不到自己的 LAN。
# 与上面的块设备同样的「连续 N 次不变」判据，上限 15 秒。
nic_snapshot() {
    for e in /sys/class/net/*; do
        [ -d "$e" ] || continue
        n=${e##*/}
        [ "$n" = lo ] && continue
        printf '%s ' "$n"
    done
}

NIC_STABLE_CHECKS=4          # 每次间隔 0.5s，即连续 2 秒无变化
NIC_MAX_TICKS=30             # 30 × 0.5s = 15 秒上限
# 初值不能是空串：网口一个都还没出现时 snapshot 也是空串，两者相等会让
# 第一次采样就记成「稳定」，异步 probe 的网卡随后才出现就被漏掉了。
nic_prev='__unset__'
nic_stable=0
nic_ticks=0
while [ "$nic_ticks" -lt "$NIC_MAX_TICKS" ]; do
    nic_cur=$(nic_snapshot 2>/dev/null || true)
    if [ "$nic_cur" = "$nic_prev" ]; then
        nic_stable=$((nic_stable + 1))
        [ "$nic_stable" -ge "$NIC_STABLE_CHECKS" ] && break
    else
        nic_stable=0
        nic_prev=$nic_cur
    fi
    sleep 0.5
    nic_ticks=$((nic_ticks + 1))
done

# 网口列表。格式与 NIC-SPEC 第 3 节第 4 小节逐字节一致（无 [n] 编号，编号
# 由安装器自己加）：
#   检测到的网口： / Network interfaces detected:
#     eth0  aa:bb:cc:dd:ee:ff  link=up    driver=igb   pci=0000:01:00.0
# 列宽：名字 6、MAC 17、link= 值 6、driver= 值 6、pci= 原样。
nic_count=0
printf '检测到的网口： / Network interfaces detected:\n'
for e in /sys/class/net/*; do
    [ -d "$e" ] || continue
    ifname=${e##*/}
    [ "$ifname" = lo ] && continue
    nic_count=$((nic_count + 1))

    mac=$(cat "$e/address" 2>/dev/null || true)
    [ -n "$mac" ] || mac='?'

    case "$(cat "$e/operstate" 2>/dev/null || true)" in
        up) link=up ;;
        *)  link=down ;;
    esac

    # 驱动名：/sys/class/net/X/device/driver 是指向 drivers/<name> 的符号链接。
    # 不要直接对不存在的路径做 readlink -f —— 那样拿回的是原路径本身，末段
    # 恰好是 "driver"，会打印出 driver=driver 这种假信息。
    drv=''
    if [ -L "$e/device/driver" ] || [ -d "$e/device/driver" ]; then
        drv=$(readlink -f "$e/device/driver" 2>/dev/null || true)
        case "$drv" in
            */drivers/*) drv=${drv##*/} ;;
            *) drv='' ;;
        esac
    fi
    if [ -z "$drv" ] && [ -r "$e/device/uevent" ]; then
        drv=$(sed -n 's/^DRIVER=//p' "$e/device/uevent" 2>/dev/null | head -n 1 || true)
    fi
    [ -n "$drv" ] || drv='?'

    # PCI 地址：/sys/class/net/X/device 的真实路径最后一段即 BDF（形如
    # 0000:01:00.0）。USB 网卡、虚拟设备的末段不是 BDF，一律写 ?，
    # 免得把没意义的路径片段当成 PCI 地址写进/console-install-ports.json。
    pci=''
    if [ -d "$e/device" ]; then
        pci=$(readlink -f "$e/device" 2>/dev/null || true)
        pci=${pci##*/}
        case "$pci" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F].[0-7])
                ;;
            *) pci='?' ;;
        esac
    fi
    [ -n "$pci" ] || pci='?'

    printf '  %-6s%-17s  link=%-6s driver=%-10s pci=%s\n' \
        "$ifname" "$mac" "$link" "$drv" "$pci"
done
[ "$nic_count" -gt 0 ] || printf '  (none)\n'
printf '网口与驱动数量 / Network interfaces: %s found, %s driver module(s) loaded.\n\n' \
    "$nic_count" "$nic_loaded"

export NIC_COUNT=$nic_count

export PAYLOAD_DIR=/installer

# 载荷必须内置；缺失属于打包错误，直接暴露出来
if [ ! -f /installer/SHA256SUMS ]; then
    printf '\n打包错误：安装环境中缺少载荷目录 / *** PACKAGING ERROR: /installer is missing from the initramfs. ***\n'
    printf '镜像内容不完整，请反馈此错误 / This image was built incorrectly; please report it.\n'
    installer_shell
fi

# rescue 菜单项：只给 shell，不自动安装
case "$(cat /proc/cmdline 2>/dev/null)" in
    *installer.rescue=1*)
        printf '\n已进入救援终端，载荷目录 / Rescue shell requested. Payload is at %s\n' "$PAYLOAD_DIR"
        printf '输入该命令查看可用磁盘 / Run "openwrt-install --list" to inspect disks.\n\n'
        installer_shell
        ;;
esac

printf '\n'
/usr/sbin/openwrt-install
rc=$?

printf '\n--------------------------------------------------\n'
if [ "$rc" = 0 ]; then
    printf ' 安装流程已正常完成 / Installer session finished normally.\n'
else
    printf ' 安装流程已退出，返回码 / Installer exited with code %s.\n' "$rc"
fi
printf ' 重新运行安装器 / Type "openwrt-install" to run it again.\n'
# PID 1 is the installer script, so the applets must act directly instead of
# signalling init. The installer has already synced and unmounted the target.
printf ' 关机请输入poweroff -f，重启请输入reboot -f / Type "poweroff -f" to shut down, or "reboot -f" to restart.\n'
printf '--------------------------------------------------\n\n'

installer_shell
