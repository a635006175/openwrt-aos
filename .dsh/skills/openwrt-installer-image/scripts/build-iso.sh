#!/bin/bash
# =============================================================================
# build-iso.sh —— 组装 OpenWrt 安装器 ISO（第 3 代引导方案）
#
# 这个脚本固化了两轮实机排障得到的全部结论。改它之前请先读「为什么」，
# 下面每一条都对应一次真实的启动失败。
#
# 核心设计：安装载荷内置在 initramfs 里，内核不需要任何外部根设备。
#   优点：光驱 / dd 到 U 盘 / Ventoy 文件拷贝 / QEMU —— 四种引导方式行为一致，
#         不存在「找不到介质」的分支。
#   代价：initramfs 约 160 MiB，全程驻留内存。
#
# 网卡驱动：$BODY/nicbundle.tar.gz 由 build-payload.sh 生成，解压进 initramfs 的 /，
#   提供 lib/modules/$KVER/{*.ko,modules.dep,modules.alias} + lib/firmware +
#   etc/nic-load.order + etc/nic-allowlist（NIC-SPEC 第 1、2 节）。
#   缺这个文件直接报错，不允许静默跳过 —— 否则安装环境里看不到真实网口。
#
# 用法：
#   bash build-iso.sh                      # 用默认路径
#   bash build-iso.sh --out /path/x.iso    # 指定输出
#   bash build-iso.sh --version 20261107-LANandcall  # 安装器与清单版本号
#   bash build-iso.sh --check-only         # 只做输入体检，不构建
#
# 之后务必执行：
#   python3 check-iso.py <出来的 iso>      # 静态体检（秒级）
#   bash verify-e2e.sh                     # 四场景端到端（约 20 分钟）
# =============================================================================
set -euo pipefail
export LC_ALL=C
umask 022

# ------------------------------------------------------------------ 默认配置
STAGE=${STAGE:-/home/openwrt/router-build}
BODY=${BODY:-$STAGE/out}                  # bios.img.gz / uefi.img.gz 及元数据
BOOTSRC=${BOOTSRC:-$STAGE/bootsrc}        # 内含内核 boot/vmlinuz
SRCDIR=${SRCDIR:-$(cd "$(dirname "$0")" && pwd)}
ASSETSDIR=${ASSETSDIR:-$SRCDIR/../assets}
OUTISO=${OUTISO:-/home/openwrt/console-sync/openwrt-console-installer.iso}
VOLID=${VOLID:-OPENWRT_INSTALLER}
KVER=${KVER:-6.18.55}
RELEASE_VERSION=${RELEASE_VERSION:-}
# 系统名称（引导菜单上显示的名字 + 装好后的系统自报版本）。
# 由 build-payload.sh --os-name 写进 $BODY/os-name.txt，这里读出来直接用，
# 目的是让「安装盘菜单」「装好后的磁盘菜单」「系统内部版本」三处永远同名。
# 显式传 --os-name 时以命令行参数为准，但会与载荷记录比对，不一致就中止。
OS_NAME=${OS_NAME:-}
PUBLISH_RELEASE=${PUBLISH_RELEASE:-1}
# 实机（192.168.1.1）内核的 sha256。上游镜像里的 vmlinuz 大小与它几乎一样
# （6960128 vs 6964224）、vermagic 也同为 6.18.55 SMP mod_unload，但**不兼容**：
# 用上游内核配 192 的 rootfs，启动约 9 秒时在 nf_defrag_ipv6_disable 处 panic。
KERNEL_SHA_EXPECT=${KERNEL_SHA_EXPECT:-fd30ff912bb85231593f5bed5b34ed06bd4daf1793089437b02b7d5c6be007b2}
WORK=${WORK:-/home/openwrt/inst2work}
# 期望状态：内核与这几份内容一致（用于 --check-only 快速判断是否需要重建）
EXPECT_VPN_SHA=${EXPECT_VPN_SHA:-11b80e1cc4999fc14f02b0738d02710db3481a5841eb8fbf703641e6a42fedf1}

CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case $1 in
        --out)        OUTISO=$2; shift 2 ;;
        --body)       BODY=$2; shift 2 ;;
        --bootsrc)    BOOTSRC=$2; shift 2 ;;
        --work)       WORK=$2; shift 2 ;;
        --volid)      VOLID=$2; shift 2 ;;
        --version)    RELEASE_VERSION=$2; shift 2 ;;
        --os-name)    OS_NAME=$2; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        -h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

TREE=$WORK/tree
IR=$WORK/initramfs

log(){  printf '\n\033[1m[build] %s\033[0m\n' "$*"; }
ok(){   printf '  [ok] %s\n' "$*"; }
info(){ printf '  %s\n' "$*"; }
warn(){ printf '  [warn] %s\n' "$*"; }
die(){  printf '\n[build] ERROR: %s\n' "$*" >&2; exit 1; }
case "$RELEASE_VERSION" in *[!A-Za-z0-9._-]*) die '版本号只允许 ASCII 字母、数字、点、下划线和短横线' ;; esac
case "$OS_NAME" in *[!A-Za-z0-9._\ -]*) die "系统名只允许 ASCII 字母、数字、点、下划线、短横线、空格：$OS_NAME" ;; esac

