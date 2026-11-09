#!/bin/bash
# =============================================================================
# verify-e2e.sh —— 四场景端到端验证（真装一块空盘，回读比对 + 解析装后配置）
#
# 为什么需要它
#   静态检查能抓住「结构上必然启动不了」的问题，但抓不住「能启动但装不对」。
#   这个脚本真正把镜像写进一块空盘，再整盘回读与载荷逐字节比对，
#   所以能证明：引导 → 磁盘枚举 → 网口选择 → 确认流程 → 写入 → 回读 → 网络配置落地
#   全链路可用。
#
# 四个场景覆盖用户实际会遇到的每一种引导方式：
#   cdrom-bios   光驱 + SeaBIOS
#   cdrom-uefi   光驱 + OVMF
#   usb-bios     ISO dd 到 U 盘（USB 大容量存储）+ SeaBIOS
#   usb-uefi     同上 + OVMF
#
# 每个场景四段，任一失败即定位到具体环节：
#   A 引导到安装器界面   B 列出磁盘   C 按新交互装完并回读校验   D 装后网络配置校验
#
# 本版本（NIC-SPEC 第 7 节）相对上一版的变化
#   1. 每个场景加 3 块 e1000 网卡，保证 guest 里出现 eth0/eth1/eth2，
#      从而真正走一遍「识别网口 → 手选 LAN → 输地址 → 选 WAN」。
#   2. 驱动脚本按新交互逐步发送，提问文本严格取自 NIC-SPEC 4.3。
#   3. 装完之后不再整盘等于载荷 —— 安装器会在写盘校验之后挂载新 rootfs
#      改写网络配置（NIC-SPEC 4.6，设计如此）。所以回读校验改为
#      「rootfs 分区以外逐字节等于载荷」，rootfs 分区改由 D 段解析检查。
#   4. 新增退出码 7 = 装后网络配置校验失败；8 = 网口阶段失败（没列出网口 /
#      没有选择提示），与「安装失败」区分开，便于定位。
#
# 依赖：qemu-system-x86_64 + KVM、python3-pexpect、OVMF($OVMF_DIR)、
#       losetup/mount + e2fsprogs（装后解析 rootfs 分区用）
# 耗时：约 25 分钟（4 场景 × 约 6 分钟）
#
# 用法：
#   bash verify-e2e.sh                          # 全部场景
#   ONLY="usb-bios" bash verify-e2e.sh          # 只跑指定场景
#   TARGET_MIB=8192 TM=900 bash verify-e2e.sh   # 调目标盘大小/超时
#   NIC_QEMU=3 LAN_ADDR=192.168.88.1/24 bash verify-e2e.sh
#   REQUIRE_NIC=0 bash verify-e2e.sh            # 冒烟：允许旧镜像（无网口阶段）
#   OS_NAME=AOS-20261109-V1 bash verify-e2e.sh  # 同时断言装后系统名/版本标识
#
# 退出码：0 全通过，1 有失败，2 环境不满足
#         3 引导失败 / 4 磁盘枚举失败 / 5 安装失败 / 6 回读校验失败
#         7 装后网络配置校验失败 / 8 网口阶段失败
# =============================================================================
set -uo pipefail
export LC_ALL=C

ISO=${ISO:-/home/openwrt/console-sync/openwrt-console-installer.iso}
BODY=${BODY:-/home/openwrt/router-build/out}
WORK=${WORK:-/home/openwrt/verify-e2e}
TARGET_MIB=${TARGET_MIB:-8192}
TM=${TM:-900}
OVMF_DIR=${OVMF_DIR:-/usr/share/OVMF}
SCENES=${ONLY:-cdrom-bios cdrom-uefi usb-bios usb-uefi}

# ---- 网口相关（NIC-SPEC 第 7 节）
NIC_QEMU=${NIC_QEMU:-3}                       # QEMU 里挂几块 e1000
LAN_INDEX=${LAN_INDEX:-2}                     # 选列表里第几个网口做 LAN（1 起）
LAN_ADDR=${LAN_ADDR:-192.168.88.1/24}         # 故意不用默认 192.168.1.1/24，
                                              # 否则「改没改」分不出来
WAN_INDEX=${WAN_INDEX:-2}                     # 剩余端口里选第几个做 WAN
REQUIRE_NIC=${REQUIRE_NIC:-1}                 # 1=必须有网口阶段（新交互）
RELEASE_VERSION=${RELEASE_VERSION:-}
OS_NAME=${OS_NAME:-}
EXPECTED_CODE_MANIFEST=${EXPECTED_CODE_MANIFEST:-}

log(){  printf '\n\033[1m[verify] %s\033[0m\n' "$*"; }
ok(){   printf '  [ok] %s\n' "$*"; }
bad(){  printf '  [FAIL] %s\n' "$*"; }
warn(){ printf '  [warn] %s\n' "$*"; }
die(){  printf '\n[verify] ERROR: %s\n' "$*" >&2; exit 2; }

# ------------------------------------------------------------------ 环境
log "环境检查"
[ -f "$ISO" ] || die "找不到 ISO: $ISO"
command -v qemu-system-x86_64 >/dev/null || die "缺 qemu-system-x86_64"
python3 -c 'import pexpect' 2>/dev/null \
    || die "缺 python3-pexpect（apt install python3-pexpect）"
[ -f "$OVMF_DIR/OVMF_CODE_4M.fd" ] || die "缺 $OVMF_DIR/OVMF_CODE_4M.fd（apt install ovmf）"
[ -f "$OVMF_DIR/OVMF_VARS_4M.fd" ] || die "缺 $OVMF_DIR/OVMF_VARS_4M.fd"
[ -e /dev/kvm ] || die "缺 /dev/kvm —— 没有 KVM 会慢到不可用"
command -v losetup >/dev/null || die "缺 losetup（装后解析 rootfs 分区用）"
for m in bios uefi; do
    [ -f "$BODY/$m.img.raw-sha256" ] || die "缺载荷元数据 $BODY/$m.img.raw-sha256"
    [ -f "$BODY/$m.img.bytes" ]       || die "缺载荷元数据 $BODY/$m.img.bytes"
    [ -f "$BODY/$m.img.gz" ]          || die "缺载荷镜像 $BODY/$m.img.gz"
done

mkdir -p "$WORK"
: > "$WORK/summary.txt"
ls -l "$ISO"
sha256sum "$ISO"
ok "环境就绪（每场景 $NIC_QEMU 块 e1000，LAN 取第 $LAN_INDEX 个口，地址 $LAN_ADDR）"

