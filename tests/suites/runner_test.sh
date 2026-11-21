#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_runner_runs_named_suite_only() {
  local output

  output="$("$ROOT_DIR/tests/run.sh" parse_log)"

  assert_contains "$output" "==> parse_log_test.sh"
  assert_contains "$output" "parse_log_test.sh passed"
  [[ "$output" != *"==> cli_test.sh"* ]] || fail "expected named suite run not to execute cli suite"
}

test_runner_errors_for_unknown_suite() {
  local output status

  set +e
  output="$("$ROOT_DIR/tests/run.sh" does_not_exist 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unknown suite to exit 1, got $status"
  assert_contains "$output" "suite not found or not executable"
  assert_contains "$output" "does_not_exist_test.sh"
}

test_legacy_wrapper_delegates_to_runner() {
  local output

  output="$("$ROOT_DIR/tests/test_ralph_v2.sh" parse_log)"

  assert_contains "$output" "==> parse_log_test.sh"
  assert_contains "$output" "parse_log_test.sh passed"
  [[ "$output" != *"==> cli_test.sh"* ]] || fail "expected legacy wrapper named suite run not to execute cli suite"
}

run_test test_runner_runs_named_suite_only
run_test test_runner_errors_for_unknown_suite
run_test test_legacy_wrapper_delegates_to_runner

echo "runner_test.sh passed"
