#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-redis
DATA_DIR=/var/lib/chroot-redis/data
CONF_DIR=/etc/chroot-redis/conf
CREDENTIALS=/etc/chroot-redis/credentials
SERVICE_NAME=chroot-redis
RUN_USER=chroot-redis
PORT=6379
BIND_ADDRESS='0.0.0.0'
PASSWORD_CLI=''

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --prefix PATH             Rootfs install directory (default: $PREFIX)
  --data-dir PATH           Persistent database directory (default: $DATA_DIR)
  --conf-dir PATH           Persistent configuration directory (default: $CONF_DIR)
  --port PORT               Redis port (default: $PORT)
  --bind ADDRESSES          Redis bind addresses (default: $BIND_ADDRESS)
  --service-name NAME       systemd service name (default: $SERVICE_NAME)
  --credentials-file PATH   Root-only credentials file (default: $CREDENTIALS)
  --password VALUE          requirepass for a new instance (or set CHROOT_REDIS_PASSWORD)
EOF
}

validate_password() {
  local pw="$1"
  [[ -n "$pw" ]] || { echo 'password must not be empty' >&2; exit 2; }
  (( ${#pw} >= 8 )) || { echo 'password must be at least 8 characters' >&2; exit 2; }
  [[ "${pw//$'\n'}" == "$pw" ]] || { echo 'password must not contain newline' >&2; exit 2; }
  [[ "${pw//$'\0'}" == "$pw" ]] || { echo 'password must not contain null bytes' >&2; exit 2; }
  [[ ! "$pw" =~ [[:cntrl:]] ]] || { echo 'password must not contain control characters' >&2; exit 2; }
}

password_was_provided() {
  [[ -n "$PASSWORD_CLI" || -n "${CHROOT_REDIS_PASSWORD:-}" ]]
}

warn_if_password_ignored() {
  if password_was_provided; then
    echo 'Warning: existing data directory detected; --password and CHROOT_REDIS_PASSWORD were ignored.' >&2
  fi
}

resolve_password_for_new_install() {
  if [[ -n "$PASSWORD_CLI" ]]; then
    password="$PASSWORD_CLI"
    echo "Using password from --password. It will be stored in $CREDENTIALS (root only)."
  elif [[ -n "${CHROOT_REDIS_PASSWORD:-}" ]]; then
    password="$CHROOT_REDIS_PASSWORD"
    echo "Using password from CHROOT_REDIS_PASSWORD. It will be stored in $CREDENTIALS (root only)."
  else
    password="$(openssl rand -hex 32)"
    echo "Generated Redis password. It is stored in $CREDENTIALS (root only)."
  fi
  validate_password "$password"
}

read_credentials_password() {
  password="$(awk -F= '$1 == "REDIS_PASSWORD" { print substr($0, index($0, "=") + 1) }' "$CREDENTIALS")"
  [[ -n "$password" ]] || { echo "credentials file has no REDIS_PASSWORD: $CREDENTIALS" >&2; exit 1; }
}

format_requirepass() {
  local pw="$1"
  if [[ "$pw" =~ [[:space:]#\\\"] ]]; then
    local escaped="${pw//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '"%s"' "$escaped"
  else
    printf '%s' "$pw"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--conf-dir|--port|--bind|--service-name|--credentials-file|--password)
      key="$1"; shift; [[ $# -gt 0 ]] || { echo "missing value for $key" >&2; exit 2; }
      case "$key" in
        --prefix) PREFIX="$1" ;;
        --data-dir) DATA_DIR="$1" ;;
        --conf-dir) CONF_DIR="$1" ;;
        --port) PORT="$1" ;;
        --bind) BIND_ADDRESS="$1" ;;
        --service-name) SERVICE_NAME="$1" ;;
        --credentials-file) CREDENTIALS="$1" ;;
        --password) PASSWORD_CLI="$1" ;;
      esac
      shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'run install.sh with sudo or as root' >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo 'chroot-redis supports Linux amd64 only' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo 'port must be 1..65535' >&2; exit 2; }
