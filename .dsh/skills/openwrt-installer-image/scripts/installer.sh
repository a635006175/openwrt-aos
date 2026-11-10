#!/bin/sh
# =============================================================================
# openwrt-install v3
#
# v2 相对 v1 的修正（保留）：
#   1. 载荷目录不再硬编码 /installer，改为读 $PAYLOAD_DIR（由 /init 探测后导出），
#      因此不再依赖「ISO 必须挂在 /」这一前提。
#   2. 校验和不再调用 `sha256sum -c`（busybox 的 -c 行为不一致），改为逐个手算比对。
#   3. valid_disk 排除 mmcblk*boot0/boot1/rpmb —— 它们也是「无 partition 文件的块设备」，
#      v1 会把 eMMC 的 boot 分区当成可安装目标，一旦选中就是砖。
#   4. 明确禁止把正在承载 ISO 的那块盘当目标（防止把启动盘自己擦掉）。
#   5. 全程只用 busybox 提供的 applet，不依赖 coreutils。
#
# v3 新增（见 NIC-SPEC.md 第 4、5 节）：
#   6. 写盘之前先识别网口、让用户选 LAN 口 / 输入 LAN 地址 / 选 WAN 口，
#      并打印配置摘要，确保用户在破坏性操作前能反悔。
#   7. 写盘并完成整盘 sha256 回读校验之后，再挂载新 rootfs 分区把选择结果
#      落进 /etc/config/network 等文件，最后只读复验。
#
# 重要：整盘 sha256 回读校验发生在「打补丁之前」。补丁之后磁盘不再等于载荷，
# 这是设计使然 —— 完成信息里也会明确说明。
# =============================================================================
set -eu

PROG=openwrt-install

fail() { printf '\n%s: ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- 载荷定位
PAYLOAD_DIR=${PAYLOAD_DIR:-}
if [ -z "$PAYLOAD_DIR" ]; then
    for cand in /cdrom/installer /installer /mnt/installer; do
        if [ -f "$cand/SHA256SUMS" ]; then PAYLOAD_DIR=$cand; break; fi
    done
fi
[ -n "$PAYLOAD_DIR" ] || fail '找不到安装载荷，请从安装镜像启动 / Installer payload is unavailable. Boot the installer image.'
[ -f "$PAYLOAD_DIR/SHA256SUMS" ] || fail "缺少载荷校验清单 / Missing SHA256SUMS in $PAYLOAD_DIR"

# ---------------------------------------------------------------- 整盘判定
valid_disk() {
    name=$1
    case "$name" in
        ''|*[!a-zA-Z0-9]*) return 1 ;;
    esac
    # eMMC 的 boot0/boot1/rpmb 是硬件保留分区，绝不能当安装目标
    case "$name" in
        *boot0|*boot1|*boot[0-9]) return 1 ;;
        *rpmb) return 1 ;;
    esac
    case "$name" in
        sd[a-z]|vd[a-z]|hd[a-z]) ;;
        nvme[0-9]n[0-9]|nvme[0-9]n[0-9][0-9]*) ;;
        mmcblk[0-9]|mmcblk[0-9][0-9]*) ;;
        *) return 1 ;;
    esac
    [ -b "/dev/$name" ] || return 1
    [ -d "/sys/class/block/$name" ] || return 1
    [ ! -f "/sys/class/block/$name/partition" ] || return 1
    [ "$(cat "/sys/class/block/$name/ro" 2>/dev/null || echo 1)" = 0 ] || return 1
    [ "$(cat "/sys/class/block/$name/size" 2>/dev/null || echo 0)" -gt 0 ] || return 1
    return 0
}

disk_mib() {
    s=$(cat "/sys/class/block/$1/size" 2>/dev/null || echo 0)
    echo $((s / 2048))
}

disk_model() {
    cat "/sys/class/block/$1/device/model" 2>/dev/null \
        || cat "/sys/class/block/$1/device/name" 2>/dev/null \
        || echo '?'
}

list_disks() {
    printf '\n目标磁盘（所选磁盘的全部数据将被清除）： / Target disks (ALL data on the chosen disk will be erased):\n'
    n=0
    for e in /sys/class/block/*; do
        name=${e##*/}
        valid_disk "$name" || continue
        lbs=$(cat "$e/queue/logical_block_size" 2>/dev/null || echo '?')
        mark=''
        [ "$lbs" = 512 ] || mark=' [不可安装：4Kn磁盘] /  [NOT INSTALLABLE: 4Kn]'
        [ "$(cat "$e/removable" 2>/dev/null || echo 0)" = 1 ] && mark="$mark [可移动磁盘] /  [removable]"
        printf '  /dev/%-12s %8s MiB  %-18s%s\n' "$name" "$(disk_mib "$name")" "$(disk_model "$name")" "$mark"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || fail '未找到可安装的整盘设备 / No installable whole disk was found.'
}

# ---------------------------------------------------------------- 占用检查
check_unused() {
    dname=$1
    for e in "/sys/class/block/$dname" "/sys/class/block/$dname/$dname"*; do
        [ -f "$e/dev" ] || continue
        num=$(cat "$e/dev")
        if awk -v n="$num" '$3 == n { f = 1 } END { exit !f }' /proc/self/mountinfo 2>/dev/null; then
            fail "${e##*/} 设备已挂载，请先卸载再安装 / is mounted. Unmount it before installing."
        fi
        for h in "$e"/holders/*; do
            [ -e "$h" ] || continue
            fail "${e##*/} 设备正在被占用 / is in use by ${h##*/}."
        done
    done
    if [ -r /proc/swaps ]; then
        while read -r sw rest; do
            [ -b "$sw" ] || continue
            case "$(readlink -f "$sw" 2>/dev/null || echo "$sw")" in
                /dev/"$dname"|/dev/"$dname"p*|/dev/"$dname"[0-9]*) fail "${sw##*/} 设备正在用作交换分区 / is used as swap." ;;
            esac
        done < /proc/swaps
    fi
}

# ---------------------------------------------------------------- 校验
verify_one() {
    f=$1
    [ -f "$PAYLOAD_DIR/$f" ] || fail "缺少载荷文件 / Payload file is missing: $f"
    want=$(awk -v f="$f" '$2 == f { print $1; exit }' "$PAYLOAD_DIR/SHA256SUMS")
    [ -n "$want" ] || fail "$f 文件未列入校验清单 / has no entry in SHA256SUMS"
    got=$(sha256sum "$PAYLOAD_DIR/$f" | awk '{ print $1 }')
    [ "$got" = "$want" ] || fail "载荷校验失败 / Checksum mismatch for $f (want ${want%%??????????????????}, got ${got%%??????????????????})"
    printf '  %-22s 校验通过 / ok\n' "$f"
}

