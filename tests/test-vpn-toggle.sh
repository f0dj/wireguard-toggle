#!/bin/sh
# test-vpn-toggle.sh - offline functional tests for /usr/sbin/vpn-toggle.
#
# Builds a sandbox copy of the script in a temp dir (absolute paths such as
# /etc/config/vpntoggle, /tmp, /var/run/vpntoggle, /etc/vpntoggle/state and
# /etc/init.d/dnsmasq are rewritten into the sandbox) and provides stub
# uci/wg/ip/nft/ping/ifup/ifdown binaries, so the full on/off/switch cycle
# runs hermetically against fake WireGuard profiles.
#
# Usage: sh tests/test-vpn-toggle.sh
# Exit code 0 = all tests passed.

set -u

# --- locate the script under test ---
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=${SRC:-"$HERE/../vpntoggle/files/usr/sbin/vpn-toggle"}
[ -f "$SRC" ] || { echo "cannot find $SRC" >&2; exit 1; }

pass=0
fail=0

ok() { pass=$((pass+1)); echo "ok  - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; [ $# -ge 2 ] && echo "       $2"; }

expect_rc() { # want_rc got_rc label
    if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3" "rc=$2 want=$1"; fi
}

expect_out() { # needle output label   (fixed-string match)
    if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3" "output missing: [$1]"; fi
}

expect_nout() { # needle output label
    if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3" "output should NOT contain: [$1]"; else ok "$3"; fi
}

# --- build the sandbox -----------------------------------------------------
SB=$(mktemp -d /tmp/vpn-toggle-test.XXXXXX) || exit 1
trap 'rm -rf "$SB"' EXIT INT TERM
mkdir -p "$SB/bin" "$SB/profiles" "$SB/etc/config" "$SB/tmp/etc" "$SB/run" "$SB/persist"

# sandbox copy of the script with router-absolute paths redirected
# NOTE: the generic /tmp/ rewrite must come first, otherwise it re-substitutes
# the sandbox base path ($SB itself lives under /tmp).
sed -e "s#/tmp/#$SB/tmp/#g" \
    -e "s#/etc/config/vpntoggle#$SB/etc/config/vpntoggle#g" \
    -e "s#/var/run/vpntoggle#$SB/run/vpntoggle#g" \
    -e "s#/etc/vpntoggle/state#$SB/persist#g" \
    -e "s#/etc/init.d/dnsmasq#$SB/bin/dnsmasq-restart#g" \
    "$SRC" > "$SB/vpn-toggle"
chmod +x "$SB/vpn-toggle"
SUT="$SB/vpn-toggle"
printf "config vpntoggle 'main'\n" > "$SB/etc/config/vpntoggle"

# uci stub: options live in $UCI_STORE as  pkg.section.option=value
# (scalar) or pkg.section.option+=value (list member, append order).
cat > "$SB/bin/uci" <<'EOF'
#!/bin/sh
store=${UCI_STORE:?}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        *) break ;;
    esac
done
[ "$#" -ge 1 ] || exit 1
cmd=$1
shift
case "$cmd" in
    get)
        key=$1 out=
        while IFS= read -r line; do
            case "$line" in
                "$key="*|"$key+"*) out=${line#*=}; break ;;
            esac
        done < "$store"
        if [ -n "$out" ]; then printf '%s\n' "$out"; exit 0; fi
        exit 1
        ;;
    set)
        kv=$1 key=${kv%%=*} val=${kv#*=}
        tmp=$store.tmp.$$
        grep -vF -e "$key=" -e "$key+=" "$store" > "$tmp" 2>/dev/null
        printf '%s=%s\n' "$key" "$val" >> "$tmp"
        mv "$tmp" "$store"
        exit 0
        ;;
    add_list)
        kv=$1 key=${kv%%=*} val=${kv#*=}
        printf '%s+=%s\n' "$key" "$val" >> "$store"
        exit 0
        ;;
    delete)
        key=$1
        tmp=$store.tmp.$$
        awk -v k="$key" '
            index($0, k) == 1 {
                r = substr($0, length(k) + 1, 1)
                if (r == "" || r == "=" || r == "+" || r == ".") next
            }
            { print }
        ' "$store" > "$tmp"
        mv "$tmp" "$store"
        exit 0
        ;;
    commit) exit 0 ;;
