#!/bin/bash
# =============================================================================
# build-payload.sh —— 从 192 实机快照重新生成安装载荷（bios.img.gz / uefi.img.gz）
#                     以及安装器的网卡驱动 bundle（nicbundle.tar.gz）
#
# 什么时候需要跑它：
#   · 实机 rootfs 有更新（改了 UI、加了数据库、换了配置）
#   · 要改根分区大小、要改移除/保留的内容范围
#   · 内核换了
#
# 什么时候不用跑：
#   只改安装器本身（init-installer.sh / installer.sh / grub.cfg）
#   —— 那种情况直接 bash build-iso.sh 就行，载荷可以复用。
#
# 输入（都在 STAGE 下）：
#   rootfs/     192 实机的根文件系统（不含 /boot，不含 /dev /proc /sys 内容）
#   bootsrc/    192 实机的 /boot（实机内核 + grub 文件）
#
# 输出（都在 OUT 下）：
#   bios.img.gz / uefi.img.gz（+ .bytes / .raw-sha256）  安装载荷
#   nicbundle.tar.gz                                      网卡驱动 bundle（NIC-SPEC 1.1）
#
# 关键约束（每条都对应一次真实故障）：
#   1. 内核必须用实机的。上游镜像的 vmlinuz 大小接近、vermagic 相同，
#      但配 192 的 rootfs 会在启动 9 秒时 nf_defrag_ipv6_disable 处 panic。
#   2. rootfs 必须显式补出 /dev /proc /sys 目录和静态设备节点。
#      打包时排除它们会导致 preinit 报
#      "can't create /dev/null: nonexistent directory" 并卡死。
#   3. UEFI 的 ESP 必须是 FAT(vfat)，不能是 ext4。
#      UEFI 固件只能读 FAT，否则报
#      'failed to load Boot0001 "UEFI QEMU HARDDISK" ...: Not Found'
#      然后回退 PXE / 掉进 EFI Shell。
#   4. GPT 镜像要给备份 GPT 留尾部空间（GPT_TAIL=34 扇区），
#      否则 sgdisk 报 "Could not create partition 2"。
#   5. dd 的子分区起点不一定 MiB 对齐，必须用 bs=1M oflag=seek_bytes seek=$((LBA*512))，
#      不能写 seek=$((LBA/2048))。
#   6. nicbundle 里的加载顺序必须照抄 rootfs/etc/modules.d 的文件名序，
#      否则安装器看到的 ethN 与装好后系统里的 ethN 会对不上（详见 NIC-SPEC 1.3）。
#
# 用法：
#   bash build-payload.sh                    # 全量（约 5 分钟，会生成 6 GiB 镜像）
#   bash build-payload.sh --root-mib 8192
#   bash build-payload.sh --nic-only         # 只重生成 nicbundle.tar.gz（几秒）
#   bash build-payload.sh --os-name AOS-20261109-V1   # 改系统名（菜单+内部版本）
#
# --os-name 同时决定：装好后**硬盘上 GRUB 菜单的条目名**、以及**系统内部自报的
# 版本**（etc/console-version、os-release、openwrt_release、banner）。
# 不传则沿用 OS_NAME 环境变量或默认值。名字会写进 $OUT/os-name.txt 供
# build-iso.sh 核对，确保「安装盘菜单」与「装完后的菜单」是同一个名字。
# =============================================================================
set -euo pipefail
export LC_ALL=C
umask 022

STAGE=${STAGE:-/home/openwrt/router-build}
ROOTFS=${ROOTFS:-$STAGE/rootfs}
BOOTSRC=${BOOTSRC:-$STAGE/bootsrc}
OUT=${OUT:-$STAGE/out}
KEEP=${KEEP:-/home/openwrt/keepbin}       # 上游 official 镜像（取 bootx64.efi 与 core.img）
WORK=${WORK:-/home/openwrt/imgwork}

BOOT_MIB=${BOOT_MIB:-32}
ROOT_MIB=${ROOT_MIB:-6144}                # 根分区大小，6 GiB
BIOS_P1=${BIOS_P1:-512}
UEFI_P1=${UEFI_P1:-512}
P128=${P128:-34}
P128_SECT=${P128_SECT:-478}
GPT_TAIL=${GPT_TAIL:-34}
MTOOLS_SKIP_CHECK=1
export MTOOLS_SKIP_CHECK

KERNEL_SHA_EXPECT=${KERNEL_SHA_EXPECT:-fd30ff912bb85231593f5bed5b34ed06bd4daf1793089437b02b7d5c6be007b2}
# 落盘自校验要核对 vpn-service.uc 的版本；原先只在 build-iso.sh 里定义，
# 在 set -u 下直接跑 build-payload.sh 会因未绑定变量而中断，这里补上同一个默认值。
EXPECT_VPN_SHA=${EXPECT_VPN_SHA:-11b80e1cc4999fc14f02b0738d02710db3481a5841eb8fbf703641e6a42fedf1}

