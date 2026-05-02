#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DASHBOARD="$ROOT_DIR/dashboard/dashboard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_jq_equals() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual

  actual="$(jq -r "$filter" <<<"$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected; got $actual"
}

assert_jq_true() {
  local json="$1"
  local filter="$2"

  jq -e "$filter" <<<"$json" >/dev/null || fail "expected jq filter to pass: $filter"$'\n'"actual: $json"
}

run_aggregate() {
  local workspaces_dir="$1"

  "$DASHBOARD" aggregate --workspaces-dir "$workspaces_dir"
}

write_workspace_state() {
  local workspaces_dir="$1"
  local issue="$2"
  local state_json="$3"

  mkdir -p "$workspaces_dir/$issue"
  printf '%s\n' "$state_json" > "$workspaces_dir/$issue/state.json"
}

test_zero_workspaces() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces | length' "0"
  assert_jq_equals "$output" '.warnings | length' "0"

  rm -rf "$tmp_dir"
}

test_completed_workspace() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 7 '{
    "issue": 7,
    "repo": "deepansh96/ralph",
    "branch": "feat/completed",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {
        "id": "first-step",
        "type": "review-decisions",
        "agent": "claude",
        "status": "completed",
        "metrics": {
          "duration_ms": 1000,
          "cost_usd": 0.25
        }
      },
      {
        "id": "second-step",
        "type": "create-prd",
        "agent": "codex",
        "status": "completed",
        "metrics": {
          "duration_ms": 2500,
          "cost_usd": 0.75
        }
      }
    ]
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.warnings | length' "0"
  assert_jq_equals "$output" '.workspaces | length' "1"
  assert_jq_equals "$output" '.workspaces[0].issue' "7"
  assert_jq_equals "$output" '.workspaces[0].repo' "deepansh96/ralph"
  assert_jq_equals "$output" '.workspaces[0].branch' "feat/completed"
  assert_jq_equals "$output" '.workspaces[0].createdAt' "2026-05-02T12:00:00Z"
  assert_jq_equals "$output" '.workspaces[0].derivedStatus' "completed"
  assert_jq_equals "$output" '.workspaces[0].currentStep' "second-step"
  assert_jq_equals "$output" '.workspaces[0].totalDuration_ms' "3500"
  assert_jq_equals "$output" '.workspaces[0].totalCost_usd' "1"
  assert_jq_equals "$output" '.workspaces[0].stepCounts.completed' "2"
  assert_jq_equals "$output" '.workspaces[0].stepCounts.pending' "0"
  assert_jq_equals "$output" '.workspaces[0].steps[0].id' "first-step"
  assert_jq_equals "$output" '.workspaces[0].steps[0].duration_ms' "1000"
  assert_jq_equals "$output" '.workspaces[0].steps[0].cost_usd' "0.25"

  rm -rf "$tmp_dir"
}

test_mixed_workspaces_are_sorted_and_prioritized() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 30 '{
    "issue": 30,
    "repo": "deepansh96/ralph",
    "branch": "feat/thirty",
    "createdAt": "2026-05-02T12:30:00Z",
    "steps": [
      {"id": "done", "type": "fixed", "agent": "claude", "status": "completed", "metrics": {"duration_ms": 10, "cost_usd": 0.1}},
      {"id": "active", "type": "dynamic", "agent": "codex", "status": "in_progress", "metrics": {"duration_ms": 20, "cost_usd": 0.2}}
    ]
  }'
  write_workspace_state "$tmp_dir" 10 '{
    "issue": 10,
    "repo": "deepansh96/ralph",
    "branch": "feat/ten",
    "createdAt": "2026-05-02T12:10:00Z",
    "steps": [
      {"id": "done", "type": "fixed", "agent": "claude", "status": "completed", "metrics": {"duration_ms": 10, "cost_usd": 0.1}},
      {"id": "next", "type": "dynamic", "agent": "codex", "status": "pending", "metrics": {"duration_ms": null, "cost_usd": null}}
    ]
  }'
  write_workspace_state "$tmp_dir" 20 '{
    "issue": 20,
    "repo": "deepansh96/ralph",
    "branch": "feat/twenty",
    "createdAt": "2026-05-02T12:20:00Z",
    "steps": [
      {"id": "bad", "type": "fixed", "agent": "claude", "status": "failed", "metrics": {"duration_ms": 1, "cost_usd": 0.01}},
      {"id": "blocked-later", "type": "dynamic", "agent": "codex", "status": "blocked", "metrics": {"duration_ms": 2, "cost_usd": 0.02}}
    ]
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces | map(.issue) | join(",")' "10,20,30"
  assert_jq_equals "$output" '.workspaces[0].derivedStatus' "pending"
  assert_jq_equals "$output" '.workspaces[0].currentStep' "next"
  assert_jq_equals "$output" '.workspaces[1].derivedStatus' "failed"
  assert_jq_equals "$output" '.workspaces[1].currentStep' "bad"
  assert_jq_equals "$output" '.workspaces[2].derivedStatus' "in_progress"
  assert_jq_equals "$output" '.workspaces[2].currentStep' "active"

  rm -rf "$tmp_dir"
}

test_invalid_files_are_skipped_with_warnings() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 1 '{
    "issue": 1,
    "repo": "deepansh96/ralph",
    "branch": "feat/valid",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "only", "type": "fixed", "agent": "codex", "status": "pending", "metrics": null}
    ]
  }'
  mkdir -p "$tmp_dir/broken" "$tmp_dir/no-steps" "$tmp_dir/bad-issue"
  printf '{not-json' > "$tmp_dir/broken/state.json"
  printf '{"issue":2}' > "$tmp_dir/no-steps/state.json"
  printf '{"issue":"3","steps":[]}' > "$tmp_dir/bad-issue/state.json"

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces | length' "1"
  assert_jq_equals "$output" '.workspaces[0].issue' "1"
  assert_jq_equals "$output" '.warnings | length' "3"
  assert_jq_true "$output" '.warnings[] | select(contains("broken/state.json: invalid JSON"))'
  assert_jq_true "$output" '.warnings[] | select(contains("no-steps/state.json: .steps must be an array"))'
  assert_jq_true "$output" '.warnings[] | select(contains("bad-issue/state.json: .issue must be numeric"))'

  rm -rf "$tmp_dir"
}