esac
exit 1
EOF

cat > "$SB/bin/wg" <<'EOF'
#!/bin/sh
# stub: pretend a healthy, recently-handshaken tunnel
if [ "$1" = show ] && [ "$3" = latest-handshakes ]; then
    echo "$2 $(( $(date +%s) - 5 ))"
    exit 0
fi
if [ "$1" = show ] && [ "$3" = endpoints ]; then
    echo "$2 1.2.3.4:51820"
    exit 0
fi
if [ "$1" = show ] && [ "$3" = transfer ]; then
    echo "$2 1000 2000"
    exit 0
fi
printf 'interface: %s\n  public key: xyz\n  listening port: 51820\npeer: peer\n  endpoint: 1.2.3.4:51820\n  allowed ips: 0.0.0.0/0\n  latest handshake: 1 second ago\n  transfer: 1.0 KiB received, 1.0 KiB sent\n' "${2:-wgclient}"
exit 0
EOF

cat > "$SB/bin/ip" <<'EOF'
#!/bin/sh
# stub: wgclient always exists, policy rules always present, no LAN addr
case "$1" in
    link) echo "3: wgclient: <POINTOPOINT,UP,LOWER_UP> mtu 1420" ;;
    rule)
        if [ "$2" = show ]; then
            printf '1001:\tfrom 192.168.1.1 lookup 254\n1000:\tfrom 192.168.1.0/24 lookup 100\n'
        fi
        ;;
    addr|route) ;;
    *) exit 0 ;;
esac
exit 0
EOF

cat > "$SB/bin/nft" <<'EOF'
#!/bin/sh
# stub: accept every nftables operation
exit 0
EOF

for s in ping ifup ifdown dnsmasq-restart; do
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/$s"
    chmod +x "$SB/bin/$s"
done
chmod +x "$SB/bin/uci" "$SB/bin/wg" "$SB/bin/ip" "$SB/bin/nft"

# dnsmasq "generated config" the script greps for after a DNS switchover
echo 'server=10.2.0.1' > "$SB/tmp/etc/dnsmasq.conf.1"

# uci store: point profiles_dir into the sandbox
export UCI_STORE="$SB/uci-store"
printf 'vpntoggle.main.profiles_dir=%s\n' "$SB/profiles" > "$UCI_STORE"
export PATH="$SB/bin:$PATH"

# --- seed fake profiles ----------------------------------------------------
cat > "$SB/profiles/alpha.conf" <<'EOF'
[Interface]
PrivateKey = aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.2.0.2
DNS = 10.2.0.1

[Peer]
PublicKey = pAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Endpoint = 95.100.1.1:51820
EOF

cat > "$SB/profiles/beta.conf" <<'EOF'
[Interface]
PrivateKey = bBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Address = 10.2.0.3
DNS = 10.2.0.1

[Peer]
PublicKey = pBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 95.100.1.2:51820
EOF

# deliberately broken: missing PrivateKey
cat > "$SB/profiles/gamma.conf" <<'EOF'
[Interface]
Address = 10.2.0.4

[Peer]
PublicKey = pCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
Endpoint = 95.100.1.3:51820
EOF

tab=$(printf '\t')

# --- tests -----------------------------------------------------------------
echo "== syntax =="
sh -n "$SRC" && ok "sh -n syntax" || bad "sh -n syntax"

echo "== initial state =="
out=$("$SUT" status 2>&1); rc=$?
expect_rc 0 $rc "status rc"
expect_out "State: OFF (3 profiles available)" "$out" "status reports OFF + 3 profiles"
expect_out "Mode: random" "$out" "default mode is random"

out=$("$SUT" info 2>&1); rc=$?
expect_rc 0 $rc "info rc"
expect_out "state=OFF" "$out" "info reports state=OFF"
expect_out "block_ipv6=1" "$out" "info reports IPv6 protection on by default"

out=$("$SUT" list 2>&1); rc=$?
expect_rc 0 $rc "list rc"
expect_out "alpha.conf${tab}95.100.1.1:51820${tab}10.2.0.2${tab}10.2.0.1${tab}0" "$out" "list: alpha row"
expect_out "beta.conf${tab}95.100.1.2:51820${tab}10.2.0.3${tab}10.2.0.1${tab}0" "$out" "list: beta row"
expect_out "gamma.conf${tab}INVALID${tab}-${tab}-${tab}0" "$out" "list: broken profile flagged INVALID"

