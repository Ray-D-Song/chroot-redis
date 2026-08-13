#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ROOTFS="$BUILD_DIR/rootfs"

[[ "$(uname -m)" == "x86_64" ]] || { echo 'only amd64 hosts are supported' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'run build-rootfs.sh with sudo' >&2; exit 1; }
command -v debootstrap >/dev/null || { echo 'debootstrap is required' >&2; exit 1; }

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
debootstrap --arch=amd64 --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

# A minbase rootfs has no CA bundle. Install it from the Debian mirror before
# adding the HTTPS-only Redis repository, otherwise apt cannot verify it.
chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates
  rm -rf /var/lib/apt/lists/* /var/cache/apt/*
'

install -d -m 0755 "$ROOTFS/usr/share/keyrings"
curl -fsSL "$REDIS_APT_KEY" | gpg --dearmor > "$ROOTFS/usr/share/keyrings/redis-archive-keyring.gpg"
chmod 0644 "$ROOTFS/usr/share/keyrings/redis-archive-keyring.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/redis.list" <<EOF
deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] $REDIS_APT_REPOSITORY $DEBIAN_SUITE main
EOF

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends redis-server="'"$REDIS_PACKAGE_VERSION"'" redis-tools="'"$REDIS_PACKAGE_VERSION"'"
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
  rm -rf /var/lib/redis/* /var/log/redis/*
  rm -f /usr/sbin/policy-rc.d /etc/machine-id
'

actual_server="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' redis-server)"
actual_tools="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' redis-tools)"
[[ "$actual_server" == "$REDIS_PACKAGE_VERSION" ]] || { echo "Redis server version mismatch: $actual_server" >&2; exit 1; }
[[ "$actual_tools" == "$REDIS_PACKAGE_VERSION" ]] || { echo "Redis tools version mismatch: $actual_tools" >&2; exit 1; }
cat > "$ROOTFS/etc/chroot-redis-build.env" <<EOF
REDIS_PACKAGE_VERSION=$actual_server
EOF
# The packaged /etc/redis/redis.conf is hidden by the bind mount that carries
# the host configuration directory. Keep a copy operators can still read as the
# annotated upstream reference.
install -D -m 0644 "$ROOTFS/etc/redis/redis.conf" "$ROOTFS/usr/share/redis/redis.conf.reference"
install -d -m 0755 "$ROOTFS/etc/redis" "$ROOTFS/var/lib/redis"
echo "rootfs ready: $ROOTFS"
