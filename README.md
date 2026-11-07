# vpntoggle — random WireGuard profile toggle for OpenWrt (+ LuCI panel)

Toggles the whole LAN between **direct internet** and a **random WireGuard
profile** (works with Proton VPN configs out of the box), with a LuCI web
panel. Safe by construction: staged bring-up, self-verification and automatic
rollback, plus a boot-time failsafe, so the router can never be locked out.

Developed and tested on OpenWrt 25.12.x (mediatek/filogic, fw4, LuCI ucode
stack, `apk`). The toggle itself is plain POSIX `sh` and works on any modern
OpenWrt with `wireguard-tools` + `kmod-wireguard`.

This repository is an **OpenWrt feed** with two packages:

| Package | Contents |
|---|---|
| `vpntoggle` | `/usr/sbin/vpn-toggle`, `/etc/config/vpntoggle`, `/etc/init.d/vpntoggle` (boot failsafe) |
| `luci-app-vpntoggle` | ACL, menu entry and view page (`VPN → VPN Toggle`) |

---

## Features

- `vpn-toggle on` — picks a **valid** random profile from
  `/etc/wireguard/profiles/*.conf`, applies it to a netifd-managed interface,
  verifies the WireGuard handshake **and** a real data path, then switches LAN
  policy-routing + DNS to the tunnel. Any failure rolls everything back.
- `vpn-toggle off` — clean inverse: removes rules/routes/leak rules, drops the
  tunnel, and **restores the original DNS** that was in place before `on`.
- `vpn-toggle switch` — off then on with a different random profile.
- `vpn-toggle list` — one line per profile (name, endpoint, address, DNS,
  active flag), no secrets. Used by the LuCI server picker.
- `vpn-toggle pick <profile>` — connect to a specific profile (one-off).
- `vpn-toggle info` — machine-readable state for the dashboard.
- `vpn-toggle latency <profile>` — ICMP latency to the profile endpoint.
- `vpn-toggle set killswitch|block_ipv6|mode <value>` — persist a setting.
- `vpn-toggle fetch <name> <url>` — download and validate a config from a URL.
- `vpn-toggle status` — human-readable state, handshake, traffic, rules.
- `vpn-toggle setup` — creates the fw4 `vpn` zone (`lan → vpn` + masquerade)
  and arms the boot failsafe.
- `vpn-toggle reset` — boot-time cleanup of leftovers from a crash while ON.
- LuCI panel (`VPN → VPN Toggle`) — on/off/switch, a **server list with
  latency**, **import by upload / paste / URL**, kill-switch and IPv6 toggles,
  and a live dashboard (profile, endpoint, handshake age, transfer, rule).

### Leak protection

- **Kill switch** (optional, default off): while ON, nftables drops LAN traffic
  that is not going through the tunnel or staying on the LAN.
- **IPv6 leak protection** (default on): the tunnel is IPv4-only, so while ON
  all IPv6 from LAN clients is dropped instead of leaking out `wan6`.

### Why it can't lock you out

1. The tunnel is proven (handshake + data path) **before** LAN routing/DNS are
   touched; failures roll back with the LAN untouched.
2. A router-IP exclusion rule keeps the router's own LAN address on the main
   table, so replies to LAN clients (SSH/LuCI/DNS answers) are never sucked
   into the tunnel.
3. After switching it verifies the policy rule and that dnsmasq actually
   generated `server=...`; on failure it rolls back instead of leaving a
   half-broken state (dead DNS).
4. **Boot failsafe**: `/etc/init.d/vpntoggle` runs `reset` at every boot, so a
   reboot always returns to direct internet. The VPN is never re-enabled
   automatically — important when non-technical people share the router.
5. A lock (`/var/run/vpntoggle/lock`) prevents concurrent toggles from
   corrupting UCI/routes.

## Requirements

- OpenWrt with `wireguard-tools`, `kmod-wireguard`, `dnsmasq`, `nftables`
  (for leak protection) and an `ip` with policy-routing support (`ip-tiny`).
- WireGuard profile files in `/etc/wireguard/profiles/*.conf` (wg-quick
  format: `[Interface] PrivateKey/Address/DNS`, `[Peer] PublicKey/Endpoint`).
  `PresharedKey`, `AllowedIPs`, `PersistentKeepalive` optional; `Key = value`
  spacing and CRLF are handled. (For Proton: download the native WireGuard
  configs — they work as-is.)

## Configuration

`/etc/config/vpntoggle` (uci) overrides built-in defaults; the LAN is
auto-detected from `network.lan` when not pinned:

