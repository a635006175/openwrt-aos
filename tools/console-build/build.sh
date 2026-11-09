#!/usr/bin/env bash
# Run with bash on Linux/WSL. Do not run as root or build on a Windows mount.
set -euo pipefail

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
build_root=${OPENWRT_BUILD_DIR:-"$HOME/openwrt-console-build"}
revision=29cf0022eb3f030d538ba452487c44611b106ed2
jobs=${OPENWRT_BUILD_JOBS:-2}

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Linux ]] || fail 'A Linux build environment is required.'
[[ $EUID != 0 ]] || fail 'Run this script as a regular Linux user, not root.'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail 'OPENWRT_BUILD_JOBS must be a positive integer.'
[[ $build_root == /* ]] || fail 'OPENWRT_BUILD_DIR must be an absolute path.'
[[ $build_root != *[[:space:]]* ]] || fail 'The build directory must not contain whitespace.'
for command in git make gcc g++ gawk rsync sha256sum xorriso mkfs.fat mcopy; do
  command -v "$command" >/dev/null || fail "Missing build dependency: $command"
done

# Check the filesystem itself (also rejects Windows drives mounted elsewhere).
mkdir -p -- "$build_root"
build_root=$(cd -- "$build_root" && pwd -P)
case $(stat -f -c %T "$build_root") in
  9p|drvfs|ntfs|ntfs3|fuseblk) fail 'Build on the Linux filesystem, not a Windows drive.' ;;
esac
[[ $build_root != /mnt/* ]] || fail 'Use a directory under your Linux home for the build.'

if [[ ! -d $build_root/.git ]]; then
  [[ -z $(find "$build_root" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail 'Existing build directory is not an empty Git checkout.'
  git -c core.autocrlf=false clone --no-hardlinks --no-checkout "$source_root" "$build_root"
  git -C "$build_root" -c core.autocrlf=false -c core.symlinks=true checkout --detach "$revision"
fi
[[ $(git -C "$build_root" rev-parse HEAD) == "$revision" ]] || fail 'Build checkout revision differs from the pinned revision.'
[[ $build_root != "$source_root" ]] || fail 'Use a separate Linux checkout for the build.'

# Only synchronize this custom package; preserve unrelated source files.
rsync -a -- "$source_root/package/luci-app-console/" "$build_root/package/luci-app-console/"
rsync -a -- "$source_root/package/luci-theme-console/" "$build_root/package/luci-theme-console/"
rsync -a -- "$source_root/package/OpenAppFilter/" "$build_root/package/OpenAppFilter/"
cd -- "$build_root"
if [[ -e feeds.conf ]] && ! cmp -s feeds.conf "$source_root/config/console-feeds.conf"; then
  fail 'Existing feeds.conf differs from the pinned feeds; use a separate build directory.'
fi
cp -- "$source_root/config/console-feeds.conf" feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

if [[ -e .config ]]; then
  cp -- .config ".config.before-console.$(date +%Y%m%d-%H%M%S).$$"
fi
cp -- "$source_root/config/console-x86_64.config" .config
make defconfig
for required in TARGET_x86_64_DEVICE_generic PACKAGE_luci-app-console PACKAGE_luci-app-oaf PACKAGE_openvpn-openssl PACKAGE_openvpn-easy-rsa PACKAGE_luci-proto-openvpn PACKAGE_kmod-tun ISO_IMAGES GRUB_IMAGES GRUB_EFI_IMAGES TARGET_ROOTFS_EXT4FS; do
  grep -qx "CONFIG_${required}=y" .config || fail "Configuration could not enable $required."
done

mkdir -p logs
make -j"$jobs" download V=s 2>&1 | tee logs/console-download.log
make -j"$jobs" V=s 2>&1 | tee logs/console-build.log

output=bin/targets/x86/64
shopt -s nullglob
isos=("$output/"*.iso)
disks=("$output/"*ext4-combined*.img.gz)
(( ${#isos[@]} >= 2 && ${#disks[@]} >= 2 )) || fail 'Expected BIOS/UEFI ISO and disk images were not all generated.'
grep -q '^luci-app-console ' "$output/"*.manifest || fail 'Firmware manifest does not contain luci-app-console.'
grep -q '^luci-theme-console ' "$output/"*.manifest || fail 'Firmware manifest does not contain luci-theme-console.'
for package in luci-app-oaf openvpn-openssl openvpn-easy-rsa luci-proto-openvpn kmod-tun; do
  grep -q "^${package} " "$output/"*.manifest || fail "Firmware manifest does not contain ${package}."
done
for image in "${disks[@]}"; do gzip -t "$image"; done
(
  cd -- "$output"
  sha256sum -- *.iso *ext4-combined*.img.gz > console-sha256sums.txt
  git -C "$build_root" rev-parse HEAD > console-source-revision.txt
  cp -- "$build_root/.config" console-build.config
  cp -- "$build_root/feeds.conf" console-feeds.conf
)
printf '\nBuild completed: %s/%s\n' "$build_root" "$output"
printf 'Raw build outputs are intermediate firmware. Publish the installer only through .dsh/skills/openwrt-installer-image/scripts/build-iso.sh.\n'
printf 'The single installer release path is /home/openwrt/console-sync/openwrt-console-installer.iso.\n'
