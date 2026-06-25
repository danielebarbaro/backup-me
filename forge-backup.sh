#!/usr/bin/env bash
#
# forge-backup.sh — auto-discovery backup of WordPress + Joomla to DigitalOcean Spaces.
#
# Modes:
#   uploads  -> incremental sync of media dirs only (rclone copy)
#   full     -> dated .tar.gz of the whole site, streamed (no local disk)
#
# Databases are NOT touched. Forge handles them.
#
# Usage:
#   forge-backup uploads
#   forge-backup full
#   forge-backup uploads --dry-run
#
set -uo pipefail

# --- Load config -----------------------------------------------------------
CONFIG="${FORGE_BACKUP_CONFIG:-/etc/forge-backup/config}"
if [ ! -r "$CONFIG" ]; then
  echo "forge-backup: config not found or unreadable: $CONFIG" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# Validate required values.
for var in REMOTE BUCKET SERVER_NAME SITES_ROOT LOG WP_UPLOADS; do
  if [ -z "${!var:-}" ]; then
    echo "forge-backup: missing required config value: $var (in $CONFIG)" >&2
    exit 1
  fi
done

# Default tar excludes (regenerable junk). Override in config if needed.
if [ -z "${TAR_EXCLUDES+x}" ]; then
  TAR_EXCLUDES=(
    "--exclude=wp-content/cache"
    "--exclude=wp-content/uploads/cache"
    "--exclude=*/cache"
    "--exclude=administrator/cache"
    "--exclude=tmp"
    "--exclude=node_modules"
    "--exclude=.git"
    "--exclude=*.log"
  )
fi

# Default Joomla media dirs. Override in config if needed.
if [ -z "${JOOMLA_DIRS+x}" ]; then
  JOOMLA_DIRS=("images" "media" "attachments")
fi

RCLONE_FLAGS=(--transfers 4 --checkers 8 --log-file "$LOG" --log-level INFO)

log() { echo "$(date '+%F %T') [${MODE:-?}] $*" >> "$LOG"; }

# Given /home/<owner>/<domain>/<...>/ set PS_OWNER and PS_SITE.
parse_owner_site() {
  local rel="${1#"$SITES_ROOT"/}"
  rel="${rel%/}"
  PS_OWNER="${rel%%/*}"
  PS_SITE="${rel#*/}"
}

# Incremental sync of one media dir -> Spaces.
sync_uploads() {
  local owner="$1" site="$2" src="$3" label="$4"
  [ ! -d "$src" ] && return
  log "uploads $owner/$site/$label <- $src"
  # shellcheck disable=SC2086
  rclone copy "$src" \
    "${REMOTE}:${BUCKET}/${SERVER_NAME}/uploads/${site}/${label}/" \
    "${RCLONE_FLAGS[@]}" $DRY_RUN
  local rc=$?
  [ $rc -ne 0 ] && { log "ERROR: uploads failed for $owner/$site/$label (rc=$rc)"; FAILURES=$((FAILURES+1)); }
}

# Dated tar.gz of a whole site, streamed straight to Spaces.
archive_full() {
  local owner="$1" site="$2" dir="$3"
  local dest="${REMOTE}:${BUCKET}/${SERVER_NAME}/full/${site}/${DATE}.tar.gz"
  log "full $owner/$site -> $dest"
  if [ -n "$DRY_RUN" ]; then
    log "DRY-RUN: tar czf - -C $dir . | rclone rcat $dest"
    return
  fi
  # shellcheck disable=SC2094
  tar czf - "${TAR_EXCLUDES[@]}" -C "$dir" . 2>>"$LOG" \
    | rclone rcat "$dest" --log-file "$LOG" --log-level INFO
  local rc=$?
  [ $rc -ne 0 ] && { log "ERROR: archive failed for $site (rc=$rc)"; FAILURES=$((FAILURES+1)); }
}

# Allow tests to source functions without running a backup.
[ -n "${SOURCED_ONLY:-}" ] && return 0

# --- Main ------------------------------------------------------------------
MODE="${1:-}"
DRY_RUN=""
[ "${2:-}" = "--dry-run" ] && DRY_RUN="--dry-run"

if [ "$MODE" != "uploads" ] && [ "$MODE" != "full" ]; then
  echo "Usage: $0 {uploads|full} [--dry-run]" >&2
  exit 1
fi

DATE="$(date +%F)"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
if ! { : >> "$LOG"; } 2>/dev/null; then
  echo "forge-backup: log file not writable: $LOG" >&2
  exit 1
fi

FAILURES=0
log "=== START (server=$SERVER_NAME${DRY_RUN:+ DRY-RUN}) ==="

if [ "$MODE" = "full" ]; then
  for dir in "$SITES_ROOT"/*/*/; do
    find "$dir" -maxdepth 4 \( -name '.?*' -o -name node_modules -o -name vendor \) -prune -o \
      -type f \( -name wp-config.php -o -name configuration.php \) -print -quit 2>/dev/null \
      | grep -q . || continue
    parse_owner_site "$dir"
    archive_full "$PS_OWNER" "$PS_SITE" "${dir%/}"
  done
else
  while IFS= read -r marker; do
    root="$(dirname "$marker")/"
    parse_owner_site "$root"
    if [ "$(basename "$marker")" = "wp-config.php" ]; then
      sync_uploads "$PS_OWNER" "$PS_SITE" "${root}${WP_UPLOADS}" "uploads"
    else
      for sub in "${JOOMLA_DIRS[@]}"; do
        sync_uploads "$PS_OWNER" "$PS_SITE" "${root}${sub}" "$sub"
      done
    fi
  done < <(
    find "$SITES_ROOT" -maxdepth 5 \
      \( -name '.?*' -o -name node_modules -o -name vendor \) -prune -o \
      -type f \( -name wp-config.php -o -name configuration.php \) -print 2>/dev/null
  )
fi

log "=== DONE ==="

if [ "$FAILURES" -gt 0 ]; then
  log "=== FAILED: $FAILURES error(s) ==="
  exit 1
fi
