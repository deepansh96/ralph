#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_claude_agent_step_renders_prompt_logs_metrics_and_summary() {
  local issue output fake_bin log_file status_value duration_value input_tokens cost_value

  issue="9007"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9007-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          sub_issue: 77,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  duration_value="$(jq -r '.steps[0].metrics.duration_ms' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected claude step to complete, got $status_value"
  [[ "$duration_value" == "1234" ]] || fail "expected duration_ms metric, got $duration_value"
  [[ "$input_tokens" == "11" ]] || fail "expected input_tokens metric, got $input_tokens"
  [[ "$cost_value" == "0.02" ]] || fail "expected cost_usd metric, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected claude step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw: Issue 9007"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Repo deepansh96/ralph"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Workspace $WORKSPACES_DIR/$issue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Branch feat/issue-9007-fixture"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Base main"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Step claude-step"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Sub 77"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Skills $ROOT_DIR/skills"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "claude-step"
  assert_contains "$output" "completed"
  assert_contains "$output" "1234"
}

test_run_claude_retries_transient_error_and_preserves_attempt_logs() {
  local log_file metrics_file output

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        printf '%s\n' 'Error: 529 overloaded'
        return 1
      fi

      printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried successfully",
        duration_ms: 2345,
        usage: {
          input_tokens: 12,
          output_tokens: 9
        },
        total_cost_usd: 0.03
      }'
    }

    RALPH_RETRY_DELAYS="0 0 0" run_claude "retry prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to be called twice, got $CLAUDE_CALLS"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected first failed attempt log to be preserved"
  assert_contains "$(<"$log_file.attempt-1")" "529 overloaded"
  assert_contains "$(<"$log_file")" "retried successfully"
  output="$(<"$metrics_file")"
  assert_contains "$output" '"provider": "claude"'
  assert_contains "$output" '"duration_ms": 2345'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_codex_retries_transient_errors_and_preserves_attempt_logs() {
  local log_file metrics_file output count_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  count_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
  printf '0\n' > "$count_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      local last_message_file calls

      last_message_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output-last-message)
            last_message_file="$2"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      cat >/dev/null

      calls="$(<"$count_file")"
      calls=$((calls + 1))
      printf '%s\n' "$calls" > "$count_file"
      case "$calls" in
        1)
          printf '%s\n' 'request failed: ETIMEDOUT'
          return 1
          ;;
        2)
          printf '%s\n' 'request failed: rate limit exceeded'
          return 1
          ;;
      esac

      if [[ -n "$last_message_file" ]]; then
        printf 'codex retried successfully\n' > "$last_message_file"
      fi
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":17,"output_tokens":19}}'
    }

    run_codex "retry prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$(<"$count_file")" -eq 3 ]] || fail "expected codex to be called three times, got $(<"$count_file")"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected first failed codex attempt log"
  [[ -f "$log_file.attempt-2" ]] || fail "expected second failed codex attempt log"
  assert_contains "$(<"$log_file.attempt-1")" "ETIMEDOUT"
  assert_contains "$(<"$log_file.attempt-2")" "rate limit"
  assert_contains "$(<"$log_file")" "turn.completed"
  output="$(<"$metrics_file")"
  assert_contains "$output" '"provider": "codex"'
  assert_contains "$output" '"input_tokens": 17'
  assert_contains "$output" '"output_tokens": 19'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$count_file"
}

test_codex_step_passes_model_and_reasoning_effort_when_set() {
  local log_file metrics_file args_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-*

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      printf '%s\n' "$@" > "$args_file"
      cat >/dev/null
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":3}}'
    }

    agent_run_step '{"agent":"codex","model":"gpt-5-codex","reasoningEffort":"ultra"}' \
      "model prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  grep -Fx -- "--model" "$args_file" >/dev/null || fail "expected separate --model argument"
  grep -Fx -- "gpt-5-codex" "$args_file" >/dev/null || fail "expected model value"
  grep -Fx -- "--config" "$args_file" >/dev/null || fail "expected separate --config argument"
  grep -Fx -- 'model_reasoning_effort="ultra"' "$args_file" >/dev/null \
    || fail "expected Codex ultra reasoning effort"
  assert_contains "$(<"$metrics_file")" '"provider": "codex"'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$args_file"
}