# A source/rootfs sync deliberately does not rebuild disk payloads. Never publish
# an ISO from those older payloads merely because the output filename is fixed.
SYNC_STATE=$STAGE/development-sync-state.json
SYNC_STATE_SHA=''
if [ -f "$SYNC_STATE" ]; then
    SYNC_STATE_SHA=$(sha256sum "$SYNC_STATE" | awk '{print $1}')
    if grep -Eq '"payload_rebuild_required"[[:space:]]*:[[:space:]]*true' "$SYNC_STATE"; then
        die '开发代码已同步，但磁盘载荷尚未更新。请先运行 build-payload.sh，再运行 build-iso.sh。'
    fi
fi

# ------------------------------------------------------------------ 工具
log "工具检查"
for c in busybox cpio gzip xorriso grub-mkrescue sha256sum stat dd od awk; do
    command -v "$c" >/dev/null 2>&1 || die "缺少工具: $c"
done
for d in /usr/lib/grub/i386-pc /usr/lib/grub/x86_64-efi; do
    [ -d "$d" ] || die "缺少 grub 模块目录: $d （apt install grub-pc-bin grub-efi-amd64-bin）"
done
[ -f /usr/lib/grub/i386-pc/boot_hybrid.img ] \
    || die "缺少 boot_hybrid.img —— grub-mkrescue 无法产出可引导 MBR"
ok "busybox / grub(i386-pc + x86_64-efi) / xorriso 就绪"

# ------------------------------------------------------------------ 输入
log "输入校验"
for f in "$BOOTSRC/boot/vmlinuz" "$SRCDIR/init-installer.sh" "$SRCDIR/installer.sh"; do
    [ -f "$f" ] || die "缺少输入: $f"
done
for m in bios uefi; do
    for s in img.gz img.bytes img.raw-sha256; do
        [ -f "$BODY/$m.$s" ] || die "缺少载荷 $m.$s （先用 build-payload.sh 生成）"
    done
done

# NIC-SPEC 1.1 / 2.5：网卡驱动 bundle 是 initramfs 的硬依赖。
# 缺了它安装环境里没有任何网卡驱动，用户只能在看不到网口的界面里瞎猜，
# 所以这里必须明确报错，不允许静默跳过。
[ -f "$BODY/nicbundle.tar.gz" ] \
    || die "缺少网卡驱动 bundle $BODY/nicbundle.tar.gz
  它会打进 initramfs，缺了安装环境里就看不到真实网口（NIC-SPEC 1.1）。
  生成方式：bash build-payload.sh --nic-only    # 几秒，不动 bios/uefi 镜像
  或全量：  bash build-payload.sh"

KERNEL_SHA=$(sha256sum "$BOOTSRC/boot/vmlinuz" | awk '{print $1}')
[ "$KERNEL_SHA" = "$KERNEL_SHA_EXPECT" ] \
    || die "内核 sha256 不是实机内核。
  期望: $KERNEL_SHA_EXPECT
  实际: $KERNEL_SHA
用错内核会导致启动 ~9 秒时 kernel panic（nf_defrag_ipv6_disable+0x28b）。
若确实换了内核，显式传入 KERNEL_SHA_EXPECT=... 覆盖。"
ok "内核 $(stat -c %s "$BOOTSRC/boot/vmlinuz") 字节 sha=${KERNEL_SHA:0:16}"

for m in bios uefi; do
    b=$(cat "$BODY/$m.img.bytes")
    case "$b" in ''|*[!0-9]*) die "$m.img.bytes 内容非法: $b" ;; esac
    actual=$(gzip -dc "$BODY/$m.img.gz" | wc -c)
    [ "$b" = "$actual" ] \
        || die "$m.img.bytes=$b 与解压流 $actual 不一致（元数据过期，重新生成）"
    ok "$m 载荷: $(stat -c %s "$BODY/$m.img.gz") 字节 gz / $b 字节 raw"
done

# ------------------------------------------------------------------ 系统名
# 载荷里的 os-release / console-version 和磁盘 grub.cfg 的菜单名由
# build-payload.sh --os-name 一次写成，这里只做核对，不允许再各写一份：
# 若两边不一致，装完重启就会出现「安装盘菜单叫 A、装好系统叫 B」。
log "系统名称核对"
PAYLOAD_OS_NAME_FILE=$BODY/os-name.txt
PAYLOAD_BRANDED=0
if [ -f "$PAYLOAD_OS_NAME_FILE" ]; then
    PAYLOAD_OS_NAME=$(head -1 "$PAYLOAD_OS_NAME_FILE")
    grep -qx 'branded=1' "$PAYLOAD_OS_NAME_FILE" && PAYLOAD_BRANDED=1
    [ -n "$PAYLOAD_OS_NAME" ] || die "$PAYLOAD_OS_NAME_FILE 是空的 —— 载荷没记录系统名"
    if [ -n "$OS_NAME" ] && [ "$OS_NAME" != "$PAYLOAD_OS_NAME" ]; then
        die "系统名不一致：命令行 --os-name '$OS_NAME'，载荷里是 '$PAYLOAD_OS_NAME'。
  载荷的引导菜单与系统内部版本已按 '$PAYLOAD_OS_NAME' 写好，
  要换名请用同样的 OS_NAME 重跑 build-payload.sh。"
    fi
    OS_NAME=$PAYLOAD_OS_NAME
    if [ "$PAYLOAD_BRANDED" != 1 ]; then
        warn "载荷只改了磁盘菜单显示名，系统内部仍是 OpenWrt 标识（未传 --os-name）。
  若要「菜单名 == 装好后的系统版本」，请 OS_NAME=$OS_NAME 重跑 build-payload.sh。"
    fi
