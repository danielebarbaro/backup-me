#!/usr/bin/env bash
#
# forge-backup installer. Run on each Forge server:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/forge-backup/main/install.sh | bash
#
set -uo pipefail

REPO_RAW="${FORGE_BACKUP_REPO_RAW:-https://raw.githubusercontent.com/<owner>/forge-backup/main}"
BIN="/usr/local/bin/forge-backup"
CONFIG_DIR="/etc/forge-backup"
CONFIG="$CONFIG_DIR/config"
CRON="/etc/cron.d/forge-backup"

say()  { printf '\n>> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root or with sudo (writes to /etc and /usr/local/bin)."; }

need_root

# 1. Dependency check.
say "Checking dependencies"
command -v tar  >/dev/null || die "tar not found."
command -v find >/dev/null || die "find not found."
if ! command -v rclone >/dev/null; then
  read -r -p "rclone not found. Install it now via the official script? [y/N] " ans
  [ "$ans" = "y" ] || die "rclone is required. Install it and re-run."
  curl -fsSL https://rclone.org/install.sh | bash || die "rclone install failed."
fi

# 2. Prompt for config.
say "Configuration"
read -r -p "SERVER_NAME (unique, e.g. server-1): " SERVER_NAME
[ -n "$SERVER_NAME" ] || die "SERVER_NAME is required."
read -r -p "Spaces bucket name: " BUCKET
[ -n "$BUCKET" ] || die "Bucket is required."
read -r -p "Spaces endpoint (e.g. fra1.digitaloceanspaces.com): " ENDPOINT
[ -n "$ENDPOINT" ] || die "Endpoint is required."
read -r -p "Spaces access key: " ACCESS_KEY
[ -n "$ACCESS_KEY" ] || die "Access key is required."
read -r -s -p "Spaces secret key: " SECRET_KEY; echo
[ -n "$SECRET_KEY" ] || die "Secret key is required."
read -r -p "User that runs backups [forge]: " RUN_USER_INPUT
RUN_USER="${RUN_USER_INPUT:-forge}"
id "$RUN_USER" >/dev/null 2>&1 || die "User '$RUN_USER' does not exist on this server."
# shellcheck disable=SC2086,SC2116
RUN_HOME="$(eval echo "~$RUN_USER")"
RCLONE_CONF="$RUN_HOME/.config/rclone/rclone.conf"
LOG_PATH="$RUN_HOME/forge-backup.log"

# 3. Write rclone.conf for the run user.
say "Writing rclone config to $RCLONE_CONF"
install -d -m 700 -o "$RUN_USER" "$(dirname "$RCLONE_CONF")"
umask 177
cat > "$RCLONE_CONF" <<EOF
[spaces]
type = s3
provider = DigitalOcean
access_key_id = $ACCESS_KEY
secret_access_key = $SECRET_KEY
endpoint = $ENDPOINT
acl = private
EOF
umask 022
chown "$RUN_USER":"$RUN_USER" "$RCLONE_CONF"
chmod 600 "$RCLONE_CONF"

# 4. Write /etc/forge-backup/config.
say "Writing $CONFIG"
install -d -m 755 "$CONFIG_DIR"
umask 177
cat > "$CONFIG" <<EOF
REMOTE="spaces"
BUCKET="$BUCKET"
SERVER_NAME="$SERVER_NAME"
SITES_ROOT="/home"
LOG="$LOG_PATH"
WP_UPLOADS="wp-content/uploads"
JOOMLA_DIRS=("images" "media" "attachments")
EOF
umask 022
chmod 600 "$CONFIG"
chown "$RUN_USER":"$RUN_USER" "$CONFIG"

# 5. Install the script.
say "Installing $BIN"
curl -fsSL "$REPO_RAW/forge-backup.sh" -o "$BIN" || die "Failed to download forge-backup.sh"
chmod 755 "$BIN"

# 6. Install cron (replaced in place, never duplicated).
say "Installing cron at $CRON"
cat > "$CRON" <<EOF
# forge-backup. Managed by install.sh. uploads daily 02:30, full weekly Sun 03:30.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
30 2 * * *   $RUN_USER  forge-backup uploads >> $LOG_PATH 2>&1
30 3 * * 0   $RUN_USER  forge-backup full    >> $LOG_PATH 2>&1
EOF
chmod 644 "$CRON"

# 7. Verify with a dry-run.
say "Verifying (dry-run)"
if sudo -u "$RUN_USER" forge-backup uploads --dry-run; then
  say "Install complete. Cron scheduled. Review $CRON to change timing."
else
  die "Dry-run failed. Check $CONFIG and $RCLONE_CONF."
fi