test_codex_step_omits_model_flag_when_unset() {
  local log_file metrics_file args_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-*

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      printf '%s\n' "$@" > "$args_file"
      cat >/dev/null
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":3}}'
    }

    agent_run_step '{"agent":"codex"}' "no model prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  ! grep -Fx -- "--model" "$args_file" >/dev/null || fail "expected no --model flag"
  ! grep -Fx -- "--config" "$args_file" >/dev/null || fail "expected no reasoning config"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$args_file"
}

test_claude_step_passes_reasoning_effort_when_set() {
  local log_file metrics_file args_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-*

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    claude() {
      printf '%s\n' "$@" > "$args_file"
      printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
      printf '%s\n' '{"type":"result","subtype":"success","result":"done","duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
    }

    agent_run_step '{"agent":"claude","reasoningEffort":"xhigh"}' \
      "reasoning prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  grep -Fx -- "--effort" "$args_file" >/dev/null || fail "expected separate --effort argument"
  grep -Fx -- "xhigh" "$args_file" >/dev/null || fail "expected Claude xhigh effort"
  assert_contains "$(<"$metrics_file")" '"provider": "claude"'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$args_file"
}

test_deepseek_step_runs_via_pi_with_default_model_reasoning_and_metrics() {
  local log_file metrics_file args_file cwd_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  cwd_file="$(mktemp)"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    pi() {
      printf '%s\n' "$@" > "$args_file"
      pwd > "$cwd_file"
      printf '%s\n' '{"type":"session","version":3,"id":"fake"}'
      printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input":21,"output":8,"cost":{"total":0.004}}}}'
      printf '%s\n' '{"type":"agent_end","messages":[]}'
    }

    agent_run_step '{"agent":"deepseek"}' \
      "deepseek prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  grep -Fx -- "--provider" "$args_file" >/dev/null || fail "expected Pi provider flag"
  grep -Fx -- "deepseek" "$args_file" >/dev/null || fail "expected DeepSeek provider"
  grep -Fx -- "deepseek-v4-flash" "$args_file" >/dev/null || fail "expected default DeepSeek model"
  grep -Fx -- "--thinking" "$args_file" >/dev/null || fail "expected Pi thinking flag"
  grep -Fx -- "high" "$args_file" >/dev/null || fail "expected default high thinking level"
  grep -Fx -- "deepseek prompt" "$args_file" >/dev/null || fail "expected rendered prompt"
  [[ "$(<"$cwd_file")" == "$PROJECT_ROOT" ]] || fail "expected Pi to run in project root"
  assert_contains "$(<"$metrics_file")" '"provider": "deepseek"'
  assert_contains "$(<"$metrics_file")" '"input_tokens": 21'
  assert_contains "$(<"$metrics_file")" '"output_tokens": 8'
  assert_contains "$(<"$metrics_file")" '"cost_usd": 0.004'

  rm -f "$log_file" "$metrics_file" "$args_file" "$cwd_file"
}

test_deepseek_step_fails_on_pi_error_event() {
  local log_file status

  log_file="$(mktemp)"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    pi() {
      printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"invalid api key","usage":{"input":0,"output":0,"cost":{"total":0}}}}'
    }

    set +e
    run_deepseek "prompt" "$log_file" "$PROJECT_ROOT" >/dev/null
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "expected Pi error event to fail the step"
  )

  rm -f "$log_file"
}

test_deepseek_step_accepts_pi_recovery_after_error_event() {
  local log_file metrics_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    pi() {
      printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"rate limit","usage":{"input":0,"output":0,"cost":{"total":0}}}}'
      printf '%s\n' '{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":0,"errorMessage":"rate limit"}'
      printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"stop","usage":{"input":21,"output":8,"cost":{"total":0.004}}}}'
    }

    run_deepseek "prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  assert_contains "$(<"$metrics_file")" '"output_tokens": 8'
  rm -f "$log_file" "$metrics_file"
}

