#!/bin/sh
# uninstall-router.sh - remove every trace of the MANUAL vpntoggle install
# from an OpenWrt router, so the apk package can own the files cleanly.
#
# Run as root on the router (Dropbear has no sftp-server, so stream over ssh):
#   cat uninstall-router.sh | ssh root@192.168.1.1 sh
#
# It is safe to re-run. It does NOT delete your WireGuard profiles in
# /etc/wireguard/profiles (those are your data). Pass --purge-profiles to
# remove them too.

PURGE=0
[ "$1" = "--purge-profiles" ] && PURGE=1

echo "== [1/8] stop boot failsafe =="
if [ -x /etc/init.d/vpntoggle ]; then
	/etc/init.d/vpntoggle disable 2>/dev/null
	/etc/init.d/vpntoggle stop 2>/dev/null
fi

echo "== [2/8] restore DNS / routes / leak rules =="
if [ -x /usr/sbin/vpn-toggle ]; then
	/usr/sbin/vpn-toggle reset 2>/dev/null
fi

echo "== [3/8] remove firewall zone + forwarding =="
uci -q delete firewall.vpn 2>/dev/null
uci -q delete firewall.lan_vpn 2>/dev/null
uci commit firewall 2>/dev/null
/etc/init.d/firewall reload >/dev/null 2>&1

echo "== [4/8] remove netifd interface =="
uci -q delete network.wgclient 2>/dev/null
uci -q delete network.wireguard_wgclient 2>/dev/null
uci commit network 2>/dev/null
ifdown wgclient 2>/dev/null

echo "== [5/8] remove installed files =="
rm -f /usr/sbin/vpn-toggle
rm -f /etc/config/vpntoggle
rm -f /etc/init.d/vpntoggle
rm -f /usr/share/rpcd/acl.d/luci-app-vpntoggle.json
rm -f /usr/share/luci/menu.d/luci-app-vpntoggle.json
rm -rf /www/luci-static/resources/view/vpntoggle
rm -rf /etc/vpntoggle
if [ "$PURGE" = 1 ]; then
	rm -rf /etc/wireguard/profiles
	echo "  (profiles purged)"
else
	echo "  (profiles in /etc/wireguard/profiles kept)"
fi

echo "== [6/8] remove uci package state =="
uci -q delete vpntoggle.main 2>/dev/null
uci commit vpntoggle 2>/dev/null
rm -f /etc/config/vpntoggle

echo "== [7/8] strip rc.local + sysupgrade.conf traces =="
if [ -f /etc/rc.local ]; then
	sed -i '/vpn-toggle reset/d' /etc/rc.local
fi
if [ -f /etc/sysupgrade.conf ]; then
	sed -i \
		-e '\#^/usr/sbin/vpn-toggle$#d' \
		-e '\#^/etc/config/vpntoggle$#d' \
		-e '\#^/etc/init.d/vpntoggle$#d' \
		-e '\#^/usr/share/rpcd/acl.d/luci-app-vpntoggle.json$#d' \
		-e '\#^/usr/share/luci/menu.d/luci-app-vpntoggle.json$#d' \
		-e '\#^/www/luci-static/resources/view/vpntoggle/index.js$#d' \
		-e '\#^/etc/rc.local$#d' \
		-e '\#^/etc/sysupgrade.conf$#d' \
		/etc/sysupgrade.conf
fi

echo "== [8/8] refresh LuCI + rpcd caches =="
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart >/dev/null 2>&1

echo "== done: manual vpntoggle removed =="
echo "Install the package with:  apk add --allow-untrusted /tmp/vpntoggle-*.apk /tmp/luci-app-vpntoggle-*.apk"
