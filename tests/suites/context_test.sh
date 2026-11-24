#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_run_hard_stops_when_context_missing() {
  local issue output status status_value

  issue="9013"
  remove_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  assert_contains "$output" "CONTEXT.md not found"
  assert_contains "$output" "$CONTEXT_FILE"
}

test_run_hard_stops_when_context_is_insufficient() {
  local issue output status status_value fake_bin log_file

  issue="9014"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_insufficient_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_context_check_claude "$fake_bin"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected insufficient CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  log_file="$WORKSPACES_DIR/$issue/logs/check-context.log"
  [[ -f "$log_file" ]] || fail "expected context check log file"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

test_context_check_passes_when_jsonl_result_contains_pass() {
  local issue output status

  issue="9034"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    local step="$1"
    local prompt="$2"
    local log_file="$3"

    printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}' > "$log_file"
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
      duration_ms: 100,
      usage: {
        input_tokens: 1,
        output_tokens: 1
      },
      total_cost_usd: 0.01
    }' >> "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected JSONL CONTEXT_CHECK PASS to return 0; output: $output"
}

test_context_check_fails_when_jsonl_result_contains_fail() {
  local issue output status

  issue="9035"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    local step="$1"
    local prompt="$2"
    local log_file="$3"

    jq -n -c '{
      type: "assistant",
      message: "CONTEXT_CHECK: PASS from a non-result stream event"
    }' > "$log_file"
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "CONTEXT_CHECK: FAIL\nMissing required sections.",
      duration_ms: 100,
      usage: {
        input_tokens: 1,
        output_tokens: 1
      },
      total_cost_usd: 0.01
    }' >> "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected JSONL CONTEXT_CHECK FAIL result to return 1; status: $status output: $output"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

test_context_check_falls_back_to_plain_text_pass() {
  local issue output status

  issue="9036"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    local step="$1"
    local prompt="$2"
    local log_file="$3"

    cat > "$log_file" <<'LOG'
CONTEXT_CHECK: PASS
CONTEXT.md follows the required format.
LOG
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected plain-text CONTEXT_CHECK PASS fallback to return 0; output: $output"
}

test_context_check_inherits_codex_step_execution_settings() {
  local issue output status capture_file

  issue="9037"
  capture_file="$WORKSPACES_DIR/$issue/captured-step.json"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "codex-step" "pending" "codex"
  jq '
    .steps[0].model = "gpt-5.6-sol"
    | .steps[0].reasoningEffort = "xhigh"
  ' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.tmp"
  mv "$WORKSPACES_DIR/$issue/state.tmp" "$WORKSPACES_DIR/$issue/state.json"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    local step="$1"
    local prompt="$2"
    local log_file="$3"

    printf '%s\n' "$step" > "$capture_file"
    jq -n -c '{
      type: "item.completed",
      item: {
        type: "agent_message",
        text: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."
      }
    }' > "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected Codex CONTEXT_CHECK PASS to return 0; output: $output"
  jq -e '
    .agent == "codex"
    and .model == "gpt-5.6-sol"
    and .reasoningEffort == "xhigh"
  ' "$capture_file" >/dev/null || fail "expected context check to inherit Codex step settings"
}

test_context_check_extracts_deepseek_result() {
  local issue output status

  issue="9038"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "deepseek-step" "pending" "deepseek"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    local step="$1"
    local prompt="$2"
    local log_file="$3"

    jq -n -c '{
      type: "message_end",
      message: {
        role: "assistant",
        content: [
          {type: "text", text: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."}
        ]
      }
    }' > "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected DeepSeek CONTEXT_CHECK PASS to return 0; output: $output"
}

# Writes a state whose steps are the given jq array expression.
write_context_steps_state() {
  local issue="$1"
  local steps="$2"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n --arg issue "$issue" \
    "{issue: (\$issue | tonumber), steps: $steps}" > "$WORKSPACES_DIR/$issue/state.json"
}