test_deepseek_step_retries_terminal_pi_error_event() {
  local log_file metrics_file count_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  count_file="$(mktemp)"
  printf '0\n' > "$count_file"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"
    export RALPH_RETRY_DELAYS="0 0"

    pi() {
      local count
      count="$(( $(<"$count_file") + 1 ))"
      printf '%s\n' "$count" > "$count_file"
      if [[ "$count" -eq 1 ]]; then
        printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"rate limit","usage":{"input":0,"output":0,"cost":{"total":0}}}}'
        return
      fi
      printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"stop","usage":{"input":21,"output":8,"cost":{"total":0.004}}}}'
    }

    run_deepseek "prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  [[ "$(<"$count_file")" -eq 2 ]] || fail "expected Ralph to retry a terminal Pi rate-limit event"
  [[ -f "$log_file.attempt-1" ]] || fail "expected the failed Pi attempt log to be preserved"
  assert_contains "$(<"$metrics_file")" '"output_tokens": 8'
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$count_file"
}

test_gemini_step_runs_via_agy_with_model_effort_and_metrics() {
  local log_file metrics_file args_file cwd_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  cwd_file="$(mktemp)"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"
    SCRIPT_DIR="$ROOT_DIR"

    agy() {
      printf '%s\n' "$@" > "$args_file"
      pwd > "$cwd_file"
      printf '%s\n' '{"event":"init","conversation_id":"fake","init":{"model":"gemini-4-neon"}}'
      printf '%s\n' '{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"done","usage":{"input_tokens":5,"output_tokens":1}}}'
      printf '%s\n' '{"event":"result","result":{"conversation_id":"fake","status":"SUCCESS","response":"done","duration_seconds":2.5,"usage":{"input_tokens":34,"output_tokens":13}}}'
    }

    agent_run_step '{"agent":"gemini","model":"gemini-4-neon","reasoningEffort":"high"}' \
      "gemini prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  grep -Fx -- "--print" "$args_file" >/dev/null || fail "expected agy print mode"
  grep -Fx -- "gemini prompt" "$args_file" >/dev/null || fail "expected rendered prompt"
  grep -Fx -- "stream-json" "$args_file" >/dev/null || fail "expected stream-json output"
  grep -Fx -- "--dangerously-skip-permissions" "$args_file" >/dev/null || fail "expected unattended permissions"
  grep -Fx -- "--model" "$args_file" >/dev/null || fail "expected --model flag"
  grep -Fx -- "gemini-4-neon" "$args_file" >/dev/null || fail "expected step model"
  grep -Fx -- "--effort" "$args_file" >/dev/null || fail "expected --effort flag"
  grep -Fx -- "high" "$args_file" >/dev/null || fail "expected step reasoning effort"
  grep -Fx -- "--add-dir" "$args_file" >/dev/null || fail "expected the Ralph directory to be added to agy's workspace"
  grep -Fx -- "$ROOT_DIR" "$args_file" >/dev/null || fail "expected --add-dir to name the Ralph directory"
  [[ "$(<"$cwd_file")" == "$PROJECT_ROOT" ]] || fail "expected agy to run in project root"
  assert_contains "$(<"$metrics_file")" '"provider": "gemini"'
  assert_contains "$(<"$metrics_file")" '"duration_ms": 2500'
  assert_contains "$(<"$metrics_file")" '"input_tokens": 34'
  assert_contains "$(<"$metrics_file")" '"output_tokens": 13'
  assert_contains "$(<"$metrics_file")" '"cost_usd": null'

  rm -f "$log_file" "$metrics_file" "$args_file" "$cwd_file"
}

test_gemini_step_omits_model_and_effort_flags_when_unset() {
  local log_file args_file

  log_file="$(mktemp)"
  args_file="$(mktemp)"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    agy() {
      printf '%s\n' "$@" > "$args_file"
      printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"done","usage":{"input_tokens":1,"output_tokens":1}}}'
    }

    agent_run_step '{"agent":"gemini"}' "prompt" "$log_file" "$PROJECT_ROOT" >/dev/null
  )

  if grep -Fx -- "--model" "$args_file" >/dev/null; then fail "expected no --model flag when the step sets no model"; fi
  if grep -Fx -- "--effort" "$args_file" >/dev/null; then fail "expected no --effort flag when the step sets no effort"; fi

  rm -f "$log_file" "$args_file"
}

