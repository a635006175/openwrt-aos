# SPDX-License-Identifier: Apache-2.0
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-console
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=OpenWrt network console and system overview
LUCI_DEPENDS:=+luci +luci-theme-console +rpcd-mod-iwinfo +conntrack +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop +ucode-mod-math +openvpn-openssl +openvpn-easy-rsa +kmod-tun +luci-proto-openvpn +sqlite3-cli +firewall4 +uclient-fetch +curl +ca-bundle +ddns-scripts +nftables-json +TARGET_x86_64:console-mihomo

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