# ---------------------------------------------------------------- 网卡 bundle 参数
KVER=${KVER:-6.18.55}
# NIC-SPEC 1.2 的允许集合，仅作为**依赖闭包的种子**（不直接写进 nic-allowlist）。
# 这里在 rootfs 里不存在的名字会被静默跳过 —— NIC-SPEC 1.2 明确要求不报错。
# 本 rootfs（6.18.55）里不存在的是这 5 个：bnx2x atlantic dwmac-sti vmxnet3 rtl8152。
# 它们只是为「换内核后驱动集合变大」预留的种子。
NIC_SEEDS=${NIC_ALLOWLIST:-"
igb igc ixgbe e1000 e1000e tg3 bnx2 bnx2x forcedeth r8169 realtek atlantic
amd-xgbe stmmac stmmac-platform dwmac-generic dwmac-intel dwmac-sti
ena vmxnet3 usbnet asix ax88179_178a ax88796b r8152 rtl8152
mii libphy mdio mdio-bus mdio_devres pcs_xpcs phylink
libie_fwlog"}
# ---------------------------------------------------------------------------
# 为什么必须带 selftests.ko —— 别当垃圾清掉
#
# rootfs 里 asix.ko（USB 网卡）的 modinfo depends **硬包含 selftests**：
#     asix.ko: selftests.ko usbnet.ko mii.ko phylink.ko libphy.ko mdio-bus.ko
# 这是 kmod-net-selftests（12 KiB，不是内核自测工具集那么吓人，只是 netdev
# selftest 的挂钩代码）。modprobe 会严格按 modules.dep 的依赖顺序先加载它，
# 缺了它 asix.ko 直接 insmod 失败，于是 USB 网卡在安装环境里彻底看不到。
#
# 为什么**不能裁剪**：这个依赖是 asix.ko 的 ELF 里写死的 symbol 依赖
# （depends 来自 modinfo，不是我们排的顺序）。想裁掉它只能丢掉 asix 整个模块，
# 要么就得重编内核模块 —— 都不现实。12 KiB 换 USB 网卡可用，很划算。
#
# 它会以"非网络直系模块"的身份出现在 allowlist 里，这是**正确**的：
# allowlist 只装 bundle 里真实存在的东西，selftests 确实是其中之一。
NIC_EXTRA_ALLOW=${NIC_EXTRA_ALLOW:-selftests}
NIC_BUNDLE_MAX=$((8 * 1024 * 1024))       # NIC-SPEC 1.1：≤ 8 MiB

# ---------------------------------------------------------------------------
# 系统名称（发行版标识）
#
# 一个变量同时决定两件用户可见的事，必须成对一致：
#   1. 装好之后**硬盘上** GRUB 菜单的条目名（本脚本生成 grub-bios.cfg / grub-uefi.cfg）
#   2. 装好之后**系统内部**自报的版本（brand-rootfs.py 写 console-version /
#      os-release / openwrt_release / banner）
# build-iso.sh 会核对本脚本落下的 out/os-name.txt，防止「安装盘菜单是一个名字、
# 装完启动是另一个名字」这种各自为政的情况。
#
# 刻意做成**显式开启**（不传 --os-name / OS_NAME 就不改名）：
#   普通重建（只因 rootfs 有更新）如果不传名字，rootfs 的 OpenWrt 标识应保持
#   原样 —— 悄悄改写 etc/os-release 属于「重建个镜像结果系统身份变了」，
#   那种副作用必须在命令行上看得见，不能靠默认值发生。
# ---------------------------------------------------------------------------
OS_NAME=${OS_NAME:-}
# 不改名时磁盘菜单沿用的传统名字（与历史镜像一致，避免默认值抖动）
OS_NAME_DEFAULT='OpenWrt Console'

NIC_ONLY=0

while [ $# -gt 0 ]; do
    case $1 in
        --root-mib)   ROOT_MIB=$2; shift 2 ;;
        --boot-mib)   BOOT_MIB=$2; shift 2 ;;
        --out)        OUT=$2; shift 2 ;;
        --os-name)    OS_NAME=$2; shift 2 ;;
        --nic-only)   NIC_ONLY=1; shift ;;
        -h|--help)    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

BRAND_SYSTEM=0
if [ -n "$OS_NAME" ]; then
    BRAND_SYSTEM=1
else
    OS_NAME=$OS_NAME_DEFAULT
fi

# 装好后的 grub.cfg 必须纯 ASCII（GRUB 解析器），因此名字也限定 ASCII。
case "$OS_NAME" in
    '') die 'OS_NAME 不能为空' ;;
    *[!A-Za-z0-9._\ -]*) die "OS_NAME 只允许 ASCII 字母、数字、点、下划线、短横线、空格：$OS_NAME" ;;
esac

BOOT_SECT=$((BOOT_MIB * 2048))
ROOT_SECT=$((ROOT_MIB * 2048))
BIOS_P2=$((BIOS_P1 + BOOT_SECT))
UEFI_P2=$((UEFI_P1 + BOOT_SECT))

log(){  printf '\n\033[1m[payload] %s\033[0m\n' "$*"; }
ok(){   printf '  [ok] %s\n' "$*"; }
info(){ printf '  %s\n' "$*"; }
warn(){ printf '  [warn] %s\n' "$*"; }
die(){  printf '\n[payload] ERROR: %s\n' "$*" >&2; exit 1; }

SYNC_STATE=$STAGE/development-sync-state.json
SYNC_STATE_SHA=''
if [ -f "$SYNC_STATE" ]; then
    SYNC_STATE_SHA=$(sha256sum "$SYNC_STATE" | awk '{print $1}')
fi