else
    [ -n "$OS_NAME" ] \
        || die "载荷没有 os-name.txt，也没有传 --os-name。
  引导菜单上需要一个系统名（例如 AOS-20261109-V1）。
  做法：OS_NAME=<名字> bash build-payload.sh  然后重跑本脚本。"
    warn "载荷无 os-name.txt（旧载荷），按命令行 --os-name '$OS_NAME' 生成菜单。
  注意：旧载荷内部的 os-release/console-version 仍是原名，装好后两处名称会不一致。"
fi
ok "系统名称：$OS_NAME"
# 本次发布的版本号与系统名是同一个东西（AOS-20261109-V1 既是名字也是版本），
# 没显式给 --version 时就跟系统名走，避免 manifest 里出现两个不同说法。
: "${RELEASE_VERSION:=$OS_NAME}"
ok "发布版本号：$RELEASE_VERSION"

# nicbundle 内容体检：光有文件不够，必须真的含 NIC-SPEC 1.1 那几项。
# 注意清单落在 mktemp 目录里而不是 $WORK —— $WORK 在后面会被 rm -rf。
log "网卡驱动 bundle 校验"
NICBUNDLE=$BODY/nicbundle.tar.gz
NIC_TMP=$(mktemp -d /tmp/nicbundle.XXXXXX)
trap 'rm -rf "$NIC_TMP"' EXIT
NIC_LIST=$NIC_TMP/list
gzip -dc "$NICBUNDLE" | tar -tf - > "$NIC_LIST" 2>/dev/null \
    || die "$NICBUNDLE 解不开（不是合法 gzip tar）"
[ -s "$NIC_LIST" ] || die "$NICBUNDLE 是空的"
NB_OK=0
grep -qE "^lib/modules/$KVER/modules\.dep$"  "$NIC_LIST" && NB_OK=$((NB_OK + 1))
grep -qxF 'etc/nic-load.order'               "$NIC_LIST" && NB_OK=$((NB_OK + 1))
grep -qxF 'etc/nic-allowlist'                "$NIC_LIST" && NB_OK=$((NB_OK + 1))
grep -qE '^lib/firmware/'                    "$NIC_LIST" && NB_OK=$((NB_OK + 1))
grep -qxF "lib/modules/$KVER/e1000.ko"       "$NIC_LIST" && NB_OK=$((NB_OK + 1))
grep -qxF "lib/modules/$KVER/igb.ko"         "$NIC_LIST" && NB_OK=$((NB_OK + 1))
if [ "$NB_OK" != 6 ]; then
    die "$NICBUNDLE 内容不全（只命中 $NB_OK/6 项）：
  需含 lib/modules/$KVER/modules.dep、etc/nic-load.order、etc/nic-allowlist、
  lib/firmware/、e1000.ko、igb.ko。重新生成：bash build-payload.sh --nic-only"
fi
NB_KO=$(grep -cE "^lib/modules/$KVER/.*\.ko$" "$NIC_LIST" || true)
NB_BYTES=$(stat -c %s "$NICBUNDLE")
[ "$NB_BYTES" -le $((8 * 1024 * 1024)) ] \
    || die "nicbundle.tar.gz $NB_BYTES 字节超过 8 MiB（NIC-SPEC 1.1）"
ok "nicbundle $((NB_BYTES / 1024)) KiB / $NB_KO 个 .ko / 结构 6 项齐全"

if [ "$CHECK_ONLY" = 1 ]; then
    log "--check-only：输入全部合法，未构建"
    exit 0
fi

# ------------------------------------------------------------------ initramfs
log "构建 initramfs（含安装载荷）"
rm -rf "$WORK"; mkdir -p "$TREE/boot/grub" "$IR"
mkdir -p "$IR"/bin "$IR"/sbin "$IR"/usr/bin "$IR"/usr/sbin \
         "$IR"/dev "$IR"/proc "$IR"/sys "$IR"/tmp "$IR"/run \
         "$IR"/installer "$IR"/mnt "$IR"/etc
cp /bin/busybox "$IR/bin/busybox"; chmod 0755 "$IR/bin/busybox"
if [ -n "$RELEASE_VERSION" ]; then
    printf '%s\n' "$RELEASE_VERSION" > "$IR/etc/console-installer-version"
fi
# 安装环境自己的菜单也显示系统名。init-installer.sh 的 banner 已经会打印
# /etc/console-installer-version；这里再单独落一份系统名，供 splash 使用。
printf '%s\n' "$OS_NAME" > "$IR/etc/installer-os-name"

