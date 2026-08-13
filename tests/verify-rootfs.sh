#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs.sh <rootfs>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"

[[ -x "$ROOTFS/usr/bin/redis-server" ]]
[[ -x "$ROOTFS/usr/bin/redis-cli" ]]
[[ -f "$ROOTFS/usr/share/redis/redis.conf.reference" ]]
actual="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' redis-server)"
[[ "$actual" == "$REDIS_PACKAGE_VERSION" ]] || { echo "expected $REDIS_PACKAGE_VERSION, got $actual" >&2; exit 1; }
# The Debian epoch and revision are stripped from the upstream version string,
# so compare against the numeric release embedded in `v=8.10.0`.
upstream="${REDIS_PACKAGE_VERSION#*:}"
upstream="${upstream%%-*}"
chroot "$ROOTFS" /usr/bin/redis-server --version | grep -Fq "v=$upstream"
echo 'rootfs verification passed'