# =============================================================================
# ==== NIC-CONFIG-CORE BEGIN ====
#
# 这一段是「网口配置改写 + 只读复验」的全部实现。刻意做成一组只依赖
# busybox applet、并且只通过 $1 拿到 rootfs 挂载点的纯函数，这样在构建机上
# 可以拿真实 rootfs 的副本当夹具直接调用（scripts/../tests/ 里就是这么做的）。
#
# 外部依赖的全局变量（由交互阶段设置）：
#   lan_port  选中的 LAN 口名（空 = 不改 br-lan 的 ports）
#   wan_port  选中的 WAN 口名（空 = 删除 wan / wan6 段）
#   lan_cidr  LAN 地址，形如 A.B.C.D/N（空 = 不改 lan 的 ipaddr）
#   lan_ip    上面那个地址的 IP 部分
#
# NIC_SYSFS_NET 只用于测试时替换 /sys/class/net，生产环境不要设置。
# =============================================================================
NIC_SYSFS_NET=${NIC_SYSFS_NET:-/sys/class/net}
NIC_DEFAULT_CIDR=192.168.1.1/24
NIC_DEFAULT_IP=192.168.1.1
NIC_DEFAULT_PFX=24

# --- 地址校验（NIC-SPEC 4.5）-----------------------------------------------
# 成功返回 0 并设置 nic_ip / nic_pfx / nic_cidr；失败返回 1，不改动它们。
nic_addr_parse() {
    nic_ip=''; nic_pfx=''; nic_cidr=''
    _in=$1
    [ -n "$_in" ] || return 1

    # 只允许一个斜杠
    case "$_in" in
        */*/*) return 1 ;;
        */*) nic_ip=${_in%%/*}; nic_pfx=${_in#*/} ;;
        *)   nic_ip=$_in;        nic_pfx=$NIC_DEFAULT_PFX ;;
    esac
    [ -n "$nic_ip" ] || return 1
    [ -n "$nic_pfx" ] || return 1

    # 前缀：纯数字、无前导零、8..32
    case "$nic_pfx" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#nic_pfx}" -le 2 ] || return 1
    case "$nic_pfx" in 0?*) return 1 ;; esac
    nic_pfx=$((nic_pfx + 0))
    [ "$nic_pfx" -ge 8 ] && [ "$nic_pfx" -le 32 ] || return 1

    # 四段十进制，每段 0..255 且无前导零（01 非法）。
    # 每一刀切分前都先确认「还剩点」，否则 '192.168.1' 这种三段输入会被
    # 悄悄补成 192.168.1.1 —— 那是另一个地址，绝不能被接受。
    _rest=$nic_ip
    case "$_rest" in *.*) ;; *) return 1 ;; esac
    _o1=${_rest%%.*}; _rest=${_rest#*.}
    case "$_rest" in *.*) ;; *) return 1 ;; esac
    _o2=${_rest%%.*}; _rest=${_rest#*.}
    case "$_rest" in *.*) ;; *) return 1 ;; esac
    _o3=${_rest%%.*}; _rest=${_rest#*.}
    _o4=$_rest
    case "$_o4" in *.*) return 1 ;; esac

    _n1=0; _n2=0; _n3=0; _n4=0
    _idx=0
    for _oct in "$_o1" "$_o2" "$_o3" "$_o4"; do
        case "$_oct" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#_oct}" -le 3 ] || return 1
        case "$_oct" in 0?*) return 1 ;; esac          # 前导零一律拒绝
        _v=$((_oct + 0))
        [ "$_v" -le 255 ] || return 1
        _idx=$((_idx + 1))
        case "$_idx" in
            1) _n1=$_v ;;
            2) _n2=$_v ;;
            3) _n3=$_v ;;
            4) _n4=$_v ;;
        esac
    done

    # 保留 / 特殊段：0.0.0.0/8、127/8、组播及以上的 224..255
    [ "$_n1" -eq 0 ] && return 1
    [ "$_n1" -eq 127 ] && return 1
    [ "$_n1" -ge 224 ] && return 1

    # 网络号与广播地址不能用。/31（点对点）与 /32（单主机）没有这两个概念。
    if [ "$nic_pfx" -lt 31 ]; then
        _ip=$(( _n1 * 16777216 + _n2 * 65536 + _n3 * 256 + _n4 ))
        _host=$(( 32 - nic_pfx ))
        _mask=$(( ((1 << nic_pfx) - 1) << _host ))
        _net=$(( _ip & _mask ))
        _bcast=$(( _net + ((1 << _host) - 1) ))
        [ "$_ip" -ne "$_net" ] || return 1
        [ "$_ip" -ne "$_bcast" ] || return 1
    fi

    nic_cidr="$nic_ip/$nic_pfx"
    return 0
}

# --- 网口信息读取 ----------------------------------------------------------
nic_mac() {
    _m=$(cat "$NIC_SYSFS_NET/$1/address" 2>/dev/null || true)
    [ -n "$_m" ] || _m='?'
    printf '%s\n' "$_m"
}

nic_link() {
    case "$(cat "$NIC_SYSFS_NET/$1/operstate" 2>/dev/null || true)" in
        up) printf 'up\n' ;;
        *)  printf 'down\n' ;;
    esac
}

# 驱动名：/sys/class/net/X/device/driver 指向 drivers/<name>。
# 不要对不存在的路径做 readlink -f —— 拿回原路径最后一段恰好是 "driver"。
nic_drv() {
    _d=''
    if [ -L "$NIC_SYSFS_NET/$1/device/driver" ] || [ -d "$NIC_SYSFS_NET/$1/device/driver" ]; then
        _d=$(readlink -f "$NIC_SYSFS_NET/$1/device/driver" 2>/dev/null || true)
        case "$_d" in */drivers/*) _d=${_d##*/} ;; *) _d='' ;; esac
    fi
    if [ -z "$_d" ] && [ -r "$NIC_SYSFS_NET/$1/device/uevent" ]; then
        _d=$(sed -n 's/^DRIVER=//p' "$NIC_SYSFS_NET/$1/device/uevent" 2>/dev/null | head -n 1 || true)
    fi
    [ -n "$_d" ] || _d='?'
    printf '%s\n' "$_d"
}

# PCI 地址：device 真实路径的最后一段若是 BDF 才采用，USB/虚拟设备一律 '?'。
nic_pci() {
    _p=''
    if [ -d "$NIC_SYSFS_NET/$1/device" ]; then
        _p=$(readlink -f "$NIC_SYSFS_NET/$1/device" 2>/dev/null || true)
        _p=${_p##*/}
        case "$_p" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F].[0-7]) ;;
            *) _p='?' ;;
        esac
    fi
    [ -n "$_p" ] || _p='?'
    printf '%s\n' "$_p"
}

