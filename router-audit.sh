#!/bin/sh
# router-audit.sh - READ-ONLY reconnaissance of an existing vpntoggle install on
# an OpenWrt router. Collects everything needed to plan a clean migration from
# the manual install to the apk packages.
#
# Usage:
#   ./router-audit.sh [user@host]        (default: root@192.168.1.1)
#
# Output: .router-audit/<timestamp>/
#   audit.txt               full labelled dump (all commands + results)
#   files/*                 selected config files (private keys redacted)
#
# This script makes NO changes to the router. WireGuard private/preshared keys
# are redacted before anything is written locally.

set -eu

RAW="${1:-192.168.1.1}"
case "$RAW" in
	*@*) ROUTER="$RAW" ;;
	*)   ROUTER="root@$RAW" ;;
esac
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT=".router-audit/$STAMP"
mkdir -p "$OUT/files"

# single SSH connection shared by every call, so the password is asked once
CTRL="$OUT/ssh-ctl"
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTRL -o ControlPersist=120"

echo "== auditing $ROUTER -> $OUT =="
echo "== (read-only; you may be prompted once for the router password) =="

if ! $SSH -o ConnectTimeout=10 "$ROUTER" true; then
	echo "ERROR: cannot ssh to $ROUTER" >&2
	exit 1
fi
echo

# ---------------------------------------------------------------------------
# 1. single SSH session: full labelled dump
# ---------------------------------------------------------------------------
$SSH "$ROUTER" sh -s > "$OUT/audit.txt" <<'REMOTE'
#!/bin/sh
exec 2>&1
sec() { echo; echo "############ $* ############"; }
hdr() { echo "---------- $* ----------"; }

sec "system / board"
hdr "ubus call system board"
ubus call system board 2>/dev/null || true
hdr "cat /etc/openwrt_release"
cat /etc/openwrt_release 2>/dev/null || true
hdr "uname -a"
uname -a 2>/dev/null || true

sec "package manager"
hdr "apk --version / opkg --version"
apk --version 2>/dev/null || true
opkg --version 2>/dev/null || true
hdr "cat /etc/apk/repositories"
cat /etc/apk/repositories 2>/dev/null || true

sec "installed packages (wireguard/vpn/luci)"
hdr "matching installed packages"
apk info 2>/dev/null | grep -iE 'wireguard|vpn|luci' || true
opkg list-installed 2>/dev/null | grep -iE 'wireguard|vpn|luci' || true
hdr "is vpntoggle a package?"
apk info -e vpntoggle 2>/dev/null && echo "vpntoggle: package installed" || echo "vpntoggle: NOT a package"
apk info -e luci-app-vpntoggle 2>/dev/null && echo "luci-app-vpntoggle: package installed" || echo "luci-app-vpntoggle: NOT a package"

sec "vpntoggle deployment: files + hashes"
hdr "ls -la"
ls -la /usr/sbin/vpn-toggle /etc/init.d/vpntoggle /etc/config/vpntoggle 2>/dev/null || true
ls -la /usr/share/rpcd/acl.d/luci-app-vpntoggle.json 2>/dev/null || true
ls -la /usr/share/luci/menu.d/luci-app-vpntoggle.json 2>/dev/null || true
ls -la /www/luci-static/resources/view/vpntoggle/ 2>/dev/null || true
hdr "sha256sum (fallback md5sum)"
sha256sum /usr/sbin/vpn-toggle /etc/init.d/vpntoggle /etc/config/vpntoggle \
	/usr/share/rpcd/acl.d/luci-app-vpntoggle.json \
	/usr/share/luci/menu.d/luci-app-vpntoggle.json \
	/www/luci-static/resources/view/vpntoggle/index.js 2>/dev/null || \
	md5sum /usr/sbin/vpn-toggle /etc/init.d/vpntoggle /etc/config/vpntoggle \
	/usr/share/rpcd/acl.d/luci-app-vpntoggle.json \
	/usr/share/luci/menu.d/luci-app-vpntoggle.json \
	/www/luci-static/resources/view/vpntoggle/index.js 2>/dev/null || true

sec "uci: vpntoggle"
hdr "uci show vpntoggle"
uci show vpntoggle 2>/dev/null || true
hdr "cat /etc/config/vpntoggle"
cat /etc/config/vpntoggle 2>/dev/null || true

sec "uci: firewall"
hdr "uci show firewall"
uci show firewall 2>/dev/null || true

sec "uci: network (keys redacted)"
hdr "uci show network | redacted"
uci show network 2>/dev/null | sed -E 's/(private_key=).*/\1<redacted>/; s/(preshared_key=).*/\1<redacted>/' || true
hdr "wgclient sections present?"
uci show network 2>/dev/null | grep -q wgclient && echo "yes: wgclient uci section exists" || echo "no: no wgclient uci section"

