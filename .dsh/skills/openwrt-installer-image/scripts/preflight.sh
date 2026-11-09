#!/bin/bash
# =============================================================================
# preflight.sh —— 构建环境体检（30 秒内判断「能不能开工」）
#
# 作用：在做任何构建/验证之前，一次性检查所有前置条件。
# 常见失败都是环境问题（缺包、缺 KVM、磁盘满、目录被删），
# 提前查出来比跑到一半失败省事得多。
#
# 用法：bash preflight.sh [--fix]
#   --fix  对可自动修复的项（缺 apt 包）尝试安装
#
# 退出码：0 可开工，1 有阻塞项
# =============================================================================
set -uo pipefail
export LC_ALL=C

STAGE=${STAGE:-/home/openwrt/router-build}
BODY=${BODY:-$STAGE/out}
KEEP=${KEEP:-/home/openwrt/keepbin}
SRCDIR=${SRCDIR:-$(cd "$(dirname "$0")" && pwd)}
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

pass=0; warn=0; fail=0
P(){ pass=$((pass+1)); printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
W(){ warn=$((warn+1)); printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
F(){ fail=$((fail+1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
S(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

S "1. 系统与权限"
if [ "$(id -u)" = 0 ]; then P "以 root 运行"; else W "非 root：loop 挂载、mke2fs、losetup 会失败"; fi
arch=$(uname -m)
[ "$arch" = x86_64 ] && P "架构 $arch" || F "需要 x86_64，实际 $arch"

S "2. 必需工具"
declare -A PKG=(
  [busybox]=busybox-static [cpio]=cpio [gzip]=gzip [xorriso]=xorriso
  [grub-mkrescue]=grub-common [mkfs.vfat]=dosfstools [mcopy]=mtools
  [mke2fs]=e2fsprogs [sgdisk]=gdisk [sfdisk]=fdisk [dd]=coreutils
  [sha256sum]=coreutils [od]=coreutils [gawk]=gawk [qemu-system-x86_64]=qemu-system-x86
  [python3]=python3 [losetup]=util-linux [mount]=util-linux
)
missing_pkgs=()
for c in "${!PKG[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
        :
    else
        F "缺命令 $c （apt install ${PKG[$c]}）"
        missing_pkgs+=("${PKG[$c]}")
    fi
done
[ "${#missing_pkgs[@]}" -eq 0 ] && P "全部 ${#PKG[@]} 个命令就绪"

S "3. 专项依赖"
if python3 -c 'import pexpect' 2>/dev/null; then
    P "python3-pexpect $(python3 -c 'import pexpect;print(pexpect.__version__)' 2>/dev/null)"
else
    F "缺 python3-pexpect（apt install python3-pexpect）—— verify-e2e.sh 必需"
    missing_pkgs+=(python3-pexpect)
fi
if [ -d /usr/lib/grub/i386-pc ] && [ -d /usr/lib/grub/x86_64-efi ]; then
    P "grub 模块目录齐全（i386-pc + x86_64-efi）"
else
    F "缺 grub 模块目录（apt install grub-pc-bin grub-efi-amd64-bin）"
    missing_pkgs+=(grub-pc-bin grub-efi-amd64-bin)
fi
[ -f /usr/lib/grub/i386-pc/boot_hybrid.img ] \
    && P "boot_hybrid.img 就位（isohybrid MBR 必需）" \
    || F "缺 boot_hybrid.img，grub-mkrescue 无法产出可引导 MBR"
if [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] && [ -f /usr/share/OVMF/OVMF_VARS_4M.fd ]; then
    P "OVMF 就位（UEFI 场景必需）"
else
    F "缺 OVMF（apt install ovmf）—— cdrom-uefi / usb-uefi 场景必需"
    missing_pkgs+=(ovmf)
fi
if [ -e /dev/kvm ]; then
    P "/dev/kvm 就位"
else
    F "缺 /dev/kvm —— 没有 KVM 时 QEMU 会慢到无法完成验证"
fi

if [ "${#missing_pkgs[@]}" -gt 0 ] && [ "$FIX" = 1 ]; then
    S "尝试安装缺失包"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y -q update >/tmp/preflight-apt.log 2>&1
    # shellcheck disable=SC2206
    uniq_pkgs=($(printf '%s\n' "${missing_pkgs[@]}" | sort -u))
    if apt-get -y -q install "${uniq_pkgs[@]}" >>/tmp/preflight-apt.log 2>&1; then
        P "已安装：${uniq_pkgs[*]}（请重跑 preflight 确认）"
    else
        F "安装失败，见 /tmp/preflight-apt.log"
    fi
fi

S "4. 输入数据"
if [ -d "$STAGE/rootfs" ]; then
    n=$(find "$STAGE/rootfs" -type f 2>/dev/null | wc -l)
    P "rootfs 存在（$n 个文件，$(du -sh "$STAGE/rootfs" 2>/dev/null | cut -f1)）"
    for d in dev proc sys; do
        [ -d "$STAGE/rootfs/$d" ] && P "rootfs/$d 存在" \
            || F "rootfs 缺 /$d —— 会让 preinit 卡在 can't create /dev/null"
    done
    [ -d "$STAGE/rootfs/srv/console-situational" ] \
        && P "态势感知数据库就位" || F "缺 srv/console-situational"
    [ -f "$STAGE/rootfs/srv/console-security/traffic.db" ] \
        && P "traffic.db 就位" || F "缺 srv/console-security/traffic.db"
    [ -e "$STAGE/rootfs/etc/console-vpn" ] \
        && F "rootfs 仍含 /etc/console-vpn —— VPN 私钥未移除" \
        || P "VPN 私钥已移除"
    [ -e "$STAGE/rootfs/etc/console-security/guard.nft" ] \
        && F "rootfs 仍含地区规则 guard.nft" || P "地区规则已移除"
else
    F "缺 $STAGE/rootfs —— 先从实机同步"
fi

if [ -f "$STAGE/bootsrc/boot/vmlinuz" ]; then
    sha=$(sha256sum "$STAGE/bootsrc/boot/vmlinuz" | awk '{print $1}')
    sz=$(stat -c %s "$STAGE/bootsrc/boot/vmlinuz")
    if [ "$sha" = "fd30ff912bb85231593f5bed5b34ed06bd4daf1793089437b02b7d5c6be007b2" ]; then
        P "内核是实机内核（$sz 字节 sha=${sha:0:16}）"
    else
        F "内核 sha 不是实机内核（$sha）—— 会导致 kernel panic"
    fi
else
    F "缺 $STAGE/bootsrc/boot/vmlinuz"
fi

S "5. 载荷"
if [ -f "$BODY/bios.img.gz" ] && [ -f "$BODY/uefi.img.gz" ]; then
    for m in bios uefi; do
        ok=1
        for s in img.gz img.bytes img.raw-sha256; do
            [ -f "$BODY/$m.$s" ] || { F "缺 $m.$s"; ok=0; }
        done
        [ "$ok" = 1 ] || continue
        b=$(cat "$BODY/$m.img.bytes")
        a=$(gzip -dc "$BODY/$m.img.gz" 2>/dev/null | wc -c)
        if [ "$b" = "$a" ]; then
            P "$m 载荷元数据自洽（$((b/1048576)) MiB）"
        else
            F "$m.img.bytes=$b 与实际 $a 不一致 —— 元数据过期"
        fi
    done
else
    F "缺载荷 $BODY/*.img.gz —— 先跑 build-payload.sh"
fi

for f in openwrt-x86-64-generic-ext4-combined.img.gz \
         openwrt-x86-64-generic-ext4-combined-efi.img.gz; do
    [ -f "$KEEP/$f" ] && P "上游镜像 $f 就位" || W "缺 $KEEP/$f（仅 build-payload.sh 需要）"
done

S "6. 磁盘空间"
avail=$(df -Pk "$(dirname "$STAGE")" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
if [ -n "${avail:-}" ]; then
    if [ "$avail" -ge 12 ]; then
        P "可用空间 ${avail} GiB"
    elif [ "$avail" -ge 6 ]; then
        W "可用空间仅 ${avail} GiB —— 6 GiB raw 镜像 + gz 会紧张，建议先清理"
    else
        F "可用空间只有 ${avail} GiB —— 不足以生成 6 GiB raw 镜像"
    fi
fi
tmpsz=$(df -Pk /tmp | awk 'NR==2{print int($4/1048576)}')
[ "${tmpsz:-0}" -ge 2 ] && P "/tmp 可用 ${tmpsz} GiB" \
    || W "/tmp 只有 ${tmpsz} GiB；若 /tmp 是 tmpfs，构建时请设 TMPDIR 到大分区"
if losetup -f >/dev/null 2>&1; then
    P "losetup 可用"
else
    F "losetup 不可用 —— 无法挂载镜像做校验"
fi

S "7. 残留进程"
# 注意：pgrep -c 无匹配时既输出 "0" 又返回退出码 1，
# 写成 `pgrep -c ... || echo 0` 会打印两行 "0" 并把判断搞坏。先赋值再清洗。
n=$(pgrep -fc 'qemu-system-x86' 2>/dev/null || true)
n=$(printf '%s' "${n:-0}" | tr -dc '0-9')
n=${n:-0}
if [ "$n" -eq 0 ]; then
    P "没有残留 QEMU"
else
    W "有 $n 个 QEMU 在跑 —— 会锁定镜像文件，导致 'Failed to get write lock'。执行：pkill -9 -f qemu-system"
fi

S "8. 脚本"
for s in check-iso.py build-iso.sh build-payload.sh verify-e2e.sh \
         init-installer.sh installer.sh; do
    [ -f "$SRCDIR/$s" ] && P "$s" || F "缺 $SRCDIR/$s"
done

# ------------------------------------------------------------------ 汇总
S "汇总"
printf '  ok=%d  warn=%d  fail=%d\n' "$pass" "$warn" "$fail"
if [ "$fail" -eq 0 ]; then
    printf '\n\033[32m可开工。\033[0m\n'
    exit 0
else
    printf '\n\033[31m有 %d 项阻塞，先修再构建。\033[0m\n' "$fail"
    [ "$FIX" = 0 ] && printf '部分缺包可以自动装：bash %s --fix\n' "$0"
    exit 1
fi
