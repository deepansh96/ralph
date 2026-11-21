#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

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
  test_workspaces="$(mktemp -d "${WORKSPACES_DIR}.isolated.XXXXXX")"
  rm -rf "$destination"
  mkdir -p "$test_workspaces/$issue"
  printf "state\n" > "$test_workspaces/$issue/state.json"

  output="$(RALPH_WORKSPACES_DIR="$test_workspaces" "$CLEANUP_SCRIPT" "$issue")"

  [[ -d "$destination" ]] || fail "expected archived workspace"
  [[ ! -d "$test_workspaces" ]] || fail "expected empty workspaces directory to be removed"
  assert_contains "$output" "$test_workspaces/$issue"
  assert_contains "$output" "$destination"
}

run_test test_cleanup_archives_workspace_by_issue_number
run_test test_cleanup_errors_when_workspace_is_missing
run_test test_cleanup_errors_when_archive_destination_exists
run_test test_cleanup_validates_issue_number
run_test test_cleanup_removes_empty_workspaces_directory

echo "cleanup_test.sh passed"
