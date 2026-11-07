include $(TOPDIR)/rules.mk

PKG_NAME:=vpntoggle
PKG_VERSION:=1.1.0
PKG_RELEASE:=3

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=f0dj <f0dj@users.noreply.github.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_USE_MIPS16:=0

include $(INCLUDE_DIR)/package.mk

define Package/vpntoggle
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Random WireGuard profile toggle for the LAN
  URL:=https://github.com/f0dj/wireguard-toggle
  DEPENDS:=+wireguard-tools +kmod-wireguard +dnsmasq +ip-tiny +uci +nftables
  PKGARCH:=all
endef

define Package/vpntoggle/description
  Toggles the whole LAN between direct internet and a random WireGuard
  profile (e.g. Proton VPN), with staged bring-up, self-verification and
  automatic rollback so the router can never be locked out. Includes an
  optional kill switch, IPv6 leak protection and a boot-time failsafe via
  /etc/init.d/vpntoggle (a reboot always returns to direct internet).

  Drop wg-quick style *.conf profiles into /etc/wireguard/profiles
  (default, configurable in /etc/config/vpntoggle) and run:
      vpn-toggle setup
      vpn-toggle on    # routes LAN through a random profile
      vpn-toggle off   # restores direct internet
      vpn-toggle switch

  Requires an ip binary with policy routing support (ip-tiny or ip-full).
endef

define Package/vpntoggle/conffiles
/etc/config/vpntoggle
endef

define Build/Compile
endef

define Package/vpntoggle/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/sbin/vpn-toggle $(1)/usr/sbin/vpn-toggle
	$(INSTALL_CONF) ./files/etc/config/vpntoggle $(1)/etc/config/vpntoggle
	$(INSTALL_BIN) ./files/etc/init.d/vpntoggle $(1)/etc/init.d/vpntoggle
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	echo "/etc/wireguard/" > $(1)/lib/upgrade/keep.d/vpntoggle
endef

define Package/vpntoggle/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	[ -x /etc/init.d/vpntoggle ] && /etc/init.d/vpntoggle enable 2>/dev/null

	# create the profile directory with restrictive permissions
	mkdir -p /etc/wireguard/profiles
	chmod 700 /etc/wireguard /etc/wireguard/profiles 2>/dev/null
	chmod 600 /etc/wireguard/profiles/*.conf 2>/dev/null

	# create the fw4 'vpn' zone + lan->vpn forwarding, and enable the boot
	# failsafe, so the package works out of the box (idempotent)
	[ -x /usr/sbin/vpn-toggle ] && /usr/sbin/vpn-toggle setup >/dev/null 2>&1

	# migrate from the old manual installer: it added package-owned files (and
	# /etc/wireguard/, now covered by the keep.d file this package installs) to
	# the sysupgrade backup list, plus an rc.local hook. Remove those stale
	# entries so the package manager owns the files.
	if [ -f /etc/sysupgrade.conf ]; then
		sed -i \
			-e '\#^/usr/sbin/vpn-toggle$$#d' \
			-e '\#^/etc/config/vpntoggle$$#d' \
			-e '\#^/etc/init.d/vpntoggle$$#d' \
			-e '\#^/usr/share/rpcd/acl.d/luci-app-vpntoggle.json$$#d' \
			-e '\#^/usr/share/luci/menu.d/luci-app-vpntoggle.json$$#d' \
			-e '\#^/www/luci-static/resources/view/vpntoggle/index.js$$#d' \
			-e '\#^/etc/wireguard$$#d' \
			-e '\#^/etc/wireguard/$$#d' \
			/etc/sysupgrade.conf
	fi
	if [ -f /etc/rc.local ]; then
		sed -i '/vpn-toggle reset/d' /etc/rc.local
	fi
fi
exit 0
endef

define Package/vpntoggle/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	[ -x /etc/init.d/vpntoggle ] && /etc/init.d/vpntoggle disable 2>/dev/null
	# restore DNS/routes/leak rules and drop the tunnel before removal
	[ -x /usr/sbin/vpn-toggle ] && /usr/sbin/vpn-toggle reset >/dev/null 2>&1
	rm -rf /etc/vpntoggle/state
fi
exit 0
endef

$(eval $(call BuildPackage,vpntoggle))