# 只带安装器真正用到的 applet。多带无害但会让 initramfs 变大。
#
# 本次（NIC-SPEC 2.3）确认过的三件事，别凭印象：
#   · tar        —— 新增。之前没有；解 nicbundle 与 /init 兜底都要它。
#   · blockdev   —— 原来**不在**列表里。安装器要 blockdev --rereadpt 让内核重读
#                   分区表，没有它写盘后找不到新分区。
#   · od         —— 原来**不在**列表里。安装器用 od 做 MBR 签名等字节级校验。
#   · blkid      —— 在列表里但 busybox 1.37 没有编译该 applet，循环会静默跳过。
#                   见下面专门的告警与提示（用 findfs 代替）。
#   · modprobe / mount / umount / losetup / awk / sed / tr / cut / sleep /
#     mkdir / sync —— 确认都在。
APPLETS="sh ash mount umount mknod mdev sleep cat ls mkdir rmdir rm mv cp ln \
 dd gzip gunzip zcat sha256sum awk sed grep egrep head tail wc tr cut expr \
 printf echo test true false readlink realpath basename dirname sort uniq \
 dmesg lsmod insmod modprobe rmmod switch_root poweroff reboot halt sync \
 blkid findfs fdisk more less vi clear stty tty df free ps kill \
 chmod chown touch find xargs yes seq stat id whoami uname timeout \
 losetup hexdump md5sum cmp diff date tar blockdev od"

n=0
MISSING_APPLETS=""
# 必须先把 --list 落到文件再 grep，不能直接 `busybox --list | grep -qx`：
# 后者在 set -o pipefail 下会因 grep -q 提前退出、busybox 收 SIGPIPE 而让整条
# 管道返回非零 —— 于是「明明有这个 applet」被判定成缺失。是否触发取决于
# busybox 写完与 grep 退出谁先，属于竞态：实测同一份 busybox 连编两次，
# 一次统计 83 个、一次 84 个（stat 时有时无）。这里落盘后再查，结果恒定。
BUSYBOX_APPLETS=$WORK/busybox-applets.txt
busybox --list | sort -u > "$BUSYBOX_APPLETS"
[ -s "$BUSYBOX_APPLETS" ] || die "busybox --list 输出为空，无法构建 applet 软链"
for a in $APPLETS; do
    if grep -qx -- "$a" "$BUSYBOX_APPLETS"; then
        ln -sf /bin/busybox "$IR/bin/$a"
        n=$((n + 1))
    else
        MISSING_APPLETS="$MISSING_APPLETS $a"
    fi
done
ok "$n 个 applet 软链（busybox 提供 $(wc -l < "$BUSYBOX_APPLETS") 个）"

# UTF-8 alone does not provide CJK glyphs on a Linux framebuffer console.
for asset in installer-console.psf installer-grub.pf2 installer-font-LICENSE.txt; do
    [ -s "$ASSETSDIR/$asset" ] || die "缺少双语安装字库资源: $asset"
done
cp "$ASSETSDIR/installer-console.psf" "$IR/etc/installer-console.psf"
mkdir -p "$IR/usr/share/licenses/installer-font"
cp "$ASSETSDIR/installer-font-LICENSE.txt" "$IR/usr/share/licenses/installer-font/LICENSE.txt"
SETFONT=$(command -v setfont) || die '缺少 setfont，无法初始化中文控制台字库'
cp "$SETFONT" "$IR/bin/setfont"
chmod 0755 "$IR/bin/setfont"
for l in $(ldd "$SETFONT" | awk '{for(i=1;i<=NF;i++)if($i~/^\//)print $i}'); do
    mkdir -p "$IR$(dirname "$l")"; cp -fL "$l" "$IR$l"
done

# 这些 applet 缺了安装流程会直接跑不动。以前 blkid 就是这样静默丢掉的
# （busybox 1.37 没编译它，循环跳过、谁也没发现），所以这里硬性拦住。
for a in sh mount umount mknod mdev modprobe insmod lsmod losetup dd gzip \
         gunzip awk sed grep tr cut sleep mkdir sync tar blockdev od poweroff reboot halt; do
    [ -e "$IR/bin/$a" ] || die "initramfs 缺关键 applet: $a（busybox 没编译它）"
done
# blkid 不是硬需求（安装器可用 findfs 兜底），但 NIC-SPEC 4.6.2 明确要安装器
# 用 blkid 找 LABEL="rootfs" 的根分区。busybox 1.37 没编译它，所以这里把构建机
# 上真正的 blkid 连同它的动态库一起打进 initramfs —— 否则安装器走到
# 「写盘后挂载新 rootfs 应用网络配置」那一步会直接失败。
if [ ! -e "$IR/bin/blkid" ]; then
    REAL_BLKID=""
    for p in /sbin/blkid /usr/sbin/blkid /bin/blkid /usr/bin/blkid; do
        [ -x "$p" ] && { REAL_BLKID=$p; break; }
    done
    if [ -n "$REAL_BLKID" ]; then
        # 目标目录先建好，再按 ldd 给出的绝对路径原样复制，保证 ld.so 找得到
        mkdir -p "$IR/lib" "$IR/lib64" "$IR/usr/lib" "$IR/sbin"
        cp -f "$REAL_BLKID" "$IR/sbin/blkid"
        chmod 0755 "$IR/sbin/blkid"
        BLKID_LIBS=$(ldd "$REAL_BLKID" 2>/dev/null \
                     | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }')
        BLKID_LIB_OK=1
        for l in $BLKID_LIBS; do
            [ -f "$l" ] || continue
            mkdir -p "$IR$(dirname "$l")"
            cp -fL "$l" "$IR$l" 2>/dev/null || { BLKID_LIB_OK=0; continue; }
            chmod 0755 "$IR$l" 2>/dev/null || true
        done
        if [ "$BLKID_LIB_OK" = 1 ]; then
            ln -sf /sbin/blkid "$IR/bin/blkid"
            ok "blkid 用宿主真实二进制 + $(echo "$BLKID_LIBS" | wc -l) 个动态库补齐"
        else
            rm -f "$IR/sbin/blkid" "$IR/bin/blkid"
            warn "blkid 动态库复制不完整，已放弃；安装器只能靠 findfs 兜底"
        fi
    else
        warn "构建机上找不到真实 blkid；安装器只能靠 findfs（LABEL= 查询）兜底"
    fi