# =============================================================================
# 网卡驱动 bundle（NIC-SPEC 第 1 节）
#
# 产物 nicbundle.tar.gz 解压到 initramfs 的 / 之后形成：
#   lib/modules/$KVER/*.ko         允许集合 + 依赖闭包
#   lib/modules/$KVER/modules.dep  depmod 现生成（rootfs 里原本没有）
#   lib/modules/$KVER/modules.alias
#   lib/firmware/**                整个 rootfs/lib/firmware 原样
#   etc/nic-load.order             NIC-SPEC 1.3，决定 ethN 编号
#   etc/nic-allowlist              NIC-SPEC 1.2，逗号分隔，供 /init 兜底 modprobe
#
# 三个必须记住的坑：
#  1. rootfs 只有 modules.builtin（299 行，每行只有 "xxx.ko"、没有路径），
#     没有 modules.dep / modules.alias / modules.order —— 依赖关系必须现用 depmod 生成。
#  2. 那个 modules.builtin 会让 depmod 报
#     "Invalid modules.builtin line: 8250.ko"；把每行规范成 kernel/xxx.ko 后 ERRORS 归零，
#     仍是 depmod 自己算出来的 modules.dep，不是手搓的。
#  3. 加载顺序不能自己排。装完系统开机时 /sbin/kmodloader 按 rootfs/etc/modules.d
#     的文件名序逐行加载，这里必须用同一份顺序，否则 ethN 编号会错位。
# =============================================================================
build_nicbundle(){
    local MODDIR=$ROOTFS/lib/modules/$KVER
    local NB=$WORK/nic
    local DEPROOT=$NB/deproot
    local STG=$NB/stage
    local CHK=$NB/check
    local DEPLOG=$NB/depmod.log
    local BUNDLE=$OUT/nicbundle.tar.gz

    log "网卡驱动 bundle（$KVER）"

    [ -d "$MODDIR" ] || die "缺少模块目录 $MODDIR —— 无法生成网卡 bundle"
    [ -d "$ROOTFS/lib/firmware" ] \
        || die "缺少 $ROOTFS/lib/firmware —— NIC-SPEC 1.1 要求整个固件目录原样带上"

    local nko
    nko=$(find "$MODDIR" -maxdepth 1 -name '*.ko' | wc -l)
    [ "$nko" -gt 0 ] || die "$MODDIR 下没有任何 .ko"
    info "rootfs 模块目录：$nko 个 .ko，$(du -sh "$ROOTFS/lib/firmware" | cut -f1) 固件"

    rm -rf "$NB"; mkdir -p "$DEPROOT/lib/modules/$KVER" "$STG/lib/modules/$KVER" "$CHK"

    # ---------------- 1) depmod 现生成依赖关系（输出目录每次清空重建，保证可重复）
    # 这一步跑的是 rootfs 里**全部** 83 个 .ko，目的是拿到真实依赖图；
    # 后面第 4 步会在筛选后的集合上再跑一次，让最终 modules.dep 只引用真正打进去的 .ko。
    find "$MODDIR" -maxdepth 1 -name '*.ko' -exec cp -a {} "$DEPROOT/lib/modules/$KVER/" \;
    if [ -f "$MODDIR/modules.builtin" ]; then
        # 规范成 kernel/xxx.ko：rootfs 那份每行只有裸文件名，depmod 认不出会报
        # "Invalid modules.builtin line: 8250.ko"。规范化后 ERROR 归零，
        # 但 modules.dep 仍然是 depmod 自己算出来的，不是手搓的。
        awk '{ if ($0 == "") next; if (index($0, "/") > 0) print; else print "kernel/" $0 }' \
            "$MODDIR/modules.builtin" > "$DEPROOT/lib/modules/$KVER/modules.builtin"
        info "modules.builtin 已规范化（$(wc -l < "$DEPROOT/lib/modules/$KVER/modules.builtin") 行）"
    fi
    : > "$DEPLOG"
    depmod -b "$DEPROOT" "$KVER" >>"$DEPLOG" 2>&1 || true
    local DEPFILE=$DEPROOT/lib/modules/$KVER/modules.dep
    if [ ! -s "$DEPFILE" ]; then
        tail -20 "$DEPLOG" | sed 's/^/    /' >&2 || true
        die "depmod 没能生成 modules.dep（日志 $DEPLOG）"
    fi
    local nerr
    nerr=$(grep -c 'ERROR' "$DEPLOG" || true)
    info "depmod（全量 83 个 .ko）生成 $(wc -l < "$DEPFILE") 行 modules.dep / \
$(wc -l < "$DEPROOT/lib/modules/$KVER/modules.alias") 行 modules.alias（ERROR $nerr 条）"
    [ "$nerr" = 0 ] || warn "depmod 日志里有 $nerr 条 ERROR，modules.dep 已生成，继续"

    # ---------------- 2) 允许集合 + 依赖闭包
    local -A DEPS_OF=()
    local -A CHOSEN=()
    local line tgt rest d m
    while IFS= read -r line; do
        tgt=${line%%:*}
        rest=${line#*:}
        tgt=${tgt##*/}; tgt=${tgt%.ko}
        local acc=""
        for d in $rest; do acc="$acc ${d##*/}"; done
        DEPS_OF[$tgt]=$acc
    done < "$DEPFILE"

    local -a QUEUE=()
    local extra_used=""
    for m in $NIC_SEEDS; do
        if [ -f "$DEPROOT/lib/modules/$KVER/$m.ko" ]; then
            CHOSEN[$m]=1; QUEUE+=("$m")
        else
            info "跳过 rootfs 里不存在的种子模块：$m（NIC-SPEC 1.2 允许）"
        fi
    done
    [ "${#QUEUE[@]}" -gt 0 ] || die "允许集合在 rootfs 里一个都找不到，检查 KVER=$KVER"

    local i=0
    local extra_set=" $NIC_EXTRA_ALLOW "
    while [ "$i" -lt "${#QUEUE[@]}" ]; do
        m=${QUEUE[$i]}; i=$((i + 1))
        for d in ${DEPS_OF[$m]:-}; do
            d=${d%.ko}
            [ -n "$d" ] || continue
            [ -z "${CHOSEN[$d]:-}" ] || continue
            [ -f "$DEPROOT/lib/modules/$KVER/$d.ko" ] || continue
            case "$extra_set" in
                *" $d "*) extra_used="$extra_used $d" ;;
            esac
            CHOSEN[$d]=1; QUEUE+=("$d")
        done
    done

    local -a KO_LIST=()
    for m in "${QUEUE[@]}"; do
        [ -f "$DEPROOT/lib/modules/$KVER/$m.ko" ] && KO_LIST+=("$m")
    done
    [ "${#KO_LIST[@]}" -gt 0 ] || die "依赖闭包展开后没有任何 .ko"
    info "选中 ${#KO_LIST[@]} 个 .ko（依赖闭包展开完成）"
    [ -z "$extra_used" ] || info "闭包额外带入（非直系但有硬依赖）：$extra_used"

    # NIC-SPEC 1.2 的红线：不许夹带无关大模块
    for m in i915 drm_buddy drm_display_helper drm_kms_helper ttm video wmi oaf \
             nf_tables nf_conntrack nft_ct nf_nat nfnetlink; do
        [ -z "${CHOSEN[$m]:-}" ] || die "闭包意外带进了 $m.ko —— NIC-SPEC 1.2 禁止"
    done

    for m in "${KO_LIST[@]}"; do
        cp -a "$DEPROOT/lib/modules/$KVER/$m.ko" "$STG/lib/modules/$KVER/"
    done
    # e1000.ko 是 verify-e2e.sh 的 QEMU 网卡驱动，igb.ko 是实机主网口，缺了这次改动就没意义
    for m in e1000 igb; do
        [ -f "$STG/lib/modules/$KVER/$m.ko" ] \
            || die "bundle 里缺 $m.ko —— QEMU e2e / 实机都依赖它"
    done

    # ---------------- 3) 在**筛选后的集合**上重跑 depmod
    # 关键：bundle 里的 modules.dep 只能引用 bundle 里真实存在的 .ko。
    # 直接搬全量那份会让 modprobe 去找 i915/nft_* 之类没带进来的文件，
    # 于是 modprobe 报 "not found"，/init 的 || true 吞掉，网口永远出不来。
    if [ -f "$DEPROOT/lib/modules/$KVER/modules.builtin" ]; then
        cp -a "$DEPROOT/lib/modules/$KVER/modules.builtin" "$STG/lib/modules/$KVER/"
    fi
    : > "$DEPLOG.2"
    depmod -b "$STG" "$KVER" >>"$DEPLOG.2" 2>&1 || true
    local DEPOUT=$STG/lib/modules/$KVER/modules.dep
    [ -s "$DEPOUT" ] || { tail -20 "$DEPLOG.2" | sed 's/^/    /' >&2 || true;
                          die "depmod（筛选后）没能生成 modules.dep"; }
    [ -s "$STG/lib/modules/$KVER/modules.alias" ] || die "depmod（筛选后）没生成 modules.alias"
    # 筛选后的 modules.dep 不许引用不存在的 .ko —— 这是整个 bundle 能否 modprobe 成功的判据
    local bad="" tko
    while IFS= read -r line; do
        for tko in ${line#*:}; do
            [ -f "$STG/lib/modules/$KVER/${tko##*/}" ] || bad="$bad ${tko##*/}"
        done
    done < "$DEPOUT"
    [ -z "$bad" ] || die "bundle 的 modules.dep 引用了未打包的 .ko:$bad"
    ok "depmod（筛选后）$(wc -l < "$DEPOUT") 行 modules.dep，全部指向已打包的 .ko"

    # ---------------- 4) etc/nic-load.order（NIC-SPEC 1.3）
    # 顺序 = rootfs/etc/modules.d 按文件名排序后，逐文件逐行取模块名，
    # 过滤掉不在允许集合/不在 bundle 里的，以及重复项。
    #
    # 注意「怎么切 token」：NIC-SPEC 1.3 的例子明确要求
    #   40-stmmac-core 的内容 `dwmac-generic stmmac stmmac-platform` 变成三行，
    # 而 e1000e 文件的内容 `e1000e IntMode=1 InterruptThrottleRate=4,4,4,4,4,4,4,4`
    # 只能得到 e1000e 一行 —— 含 '=' 的是模块参数不是模块名，遇到即停。
    # 这也正是装好后 /sbin/kmodloader 读同一份文件的解析方式。
    local ORDER=$STG/etc/nic-load.order
    mkdir -p "$STG/etc"
    : > "$ORDER"
    local MODSD=$ROOTFS/etc/modules.d
    local seen=" "
    if [ -d "$MODSD" ]; then
        local f tok
        while IFS= read -r f; do
            [ -f "$MODSD/$f" ] || continue
            while IFS= read -r line || [ -n "$line" ]; do
                for tok in $line; do
                    case $tok in '#'*) break ;; esac   # 行内注释：本行结束
                    case $tok in *=*)   break ;; esac   # 模块参数：本行结束
                    tok=${tok%.ko}
                    case "$seen" in *" $tok "*) continue ;; esac
                    [ -n "${CHOSEN[$tok]:-}" ] || continue
                    printf '%s\n' "$tok" >> "$ORDER"
                    seen="$seen$tok "
                done
            done < "$MODSD/$f"
        done < <(ls "$MODSD" | LC_ALL=C sort)
        info "nic-load.order 来源：$MODSD（$(ls "$MODSD" | wc -l) 个文件，文件名序）"
    else
        warn "$MODSD 不存在 —— nic-load.order 退化为按允许集合顺序"
        for m in "${KO_LIST[@]}"; do printf '%s\n' "$m" >> "$ORDER"; done
    fi
    [ "$(wc -l < "$ORDER")" -ge 1 ] || die "nic-load.order 为空 —— 装好后 ethN 编号无法对齐"

    # ---------------- 5) etc/nic-allowlist（NIC-SPEC 1.2）
    # 关键：allowlist **从实际打进去的 .ko 反推**，不用静态硬编码列表。
    # 原因是静态列表会与 bundle 内容漂移：换内核后某些种子模块不存在、
    # 或者名字和 .ko 文件名不一致（mdio_devres vs mdio-devres 这类），
    # 于是 /init 兜底 modprobe 一个不存在的名字 —— 不崩，但排查
    # 「为什么某块网卡没被识别」时会误导人浪费大量时间。
    #
    # 现在 allowlist 里的每个名字都必然对应 bundle 里一个真实 .ko 文件。
    # 下面第 8 步还会再断言一次（对着解包后的产物验），双保险。
    local -a AL_NAMES=()
    local al_seen=" "
    for m in "${KO_LIST[@]}"; do
        case "$al_seen" in *" $m "*) continue ;; esac
        [ -f "$STG/lib/modules/$KVER/$m.ko" ] || continue
        AL_NAMES+=("$m")
        al_seen="$al_seen$m "
    done
    [ "${#AL_NAMES[@]}" -ge 1 ] || die "nic-allowlist 反推结果为空 —— bundle 里没有 .ko？"
    printf '%s\n' "$(printf '%s\n' "${AL_NAMES[@]}" | paste -sd, -)" > "$STG/etc/nic-allowlist"
    [ "$(wc -l < "$STG/etc/nic-allowlist")" = 1 ] || die "nic-allowlist 必须是单行"
    if grep -q ' ' "$STG/etc/nic-allowlist"; then
        die "nic-allowlist 不能含空格"
    fi
    info "nic-allowlist 由 bundle 内 ${#AL_NAMES[@]} 个真实 .ko 反推生成"

    # ---------------- 6) 整个固件目录原样
    cp -a "$ROOTFS/lib/firmware" "$STG/lib/firmware"
    [ -d "$STG/lib/firmware" ] || die "bundle 内缺 lib/firmware"

    # ---------------- 7) 打包（成员为相对路径，无 ./ 前缀）
    rm -f "$BUNDLE"
    local tarbin
    tarbin=$(command -v tar)
    if "$tarbin" --version 2>/dev/null | grep -q 'GNU tar'; then
        ( cd "$STG" && "$tarbin" --create --gzip --file="$BUNDLE" \
              --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' \
              lib etc )
    else
        ( cd "$STG" && "$tarbin" -czf "$BUNDLE" lib etc )
    fi
    [ -s "$BUNDLE" ] || die "nicbundle.tar.gz 没生成出来"

    # ---------------- 8) 解包自校验（NIC-SPEC 1.1 的硬性指标）
    ( cd "$CHK" && gzip -dc "$BUNDLE" | "$tarbin" -xf - ) || die "nicbundle 解包失败"
    local chkdep=$CHK/lib/modules/$KVER/modules.dep
    [ -s "$chkdep" ] || die "解包后缺 lib/modules/$KVER/modules.dep"
    local ndep
    ndep=$(wc -l < "$chkdep")
    [ "$ndep" -gt 20 ] || die "modules.dep 只有 $ndep 行，太少（应包含整个依赖闭包）"
    [ -s "$CHK/etc/nic-load.order" ] || die "解包后缺 etc/nic-load.order"
    local norder
    norder=$(wc -l < "$CHK/etc/nic-load.order")
    [ "$norder" -ge 1 ] || die "etc/nic-load.order 是空的"
    [ -d "$CHK/lib/firmware" ] || die "解包后缺 lib/firmware"
    local nfw
    nfw=$(find "$CHK/lib/firmware" -type f | wc -l)
    [ "$nfw" -ge 1 ] || die "lib/firmware 是空目录"
    local nchkko
    nchkko=$(find "$CHK/lib/modules/$KVER" -maxdepth 1 -name '*.ko' | wc -l)
    [ "$nchkko" -ge 1 ] || die "解包后 .ko 数量为 0"
    for m in e1000 igb; do
        [ -f "$CHK/lib/modules/$KVER/$m.ko" ] || die "解包后缺 $m.ko"
    done

    # ---- allowlist 一致性断言（对着解包后的真实产物验，不信任生成过程）----
    # 每个名字都必须能在 bundle 的 lib/modules/$KVER/ 下找到同名 .ko。
    # 这条断言存在的原因：allowlist 是给 /init 兜底 modprobe 用的，
    # 写进一个不存在的名字不会崩（|| true），但会让排查网卡问题的人
    # 以为「驱动应该在、就是没加载」，白白浪费大量时间。
    # 以后换内核 / 换驱动集合时，这里会立刻报出来而不是静默退化。
    local al_bad="" al_n=0
    # 必须是单行：允许多个名字用逗号分隔，但不许出现换行
    [ "$(wc -l < "$CHK/etc/nic-allowlist")" = 1 ] \
        || die "nic-allowlist 必须是单行逗号分隔（实际 $(wc -l < "$CHK/etc/nic-allowlist") 行）"
    for al in $(tr ',' ' ' < "$CHK/etc/nic-allowlist"); do
        al_n=$((al_n + 1))
        if [ ! -f "$CHK/lib/modules/$KVER/$al.ko" ]; then
            al_bad="$al_bad $al"
        fi
    done
    [ "$al_n" -ge 1 ] || die "nic-allowlist 是空的"
    if [ -n "$al_bad" ]; then
        die "nic-allowlist 里有 $al_n 个名字中的以下项在 bundle 里找不到同名 .ko:$al_bad
  （bundle 实际含 $nchkko 个 .ko；allowlist 必须与之一一对应）"
    fi
    ok "nic-allowlist $al_n 个名字全部对应 bundle 内真实 .ko"

    # ---- nic-load.order 里的名字也必须在 bundle 里 ----
    local ord_bad=""
    while IFS= read -r om; do
        [ -n "$om" ] || continue
        [ -f "$CHK/lib/modules/$KVER/$om.ko" ] || ord_bad="$ord_bad $om"
    done < "$CHK/etc/nic-load.order"
    [ -z "$ord_bad" ] || die "nic-load.order 引用了 bundle 里不存在的模块:$ord_bad"

    # 顺序断言：tg3 必须早于 igc，igc 必须不晚于 igb（模块文件名数字序决定）
    local lt3 ligc ligb
    lt3=$(grep -n -x tg3   "$CHK/etc/nic-load.order" | cut -d: -f1 || true)
    ligc=$(grep -n -x igc  "$CHK/etc/nic-load.order" | cut -d: -f1 || true)
    ligb=$(grep -n -x igb  "$CHK/etc/nic-load.order" | cut -d: -f1 || true)
    if [ -n "$lt3" ] && [ -n "$ligc" ]; then
        [ "$lt3" -lt "$ligc" ] || die "nic-load.order 顺序错：tg3($lt3) 应在 igc($ligc) 之前"
    fi
    if [ -n "$ligc" ] && [ -n "$ligb" ]; then
        [ "$ligc" -lt "$ligb" ] || die "nic-load.order 顺序错：igc($ligc) 应在 igb($ligb) 之前"
    fi
    # tar 成员不允许有 ./ 前缀或绝对路径（解压到 / 会出歧义）
    # 注意：这里把清单先落到文件再 grep。直接 gzip | tar | grep -q 在 set -o pipefail
    # 下会因 grep 提前退出、gzip 收 SIGPIPE 而让整条管道返回非零，误判成“缺文件”。
    local LIST=$NB/bundle.list
    gzip -dc "$BUNDLE" | "$tarbin" -tf - > "$LIST"
    if grep -qE '^(\./|/)' "$LIST"; then
        die "nicbundle 成员路径带 ./ 或绝对路径 —— 解压到 / 会有歧义"
    fi
    tar_in_list(){ grep -qx -- "$1" "$LIST"; }
    tar_in_list etc/nic-allowlist                    || die "bundle 里缺 etc/nic-allowlist"
    tar_in_list "lib/modules/$KVER/modules.alias"    || die "bundle 里缺 modules.alias"
    tar_in_list "lib/modules/$KVER/modules.dep"      || die "bundle 里缺 modules.dep"
    tar_in_list "lib/modules/$KVER/e1000.ko"         || die "bundle 里缺 e1000.ko"
    tar_in_list "lib/modules/$KVER/igb.ko"           || die "bundle 里缺 igb.ko"

    local bytes
    bytes=$(stat -c %s "$BUNDLE")
    [ "$bytes" -le "$NIC_BUNDLE_MAX" ] \
        || die "nicbundle.tar.gz 体积 $bytes 字节（$((bytes / 1024)) KiB）超过 8 MiB 上限"
    ok "nicbundle.tar.gz $bytes 字节（$((bytes / 1024)) KiB，上限 8192 KiB）"
    ok "  .ko $nchkko 个 / modules.dep $ndep 行 / nic-load.order $norder 行 / 固件 $nfw 个文件"
    ok "  nic-allowlist $al_n 项，与 bundle 内 .ko 一一对应（无无效名字）"
    info "  nic-load.order 前 10 行："
    head -10 "$CHK/etc/nic-load.order" | sed 's/^/    /'
    info "  nic-allowlist: $(cat "$CHK/etc/nic-allowlist")"
    rm -rf "$NB"
}

