#!/bin/sh
# Build against the exact original OpenWrt kernel; do not bypass ABI checks.
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 /absolute/path/to/original/openwrt-build" >&2; exit 2; fi
case "$1" in /*) ;; *) echo 'Build tree must be an absolute path.' >&2; exit 2;; esac
build=$1
expected=6989ebace8ca6b48ae315baa2f7db7d3
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
[ -f "$build/.config" ] && [ -f "$build/include/kernel.mk" ] || { echo 'Not an existing OpenWrt build tree.' >&2; exit 1; }
[ -f "$build/staging_dir/target-x86_64_musl/kernel.version" ] || { echo 'Original target kernel.version not found.' >&2; exit 1; }
[ "$(cat "$build/staging_dir/target-x86_64_musl/kernel.version")" = "6.18.55~${expected}-r1" ] || { echo 'Kernel package ABI does not match the target.' >&2; exit 1; }
config_vermagic="$build/build_dir/target-x86_64_musl/linux-x86_64/linux-6.18.55/.vermagic"
[ -f "$config_vermagic" ] && [ "$(cat "$config_vermagic")" = "$expected" ] || { echo 'Prepared kernel tree is missing or ABI differs.' >&2; exit 1; }
[ -f "$build/build_dir/target-x86_64_musl/linux-x86_64/linux-6.18.55/Module.symvers" ] || { echo 'Original kernel Module.symvers is missing.' >&2; exit 1; }
[ "$(git -C "$build" rev-parse HEAD)" = '29cf0022eb3f030d538ba452487c44611b106ed2' ] || { echo 'OpenWrt revision does not match.' >&2; exit 1; }
[ ! -e "$build/package/OpenAppFilter" ] || { echo 'package/OpenAppFilter already exists; inspect it manually.' >&2; exit 1; }
cp -R "$source_root/package/OpenAppFilter" "$build/package/OpenAppFilter"
cd "$build"
config_backup=$(mktemp "${TMPDIR:-/tmp}/console-oaf-config.XXXXXXXX")
cp -p .config "$config_backup"
trap 'cp -p "$config_backup" .config; rm -f "$config_backup"' EXIT
printf '\nCONFIG_PACKAGE_luci-app-oaf=m\n' >> .config
make defconfig
grep -Eq '^CONFIG_PACKAGE_luci-app-oaf=[ym]$' .config || { echo 'OAF package selection failed.' >&2; exit 1; }
make package/oaf/compile V=s
make package/open-app-filter/compile V=s
make package/luci-app-oaf/compile V=s
printf '%s\n' 'Build finished; verify and test generated packages before installing.'