# ------------------------------------------------------------------ 驱动
# /init 会自动执行 openwrt-install（无参数），后者先列盘再提示输入路径。
# 所以「Enter the full target disk path」出现，就说明引导成功且安装器就绪。
#
# 之后按 NIC-SPEC 4.1 的真实顺序走：
#   输目标盘路径 → 选 LAN 编号 → 输 LAN 地址 → 选 WAN 编号 → 回车确认擦除
# 注意网口阶段排在「Press Enter to erase」之前，所以确认擦除那一步必须等到
# 三个网口提问都答完才会出现。
cat > "$WORK/drive.py" <<'PYEOF'
import os, sys, re, json, time

scene = sys.argv[1]
cfg = json.loads(sys.argv[2])
d, fw, tm = cfg["dir"], cfg["fw"], float(cfg["timeout"])
target = cfg["target"]
lan_pick = int(cfg.get("lan_index", 2))
lan_addr = cfg.get("lan_addr", "192.168.88.1/24")
wan_pick = int(cfg.get("wan_index", 2))
nic_qemu = int(cfg.get("nic_count", 3))
require_nic = int(cfg.get("require_nic", 1))

import pexpect

logf = open(os.path.join(d, "console.log"), "wb")

def w(s):
    if isinstance(s, str):
        s = s.encode()
    logf.write(s); logf.flush()

def readlog():
    # pexpect 通过 p.logfile_read 直接写同一个文件句柄，但它自己不 flush。
    # 不在这里主动 flush，就会读到「安装器已经打印、但还在缓冲里没落盘」的
    # 旧内容 —— 表现为明明有 Network plan 摘要却报 WARN（实测四个场景全中）。
    try:
        logf.flush()
    except Exception:
        pass
    with open(os.path.join(d, "console.log"), "rb") as f:
        return f.read().decode("utf-8", "replace")

env = dict(os.environ); env["QEMU_AUDIO_DRV"] = "none"
cmd = ["qemu-system-x86_64", "-m", "3072", "-smp", "2", "-nographic",
       "-enable-kvm", "-cpu", "host", "-no-reboot"] + cfg["qemu"]
w("### CMD: " + " ".join(cmd) + "\n")

p = pexpect.spawn(cmd[0], cmd[1:], timeout=30, env=env, encoding=None,
                  dimensions=(50, 200))
p.logfile_read = logf

# The default entry uses the local VGA keyboard. Exercise the explicit serial
# entry here; PVE's no-UART VGA path is verified independently through QMP.
try:
    p.expect(r'executed automatically in', timeout=90)
    p.send('\x1b[B\r')
except Exception:
    logf.write(b'\n### FAIL: GRUB serial entry could not be selected\n')
    p.close(force=True)
    logf.close()
    sys.exit(3)

def wait_any(pats, timeout):
    try:
        return p.expect(list(pats) + [pexpect.TIMEOUT, pexpect.EOF], timeout=timeout)
    except Exception:
        return -1

def drain(sec):
    end = time.time() + sec
    while time.time() < end:
        try:
            p.expect([pexpect.TIMEOUT, pexpect.EOF], timeout=0.5)
        except Exception:
            return
        if not p.isalive():      # 注意是 isalive 不是 is_alive（pexpect 4.x）
            return

def finish(code):
    w("\n### EXIT %d\n" % code)
    try:
        p.close(force=True)
    except Exception:
        pass
    logf.close()
    sys.exit(code)

# NIC-SPEC 4.3 的提问文本，逐字节取自契约，用 re.escape 转义后匹配
PROMPT_LAN  = 'Select the LAN port by number (or "d" for the built-in default eth0=LAN / eth1=WAN):'
PROMPT_ADDR = 'Enter the LAN address as IPv4 or IPv4/prefix, Enter for 192.168.1.1/24:'
PROMPT_WAN  = 'Select the WAN port by number, or "n" to leave WAN unconfigured:'
RE_AUTOWAN  = r"Only one spare port is left: (\S+) will be the WAN port\."
RE_NOWAN    = r"No spare port for WAN; WAN will be left unconfigured\."
RE_DEFAULT  = r"Using the built-in default: LAN (\S+), WAN (\S+), LAN address (\S+)\."
RE_REQUIRED = r'A choice is required; press "d" to accept the built-in default\.'

# NIC-SPEC 4.2 的网口行：  [1] eth0  aa:bb:cc:dd:ee:ff  link=up    driver=igb   pci=0000:01:00.0
NIC_LINE = re.compile(
    r"^\s*\[(\d+)\]\s+(\S+)\s+([0-9A-Fa-f:]{17}|\?)\s+"
    r"link=(up|down)\s+driver=(\S+)\s+pci=(\S+)\s*$", re.M)

def parse_nics(text):
    """取 console.log 里最后一处安装器打印的网口列表（init 也打印同名标题，
    但 init 的没有 [n] 编号，所以按 [n] 行解析不会误取）。"""
    idx = text.rfind("Network interfaces detected:")
    if idx < 0:
        return []
    out = []
    started = False
    for line in text[idx:].splitlines()[1:]:
        m = NIC_LINE.match(line)
        if m:
            out.append({"n": int(m.group(1)), "name": m.group(2), "mac": m.group(3),
                        "link": m.group(4), "driver": m.group(5), "pci": m.group(6)})
            started = True
        elif not line.strip():
            # 串口输出是 CRLF，splitlines() 会在 \r 和 \n 处各断一次，
            # 于是每两行之间夹一个空行。空行不能当成「列表结束」，否则
            # 只会解析到第一个网口，后续选择全错。
            continue
        elif started:
            break
    return out

# ---------- A: 等安装器就绪 ----------
if wait_any([r"Enter the full target disk path"], tm) != 0:
    w("\n### STAGE A FAIL: installer never became ready\n")
    finish(3)
w("\n### STAGE A OK\n")

# ---------- B: 解析磁盘列表 ----------
raw = readlog()
listed = re.findall(r"/dev/(sd[a-z]|vd[a-z]|hd[a-z]|mmcblk\d+|nvme\d+n\d+)\s+(\d+) MiB", raw)
if not listed:
    w("\n### STAGE B FAIL: no installable disk listed\n")
    finish(4)
w("\n### STAGE B OK: %s\n" % ", ".join(sorted({a for a, _ in listed})))

# ---------- C: 真装 ----------
# 目标盘是唯一一块 TARGET_MIB 大小的盘；介质要么是光驱（不出现），
# 要么是一块明显更大的 U 盘镜像，不会混淆。
want = int(re.search(r"(\d+)", cfg["target_mib"]).group(1))
tgtdisk = None
for dev, mib in listed:
    if abs(int(mib) - want) <= 64:
        tgtdisk = "/dev/" + dev
        break