test_gemini_step_fails_when_agy_result_is_not_success() {
  local log_file status

  log_file="$(mktemp)"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    agy() {
      printf '%s\n' '{"event":"result","result":{"status":"ERROR","error":"model not found","usage":{"input_tokens":0,"output_tokens":0}}}'
    }

    set +e
    run_gemini "prompt" "$log_file" "$PROJECT_ROOT" >/dev/null
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "expected an agy ERROR result to fail the step"
  )

  rm -f "$log_file"
}

test_gemini_step_fails_when_agy_stream_has_no_result() {
  local log_file status

  log_file="$(mktemp)"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    agy() {
      printf '%s\n' '{"event":"init","conversation_id":"fake","init":{}}'
    }

    set +e
    run_gemini "prompt" "$log_file" "$PROJECT_ROOT" >/dev/null
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "expected a stream without a result event to fail the step"
  )

  rm -f "$log_file"
}

test_gemini_step_retries_transient_agy_error() {
  local log_file metrics_file count_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  count_file="$(mktemp)"
  printf '0\n' > "$count_file"
  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"
    export RALPH_RETRY_DELAYS="0 0"

    agy() {
      local count
      count="$(( $(<"$count_file") + 1 ))"
      printf '%s\n' "$count" > "$count_file"
      if [[ "$count" -eq 1 ]]; then
        printf '%s\n' '{"event":"result","result":{"status":"ERROR","error":"rate limit exceeded"}}'
        return 1
      fi
      printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"done","usage":{"input_tokens":34,"output_tokens":13}}}'
    }

    run_gemini "prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  [[ "$(<"$count_file")" -eq 2 ]] || fail "expected Ralph to retry a transient agy error"
  [[ -f "$log_file.attempt-1" ]] || fail "expected the failed agy attempt log to be preserved"
  assert_contains "$(<"$metrics_file")" '"output_tokens": 13'
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$count_file"
}

test_gemini_step_rejects_unsupported_reasoning_effort() {
  local log_file output status

  log_file="$(mktemp)"
  rm -f "$log_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    set +e
    output="$(agent_run_step '{"agent":"gemini","reasoningEffort":"minimal"}' \
      "invalid effort" "$log_file" "$PROJECT_ROOT" 2>&1)"
    status=$?
    set -e

    [[ "$status" -eq 1 ]] || fail "expected unsupported effort to fail"
    assert_contains "$output" "unsupported reasoning effort 'minimal' for agent 'gemini'"
  )

  rm -f "$log_file"
}

test_agent_rejects_unsupported_reasoning_effort() {
  local log_file output status

  log_file="$(mktemp)"
  rm -f "$log_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    set +e
    output="$(agent_run_step '{"agent":"claude","reasoningEffort":"ultra"}' \
      "invalid effort" "$log_file" "$PROJECT_ROOT" 2>&1)"
    status=$?
    set -e

    [[ "$status" -eq 1 ]] || fail "expected unsupported effort to fail"
    assert_contains "$output" "unsupported reasoning effort 'ultra' for agent 'claude'"
  )

  rm -f "$log_file"
}

test_run_claude_fails_clean_json_error_without_retrying() {
  local log_file metrics_file status

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      jq -n -c '{
        type: "error",
        error: {
          type: "authentication_error",
          message: "invalid api key"
        }
      }'
      return 2
    }

    set +e
    run_claude "auth prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    status=$?
    set -e

    [[ "$status" -eq 2 ]] || fail "expected clean JSON auth error status 2, got $status"
    [[ "$CLAUDE_CALLS" -eq 1 ]] || fail "expected claude to be called once, got $CLAUDE_CALLS"
  )

  [[ ! -f "$log_file.attempt-1" ]] || fail "expected non-retryable claude error not to preserve retry attempt"
  assert_contains "$(<"$log_file")" "authentication_error"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_claude_retries_empty_crash_log() {
  local log_file metrics_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        return 1
      fi

      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried after empty crash log",
        duration_ms: 3456,
        usage: {
          input_tokens: 3,
          output_tokens: 4
        },
        total_cost_usd: 0.04
      }'
    }

    run_claude "empty crash prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to retry empty crash log, got $CLAUDE_CALLS calls"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected empty failed attempt log to be preserved"
  [[ ! -s "$log_file.attempt-1" ]] || fail "expected first attempt log to be empty"
  assert_contains "$(<"$log_file")" "retried after empty crash log"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_claude_retries_truncated_crash_log() {
  local log_file metrics_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        printf '%s\n' '{"type":"result"'
        return 1
      fi

      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried after truncated crash log",
        duration_ms: 4567,
        usage: {
          input_tokens: 5,
          output_tokens: 6
        },
        total_cost_usd: 0.05
      }'
    }

    run_claude "truncated crash prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to retry truncated crash log, got $CLAUDE_CALLS calls"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected truncated failed attempt log to be preserved"
  assert_contains "$(<"$log_file.attempt-1")" '{"type":"result"'
  assert_contains "$(<"$log_file")" "retried after truncated crash log"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_codex_agent_step_logs_jsonl_and_records_metrics() {
  local issue output fake_bin log_file status_value input_tokens output_tokens cost_value

  issue="9008"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9008-fixture",
      projectRoot: $project_root,
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/codex-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ "$input_tokens" == "13" ]] || fail "expected codex input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "8" ]] || fail "expected codex output_tokens metric, got $output_tokens"
  [[ "$cost_value" == "null" ]] || fail "expected codex cost_usd to be null, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected codex step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "codex-step"
  assert_contains "$output" "codex"
}

