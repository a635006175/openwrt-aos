#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check-iso.py —— OpenWrt 安装器 ISO 静态体检（纯标准库，跨平台，无需 QEMU）

用途
    在真正写盘 / 上机之前，几秒钟内判断一个安装器 ISO 是否「结构上能启动」。
    本工具编码了实际踩过的全部启动级故障，每条都能独立定位到具体原因。

为什么需要它
    v5 版镜像有两个致命问题，只有插到真机上才会暴露：
      · MBR 全零 —— dd 到 U 盘后 BIOS 报 "not a bootable disk"
      · grub 用 root=/dev/sr0 —— Ventoy 文件拷贝模式下内核看不到 sr0，
        永久卡在 "Waiting for root device"
    这两个问题用 QEMU 测都未必能发现（QEMU 光驱会正常提供 sr0）。
    静态检查能直接抓住。

退出码
    0  全部通过
    1  存在 FAIL（必然启动不了）
    2  无法读取 ISO
    仅 WARN 时为 0，但会在汇总里标出。

用法
    python3 check-iso.py <image.iso> [--expect-kernel-sha <sha256>] [--json]
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import struct
import sys

SECTOR = 2048

# Windows 控制台默认 GBK，中文输出会乱码。这里显式切到 UTF-8，
# 并用 errors='replace' 兜底，保证任何终端下都不会因编码抛异常。
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ----------------------------------------------------------------- 结果收集
class Report:
    def __init__(self):
        self.items = []           # (level, code, message)
        self.fails = 0
        self.warns = 0

    def ok(self, code, msg):
        self.items.append(("OK", code, msg))

    def warn(self, code, msg):
        self.items.append(("WARN", code, msg))
        self.warns += 1

    def fail(self, code, msg):
        self.items.append(("FAIL", code, msg))
        self.fails += 1

    def info(self, code, msg):
        self.items.append(("INFO", code, msg))


R = Report()


def fail(code, msg):
    R.fail(code, msg)


def ok(code, msg):
    R.ok(code, msg)


def warn(code, msg):
    R.warn(code, msg)


