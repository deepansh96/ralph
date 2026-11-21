#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

# Default-path tests must not follow a workspaces override from the caller's
# shell, or they could archive (and teardown delete) a real workspace.
unset RALPH_WORKSPACES_DIR RALPH_V2_WORKSPACES_DIR

# Override-path fixtures live under one temp root outside the checkout, removed
# on exit even when an assertion fails; the helpers' own cleanup still runs.
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"; cleanup' EXIT

test_cleanup_archives_workspace_by_issue_number() {
  local issue date destination output

  issue="42"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  mkdir -p "$WORKSPACES_DIR/$issue"
  printf "state\n" > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$CLEANUP_SCRIPT" "$issue")"

  [[ ! -d "$WORKSPACES_DIR/$issue" ]] || fail "expected workspace to be moved"
  [[ -f "$destination/state.json" ]] || fail "expected archived state.json"
  [[ "$(ls -1 "$WORKSPACES_DIR" | grep -x "$issue" || true)" == "" ]] || fail "workspace still listed"
  assert_contains "$output" "$WORKSPACES_DIR/$issue"
  assert_contains "$output" "$destination"
}

test_cleanup_errors_when_workspace_is_missing() {
  local issue output status

  issue="9022"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$CLEANUP_SCRIPT" "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing workspace cleanup to fail"
  assert_contains "$output" "workspace not found"
  assert_contains "$output" "$WORKSPACES_DIR/$issue"
}

test_cleanup_errors_when_archive_destination_exists() {
  local issue date destination output status

  issue="9023"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  mkdir -p "$WORKSPACES_DIR/$issue" "$destination"

  set +e
  output="$("$CLEANUP_SCRIPT" "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected existing archive cleanup to fail"
  [[ -d "$WORKSPACES_DIR/$issue" ]] || fail "expected workspace to remain when archive exists"
  assert_contains "$output" "archive destination already exists"
  assert_contains "$output" "$destination"
}

test_cleanup_validates_issue_number() {
  local output status

  set +e
  output="$("$CLEANUP_SCRIPT" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing cleanup issue to fail"
  assert_contains "$output" "issue number is required"

  set +e
  output="$("$CLEANUP_SCRIPT" "0" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid cleanup issue to fail"
  assert_contains "$output" "issue number must be a positive integer"
}

test_cleanup_removes_empty_workspaces_directory() {
  local issue date destination output test_workspaces

  issue="9024"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  test_workspaces="$(mktemp -d "$FIXTURE_ROOT/isolated.XXXXXX")"
  rm -rf "$destination"
  mkdir -p "$test_workspaces/$issue"
  printf "state\n" > "$test_workspaces/$issue/state.json"

  output="$(RALPH_WORKSPACES_DIR="$test_workspaces" "$CLEANUP_SCRIPT" "$issue")"

  [[ -d "$destination" ]] || fail "expected archived workspace"
  [[ ! -d "$test_workspaces" ]] || fail "expected empty workspaces directory to be removed"
  assert_contains "$output" "$test_workspaces/$issue"
  assert_contains "$output" "$destination"
}

test_cleanup_falls_back_to_legacy_workspaces_dir_env_var() {
  local issue date destination output legacy_workspaces

  issue="9085"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  legacy_workspaces="$(mktemp -d "$FIXTURE_ROOT/legacy.XXXXXX")"
  rm -rf "$destination"
  mkdir -p "$legacy_workspaces/$issue"
  printf "legacy-state\n" > "$legacy_workspaces/$issue/state.json"

  output="$(RALPH_V2_WORKSPACES_DIR="$legacy_workspaces" "$CLEANUP_SCRIPT" "$issue")"

  [[ -d "$destination" ]] || fail "expected archived workspace from RALPH_V2_WORKSPACES_DIR"
  [[ "$(<"$destination/state.json")" == "legacy-state" ]] || fail "expected legacy workspace state.json to be archived"
  [[ ! -d "$legacy_workspaces" ]] || fail "expected empty legacy workspaces directory to be removed"
  assert_contains "$output" "$legacy_workspaces/$issue"
  assert_contains "$output" "$destination"
}

test_cleanup_prefers_ralph_workspaces_dir_over_legacy_env_var() {
  local issue date destination output new_workspaces legacy_workspaces

  issue="9086"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  new_workspaces="$(mktemp -d "$FIXTURE_ROOT/new.XXXXXX")"
  legacy_workspaces="$(mktemp -d "$FIXTURE_ROOT/legacy.XXXXXX")"
  rm -rf "$destination"
  mkdir -p "$new_workspaces/$issue" "$legacy_workspaces/$issue"
  printf "new-state\n" > "$new_workspaces/$issue/state.json"
  printf "legacy-state\n" > "$legacy_workspaces/$issue/state.json"

  output="$(
    RALPH_WORKSPACES_DIR="$new_workspaces" \
      RALPH_V2_WORKSPACES_DIR="$legacy_workspaces" \
      "$CLEANUP_SCRIPT" "$issue"
  )"

  [[ -d "$destination" ]] || fail "expected archived workspace from RALPH_WORKSPACES_DIR"
  [[ "$(<"$destination/state.json")" == "new-state" ]] || fail "expected RALPH_WORKSPACES_DIR to take precedence over RALPH_V2_WORKSPACES_DIR"
  [[ ! -d "$new_workspaces" ]] || fail "expected empty new workspaces directory to be removed"
  [[ -f "$legacy_workspaces/$issue/state.json" ]] || fail "expected legacy workspace to remain untouched"
  assert_contains "$output" "$new_workspaces/$issue"
  assert_contains "$output" "$destination"
}

run_test test_cleanup_archives_workspace_by_issue_number
run_test test_cleanup_errors_when_workspace_is_missing
run_test test_cleanup_errors_when_archive_destination_exists
run_test test_cleanup_validates_issue_number
run_test test_cleanup_removes_empty_workspaces_directory
run_test test_cleanup_falls_back_to_legacy_workspaces_dir_env_var
run_test test_cleanup_prefers_ralph_workspaces_dir_over_legacy_env_var

echo "cleanup_test.sh passed"
