#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DASHBOARD="$ROOT_DIR/dashboard/dashboard.sh"
SERVER_PID=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

trap cleanup EXIT

assert_jq_equals() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual

  actual="$(jq -r "$filter" <<<"$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected; got $actual"
}

write_workspace_state() {
  local workspaces_dir="$1"
  local issue="$2"

  mkdir -p "$workspaces_dir/$issue"
  jq -n \
    --argjson issue "$issue" \
    '{
      issue: $issue,
      repo: "deepansh96/ralph",
      branch: "feat/dashboard",
      createdAt: "2026-05-02T12:00:00Z",
      steps: [
        {
          id: "serve-step",
          type: "implement-slice",
          agent: "codex",
          status: "in_progress",
          metrics: {
            duration_ms: 83000,
            cost_usd: 0.21
          }
        }
      ]
    }' > "$workspaces_dir/$issue/state.json"
}

start_server() {
  local port="$1"
  local workspaces_dir="$2"
  local log_file="$3"

  "$DASHBOARD" serve --port "$port" --workspaces-dir "$workspaces_dir" > "$log_file" 2>&1 &
  SERVER_PID="$!"

  for _ in {1..50}; do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  fail "server did not start; log: $(cat "$log_file" 2>/dev/null || true)"
}

test_api_serves_configured_workspace_data() {
  local tmp_dir port log_file response

  tmp_dir="$(mktemp -d)"
  port="19081"
  log_file="$tmp_dir/server.log"
  write_workspace_state "$tmp_dir/workspaces" 19

  start_server "$port" "$tmp_dir/workspaces" "$log_file"
  response="$(curl -fsS "http://127.0.0.1:$port/api/workspaces")"

  assert_jq_equals "$response" '.workspaces | length' "1"
  assert_jq_equals "$response" '.workspaces[0].issue' "19"
  assert_jq_equals "$response" '.workspaces[0].currentStep' "serve-step"
  grep -q "Dashboard: http://127.0.0.1:$port" "$log_file" || fail "startup URL was not printed"

  cleanup
  rm -rf "$tmp_dir"
}

test_static_file_server_rejects_path_traversal() {
  local tmp_dir port log_file plain_status encoded_status

  tmp_dir="$(mktemp -d)"
  port="19082"
  log_file="$tmp_dir/server.log"

  start_server "$port" "$tmp_dir/workspaces" "$log_file"
  plain_status="$(curl --path-as-is -o /dev/null -s -w "%{http_code}" "http://127.0.0.1:$port/../../etc/passwd")"
  encoded_status="$(curl --path-as-is -o /dev/null -s -w "%{http_code}" "http://127.0.0.1:$port/%2e%2e%2f%2e%2e%2fetc/passwd")"

  [[ "$plain_status" == "403" || "$plain_status" == "404" ]] || fail "expected traversal request to be rejected; got $plain_status"
  [[ "$encoded_status" == "403" || "$encoded_status" == "404" ]] || fail "expected encoded traversal request to be rejected; got $encoded_status"

  cleanup
  rm -rf "$tmp_dir"
}

test_api_reports_aggregate_failure_as_json() {
  local tmp_dir port log_file response_body status

  tmp_dir="$(mktemp -d)"
  port="19083"
  log_file="$tmp_dir/server.log"
  response_body="$tmp_dir/response.json"
  printf 'not a directory\n' > "$tmp_dir/not-a-directory"

  start_server "$port" "$tmp_dir/not-a-directory" "$log_file"
  status="$(curl -o "$response_body" -s -w "%{http_code}" "http://127.0.0.1:$port/api/workspaces")"

  [[ "$status" == "500" ]] || fail "expected aggregate failure to return HTTP 500; got $status with $(cat "$response_body")"
  assert_jq_equals "$(cat "$response_body")" '.error' "aggregate failed"

  cleanup
  rm -rf "$tmp_dir"
}

test_server_validates_jq_at_startup() {
  local tmp_dir fake_bin python_path output status

  tmp_dir="$(mktemp -d)"
  fake_bin="$tmp_dir/bin"
  mkdir -p "$fake_bin"
  python_path="$(command -v python3)"
  ln -s "$python_path" "$fake_bin/python3"

  set +e
  output="$(PATH="$fake_bin" /bin/bash "$DASHBOARD" serve --port 19084 --workspaces-dir "$tmp_dir/workspaces" 2>&1)"
  status="$?"
  set -e

  [[ "$status" != "0" ]] || fail "expected serve to fail when jq is missing"
  [[ "$output" == *"jq is required"* ]] || fail "expected missing jq message; got $output"

  rm -rf "$tmp_dir"
}

test_frontend_static_assets_expose_pipeline_table() {
  local tmp_dir port log_file html css

  tmp_dir="$(mktemp -d)"
  port="19085"
  log_file="$tmp_dir/server.log"

  start_server "$port" "$tmp_dir/workspaces" "$log_file"
  html="$(curl -fsS "http://127.0.0.1:$port/")"
  css="$(curl -fsS "http://127.0.0.1:$port/style.css")"

  [[ "$html" == *"Pipeline Dashboard"* ]] || fail "expected Pipeline Dashboard heading"
  [[ "$html" == *"Refresh"* ]] || fail "expected refresh button"
  [[ "$html" == *"Issue #"* ]] || fail "expected issue column"
  [[ "$html" == *"Current Step"* ]] || fail "expected current Step column"
  [[ "$html" == *"Steps Progress"* ]] || fail "expected Steps Progress column"
  [[ "$html" == *"formatDuration"* ]] || fail "expected duration formatter"
  [[ "$html" == *"formatCost"* ]] || fail "expected cost formatter"
  [[ "$html" != *"Loop"* && "$html" != *"Iteration"* ]] || fail "frontend must not use Loop or Iteration labels"
  [[ "$css" == *"status-completed"* && "$css" == *"status-in_progress"* && "$css" == *"status-blocked"* && "$css" == *"status-failed"* && "$css" == *"status-pending"* ]] || fail "expected status color classes"
  [[ "$css" == *"step-segment"* ]] || fail "expected compact Step progress segment styles"

  cleanup
  rm -rf "$tmp_dir"
}

test_api_serves_configured_workspace_data
test_static_file_server_rejects_path_traversal
test_api_reports_aggregate_failure_as_json
test_server_validates_jq_at_startup
test_frontend_static_assets_expose_pipeline_table

echo "dashboard serve tests passed"