# ------------------------------------------------------------------ 前置检查
log "前置检查"
[ -d "$ROOTFS" ] || die "缺少 rootfs: $ROOTFS"
for t in depmod tar gzip sha256sum; do
    command -v $t >/dev/null || die "缺工具 $t"
done

if [ "$NIC_ONLY" = 1 ]; then
    mkdir -p "$OUT" "$WORK"
    build_nicbundle
    log "--nic-only 完成 —— 只生成了 $OUT/nicbundle.tar.gz，未触碰 bios/uefi 镜像"
    exit 0
fi

[ -d "$BOOTSRC/boot" ] || die "缺少 bootsrc/boot: $BOOTSRC"
[ -f "$ROOTFS/boot/vmlinuz" ] && die "rootfs 里不该有 /boot（内核放引导分区）"
for d in dev proc sys; do
    [ -d "$ROOTFS/$d" ] || die "rootfs 缺 /$d —— 必须补出来，否则 preinit 卡死"
done
# 数据库是这次镜像的核心内容，缺了要立刻发现而不是等装完才察觉
for f in srv/console-security/traffic.db; do
    [ -f "$ROOTFS/$f" ] || die "rootfs 缺 $f —— 数据库没带进来"
done
[ -d "$ROOTFS/srv/console-situational" ] \
    || die "rootfs 缺 srv/console-situational —— 态势感知数据库没带进来"
