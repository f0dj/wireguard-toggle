include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpntoggle
PKG_VERSION:=1.1.0
PKG_RELEASE:=3

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=f0dj <f0dj@users.noreply.github.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vpntoggle
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI panel for the WireGuard VPN toggle
  URL:=https://github.com/f0dj/wireguard-toggle
  DEPENDS:=+luci-base +rpcd-mod-file +vpntoggle
  PKGARCH:=all
endef

define Package/luci-app-vpntoggle/description
  Adds a "VPN Toggle" page (VPN -> VPN Toggle) with on/off/switch buttons, a
  server list with latency, profile import (upload / paste / URL), and kill
  switch + IPv6 leak-protection toggles. The page shows live state, handshake
  age, transfer counters and policy-rule status.
endef

define Build/Compile
endef

define Package/luci-app-vpntoggle/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/vpntoggle
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-vpntoggle.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-vpntoggle.json
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-vpntoggle.json \
		$(1)/usr/share/luci/menu.d/luci-app-vpntoggle.json
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/vpntoggle/index.js \
		$(1)/www/luci-static/resources/view/vpntoggle/index.js
endef

$(eval $(call BuildPackage,luci-app-vpntoggle))