echo "== pin / unpin =="
out=$("$SUT" pin alpha.conf 2>&1); rc=$?
expect_rc 0 $rc "pin alpha rc"
expect_out "pinned: alpha.conf" "$out" "pin reports profile"
grep -qF 'vpntoggle.main.mode=pinned' "$UCI_STORE" && ok "store: mode=pinned" || bad "store: mode=pinned"
grep -qF 'vpntoggle.main.pinned=alpha.conf' "$UCI_STORE" && ok "store: pinned=alpha.conf" || bad "store: pinned=alpha.conf"

out=$("$SUT" status 2>&1); rc=$?
expect_rc 0 $rc "status rc after pin"
expect_out "Mode: pinned (profile: alpha.conf)" "$out" "status shows pinned mode"

echo "== on uses pinned profile =="
out=$("$SUT" on 2>&1); rc=$?
expect_rc 0 $rc "on (pinned) rc"
active=$(cat "$SB/run/vpntoggle/active" 2>/dev/null)
[ "$active" = "$SB/profiles/alpha.conf" ] && ok "on activated alpha.conf" || bad "on activated alpha.conf" "active=$active"

out=$("$SUT" list 2>&1); rc=$?
expect_rc 0 $rc "list rc while on"
expect_out "alpha.conf${tab}95.100.1.1:51820${tab}10.2.0.2${tab}10.2.0.1${tab}1" "$out" "list: alpha active=1"
expect_out "beta.conf${tab}95.100.1.2:51820${tab}10.2.0.3${tab}10.2.0.1${tab}0" "$out" "list: beta active=0"

echo "== pick overrides pinned (one-off) =="
out=$("$SUT" pick beta 2>&1); rc=$?   # name without .conf suffix
expect_rc 0 $rc "pick beta rc"
active=$(cat "$SB/run/vpntoggle/active" 2>/dev/null)
[ "$active" = "$SB/profiles/beta.conf" ] && ok "pick activated beta.conf" || bad "pick activated beta.conf" "active=$active"

out=$("$SUT" on 2>&1); rc=$?
expect_rc 0 $rc "on (still pinned) rc"
active=$(cat "$SB/run/vpntoggle/active" 2>/dev/null)
[ "$active" = "$SB/profiles/alpha.conf" ] && ok "on went back to pinned alpha.conf" || bad "on went back to pinned alpha.conf" "active=$active"

echo "== unpin returns to random =="
out=$("$SUT" unpin 2>&1); rc=$?
expect_rc 0 $rc "unpin rc"
expect_out "mode=random" "$out" "unpin reports random"
grep -qF 'vpntoggle.main.mode=random' "$UCI_STORE" && ok "store: mode=random" || bad "store: mode=random"

out=$("$SUT" status 2>&1)
expect_out "Mode: random" "$out" "status shows random again"

echo "== switch excludes the active profile (random mode) =="
out=$("$SUT" switch 2>&1); rc=$?
expect_rc 0 $rc "switch rc (alpha active)"
active=$(cat "$SB/run/vpntoggle/active" 2>/dev/null)
[ "$active" = "$SB/profiles/beta.conf" ] && ok "switch moved to beta.conf" || bad "switch moved to beta.conf" "active=$active"

out=$("$SUT" switch 2>&1); rc=$?
expect_rc 0 $rc "switch rc (beta active)"
active=$(cat "$SB/run/vpntoggle/active" 2>/dev/null)
[ "$active" = "$SB/profiles/alpha.conf" ] && ok "switch moved to alpha.conf" || bad "switch moved to alpha.conf" "active=$active"

echo "== settings (killswitch / ipv6) =="
out=$("$SUT" set killswitch 1 2>&1); rc=$?
expect_rc 0 $rc "set killswitch rc"
expect_out "set killswitch=1" "$out" "set killswitch reports"
grep -qF 'vpntoggle.main.killswitch=1' "$UCI_STORE" && ok "store: killswitch=1" || bad "store: killswitch=1"
out=$("$SUT" set block_ipv6 0 2>&1); rc=$?
expect_rc 0 $rc "set block_ipv6 rc"
out=$("$SUT" info 2>&1)
expect_out "killswitch=1" "$out" "info reflects killswitch"
expect_out "block_ipv6=0" "$out" "info reflects block_ipv6"