for t in mkfs.vfat mcopy sgdisk sfdisk mke2fs; do
    command -v $t >/dev/null || die "缺工具 $t"
done
ok "目录与工具就绪"

KERNEL_SHA=$(sha256sum "$BOOTSRC/boot/vmlinuz" | awk '{print $1}')
[ "$KERNEL_SHA" = "$KERNEL_SHA_EXPECT" ] \
    || die "内核不是 192 实机内核：$KERNEL_SHA"
ok "实机内核 $(stat -c %s "$BOOTSRC/boot/vmlinuz") 字节 sha=${KERNEL_SHA:0:16}"

[ -f "$KEEP/openwrt-x86-64-generic-ext4-combined.img.gz" ] \
    || die "缺少上游 BIOS 镜像 $KEEP/...ext4-combined.img.gz"
[ -f "$KEEP/openwrt-x86-64-generic-ext4-combined-efi.img.gz" ] \
    || die "缺少上游 UEFI 镜像 $KEEP/...ext4-combined-efi.img.gz"

# ------------------------------------------------------------------ 工作区
mkdir -p "$OUT"
rm -rf "$WORK"; mkdir -p "$WORK"
LPS=""
cleanup(){ for l in $LPS; do losetup -d "$l" 2>/dev/null || true; done; }
trap cleanup EXIT

