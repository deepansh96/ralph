#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
TEST_ISSUES=(9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012)

cleanup() {
  local issue

  for issue in "${TEST_ISSUES[@]}"; do
    rm -rf "${WORKSPACES_DIR:?}/$issue"
  done
  rm -rf "${WORKSPACES_DIR:?}/fake-bin"
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

install_fake_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

jq -n --arg prompt "$prompt" '{
  result: ("claude saw: " + $prompt),
  duration_ms: 1234,
  usage: {
    input_tokens: 11,
    output_tokens: 7
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_interrupt_once_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

marker="$(dirname "$0")/interrupted-once"
if [[ ! -f "$marker" ]]; then
  touch "$marker"
  kill -INT "$PPID"
  sleep 1
  exit 130
fi

jq -n '{
  result: "completed after interrupt",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_hitl_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

workspace="$(awk '/^Workspace / { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step / { print $2; exit }' <<<"$prompt")"
state_file="$workspace/state.json"
flag_file="$workspace/hitl-$step_id.md"

if [[ "$prompt" == *"## HITL Resume"* ]]; then
  [[ "$prompt" == *"Use the reviewed option"* ]] || exit 41
  [[ "$prompt" == *"Do not repeat any council or review phase"* ]] || exit 42
  jq -n --arg prompt "$prompt" '{
    result: ("resumed with: " + $prompt),
    duration_ms: 222,
    usage: {
      input_tokens: 3,
      output_tokens: 2
    },
    total_cost_usd: 0.03
  }'
  exit 0
fi

jq --arg id "$step_id" '
  .steps |= map(if .id == $id then .status = "blocked" else . end)
' "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

cat > "$flag_file" <<'FLAG'
## Questions

Which option should the review continue with?

## Answers
FLAG

jq -n '{
  result: "blocked for human input",
  duration_ms: 111,
  usage: {
    input_tokens: 2,
    output_tokens: 1
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_failing_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

echo "agent failed deliberately" >&2
exit 42
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_codex() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

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

prompt="$(cat)"
if [[ -n "$last_message_file" ]]; then
  printf 'codex saw: %s\n' "$prompt" > "$last_message_file"
fi

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"
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

test_run_completes_pending_agent_step() {
  local issue status_value log_file fake_bin

  issue="9003"
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
      branch: "feat/issue-9003-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected agent step to be completed, got $status_value"

  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"
  [[ -f "$log_file" ]] || fail "expected agent step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw"
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

test_claude_agent_step_renders_prompt_logs_metrics_and_summary() {
  local issue output fake_bin log_file status_value duration_value input_tokens cost_value

  issue="9007"
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
          subIssue: 77,
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

test_codex_agent_step_logs_jsonl_and_records_metrics() {
  local issue output fake_bin log_file status_value input_tokens output_tokens cost_value

  issue="9008"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9008-fixture",
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

test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up() {
  local issue output fake_bin status first_status second_status

  issue="9009"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_interrupt_once_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9009-fixture",
      steps: [
        {
          id: "interruptible-step",
          type: "test-fixture",
          agent: "claude",
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

  [[ "$status" -eq 0 ]] || fail "expected SIGINT handler to exit cleanly, got $status: $output"
  first_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$first_status" == "pending" ]] || fail "expected interrupted step to reset to pending, got $first_status"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null
  second_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$second_status" == "completed" ]] || fail "expected rerun to complete same step, got $second_status"
}

test_blocked_step_stops_then_resumes_with_human_answers() {
  local issue output fake_bin flag_file status_value log_file

  issue="9010"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_hitl_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9010-fixture",
      steps: [
        {
          id: "review-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"
  flag_file="$WORKSPACES_DIR/$issue/hitl-review-step.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected step to remain blocked, got $status_value"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$output" "$flag_file"

  printf "\nUse the reviewed option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-step.log"
  [[ "$status_value" == "completed" ]] || fail "expected answered HITL step to complete, got $status_value"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "resumed with"
}

test_failed_agent_invocation_marks_step_failed_and_exits_one() {
  local issue output fake_bin status status_value

  issue="9011"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_failing_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9011-fixture",
      steps: [
        {
          id: "failing-step",
          type: "test-fixture",
          agent: "claude",
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

  [[ "$status" -eq 1 ]] || fail "expected failed agent to make ralph exit 1, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "failed" ]] || fail "expected failed agent step to be marked failed, got $status_value"
}

test_init_prompt_defines_complete_workspace_initialization_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/init.md"
  [[ -f "$prompt_file" ]] || fail "expected init prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "command -v gh"
  assert_contains "$prompt" "workspaces/{{ISSUE}}"
  assert_contains "$prompt" "must not overwrite"
  assert_contains "$prompt" '"baseBranch": null'
  assert_contains "$prompt" '"branch": null'
  assert_contains "$prompt" '"status": "initialized"'
  assert_contains "$prompt" '"phase": "fixed"'
  assert_contains "$prompt" '"metrics": null'
  assert_contains "$prompt" '"reviewer": null'
  assert_contains "$prompt" "review-decisions"
  assert_contains "$prompt" "create-prd"
  assert_contains "$prompt" "create-slices"
  assert_contains "$prompt" "preflight"
  assert_contains "$prompt" "ralph.sh status --issue {{ISSUE}}"
}

test_initialized_workspace_status_shows_four_pending_fixed_steps() {
  local issue output pending_count

  issue="9012"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      createdAt: "2026-05-02T00:00:00Z",
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: true,
          metrics: null,
          notes: ""
        },
        {
          id: "create-prd",
          phase: "fixed",
          type: "create-prd",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "create-slices",
          phase: "fixed",
          type: "create-slices",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          status: "pending",
          agent: "claude",
          reviewer: null,
          hitl: false,
          metrics: null,
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$RALPH" status --issue "$issue")"
  pending_count="$(grep -c "pending" <<<"$output")"

  [[ "$pending_count" == "4" ]] || fail "expected 4 pending steps in status output, got $pending_count: $output"
  assert_contains "$output" "review-decisions"
  assert_contains "$output" "create-prd"
  assert_contains "$output" "create-slices"
  assert_contains "$output" "preflight"
}

test_issue_must_be_positive_integer
test_run_requires_existing_state
test_run_rejects_failed_steps
test_run_completes_pending_agent_step
test_status_prints_step_table
test_logs_tails_active_step_log
test_logs_tails_specific_step_log
test_claude_agent_step_renders_prompt_logs_metrics_and_summary
test_codex_agent_step_logs_jsonl_and_records_metrics
test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up
test_blocked_step_stops_then_resumes_with_human_answers
test_failed_agent_invocation_marks_step_failed_and_exits_one
test_init_prompt_defines_complete_workspace_initialization_contract
test_initialized_workspace_status_shows_four_pending_fixed_steps

echo "All ralph-v2 tests passed"