if not tgtdisk:
    w("\n### STAGE C FAIL: no disk of %s MiB in listing\n" % want)
    finish(4)
w("\n### STAGE C target=%s\n" % tgtdisk)

p.sendline(tgtdisk)                     # 第一次确认：输入完整路径

erase_re = r"Press Enter to erase %s" % re.escape(tgtdisk)

expect = {"nic_phase": False, "nics": [], "lan": None, "lan_addr": None,
          "wan": None, "wan_mode": "none", "disk": tgtdisk}

# ---------- C1: 网口阶段（NIC-SPEC 4.1 的 c 段） ----------
i = wait_any([re.escape(PROMPT_LAN), erase_re, r"ERROR:"], 900)
if i == 1:
    if require_nic:
        w("\n### STAGE C FAIL: installer has no NIC selection phase "
          "(image still the old one?)\n")
        finish(8)
    w("\n### STAGE C WARN: no NIC phase in this image; network assertions will be skipped\n")
    p.sendline("")
    if wait_any([r"Installation complete and verified", r"ERROR:"], 2400) != 0:
        w("\n### STAGE C FAIL: install did not complete\n")
        finish(5)
    w("\n### STAGE C OK (no NIC phase)\n")
    drain(3)
    try:
        p.sendline("poweroff")
        p.expect(pexpect.EOF, timeout=90)
    except Exception:
        pass
    json.dump(expect, open(os.path.join(d, "expect.json"), "w"), indent=1)
    finish(0)
elif i == 2:
    w("\n### STAGE C FAIL: installer reported an ERROR before the NIC phase\n")
    finish(5)
elif i != 0:
    w("\n### STAGE C FAIL: no LAN selection prompt\n")
    finish(8)

nics = parse_nics(readlog())
if not nics:
    w("\n### STAGE C FAIL: NIC list printed but no parseable port line\n")
    finish(8)
w("\n### STAGE C nics: %s\n" % ", ".join("%s(%s,%s)" % (x["name"], x["driver"], x["link"])
                                        for x in nics))
if len(nics) < nic_qemu:
    w("\n### STAGE C WARN: expected %d ports from %d e1000 NICs, saw %d "
      "(driver bundle incomplete?)\n" % (nic_qemu, nic_qemu, len(nics)))
if len(nics) < 1:
    w("\n### STAGE C FAIL: no usable port could be parsed from the installler\n")
    finish(8)
if len(nics) < 2:
    # 只有一个口时安装器会把 WAN 留空（NIC-SPEC 4.3 的「No spare port」分支）。
    # 这仍然是可用的一条路（LAN 能配），所以不判失败，只记录。
    w("\n### STAGE C NOTE: only %d port visible; WAN will be left unconfigured\n"
      % len(nics))

lan = nics[min(lan_pick, len(nics)) - 1]
w("\n### STAGE C LAN pick: [%d] %s\n" % (lan["n"], lan["name"]))
p.sendline(str(lan["n"]))

if wait_any([re.escape(PROMPT_ADDR), RE_REQUIRED, r"ERROR:"], 300) != 0:
    w("\n### STAGE C FAIL: no LAN address prompt\n")
    finish(8)
p.sendline(lan_addr)
w("\n### STAGE C LAN address: %s\n" % lan_addr)

spare = [x for x in nics if x["name"] != lan["name"]]
wan_mode = "none"
wan = None
saw_erase = False

# NIC-SPEC 4.3 的三个分支：
#   · 候选 ≥2  -> 发 WAN 提问，等我们回编号
#   · 候选 ==1 -> 安装器自己指定，根本不提问，只打一行 "Only one spare port..."
#   · 候选 ==0 -> 安装器只打 "No spare port for WAN..."
# 所以先按候选数决定等哪一组模式串；不能一律等 PROMPT_WAN，
# 否则单网口场景会一直等到超时。
if len(spare) >= 2:
    j = wait_any([re.escape(PROMPT_WAN), RE_AUTOWAN, RE_NOWAN, erase_re, r"ERROR:"], 600)
elif len(spare) == 1:
    j = wait_any([RE_AUTOWAN, re.escape(PROMPT_WAN), RE_NOWAN, erase_re, r"ERROR:"], 600)
else:
    j = wait_any([RE_NOWAN, re.escape(PROMPT_WAN), RE_AUTOWAN, erase_re, r"ERROR:"], 600)

if j < 0:
    w("\n### STAGE C FAIL: no WAN prompt / WAN decision seen\n")
    finish(8)
if j == 4:
    w("\n### STAGE C FAIL: installer reported an ERROR during the NIC phase\n")
    finish(5)
if j == 3:
    # 直接跳到了擦除确认 —— 只有「本来就该没有 WAN 提问」时才接受
    if len(spare) >= 2:
        w("\n### STAGE C FAIL: WAN prompt expected (%d spare ports) but skipped\n"
          % len(spare))
        finish(8)
    saw_erase = True
    w("\n### STAGE C WAN: none (installer skipped the WAN question)\n")
elif j == 0 and len(spare) >= 2:
    wan = spare[min(wan_pick, len(spare)) - 1]
    wan_mode = "prompt"
    w("\n### STAGE C WAN pick: [%d] %s\n" % (wan["n"], wan["name"]))
    p.sendline(str(wan["n"]))
else:
    # 自动 WAN 分支：读安装器自己打印的那一行来确定结果
    m = re.search(RE_AUTOWAN, readlog())
    if m:
        wan = {"name": m.group(1), "n": None}
        wan_mode = "auto"
        w("\n### STAGE C WAN auto: %s\n" % wan["name"])
    else:
        wan_mode = "none"
        w("\n### STAGE C WAN: none\n")

expect.update({"nic_phase": True, "nics": [x["name"] for x in nics],
               "lan": lan["name"], "lan_addr": lan_addr,
               "wan": (wan or {}).get("name"), "wan_mode": wan_mode})

# 摘要必须落在确认擦除之前（NIC-SPEC 4.4）：用户在破坏性操作前必须真的看到
# 自己的选择。
#
# 不能只「查一次日志快照」了事 —— 那是竞态：刚发完 WAN 编号的那一刻，安装器
# 可能还没把摘要打出来，于是稳定误报成「缺摘要」（实测四个场景全中，且是假阳性：
# 日志里摘要明明在擦除确认之前）。正确做法是等「摘要」和「擦除确认」谁先到，
# 谁先出现就直接判定顺序。
if not saw_erase:
    k = wait_any(["Network plan:", erase_re, r"ERROR:"], 180)
    if k == 0:
        w("\n### STAGE C summary block present (before erase prompt)\n")
        if wait_any([erase_re, r"ERROR:"], 900) != 0:
            w("\n### STAGE C FAIL: no erase confirmation prompt after the summary\n")
            finish(5)
        w("\n### STAGE C: erase confirmation shown\n")
    elif k == 1:
        w("\n### STAGE C FAIL: 'Network plan:' summary is missing or was printed "
          "AFTER the erase prompt\n")
        finish(5)
    else:
        w("\n### STAGE C FAIL: neither the summary nor the erase prompt appeared\n")
        finish(5)