fi
# 无论如何 findfs 必须可用：它是 blkid 缺失时的唯一替代手段
[ -e "$IR/bin/findfs" ] || die "initramfs 既没有 blkid 也没有 findfs，安装器无法定位 rootfs 分区"
[ -z "$MISSING_APPLETS" ] || info "未编入的 applet（已跳过）:$MISSING_APPLETS"

# 静态设备节点：内核若没开 CONFIG_DEVTMPFS_MOUNT，devtmpfs 不会被自动挂载，
# 此时 /dev/console 不存在，init 连输出都打不出来（v1 就栽在这里）。
for spec in "console c 5 1 622" "null c 1 3 666" "zero c 1 5 666" \
            "tty c 5 0 666" "random c 1 8 444" "urandom c 1 9 444"; do
    set -- $spec
    mknod -m "$5" "$IR/dev/$1" "$2" "$3" "$4"
done
ok "静态 /dev 节点 6 个"

install -m 0755 "$SRCDIR/init-installer.sh"      "$IR/init"
install -m 0755 "$SRCDIR/installer.sh"           "$IR/usr/sbin/openwrt-install"
sh -n "$IR/init"                     || die "/init 语法检查失败"
sh -n "$IR/usr/sbin/openwrt-install" || die "openwrt-install 语法检查失败"
ok "init + openwrt-install 通过 sh -n"

for m in bios uefi; do
    cp "$BODY/$m.img.gz"         "$IR/installer/$m.img.gz"
    cp "$BODY/$m.img.bytes"      "$IR/installer/$m.img.bytes"
    cp "$BODY/$m.img.raw-sha256" "$IR/installer/$m.img.raw-sha256"
done
# 系统名随载荷一起进 initramfs：check-iso.py 靠它核对「ISO 菜单名」与
# 「装好后磁盘菜单名/系统内部版本」是否同一个名字。branded 标记来自载荷，
# 用来区分「名字真的贯穿到系统内部」还是「只改了菜单显示名」。
{
    printf '%s\n' "$OS_NAME"
    printf 'branded=%s\n' "$PAYLOAD_BRANDED"
} > "$IR/installer/os-name.txt"
( cd "$IR/installer" && sha256sum *.gz *.bytes *.raw-sha256 > SHA256SUMS )
[ "$(wc -l < "$IR/installer/SHA256SUMS")" = 6 ] || die "SHA256SUMS 应为 6 行"
( cd "$IR/installer" && sha256sum -c --quiet SHA256SUMS ) || die "SHA256SUMS 自校验失败"
ok "载荷内置 $(du -sh "$IR/installer" | cut -f1)"

# ---------------------------------------------------------------- 网卡驱动 bundle
# NIC-SPEC 第 2 节：解压到 initramfs 的根（$IR），形成
#   lib/modules/$KVER/{*.ko,modules.dep,modules.alias}
#   lib/firmware/**
#   etc/nic-load.order, etc/nic-allowlist
# 之后 /init 会按 nic-load.order 逐个 modprobe，安装环境里才看得见真实网口。
log "解压网卡驱动 bundle 进 initramfs"
gzip -dc "$NICBUNDLE" | tar -xf - -C "$IR" \
    || die "nicbundle 解压进 initramfs 失败"
# 逐项断言：这四项任何一项缺失，装完系统后 ethN 编号就和开机后对不上
[ -s "$IR/lib/modules/$KVER/modules.dep" ] \
    || die "initramfs 里缺 lib/modules/$KVER/modules.dep（modprobe 无法解依赖）"
NIC_ORDER_LINES=$(wc -l < "$IR/etc/nic-load.order" 2>/dev/null || echo 0)
[ "$NIC_ORDER_LINES" -ge 1 ] \
    || die "initramfs 里 etc/nic-load.order 缺失或为空（NIC-SPEC 2.4）"
[ -d "$IR/lib/firmware" ] || die "initramfs 里缺 lib/firmware"
[ -s "$IR/etc/nic-allowlist" ] || die "initramfs 里缺 etc/nic-allowlist"
NIC_KO_IR=$(find "$IR/lib/modules/$KVER" -name '*.ko' | wc -l)
[ "$NIC_KO_IR" -ge 1 ] || die "initramfs 里一个 .ko 都没有"
for m in e1000 igb; do
    [ -f "$IR/lib/modules/$KVER/$m.ko" ] \
        || die "initramfs 里缺 $m.ko —— QEMU e2e / 实机都依赖它"
done
ok "网卡 bundle 就位：$NIC_KO_IR 个 .ko / modules.dep $(wc -l < "$IR/lib/modules/$KVER/modules.dep") 行 / 顺序 $NIC_ORDER_LINES 行"