```sh
uci show vpntoggle
# vpntoggle.main.profiles_dir=/etc/wireguard/profiles
# vpntoggle.main.iface=wgclient
# vpntoggle.main.table=100
# vpntoggle.main.pref=1000
# vpntoggle.main.dns=10.2.0.1
# vpntoggle.main.mode=random
# vpntoggle.main.killswitch=0
# vpntoggle.main.block_ipv6=1
# vpntoggle.main.lan_net=''     # e.g. 192.168.1.0/24 (empty = auto-detect)
# vpntoggle.main.lan_dev=''     # e.g. br-lan       (empty = auto-detect)
```

---

## Install from the package (recommended)

The router runs OpenWrt 25.12.x with `apk`. Build the packages, then install.

### 1. Get the `.apk` files

Download them from the latest
[GitHub release](https://github.com/f0dj/wireguard-toggle/releases)
(assets: `vpntoggle-*.apk` and `luci-app-vpntoggle-*.apk`, plus `SHA256SUMS`),
or build them yourself:

```sh
./build-apk.sh          # downloads the OpenWrt 25.12.5 SDK, builds in Docker
# output: dist/vpntoggle-1.1.0-r3.apk  dist/luci-app-vpntoggle-1.1.0-r3.apk
```

The SDK host tools are glibc binaries, so the build runs in a `debian:bookworm`
container (works on NixOS and other non-FHS hosts). Override the SDK with
`SDK_URL=...`, the build dir with `WORK=...`.

A Nix flake provides every dependency (`docker`, `curl`, `tar`/`zstd`, `git`,
`openssh`), so on NixOS you can do:

```sh
nix develop          # shell with all build + router tooling on PATH
./build-apk.sh
```

The Docker daemon must be running. The flake also ships a NixOS module that
enables it (rootless, so no `docker` group is needed) — import
`nixosModules.default`:

```nix
{
  inputs.vpntoggle.url = "github:f0dj/wireguard-toggle";
  # ...
  modules = [ vpntoggle.nixosModules.default ];
}
```

### 2. Remove any old manual install first

Skip this if the router was never set up the old way. If it has a **manual
(pre-package) install**, migrate once so the package manager owns the files and
the stale `/etc/sysupgrade.conf` entries are gone. `migrate-to-apk.sh` audits the
router, takes a `sysupgrade -b` safety backup, runs the legacy uninstaller
(keeping `/etc/wireguard/profiles`), installs the `.apk`s and verifies:

```sh
./migrate-to-apk.sh root@192.168.1.1
# PULL_BACKUP=1 also copies the backup here; TEST=1 cycles on/off to verify
```

Prefer this over doing it by hand. To remove the legacy files manually instead:

```sh
cat uninstall-router.sh | ssh root@192.168.1.1 sh
# append --purge-profiles to also delete /etc/wireguard/profiles
```

`router-audit.sh [user@host]` is a read-only variant of the same recon if you
only want to inspect the current state (it stores no private keys).

### 3. Install

OpenWrt uses Dropbear, which has no `sftp-server`, so stream the files over `ssh`
(plain `scp` fails):

```sh
tar -C dist -cf - *.apk | ssh root@192.168.1.1 'tar -C /tmp -xf -'
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/vpntoggle-*.apk /tmp/luci-app-vpntoggle-*.apk'
```

Then log out/in of LuCI and open **VPN → VPN Toggle**.

### Building as a feed in a full OpenWrt tree

```sh
# feeds.conf: add
src-git vpntoggle https://github.com/f0dj/wireguard-toggle.git

./scripts/feeds update -a
./scripts/feeds install -a -p vpntoggle
make package/vpntoggle/compile package/luci-app-vpntoggle/compile V=s
```

---

## Tests

```sh
sh tests/test-vpn-toggle.sh
```

Hermetic offline tests (stub `uci`/`wg`/`ip`/`nft`/`ping`) covering on/off/
switch, pinned vs random mode, invalid-profile handling, path-traversal
rejection, settings and argument handling.

## Security notes

- Runtime state lives in `/var/run/vpntoggle` (root-only `0700`), avoiding
  symlink attacks on world-writable `/tmp`.
- DNS is **backed up and restored**, not clobbered, and the backup is kept in
  `/etc/vpntoggle/state` so a reboot while ON restores the original upstreams.
- `pick`/`validate` reject paths outside the profiles directory and unsafe
  names; random selection skips unparseable profiles.
- The LuCI ACL is scoped to the exact `vpn-toggle` command lines and
  `/etc/wireguard/profiles/*` writes; it does not grant `cgi-io`.
- Profiles should be `0600` in a `0700` directory (the package sets this on
  install; the LuCI upload uses mode `0600`).

> The ACL gives the LuCI admin session shell execution of those commands —
> appropriate for an admin-only router (root can already do anything over
> SSH). For strict least privilege, wrap the actions in a dedicated rpcd ucode
> object instead.

## Existing OpenWrt software you may prefer

- **`pbr` / `luci-app-pbr`** — the mature, in-feed Policy Based Routing
  package. It routes LAN clients through WireGuard/OpenVPN interfaces with
  per-source/per-domain policy and DNS policy. It does **not** do random
  multi-profile switching. If you only need "send the LAN through one tunnel",
  use PBR.
- **`luci-app-mihomo` / `luci-app-passwall` / `luci-app-openclash`** — the
  "easy router" node-picker UX (server lists, latency, subscriptions). They are
  proxy-oriented, from community feeds, and heavier than this use case.
- **`luci-proto-wireguard`** — WireGuard interface/status management, no
  one-click LAN toggle.

No existing package combines one-click LAN toggle + random WireGuard profile
selection + Proton-style configs, which is why this exists.

## Backup / sysupgrade

Only **user data** belongs in the backup. The package ships
`/lib/upgrade/keep.d/vpntoggle`, which preserves `/etc/wireguard/` (your
profiles); `/etc/config/vpntoggle` is a conffile and is also covered by the base
`/etc/config/` keep rule. Package files are restored by reinstalling the
package. Archives contain the private keys — store them as safely as the router
itself.

## Repository layout

```
wireguard-toggle/
├── LICENSE                    Apache-2.0 (full text; covers the whole repo)
├── NOTICE                     copyright/attribution + relicensing history
├── build-apk.sh               build the .apk packages via the OpenWrt SDK
├── migrate-to-apk.sh          migrate a legacy manual install to the packages
├── router-audit.sh            read-only audit of a router's vpntoggle state
├── uninstall-router.sh        remove a legacy manual install (used by migrate)
├── flake.nix, flake.lock      Nix dev shell + NixOS module (Docker)
├── tests/test-vpn-toggle.sh   hermetic offline tests
├── vpntoggle/                 feed package: script + uci config + init.d
│   ├── Makefile
│   ├── LICENSE
│   └── files/
│       ├── etc/config/vpntoggle
│       ├── etc/init.d/vpntoggle
│       └── usr/sbin/vpn-toggle
├── luci-app-vpntoggle/        feed package: LuCI panel
│   ├── Makefile
│   ├── LICENSE
│   └── root/                  mirrors target paths (acl.d, menu.d, /www)
└── dist/                      built .apk files (gitignored)
```

## Known limitations

- **IPv6 is not tunneled**: profiles may carry `AllowedIPs ::/0`, but there is
  no v6 address or v6 policy routing on the tunnel. While ON, LAN v6 is dropped
  (leak protection); it is not carried through the VPN.
- Router-originated traffic (updates, NTP, LuCI) stays on the direct WAN; only
  LAN clients are routed through the tunnel.
- The whole LAN is toggled at once (no per-host policy; use PBR for that).
- WAN/modem DHCP flapping during a toggle is upstream interference; a down WAN
  simply makes `on` time out and roll back safely.

## Troubleshooting cheatsheet

- **Locked out after a toggle?** Power-cycle: the boot failsafe restores clean
  OFF.
- **DNS dead after `on`** — dnsmasq only emits upstreams from `list server`
  entries; the script verifies the generated `/tmp/etc/dnsmasq.conf.*` contains
  `server=...`, rolling back otherwise.
- **"Permission denied" on the LuCI buttons** — ACL must list the exact
  command lines; re-login after changing ACLs.
- Run `./router-audit.sh [user@host]` against the router and include the dump
  when reporting issues.

## License

Both packages are Apache-2.0; the full text is in `LICENSE` at the repository
root and is also shipped as `vpntoggle/LICENSE` and
`luci-app-vpntoggle/LICENSE`. `NOTICE` carries the attribution notice that
Apache-2.0 requires redistributors to propagate. Apache-2.0 allows private,
commercial and closed-source use, requires attribution to be kept, and grants
an explicit patent license. Builds through v1.1.0-r2 were released under
GPL-2.0; that grant stands for those copies, and everything later is
Apache-2.0.
