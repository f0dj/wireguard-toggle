#!/bin/sh
# migrate-to-apk.sh - replace a legacy MANUAL vpntoggle install on an OpenWrt
# router with the apk packages, safely and verifiably.
#
# Prereq: build the packages first.
#   ./build-apk.sh
#
# Then, from the repo root:
#   ./migrate-to-apk.sh [user@host]        (default root@192.168.1.1)
#
# Env:
#   PULL_BACKUP=1   also copy the pre-migration config backup to the host
#                   (WARNING: it contains WireGuard private keys)
#   TEST=1          after install, cycle on/off to verify, then leave OFF
#
# Flow: preflight -> safety backup -> stage .apk -> uninstall legacy ->
#       apk add -> verify (ownership, keep.d, backup list, firewall, status).
#
# The router must be OFF (direct internet) before running this.

set -eu

RAW="${1:-192.168.1.1}"
case "$RAW" in
	*@*) ROUTER="$RAW" ;;
	*)   ROUTER="root@$RAW" ;;
esac

REPO=$(cd "$(dirname "$0")" && pwd)
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT=".router-audit/$STAMP-migration"
mkdir -p "$OUT"

if [ -z "$(ls "$REPO"/dist/vpntoggle-*.apk 2>/dev/null)" ]; then
	echo "ERROR: no dist/vpntoggle-*.apk - run ./build-apk.sh first" >&2
	exit 1
fi
if [ -z "$(ls "$REPO"/dist/luci-app-vpntoggle-*.apk 2>/dev/null)" ]; then
	echo "ERROR: no dist/luci-app-vpntoggle-*.apk - run ./build-apk.sh first" >&2
	exit 1
fi

CTRL="$OUT/ssh-ctl"
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTRL -o ControlPersist=300"
# NB: files are streamed over ssh (tar/cat), not scp: Dropbear has no
# sftp-server, which modern OpenSSH scp requires by default.

echo "== migrating $ROUTER to apk packages =="
echo "== logs -> $OUT =="
$SSH -o ConnectTimeout=10 "$ROUTER" true

# ---------------------------------------------------------------------------
echo "== [1/7] preflight =="
if ! $SSH "$ROUTER" sh -s > "$OUT/preflight.txt" 2>&1 <<'REMOTE'
set -e
echo "-- current state --"
vpn-toggle status 2>/dev/null || true
if vpn-toggle status 2>/dev/null | grep -q 'State: ON'; then
	echo "REFUSING: tunnel is ON. run 'vpn-toggle off' first." >&2
	exit 3
fi
echo "-- required runtime commands --"
for c in wg nft ip uci dnsmasq; do
	if command -v "$c" >/dev/null 2>&1; then echo "ok: $c"; else echo "MISSING: $c" >&2; exit 4; fi
done
echo "-- package dependencies --"
for p in wireguard-tools kmod-wireguard dnsmasq luci-base rpcd-mod-file; do
	if apk info -e "$p" >/dev/null 2>&1; then echo "ok: $p"; else echo "WARN: not installed: $p"; fi
