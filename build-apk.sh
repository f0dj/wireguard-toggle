#!/bin/sh
# build-apk.sh - build vpntoggle + luci-app-vpntoggle .apk packages with the
# OpenWrt SDK, inside a Debian container (the SDK's host tools are glibc
# binaries and will not run natively on NixOS).
#
# Usage:  ./build-apk.sh
# Env:    SDK_URL  override the SDK tarball URL
#         WORK     override the build directory (default: ./.build)
# Output: ./dist/*.apk
#
# Requires: docker, curl, tar with zstd support.

set -e

REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-"$REPO/.build"}
DIST="$REPO/dist"
SDK_URL=${SDK_URL:-https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst}

mkdir -p "$WORK" "$DIST"

# Docker: on NixOS (and other userns/rootless setups) the daemon socket is
# per-user, not /var/run/docker.sock. `nix develop` exports DOCKER_HOST, but
# this script must also work outside the dev shell, so point docker at the
# rootless socket when DOCKER_HOST is unset.
if [ -z "${DOCKER_HOST:-}" ]; then
	for sock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" \
	            "/run/user/$(id -u)/docker.sock"; do
		if [ -S "$sock" ]; then
			DOCKER_HOST="unix://$sock"
			export DOCKER_HOST
			break
		fi
	done
fi
if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: docker client not found. On NixOS run this via 'nix develop'." >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "ERROR: cannot reach the Docker daemon (DOCKER_HOST=${DOCKER_HOST:-<unset>})." >&2
	echo "  - 'nix develop' exports DOCKER_HOST for rootless docker." >&2
	echo "  - or: export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock" >&2
	echo "  - ensure the daemon is enabled (flake nixosModules / your NixOS config)." >&2
	exit 1
fi
echo "== [0/5] docker: ${DOCKER_HOST:-<default>} =="

echo "== [1/5] fetch SDK =="
TARBALL="$WORK/sdk.tar.zst"
if [ ! -f "$TARBALL" ]; then
	curl -fL --retry 3 -o "$TARBALL.part" "$SDK_URL"
	mv "$TARBALL.part" "$TARBALL"
else
	echo "  cached: $TARBALL"
fi

echo "== [2/5] extract SDK =="
SDK="$WORK/sdk"
if [ ! -d "$SDK" ]; then
	mkdir -p "$SDK"
	tar --zstd -xf "$TARBALL" -C "$SDK" --strip-components=1
else
	echo "  cached: $SDK"
fi

echo "== [3/5] stage packages into the SDK tree =="
rm -rf "$SDK/package/vpntoggle" "$SDK/package/luci-app-vpntoggle"
cp -r "$REPO/vpntoggle" "$SDK/package/vpntoggle"
cp -r "$REPO/luci-app-vpntoggle" "$SDK/package/luci-app-vpntoggle"

echo "== [4/5] build in debian:bookworm (docker) =="
# stage into a host-owned dir; the container runs as an unmapped uid, so we
# copy the artefacts out on the host afterwards to get sane ownership.
OUT="$WORK/out"
rm -rf "$OUT"
mkdir -p "$OUT"
rm -f "$DIST"/*.apk 2>/dev/null || true
docker run --rm \
	-v "$SDK":/sdk \
	-v "$OUT":/out \
	-w /sdk \
	debian:bookworm bash -lc '
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends \
			build-essential bc bzip2 ca-certificates file gawk gettext git \
			libelf-dev libncurses-dev libssl-dev zlib1g-dev patch perl \
			python3 python3-distutils rsync subversion unzip wget xz-utils \
			zstd >/dev/null
		make defconfig >/dev/null
		make package/vpntoggle/clean package/luci-app-vpntoggle/clean >/dev/null 2>&1 || true
		make package/vpntoggle/compile package/luci-app-vpntoggle/compile V=s
		# the SDK ships a full package repository under bin/packages; copy
		# only the two packages we built
		find bin/packages -name "vpntoggle-*.apk" -exec cp -v {} /out/ \;
		find bin/packages -name "luci-app-vpntoggle-*.apk" -exec cp -v {} /out/ \;
	'
cp "$OUT"/*.apk "$DIST"/

echo "== [5/5] done =="
ls -l "$DIST"/*.apk
echo
echo "Install on the router:"
echo "  ./migrate-to-apk.sh root@192.168.1.1        # migrate a legacy manual install"
echo "  # fresh install:"
echo "  tar -C $DIST -cf - *.apk | ssh root@192.168.1.1 'tar -C /tmp -xf -'"
echo "  ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/vpntoggle-*.apk /tmp/luci-app-vpntoggle-*.apk'"