# 非 lo 的网口名，每行一个（顺序稳定：glob 展开本身有序）
nic_names() {
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        _n=${_e##*/}
        [ "$_n" = lo ] && continue
        printf '%s\n' "$_n"
    done
}

nic_count() {
    _c=0
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        [ "${_e##*/}" = lo ] && continue
        _c=$((_c + 1))
    done
    printf '%s\n' "$_c"
}

# --- uci 文本读工具 --------------------------------------------------------
# nic_showvals <文件> <段类型> <段名> <option name 过滤> <键>
#   段类型 interface 时 <段名> 是该 interface 的名字；
#   段类型 device 时 <段名> 传空、用 <option name 过滤> 指定 br-lan。
nic_showvals() {
    [ -f "$1" ] || return 0
    awk -v wanttp="$2" -v wantnm="$3" -v wanton="$4" -v wantkey="$5" '
    function kvk(s,   t, n) {
        sub(/^[ \t]+/, "", s)
        n = split(s, t, /[ \t]+/)
        if (n < 2) return ""
        if (t[1] != "option" && t[1] != "list") return ""
        return t[2]
    }
    function kvv(s,   t, n, v) {
        sub(/^[ \t]+/, "", s)
        n = split(s, t, /[ \t]+/)
        if (n < 3) return ""
        v = t[3]
        gsub(/[^A-Za-z0-9_.:\/-]/, "", v)
        return v
    }
    function flush(   i, ok) {
        if (!nb) return
        ok = 1
        if (tp != wanttp) ok = 0
        if (wantnm != "" && nm != wantnm) ok = 0
        if (ok && wanton != "") {
            hit = 0
            for (i = 2; i <= nb; i++)
                if (kvk(buf[i]) == "name" && kvv(buf[i]) == wanton) hit = 1
            if (!hit) ok = 0
        }
        if (ok) {
            for (i = 2; i <= nb; i++)
                if (kvk(buf[i]) == wantkey) print kvv(buf[i])
        }
        nb = 0
    }
    /^[ \t]*config[ \t]/ {
        flush()
        tp = ""; nm = ""
        n = split($0, tk, /[ \t]+/)
        if (n >= 2) { tp = tk[2]; gsub(/[^A-Za-z0-9_]/, "", tp) }
        if (n >= 3) { nm = tk[3]; gsub(/[^A-Za-z0-9_]/, "", nm) }
        nb = 0; buf[++nb] = $0
        next
    }
    { if (nb > 0) buf[++nb] = $0 }
    END { flush() }
    ' "$1"
}

# nic_has_iface <文件> <interface 名> —— 存在该 config interface 段则返回 0
nic_has_iface() {
    [ -f "$1" ] || return 1
    awk -v want="$2" '
    /^[ \t]*config[ \t]/ {
        tp = ""; nm = ""
        n = split($0, tk, /[ \t]+/)
        if (n >= 2) { tp = tk[2]; gsub(/[^A-Za-z0-9_]/, "", tp) }
        if (n >= 3) { nm = tk[3]; gsub(/[^A-Za-z0-9_]/, "", nm) }
        if (tp == "interface" && nm == want) found = 1
    }
    END { exit (found ? 0 : 1) }' "$1"
}

# nic_grep_count <文件> <固定字串> —— 打印出现次数
nic_grep_count() {
    [ -f "$1" ] || { printf '0\n'; return 0; }
    grep -F -c "$2" "$1" 2>/dev/null || true
}

# --- 落盘小工具 ------------------------------------------------------------
# 用「先写临时文件、再 cat 回原文件」的方式替换内容：保留原 inode 与权限，
# 不会因为 uid/gid/mode 变化让 OpenWrt 的 uci 少读文件。
nic_splice() {
    _dst=$1
    _tmp=$2
    [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
    cat "$_tmp" > "$_dst" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    return 0
}

# --- 5.1 /etc/config/network ----------------------------------------------
# awk 状态机：一次缓冲一个 config 段，按「段类型 + 段名」决定改写或整段删除。
# 不按行号改，段顺序变化、多/少一个空行都不影响。
nic_apply_network() {
    _f=$1
    [ -f "$_f" ] || return 0
    _t="$_f.nictmp.$$"
    awk -v lanport="$lan_port" -v wanport="$wan_port" -v lanaddr="$lan_cidr" -v q="'" '
    function kvk(s,   t, n) {
        sub(/^[ \t]+/, "", s)
        n = split(s, t, /[ \t]+/)
        if (n < 2) return ""
        if (t[1] != "option" && t[1] != "list") return ""
        return t[2]
    }
    function kvv(s,   t, n, v) {
        sub(/^[ \t]+/, "", s)
        n = split(s, t, /[ \t]+/)
        if (n < 3) return ""
        v = t[3]
        gsub(/[^A-Za-z0-9_.:\/-]/, "", v)
        return v
    }
    function flushblk(   i, tp, nm, last, pi, repl, drop, isbr, n2, tmp) {
        if (nb == 0) return
        tp = ""; nm = ""
        n2 = split(buf[1], tk2, /[ \t]+/)
        if (n2 >= 2) { tp = tk2[2]; gsub(/[^A-Za-z0-9_]/, "", tp) }
        if (n2 >= 3) { nm = tk2[3]; gsub(/[^A-Za-z0-9_]/, "", nm) }

        last = 1
        for (i = 1; i <= nb; i++) {
            tmp = buf[i]; gsub(/[ \t]/, "", tmp)
            if (tmp != "") last = i
        }

        drop = 0; pi = 0; repl = ""
        if (tp == "device") {
            isbr = 0
            for (i = 2; i <= nb; i++)
                if (kvk(buf[i]) == "name" && kvv(buf[i]) == "br-lan") isbr = 1
            if (isbr && lanport != "") {
                for (i = 2; i <= nb; i++)
                    if (kvk(buf[i]) == "ports") { if (pi == 0) pi = i; del[i] = 1 }
                if (pi == 0) pi = last
                repl = "\tlist ports " q lanport q
            }
        } else if (tp == "interface") {
            if (nm == "lan2") {
                drop = 1
            } else if (nm == "lan") {
                if (lanaddr != "") {
                    for (i = 2; i <= nb; i++)
                        if (kvk(buf[i]) == "ipaddr") { if (pi == 0) pi = i; del[i] = 1 }
                    if (pi == 0) pi = last
                    repl = "\tlist ipaddr " q lanaddr q
                }
            } else if (nm == "wan" || nm == "wan6") {
                if (wanport == "") {
                    drop = 1
                } else {
                    for (i = 2; i <= nb; i++)
                        if (kvk(buf[i]) == "device") { if (pi == 0) pi = i; del[i] = 1 }
                    if (pi == 0) pi = last
                    repl = "\toption device " q wanport q
                }
            }
        }

        if (drop) { nb = 0; return }
        for (i = 1; i <= nb; i++) {
            if (!del[i]) print buf[i]
            if (i == pi && repl != "") print repl
        }
        nb = 0
    }
    /^[ \t]*config[ \t]/ {
        flushblk()
        split("", del)
        nb = 0
    }
    {
        if ($0 ~ /^[ \t]*config[ \t]/) { buf[++nb] = $0; next }
        if (nb > 0) { buf[++nb] = $0; next }
        print
    }
    END { flushblk() }
    ' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
    # A clean release may contain only loopback. Populate missing sections from
    # the user's validated port choices instead of requiring a device snapshot.
    if [ -n "$lan_port" ] && [ -z "$(nic_showvals "$_t" device '' br-lan name)" ]; then
        printf '\nconfig device\n\toption name '\''br-lan'\''\n\toption type '\''bridge'\''\n\tlist ports '\''%s'\''\n' "$lan_port" >> "$_t"
    fi
    if [ -n "$lan_port" ] && ! nic_has_iface "$_t" lan; then
        printf '\nconfig interface '\''lan'\''\n\toption device '\''br-lan'\''\n\toption proto '\''static'\''\n\tlist ipaddr '\''%s'\''\n\toption ip6assign '\''60'\''\n' "$lan_cidr" >> "$_t"
    fi
    if [ -n "$wan_port" ]; then
        if ! nic_has_iface "$_t" wan; then
            printf '\nconfig interface '\''wan'\''\n\toption device '\''%s'\''\n\toption proto '\''dhcp'\''\n' "$wan_port" >> "$_t"
        fi
        if ! nic_has_iface "$_t" wan6; then
            printf '\nconfig interface '\''wan6'\''\n\toption device '\''%s'\''\n\toption proto '\''dhcpv6'\''\n' "$wan_port" >> "$_t"
        fi
    fi
    nic_splice "$_f" "$_t" || return 1
    return 0
}

# --- 5.2 /etc/config/firewall ---------------------------------------------
# lan2 的引用一律删掉；没有 WAN 时连 wan / wan6 的引用一起删。
nic_apply_firewall() {
    _f=$1
    [ -f "$_f" ] || return 0
    _t="$_f.nictmp.$$"
    awk -v wanport="$wan_port" '
    {
        t = $0
        sub(/^[ \t]+/, "", t)
        if (t ~ /^(list|option)[ \t]+network[ \t]/) {
            v = t
            sub(/^[^ \t]+[ \t]+network[ \t]+/, "", v)
            gsub(/[^A-Za-z0-9_]/, "", v)
            if (v == "lan2") next
            if (wanport == "" && (v == "wan" || v == "wan6")) next
        }
        print
    }
    ' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
    nic_splice "$_f" "$_t" || return 1
    return 0
}

# --- 5.2 /etc/board.json ---------------------------------------------------
# 缩进好的 JSON，逐行处理：只改 network.lan / network.wan 里的 "device"，
# 没 WAN 时整块删掉 "wan" 对象，最后统一修掉悬空的逗号。
nic_apply_board() {
    _f=$1
    [ -f "$_f" ] || return 0
    _t="$_f.nictmp.$$"
    awk -v lanport="$lan_port" -v wanport="$wan_port" '
    function braces(s,   o, c) {
        o = gsub(/\{/, "", s)
        c = gsub(/\}/, "", s)
        return o - c
    }
    BEGIN { state = ""; delmode = 0; depth = 0; m = 0 }
    {
        line = $0
        if (delmode) {
            depth += braces(line)
            if (depth <= 0) { delmode = 0 }
            next
        }
        if (line ~ /^[ \t]*"lan"[ \t]*:[ \t]*\{/)  { state = "lan";  out[++m] = line; next }
        if (line ~ /^[ \t]*"wan"[ \t]*:[ \t]*\{/) {
            if (wanport == "") {
                delmode = 1
                depth = braces(line)
                if (depth <= 0) delmode = 0
                next
            }
            state = "wan"; out[++m] = line; next
        }
        if (line ~ /^[ \t]*\}/) { state = ""; out[++m] = line; next }
        if (state == "lan" && lanport != "" && line ~ /^[ \t]*"device"[ \t]*:/) {
            sub(/:[ \t]*"[^"]*"/, ": \"" lanport "\"", line)
            out[++m] = line; next
        }
        if (state == "wan" && wanport != "" && line ~ /^[ \t]*"device"[ \t]*:/) {
            sub(/:[ \t]*"[^"]*"/, ": \"" wanport "\"", line)
            out[++m] = line; next
        }
        out[++m] = line
    }
    END {
        for (i = 1; i <= m; i++) {
            if (out[i] ~ /,$/) {
                j = i + 1
                while (j <= m && out[j] ~ /^[ \t]*$/) j++
                if (j <= m) {
                    t = out[j]
                    sub(/^[ \t]+/, "", t)
                    if (substr(t, 1, 1) == "}" || substr(t, 1, 1) == "]")
                        sub(/,[ \t]*$/, "", out[i])
                }
            }
        }
        for (i = 1; i <= m; i++) print out[i]
    }
    ' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
    nic_splice "$_f" "$_t" || return 1
    return 0
}

# --- 5.2 mihomo：bind-address 与 include-interface -------------------------
# config.json 是**一整行**超长 JSON（含中文节点名），所以只做定点替换：
#   1. 用 sub() 精确命中 "bind-address" 的**值**，两种空格写法都能中；
#   2. include-interface 里删掉「装好后不会存在的物理网口名」，
#      保留 br-lan / cvpns 这类虚拟接口。
# 绝不做整行重写 —— 那会把中文节点名和 47 KB 的代理规则一起搞坏。
nic_apply_mihomo() {
    _f=$1
    [ -f "$_f" ] || return 0
    _t="$_f.nictmp.$$"
    awk -v ipaddr="$lan_ip" -v rmlist="$NIC_DROP_IFACES" '
    function dropone(s, pat,   p) {
        while ((p = index(s, pat)) > 0)
            s = substr(s, 1, p - 1) substr(s, p + length(pat))
        return s
    }
    BEGIN { nr = split(rmlist, names, " ") }
    {
        line = $0
        if (ipaddr != "")
            sub(/"bind-address"[ \t]*:[ \t]*"[^"]*"/, "\"bind-address\": \"" ipaddr "\"", line)
        for (i = 1; i <= nr; i++) {
            n = names[i]
            if (n == "") continue
            if (index(line, ", \"" n "\"") > 0)      line = dropone(line, ", \"" n "\"")
            else if (index(line, "\"" n "\", ") > 0) line = dropone(line, "\"" n "\", ")
            else if (index(line, "\"" n "\"") > 0)   line = dropone(line, "\"" n "\"")
        }
        print line
    }
    ' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
    nic_splice "$_f" "$_t" || return 1
    return 0
}

