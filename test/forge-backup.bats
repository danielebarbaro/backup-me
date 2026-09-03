#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../forge-backup.sh"
}

@test "missing config file fails fast with clear message" {
  run env FORGE_BACKUP_CONFIG=/nonexistent/config bash "$SCRIPT" uploads --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}

@test "invalid mode prints usage and exits non-zero" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" bash "$SCRIPT" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  rm -f "$cfg"
}

@test "non-numeric KEEP_FULL fails fast" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\nKEEP_FULL=abc\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" bash "$SCRIPT" full --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"KEEP_FULL"* ]]
  rm -f "$cfg"
}

@test "KEEP_FULL defaults to 14 when unset" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    echo "keep=$KEEP_FULL"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep=14"* ]]
  rm -f "$cfg"
}

@test "prune_full is a no-op when KEEP_FULL is 0" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\nKEEP_FULL=0\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    rclone() { echo "rclone should not run: $*"; }
    DRY_RUN=""
    prune_full "example.com"
    echo "ok"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"rclone should not run"* ]]
  [[ "$output" == *"ok"* ]]
  rm -f "$cfg"
}

@test "prune_full deletes only archives beyond KEEP_FULL, oldest first" {
  cfg="$(mktemp)"
  log="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=%s\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\nKEEP_FULL=2\n' "$log" > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    rclone() {
      case "$1" in
        lsf) printf "2024-03-01.tar.gz\n2024-01-01.tar.gz\n2024-02-01.tar.gz\n2024-04-01.tar.gz\n" ;;
        deletefile) echo "DELETED $2" ;;
      esac
    }
    DRY_RUN=""
    FAILURES=0
    MODE=full
    prune_full "example.com"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DELETED spaces:b/s1/full/example.com/2024-01-01.tar.gz"* ]]
  [[ "$output" == *"DELETED spaces:b/s1/full/example.com/2024-02-01.tar.gz"* ]]
  [[ "$output" != *"2024-03-01.tar.gz"* ]]
  [[ "$output" != *"2024-04-01.tar.gz"* ]]
  rm -f "$cfg" "$log"
}

@test "prune_full deletes nothing in dry-run" {
  cfg="$(mktemp)"
  log="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/tmp\nLOG=%s\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\nKEEP_FULL=1\n' "$log" > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    rclone() {
      case "$1" in
        lsf) printf "2024-01-01.tar.gz\n2024-02-01.tar.gz\n" ;;
        deletefile) echo "DELETED $2" ;;
      esac
    }
    DRY_RUN="--dry-run"
    FAILURES=0
    MODE=full
    prune_full "example.com"
    echo "ok"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DELETED"* ]]
  grep -q "DRY-RUN: prune spaces:b/s1/full/example.com/2024-01-01.tar.gz" "$log"
  rm -f "$cfg" "$log"
}

@test "parse_owner_site splits owner and site" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/home\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    parse_owner_site "/home/alice/example.com/"
    echo "$PS_OWNER|$PS_SITE"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice|example.com"* ]]
  rm -f "$cfg"
}

@test "parse_owner_site keeps nested subdirs in site" {
  cfg="$(mktemp)"
  printf 'REMOTE=spaces\nBUCKET=b\nSERVER_NAME=s1\nSITES_ROOT=/home\nLOG=/tmp/fb.log\nWP_UPLOADS=wp-content/uploads\nJOOMLA_DIRS=(images)\n' > "$cfg"
  run env FORGE_BACKUP_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    parse_owner_site "/home/bob/site.it/blog/"
    echo "$PS_OWNER|$PS_SITE"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bob|site.it/blog"* ]]
  rm -f "$cfg"
}
