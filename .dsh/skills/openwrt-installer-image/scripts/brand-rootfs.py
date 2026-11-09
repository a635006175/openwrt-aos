#!/usr/bin/env python3
"""Set the product name / release version inside a *disposable* release rootfs copy.

安装盘（ISO）的 GRUB 菜单由 build-iso.sh 负责；装好之后硬盘上的 GRUB 菜单由
build-payload.sh 负责。本脚本只管「装好后的系统自报什么版本」这一层，也就是
内核启动完之后用户能看到的那些身份文件：

  etc/console-version   发布标记；verify-e2e.sh 用它确认装进去的是这一版
  usr/lib/os-release    procd 解析它填 ubus system board 的 release.* 字段
                        （NAME->distribution / VERSION->version /
                          OPENWRT_RELEASE->description），控制台首页的
                        「版本」卡片显示的就是 version + target
  etc/openwrt_release   luci.version 读 DISTRIB_DESCRIPTION
  etc/banner            登录 banner 里那行 "OpenWrt SNAPSHOT, r0-…"

刻意**不改**的东西，以及为什么：

  · DISTRIB_ID / os-release 的 NAME、ID 保持 OpenWrt
    —— apk 源、attended sysupgrade、按发行版名分支的脚本都看它；
      用户也明确要求保留 DISTRIB_ID。
  · etc/openwrt_version（内容 r0-29cf002）保持不动
    —— 这是上游快照号，OpenAppFilter 的 dashboard.htm 会拿它和 'SNAPSHOT'
      比较来拼版本串；改成产品名只会让那段逻辑走不到本意分支。
  · VERSION_ID 保持 snapshot
    —— 机器可读字段，改动没有收益但可能影响外部工具。

用法：
    python3 brand-rootfs.py <rootfs> --name AOS-20261109-V1
    python3 brand-rootfs.py <rootfs> --name AOS-20261109-V1 --check
"""
import argparse
import re
import sys
from pathlib import Path

# os-release 里被改写的键；顺序无关，按行匹配
OS_RELEASE_SET = {
    "VERSION": "{name}",
    "PRETTY_NAME": "{name}",
    "OPENWRT_RELEASE": "{name} {revision}",
}
OPENWRT_RELEASE_SET = {
    "DISTRIB_DESCRIPTION": "{name} {revision}",
}