# 只在根文件系统上做，几秒钟就好；一次失败要尽早报出来，别等 6 GiB 镜像写完
build_nicbundle

# Personal service settings must never leak into a distributable image. Work on
# an isolated copy so development/runtime inputs and their databases stay intact.
log "清理发行副本中的 OpenVPN、Mihomo 和 DDNS 用户配置"
cp -a "$ROOTFS" "$WORK/release-rootfs"
ROOTFS=$WORK/release-rootfs
python3 "$(dirname "$0")/sanitize-rootfs.py" "$ROOTFS"

# 发行版标识：只有显式给了 --os-name 才写系统内部版本文件。
# 不改名的常规重建保持 etc/os-release 等原样 —— 重建镜像不该顺带改变系统身份。
# 只在副本上做（上面 cp -a 出来的 release-rootfs），开发实机与 router-build/rootfs
# 的版本文件保持原样 —— 装到实机上的包由 apk 管理，不该被镜像脚本改写。
if [ "$BRAND_SYSTEM" = 1 ]; then
    log "写入系统名称：$OS_NAME"
    python3 "$(dirname "$0")/brand-rootfs.py" "$ROOTFS" --name "$OS_NAME" \
        || die "brand-rootfs.py 失败"
    ok "系统名称已写入发行副本：$OS_NAME"
else
    log "未指定 --os-name：保留 rootfs 原有版本标识，仅把磁盘 GRUB 菜单名设为 $OS_NAME"
fi

# ------------------------------------------------------------------ 根分区
log "根分区 ${ROOT_MIB} MiB（直接来自 192 实机 rootfs）"
ROOT_IMG=$WORK/root.img
rm -f "$ROOT_IMG"
truncate -s $((ROOT_MIB * 1048576)) "$ROOT_IMG"
# -d 直接把目录写进新建 ext4，不需要 mount，也不会改变源目录
mke2fs -q -F -t ext4 -L rootfs -d "$ROOTFS" "$ROOT_IMG" >/dev/null
ok "root.img $(stat -c %s "$ROOT_IMG") 字节"

# ------------------------------------------------------------------ 从上游取引导件
log "抽取上游 bootx64.efi 与 p128 core.img"
gzip -dc "$KEEP/openwrt-x86-64-generic-ext4-combined-efi.img.gz" > "$WORK/up.img"
L=$(losetup -f --show -P "$WORK/up.img"); LPS="$LPS $L"
M=$WORK/upm; mkdir -p "$M"
mount -o ro "${L}p1" "$M" || die "上游 UEFI p1 挂载失败"
[ -f "$M/efi/boot/bootx64.efi" ] || die "上游缺 bootx64.efi"
cp "$M/efi/boot/bootx64.efi" "$WORK/bootx64.efi"
ok "bootx64.efi $(stat -c %s "$WORK/bootx64.efi") 字节"
umount "$M"
dd if="$WORK/up.img" of="$WORK/p128.img" bs=512 skip=$P128 count=$P128_SECT status=none
ok "p128 core.img $(stat -c %s "$WORK/p128.img") 字节"
losetup -d "$L"; LPS=""
rm -f "$WORK/up.img"

# ------------------------------------------------------------------ BIOS 引导分区（ext4）
log "BIOS 引导分区 ext4 ${BOOT_MIB} MiB"
BIOS_BOOT=$WORK/bios-boot.img
rm -f "$BIOS_BOOT"; truncate -s $((BOOT_MIB * 1048576)) "$BIOS_BOOT"
mke2fs -q -F -t ext4 -L boot -d "$BOOTSRC" "$BIOS_BOOT" >/dev/null
ok "bios-boot.img $(stat -c %s "$BIOS_BOOT") 字节"

# ------------------------------------------------------------------ UEFI ESP（vfat）
log "UEFI ESP vfat(FAT16) ${BOOT_MIB} MiB"
UEFI_BOOT=$WORK/uefi-boot.img
rm -f "$UEFI_BOOT"; truncate -s $((BOOT_MIB * 1048576)) "$UEFI_BOOT"
mkdir -p "$WORK/esp"
mkfs.vfat -F 16 -n kernel -i 1234ABCD "$UEFI_BOOT" >/dev/null
# 用 mtools 直接写，避免依赖 loop 挂载
mmd -i "$UEFI_BOOT" ::/boot ::/boot/grub ::/efi ::/efi/boot
mcopy -i "$UEFI_BOOT" "$BOOTSRC/boot/vmlinuz"       ::/boot/vmlinuz
mcopy -i "$UEFI_BOOT" "$BOOTSRC/boot/grub/boot.img" ::/boot/grub/boot.img
mcopy -i "$UEFI_BOOT" "$BOOTSRC/boot/grub/core.img" ::/boot/grub/core.img
mcopy -i "$UEFI_BOOT" "$WORK/bootx64.efi"           ::/efi/boot/bootx64.efi
info "ESP 内容:"
mdir -/ -i "$UEFI_BOOT" :: 2>/dev/null | sed 's/^/    /'
blkid "$UEFI_BOOT" 2>/dev/null | sed 's/^/    /'
ok "uefi-boot.img $(stat -c %s "$UEFI_BOOT") 字节"