# --- 5.2 /etc/console-mihomo/lan-devices.json -----------------------------
# 与 include-interface 保持完全一致的数组内容：直接从（已改写的）config.json
# 里把那个数组抽出来重写，天然不会两边漂移。
nic_apply_lan_devices() {
    _cfg=$1
    _f=$2
    [ -f "$_cfg" ] || return 0
    _inner=$(sed -n 's/.*"include-interface"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$_cfg" 2>/dev/null | head -n 1 || true)
    if [ -n "$_inner" ]; then
        _t="$_f.nictmp.$$"
        printf '[%s]\n' "$_inner" > "$_t" || { rm -f "$_t"; return 1; }
        nic_splice "$_f" "$_t" || return 1
        return 0
    fi
    # 抽不出来就退化成对原文件做同样的过滤
    if [ -f "$_f" ]; then
        _t="$_f.nictmp.$$"
        awk -v rm="$NIC_DROP_IFACES" '
        function dropone(s, pat,   p) {
            while ((p = index(s, pat)) > 0)
                s = substr(s, 1, p - 1) substr(s, p + length(pat))
            return s
        }
        BEGIN { nr = split(rm, names, " ") }
        {
            line = $0
            for (i = 1; i <= nr; i++) {
                n = names[i]
                if (n == "") continue
                if (index(line, ", \"" n "\"") > 0)      line = dropone(line, ", \"" n "\"")
                else if (index(line, "\"" n "\", ") > 0) line = dropone(line, "\"" n "\", ")
                else if (index(line, "\"" n "\"") > 0)   line = dropone(line, "\"" n "\"")
            }
            print line
        }' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
        nic_splice "$_f" "$_t" || return 1
    fi
    return 0
}

# --- 5.2 /etc/fwx：monitor_device 跟 WAN 走 ---------------------------------
nic_apply_fwx() {
    _f=$1
    [ -f "$_f" ] || return 0
    _t="$_f.nictmp.$$"
    awk -v wanport="$wan_port" -v q="'" '
    {
        s = $0
        sub(/^[ \t]+/, "", s)
        if (s ~ /^option[ \t]+monitor_device[ \t]/) {
            if (wanport == "") next
            print "\toption monitor_device " q wanport q
            next
        }
        print
    }
    ' "$_f" > "$_t" || { rm -f "$_t"; return 1; }
    nic_splice "$_f" "$_t" || return 1
    return 0
}

# --- 5.4 /etc/console-install-ports.json ----------------------------------
nic_write_ports_json() {
    _f=$1
    _wan='null'
    if [ -n "$wan_port" ]; then
        _wan=$(printf '{"name":"%s","mac":"%s","driver":"%s","pci":"%s"}' \
            "$wan_port" "$(nic_mac "$wan_port")" "$(nic_drv "$wan_port")" "$(nic_pci "$wan_port")")
    fi
    _lan_name=$lan_port
    _lan_mac='?'; _lan_drv='?'; _lan_pci='?'
    if [ -n "$lan_port" ]; then
        _lan_mac=$(nic_mac "$lan_port")
        _lan_drv=$(nic_drv "$lan_port")
        _lan_pci=$(nic_pci "$lan_port")
    fi
    _now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '1970-01-01T00:00:00Z')
    printf '{"lan":{"name":"%s","mac":"%s","driver":"%s","pci":"%s"},"wan":%s,"address":"%s","installed_at":"%s"}\n' \
        "$_lan_name" "$_lan_mac" "$_lan_drv" "$_lan_pci" "$_wan" "$lan_cidr" "$_now" > "$_f" || return 1
    return 0
}