def die(msg):
    print("brand-rootfs: ERROR: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def read_revision(root):
    """上游快照号：优先 /etc/openwrt_version，退而求其次用 DISTRIB_REVISION。"""
    ver = root / "etc/openwrt_version"
    if ver.is_file():
        text = ver.read_text(encoding="utf-8").strip()
        if text:
            return text
    rel = root / "etc/openwrt_release"
    if rel.is_file():
        m = re.search(r"^DISTRIB_REVISION=['\"]?([^'\"\n]+)", rel.read_text(encoding="utf-8"), re.M)
        if m:
            return m.group(1).strip()
    return ""


def real_target(root, relpath):
    """解析 rootfs 内的符号链接（/etc/os-release -> ../usr/lib/os-release）。

    必须写到真实文件上：直接覆盖符号链接会把它变成一个独立的普通文件，
    装好之后 /etc/os-release 与 /usr/lib/os-release 就不再是同一份内容，
    procd（读 /usr/lib）和 luci dispatcher（读 /etc）会显示两个版本。
    """
    p = root / relpath
    if not p.exists():
        die("rootfs 里缺 %s" % relpath)
    if p.is_symlink():
        target = (p.parent / p.readlink()).resolve()
        try:
            target.relative_to(root.resolve())
        except ValueError:
            die("%s 指向 rootfs 之外：%s" % (relpath, target))
        return target, relpath + " (-> %s)" % target.relative_to(root.resolve()).as_posix()
    return p, relpath


def rewrite_kv(path, mapping, ctx):
    """按行改写 KEY=VALUE。只动 mapping 里列出的键，注释与其余键原样保留。"""
    text = path.read_text(encoding="utf-8")
    out = []
    seen = set()
    for line in text.splitlines(True):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if not m or m.group(1) not in mapping:
            out.append(line)
            continue
        key = m.group(1)
        seen.add(key)
        value = mapping[key].format(**ctx)
        out.append('%s="%s"\n' % (key, value))
    missing = set(mapping) - seen
    if missing:
        die("%s 里缺少键：%s" % (path.name, ", ".join(sorted(missing))))
    path.write_text("".join(out), encoding="utf-8")


def rewrite_banner(path, ctx):
    """把 banner 里那行 " OpenWrt SNAPSHOT, r0-…" 换成产品名，保留快照号。"""
    lines = path.read_text(encoding="utf-8").splitlines(True)
    hit = 0
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("OpenWrt") and "," in s:
            lines[i] = " %s, %s\n" % (ctx["name"], ctx["revision"])
            hit += 1
    if hit != 1:
        die("etc/banner 里期望恰好 1 行 'OpenWrt …, …'，实际匹配 %d 行" % hit)
    path.write_text("".join(lines), encoding="utf-8")


def apply(root, name):
    revision = read_revision(root)
    ctx = {"name": name, "revision": revision}

    (root / "etc/console-version").write_text(name + "\n", encoding="utf-8")

    os_rel, os_rel_desc = real_target(root, "etc/os-release")
    rewrite_kv(os_rel, OS_RELEASE_SET, ctx)

    openwrt_rel = root / "etc/openwrt_release"
    if not openwrt_rel.is_file():
        die("rootfs 里缺 etc/openwrt_release")
    rewrite_kv(openwrt_rel, OPENWRT_RELEASE_SET, ctx)

    banner = root / "etc/banner"
    if banner.is_file():
        rewrite_banner(banner, ctx)

    return {"name": name, "revision": revision, "os_release_file": os_rel_desc}


def check(root, name):
    problems = []
    ver = root / "etc/console-version"
    got = ver.read_text(encoding="utf-8").strip() if ver.is_file() else None
    if got != name:
        problems.append("etc/console-version=%r 应为 %r" % (got, name))

    os_rel, _ = real_target(root, "etc/os-release")
    text = os_rel.read_text(encoding="utf-8")
    for key in ("VERSION", "PRETTY_NAME"):
        m = re.search(r'^%s="(.*)"$' % key, text, re.M)
        if not m or m.group(1) != name:
            problems.append("os-release %s=%r 应为 %r" % (key, m.group(1) if m else None, name))
    m = re.search(r'^OPENWRT_RELEASE="(.*)"$', text, re.M)
    if not m or not m.group(1).startswith(name):
        problems.append("os-release OPENWRT_RELEASE=%r 应以 %r 开头"
                        % (m.group(1) if m else None, name))

    rel = root / "etc/openwrt_release"
    text = rel.read_text(encoding="utf-8")
    m = re.search(r"^DISTRIB_DESCRIPTION=['\"]?(.*?)['\"]?$", text, re.M)
    if not m or not m.group(1).startswith(name):
        problems.append("openwrt_release DISTRIB_DESCRIPTION=%r 应以 %r 开头"
                        % (m.group(1) if m else None, name))
    # 保留项：DISTRIB_ID 必须仍是 OpenWrt（用户明确要求）
    m = re.search(r"^DISTRIB_ID=['\"]?(.*?)['\"]?$", text, re.M)
    if not m or m.group(1) != "OpenWrt":
        problems.append("openwrt_release DISTRIB_ID 应保持 OpenWrt，实际 %r"
                        % (m.group(1) if m else None))

    banner = root / "etc/banner"
    if banner.is_file() and name not in banner.read_text(encoding="utf-8"):
        problems.append("etc/banner 未包含 %r" % name)

    if problems:
        print("brand-rootfs --check FAIL")
        for p in problems:
            print("  - " + p)
        return False
    print("brand-rootfs --check OK: %s" % name)
    return True


def main():
    ap = argparse.ArgumentParser(description="给发行 rootfs 副本写入产品名/版本")
    ap.add_argument("rootfs")
    ap.add_argument("--name", required=True,
                    help="产品名与版本，例如 AOS-20261109-V1")
    ap.add_argument("--check", action="store_true", help="只校验，不写入")
    args = ap.parse_args()

    root = Path(args.rootfs).resolve()
    # 防手滑：只允许对真正的 release rootfs 目录操作，绝不对实机根目录跑
    if str(root) == "/" or not (root / "etc/config/network").is_file():
        die("%s 不是 release rootfs 目录" % root)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.name):
        die("产品名只允许 ASCII 字母、数字、点、下划线、短横线：%r" % args.name)

    if args.check:
        raise SystemExit(0 if check(root, args.name) else 1)

    info = apply(root, args.name)
    print("brand-rootfs: %s (revision %s) -> %s"
          % (info["name"], info["revision"], info["os_release_file"]))
    raise SystemExit(0 if check(root, args.name) else 1)


if __name__ == "__main__":
    main()