# Runs context_check with agent_run_step stubbed to record the step and
# directory it was given and to write $2 as the provider log.
run_stubbed_context_check() {
  local issue="$1"

  CONTEXT_STUB_LOG="$2"
  CONTEXT_STUB_DIR="$WORKSPACES_DIR/$issue"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/state.sh"
  source "$ROOT_DIR/scripts/context.sh"

  agent_run_step() {
    printf '%s\n' "$1" > "$CONTEXT_STUB_DIR/captured-step.json"
    printf '%s\n' "$4" > "$CONTEXT_STUB_DIR/captured-dir"
    printf '%s\n' "$CONTEXT_STUB_LOG" > "$3"
  }

  set +e
  CONTEXT_OUTPUT="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  CONTEXT_STATUS=$?
  set -e
}

codex_message() {
  jq -n -c --arg text "$1" '{type: "item.completed", item: {type: "agent_message", text: $text}}'
}

deepseek_message() {
  jq -n -c --argjson content "$1" '{type: "message_end", message: {role: "assistant", content: $content}}'
}

test_context_check_skips_non_json_log_lines() {
  local issue="9076"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"

  run_stubbed_context_check "$issue" "warning: something
$(jq -n -c '{type: "result", result: "CONTEXT_CHECK: PASS\nok"}')"

  [[ "$CONTEXT_STATUS" -eq 0 ]] || fail "expected PASS despite a non-JSON log line; output: $CONTEXT_OUTPUT"
}

test_context_check_prefers_blocked_step() {
  local issue="9077"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_context_steps_state "$issue" '[
    {id: "first-pending", type: "stub", agent: "claude", status: "pending", metrics: {}, notes: ""},
    {id: "blocked-step", type: "stub", agent: "codex", status: "blocked", metrics: {}, notes: ""}
  ]'

  run_stubbed_context_check "$issue" "$(codex_message $'CONTEXT_CHECK: PASS\nok')"

  [[ "$CONTEXT_STATUS" -eq 0 ]] || fail "expected PASS; output: $CONTEXT_OUTPUT"
  jq -e '.id == "blocked-step" and .agent == "codex"' "$WORKSPACES_DIR/$issue/captured-step.json" >/dev/null \
    || fail "expected the blocked step's settings to be used"
}

test_context_check_skips_always_run_cleanup_listed_first() {
  local issue="9078"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_context_steps_state "$issue" '[
    {id: "cleanup", type: "stub", agent: "deepseek", status: "pending", alwaysRun: true, metrics: {}, notes: ""},
    {id: "implement", type: "stub", agent: "codex", status: "pending", metrics: {}, notes: ""}
  ]'

  run_stubbed_context_check "$issue" "$(codex_message $'CONTEXT_CHECK: PASS\nok')"

  [[ "$CONTEXT_STATUS" -eq 0 ]] || fail "expected PASS; output: $CONTEXT_OUTPUT"
  jq -e '.id == "implement"' "$WORKSPACES_DIR/$issue/captured-step.json" >/dev/null \
    || fail "expected the cleanup step to be skipped"
}

test_context_check_fails_without_runnable_step() {
  local issue="9079"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "done-step" "completed" "claude"

  run_stubbed_context_check "$issue" ""

  [[ "$CONTEXT_STATUS" -eq 1 ]] || fail "expected no runnable step to fail; output: $CONTEXT_OUTPUT"
  assert_contains "$CONTEXT_OUTPUT" "no runnable step is available"
  [[ ! -e "$WORKSPACES_DIR/$issue/captured-step.json" ]] || fail "expected no agent run"
}

test_context_check_uses_last_codex_message_for_fail() {
  local issue="9080"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "codex-step" "pending" "codex"

  run_stubbed_context_check "$issue" "$(codex_message $'CONTEXT_CHECK: PASS\ndraft')
$(codex_message $'CONTEXT_CHECK: FAIL\nMissing glossary.')"

  [[ "$CONTEXT_STATUS" -eq 1 ]] || fail "expected the last Codex message FAIL to win; output: $CONTEXT_OUTPUT"
  assert_contains "$CONTEXT_OUTPUT" "CONTEXT.md is insufficient"
  assert_contains "$CONTEXT_OUTPUT" "Missing glossary."
}

test_context_check_extracts_deepseek_fail() {
  local issue="9081"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "deepseek-step" "pending" "deepseek"

  run_stubbed_context_check "$issue" "$(deepseek_message '[{"type": "text", "text": "CONTEXT_CHECK: FAIL\nMissing glossary."}]')"

  [[ "$CONTEXT_STATUS" -eq 1 ]] || fail "expected DeepSeek FAIL to return 1; output: $CONTEXT_OUTPUT"
  assert_contains "$CONTEXT_OUTPUT" "Missing glossary."
}