# --- 「装好后会存在」的网口名 ---------------------------------------------
# include-interface 里要删掉的是「装完系统后不存在」的物理口。
# 保留集合 = 虚拟接口白名单 + 当前 sysfs 里出现的口 + 本次选中的 LAN/WAN 口
#（选中的口在装好的系统里一定会出现，即使安装环境里一时没枚举到）。
nic_compute_drop_ifaces() {
    NIC_DROP_IFACES=''
    _keep='br-lan cvpns lo'
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        _keep="$_keep ${_e##*/}"
    done
    [ -n "$lan_port" ] && _keep="$_keep $lan_port"
    [ -n "$wan_port" ] && _keep="$_keep $wan_port"

    _raw=''
    if [ -n "${NIC_INC_RAW:-}" ]; then
        _raw=$NIC_INC_RAW
    elif [ -f "${NIC_MIHOMO_CFG:-}" ]; then
        _raw=$(sed -n 's/.*"include-interface"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$NIC_MIHOMO_CFG" 2>/dev/null | head -n 1 || true)
    fi
    [ -n "$_raw" ] || return 0

    _oldifs=$IFS
    IFS=','
    for _n in $_raw; do
        _n=$(printf '%s' "$_n" | tr -d ' \t"')
        [ -n "$_n" ] || continue
        case " $_keep " in
            *" $_n "*) ;;
            *) NIC_DROP_IFACES="$NIC_DROP_IFACES $_n" ;;
        esac
    done
    IFS=$_oldifs
    NIC_DROP_IFACES=${NIC_DROP_IFACES# }
    return 0
}

# --- 统一入口：把计划落到挂载好的新 rootfs 上 ------------------------------
nic_apply_all() {
    _R=$1
    [ -d "$_R" ] || return 1
    [ -f "$_R/etc/config/network" ] || return 1

    if [ -f "$_R/etc/console-mihomo/config.json" ]; then
        NIC_MIHOMO_CFG="$_R/etc/console-mihomo/config.json"
    else
        NIC_MIHOMO_CFG=''
    fi
    nic_compute_drop_ifaces

    nic_apply_network  "$_R/etc/config/network" || return 1
    if [ -f "$_R/etc/console-backup/network.last-good" ]; then
        nic_apply_network "$_R/etc/console-backup/network.last-good" || return 1
    fi
    nic_apply_firewall "$_R/etc/config/firewall" || return 1
    nic_apply_board    "$_R/etc/board.json" || return 1

    if [ -n "$NIC_MIHOMO_CFG" ]; then
        nic_apply_mihomo "$NIC_MIHOMO_CFG" || return 1
        nic_apply_lan_devices "$NIC_MIHOMO_CFG" "$(dirname "$NIC_MIHOMO_CFG")/lan-devices.json" || return 1
    fi

    if [ -f "$_R/etc/config/fwx" ]; then
        nic_apply_fwx "$_R/etc/config/fwx" || return 1
    fi
    if [ -f "$_R/etc/fwx" ]; then
        nic_apply_fwx "$_R/etc/fwx" || return 1
    fi

    nic_write_ports_json "$_R/etc/console-install-ports.json" || return 1
    return 0
}