sec "uci: dhcp / dnsmasq"
hdr "dnsmasq-relevant dhcp config"
uci show dhcp 2>/dev/null | grep -i dnsmasq || true

sec "init.d / boot hooks"
hdr "rc.d links"
ls -la /etc/rc.d/ 2>/dev/null | grep -i vpn || echo "no vpntoggle rc.d link"
hdr "cat /etc/rc.local"
cat /etc/rc.local 2>/dev/null || true

sec "wireguard profiles"
hdr "ls -la /etc/wireguard /etc/wireguard/profiles"
ls -la /etc/wireguard /etc/wireguard/profiles 2>/dev/null || true

sec "sysupgrade backup list"
hdr "sysupgrade -l"
sysupgrade -l 2>/dev/null || true
hdr "cat /etc/sysupgrade.conf"
cat /etc/sysupgrade.conf 2>/dev/null || true
hdr "ls /lib/upgrade/keep.d/"
ls -la /lib/upgrade/keep.d/ 2>/dev/null || true
hdr "keep.d contents"
for f in /lib/upgrade/keep.d/*; do
	[ -e "$f" ] || continue
	echo "-- $f --"
	cat "$f" 2>/dev/null
done

sec "runtime state"
hdr "vpn-toggle status"
vpn-toggle status 2>&1 || true
hdr "vpn-toggle info"
vpn-toggle info 2>&1 || true
hdr "vpn-toggle list"
vpn-toggle list 2>&1 || true
hdr "wg show (private key redacted)"
wg show 2>&1 | sed -E 's/(private key:).*/\1 <redacted>/' || true
hdr "ip rule show"
ip rule show 2>/dev/null || true
hdr "ip -4 route show table 100"
ip -4 route show table 100 2>/dev/null || true
hdr "nft list table inet vpntoggle"
nft list table inet vpntoggle 2>&1 || true
hdr "state directories"
ls -la /var/run/vpntoggle /etc/vpntoggle /etc/vpntoggle/state 2>/dev/null || true
hdr "dns backup file"
cat /etc/vpntoggle/state/dns.bak 2>/dev/null || true

sec "luci files"
hdr "rpcd acl"
cat /usr/share/rpcd/acl.d/luci-app-vpntoggle.json 2>/dev/null || true
hdr "menu entry"
cat /usr/share/luci/menu.d/luci-app-vpntoggle.json 2>/dev/null || true

sec "recent related logs"
hdr "logread | grep"
logread 2>/dev/null | grep -iE 'vpn-toggle|vpntoggle|wgclient|wireguard' | tail -50 || true

sec "end"
echo "audit complete"
REMOTE

# ---------------------------------------------------------------------------
# 2. fetch selected files verbatim (network redacted locally afterwards)
# ---------------------------------------------------------------------------
fetch() { $SSH "$ROUTER" "cat '$2' 2>/dev/null" > "$OUT/files/$1" || true; }

fetch sysupgrade.conf      /etc/sysupgrade.conf
fetch config-vpntoggle     /etc/config/vpntoggle
fetch init.d-vpntoggle     /etc/init.d/vpntoggle
fetch rc.local             /etc/rc.local
fetch config-network.txt   /etc/config/network
fetch config-firewall.txt  /etc/config/firewall
fetch acl.json             /usr/share/rpcd/acl.d/luci-app-vpntoggle.json
fetch menu.json            /usr/share/luci/menu.d/luci-app-vpntoggle.json

# /etc/config/network is UCI *file* syntax (`option private_key '...'`), not
# `uci show` syntax (`private_key=...`). Redact both shapes; the second rule
# cannot re-match the output of the first, so this is idempotent.
sed -i -E \
	-e "s/(private_key[[:space:]]*=[[:space:]]*).*/\1<redacted>/" \
	-e "s/(preshared_key[[:space:]]*=[[:space:]]*).*/\1<redacted>/" \
	-e "s/((private_key|preshared_key)[[:space:]]+).*/\1'<redacted>'/" \
	"$OUT/files/config-network.txt" 2>/dev/null || true

# Never hand back a dump we cannot vouch for.
if grep -qE "(private_key|preshared_key)[[:space:]]*[= ][[:space:]]*'?[A-Za-z0-9+/]{20,}" \
	"$OUT/files/config-network.txt" 2>/dev/null; then
	echo "WARNING: possible key material left in $OUT/files/config-network.txt" >&2
	echo "         do not share this dump; report this as a bug" >&2
fi

$SSH -O exit "$ROUTER" 2>/dev/null || true

echo
echo "== done =="
echo "   dump:  $OUT/audit.txt"
echo "   files: $OUT/files/"
echo "   (WireGuard keys in the network config are redacted)"