# ----------------------------------------------------------------- ISO9660
def _iso_dir_records(buf, lba, size, rb):
    """遍历一个目录的 extent，产出 (name, is_dir, extent_lba, data_len)。"""
    out = []
    pos = 0
    while pos + 34 <= size:
        rb.seek(lba * SECTOR + pos)
        hdr = rb.read(34)
        if len(hdr) < 34:
            break
        rec_len = hdr[0]
        if rec_len == 0:
            # 记录以扇区为边界，跳到下一个扇区起点
            nxt = ((lba * SECTOR + pos) // SECTOR + 1) * SECTOR
            pos = nxt - lba * SECTOR
            if pos >= size:
                break
            continue
        extent = struct.unpack_from("<I", hdr, 2)[0]
        dlen = struct.unpack_from("<I", hdr, 10)[0]
        flags = hdr[25]
        nlen = hdr[32]
        rb.seek(lba * SECTOR + pos + 33)
        name_raw = rb.read(nlen)
        name = name_raw.decode("latin-1", "replace")
        # 去掉 ISO9660 的版本后缀 ";1"
        if ";" in name:
            name = name.split(";", 1)[0]
        name = name.rstrip(".")
        out.append((name, bool(flags & 0x02), extent, dlen))
        pos += rec_len
    return out


def iso_lookup(rb, path):
    """在 ISO9660 主卷描述符里按路径找条目，返回 (extent, size, is_dir)。"""
    rb.seek(16 * SECTOR)
    pvd = rb.read(SECTOR)
    if len(pvd) < 156 or pvd[1:6] != b"CD001":
        return None
    root = pvd[156:156 + 34]
    extent = struct.unpack_from("<I", root, 2)[0]
    size = struct.unpack_from("<I", root, 10)[0]

    parts = [p for p in path.strip("/").split("/") if p]
    cur_extent, cur_size = extent, size
    for i, want in enumerate(parts):
        found = None
        for name, is_dir, ex, dl in _iso_dir_records(b"", cur_extent, cur_size, rb):
            if name.upper() == want.upper():
                found = (ex, dl, is_dir)
                break
        if not found:
            return None
        cur_extent, cur_size, is_dir = found
        if i == len(parts) - 1:
            return (cur_extent, cur_size, is_dir)
    return (cur_extent, cur_size, True)


def iso_read(rb, path):
    ent = iso_lookup(rb, path)
    if not ent or ent[2]:
        return None
    rb.seek(ent[0] * SECTOR)
    return rb.read(ent[1])


def iso_volid(rb):
    rb.seek(16 * SECTOR)
    pvd = rb.read(SECTOR)
    if len(pvd) < 88 or pvd[1:6] != b"CD001":
        return None
    return pvd[40:72].decode("latin-1", "replace").rstrip(" \x00")


# ----------------------------------------------------------------- MBR / GPT
def check_boot_area(rb, total_size):
    rb.seek(0)
    mbr = rb.read(512)
    if len(mbr) < 512:
        fail("MBR/SHORT", "读不到前 512 字节")
        return

    sig = struct.unpack_from("<H", mbr, 510)[0]
    if sig != 0xAA55:
        fail("MBR/SIG",
             "前 512 字节结尾不是 55AA —— 这张盘不可能被 BIOS 引导。"
             "这正是 v5 的缺陷：dd 到 U 盘后 SeaBIOS 报 'not a bootable disk'。")
    else:
        ok("MBR/SIG", "55AA 引导签名存在")

    # 引导代码不能全零，否则 BIOS 跳进空白
    code = mbr[:440]
    if sum(code) == 0:
        fail("MBR/CODE",
             "MBR 引导代码 440 字节全为零 —— 有 55AA 签名但没有可执行代码，"
             "BIOS 会直接失败。dd 到 U 盘不可引导。")
    else:
        ok("MBR/CODE", "MBR 引导代码非空（字节和 %d）" % sum(code))

    parts = []
    for i in range(4):
        e = mbr[446 + 16 * i: 446 + 16 * (i + 1)]
        boot, ptype = e[0], e[4]
        lba, cnt = struct.unpack_from("<I", e, 8)[0], struct.unpack_from("<I", e, 12)[0]
        if ptype != 0 or cnt != 0:
            parts.append(dict(idx=i + 1, boot=boot, type=ptype, lba=lba, cnt=cnt))

    if not parts:
        fail("MBR/PT",
             "MBR 分区表 4 个条目全为空 —— 这是纯 ISO 镜像，"
             "只能从光驱/虚拟光驱启动，dd 到 U 盘不可引导。")
    else:
        desc = ", ".join("p%d type=0x%02x lba=%d cnt=%d" % (p["idx"], p["type"], p["lba"], p["cnt"])
                         for p in parts)
        ok("MBR/PT", "分区表非空：%s" % desc)

        # 若第一项是 GPT 保护表，说明用了 isohybrid 的 GPT 布局
        if parts[0]["type"] == 0xEE:
            rb.seek(512)
            gpt = rb.read(8)
            if gpt == b"EFI PART":
                ok("GPT/HDR", "GPT 保护表 + 头部签名有效（grub-mkrescue 标准布局）")
            else:
                warn("GPT/HDR",
                     "分区类型是 0xEE，但 512 偏移处不是 'EFI PART'（实际 %r）。"
                     "这属于『有保护表却没有 GPT 头』的半成品布局。"
                     "对 isohybrid 引导通常无害（启动走的是 MBR 代码 + El Torito），"
                     "但如果某些固件优先按 GPT 解析，可能找不到启动项。" % gpt)

    # 启动记录：El Torito
    rb.seek(17 * SECTOR)
    brvd = rb.read(SECTOR)
    if not brvd or brvd[1:6] != b"CD001" or brvd[0] != 0:
        fail("ELTORITO/BRVD",
             "第 17 扇区没有 Boot Record Volume Descriptor —— 没有 El Torito，"
             "光驱/UEFI 都无法从这个 ISO 启动。")
        return

    cat_lba = struct.unpack_from("<I", brvd, 0x47)[0]
    rb.seek(cat_lba * SECTOR)
    cat = rb.read(SECTOR)
    if len(cat) < 64 or cat[0] != 0x01:
        fail("ELTORITO/VALID", "El Torito 校验条目无效")
        return
    if struct.unpack_from("<H", cat, 30)[0] != 0xAA55:
        fail("ELTORITO/VALID", "El Torito 校验条目缺少 55AA")
    else:
        ok("ELTORITO/VALID", "El Torito 校验条目有效")

    entries = []
    i = 0
    while True:
        e = cat[32 + 32 * i: 32 + 32 * (i + 1)]
        if len(e) < 32 or e[0] == 0:
            break
        entries.append(dict(boot=e[0], media=e[1],
                            load_seg=struct.unpack_from("<H", e, 2)[0],
                            sectors=struct.unpack_from("<I", e, 8)[0] or
                                    struct.unpack_from("<H", e, 6)[0]))
        i += 1
        if i > 64:
            break

    if not entries:
        fail("ELTORITO/ENTRY", "El Torito 里没有任何启动条目")
        return

    bios = [e for e in entries if e["media"] != 0xEF]
    uefi = [e for e in entries if e["media"] == 0xEF]
    if bios:
        ok("ELTORITO/BIOS", "含 BIOS(no-emulation) 启动条目 %d 个" % len(bios))
    else:
        fail("ELTORITO/BIOS", "缺少 BIOS 启动条目 —— BIOS/CSM 模式下无法从光驱启动")
    if uefi:
        ok("ELTORITO/UEFI", "含 UEFI 启动条目（media=0xEF）")
    else:
        warn("ELTORITO/UEFI", "缺少 UEFI(0xEF) 启动条目 —— UEFI 光驱启动可能失败；"
                              "若只做 dd/U 盘引导可忽略，但双引导镜像应当具备")


# ----------------------------------------------------------------- grub.cfg
FOR_DEVICE_LIST = re.compile(r"^\s*for\s+\w+\s+in\s+.*\((?:cd|hd)[0-9]", re.M)

FORDEV_INVALID = (
    "grub.cfg 里出现 `for x in (cd0) (hd0) ...; do` 这种写法。"
    "GRUB 的脚本解析器不接受带括号的设备列表作为 for 的迭代项，会报 "
    "'syntax error' / 'not in function body'，"
    "导致整个 menuentry 被丢弃，最后表现为菜单能显示但一引导就 "
    "'you need to load the kernel first'。"
    "—— 改用 search --no-floppy --file --set=root /boot/initrd.gz 定位介质。"
)


def strip_comments(text, marker="#"):
    """去掉行注释，只留可执行内容。

    这一步是必须的：本项目的脚本会在注释里写明「不要再用 root=/dev/sr0」
    以及「不要写 for x in (cd0) (hd0)」这类反例说明。如果直接对全文做正则，
    这些反例注释本身就会被误判成缺陷（实测确实会误报 3 项）。

    不能简单地对每个 `#` 做 find 截断：shell 里 `$#`、`${#var}` 都含 #，
    那会把整行后半截代码也切掉，导致真实实现被漏判成缺失。
    这里只在「行首或空白之后、且 # 前面不是 $ / { 」时才认定为注释起点。
    """
    import re as _re
    pat = _re.compile(r"(?:^|\s)" + _re.escape(marker) + r".*$")
    out = []
    for ln in text.splitlines():
        # 跳过 $# 和 ${#x} 这类非注释用法
        m = None
        for mm in _re.finditer(_re.escape(marker), ln):
            i = mm.start()
            if i > 0 and ln[i - 1] in "$\\":
                continue
            if i > 1 and ln[i - 1] == "{" and ln[i - 2] == "$":
                continue
            m = mm
            break
        out.append(ln[:m.start()] if m else ln)
    return "\n".join(out)


def check_grub(rb):
    raw = iso_read(rb, "/boot/grub/grub.cfg")
    if raw is None:
        fail("GRUB/MISSING", "ISO 内找不到 /boot/grub/grub.cfg")
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        fail("GRUB/UTF8", "grub.cfg 不是合法 UTF-8")
        return None

    # 1) ASCII remains valid; UTF-8 menus additionally require a real CJK font
    # and gfxterm. Invalid UTF-8 was rejected above, before parsing any menu.
    bad = [(i + 1, ln) for i, ln in enumerate(text.splitlines())
           if any(ord(c) > 127 for c in ln)]
    if bad:
        detail = "; ".join("第 %d 行: %s" % (n, s.strip()[:40]) for n, s in bad[:3])
        font = iso_read(rb, '/boot/grub/fonts/cjk.pf2')
        if font and font[:4] == b'FILE' and font[8:12] == b'PFF2' and 'loadfont /boot/grub/fonts/cjk.pf2' in text and 'gfxterm' in text and not text.startswith(chr(0xfeff)) and chr(0xfffd) not in text:
            ok('GRUB/UTF8FONT', '双语菜单采用有效 UTF-8，包含 PF2 字库和图形终端')
        else:
            fail('GRUB/UTF8FONT', '非 ASCII 菜单缺少有效字库/图形终端或编码损坏（%s）' % detail)
    else:
        ok("GRUB/ASCII", "grub.cfg 纯 ASCII")

    code = strip_comments(text)

    # 2) 非法 for 语法（只在代码里找，注释里的反例不算）
    if FOR_DEVICE_LIST.search(code):
        fail("GRUB/FOR", FORDEV_INVALID)
    else:
        ok("GRUB/FOR", "没有非法的 for 设备列表语法")

    # 3) 必须有 linux + initrd
    has_linux = re.search(r"^\s*linux(?:efi|16)?\s+\S+", code, re.M)
    has_initrd = re.search(r"^\s*initrd(?:efi|16)?\s+\S+", code, re.M)
    if has_linux:
        ok("GRUB/LINUX", "含 linux 加载行")
    else:
        fail("GRUB/LINUX", "grub.cfg 没有任何 linux 行 —— 不会加载内核")
    if has_initrd:
        ok("GRUB/INITRD", "含 initrd 加载行")
    else:
        warn("GRUB/INITRD", "grub.cfg 没有 initrd 行 —— 若内核依赖外部根设备，"
                            "需要确保 root= 指向的设备在目标环境下真实存在")

    # 4) root=/dev/sr0 只能在内核确实能拿到 sr0 的情况下用
    m = re.search(r"root=(/dev/sr[0-9]\d*)", code)
    if m:
        fail("GRUB/SR0",
             "grub.cfg 用 root=%s 把光盘当根文件系统。"
             "Ventoy「文件拷贝」模式、以及 dd 到 U 盘的情况下，内核看不到 %s，"
             "会永久停在 'Waiting for root device %s...'，不报错也不超时。"
             "—— 正确做法是把载荷放进 initramfs，内核不需要任何外部根设备。"
             % (m.group(1), m.group(1), m.group(1)))
    else:
        ok("GRUB/NOSR0", "没有把 /dev/sr* 当根设备")

    # 5) 记录定位方式
    if re.search(r"search\b[^\n]*--file", code):
        ok("GRUB/SEARCH", "用 search --file 定位介质（不写死 cd0/hd0，最稳）")
    elif re.search(r"search\b[^\n]*--label", code):
        ok("GRUB/SEARCH", "用卷标定位介质")
    elif re.search(r"set\s+root=\((?:cd|hd)[0-9]", code):
        warn("GRUB/SEARCH", "写死了 set root=(cdX)/(hdX)。UEFI 下光驱常被枚举成 (hd2)，"
                            "dd 到 U 盘后是 (hd1)/(hd2)，内置 eMMC 可能是 (hd0)，"
                            "编号会漂移，建议改用 search --file")

    # 6) 引用的文件必须在 ISO 里真实存在（去重，两个 menuentry 会各引一次）
    seen = set()
    for m in re.finditer(r"^\s*(?:linux|initrd)(?:efi|16)?\s+(/\S+)", code, re.M):
        p = m.group(1)
        if p in seen:
            continue
        seen.add(p)
        ent = iso_lookup(rb, p)
        if ent is None:
            fail("GRUB/REF", "grub.cfg 引用了 ISO 内不存在的路径：%s" % p)
        else:
            ok("GRUB/REF", "引用路径存在：%s（%d 字节）" % (p, ent[1]))

    # The default installer must work on PVE's VGA console without a UART.
    # Serial-only checks used to miss the fatal ttyS0 stdin/EOF path entirely.
    menus = re.findall(r'^\s*menuentry\s+([^\n]+)\{\s*\n(.*?)^\}', code, re.M | re.S)
    default_match = re.search(r'^\s*set\s+default=["\']?(\d+)', code, re.M)
    default_index = int(default_match.group(1)) if default_match else 0
    def consoles(body):
        line = re.search(r'^\s*linux(?:efi|16)?\s+([^\n]+)', body, re.M)
        return re.findall(r'\bconsole=([^\s,]+)', line.group(1)) if line else []
    selected = consoles(menus[default_index][1]) if default_index < len(menus) else []
    if selected and selected[-1] in ('tty0', 'tty1'):
        ok('GRUB/LOCALCONSOLE', '默认入口使用本地显示/键盘，适配没有串口的 PVE 虚拟机')
    else:
        fail('GRUB/LOCALCONSOLE', '默认入口未将 tty0/tty1 放在最后；无串口时安装器会失去交互控制台，可能退出并重启')
    serial = [consoles(body) for title, body in menus if '(serial console)' in title]
    if any(items and items[-1].startswith('ttyS') for items in serial):
        ok('GRUB/SERIALCONSOLE', '提供独立串口启动入口')
    else:
        fail('GRUB/SERIALCONSOLE', '缺少独立的串口启动入口')

    # 7) 系统名称：菜单内部一致性（与载荷的比对在 main 里做，需要 initramfs 表）
    check_os_name(text, menus)
    return text


def check_os_name(grub_text, menus):
    """核对引导菜单内部的系统名一致。

    名字本身会随版本变化，所以这里只断言「所有安装入口用同一个名字」。
    与载荷/系统内部版本的交叉核对在 check_os_name_vs_payload() 里做。
    """
    got = []
    for title, _ in menus:
        m = re.search(r'/ *Install\s+([A-Za-z0-9._-]+)', title)
        if m:
            got.append(m.group(1))
    if not got:
        fail('GRUB/OSNAME',
             '引导菜单里没有形如 "安装系统 / Install <系统名>" 的条目 —— '
             '用户无法从菜单辨认要装的是哪个系统。')
        return None
    uniq = set(got)
    if len(uniq) > 1:
        fail('GRUB/OSNAME', '多个安装入口的系统名不一致：%s' % ', '.join(sorted(uniq)))
        return None
    return got[0]


def menu_os_name(grub_text):
    """从 grub.cfg 文本里取出安装入口的系统名（用于与载荷交叉核对）。"""
    menu_name = None
    for title in re.findall(r'^\s*menuentry\s+([^\n]+)\{', grub_text, re.M):
        m = re.search(r'/ *Install\s+([A-Za-z0-9._-]+)', title)
        if m:
            menu_name = m.group(1)
            break
    return menu_name


def check_os_name_vs_payload(menu_name, names):
    """核对「ISO 菜单名」与「载荷记录的系统名」一致。

    build-payload.sh --os-name 会把同一个名字同时写进：
      · 载荷里磁盘 grub.cfg 的 menuentry（$BODY/os-name.txt 记录）
      · rootfs 的 etc/console-version / os-release / openwrt_release / banner
    build-iso.sh 再把那个名字放进 initramfs 的 installer/os-name.txt，
    所以只凭 ISO 就能验「菜单名 == 装好后系统自报版本」。
    """
    if not menu_name:
        return
    rec = None
    for cand in ('installer/os-name.txt', './installer/os-name.txt'):
        if cand in names and names[cand][2]:
            rec = names[cand][2].decode('utf-8', 'replace')
            break
    if rec is None:
        warn('GRUB/OSNAME',
             '引导菜单名 %r，但 initramfs 里没有 installer/os-name.txt，'
             '无法核对「菜单名 == 装好后系统自报版本」。' % menu_name)
        return
    lines = [l.strip() for l in rec.splitlines() if l.strip()]
    payload_name = lines[0] if lines else ''
    branded = any(l == 'branded=1' for l in lines[1:])
    if payload_name != menu_name:
        fail('GRUB/OSNAME',
             '菜单名 %r 与载荷记录的系统名 %r 不一致 —— 装完后重启会看到另一个名字。'
             % (menu_name, payload_name))
    elif branded:
        ok('GRUB/OSNAME',
           '系统名 %s：引导菜单、磁盘菜单、系统内部版本三处同名' % menu_name)
    else:
        # 诚实报告：菜单改了名，但 rootfs 的 os-release/console-version 没动。
        # 这是 build-payload.sh 不带 --os-name 时的预期行为，不是缺陷，
        # 但必须显式说出来，否则「一致」二字会掩盖「内部还是 OpenWrt」。
        warn('GRUB/OSNAME',
             '引导菜单名 %s，但系统内部版本标识未改（rootfs 的 '
             'os-release/console-version 仍是原值）。装好后系统自报的版本与菜单名不同。'
             % menu_name)


# ----------------------------------------------------------------- initramfs
CPIO_NEWC = b"070701"
CPIO_CRC = b"070702"


def cpio_iter(gz_bytes):
    """流式遍历 newc/crc cpio，产出 (name, mode, filesize, data_or_None)。"""
    data = gzip.decompress(gz_bytes)
    mv = memoryview(data)
    pos = 0
    n = len(data)
    while pos + 110 <= n:
        magic = data[pos:pos + 6]
        if magic not in (CPIO_NEWC, CPIO_CRC):
            break
        hdr = data[pos + 6:pos + 110]
        try:
            fields = [int(hdr[i * 8:(i + 1) * 8], 16) for i in range(13)]
        except ValueError:
            break
        mode = fields[1]
        filesize = fields[6]
        namesize = fields[11]
        name_start = pos + 110
        name = data[name_start:name_start + namesize - 1].decode("utf-8", "replace")
        after_name = name_start + namesize
        pad1 = (-after_name) % 4
        data_start = after_name + pad1
        if name == "TRAILER!!!":
            break
        # 大文件不读内容，只要能拿到大小
        payload = data[data_start:data_start + filesize] if filesize <= 4 * 1024 * 1024 else None
        yield name, mode, filesize, payload
        after_data = data_start + filesize
        pos = after_data + ((-after_data) % 4)


def check_initramfs(rb):
    raw = iso_read(rb, "/boot/initrd.gz")
    if raw is None:
        warn("INITRD/MISSING", "ISO 内没有 /boot/initrd.gz")
        return {}
    ok("INITRD/PRESENT", "initrd.gz 存在（%d 字节）" % len(raw))
    try:
        entries = list(cpio_iter(raw))
    except Exception as e:
        fail("INITRD/DECOMPRESS", "initrd.gz 解压或解析失败：%s" % e)
        return {}
    if not entries:
        fail("INITRD/EMPTY", "initrd 里没有任何 cpio 条目")
        return {}

    names = {}
    for name, mode, size, payload in entries:
        names[name] = (mode, size, payload)
    ok("INITRD/ENTRIES", "initrd 含 %d 个条目" % len(entries))

    # /init 必须存在且可执行
    init_key = None
    for cand in ("init", "./init"):
        if cand in names:
            init_key = cand
            break
    if init_key is None:
        fail("INITRD/INIT", "initrd 根目录没有 /init —— 内核解压后无法启动第一个进程")
        init_text = None
    else:
        mode, size, payload = names[init_key]
        if not (mode & 0o111):
            fail("INITRD/INIT", "/init 没有可执行位（mode=%o）" % mode)
        else:
            ok("INITRD/INIT", "/init 存在且可执行（%d 字节）" % size)
        init_text = payload.decode("utf-8", "replace") if payload else None

    # 安装器程序
    inst = None
    inst_text = None
    for cand in ("usr/sbin/openwrt-install", "./usr/sbin/openwrt-install"):
        if cand in names:
            inst = cand
            break
    if inst is None:
        fail("INITRD/INSTALLER",
             "initrd 里没有 /usr/sbin/openwrt-install —— 就算能起来也没有安装程序")
    else:
        mode, size, payload = names[inst]
        ok("INITRD/INSTALLER", "openwrt-install 存在（%d 字节）" % size)
        inst_text = payload.decode("utf-8", "replace") if payload else None

    # 载荷是否内置 —— 这是「不依赖 sr0」的根本保证
    payloads = [k for k in names
                if re.search(r"(^|/)installer/(bios|uefi)\.img\.gz$", k)]
    if payloads:
        tot = sum(names[k][1] for k in payloads)
        ok("INITRD/PAYLOAD",
           "安装载荷已内置于 initramfs（%s，合计 %.1f MiB）—— 内核不需要外部根设备"
           % (", ".join(sorted(os.path.basename(k) for k in payloads)),
              tot / 1048576.0))
    else:
        warn("INITRD/PAYLOAD",
             "initramfs 内没有发现 installer/*.img.gz。若安装器要在运行时从"
             "光驱/分区读取载荷，则必须保证 init 能定位到那个分区，"
             "Ventoy 文件拷贝模式和 exFAT 数据分区会失败。")

    shasums = [k for k in names if k.endswith("installer/SHA256SUMS")]
    if payloads and shasums:
        ok("INITRD/SHA", "含 installer/SHA256SUMS，可在写入前校验载荷")
    elif payloads:
        warn("INITRD/SHA", "有载荷但没有 SHA256SUMS")

    # init 里的块设备稳定等待 —— 防漏盘。同样只看代码，注释里的说明不算。
    init_code = strip_comments(init_text) if init_text else None
    if init_code:
        if re.search(r"stable", init_code, re.I):
            ok("INIT/STABLE",
               "init 含块设备集合稳定等待 —— 可避免 C3558 这类机器上 "
               "eMMC/USB 枚举先后不同导致磁盘列表漏盘")
        else:
            warn("INIT/STABLE",
                 "init 未发现『块设备集合稳定后再继续』的逻辑。"
                 "实机上 eMMC 约 3.8s、USB 约 4~5s 才枚举完，"
                 "安装器启动过快会漏掉目标盘。")
        if re.search(r"root=/dev/sr", init_code):
            fail("INIT/SR0", "init 里仍在用 /dev/sr* 作为数据来源")
        else:
            ok("INIT/NOSR0", "init 不依赖 /dev/sr*")

    # 安装器行为检查（同样剥离注释）
    inst_code = strip_comments(inst_text) if inst_text else None
    wanted = {c for c in (init_code or '') + (inst_code or '') if ord(c) > 127}
    if wanted:
        font_entry = names.get('etc/installer-console.psf') or names.get('./etc/installer-console.psf')
        font = font_entry[2] if font_entry else None
        try:
            magic, version, head, flags, count, size, height, width = struct.unpack('<8I', font[:32])
            assert magic == 0x864ab572 and flags & 1 and count <= 512
            mapping = font[head + count * size:]
            covered = set(''.join(part.decode('utf8') for part in mapping.split(b'\xff') if part))
            missing = wanted - covered
            assert not missing, 'missing glyphs: ' + ''.join(sorted(missing))
            assert 'bin/setfont' in names or './bin/setfont' in names
            assert 'setfont' in (init_code or '')
            ok('INITRD/CJKFONT', '双语安装提示所需 %d 个非 ASCII 字形均已包含，启动时加载字库' % len(wanted))
        except Exception as exc:
            fail('INITRD/CJKFONT', '中文控制台字库缺失或字符覆盖不完整: %s' % exc)
    if inst_code:
        if "Press Enter to erase" in inst_code:
            ok("INST/ENTER", "第二次确认是『按回车』（符合要求）")
        if re.search(r"must type|type the full|retype", inst_code, re.I):
            warn("INST/CONFIRM", "安装器可能仍要求第二次输入完整路径")
        if re.search(r"rpmb", inst_code) and re.search(r"boot0|boot\[0-9\]", inst_code):
            ok("INST/EMMC",
               "安装器已排除 mmcblk*boot0/boot1/rpmb —— 这三个是 eMMC 硬件保留区，"
               "误写会变砖")
        else:
            fail("INST/EMMC",
                 "安装器的整盘判定没有排除 mmcblk*boot0/boot1/rpmb。"
                 "它们也是『没有 partition 文件的块设备』，会被当成可安装目标，"
                 "一旦选中就变砖。")
        if re.search(r"logical_block_size", inst_code):
            ok("INST/4KN", "安装器检查 logical_block_size（拒绝 4Kn 盘）")
        else:
            warn("INST/4KN", "安装器未检查逻辑扇区大小，4Kn 盘会写入失败")
        if re.search(r"gzip\s+-dc", inst_code) and re.search(r"sha256", inst_code, re.I):
            ok("INST/VERIFY", "写入后回读并校验 sha256")
        if re.search(r"raw-sha256|raw_sha256", inst_code):
            pass
        else:
            warn("INST/VERIFY", "未见写入后校验安装器原始镜像 sha256 的逻辑")

    # 网卡驱动包与网口选择链路
    check_nic_bundle(names)
    check_nic_ui(init_code, inst_code)
    return names


# ----------------------------------------------------------------- 网卡驱动包
def check_nic_bundle(names):
    """initramfs 里必须带网卡驱动，否则安装环境根本看不到网口。

    安装器现在要在装系统时列网口、让用户手选 LAN/WAN。initramfs 是一个
    不含任何 .ko 的最小根，内核自带的只有 builtin 驱动；实机的千兆/万兆网卡
    （igb/igc/ixgbe/r8169/tg3...）几乎全是模块。所以驱动包必须打进 initramfs。
    """
    dep = None
    for k in names:
        m = re.search(r"(?:^|/)lib/modules/([^/]+)/modules\.dep$", k)
        if m and names[k][1] > 0:
            dep = (k, m.group(1))
            break
    if dep is None:
        fail("INITRD/NICBUNDLE",
             "initramfs 内没有 lib/modules/<ver>/modules.dep —— 网卡驱动包没打进去。"
             "安装环境里将看不到任何网口，LAN/WAN 选择功能等于没有。")
    else:
        ok("INITRD/NICBUNDLE",
           "initramfs 含网卡驱动依赖表 %s（%d 字节）"
           % (dep[0], names[dep[0]][1]))

    # 按真实开机顺序排好的加载清单：保证「安装器看到的 ethN」= 「装好后系统的 ethN」
    order = None
    for k in names:
        if re.fullmatch(r"(?:^|/)etc/nic-load\.order", k):
            order = k
            break
    if order is None:
        fail("INITRD/NICORDER",
             "initramfs 内没有 /etc/nic-load.order —— 无法按 rootfs 真实顺序加载网卡驱动，"
             "安装器里看到的 ethN 可能与装好后系统里的不一致，用户选错口就失联。")
    else:
        text = (names[order][2] or b"").decode("utf-8", "replace")
        mods = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
        if not mods:
            fail("INITRD/NICORDER", "/etc/nic-load.order 是空的，至少应列出 1 个模块")
        else:
            ok("INITRD/NICORDER",
               "/etc/nic-load.order 含 %d 个模块（%s%s）"
               % (len(mods), ", ".join(mods[:4]), " …" if len(mods) > 4 else ""))

    # 网卡固件：部分网卡（如 r8169/igb 的某些型号）没有 firmware 就 probe 失败
    fw = [k for k in names if re.match(r"(?:^|/)lib/firmware/", k)]
    if not fw:
        fail("INITRD/NICFW",
             "initramfs 内没有 /lib/firmware —— 需要固件的网卡会加载失败")
    else:
        ok("INITRD/NICFW", "initramfs 含网卡固件（%d 个文件）" % len(fw))

    # 网口清单本身：至少要有 e1000 / igb 这类常见驱动，否则大概率是筛错了
    kos = [k for k in names if k.endswith(".ko")]
    if kos:
        base = sorted({os.path.basename(k)[:-3] for k in kos})
        ok("INITRD/NICKO", "initramfs 含 %d 个内核模块（%s%s）"
           % (len(base), ", ".join(base[:6]), " …" if len(base) > 6 else ""))


# ----------------------------------------------------------------- 网口选择交互
def check_nic_ui(init_code, inst_code):
    """静态确认「选网口」这条新链路真的接上了，而不是只加了提示却没用。

    这一组检查每个都对应一个真实会踩的坑：
      · init 加载了驱动但安装器不列网口      -> 用户看不到可选口
      · 只有 LAN 选择没有地址输入            -> 装完还是旧网段
      · 选了网口但没写回 rootfs              -> 白选
      · 写回用了硬编码的 eth0                -> 选别的口无效
      · lan2 没删                            -> 双内网配置打在错误的物理口上
    """
    # ---- init 侧：必须真的去加载驱动
    if init_code:
        if re.search(r"nic-load\.order|nic_load\.order", init_code):
            ok("INIT/LOADNIC", "init 会读取 /etc/nic-load.order 加载网卡驱动")
        else:
            fail("INIT/LOADNIC",
                 "init 没有读取 /etc/nic-load.order —— 驱动包打进去了但没人加载，"
                 "安装环境里依然看不到网口")
        if re.search(r"modprobe|insmod", init_code):
            ok("INIT/MODPROBE", "init 用 modprobe/insmod 加载模块")
        else:
            fail("INIT/MODPROBE", "init 没有 modprobe/insmod —— 模块无法加载")

    if not inst_code:
        return

    # ---- 安装器侧：列表 + 选 LAN
    if re.search(r"Select the LAN port", inst_code):
        ok("INST/LANSELECT", "安装器会提示选择 LAN 口")
    else:
        fail("INST/LANSELECT",
             "安装器没有『选择 LAN 口』的提示 —— 网口选择功能没接上")

    if re.search(r"Network interfaces detected", inst_code):
        ok("INST/NICLIST", "安装器会先列出识别到的网口")
    else:
        fail("INST/NICLIST", "安装器没有打印网口列表，用户无从选择")

    # ---- 必须有「内置默认」这条显式路径
    if re.search(r"built-in default|builtin default", inst_code, re.I):
        ok("INST/DEFAULTKEY", "保留了『内置默认（eth0=LAN/eth1=WAN）』快速路径")
    else:
        warn("INST/DEFAULTKEY",
             "安装器没有『内置默认』选项。老机器/紧急情况下装机人员没有跳过选择的手段。")

    # ---- 地址输入
    if re.search(r"Enter the LAN address", inst_code):
        ok("INST/ADDR", "安装器会要求输入 LAN 地址")
    else:
        fail("INST/ADDR", "安装器没有要求输入 LAN 地址 —— 装完仍会是 192.168.1.1")
    # 地址校验：必须有人挡非法输入，否则写进去的是坏配置
    has_prefix = re.search(r"prefix|/24|str2pfx|netmask", inst_code, re.I)
    has_octet = re.search(r"octet|segment|\b255\b", inst_code)
    if has_prefix and has_octet:
        ok("INST/ADDRCHK", "安装器对地址做了格式/前缀校验")
    else:
        warn("INST/ADDRCHK",
             "未见明显的地址合法性校验（前缀范围、八位组范围、网络号/广播地址）。"
             "非法地址会让装好的机器直接失联。")

    # ---- 写回 rootfs
    # 必须是「可写挂载」：只 ro 挂载改不了文件，等于没落地。
    if re.search(r"rootfs", inst_code) and \
       re.search(r"mount\b[^\n]*-t\s*ext4[^\n]*-o\s*rw\b|mount\b[^\n]*-o\s*rw[^\n]*-t\s*ext4", inst_code):
        ok("INST/MOUNTROOT", "安装器会可写挂载新写入的 rootfs 分区来落地配置")
    else:
        fail("INST/MOUNTROOT",
             "安装器没有『可写挂载 rootfs 分区』的步骤（需同时出现 rootfs、-t ext4、-o rw）"
             "—— 网口选择只在内存里，装完即丢")
    if re.search(r"Network configuration applied and verified", inst_code):
        ok("INST/APPLYVERIFY", "安装器写回后会只读复验并给出结论")
    else:
        fail("INST/APPLYVERIFY",
             "安装器没有『写入并复验』的完成标志 —— 无法判断配置是否真的落地")

    # ---- 必须删 lan2
    if re.search(r"lan2", inst_code):
        ok("INST/LAN2DROP", "安装器会处理 lan2（第三个口的双内网段）")
    else:
        fail("INST/LAN2DROP",
             "安装器没有处理 lan2。该段固定绑在 eth2 上，装到没有 eth2 的机器会变成"
             "一个挂空的 192.168.2.1，且防火墙 lan 区仍引用它。")

    # ---- 不许再硬编码物理口
    if re.search(r"list ports 'eth0'|ports 'eth0'", inst_code):
        fail("INST/NOHARDCODE",
             "安装器里仍有写死的 ports 'eth0' —— 用户选了别的口也会被覆盖回 eth0")
    else:
        ok("INST/NOHARDCODE", "安装器不再硬编码 br-lan 的物理口")

    # ---- mihomo 联动：改了 LAN 地址不同步会导致代理监听在旧 IP 上
    if re.search(r"bind-address", inst_code):
        ok("INST/MIHOMOADDR", "安装器会同步 mihomo 的 bind-address")
    else:
        warn("INST/MIHOMOADDR",
             "安装器没有同步 mihomo 的 bind-address。若 LAN 地址改了，"
             "mihomo 仍绑在旧地址上，代理会不可用。")


# ----------------------------------------------------------------- 载荷元数据
def check_payload_meta(rb):
    """检查 /installer 目录（若在 ISO 顶层）里的元数据自洽性。"""
    have_any = False
    for mode in ("bios", "uefi"):
        b = iso_read(rb, "/installer/%s.img.bytes" % mode)
        s = iso_read(rb, "/installer/%s.img.raw-sha256" % mode)
        if b is None or s is None:
            continue
        have_any = True
        try:
            nbytes = int(b.decode().strip())
        except ValueError:
            fail("PAYLOAD/BYTES", "%s.img.bytes 内容不是整数" % mode)
            continue
        sha = s.decode().strip()
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            fail("PAYLOAD/SHA", "%s.img.raw-sha256 不是 64 位十六进制" % mode)
        else:
            ok("PAYLOAD/META", "%s 载荷元数据合法（%d 字节，sha=%s…）"
               % (mode, nbytes, sha[:12]))
    if not have_any:
        R.info("PAYLOAD/META", "ISO 顶层没有 /installer 目录（载荷可能在 initramfs 内）")


# ----------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser(description="OpenWrt 安装器 ISO 静态体检")
    ap.add_argument("iso")
    ap.add_argument("--expect-kernel-sha", default=None,
                    help="期望的内核 sha256；给出时会比对 ISO 内 /boot/vmlinuz")
    ap.add_argument("--json", action="store_true", help="以 JSON 输出")
    ap.add_argument("--min-bytes", type=int, default=20 * 1024 * 1024,
                    help="ISO 最小合理字节数（默认 20 MiB）")
    args = ap.parse_args()

    if not os.path.isfile(args.iso):
        print("ERROR: 找不到文件 %s" % args.iso, file=sys.stderr)
        return 2

    size = os.path.getsize(args.iso)
    R.info("FILE/SIZE", "大小 %d 字节（%.1f MiB）" % (size, size / 1048576.0))
    if size < args.min_bytes:
        fail("FILE/SMALL", "ISO 只有 %.1f MiB，小于合理下限 %.1f MiB —— 可能是残缺文件"
             % (size / 1048576.0, args.min_bytes / 1048576.0))

    try:
        rb = io.BufferedReader(open(args.iso, "rb"), buffer_size=1 << 20)
        # 先确认是 ISO9660
        rb.seek(16 * SECTOR)
        pvd = rb.read(7)
        if pvd[1:6] != b"CD001":
            fail("ISO/PVD", "第 16 扇区不是 ISO9660 主卷描述符 —— 这不是 ISO9660 镜像")
        else:
            volid = iso_volid(rb)
            ok("ISO/PVD", "ISO9660 主卷描述符有效，卷标 '%s'" % (volid or ""))
            if volid and "OPENWRT" not in volid.upper():
                warn("ISO/VOLID", "卷标里没有 OPENWRT，确认不是拿错了文件")

        check_boot_area(rb, size)
        grub = check_grub(rb)
        ir_names = check_initramfs(rb) or {}
        check_payload_meta(rb)
        # 菜单名 vs 载荷记录的系统名。放在 initramfs 解析之后做，
        # 因为记录在 initramfs 的 installer/os-name.txt 里。
        check_os_name_vs_payload(menu_os_name(grub or ''), ir_names)

        # 内核比对
        if args.expect_kernel_sha:
            raw = iso_read(rb, "/boot/vmlinuz")
            if raw is None:
                fail("KERNEL/MISSING", "ISO 内没有 /boot/vmlinuz")
            else:
                got = hashlib.sha256(raw).hexdigest()
                if got == args.expect_kernel_sha:
                    ok("KERNEL/SHA", "内核 sha256 匹配（%s…，%d 字节）"
                       % (got[:16], len(raw)))
                else:
                    fail("KERNEL/SHA",
                         "内核 sha256 不匹配！期望 %s…，实际 %s…。"
                         "若内核与 rootfs 内的 /lib/modules 版本不一致，"
                         "启动时会 kernel panic（实测在 nf_defrag_ipv6_disable 处崩）"
                         % (args.expect_kernel_sha[:16], got[:16]))
        rb.close()
    except Exception as e:
        fail("READ", "读取 ISO 失败：%r" % e)

    # -------------------------------------------------------------- 输出
    if args.json:
        print(json.dumps({
            "iso": os.path.abspath(args.iso),
            "bytes": size,
            "fails": R.fails,
            "warns": R.warns,
            "items": [{"level": l, "code": c, "message": m} for l, c, m in R.items],
        }, ensure_ascii=False, indent=2))
    else:
        width = max((len(c) for _, c, _ in R.items), default=10)
        print("")
        print("=" * 78)
        print(" OpenWrt 安装器 ISO 静态体检")
        print(" %s" % os.path.abspath(args.iso))
        print("=" * 78)
        for level, code, msg in R.items:
            tag = {"OK": "  OK  ", "WARN": " WARN ", "FAIL": " FAIL ", "INFO": " info "}[level]
            pad = " " * (width - len(code))
            print("[%s] %s%s  %s" % (tag, code, pad, msg))
        print("-" * 78)
        if R.fails:
            print("结论: FAIL —— %d 项致命问题、%d 项警告" % (R.fails, R.warns))
            print("      这些镜像写盘后必然无法启动，先修再测。")
        elif R.warns:
            print("结论: PASS（有 %d 项警告）—— 结构可启动，建议核对警告项" % R.warns)
        else:
            print("结论: PASS —— 全部检查通过")
        print("")

    return 1 if R.fails else 0


if __name__ == "__main__":
    sys.exit(main())