else:
    # j==3 分支说明「擦除确认」已经从缓冲区里被消费掉了，此时只能回看日志。
    w("\n### STAGE C: erase confirmation seen before the WAN step\n")
    if "Network plan:" in readlog():
        w("\n### STAGE C summary block present\n")
    else:
        w("\n### STAGE C WARN: no 'Network plan:' summary (erase prompt came first)\n")

p.sendline("")                          # 第二次确认：只按回车
if wait_any([r"Installation complete and verified", r"ERROR:"], 2400) != 0:
    w("\n### STAGE C FAIL: install did not complete\n")
    finish(5)

# 安装器在写盘校验之后还会挂载新 rootfs 改写网络配置（NIC-SPEC 4.6），
# 那一步失败会明确报错，这里只确认它没有把「已应用」说成别的。
tail = readlog()
if "Network configuration applied and verified" in tail:
    w("\n### STAGE C: network configuration applied by installer\n")
else:
    w("\n### STAGE C WARN: installer did not report "
      "'Network configuration applied and verified'\n")
w("\n### STAGE C OK\n")

drain(3)
try:
    p.sendline("poweroff -f")
    p.expect(pexpect.EOF, timeout=90)
except Exception:
    w("\n### STAGE C FAIL: installer poweroff did not exit QEMU\n")
    finish(5)

json.dump(expect, open(os.path.join(d, "expect.json"), "w"), indent=1)
finish(0)
PYEOF
ok "驱动脚本已生成"

# ------------------------------------------------------------------ 装后检查器
# 这里负责两件事，都直接读 target.img 本身，不依赖 guest 里的任何东西：
#   1) locate  —— 纯 Python 解析 MBR/GPT 分区表，按 ext4 超级块的 LABEL
#                 找到 rootfs 分区，输出起始 LBA/扇区数。不调用 sgdisk/parted，
#                 因为有些构建机上没有 sgdisk 且 parted 会改动 GPT 备份头。
#   2) compare —— rootfs 分区以外逐字节与载荷比对。rootfs 分区被安装器有意
#                 改写过（NIC-SPEC 4.6），所以整盘不可能再等于载荷；把它排除
#                 掉，其余每个字节仍然必须一致，原有「回读校验」能力不退化。
#   3) assert  —— 对 shell 挂载后拷出来的配置文件做断言（NIC-SPEC 7.3）。
# 退出码：0 通过 / 6 回读不一致 / 7 网络配置不符
cat > "$WORK/checkimg.py" <<'PYEOF'
import json, os, re, struct, sys

MIB = 1048576


# ------------------------------------------------------------------ 分区表
def read_partitions(path):
    """返回 (ptype_mbr, [ {name, start_lba, sectors, scheme} ])。

    MBR：偏移 446 起 4 个 16 字节项，LBA 在 +8（小端 u32），扇区数在 +12。
    GPT：偏移 512 是头，分区项表位置在头内 +72（u64）、项数 +80（u32）、
         项大小 +84（u32）；每项首 LBA 在 +32（u64）、末 LBA 在 +40（u64）。
    """
    with open(path, "rb") as f:
        head = f.read(4096)
        if len(head) < 1024:
            raise RuntimeError("image is too small to hold a partition table")
        if head[510:512] != b"\x55\xaa":
            raise RuntimeError("no 0xAA55 boot signature in MBR")
        ptype = head[450]
        parts = []
        if ptype == 0xEE:
            hdr = head[512:1024]
            if hdr[:8] != b"EFI PART":
                raise RuntimeError("protective MBR present but GPT header missing")
            ent_lba, nent, esize = struct.unpack("<QII", hdr[72:88])
            f.seek(ent_lba * 512)
            tbl = f.read(nent * esize)
            for i in range(nent):
                e = tbl[i * esize:(i + 1) * esize]
                if len(e) < 128 or e[0:16] == b"\x00" * 16:
                    continue
                first, last = struct.unpack("<QQ", e[32:48])
                if last < first:
                    continue
                parts.append({"scheme": "gpt", "index": i + 1, "start_lba": first,
                              "sectors": last - first + 1,
                              "type_guid": e[0:16].hex()})
        else:
            for i in range(4):
                e = head[446 + 16 * i: 446 + 16 * (i + 1)]
                ptype_i = e[4]
                lba, nsect = struct.unpack("<II", e[8:16])
                if ptype_i == 0 or lba == 0 or nsect == 0:
                    continue
                parts.append({"scheme": "mbr", "index": i + 1, "start_lba": lba,
                              "sectors": nsect, "type_byte": ptype_i})
        return ptype, parts


def ext4_label(path, start_lba):
    """读分区起始偏移 +1024 处的 ext4 超级块，返回 (label, ok)。

    ext4 超级块固定在该分区第 1024 字节；0x53 0xEF 是魔数（+56），
    s_volume_name 在 +120，16 字节。
    """
    with open(path, "rb") as f:
        f.seek(start_lba * 512 + 1024)
        sb = f.read(1024)
    if len(sb) < 1024:
        return None, False
    if struct.unpack("<H", sb[56:58])[0] != 0xEF53:
        return None, False
    return sb[120:136].split(b"\x00")[0].decode("latin1"), True


def cmd_locate(path, fw):
    ptype, parts = read_partitions(path)
    if fw == "uefi" and ptype != 0xEE:
        print("FAIL protective MBR missing (type=%02x, want ee)" % ptype)
        return 6
    if fw != "uefi" and ptype not in (0x83, 0xEE):
        print("FAIL first partition is not Linux (type=%02x)" % ptype)
        return 6
    found = []
    for p in parts:
        label, isext = ext4_label(path, p["start_lba"])
        p["label"] = label if isext else None
        p["ext4"] = isext
        found.append(p)
        print("PART %(scheme)s%(index)d start_lba=%(start_lba)d "
              "sectors=%(sectors)d ext4=%(ext4)s label=%(label)s" % p)
    root = None
    for p in found:
        if p["ext4"] and p["label"] == "rootfs":
            root = p
            break
    if root is None:
        # 兜底：UEFI 布局里 ESP 在前、rootfs 在后；BIOS 布局里 boot 在前。
        # 没有 LABEL 时退化为「最后一个 ext4 分区」。
        exts = [p for p in found if p["ext4"]]
        if exts:
            root = exts[-1]
    if root is None:
        print("FAIL no ext4 partition found on the installed disk")
        return 7
    print("ROOTFS start_lba=%d sectors=%d label=%s"
          % (root["start_lba"], root["sectors"], root["label"]))
    return 0


