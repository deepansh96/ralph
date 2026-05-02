#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
TEST_ISSUES=(9001 9002 9003 9004 9005 9006)

cleanup() {
  local issue

  for issue in "${TEST_ISSUES[@]}"; do
    rm -rf "${WORKSPACES_DIR:?}/$issue"
  done
}

trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"actual: $haystack"
}

write_single_step_state() {
  local issue="$1"
  local step_id="$2"
  local status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg id "$step_id" \
    --arg status "$status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: $id,
          type: "stub",
          agent: "stub",
          status: $status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

write_two_step_state() {
  local issue="$1"
  local first_status="$2"
  local second_status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg first_status "$first_status" \
    --arg second_status "$second_status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "first-step",
          type: "stub",
          agent: "stub",
          status: $first_status,
          metrics: { duration: "1s" },
          notes: ""
        },
        {
          id: "second-step",
          type: "stub",
          agent: "stub",
          status: $second_status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

test_issue_must_be_positive_integer() {
  local output status

  set +e
  output="$("$RALPH" --issue nope 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid issue to fail"
  assert_contains "$output" "--issue must be a positive integer"
}

test_run_requires_existing_state() {
  local issue output status

  issue="9001"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing state to fail"
  assert_contains "$output" "state.json not found"
  assert_contains "$output" "run init.md first"
}

test_run_rejects_failed_steps() {
  local issue output status

  issue="9002"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "failed"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected failed step pre-check to fail"
  assert_contains "$output" "failed steps"
  assert_contains "$output" "set status to pending or completed"
}

test_run_completes_pending_stub_step() {
  local issue status_value log_file

  issue="9003"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  "$RALPH" --issue "$issue"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected stub step to be completed, got $status_value"

  log_file="$WORKSPACES_DIR/$issue/logs/stub-step.log"
  [[ -f "$log_file" ]] || fail "expected stub step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "in_progress"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "completed"
}

test_status_prints_step_table() {
  local issue output

  issue="9004"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "in_progress"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "#"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "Type"
  assert_contains "$output" "Agent"
  assert_contains "$output" "Status"
  assert_contains "$output" "Duration"
  assert_contains "$output" "stub-step"
  assert_contains "$output" "stub"
  assert_contains "$output" "in_progress"
}

test_logs_tails_active_step_log() {
  local issue output

  issue="9005"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "active log line\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"
  printf "old log line\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"

  output="$("$RALPH" logs --issue "$issue")"

  assert_contains "$output" "active log line"
  [[ "$output" != *"old log line"* ]] || fail "expected active logs to exclude inactive step log"
}

test_logs_tails_specific_step_log() {
  local issue output

  issue="9006"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "specific completed log\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"
  printf "active log\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"

  output="$("$RALPH" logs --issue "$issue" --step first-step)"

  assert_contains "$output" "specific completed log"
  [[ "$output" != *"active log"* ]] || fail "expected --step logs to exclude active step log"
}

test_issue_must_be_positive_integer
test_run_requires_existing_state
test_run_rejects_failed_steps
test_run_completes_pending_stub_step
test_status_prints_step_table
test_logs_tails_active_step_log
test_logs_tails_specific_step_log

echo "All ralph-v2 tests passed"
