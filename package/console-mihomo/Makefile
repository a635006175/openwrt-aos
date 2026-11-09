# SPDX-License-Identifier: GPL-3.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=console-mihomo
PKG_VERSION:=1.19.33
PKG_RELEASE:=1
PKG_SOURCE:=mihomo-linux-amd64-compatible-v$(PKG_VERSION).gz
PKG_SOURCE_URL:=https://github.com/MetaCubeX/mihomo/releases/download/v$(PKG_VERSION)/
PKG_HASH:=386508bfb1c72c43b6a0eda73708ecdce82546581b0ebcb16366c53757c622b6
PKG_LICENSE:=GPL-3.0-only

include $(INCLUDE_DIR)/package.mk

define Package/console-mihomo
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Mihomo core for Console VPN
  DEPENDS:=@TARGET_x86_64 +ca-bundle
  URL:=https://github.com/MetaCubeX/mihomo
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) > $(PKG_BUILD_DIR)/mihomo
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/console-mihomo/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mihomo $(1)/usr/bin/mihomo
endef

$(eval $(call BuildPackage,console-mihomo))