# ------------------------------------------------------------------ 逐字节比对
def cmd_compare(target, payload, nbytes, skip_lba, skip_sectors):
    import gzip
    skip_lo = skip_lba * 512
    skip_hi = skip_lo + skip_sectors * 512
    CH = 1 << 20
    off = 0
    compared = 0
    mismatches = 0
    first_bad = None
    gz = gzip.open(payload, "rb")
    tf = open(target, "rb")
    while off < nbytes:
        n = min(CH, nbytes - off)
        a = gz.read(n)
        if len(a) != n:
            print("FAIL payload is shorter than %d bytes (ended at %d)" % (nbytes, off))
            return 6
        b = tf.read(n)
        if len(b) != n:
            print("FAIL target image is shorter than %d bytes" % nbytes)
            return 6
        lo = max(off, skip_lo)
        hi = min(off + n, skip_hi)
        if lo < hi:
            # 跳过被安装器改写过的 rootfs 区间
            i, j = lo - off, hi - off
            segs = [(a[:i], b[:i]), (a[j:], b[j:])]
            done = n - (j - i)
        else:
            segs = [(a, b)]
            done = n
        for ms, ts in segs:
            if ms != ts:
                for k in range(len(ms)):
                    if ms[k] != ts[k]:
                        if first_bad is None:
                            first_bad = off + k
                        mismatches += 1
                        break
        compared += done
        off += n
    print("compared=%d bytes, skipped rootfs=%d bytes at offset %d, mismatches=%d"
          % (compared, max(0, min(skip_hi, nbytes) - skip_lo), skip_lo, mismatches))
    if first_bad is not None:
        print("FAIL first difference at offset %d" % first_bad)
        return 6
    return 0


# ------------------------------------------------------------------ UCI 解析
SEC_RE = re.compile(r"^config\s+(\S+)(?:\s+['\"]?([^'\"]+)['\"]?)?\s*$")
OPT_RE = re.compile(r"^(?:option)\s+(\S+)\s+['\"]?([^'\"]*)['\"]?\s*$")
LIST_RE = re.compile(r"^(?:list)\s+(\S+)\s+['\"]?([^'\"]*)['\"]?\s*$")


def parse_uci(text):
    secs = []
    cur = None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = SEC_RE.match(s)
        if m:
            cur = {"type": m.group(1), "name": m.group(2) or None,
                   "options": {}, "lists": {}}
            secs.append(cur)
            continue
        if cur is None:
            continue
        m = OPT_RE.match(s)
        if m:
            cur["options"][m.group(1)] = m.group(2)
            continue
        m = LIST_RE.match(s)
        if m:
            cur["lists"].setdefault(m.group(1), []).append(m.group(2))
    return secs


def find_sec(secs, stype, name=None):
    for s in secs:
        if s["type"] == stype and (name is None or s["name"] == name):
            return s
    return None


def cmd_assert(root, expect_path):
    exp = json.load(open(expect_path))
    lan, addr, wan = exp.get("lan"), exp.get("lan_addr"), exp.get("wan")
    net_path = os.path.join(root, "etc/config/network")
    fw_path = os.path.join(root, "etc/config/firewall")
    bj_path = os.path.join(root, "etc/board.json")
    ip_path = os.path.join(root, "etc/console-install-ports.json")
    mi_path = os.path.join(root, "etc/console-mihomo/config.json")

    results = []

    def check(cond, good, badmsg):
        if cond:
            results.append((True, good))
        else:
            results.append((False, badmsg))
        print("  [%s] %s" % ("ok" if cond else "FAIL", good if cond else badmsg))

    if not exp.get("nic_phase"):
        print("  [warn] image had no NIC phase; network assertions skipped")
        return 0

    if not os.path.isfile(net_path):
        print("  [FAIL] /etc/config/network not found in the installed rootfs")
        return 7

    net = parse_uci(open(net_path, encoding="utf-8", errors="replace").read())
    dev = find_sec(net, "device")
    lan_if = find_sec(net, "interface", "lan")
    wan_if = find_sec(net, "interface", "wan")
    wan6_if = find_sec(net, "interface", "wan6")
    lan2_if = find_sec(net, "interface", "lan2")

    ports = []
    for s in net:
        if s["type"] == "device" and s["options"].get("name") == "br-lan":
            ports = s["lists"].get("ports", [])
    check(ports == [lan], "br-lan ports == %s" % lan,
          "br-lan ports is %r, expected [%r]" % (ports, lan))

    ipaddrs = lan_if["lists"].get("ipaddr", []) if lan_if else []
    check(ipaddrs == [addr], "lan ipaddr == %s" % addr,
          "lan ipaddr is %r, expected [%r]" % (ipaddrs, addr))

    if wan:
        got = (wan_if or {}).get("options", {}).get("device")
        check(got == wan, "wan device == %s" % wan,
              "wan device is %r, expected %r" % (got, wan))
        got6 = (wan6_if or {}).get("options", {}).get("device")
        check(got6 in (None, wan), "wan6 device consistent with %s" % wan,
              "wan6 device is %r, expected %r" % (got6, wan))
    else:
        check(wan_if is None, "no wan interface (WAN left unconfigured)",
              "wan interface still present although WAN was left unconfigured")
        check(wan6_if is None, "no wan6 interface (WAN left unconfigured)",
              "wan6 interface still present although WAN was left unconfigured")

    check(lan2_if is None, "no lan2 interface (removed)",
          "lan2 interface still present in /etc/config/network")

    fw_text = open(fw_path, encoding="utf-8", errors="replace").read() \
        if os.path.isfile(fw_path) else ""
    check("lan2" not in fw_text, "firewall has no lan2 reference",
          "firewall still references lan2")
    if not wan:
        check("list network 'wan'" not in fw_text and 'list network "wan"' not in fw_text,
              "firewall has no wan zone membership",
              "firewall still lists network 'wan' although WAN is unconfigured")

    if os.path.isfile(bj_path):
        try:
            bj = json.load(open(bj_path, encoding="utf-8", errors="replace"))
            bn = bj.get("network", {})
            got = (bn.get("lan") or {}).get("device")
            check(got == lan, "board.json network.lan.device == %s" % lan,
                  "board.json network.lan.device is %r, expected %r" % (got, lan))
            gw = (bn.get("wan") or {}).get("device")
            if wan:
                check(gw == wan, "board.json network.wan.device == %s" % wan,
                      "board.json network.wan.device is %r, expected %r" % (gw, wan))
            else:
                check("wan" not in bn, "board.json has no network.wan",
                      "board.json still has network.wan although WAN is unconfigured")
        except Exception as exc:
            check(False, "", "board.json is not valid JSON: %s" % exc)
    else:
        check(False, "", "/etc/board.json is missing from the installed rootfs")

    if os.path.isfile(ip_path):
        try:
            ipj = json.load(open(ip_path, encoding="utf-8", errors="replace"))
            got = (ipj.get("lan") or {}).get("name")
            check(got == lan, "console-install-ports.json lan.name == %s" % lan,
                  "console-install-ports.json lan.name is %r, expected %r" % (got, lan))
            check(ipj.get("address") == addr,
                  "console-install-ports.json address == %s" % addr,
                  "console-install-ports.json address is %r, expected %r"
                  % (ipj.get("address"), addr))
            if wan:
                wgot = (ipj.get("wan") or {}).get("name")
                check(wgot == wan, "console-install-ports.json wan.name == %s" % wan,
                      "console-install-ports.json wan.name is %r, expected %r"
                      % (wgot, wan))
            else:
                check(ipj.get("wan") is None,
                      "console-install-ports.json wan == null",
                      "console-install-ports.json wan is %r, expected null"
                      % (ipj.get("wan"),))
        except Exception as exc:
            check(False, "", "/etc/console-install-ports.json is unusable: %s" % exc)
    else:
        check(False, "", "/etc/console-install-ports.json was not created "
                        "(NIC-SPEC 5.4)")

    if os.path.isfile(mi_path):
        try:
            mi = json.load(open(mi_path, encoding="utf-8", errors="replace"))
            got = mi.get("bind-address")
            want_ip = addr.split("/")[0]
            check(got == want_ip, "mihomo bind-address == %s" % want_ip,
                  "mihomo bind-address is %r, expected %r" % (got, want_ip))
        except Exception as exc:
            print("  [warn] mihomo config is not valid JSON: %s" % exc)
    else:
        print("  [ok] Mihomo configuration absent (clean release defaults)")

    fails = [m for okk, m in results if not okk]
    return 0 if not fails else 7