# --- 5.3 只读复验：任一条不符即返回 1 --------------------------------------
nic_verify() {
    _R=$1
    _bad=0
    _err() { printf '  配置复验错误 / verify: %s\n' "$*" >&2; _bad=$((_bad + 1)); }

    _net=$_R/etc/config/network
    _fw=$_R/etc/config/firewall
    _board=$_R/etc/board.json
    _mih=$_R/etc/console-mihomo/config.json

    # 1) br-lan 的 ports 恰好等于所选 LAN 口
    if [ -n "$lan_port" ]; then
        _p=$(nic_showvals "$_net" device '' br-lan ports | tr '\n' ' ')
        _p=${_p% }
        [ "$_p" = "$lan_port" ] || _err "br-lan ports is '$_p', expected '$lan_port'"
    fi

    # 2) lan 的 ipaddr 恰好等于所选地址
    if [ -n "$lan_cidr" ]; then
        _a=$(nic_showvals "$_net" interface lan '' ipaddr | tr '\n' ' ')
        _a=${_a% }
        [ "$_a" = "$lan_cidr" ] || _err "lan ipaddr is '$_a', expected '$lan_cidr'"
    fi

    # 3) WAN：没有就不能有 wan 段；有就必须 device 对
    if [ -z "$wan_port" ]; then
        if nic_has_iface "$_net" wan; then _err 'network still has a wan interface'; fi
        if nic_has_iface "$_net" wan6; then _err 'network still has a wan6 interface'; fi
    else
        _w=$(nic_showvals "$_net" interface wan '' device | tr '\n' ' ')
        _w=${_w% }
        [ "$_w" = "$wan_port" ] || _err "wan device is '$_w', expected '$wan_port'"
    fi

    # 4) network 里不许再有 lan2
    [ "$(nic_grep_count "$_net" lan2)" = 0 ] || _err 'network still mentions lan2'

    # 5) firewall 里不许再有 lan2 字样
    [ "$(nic_grep_count "$_fw" lan2)" = 0 ] || _err 'firewall still mentions lan2'

    # 6) board.json 里能确认 LAN 口
    if [ -n "$lan_port" ]; then
        grep -F -q "$lan_port" "$_board" 2>/dev/null || _err "board.json does not mention '$lan_port'"
    fi

    # 7) mihomo bind-address 跟 LAN 地址的 IP 部分一致
    if [ -f "$_mih" ] && [ -n "$lan_ip" ]; then
        _b=$(sed -n 's/.*"bind-address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_mih" 2>/dev/null | head -n 1 || true)
        [ "$_b" = "$lan_ip" ] || _err "mihomo bind-address is '$_b', expected '$lan_ip'"
    fi

    # 附加：安装结果清单必须存在且非空
    [ -s "$_R/etc/console-install-ports.json" ] || _err 'console-install-ports.json is missing or empty'

    [ "$_bad" -eq 0 ] || return 1
    return 0
}
# ==== NIC-CONFIG-CORE END ====

# ---------------------------------------------------------------- 网口交互
# 网口列表格式见 NIC-SPEC 4.2（逐字节，check-iso / e2e 会按键面匹配解析）。
nic_print_list() {
    printf '检测到的网口： / Network interfaces detected:\n'
    _i=0
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        _n=${_e##*/}
        [ "$_n" = lo ] && continue
        _i=$((_i + 1))
        printf '  [%s] %-6s%-17s  link=%-6s driver=%-10s pci=%s\n' \
            "$_i" "$_n" "$(nic_mac "$_n")" "$(nic_link "$_n")" "$(nic_drv "$_n")" "$(nic_pci "$_n")"
    done
    return 0
}

# 打印第 n 个网口名（n 从 1 开始）；越界打印空
nic_nth() {
    _want=$1
    _i=0
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        _n=${_e##*/}
        [ "$_n" = lo ] && continue
        _i=$((_i + 1))
        if [ "$_i" -eq "$_want" ]; then printf '%s\n' "$_n"; return 0; fi
    done
    printf '\n'
    return 0
}

# 把用户输入的编号映射成网口名；非法打印空。
# 参数：<输入> <允许的最大编号> <要排除的网口名>
nic_pick() {
    _in=$1
    _max=$2
    _excl=$3
    case "$_in" in ''|*[!0-9]*) printf '\n'; return 0 ;; esac
    [ "${#_in}" -le 3 ] || { printf '\n'; return 0; }
    _v=$((_in + 0))
    [ "$_v" -ge 1 ] && [ "$_v" -le "$_max" ] || { printf '\n'; return 0; }
    _got=$(nic_nth "$_v")
    if [ -n "$_excl" ] && [ "$_got" = "$_excl" ]; then printf '\n'; return 0; fi
    printf '%s\n' "$_got"
    return 0
}

# 网口阶段：列网口 → 选 LAN → 输入地址 → 选 WAN。
# 设置：nic_apply_needed / lan_port / lan_cidr / lan_ip / lan_pfx / wan_port
nic_stage() {
    nic_apply_needed=1
    lan_port=''; wan_port=''
    lan_cidr=''; lan_ip=''; lan_pfx=''
    nic_n=$(nic_count)

    if [ "$nic_n" -eq 0 ]; then
        # NIC-SPEC 4.2：无网口时整行提示，配置保持镜像内置默认值。
        printf '未发现网口，将使用内置网络配置 / Network interfaces detected: (none) \342\200\224 network configuration is left at the built-in default.\n'
        nic_apply_needed=0
        return 0
    fi

    nic_print_list

    # ---- 选 LAN ----
    # 提示语行尾不带空格：NIC-SPEC 4.3 明确规定，verify-e2e.sh 的 PROMPT_LAN
    # 也按这个字面量做子串匹配。
    while :; do
        printf '输入编号选择LAN内网口，输入d使用默认网口： / Select the LAN port by number (or "d" for the built-in default eth0=LAN / eth1=WAN):'
        read -r nic_ans || nic_ans=''
        case "$nic_ans" in
            '')
                # 空回车不跳过：必须显式选 d 才走内置默认
                printf '必须选择网口，输入d才会使用默认设置 / A choice is required; press "d" to accept the built-in default.\n'
                continue
                ;;
            d|D)
                nic_use_builtin_default
                return 0
                ;;
        esac
        lan_port=$(nic_pick "$nic_ans" "$nic_n" '')
        if [ -n "$lan_port" ]; then break; fi
        printf '选择无效，请重新输入 / Invalid choice: %s\n' "$nic_ans"
    done

    # ---- 输入 LAN 地址 ----
    while :; do
        printf '输入LAN地址或地址及前缀，回车使用默认地址： / Enter the LAN address as IPv4 or IPv4/prefix, Enter for 192.168.1.1/24:'
        read -r nic_ans || nic_ans=''
        [ -n "$nic_ans" ] || nic_ans=$NIC_DEFAULT_CIDR
        if nic_addr_parse "$nic_ans"; then break; fi
        printf '地址无效，请重新输入 / Invalid address: %s\n' "$nic_ans"
    done
    lan_cidr=$nic_cidr; lan_ip=$nic_ip; lan_pfx=$nic_pfx

    # ---- 选 WAN ----
    nic_choose_wan
    return 0
}

# 「d」内置默认：LAN eth0 / WAN eth1 / 192.168.1.1/24，不再追问。
# 若 eth0 / eth1 实际不存在，则退化为「能配就配、配不了的对应角色留空」。
nic_use_builtin_default() {
    printf '采用默认网口及内网地址 / Using the built-in default: LAN eth0, WAN eth1, LAN address 192.168.1.1/24.\n'
    lan_cidr=$NIC_DEFAULT_CIDR
    lan_ip=$NIC_DEFAULT_IP
    lan_pfx=$NIC_DEFAULT_PFX
    lan_port=''; wan_port=''
    [ -d "$NIC_SYSFS_NET/eth0" ] && lan_port=eth0
    [ -d "$NIC_SYSFS_NET/eth1" ] && wan_port=eth1
    if [ -z "$lan_port" ] || [ -z "$wan_port" ]; then
        printf '默认网口不齐全，只配置当前可用网口 / Built-in default ports are not both present here; only the available roles will be configured.\n'
    fi
    return 0
}

