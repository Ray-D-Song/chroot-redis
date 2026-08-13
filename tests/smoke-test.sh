#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: smoke-test.sh <bundle.tar.gz>}"
TEST_ID="${2:-${GITHUB_RUN_ID:-local}-${RANDOM}}"
WORK_DIR="$(mktemp -d /tmp/chroot-redis-test.XXXXXX)"
PREFIX="/opt/chroot-redis-test-$TEST_ID"
DATA_DIR="/var/lib/chroot-redis-test-$TEST_ID"
SERVICE="chroot-redis-test-$TEST_ID"
PORT="$(( 20000 + RANDOM % 20000 ))"
CONF_DIR="/etc/chroot-redis-test-$TEST_ID/conf"
CREDENTIALS="/etc/chroot-redis-test-$TEST_ID/credentials"
PACKAGE_DIR=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
      --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  rm -rf "$PREFIX" "$DATA_DIR" "$(dirname "$CREDENTIALS")" "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
"$PACKAGE_DIR/install.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --port "$PORT" --bind 127.0.0.1
systemctl is-active --quiet "$SERVICE"
[[ "$(grep -c '^# BEGIN chroot-redis managed settings$' "$CONF_DIR/redis.conf")" == 1 ]] || { echo 'managed block is missing or duplicated' >&2; exit 1; }
[[ "$(head -n 1 "$CONF_DIR/redis.conf")" == '# BEGIN chroot-redis managed settings' ]] || { echo 'managed block must come first so operator directives win' >&2; exit 1; }

source "$CREDENTIALS"
redis_cli() {
  chroot "$PREFIX/rootfs" /usr/bin/redis-cli -h 127.0.0.1 -p "$PORT" -a "$REDIS_PASSWORD" --no-auth-warning "$@"
}
wait_for_redis() {
  for _ in $(seq 1 30); do
    if [[ "$(redis_cli ping 2>/dev/null)" == PONG ]]; then return 0; fi
    sleep 1
  done
  echo "Redis did not become ready on port $PORT" >&2
  {
    echo '--- systemctl status ---'
    systemctl status "$SERVICE" --no-pager 2>&1 | head -20
    echo '--- journal ---'
    journalctl -u "$SERVICE" --no-pager -n 30 2>&1
  } >&2
  return 1
}

wait_for_redis
# An unauthenticated client must be rejected: the generated password is the only
# thing standing between the dataset and the network.
unauthenticated="$(chroot "$PREFIX/rootfs" /usr/bin/redis-cli -h 127.0.0.1 -p "$PORT" set ci_smoke nope 2>&1 || true)"
grep -q NOAUTH <<<"$unauthenticated" || { echo "unauthenticated write was not rejected: $unauthenticated" >&2; exit 1; }
redis_cli set ci_smoke ok | grep -Fx OK
redis_cli get ci_smoke | grep -Fx ok
[[ -d "$DATA_DIR/appendonlydir" ]] || { echo 'append-only persistence was not enabled' >&2; exit 1; }

systemctl restart "$SERVICE"
wait_for_redis
redis_cli get ci_smoke | grep -Fx ok

"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -d "$DATA_DIR/appendonlydir" ]] || { echo 'uninstall unexpectedly removed Redis data' >&2; exit 1; }
[[ -f "$CONF_DIR/redis.conf" ]] || { echo 'uninstall unexpectedly removed the configuration' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" && ! -e "$CONF_DIR" ]] || { echo 'purge-data did not remove test data' >&2; exit 1; }
echo 'chroot-redis smoke test passed'