echo "== switch with a single profile fails cleanly =="
rm "$SB/profiles/beta.conf" "$SB/profiles/gamma.conf"
out=$("$SUT" switch 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "switch rc != 0 with one profile" || bad "switch rc != 0 with one profile" "rc=$rc"
expect_out "only profile available is alpha.conf" "$out" "switch explains single-profile case"
[ ! -f "$SB/run/vpntoggle/active" ] && ok "switch failure left tunnel OFF" || bad "switch failure left tunnel OFF"

echo "== off =="
out=$("$SUT" on 2>&1); rc=$?
expect_rc 0 $rc "on rc (single profile)"
out=$("$SUT" off 2>&1); rc=$?
expect_rc 0 $rc "off rc"
[ ! -f "$SB/run/vpntoggle/active" ] && ok "off removed active marker" || bad "off removed active marker"

echo "== on with no profiles at all =="
mv "$SB/profiles/alpha.conf" "$SB/profiles/alpha.conf.bak"
out=$("$SUT" on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "on rc != 0 with zero profiles" || bad "on rc != 0 with zero profiles" "rc=$rc"
expect_out "no *.conf in" "$out" "on reports empty profile dir"
mv "$SB/profiles/alpha.conf.bak" "$SB/profiles/alpha.conf"

echo "== pinned profile deleted -> loud refusal =="
out=$("$SUT" pin alpha.conf 2>&1); rc=$?
expect_rc 0 $rc "pin alpha rc (again)"
mv "$SB/profiles/alpha.conf" "$SB/profiles/alpha.conf.bak"
out=$("$SUT" on 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "pinned-missing on rc != 0" || bad "pinned-missing on rc != 0" "rc=$rc"
expect_out "pinned profile not found" "$out" "on refuses when pinned profile is gone"
mv "$SB/profiles/alpha.conf.bak" "$SB/profiles/alpha.conf"

echo "== validate =="
out=$("$SUT" validate alpha.conf 2>&1); rc=$?
expect_rc 0 $rc "validate alpha rc"
expect_out "OK: $SB/profiles/alpha.conf" "$out" "validate reports OK"
expect_out "95.100.1.1:51820" "$out" "validate shows endpoint"

# a broken profile (missing PrivateKey); gamma was removed by an earlier test
cat > "$SB/profiles/broken.conf" <<'EOF'
[Interface]
Address = 10.2.0.9

[Peer]
PublicKey = pZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ=
Endpoint = 95.100.1.9:51820
EOF
out=$("$SUT" validate broken.conf 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "validate broken rc != 0" || bad "validate broken rc != 0" "rc=$rc"
expect_out "missing keys" "$out" "validate explains broken profile"

out=$("$SUT" validate nosuch.conf 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "validate missing rc != 0" || bad "validate missing rc != 0" "rc=$rc"
expect_out "profile not found" "$out" "validate reports unknown profile"

echo "== path traversal is rejected =="
out=$("$SUT" validate /etc/passwd 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "validate /etc/passwd rc != 0" || bad "validate /etc/passwd rc != 0" "rc=$rc"
expect_out "outside" "$out" "validate rejects paths outside the profiles dir"
out=$("$SUT" pick '../alpha' 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "pick ../alpha rc != 0" || bad "pick ../alpha rc != 0" "rc=$rc"

echo "== pick / pin argument handling =="
out=$("$SUT" pick 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "pick without name rc != 0" || bad "pick without name rc != 0" "rc=$rc"
expect_out "no profile name given" "$out" "pick without name explains usage"

out=$("$SUT" pin nosuch.conf 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "pin unknown profile rc != 0" || bad "pin unknown profile rc != 0" "rc=$rc"

out=$("$SUT" badcmd 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "unknown command rc != 0" || bad "unknown command rc != 0" "rc=$rc"
expect_out "usage:" "$out" "usage line on unknown command"

echo
echo "== results: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