test_invalid_step_status_is_skipped_with_warning() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 3 '{
    "issue": 3,
    "repo": "deepansh96/ralph",
    "branch": "feat/bad-status",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "mystery", "type": "fixed", "agent": "codex", "status": "waiting", "metrics": null}
    ]
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces | length' "0"
  assert_jq_equals "$output" '.warnings | length' "1"
  assert_jq_true "$output" '.warnings[] | select(contains("step status must be one of pending, in_progress, completed, blocked, failed"))'

  rm -rf "$tmp_dir"
}

test_missing_metrics_produce_zero_duration_and_null_cost() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 44 '{
    "issue": 44,
    "repo": "deepansh96/ralph",
    "branch": "feat/missing-metrics",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "without-metrics", "type": "fixed", "agent": "claude", "status": "pending"},
      {"id": "null-metrics", "type": "dynamic", "agent": "codex", "status": "pending", "metrics": null}
    ]
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces[0].totalDuration_ms' "0"
  assert_jq_equals "$output" '.workspaces[0].totalCost_usd == null' "true"
  assert_jq_equals "$output" '.workspaces[0].steps[0].duration_ms' "0"
  assert_jq_equals "$output" '.workspaces[0].steps[0].cost_usd == null' "true"

  rm -rf "$tmp_dir"
}

test_blocked_step_is_current_when_no_failed_step_exists() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 45 '{
    "issue": 45,
    "repo": "deepansh96/ralph",
    "branch": "feat/blocked",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "done", "type": "fixed", "agent": "claude", "status": "completed", "metrics": null},
      {"id": "needs-input", "type": "dynamic", "agent": "codex", "status": "blocked", "metrics": null},
      {"id": "active-later", "type": "dynamic", "agent": "codex", "status": "in_progress", "metrics": null}
    ]
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces[0].derivedStatus' "blocked"
  assert_jq_equals "$output" '.workspaces[0].currentStep' "needs-input"
  assert_jq_equals "$output" '.workspaces[0].stepCounts.blocked' "1"
  assert_jq_equals "$output" '.workspaces[0].stepCounts.in_progress' "1"

  rm -rf "$tmp_dir"
}

test_environment_workspaces_dir_is_used_without_flag() {
  local env_dir output

  env_dir="$(mktemp -d)"
  write_workspace_state "$env_dir" 49 '{
    "issue": 49,
    "repo": "deepansh96/ralph",
    "branch": "feat/env-only",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "env-step", "type": "fixed", "agent": "claude", "status": "pending", "metrics": null}
    ]
  }'

  output="$(RALPH_WORKSPACES_DIR="$env_dir" "$DASHBOARD" aggregate)"

  assert_jq_equals "$output" '.workspaces | length' "1"
  assert_jq_equals "$output" '.workspaces[0].issue' "49"

  rm -rf "$env_dir"
}

test_workspaces_dir_flag_precedes_environment() {
  local env_dir flag_dir output

  env_dir="$(mktemp -d)"
  flag_dir="$(mktemp -d)"
  write_workspace_state "$env_dir" 50 '{
    "issue": 50,
    "repo": "deepansh96/ralph",
    "branch": "feat/env",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "env-step", "type": "fixed", "agent": "claude", "status": "pending", "metrics": null}
    ]
  }'
  write_workspace_state "$flag_dir" 51 '{
    "issue": 51,
    "repo": "deepansh96/ralph",
    "branch": "feat/flag",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": [
      {"id": "flag-step", "type": "fixed", "agent": "codex", "status": "pending", "metrics": null}
    ]
  }'

  output="$(RALPH_WORKSPACES_DIR="$env_dir" "$DASHBOARD" aggregate --workspaces-dir "$flag_dir")"

  assert_jq_equals "$output" '.workspaces | length' "1"
  assert_jq_equals "$output" '.workspaces[0].issue' "51"

  rm -rf "$env_dir" "$flag_dir"
}

test_empty_steps_derives_pending_not_completed() {
  local tmp_dir output

  tmp_dir="$(mktemp -d)"
  write_workspace_state "$tmp_dir" 99 '{
    "issue": 99,
    "repo": "deepansh96/ralph",
    "branch": "feat/empty-steps",
    "createdAt": "2026-05-02T12:00:00Z",
    "steps": []
  }'

  output="$(run_aggregate "$tmp_dir")"

  assert_jq_equals "$output" '.workspaces | length' "1"
  assert_jq_equals "$output" '.workspaces[0].derivedStatus' "pending"
  assert_jq_equals "$output" '.workspaces[0].currentStep' "null"
  assert_jq_equals "$output" '.workspaces[0].totalDuration_ms' "0"

  rm -rf "$tmp_dir"
}

test_zero_workspaces
test_completed_workspace
test_mixed_workspaces_are_sorted_and_prioritized
test_invalid_files_are_skipped_with_warnings
test_invalid_step_status_is_skipped_with_warning
test_missing_metrics_produce_zero_duration_and_null_cost
test_blocked_step_is_current_when_no_failed_step_exists
test_empty_steps_derives_pending_not_completed
test_environment_workspaces_dir_is_used_without_flag
test_workspaces_dir_flag_precedes_environment

echo "dashboard aggregate tests passed"