# WAN 候选 = 除 LAN 口以外的全部网口。
# 0 个：不配 WAN；1 个：直接用它；≥2：让用户选，"n" 表示不配。
nic_choose_wan() {
    _cand=''
    _c=0
    for _e in "$NIC_SYSFS_NET"/*; do
        [ -d "$_e" ] || continue
        _n=${_e##*/}
        [ "$_n" = lo ] && continue
        [ "$_n" = "$lan_port" ] && continue
        _c=$((_c + 1))
        _cand="$_cand $_n"
    done
    _cand=${_cand# }

    if [ "$_c" -eq 0 ]; then
        printf '没有剩余网口，暂不配置WAN外网 / No spare port for WAN; WAN will be left unconfigured.\n'
        wan_port=''
        return 0
    fi
    if [ "$_c" -eq 1 ]; then
        printf '仅剩一个网口，将自动作为WAN外网口 / Only one spare port is left: %s will be the WAN port.\n' "$_cand"
        wan_port=$_cand
        return 0
    fi

    while :; do
        printf '输入编号选择WAN外网口，输入n暂不配置： / Select the WAN port by number, or "n" to leave WAN unconfigured:'
        read -r nic_ans || nic_ans=''
        case "$nic_ans" in
            '')
                printf '必须选择网口，输入n才会跳过WAN配置 / A choice is required; press "n" to leave WAN unconfigured.\n'
                continue
                ;;
            n|N)
                wan_port=''
                return 0
                ;;
        esac
        wan_port=$(nic_pick "$nic_ans" "$(nic_count)" "$lan_port")
        if [ -n "$wan_port" ]; then return 0; fi
        printf '选择无效，请重新输入 / Invalid choice: %s\n' "$nic_ans"
    done
}

# 摘要（NIC-SPEC 4.4），必须打在 按回车确认清空目标磁盘并安装，输入其他内容取消 / Press Enter to erase 之前。
nic_print_plan() {
    printf '\n网络配置摘要： / Network plan:\n'
    if [ -n "$lan_port" ]; then
        printf '  LAN内网口 / LAN port    : %s  %s  (%s, pci=%s)\n' \
            "$lan_port" "$(nic_mac "$lan_port")" "$(nic_drv "$lan_port")" "$(nic_pci "$lan_port")"
    else
        printf '  LAN内网口 / LAN port    : (none)\n'
    fi
    printf '  LAN内网地址 / LAN address : %s\n' "$lan_cidr"
    if [ -n "$wan_port" ]; then
        printf '  WAN外网口 / WAN port    : %s  %s  (%s, pci=%s)\n' \
            "$wan_port" "$(nic_mac "$wan_port")" "$(nic_drv "$wan_port")" "$(nic_pci "$wan_port")"
    else
        printf '  WAN外网口 / WAN port    : (none)\n'
    fi
}

# ---------------------------------------------------------------- rootfs 落地
ROOTMNT=/mnt/rootfs

# 分区重读：写盘后内核的分区表可能还是旧的，不重读就拿不到 ${disk}2。
nic_reread_partitions() {
    _d=$1
    _i=0
    while [ "$_i" -lt 3 ]; do
        _i=$((_i + 1))
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --rereadpt "$_d" 2>/dev/null || true
        fi
        if command -v partprobe >/dev/null 2>&1; then
            partprobe "$_d" 2>/dev/null || true
        fi
        mdev -s 2>/dev/null || true
        sleep 1
        if [ -b "${_d}2" ] || [ -b "${_d}p2" ]; then return 0; fi
    done
    return 0
}

# 找 rootfs 分区并挂上。优先 LABEL="rootfs"，其次按名字猜，最后逐个试挂。
nic_mount_rootfs() {
    _d=$1
    _n=$2
    mkdir -p "$ROOTMNT"
    nic_reread_partitions "$_d"

    # 1) 有 blkid / findfs 就用卷标定位（LABEL=rootfs 是载荷里的固定标签）
    _by_label=''
    if command -v blkid >/dev/null 2>&1; then
        _by_label=$(blkid 2>/dev/null | grep -F 'LABEL="rootfs"' | cut -d: -f1 | head -n 1 || true)
    fi
    if [ -z "$_by_label" ] && command -v findfs >/dev/null 2>&1; then
        _by_label=$(findfs LABEL=rootfs 2>/dev/null || true)
    fi

    _cands=''
    [ -n "$_by_label" ] && _cands="$_by_label"
    _cands="$_cands ${_d}2 ${_d}p2 ${_d}3 ${_d}p3"
    for _e in /sys/class/block/*; do
        _b=${_e##*/}
        case "$_b" in
            "$_n"p[0-9]*|"$_n"[0-9]*) ;;
            *) continue ;;
        esac
        [ -f "$_e/partition" ] || continue
        _cands="$_cands /dev/$_b"
    done

    for _p in $_cands; do
        [ -b "$_p" ] || continue
        mount -t ext4 -o rw "$_p" "$ROOTMNT" 2>/dev/null || continue
        if [ -f "$ROOTMNT/etc/config/network" ]; then
            printf '%s\n' "$_p"
            return 0
        fi
        umount "$ROOTMNT" 2>/dev/null || true
    done
    return 1
}

# =============================================================================
# 自检
# =============================================================================
[ "$(id -u)" = 0 ] || fail '请使用root管理员运行 / Run as root.'
[ -d /proc/self ] || fail '系统信息目录未挂载 / /proc is not mounted.'
[ "$#" -le 1 ] || fail '用法 / Usage: openwrt-install [--list | /dev/WHOLE-DISK]'

list_disks
[ "${1:-}" != '--list' ] || exit 0

[ -t 0 ] && [ -t 1 ] || fail '必须使用交互终端，禁止无人确认写盘 / An interactive terminal is required; unattended writes are not allowed.'

disk=${1:-}
if [ -z "$disk" ]; then
    printf '\n输入目标整盘路径（例如/dev/sda），回车取消： / Enter the full target disk path (e.g. /dev/sda), or press Enter to cancel: '
    read -r disk
    [ -n "$disk" ] || fail '安装已取消 / Installation cancelled.'
fi
case "$disk" in /dev/*) ;; *) fail '请输入/dev目录下的整盘路径 / Use a whole-disk path under /dev.' ;; esac
disk=$(readlink -f "$disk")
name=${disk##*/}
valid_disk "$name" || fail '不支持该目标设备，只支持逻辑扇区为512字节的整盘 / That is not a supported whole disk (whole disks only; 512-byte logical sectors required, 4Kn is not supported).'

lbs=$(cat "/sys/class/block/$name/queue/logical_block_size" 2>/dev/null || echo 0)
[ "$lbs" = 512 ] || fail "$disk has ${lbs}-byte 不支持该扇区格式，只支持512字节逻辑扇区 / logical sectors. Only 512-byte logical sectors (512e) are supported."