# ------------------------------------------------------------------ grub.cfg
# 注意：这里是**安装后磁盘上的** grub.cfg，不是 ISO 的 grub.cfg。
# 它必须纯 ASCII（同样因为 GRUB 解析器），并且 root= 要能定位到根分区。
# 菜单条目名用 $OS_NAME（例如 AOS-20261109-V1），与系统内部自报的版本一致。
cat > "$WORK/grub-bios.cfg" <<CFG
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1 --rtscts=off
terminal_input console serial; terminal_output console serial

set default="0"
set timeout="5"
set root='(hd0,msdos1)'

menuentry "$OS_NAME" {
	linux /boot/vmlinuz root=PARTUUID=1593f3b2-02 rootwait  console=tty1 console=ttyS0,115200n8 noinitrd
}
menuentry "$OS_NAME (failsafe)" {
	linux /boot/vmlinuz failsafe=true root=PARTUUID=1593f3b2-02 rootwait  console=tty1 console=ttyS0,115200n8 noinitrd
}
CFG
# 记下本次载荷用的系统名与「是否真的改了系统内部标识」。
# build-iso.sh 读它来保证安装盘菜单与磁盘菜单同名；第二行的 branded 标记让
# check-iso 能诚实区分「名字真的贯穿到系统内部」还是「只改了菜单显示名」，
# 而不是两种情形都报「一致」。
{
    printf '%s\n' "$OS_NAME"
    printf 'branded=%s\n' "$BRAND_SYSTEM"
} > "$OUT/os-name.txt"

# ------------------------------------------------------------------ BIOS 镜像
log "组装 BIOS 镜像（MBR/dos）"
BIOS=$OUT/bios.img
rm -f "$BIOS"
truncate -s $(( (BIOS_P2 + ROOT_SECT) * 512 )) "$BIOS"
sfdisk "$BIOS" >/dev/null <<EOF
label: dos
label-id: 0x1593f3b2
unit: sectors
sector-size: 512

start=$BIOS_P1, size=$BOOT_SECT, type=83, bootable
start=$BIOS_P2, size=$ROOT_SECT, type=83
EOF
dd if="$BIOS_BOOT" of="$BIOS" bs=512 seek=$BIOS_P1 conv=notrunc status=none
# 关键：用 seek_bytes 按字节定位，不能按 MiB 整除
dd if="$ROOT_IMG" of="$BIOS" bs=1M oflag=seek_bytes seek=$((BIOS_P2 * 512)) \
   conv=notrunc status=none
# 把实机自己的 grub 引导代码写进 MBR（440 字节）和紧跟的 core.img
dd if="$BOOTSRC/boot/grub/boot.img" of="$BIOS" bs=440 count=1 conv=notrunc status=none
dd if="$BOOTSRC/boot/grub/core.img" of="$BIOS" bs=512 seek=1  conv=notrunc status=none
sync
# 写 grub.cfg 进 p1（ext4，需 loop 挂载）
L=$(losetup -f --show -P "$BIOS"); LPS="$LPS $L"
M=$WORK/mb; mkdir -p "$M"
mount "${L}p1" "$M" || die "BIOS p1 挂载失败"
cp -f "$WORK/grub-bios.cfg" "$M/boot/grub/grub.cfg"
sync; umount "$M"; losetup -d "$L"
LPS=$(echo "$LPS" | tr ' ' '\n' | grep -v "^$L$" | tr '\n' ' ')
sfdisk -d "$BIOS" | sed 's/^/    /'
ok "BIOS 镜像 $(stat -c %s "$BIOS") 字节"

# ------------------------------------------------------------------ UEFI 镜像
log "组装 UEFI 镜像（GPT）"
UEFI=$OUT/uefi.img
rm -f "$UEFI"
truncate -s $(( (UEFI_P2 + ROOT_SECT + GPT_TAIL) * 512 )) "$UEFI"
# 先清零头 2 MiB：truncate 会保留旧 GPT 头，导致 sgdisk 按旧盘尺寸校验而失败
dd if=/dev/zero of="$UEFI" bs=1M count=2 conv=notrunc status=none
# -a 1 关闭自动对齐，否则 p1 会被从 512 挪到 2048
sgdisk -a 1 \
  --new=1:$UEFI_P1:$((UEFI_P1 + BOOT_SECT - 1)) \
  --typecode=1:C12A7328-F81F-11D2-BA4B-00A0C93EC93B --change-name=1:boot \
  --new=128:$P128:$((P128 + P128_SECT - 1)) \
  --typecode=128:21686148-6449-6E6F-744E-656564454649 --change-name=128:BIOS\ boot \
  --new=2:$UEFI_P2:$((UEFI_P2 + ROOT_SECT - 1)) \
  --typecode=2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 --change-name=2:rootfs \
  "$UEFI" >/dev/null 2>&1 || die "sgdisk 建表失败（检查 GPT_TAIL 是否够放备份 GPT）"
sgdisk -p "$UEFI" | sed 's/^/    /'
ROOT_PARTUUID=$(sgdisk -i 2 "$UEFI" \
    | awk -F: '/Partition unique GUID/{gsub(/ /,"",$2); print tolower($2)}')
[ -n "$ROOT_PARTUUID" ] || die "取不到根分区 PARTUUID"
info "UEFI root PARTUUID=$ROOT_PARTUUID"

dd if="$UEFI_BOOT"    of="$UEFI" bs=512 seek=$UEFI_P1 conv=notrunc status=none
dd if="$WORK/p128.img" of="$UEFI" bs=512 seek=$P128    conv=notrunc status=none
dd if="$ROOT_IMG"     of="$UEFI" bs=1M oflag=seek_bytes seek=$((UEFI_P2 * 512)) \
   conv=notrunc status=none
sync

cat > "$WORK/grub-uefi.cfg" <<CFG
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1 --rtscts=off
terminal_input console serial; terminal_output console serial

set default="0"
set timeout="5"
search -l kernel -s root