bind_pattern='^[a-zA-Z0-9.:_ -]+$'
[[ "$BIND_ADDRESS" =~ $bind_pattern ]] || { echo 'invalid bind addresses' >&2; exit 2; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo 'invalid service name' >&2; exit 2; }
[[ "$PREFIX" == /* && "$PREFIX" != / && "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || { echo 'prefix and data-dir must be non-root absolute paths' >&2; exit 2; }
[[ "$CONF_DIR" == /* && "$CONF_DIR" != / ]] || { echo 'conf-dir must be a non-root absolute path' >&2; exit 2; }
[[ "$CREDENTIALS" == /* && "$CREDENTIALS" != / ]] || { echo 'credentials-file must be a non-root absolute path' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOTFS="$SCRIPT_DIR/rootfs"
[[ -x "$SOURCE_ROOTFS/usr/bin/redis-server" ]] || { echo "rootfs is missing from $SOURCE_ROOTFS" >&2; exit 1; }

if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$RUN_USER"
fi
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"

ensure_chroot_identity() {
  local rootfs="$1"
  if ! awk -F: -v gid="$RUN_GID" '$3 == gid { found=1 } END { exit !found }' "$rootfs/etc/group"; then
    printf '%s:x:%s:\n' "$RUN_USER" "$RUN_GID" >> "$rootfs/etc/group"
  fi
  if ! awk -F: -v uid="$RUN_UID" '$3 == uid { found=1 } END { exit !found }' "$rootfs/etc/passwd"; then
    printf '%s:x:%s:%s:chroot-redis runtime:/nonexistent:/usr/sbin/nologin\n' \
      "$RUN_USER" "$RUN_UID" "$RUN_GID" >> "$rootfs/etc/passwd"
  fi
}

if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl stop "$SERVICE_NAME"; fi
mkdir -p "$PREFIX" "$DATA_DIR" "$CONF_DIR" "$(dirname "$CREDENTIALS")"
chmod 0750 "$(dirname "$CREDENTIALS")"
chown "$RUN_UID:$RUN_GID" "$DATA_DIR" "$CONF_DIR"
chmod 0750 "$DATA_DIR" "$CONF_DIR"

new_rootfs="$PREFIX/rootfs.new"
rm -rf "$new_rootfs"
cp -a "$SOURCE_ROOTFS" "$new_rootfs"
if [[ -d "$PREFIX/rootfs" ]]; then rm -rf "$PREFIX/rootfs"; fi
mv "$new_rootfs" "$PREFIX/rootfs"
install -D -m 0755 "$SCRIPT_DIR/bin/chroot-redis-run" "$PREFIX/bin/chroot-redis-run"
ensure_chroot_identity "$PREFIX/rootfs"

# Redis never rewrites an existing dataset password, so reuse the one from a
# previous install instead of locking the operator out of their own data.
data_has_state=false
if [[ -e "$DATA_DIR/dump.rdb" || -e "$DATA_DIR/appendonlydir" ]]; then data_has_state=true; fi
if [[ "$data_has_state" == true ]]; then
  [[ -f "$CREDENTIALS" ]] || { echo "existing data directory requires credentials file: $CREDENTIALS" >&2; exit 1; }
  read_credentials_password
  warn_if_password_ignored
elif [[ -f "$CREDENTIALS" ]]; then
  read_credentials_password
  warn_if_password_ignored
else
  resolve_password_for_new_install
fi
requirepass_line="requirepass $(format_requirepass "$password")"
install -m 0600 /dev/null "$CREDENTIALS"
cat > "$CREDENTIALS" <<EOF
REDIS_PASSWORD=$password
REDIS_PORT=$PORT
EOF

MANAGED_BEGIN='# BEGIN chroot-redis managed settings'
MANAGED_END='# END chroot-redis managed settings'
# Redis applies the last occurrence of a directive, so the managed block goes
# first: everything an operator adds below it overrides the defaults we ship,
# and a reinstall refreshes the block instead of stacking duplicates.
write_managed_block() {
  local target="$1" tmp
  tmp="$(mktemp)"
  { printf '%s\n' "$MANAGED_BEGIN"; cat; printf '%s\n' "$MANAGED_END"; } > "$tmp"
  if [[ -f "$target" ]]; then
    awk -v head="$MANAGED_BEGIN" -v tail="$MANAGED_END" '
      $0 == head { inside = 1; next }
      $0 == tail { inside = 0; next }
      inside == 0 { print }
    ' "$target" >> "$tmp"
  else
    cat >> "$tmp" <<'HINT'

# Add custom directives below this line. They are kept across reinstalls and
# override the managed block above. The annotated upstream reference lives in
# the rootfs at /usr/share/redis/redis.conf.reference.
HINT
  fi
  cat "$tmp" > "$target"
  rm -f "$tmp"
  chown "$RUN_UID:$RUN_GID" "$target"
  chmod 0600 "$target"
}

write_managed_block "$CONF_DIR/redis.conf" <<EOF
bind $BIND_ADDRESS
port $PORT
protected-mode yes
$requirepass_line
dir /var/lib/redis
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
daemonize no
supervised no
logfile ""
EOF

sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@CONF_DIR@|$CONF_DIR|g" \
  -e "s|@RUN_UID@|$RUN_UID|g" -e "s|@RUN_GID@|$RUN_GID|g" \
  "$SCRIPT_DIR/systemd/chroot-redis.service.in" > "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Installed $SERVICE_NAME. Check: systemctl status $SERVICE_NAME"