test_codex_step_uses_project_root_from_state_json() {
  local issue fake_bin status_value log_file cwd_file

  issue="9025"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"

  mkdir -p "$fake_bin"
  cwd_file="$fake_bin/codex-cwd"
  cat > "$fake_bin/codex" <<FAKE_CODEX
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$(pwd)" > "$cwd_file"
while [[ \$# -gt 0 ]]; do shift; done
prompt="\$(cat)"
if [[ "\$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."}}'
fi
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: { input_tokens: 1, output_tokens: 1 },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9025-fixture",
      projectRoot: $project_root,
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ -f "$cwd_file" ]] || fail "expected codex cwd file to exist"

  local actual_cwd
  actual_cwd="$(<"$cwd_file")"
  [[ "$actual_cwd" == "$PROJECT_ROOT" ]] || fail "expected codex to run in $PROJECT_ROOT, got $actual_cwd"
}

test_unsupported_agent_marks_step_failed() {
  local issue fake_bin output status status_value

  issue="9048"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9048-unsupported-agent",
      projectRoot: $project_root,
      steps: [
        {
          id: "completed-setup",
          type: "test-fixture",
          agent: "claude",
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "unsupported-step",
          type: "test-fixture",
          agent: "kimi",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unsupported agent run to exit 1, got $status: $output"
  status_value="$(jq -r '.steps[] | select(.id == "unsupported-step") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "failed" ]] || fail "expected unsupported agent step to be marked failed, got $status_value"
}

run_test test_claude_agent_step_renders_prompt_logs_metrics_and_summary
run_test test_run_claude_retries_transient_error_and_preserves_attempt_logs
run_test test_run_codex_retries_transient_errors_and_preserves_attempt_logs
run_test test_codex_step_passes_model_and_reasoning_effort_when_set
run_test test_codex_step_omits_model_flag_when_unset
run_test test_claude_step_passes_reasoning_effort_when_set
run_test test_deepseek_step_runs_via_pi_with_default_model_reasoning_and_metrics
run_test test_deepseek_step_fails_on_pi_error_event
run_test test_deepseek_step_accepts_pi_recovery_after_error_event
run_test test_deepseek_step_retries_terminal_pi_error_event
run_test test_gemini_step_runs_via_agy_with_model_effort_and_metrics
run_test test_gemini_step_omits_model_and_effort_flags_when_unset
run_test test_gemini_step_fails_when_agy_result_is_not_success
run_test test_gemini_step_fails_when_agy_stream_has_no_result
run_test test_gemini_step_retries_transient_agy_error
run_test test_gemini_step_rejects_unsupported_reasoning_effort
run_test test_agent_rejects_unsupported_reasoning_effort
run_test test_run_claude_fails_clean_json_error_without_retrying
run_test test_run_claude_retries_empty_crash_log
run_test test_run_claude_retries_truncated_crash_log
run_test test_codex_agent_step_logs_jsonl_and_records_metrics
run_test test_codex_step_uses_project_root_from_state_json
run_test test_unsupported_agent_marks_step_failed

echo "agent_test.sh passed"