menuentry "$OS_NAME" {
	linux /boot/vmlinuz root=PARTUUID=$ROOT_PARTUUID rootwait  console=tty1 console=ttyS0,115200n8 noinitrd
}
menuentry "$OS_NAME (failsafe)" {
	linux /boot/vmlinuz failsafe=true root=PARTUUID=$ROOT_PARTUUID rootwait  console=tty1 console=ttyS0,115200n8 noinitrd
}
CFG
# grub.cfg 要写进镜像内的 ESP：对 p1 区域做偏移写回
ESP_TMP=$WORK/esp-edit.img
dd if="$UEFI" of="$ESP_TMP" bs=512 skip=$UEFI_P1 count=$BOOT_SECT status=none
mcopy -o -i "$ESP_TMP" "$WORK/grub-uefi.cfg" ::/boot/grub/grub.cfg
dd if="$ESP_TMP" of="$UEFI" bs=512 seek=$UEFI_P1 conv=notrunc status=none
sync
ok "UEFI 镜像 $(stat -c %s "$UEFI") 字节"

# ------------------------------------------------------------------ 落盘自校验
log "镜像自校验（挂载后逐项核对）"
for m in bios uefi; do
    IMG=$OUT/$m.img
    L=$(losetup -f --show -P "$IMG"); LPS="$LPS $L"
    MP=$WORK/v-$m; mkdir -p "$MP"

    mount -o ro "${L}p1" "$MP" || die "$m p1 挂载失败"
    fs=$(blkid -o value -s TYPE "${L}p1")
    info "$m p1 fstype=$fs"
    ks=$(sha256sum "$MP/boot/vmlinuz" | awk '{print $1}')
    [ "$ks" = "$KERNEL_SHA" ] || die "$m p1 内核不匹配"
    ok "$m p1 内核 $(stat -c %s "$MP/boot/vmlinuz") 字节"
    # 引导选择界面上的系统名——用户直接看到这一行，必须是本次要求的名字
    [ -f "$MP/boot/grub/grub.cfg" ] || die "$m p1 缺 boot/grub/grub.cfg"
    grep -qxF "menuentry \"$OS_NAME\" {" "$MP/boot/grub/grub.cfg" \
        || die "$m p1 grub.cfg 缺 menuentry \"$OS_NAME\"（引导菜单名称没写对）"
    grep -qxF "menuentry \"$OS_NAME (failsafe)\" {" "$MP/boot/grub/grub.cfg" \
        || die "$m p1 grub.cfg 缺 failsafe 条目或名称不符"
    if grep -q 'OpenWrt Console' "$MP/boot/grub/grub.cfg"; then
        die "$m p1 grub.cfg 里仍残留旧名称 'OpenWrt Console'"
    fi
    ok "$m p1 引导菜单名称：$OS_NAME"
    if [ "$m" = uefi ]; then
        [ "$fs" = vfat ] || die "UEFI p1 必须是 vfat，实际 $fs —— 固件读不到，会掉进 EFI Shell"
        [ -f "$MP/efi/boot/bootx64.efi" ] || die "UEFI p1 缺 bootx64.efi"
        ok "$m p1: vfat + bootx64.efi 就位"
    fi
    umount "$MP"

    mount -o ro "${L}p2" "$MP" || die "$m p2 挂载失败"
    for chk in dev proc sys etc/config/network \
               www/luci-static/resources/view/console/overview.js \
               usr/share/ucode/console/vpn-service.uc; do
        [ -e "$MP/$chk" ] || die "$m p2 缺 $chk"
    done
    vs=$(sha256sum "$MP/usr/share/ucode/console/vpn-service.uc" | awk '{print $1}')
    [ "$vs" = "$EXPECT_VPN_SHA" ] || die "$m p2 vpn-service.uc 不是最新版: $vs"
    ok "$m p2 结构与 VPN 代码就位"
    # 明确验证「该删的都删了」
    [ -e "$MP/etc/console-vpn" ] && die "$m p2 仍含 /etc/console-vpn（VPN 私钥未移除）"
    [ -e "$MP/etc/console-security/guard.nft" ] && die "$m p2 仍含地区规则 guard.nft"
    ok "$m p2 无 VPN 私钥、无地区规则"
    python3 "$(dirname "$0")/sanitize-rootfs.py" "$MP" --check || die "$m p2 用户配置清理校验失败"
    # 系统内部自报的版本必须与引导菜单同名（仅在显式改名时才断言：
    # 不改名的常规重建里 rootfs 仍是 OpenWrt 标识，那是正确行为）。
    if [ "$BRAND_SYSTEM" = 1 ]; then
        python3 "$(dirname "$0")/brand-rootfs.py" "$MP" --name "$OS_NAME" --check \
            || die "$m p2 系统内部版本标识不是 $OS_NAME"
        ok "$m p2 系统内部版本标识：$OS_NAME"
    fi
    umount "$MP"; losetup -d "$L"
    LPS=$(echo "$LPS" | tr ' ' '\n' | grep -v "^$L$" | tr '\n' ' ')
done

# nicbundle 是 build-iso.sh 的硬依赖（NIC-SPEC 1.1 / 2.5），
# 它是在最前面生成的；这里再确认一次，避免中途被误删。
[ -s "$OUT/nicbundle.tar.gz" ] || die "nicbundle.tar.gz 丢了 —— build-iso.sh 会报缺载荷"
ok "nicbundle.tar.gz $(stat -c %s "$OUT/nicbundle.tar.gz") 字节"

# ------------------------------------------------------------------ 压缩与元数据
log "压缩并生成元数据"
cd "$OUT"
rm -f bios.img.gz uefi.img.gz
gzip -9 -c bios.img > bios.img.gz
gzip -9 -c uefi.img > uefi.img.gz
for m in bios uefi; do
    # 这两个值必须从解压流现算，不能由 .gz 的哈希推导
    stat -c %s "$m.img" > "$m.img.bytes"
    gzip -dc "$m.img.gz" | sha256sum | awk '{print $1}' > "$m.img.raw-sha256"
    printf '    %-5s raw=%-12s gz=%-10s sha=%s\n' \
        "$m" "$(cat "$m.img.bytes")" "$(stat -c %s "$m.img.gz")" \
        "$(cut -c1-16 "$m.img.raw-sha256")"
done

# 释放中间 raw（每个 6 GiB，磁盘紧张时很关键）
rm -f "$OUT/bios.img" "$OUT/uefi.img"
ls -la "$OUT"
if [ -n "$SYNC_STATE_SHA" ]; then
    [ "$(sha256sum "$SYNC_STATE" | awk '{print $1}')" = "$SYNC_STATE_SHA" ] \
        || die '生成载荷期间开发代码再次同步，请重新生成载荷，不能清除待更新标记。'
    sed 's/"payload_rebuild_required"[[:space:]]*:[[:space:]]*true/"payload_rebuild_required": false/' "$SYNC_STATE" > "$SYNC_STATE.new"
    mv -f "$SYNC_STATE.new" "$SYNC_STATE"
fi
log "完成 —— 接下来 bash build-iso.sh"