cat > "$IR/etc/motd" <<'MOTD'
OpenWrt Console Installer — rescue shell
Run "openwrt-install --list" to list disks, "openwrt-install" to install.
MOTD

log "打包 initramfs"
( cd "$IR" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -6 ) \
    > "$TREE/boot/initrd.gz"
INITRD_SIZE=$(stat -c %s "$TREE/boot/initrd.gz")
[ "$INITRD_SIZE" -gt 100000000 ] \
    || die "initramfs 只有 $INITRD_SIZE 字节，载荷可能没打进去"
ok "initrd.gz $INITRD_SIZE 字节 ($((INITRD_SIZE / 1048576)) MiB)"

# 回读校验：确认打进去的东西真的在
mkdir -p "$WORK/ircheck"
( cd "$WORK/ircheck" && gzip -dc "$TREE/boot/initrd.gz" | cpio -idm --quiet ) \
    || die "initramfs 回读失败"
for f in init bin/busybox usr/sbin/openwrt-install \
         installer/SHA256SUMS installer/bios.img.gz installer/uefi.img.gz \
         "lib/modules/$KVER/modules.dep" etc/nic-load.order etc/nic-allowlist \
         "lib/modules/$KVER/e1000.ko" "lib/modules/$KVER/igb.ko"; do
    [ -e "$WORK/ircheck/$f" ] || die "initramfs 内缺 $f"
done
# NIC-SPEC 2.4：回读后这三项必须仍在且非空
[ -s "$WORK/ircheck/lib/modules/$KVER/modules.dep" ] \
    || die "initramfs 回读后 modules.dep 为空 —— modprobe 解不了依赖"
[ "$(wc -l < "$WORK/ircheck/etc/nic-load.order" 2>/dev/null || echo 0)" -ge 1 ] \
    || die "initramfs 回读后 etc/nic-load.order 为空"
[ -d "$WORK/ircheck/lib/firmware" ] \
    || die "initramfs 回读后 lib/firmware 不见了"
ok "回读确认网卡 bundle 仍在（modules.dep $(wc -l < "$WORK/ircheck/lib/modules/$KVER/modules.dep") 行 / 顺序 $(wc -l < "$WORK/ircheck/etc/nic-load.order") 行 / 固件 $(find "$WORK/ircheck/lib/firmware" -type f | wc -l) 个文件）"
( cd "$WORK/ircheck/installer" && sha256sum -c --quiet SHA256SUMS ) \
    || die "initramfs 内载荷校验失败"
IR_FILES=$(find "$WORK/ircheck" -type f | wc -l)
# 上限从 400 放宽到 800：nicbundle 本身带来 100+ 个文件
# （30 个 .ko + 77 个固件 + depmod 产物 + 2 个 etc 文件）。
# 「误打包了整机 rootfs」会立刻冲到几千个文件，800 依然能拦住。
[ "$IR_FILES" -lt 800 ] || die "initramfs 文件数异常 ($IR_FILES)，可能误打包了整机 rootfs"
ok "initramfs 回读通过（$IR_FILES 个文件）"
rm -rf "$WORK/ircheck"

# ------------------------------------------------------------------ grub.cfg
log "生成 grub.cfg"
# 三条硬约束，每条都对应一次真实的启动失败：
#  1. 双语菜单必须使用有效 UTF-8，无 BOM、无替换字符，同时加载中文字库
#     和 gfxterm。缺字库会显示问号；编码损坏可能令 menuentry 解析失败。
#  2. 不能用 `for x in (cd0) (hd0); do` —— 带括号的设备列表不是合法的
#     GRUB 迭代项，同样导致整段被丢弃。
#  3. 不能写死 set root=(cd0)/(hd0)。UEFI 下光驱常是 (cd0)，USB 下同一镜像
#     是 (hd0)，内置 eMMC 又可能挤占 (hd0)，编号会漂移。
#     用 search --file 按文件名定位，四类介质都能找到。
mkdir -p "$TREE/boot/grub/fonts"
cp "$ASSETSDIR/installer-grub.pf2" "$TREE/boot/grub/fonts/cjk.pf2"
cat > "$TREE/boot/grub/grub.cfg" <<CFG
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1 --rtscts=off
terminal_input console serial
terminal_output console serial
insmod all_video
insmod gfxterm
insmod font
if loadfont /boot/grub/fonts/cjk.pf2; then
    set gfxterm_font="Unifont Regular 16"
    set gfxmode=1024x768,800x600,auto
    if terminal_output gfxterm serial; then
        true
    else
        terminal_output gfxterm
    fi
fi

set timeout=8
set default=0

menuentry "安装系统 / Install $OS_NAME" {
    insmod part_msdos
    insmod part_gpt
    insmod iso9660
    insmod search_fs_file
    search --no-floppy --file --set=root /boot/initrd.gz
    echo "安装介质 / installer medium: \$root"
    echo "加载内核 / Loading kernel ..."
    linux /boot/vmlinuz console=ttyS0,115200n8 console=tty0
    echo "加载安装载荷，请稍候 / Loading installer payload ..."
    initrd /boot/initrd.gz
}

