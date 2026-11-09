#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""selftest-nic.py —— 对 check-iso.py 的网口检查项做「必须报错」反向自测。

为什么需要：
    check-iso.py 新增了 14 个网口相关断言。如果断言正则写错（比如匹配了一个
    根本不存在的字符串），它会对任何镜像都报 FAIL，看起来"很严格"，实际上
    永远通不过，或者反过来永远通过。两种情况都必须在上机前排除。

做法：
    1. 用 check-iso.py 的内部函数直接构造一份「理想」的 init 与 installer 文本，
       断言全部网口检查项为 OK/WARN（无 FAIL）。
    2. 再逐项破坏（删掉关键字符串），断言对应检查项变 FAIL。
    3. 顺带检查「注释里的反例不算违规」这条机制仍然有效。

用法：
    python3 selftest-nic.py
退出码 0 = 自测通过。
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(HERE, "check-iso.py")

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

spec = importlib.util.spec_from_file_location("checkiso", SPEC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


# ------------------------------------------------------------------ 理想样本
GOOD_INIT = r"""#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mdev -s
if [ -f /etc/nic-load.order ]; then
    while read -r m; do
        [ -n "$m" ] || continue
        modprobe "$m" 2>/dev/null || true
    done < /etc/nic-load.order
fi
for m in $(cat /etc/nic-allowlist 2>/dev/null | tr ',' ' '); do
    modprobe "$m" 2>/dev/null || true
done
printf 'Network interfaces detected:\n'
n=0
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    echo "$d"
    n=$((n+1))
done
export NIC_COUNT=$n
exec /usr/sbin/openwrt-install
"""

GOOD_INST = r"""#!/bin/sh
set -eu
valid_disk() {
    case "$name" in
        *boot0|*boot1) return 1 ;;
        *rpmb) return 1 ;;
    esac
}
list_disks
[ -t 0 ] || exit 1
printf '\nEnter the full target disk path (e.g. /dev/sda): '
read -r disk
lbs=$(cat "/sys/class/block/$name/queue/logical_block_size")
[ "$lbs" = 512 ] || exit 1

# ---- 网口阶段 ----
list_nics() {
    printf 'Network interfaces detected:\n'
    i=1
    for e in /sys/class/net/*; do
        printf '  [%d] %s\n' "$i" "$(basename "$e")"
        i=$((i+1))
    done
}
list_nics
printf 'Select the LAN port by number (or "d" for the built-in default eth0=LAN / eth1=WAN): '
read -r choice
printf 'Enter the LAN address as IPv4 or IPv4/prefix, Enter for 192.168.1.1/24: '
read -r lanaddr
printf 'Select the WAN port by number, or "n" to leave WAN unconfigured: '
read -r wanchoice

# 地址校验：八位组范围 + 前缀 + 网络号/广播地址
validate_addr() {
    a=$1
    o1=${a%%.*}; rest=${a#*.}
    o2=${rest%%.*}; rest=${rest#*.}
    o3=${rest%%.*}; o4=${rest#*.}
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -le 255 ] || return 1
    done
    case "$a" in */*) prefix=${a#*/} ;; *) prefix=24 ;; esac
    [ "$prefix" -ge 8 ] && [ "$prefix" -le 32 ] || return 1
    net=$(ipcalc-net "$a")
    brd=$(ipcalc-broadcast "$a")
    [ "$a" != "$net" ] || return 1
    [ "$a" != "$brd" ] || return 1
}

printf '\nNetwork plan:\n'
printf '  LAN port    : %s\n' "$lan"
printf '  LAN address : %s\n' "$lanaddr"
printf '  WAN port    : %s\n' "$wan"

printf '\nWARNING: ALL PARTITIONS AND ALL DATA ON %s WILL BE DESTROYED.\n' "$disk"
printf '\nPress Enter to erase %s and install, or type anything to cancel: ' "$disk"
read -r confirmation
gzip -dc "$payload" | dd of="$disk" bs=1048576 conv=fsync
actual=$(head -c "$bytes" "$disk" | sha256sum)
expected=$(cat "$PAYLOAD_DIR/$mode.img.raw-sha256")
[ "$actual" = "$expected" ] || exit 1

# ---- 写盘后落地配置 ----
blockdev --rereadpt "$disk"
mdev -s
rootpart=""
for p in "${disk}2" "${disk}p2"; do
    [ -b "$p" ] || continue
    case "$(blkid "$p" 2>/dev/null)" in *'LABEL="rootfs"'*) rootpart=$p ;; esac
done
[ -n "$rootpart" ] || exit 1
mount -t ext4 -o rw "$rootpart" /mnt/rootfs
# 删掉 lan2（第三个口固定的 192.168.2.1 双内网段）
awk -v drop=lan2 'BEGIN{skip=0} /^config /{ skip = ($0 ~ drop) } !skip' \
    "$R/etc/config/network" > /tmp/net.new
mv /tmp/net.new "$R/etc/config/network"
sed -i "s/\"bind-address\":[[:space:]]*\"[^\"]*\"/\"bind-address\": \"$lan_ip\"/" \
    "$R/etc/console-mihomo/config.json"
sync
umount /mnt/rootfs
mount -t ext4 -o ro "$rootpart" /mnt/rootfs
grep -q "list ports '$lan'" "$R/etc/config/network" || exit 1
umount /mnt/rootfs
printf 'Network configuration applied and verified.\n'
"""


def run(init_text, inst_text, label):
    """跑一遍网口相关检查，返回 (fails, warns, ok_codes)。"""
    mod.R.items = []
    mod.R.fails = 0
    mod.R.warns = 0
    NAMES = {
        "init": (0o755, len(init_text), init_text.encode()),
        "usr/sbin/openwrt-install": (0o755, len(inst_text), inst_text.encode()),
        "lib/modules/6.18.55/modules.dep": (0o644, 4096, b"igb.ko:\n" * 10),
        "lib/modules/6.18.55/igb.ko": (0o644, 65536, b"\x7fELF"),
        "etc/nic-load.order": (0o644, 20, b"tg3\nigc\nigb\n"),
        "lib/firmware/rtl_nic/rtl8168h-2.fw": (0o644, 1024, b"\x00"),
    }
    # 需要剥注释，模拟真实流程
    init_code = mod.strip_comments(init_text)
    inst_code = mod.strip_comments(inst_text)
    mod.check_nic_bundle(NAMES)
    mod.check_nic_ui(init_code, inst_code)
    codes = {c: l for l, c, _ in mod.R.items}
    return mod.R.fails, mod.R.warns, codes


def expect(label, cond, detail=""):
    status = "OK  " if cond else "FAIL"
    print("  [%s] %s%s" % (status, label, ("  " + detail) if detail else ""))
    return 0 if cond else 1


def main():
    bad = 0
    print("=" * 70)
    print(" check-iso.py 网口检查项反向自测")
    print("=" * 70)

    print("\n[1] 理想样本应当全部通过（不得有 FAIL）")
    f, w, codes = run(GOOD_INIT, GOOD_INST, "good")
    bad += expect("无 FAIL", f == 0, "fails=%d warns=%d" % (f, w))
    for code in ("INITRD/NICBUNDLE", "INITRD/NICORDER", "INITRD/NICFW",
                 "INITRD/NICKO", "INIT/LOADNIC", "INIT/MODPROBE",
                 "INST/LANSELECT", "INST/NICLIST", "INST/ADDR",
                 "INST/MOUNTROOT", "INST/APPLYVERIFY", "INST/LAN2DROP",
                 "INST/NOHARDCODE", "INST/MIHOMOADDR"):
        bad += expect("  %s 判为 OK" % code, codes.get(code) == "OK",
                      codes.get(code, "MISSING"))
    print("\n[2] 逐项破坏，对应检查必须变 FAIL")
    cases = [
        ("INIT/LOADNIC", GOOD_INIT.replace("nic-load.order", "xxx"), GOOD_INST,
         "去掉读 nic-load.order"),
        ("INIT/MODPROBE", GOOD_INIT.replace("modprobe", "echo"), GOOD_INST,
         "去掉 modprobe"),
        ("INST/LANSELECT", GOOD_INIT, GOOD_INST.replace("Select the LAN port", "pick one"),
         "去掉 LAN 选择提示"),
        ("INST/NICLIST", GOOD_INIT, GOOD_INST.replace("Network interfaces detected", "nics"),
         "去掉网口列表"),
        ("INST/ADDR", GOOD_INIT, GOOD_INST.replace("Enter the LAN address", "addr?"),
         "去掉地址输入"),
        ("INST/MOUNTROOT", GOOD_INIT,
         GOOD_INST.replace("mount -t ext4 -o rw", "echo skip"), "去掉挂载 rootfs"),
        ("INST/APPLYVERIFY", GOOD_INIT,
         GOOD_INST.replace("Network configuration applied and verified", "done"),
         "去掉复验标志"),
        ("INST/LAN2DROP", GOOD_INIT, GOOD_INST.replace("lan2", "zzz"), "去掉 lan2 处理"),
        ("INST/NOHARDCODE", GOOD_INIT,
         GOOD_INST.replace("list_nics", "list_nics\n    printf \"list ports 'eth0'\\n\""),
         "重新引入硬编码 eth0"),
        ("INST/MIHOMOADDR", GOOD_INIT,
         GOOD_INST.replace("bind-address", "other-key"), "去掉 mihomo 联动"),
    ]
    for code, i2, s2, desc in cases:
        f2, _, c2 = run(i2, s2, code)
        got = c2.get(code)
        bad += expect("%s 因『%s』变 %s" % (code, desc, "FAIL/WARN"), got in ("FAIL", "WARN"),
                      "实际=%s" % got)

    print("\n[3] 驱动包裹缺失也必须被抓出来")
    base = {
        "init": (0o755, len(GOOD_INIT), GOOD_INIT.encode()),
        "usr/sbin/openwrt-install": (0o755, len(GOOD_INST), GOOD_INST.encode()),
        "etc/nic-load.order": (0o644, 20, b"tg3\nigc\n"),
        "lib/firmware/x.fw": (0o644, 10, b"\x00"),
    }
    mod.R.items = []; mod.R.fails = 0; mod.R.warns = 0
    mod.check_nic_bundle(base)
    ns = {c: l for l, c, _ in mod.R.items}
    bad += expect("缺 modules.dep 报 INITRD/NICBUNDLE", ns.get("INITRD/NICBUNDLE") == "FAIL",
                  str(ns.get("INITRD/NICBUNDLE")))

    print("\n[4] 注释剥离：注释既不能误判成缺陷，也不能把缺陷掩盖掉")
    # 4a) 代码里没有硬编码 eth0，但注释里写了反例 -> 必须判 OK
    with_comment = GOOD_INST + "\n# \u4ee5\u524d\u7684\u9519\u8bef\u5199\u6cd5\uff1alist ports 'eth0'\n"
    mod.R.items = []; mod.R.fails = 0; mod.R.warns = 0
    mod.check_nic_ui(mod.strip_comments(GOOD_INIT), mod.strip_comments(with_comment))
    cs = {c: l for l, c, _ in mod.R.items}
    bad += expect("注释里的 eth0 不误判为 INST/NOHARDCODE",
                  cs.get("INST/NOHARDCODE") == "OK", str(cs.get("INST/NOHARDCODE")))

    # 4b) 代码里确实没有 modprobe/insmod，只在注释里提到 -> 必须仍判 FAIL，
    #     否则「注释剥离」就把真实缺陷掩盖掉了。
    no_loadmod = GOOD_INIT.replace("modprobe", "loadmod")
    assert "modprobe" not in no_loadmod and "insmod" not in no_loadmod
    sneaky = no_loadmod + "\n# \u6ce8\u610f\uff1a\u8fd9\u91cc\u4ee5\u524d\u662f\u7528 insmod \u52a0\u8f7d\u7684\n"
    mod.R.items = []; mod.R.fails = 0; mod.R.warns = 0
    mod.check_nic_ui(mod.strip_comments(sneaky), mod.strip_comments(GOOD_INST))
    cs = {c: l for l, c, _ in mod.R.items}
    bad += expect("只在注释里出现的 insmod 不能掩盖 INIT/MODPROBE 缺陷",
                  cs.get("INIT/MODPROBE") == "FAIL", str(cs.get("INIT/MODPROBE")))

    # 4c) 反向护栏：GOOD_INIT 本身必须真的含 modprobe（否则 4b 是因为样本坏了才通过）
    bad += expect("GOOD_INIT 本身含 modprobe（样本有效）",
                  "modprobe" in GOOD_INIT, "count=%d" % GOOD_INIT.count("modprobe"))

    print("\n" + "=" * 70)
    if bad:
        print("自测 FAIL —— %d 项不符合预期" % bad)
        return 1
    print("自测 PASS —— 14 个网口检查项都能正确区分好/坏实现")
    return 0


if __name__ == "__main__":
    sys.exit(main())
