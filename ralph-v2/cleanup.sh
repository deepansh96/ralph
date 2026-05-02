#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage:
  cleanup.sh <issue-number>
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

[[ $# -eq 1 ]] || {
  usage
  die "issue number is required"
}

ISSUE="$1"
is_positive_integer "$ISSUE" || die "issue number must be a positive integer"

WORKSPACE_DIR="$SCRIPT_DIR/workspaces/$ISSUE"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
DATE="$(date +%Y-%m-%d)"
ARCHIVE_DESTINATION="$ARCHIVE_DIR/$DATE-$ISSUE"

[[ -d "$WORKSPACE_DIR" ]] || die "workspace not found: $WORKSPACE_DIR"
[[ ! -e "$ARCHIVE_DESTINATION" ]] || die "archive destination already exists: $ARCHIVE_DESTINATION"

mkdir -p "$ARCHIVE_DIR"
mv "$WORKSPACE_DIR" "$ARCHIVE_DESTINATION"
rmdir "$SCRIPT_DIR/workspaces" 2>/dev/null || true

printf 'Archived workspace\n'
printf '  From: %s\n' "$WORKSPACE_DIR"
printf '  To:   %s\n' "$ARCHIVE_DESTINATION"