menuentry "串口安装 / Install $OS_NAME (serial console)" {
    insmod part_msdos
    insmod part_gpt
    insmod iso9660
    insmod search_fs_file
    search --no-floppy --file --set=root /boot/initrd.gz
    echo "安装介质 / installer medium: \$root"
    echo "加载内核 / Loading kernel ..."
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    echo "加载安装载荷，请稍候 / Loading installer payload ..."
    initrd /boot/initrd.gz
}

menuentry "救援终端 / Rescue shell" {
    insmod part_msdos
    insmod part_gpt
    insmod iso9660
    insmod search_fs_file
    search --no-floppy --file --set=root /boot/initrd.gz
    echo "安装介质 / installer medium: \$root"
    echo "加载内核 / Loading kernel ..."
    linux /boot/vmlinuz console=ttyS0,115200n8 console=tty0 installer.rescue=1
    echo "加载安装载荷，请稍候 / Loading installer payload ..."
    initrd /boot/initrd.gz
}

menuentry "重新启动 / Reboot" {
    reboot
}
CFG
ok "grub.cfg $(stat -c %s "$TREE/boot/grub/grub.cfg") 字节"

# 构建期就拦住这三类错误，不要等到引导时才发现
python3 - "$TREE/boot/grub/grub.cfg" <<'CHECK_UTF8'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_bytes().decode('utf-8','strict')
assert not s.startswith(chr(0xfeff)) and chr(0xfffd) not in s, 'Invalid GRUB UTF-8 text'
assert 'loadfont /boot/grub/fonts/cjk.pf2' in s and 'gfxterm' in s
CHECK_UTF8
grep -qE '^[[:space:]]*for[[:space:]]+[A-Za-z_]+[[:space:]]+in[[:space:]].*\((cd|hd)[0-9]' \
    "$TREE/boot/grub/grub.cfg" \
    && die "grub.cfg 里有非法的 for 设备列表 —— GRUB 会报 syntax error"
grep -q '^ *linux /boot/vmlinuz ' "$TREE/boot/grub/grub.cfg" \
    || die "grub.cfg 缺 linux 行"
grep -q '^ *initrd /boot/initrd.gz' "$TREE/boot/grub/grub.cfg" \
    || die "grub.cfg 缺 initrd 行"
ok "grub.cfg 编码与引导检查通过（UTF-8及中文字库 / 无非法 for / 有 linux+initrd）"

cp "$BOOTSRC/boot/vmlinuz" "$TREE/boot/vmlinuz"

# ------------------------------------------------------------------ 出 ISO
log "grub-mkrescue 生成混合引导 ISO"
mkdir -p "$(dirname "$OUTISO")"
TMPISO=$WORK/out.iso
rm -f "$TMPISO"
grub-mkrescue -o "$TMPISO" "$TREE" \
    -- -volid "$VOLID" -joliet on -rockridge on \
    >"$WORK/mkrescue.log" 2>&1 \
    || { tail -40 "$WORK/mkrescue.log" >&2; die "grub-mkrescue 失败"; }
[ -f "$TMPISO" ] || die "grub-mkrescue 没有产出 ISO"
ok "ISO $(stat -c %s "$TMPISO") 字节"

# ------------------------------------------------------------------ 自校验
log "ISO 结构自校验"

SIG=$(dd if="$TMPISO" bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d ' \n')
[ "$SIG" = "55aa" ] || die "MBR 缺少 55AA 签名（实际 $SIG）—— dd 到 U 盘无法启动"
BOOTSUM=$(dd if="$TMPISO" bs=1 count=440 status=none | od -An -tu1 | tr -s ' ' '\n' \
          | awk '{s+=$1} END{print s+0}')
[ "$BOOTSUM" -gt 0 ] || die "MBR 引导代码全零 —— BIOS 会跳进空白"
PTYPE=$(dd if="$TMPISO" bs=1 skip=450 count=1 status=none | od -An -tx1 | tr -d ' \n')
[ "$PTYPE" != "00" ] || die "MBR 分区表为空 —— dd 到 U 盘无法启动"
ok "MBR 可引导：签名=$SIG 引导代码和=$BOOTSUM 分区类型=0x$PTYPE"

ET=$WORK/eltorito.txt
xorriso -indev "$TMPISO" -report_el_torito plain >"$ET" 2>/dev/null || true
grep -q 'El Torito boot img.*BIOS' "$ET" || die "缺少 BIOS El Torito 条目"
grep -q 'El Torito boot img.*UEFI' "$ET" || die "缺少 UEFI El Torito 条目"
ok "El Torito 双引导（BIOS + UEFI）"

VOLID_GOT=$(xorriso -indev "$TMPISO" -pvd_info 2>/dev/null | grep -i 'volume id' \
            | sed 's/.*:[[:space:]]*//' | tr -d '\n\r')
[ "$VOLID_GOT" = "$VOLID" ] || die "卷标应为 $VOLID，实际 '$VOLID_GOT'"
ok "卷标 $VOLID_GOT"

EX=$WORK/ex
rm -rf "$EX"; mkdir -p "$EX"
xorriso -osirrox on -indev "$TMPISO" -extract / "$EX" >/dev/null 2>&1 \
    || die "ISO 展开失败"
for f in boot/vmlinuz boot/initrd.gz boot/grub/grub.cfg; do
    [ -f "$EX/$f" ] || die "ISO 内缺少 /$f"
done
[ "$(sha256sum "$EX/boot/vmlinuz" | awk '{print $1}')" = "$KERNEL_SHA_EXPECT" ] \
    || die "ISO 内内核不是实机内核"