# 防止把承载 ISO 的启动介质本身擦掉
if [ -n "${ISO_DEV:-}" ]; then
    base=$(readlink -f "$ISO_DEV" 2>/dev/null || echo "$ISO_DEV")
    case "$base" in
        "$disk"|"$disk"p*|"$disk"[0-9]*) fail "$disk 这是当前安装介质，请选择另一块磁盘 / is the medium this installer is running from. Choose another disk." ;;
    esac
fi

check_unused "$name"

mode=bios
[ ! -d /sys/firmware/efi ] || mode=uefi
payload=$PAYLOAD_DIR/$mode.img.gz
[ -f "$payload" ] || fail "缺少当前启动模式所需的载荷 / Missing payload for $mode mode: $payload.gz"

bytes=$(cat "$PAYLOAD_DIR/$mode.img.bytes" 2>/dev/null || echo '')
case "$bytes" in ''|*[!0-9]*) fail "镜像容量信息无效 / Invalid image size metadata ($mode.img.bytes)." ;; esac
[ "$bytes" -gt 0 ] || fail '磁盘镜像为空 / The disk image is empty.'

sectors=$(cat "/sys/class/block/$name/size")
need=$(( (bytes + 511) / 512 ))
[ "$sectors" -ge "$need" ] \
    || fail "$disk 目标磁盘容量不足 / is too small: needs $(( (need + 2047) / 2048 )) MiB, has $(( sectors / 2048 )) MiB."

# =============================================================================
# 网口阶段：必须在写盘之前，让用户看完摘要还能反悔。
# =============================================================================
printf '\n'
nic_stage
nic_print_plan

printf '\n启动模式 / Firmware mode : %s\n' "$mode"
printf '目标磁盘 / Target disk   : %s  (%s MiB, %s)\n' "$disk" "$(( sectors / 2048 ))" "$(disk_model "$name")"
printf '镜像大小 / Image size    : %s MiB\n' "$(( (bytes + 1048575) / 1048576 ))"
printf '\n正在校验安装载荷，请稍候…… / Verifying the installer payload (this can take a moment)...\n'
verify_one "$mode.img.gz"
verify_one "$mode.img.bytes"
verify_one "$mode.img.raw-sha256"
gzip -t "$payload" || fail '压缩镜像已损坏 / The compressed disk image is corrupt.'

printf '\n警告：目标盘的全部分区及数据都将被删除 / WARNING: ALL PARTITIONS AND ALL DATA ON %s WILL BE DESTROYED.\n' "$disk"
printf '本次全新安装不保留目标盘上的任何配置 / This installs a fresh system and does not preserve any configuration.\n'

# 第二次确认只要求回车：目标盘已在上面明确选定过一次，
# 这里再敲一遍完整路径既容易输错，也没有额外的安全收益。
printf '\n按回车确认清空目标磁盘并安装，输入其他内容取消 / Press Enter to erase %s and install, or type anything to cancel: ' "$disk"
read -r confirmation
case "$confirmation" in
    '') ;;
    *) fail '安装已取消，尚未写入任何数据 / Installation cancelled. Nothing was written.' ;;
esac

valid_disk "$name" || fail '目标磁盘已不可用 / The target disk is no longer available.'
check_unused "$name"

printf '\n正在写盘，请勿断电或拔出安装介质…… / Writing the disk image. Do not power off, do not remove the medium...\n'
if ! gzip -dc "$payload" | dd of="$disk" bs=1048576 conv=fsync 2>/dev/null; then
    fail '写盘失败，目标盘内容不完整，请勿从该盘启动 / Disk write failed. The target is incomplete; do not boot it.'
fi
sync

# 整盘回读校验必须在打补丁之前完成：打完补丁磁盘就不再等于载荷了。
printf '正在回读校验已写入的数据…… / Verifying the written data...\n'
expected=$(cat "$PAYLOAD_DIR/$mode.img.raw-sha256")
actual=$(head -c "$bytes" "$disk" | sha256sum)
actual=${actual%% *}
[ "$actual" = "$expected" ] || fail '写盘回读校验失败，请勿从目标盘启动 / Written disk checksum mismatch. Do not boot the target.'
sync

# =============================================================================
# 把网口选择写进刚写入的 rootfs
# =============================================================================
lan_url='192.168.1.1'
if [ -n "$lan_ip" ]; then lan_url=$lan_ip; fi

if [ "$nic_apply_needed" -eq 1 ]; then
    printf '\n正在写入网口及网络配置…… / Applying network configuration...\n'
    part=$(nic_mount_rootfs "$disk" "$name") || part=''
    if [ -z "$part" ]; then
        fail "磁盘已写入，但无法挂载根分区，网络配置未应用，请手动修复 / The disk was written, but the new rootfs partition could not be mounted, so the network configuration was NOT applied. Boot the target and fix the network manually."
    fi

    if ! nic_apply_all "$ROOTMNT"; then
        umount "$ROOTMNT" 2>/dev/null || true
        fail "磁盘已写入，但保存网络配置失败，请手动修复 / The disk was written, but writing the network configuration failed. Boot the target and fix the network manually."
    fi
    sync

    if ! umount "$ROOTMNT" 2>/dev/null; then
        fail "磁盘已写入，但根分区卸载失败，网络配置可能不完整 / The disk was written, but unmounting the rootfs partition failed. Network configuration may be incomplete."
    fi

    # 只读复验：确认落盘的确实是我们要的配置
    if ! mount -t ext4 -o ro "$part" "$ROOTMNT" 2>/dev/null; then
        fail "磁盘已写入，但无法重新挂载进行复验，网络配置可能不完整 / The disk was written, but the rootfs partition could not be re-mounted for verification. Network configuration may be incomplete."
    fi
    if ! nic_verify "$ROOTMNT"; then
        umount "$ROOTMNT" 2>/dev/null || true
        fail "磁盘已写入，但网络配置复验失败，请手动修复 / The disk was written, but the network configuration did not verify. Boot the target and fix the network manually."
    fi
    umount "$ROOTMNT" 2>/dev/null || true
    printf '网络配置已写入并验证通过 / Network configuration applied and verified.\n'
else
    printf '\n未检测到网口，保留内置网络配置 / Network configuration left at the built-in default (no interface was detected).\n'
fi

printf '\n安装完成，校验通过 / Installation complete and verified.\n'
printf '请关机或重启，移除安装介质后从目标盘启动 / Shut down or reboot, remove the installer medium, then boot from %s (%s mode).\n' "$disk" "$mode"
printf '管理页面地址 / Management UI defaults to http://%s/ - set a root password after boot.\n' "$lan_url"
printf '根分区保持内置的6GiB大小，不会自动扩展到整盘 / The root partition keeps its built-in size (6 GiB); it is not expanded automatically.\n'
printf '说明：整盘校验发生在网络配置写入之前 / Note: the whole-disk checksum was verified BEFORE the network settings were written,\n'
printf '写入网络配置后，整盘数据会与原载荷有所不同 / so the final disk intentionally no longer matches the payload image byte for byte.\n'