test_context_check_fails_closed_on_deepseek_message_without_text() {
  local issue="9082"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "deepseek-step" "pending" "deepseek"

  run_stubbed_context_check "$issue" "$(deepseek_message '[{"type": "thinking", "thinking": "CONTEXT_CHECK: PASS"}]')"

  [[ "$CONTEXT_STATUS" -eq 1 ]] || fail "expected a message without text to fail; output: $CONTEXT_OUTPUT"
  assert_contains "$CONTEXT_OUTPUT" "did not return CONTEXT_CHECK"
}

gemini_result() {
  jq -n -c --arg status "$1" --arg response "$2" '{event: "result", result: {status: $status, response: $response}}'
}

test_context_check_extracts_gemini_pass() {
  local issue="9085"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "gemini-step" "pending" "gemini"

  run_stubbed_context_check "$issue" "$(jq -n -c '{event: "step_update", step_update: {step_type: "agent_response", text_delta: "CONTEXT_CHECK: FAIL"}}')
$(gemini_result SUCCESS 'CONTEXT_CHECK: PASS
CONTEXT.md follows the required format.')"

  [[ "$CONTEXT_STATUS" -eq 0 ]] || fail "expected Gemini CONTEXT_CHECK PASS to return 0; output: $CONTEXT_OUTPUT"
}

test_context_check_extracts_gemini_fail() {
  local issue="9086"

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "gemini-step" "pending" "gemini"

  run_stubbed_context_check "$issue" "$(gemini_result SUCCESS 'CONTEXT_CHECK: FAIL
Missing glossary.')"

  [[ "$CONTEXT_STATUS" -eq 1 ]] || fail "expected Gemini FAIL to return 1; output: $CONTEXT_OUTPUT"
  assert_contains "$CONTEXT_OUTPUT" "Missing glossary."
}

test_context_check_runs_in_state_project_root() {
  local issue="9083"
  local project_dir

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending" "claude"
  project_dir="$WORKSPACES_DIR/$issue/project"
  mkdir -p "$project_dir"
  cp "$CONTEXT_FILE" "$project_dir/CONTEXT.md"
  jq --arg root "$project_dir" '.projectRoot = $root' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.tmp"
  mv "$WORKSPACES_DIR/$issue/state.tmp" "$WORKSPACES_DIR/$issue/state.json"

  run_stubbed_context_check "$issue" "$(jq -n -c '{type: "result", result: "CONTEXT_CHECK: PASS\nok"}')"

  [[ "$CONTEXT_STATUS" -eq 0 ]] || fail "expected PASS; output: $CONTEXT_OUTPUT"
  [[ "$(<"$WORKSPACES_DIR/$issue/captured-dir")" == "$project_dir" ]] || fail "expected the check to run in state .projectRoot"
}

test_run_stops_before_step_when_first_agent_is_unsupported() {
  local issue="9084"
  local output status status_value

  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "unsupported-step" "pending" "kimi"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected an unsupported first agent to stop the run"
  assert_contains "$output" "unsupported agent 'kimi'"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected the step to stay pending, got $status_value"
}

run_test test_run_hard_stops_when_context_missing
run_test test_run_hard_stops_when_context_is_insufficient
run_test test_context_check_passes_when_jsonl_result_contains_pass
run_test test_context_check_fails_when_jsonl_result_contains_fail
run_test test_context_check_falls_back_to_plain_text_pass
run_test test_context_check_inherits_codex_step_execution_settings
run_test test_context_check_extracts_deepseek_result
run_test test_context_check_skips_non_json_log_lines
run_test test_context_check_prefers_blocked_step
run_test test_context_check_skips_always_run_cleanup_listed_first
run_test test_context_check_fails_without_runnable_step
run_test test_context_check_uses_last_codex_message_for_fail
run_test test_context_check_extracts_deepseek_fail
run_test test_context_check_fails_closed_on_deepseek_message_without_text
run_test test_context_check_extracts_gemini_pass
run_test test_context_check_extracts_gemini_fail
run_test test_context_check_runs_in_state_project_root
run_test test_run_stops_before_step_when_first_agent_is_unsupported

echo "context_test.sh passed"