[ "$(stat -c %s "$EX/boot/initrd.gz")" = "$INITRD_SIZE" ] \
    || die "ISO 内 initrd.gz 大小不符"

mkdir -p "$WORK/irverify"
( cd "$WORK/irverify" && gzip -dc "$EX/boot/initrd.gz" | cpio -idm --quiet ) \
    || die "ISO 内 initrd 回读失败"
for m in bios uefi; do
    [ -f "$WORK/irverify/installer/$m.img.gz" ] \
        || die "ISO 内 initrd 不含 $m.img.gz —— 载荷没打进去"
done
( cd "$WORK/irverify/installer" && sha256sum -c --quiet SHA256SUMS ) \
    || die "ISO 内 initrd 载荷校验失败"
# NIC-SPEC 2.4 的最后一道：从 ISO 里剥出来的 initramfs，网卡 bundle 还得在
[ -s "$WORK/irverify/lib/modules/$KVER/modules.dep" ] \
    || die "ISO 内 initrd 缺 lib/modules/$KVER/modules.dep —— 网卡驱动没进镜像"
[ "$(wc -l < "$WORK/irverify/etc/nic-load.order" 2>/dev/null || echo 0)" -ge 1 ] \
    || die "ISO 内 initrd 缺 etc/nic-load.order —— ethN 编号对不上"
[ -d "$WORK/irverify/lib/firmware" ] \
    || die "ISO 内 initrd 缺 lib/firmware"
for m in e1000 igb; do
    [ -f "$WORK/irverify/lib/modules/$KVER/$m.ko" ] \
        || die "ISO 内 initrd 缺 $m.ko"
done
ok "ISO 内 initrd 自带双载荷 + 网卡 bundle，并通过校验"
rm -rf "$WORK/irverify" "$EX"

ISO_BYTES=$(stat -c %s "$TMPISO")
[ "$ISO_BYTES" -lt 400000000 ] || die "ISO 异常膨胀 ($ISO_BYTES)"
info "ISO 大小 $((ISO_BYTES / 1048576)) MiB"

# ------------------------------------------------------------------ 落盘
log "落盘"
if [ -n "$SYNC_STATE_SHA" ]; then
    [ "$(sha256sum "$SYNC_STATE" | awk '{print $1}')" = "$SYNC_STATE_SHA" ] \
        || die '构建期间开发同步状态发生变化，拒绝发布旧快照；请重新生成载荷。'
fi
mv -f "$TMPISO" "$OUTISO"
chmod 0644 "$OUTISO"
FINAL_SHA=$(sha256sum "$OUTISO" | awk '{print $1}')
FINAL_SIZE=$(stat -c %s "$OUTISO")
printf '%s  %s\n' "$FINAL_SHA" "$(basename "$OUTISO")" > "$OUTISO.sha256"

{
    printf 'iso=%s\n'              "$(basename "$OUTISO")"
    printf 'release_version=%s\n'  "$RELEASE_VERSION"
    printf 'iso_bytes=%s\n'        "$FINAL_SIZE"
    printf 'iso_sha256=%s\n'       "$FINAL_SHA"
    printf 'generator=grub-mkrescue (isohybrid MBR + El Torito BIOS/UEFI)\n'
    printf 'boot=initramfs with embedded payload (no external root device)\n'
    printf 'kernel_sha256=%s\n'    "$KERNEL_SHA_EXPECT"
    printf 'kernel_bytes=%s\n'     "$(stat -c %s "$BOOTSRC/boot/vmlinuz")"
    printf 'initrd_bytes=%s\n'     "$INITRD_SIZE"
    for m in bios uefi; do
        printf '%s_img_sha256=%s\n' "$m" "$(sha256sum "$BODY/$m.img.gz" | awk '{print $1}')"
        printf '%s_raw_sha256=%s\n' "$m" "$(cat "$BODY/$m.img.raw-sha256")"
        printf '%s_raw_bytes=%s\n'  "$m" "$(cat "$BODY/$m.img.bytes")"
    done
    printf 'built_utc=%s\n'        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUTISO.installer-manifest.txt"

if [ -n "$SYNC_STATE_SHA" ]; then
    sed -n 's/.*"code_signature"[[:space:]]*:[[:space:]]*"\([a-f0-9]*\)".*/source_code_signature=\1/p' "$SYNC_STATE" >> "$OUTISO.installer-manifest.txt"
    if [ "$PUBLISH_RELEASE" = 1 ]; then
        sed 's/"iso_rebuild_required"[[:space:]]*:[[:space:]]*true/"iso_rebuild_required": false/' "$SYNC_STATE" > "$SYNC_STATE.new"
        mv -f "$SYNC_STATE.new" "$SYNC_STATE"
    fi
fi

log "完成"
printf '  ISO    : %s\n' "$OUTISO"
printf '  大小   : %s 字节 (%s MiB)\n' "$FINAL_SIZE" "$((FINAL_SIZE / 1048576))"
printf '  SHA256 : %s\n' "$FINAL_SHA"
printf '\n  下一步：\n'
printf '    python3 %s/check-iso.py "%s"\n' "$SRCDIR" "$OUTISO"
printf '    bash %s/verify-e2e.sh\n' "$SRCDIR"