def main():
    cmd = sys.argv[1]
    if cmd == "locate":
        return cmd_locate(sys.argv[2], sys.argv[3])
    if cmd == "compare":
        return cmd_compare(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                           int(sys.argv[5]), int(sys.argv[6]))
    if cmd == "assert":
        return cmd_assert(sys.argv[2], sys.argv[3])
    print("unknown subcommand %r" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
PYEOF
ok "装后检查器已生成"

# ------------------------------------------------------------------ 介质
USBR=$WORK/usb.img
if [ ! -f "$USBR" ]; then
    cp "$ISO" "$USBR"
    # 补齐到 6G：模拟真实 U 盘（镜像尾部之外还有空白），更接近实机
    truncate -s 6G "$USBR"
fi
ok "USB 介质 $USBR（$(stat -c %s "$USBR") 字节）"

# ------------------------------------------------------------------ 装后校验
# rootfs 分区由安装器有意改写（NIC-SPEC 4.6），所以：
#   · rootfs 分区以外的每个字节仍必须与载荷一致（原有回读能力的等价物）；
#   · rootfs 分区挂成只读，把配置文件拷出来做断言。
# 挂载在 shell 里做（losetup + mount），比在 Python 里调外部命令更好排查。
verify_installed() {
    local name=$1 d=$2 fw=$3
    local img=$d/target.img
    local payload=$BODY/$fw.img.gz
    local nbytes
    nbytes=$(cat "$BODY/$fw.img.bytes")

    # --- 定位 rootfs 分区
    local loc
    if ! loc=$(python3 "$WORK/checkimg.py" locate "$img" "$fw" 2>&1); then
        printf '%s\n' "$loc" | sed 's/^/    /'
        bad "$name 磁盘结构不对（分区表/rootfs 定位失败）"
        return 6
    fi
    printf '%s\n' "$loc" | sed 's/^/    /'
    local rl
    rl=$(printf '%s\n' "$loc" | sed -n 's/^ROOTFS start_lba=\([0-9]*\) .*/\1/p' | tail -1)
    local rs
    rs=$(printf '%s\n' "$loc" | sed -n 's/^ROOTFS start_lba=[0-9]* sectors=\([0-9]*\).*/\1/p' | tail -1)
    [ -n "$rl" ] && [ -n "$rs" ] || { bad "$name 没解析出 rootfs 分区"; return 7; }
    ok "$name rootfs 分区 start_lba=$rl sectors=$rs ($((rs * 512 / 1048576)) MiB)"

    # --- 逐字节回读（rootfs 区间除外）
    if python3 "$WORK/checkimg.py" compare "$img" "$payload" "$nbytes" "$rl" "$rs"; then
        ok "$name 载荷回读一致（rootfs 分区以外逐字节相同）"
    else
        bad "$name 回读校验失败（写入数据与载荷不一致）"
        return 6
    fi

    # --- 挂载 rootfs 读配置
    local off siz loop mnt
    off=$((rl * 512)); siz=$((rs * 512))
    mnt=$d/rootfs_mnt
    rm -rf "$mnt"; mkdir -p "$mnt"
    loop=$(losetup -f --show -o "$off" --sizelimit "$siz" "$img" 2>"$d/losetup.err") || {
        bad "$name losetup 失败: $(cat "$d/losetup.err")"
        return 7
    }
    local mounted=0
    if mount -t ext4 -o ro "$loop" "$mnt" 2>"$d/mount.err"; then
        mounted=1
    elif mount -t ext4 -o ro,noload "$loop" "$mnt" 2>>"$d/mount.err"; then
        mounted=1
        warn "$name rootfs 需要 noload 才能只读挂载"
    fi
    if [ "$mounted" != 1 ]; then
        bad "$name 挂载 rootfs 失败: $(tr '\n' ' ' < "$d/mount.err")"
        losetup -d "$loop" 2>/dev/null
        return 7
    fi

    # Verify the actual installed program files and release marker, not just the
    # installer prompts. Metadata/config changes made by the installer are excluded.
    if [ -n "$RELEASE_VERSION" ] || [ -n "$EXPECTED_CODE_MANIFEST" ]; then
        if ! python3 - "$mnt" "$RELEASE_VERSION" "$EXPECTED_CODE_MANIFEST" > "$d/installed-code.json" <<'CHECK_CODE'
import hashlib,json,sys
from pathlib import Path
root,version,manifest=Path(sys.argv[1]),sys.argv[2],sys.argv[3]
fail=[];checked=0
if version and (root/'etc/console-version').read_text().strip()!=version:fail.append('release version')
if manifest:
    for item in json.loads(Path(manifest).read_text()):
        if not item.get('deploy'):continue
        checked+=1;p=root/item['deploy'].lstrip('/')
        if not p.is_file():fail.append(item['deploy']);continue
        with p.open('rb') as f:actual=hashlib.file_digest(f,'sha256').hexdigest()
        if actual!=item['sha256']:fail.append(item['deploy'])
print(json.dumps({'version':version,'checked_files':checked,'differences':fail}))
sys.exit(1 if fail else 0)
CHECK_CODE
        then
            cat "$d/installed-code.json"
            umount "$mnt" 2>/dev/null || true
            losetup -d "$loop" 2>/dev/null || true
            bad "$name 安装后的版本或程序代码与开发快照不一致"
            return 7
        fi
        ok "$name 已安装版本与开发代码一致：$(cat "$d/installed-code.json")"
    fi

    # 系统名落地校验：装好之后系统自报的版本、以及磁盘上的引导菜单条目名。
    # 这两处必须同名 —— 一处来自 rootfs（brand-rootfs.py 写入），
    # 一处来自载荷的 p1 分区 grub.cfg。两者由不同脚本生成，最容易各自为政。
    if [ -n "$OS_NAME" ]; then
        if ! python3 "$(dirname "$0")/brand-rootfs.py" "$mnt" --name "$OS_NAME" --check \
                > "$d/installed-name.json" 2>&1; then
            cat "$d/installed-name.json"
            umount "$mnt" 2>/dev/null || true
            losetup -d "$loop" 2>/dev/null || true
            bad "$name 装后系统内部版本标识不是 $OS_NAME"
            return 7
        fi
        ok "$name 装后系统内部版本标识：$OS_NAME"
    fi

    if ! python3 "$(dirname "$0")/sanitize-rootfs.py" "$mnt" --check > "$d/installed-policy.json"; then
        cat "$d/installed-policy.json"
        umount "$mnt" 2>/dev/null || true
        losetup -d "$loop" 2>/dev/null || true
        bad "$name 安装盘残留 OpenVPN/Mihomo/DDNS 配置或自动启动项"
        return 7
    fi
    ok "$name 安装盘内个人服务配置已清除，OpenVPN/Mihomo 默认关闭"

    # 只拷配置相关的小文件，然后马上卸载：挂载窗口越短越不容易受干扰
    local f
    for f in etc/config/network etc/config/firewall etc/board.json \
             etc/console-install-ports.json etc/console-mihomo/config.json \
             etc/console-mihomo/lan-devices.json \
             etc/console-backup/network.last-good etc/fwx; do
        if [ -f "$mnt/$f" ]; then
            mkdir -p "$d/rootfs/$(dirname "$f")"
            cp -a "$mnt/$f" "$d/rootfs/$f" 2>/dev/null || true
        fi
    done
    sync
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    losetup -d "$loop" 2>/dev/null || true
    ok "$name 已从装好的 rootfs 拷出配置"

    # 把关键文件打到日志里，失败时不用再重跑一遍才知道内容
    if [ -f "$d/rootfs/etc/config/network" ]; then
        printf '    --- /etc/config/network (installed) ---\n' >> "$d/console.log"
        sed 's/^/    /' "$d/rootfs/etc/config/network" >> "$d/console.log"
    fi

    # --- 断言
    if [ ! -f "$d/expect.json" ]; then
        bad "$name 缺 expect.json（驱动脚本没跑完？）"
        return 7
    fi
    log "场景 $name 装后网络配置断言"
    if python3 "$WORK/checkimg.py" assert "$d/rootfs" "$d/expect.json"; then
        ok "$name 装后网络配置符合所选 LAN/WAN 与地址"
        return 0
    fi
    bad "$name 装后网络配置校验失败"
    return 7
}

# ------------------------------------------------------------------ 单场景
run_scene() {
    local name=$1 fw=$2 kind=$3 media=$4
    log "场景 $name（fw=$fw boot=$kind）"
    local d=$WORK/$name
    rm -rf "$d"; mkdir -p "$d"
    truncate -s "${TARGET_MIB}M" "$d/target.img"

    # bootindex 只能挂在 -device 上。挂在 -drive 上会报
    # "Block format 'raw' does not support the option 'bootindex'"。
    # 用 if=none + 显式 -device 才能在 BIOS 下指定启动顺序，
    # 否则 SeaBIOS 会先试那块空的 IDE 目标盘并报 not a bootable disk。
    local qj=$d/qemu.txt
    : > "$qj"
    if [ "$fw" = uefi ]; then
        cp "$OVMF_DIR/OVMF_VARS_4M.fd" "$d/vars.fd"
        printf '%s\n' -machine q35 >> "$qj"
        printf '%s\n' -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_DIR/OVMF_CODE_4M.fd" >> "$qj"
        printf '%s\n' -drive "if=pflash,format=raw,unit=1,file=$d/vars.fd" >> "$qj"
        printf '%s\n' -device ich9-ahci,id=sata >> "$qj"
        if [ "$kind" = cdrom ]; then
            printf '%s\n' -drive "file=$media,format=raw,if=none,id=med0,media=cdrom" >> "$qj"
            printf '%s\n' -device ide-cd,drive=med0,bus=sata.1,bootindex=0 >> "$qj"
        else
            printf '%s\n' -device qemu-xhci,id=xhci >> "$qj"
            printf '%s\n' -drive "file=$media,format=raw,if=none,id=med0,media=disk" >> "$qj"
            printf '%s\n' -device usb-storage,drive=med0,bus=xhci.0,bootindex=0 >> "$qj"
        fi
        printf '%s\n' -drive "file=$d/target.img,format=raw,if=none,id=tgt0" >> "$qj"
        printf '%s\n' -device ide-hd,drive=tgt0,bus=sata.2,bootindex=1 >> "$qj"
    else
        printf '%s\n' -machine pc >> "$qj"
        if [ "$kind" = cdrom ]; then
            printf '%s\n' -drive "file=$media,format=raw,if=none,id=med0,media=cdrom" >> "$qj"
            printf '%s\n' -device ide-cd,drive=med0,bus=ide.1,bootindex=0 >> "$qj"
        else
            printf '%s\n' -device qemu-xhci,id=xhci >> "$qj"
            printf '%s\n' -drive "file=$media,format=raw,if=none,id=med0,media=disk" >> "$qj"
            printf '%s\n' -device usb-storage,drive=med0,bus=xhci.0,bootindex=0 >> "$qj"
        fi
        printf '%s\n' -drive "file=$d/target.img,format=raw,if=none,id=tgt0,media=disk" >> "$qj"
        printf '%s\n' -device ide-hd,drive=tgt0,bus=ide.0,bootindex=1 >> "$qj"
    fi

    # NIC-SPEC 7.1：每个场景挂 NIC_QEMU 块 e1000。
    #   · e1000 是 QEMU 里最稳的型号（igb/igc 在 guest 里偶发 probe 失败），
    #     而且 e1000.ko 一定在载荷 rootfs 的 modules.d/35-e1000 里、也就一定
    #     在网卡 bundle 里，不会因为筛选漏模块而看不见网口。
    #   · romfile= 关掉网卡的 PXE 选项 ROM：省掉 SeaBIOS 的 PXE 重试，
    #     也避免 "Booting from ROM..." 的输出干扰 console.log 的正则解析。
    #   · bootindex 已经在介质/目标盘上显式指定（0/1），网卡不设 bootindex，
    #     所以加网卡不会改变启动顺序。
    local i
    for ((i = 0; i < NIC_QEMU; i++)); do
        printf '%s\n' -netdev "user,id=n$i" >> "$qj"
        printf '%s\n' -device "e1000,netdev=n$i,romfile=" >> "$qj"
    done
    ok "$name QEMU 命令行：$(wc -l < "$qj") 个参数（含 $NIC_QEMU 块 e1000）"

    # 用显式参数把 BODY 传给 python。之前写成 heredoc 里引用 $BODY，
    # 但那个变量是传给 python 进程的环境变量、不是 shell 展开，
    # 结果 cfg.json 生成失败、后续 json.loads 拿到空串直接崩。
    python3 - "$qj" "$d" "$fw" "$TM" "$TARGET_MIB" "$BODY" \
            "$LAN_INDEX" "$LAN_ADDR" "$WAN_INDEX" "$NIC_QEMU" "$REQUIRE_NIC" \
            > "$d/cfg.json" <<'PY'
import json, sys
(qj, d, fw, tm, tmib, body,
 lan_index, lan_addr, wan_index, nic_count, require_nic) = sys.argv[1:12]
q = [l.rstrip("\n") for l in open(qj) if l.strip()]
cfg = {
    "dir": d, "fw": fw, "timeout": tm, "target": d + "/target.img",
    "target_mib": str(tmib),
    "exp_raw_sha": open("%s/%s.img.raw-sha256" % (body, fw)).read().strip(),
    "exp_bytes": open("%s/%s.img.bytes" % (body, fw)).read().strip(),
    "lan_index": lan_index, "lan_addr": lan_addr, "wan_index": wan_index,
    "nic_count": nic_count, "require_nic": require_nic,
    "qemu": q,
}
print(json.dumps(cfg))
PY
    [ -s "$d/cfg.json" ] || { bad "$name cfg.json 生成失败"; printf '%s 1\n' "$name" >> "$WORK/summary.txt"; return 1; }

    python3 "$WORK/drive.py" "$name" "$(cat "$d/cfg.json")"
    local rc=$?
    local stage=""
    case $rc in
        0) ;;
        3) bad "$name 引导失败（安装器没出现）" ;;
        4) bad "$name 磁盘枚举失败（没列出盘 / 没找到目标盘）" ;;
        5) bad "$name 安装失败（未到达完成校验）" ;;
        6) bad "$name 回读校验失败（写入数据与载荷不一致）" ;;
        7) bad "$name 装后网络配置校验失败" ;;
        8) bad "$name 网口阶段失败（没列出网口 / 没有选择提示）" ;;
        *) bad "$name 异常退出 rc=$rc" ;;
    esac

    # 装完了才做装后校验；C 段失败就没有可信的磁盘可查
    if [ "$rc" = 0 ]; then
        verify_installed "$name" "$d" "$fw"
        rc=$?
        case $rc in
            0) ok "$name PASS" ;;
            6) bad "$name 回读校验失败（rootfs 以外与载荷不一致）" ;;
            7) bad "$name 装后网络配置校验失败" ;;
            *) bad "$name 装后校验异常 rc=$rc" ;;
        esac
    fi

    printf '%s %s\n' "$name" "$rc" >> "$WORK/summary.txt"
    return $rc
}

