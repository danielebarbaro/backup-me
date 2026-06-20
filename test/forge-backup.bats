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
  [[ "$output" == *"Uso:"* ]]
  rm -f "$cfg"
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