done
echo "-- apk feeds --"
ls -la /etc/apk/repositories.d/ 2>/dev/null || true
cat /etc/apk/repositories.d/* 2>/dev/null || true
REMOTE
then
	cat "$OUT/preflight.txt"
	echo "== preflight FAILED - aborting, nothing changed ==" >&2
	exit 1
fi
cat "$OUT/preflight.txt"

# ---------------------------------------------------------------------------
echo "== [2/7] safety backup =="
$SSH "$ROUTER" 'sysupgrade -b /tmp/vpntoggle-pre-migration.tar.gz && ls -l /tmp/vpntoggle-pre-migration.tar.gz'
if [ "${PULL_BACKUP:-0}" = 1 ]; then
	$SSH "$ROUTER" 'cat /tmp/vpntoggle-pre-migration.tar.gz' > "$OUT/vpntoggle-pre-migration.tar.gz"
	echo "  pulled to $OUT/vpntoggle-pre-migration.tar.gz (contains private keys)"
else
	echo "  stored on router: /tmp/vpntoggle-pre-migration.tar.gz"
	echo "  (set PULL_BACKUP=1 to copy it here before you start)"
fi

# ---------------------------------------------------------------------------
echo "== [3/7] stage packages on router =="
( cd "$REPO/dist" && tar -cf - vpntoggle-*.apk luci-app-vpntoggle-*.apk ) | \
	$SSH "$ROUTER" 'tar -C /tmp -xf -'

# ---------------------------------------------------------------------------
echo "== [4/7] remove legacy manual install (profiles kept) =="
$SSH "$ROUTER" 'cat > /tmp/uninstall-router.sh' < "$REPO/uninstall-router.sh"
if ! $SSH "$ROUTER" 'sh /tmp/uninstall-router.sh' > "$OUT/uninstall.txt" 2>&1; then
	cat "$OUT/uninstall.txt"
	echo "== uninstall FAILED - inspect $OUT/uninstall.txt ==" >&2
	exit 1
fi
cat "$OUT/uninstall.txt"

# ---------------------------------------------------------------------------
echo "== [5/7] install apk packages =="
if ! $SSH "$ROUTER" 'apk add --allow-untrusted /tmp/vpntoggle-*.apk /tmp/luci-app-vpntoggle-*.apk' > "$OUT/apk-add.txt" 2>&1; then
	cat "$OUT/apk-add.txt"
	echo "== apk add FAILED - inspect $OUT/apk-add.txt ==" >&2
	echo "   (legacy files were removed; re-run after fixing, or restore the backup)" >&2
	exit 1
fi
cat "$OUT/apk-add.txt"

# ---------------------------------------------------------------------------
echo "== [6/7] verify =="
$SSH "$ROUTER" sh -s > "$OUT/verify.txt" 2>&1 <<'REMOTE'
echo "-- installed packages --"
apk info -e vpntoggle >/dev/null 2>&1 && echo "vpntoggle: installed" || echo "vpntoggle: MISSING"
apk info -e luci-app-vpntoggle >/dev/null 2>&1 && echo "luci-app-vpntoggle: installed" || echo "luci-app-vpntoggle: MISSING"
echo "-- package-owned files --"
apk info -L vpntoggle 2>/dev/null || true
echo "-- keep.d entry --"
cat /lib/upgrade/keep.d/vpntoggle 2>/dev/null || echo "MISSING keep.d"
echo "-- /etc/sysupgrade.conf --"
cat /etc/sysupgrade.conf 2>/dev/null || true
echo "-- backup list (should be profiles + /etc/config/vpntoggle only) --"
sysupgrade -l | grep -iE 'wireguard|vpntoggle'
echo "-- fw4 vpn zone --"
uci show firewall 2>/dev/null | grep -E 'firewall.vpn|lan_vpn' || echo "NO vpn zone (setup failed)"
echo "-- init.d enabled --"
ls -l /etc/rc.d/*vpntoggle* 2>/dev/null || echo "not enabled"
echo "-- rc.local hook (should be gone) --"
grep -n 'vpn-toggle' /etc/rc.local 2>/dev/null || echo "clean"
echo "-- status --"
vpn-toggle status
echo "-- stale network wgclient section (should be 0 while OFF) --"
uci show network 2>/dev/null | grep -c wgclient || true
REMOTE
cat "$OUT/verify.txt"

# ---------------------------------------------------------------------------
if [ "${TEST:-0}" = 1 ]; then
	echo "== [7/7] functional test: on -> status -> off =="
	if ! $SSH "$ROUTER" 'vpn-toggle on && vpn-toggle status && vpn-toggle off && vpn-toggle status' > "$OUT/test.txt" 2>&1; then
		cat "$OUT/test.txt"
		echo "== TEST FAILED (tunnel left in last state; check manually) ==" >&2
		exit 1
	fi
	cat "$OUT/test.txt"
else
	echo "== [7/7] skipping functional test (set TEST=1 to run on/off) =="
fi

$SSH -O exit "$ROUTER" 2>/dev/null || true

echo
echo "== migration done =="
echo "   log: $OUT"
echo "   Check LuCI: log out/in, then VPN -> VPN Toggle"