# ------------------------------------------------------------------ 执行
for sc in $SCENES; do
    case $sc in
        cdrom-bios) run_scene cdrom-bios bios cdrom "$ISO"  ;;
        cdrom-uefi) run_scene cdrom-uefi uefi cdrom "$ISO"  ;;
        usb-bios)   run_scene usb-bios   bios usb   "$USBR" ;;
        usb-uefi)   run_scene usb-uefi   uefi usb   "$USBR" ;;
        *) bad "未知场景 $sc" ;;
    esac
done

# ------------------------------------------------------------------ 汇总
log "汇总"
printf '\n%-14s %s\n' SCENE RESULT
printf '%-14s %s\n' ------------- ------
pass=0; total=0
while read -r n r; do
    [ -n "${n:-}" ] || continue
    total=$((total + 1))
    case "${r:-1}" in
        0)  printf '%-14s PASS\n' "$n"; pass=$((pass + 1)) ;;
        3)  printf '%-14s FAIL (rc=3 引导失败)\n' "$n" ;;
        4)  printf '%-14s FAIL (rc=4 磁盘枚举失败)\n' "$n" ;;
        5)  printf '%-14s FAIL (rc=5 安装失败)\n' "$n" ;;
        6)  printf '%-14s FAIL (rc=6 回读校验失败)\n' "$n" ;;
        7)  printf '%-14s FAIL (rc=7 装后网络配置校验失败)\n' "$n" ;;
        8)  printf '%-14s FAIL (rc=8 网口阶段失败)\n' "$n" ;;
        *)  printf '%-14s FAIL (rc=%s)\n' "$n" "$r" ;;
    esac
done < "$WORK/summary.txt"

echo
if [ "$pass" = "$total" ] && [ "$total" -ge 1 ]; then
    printf 'RESULT: PASS —— %d/%d 场景端到端通过（含网口选择与装后配置校验）\n' "$pass" "$total"
    exit 0
else
    printf 'RESULT: FAIL —— %d/%d 通过\n' "$pass" "$total"
    printf '\n排障线索（各场景 console.log 里的关键行）：\n'
    for sc in $SCENES; do
        f=$WORK/$sc/console.log
        [ -f "$f" ] || continue
        printf '  %s:\n' "$sc"
        tr -d '\r' < "$f" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | sed 's/\x1b\[[0-9;]*H//g' \
            | grep -aE 'error:|Boot failed|Waiting for root|not a bootable|ERROR:|### STAGE|FAIL\]' \
            | head -12 | sed 's/^/    /'
    done
    exit 1
fi
