#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/state.sh
source "$SCRIPT_DIR/scripts/state.sh"
# shellcheck source=scripts/parse-log.sh
source "$SCRIPT_DIR/scripts/parse-log.sh"
# shellcheck source=scripts/status.sh
source "$SCRIPT_DIR/scripts/status.sh"
# shellcheck source=scripts/logs.sh
source "$SCRIPT_DIR/scripts/logs.sh"
# shellcheck source=scripts/context.sh
source "$SCRIPT_DIR/scripts/context.sh"
# shellcheck source=scripts/prompt.sh
source "$SCRIPT_DIR/scripts/prompt.sh"
# shellcheck source=scripts/metrics.sh
source "$SCRIPT_DIR/scripts/metrics.sh"
# shellcheck source=scripts/agent.sh
source "$SCRIPT_DIR/scripts/agent.sh"
# shellcheck source=scripts/grill.sh
source "$SCRIPT_DIR/scripts/grill.sh"
# shellcheck source=scripts/delegation-gate.sh
source "$SCRIPT_DIR/scripts/delegation-gate.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  ralph.sh --issue N [--steps N] [--background]
  ralph.sh status --issue N
  ralph.sh logs --issue N [--step step-id]
  ralph.sh poll --issue N
  ralph.sh grill start (--issue N | --requirement-file PATH) --grilling-agent A --answering-agent A
  ralph.sh grill resume|status|logs|cleanup --id SESSION_ID
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

ACTIVE_STATE_FILE=""
ACTIVE_STEP_ID=""
ACTIVE_METRICS_FILE=""

handle_shutdown() {
  trap - INT TERM HUP EXIT
  if [[ -n "$ACTIVE_STATE_FILE" && -n "$ACTIVE_STEP_ID" ]]; then
    state_update_step "$ACTIVE_STATE_FILE" "$ACTIVE_STEP_ID" "pending"
  fi
  if [[ -n "$ACTIVE_METRICS_FILE" ]]; then
    rm -f "$ACTIVE_METRICS_FILE"
  fi
  delegation_gate_cleanup_inputs
  exit 0
}

hitl_flag_file() {
  local workspace="$1"
  local step_id="$2"

  printf '%s/hitl-%s.md\n' "$workspace" "$step_id"
}

hitl_answers() {
  local flag_file="$1"

  awk '
    BEGIN { in_answers = 0 }
    /^##[[:space:]]*Answers[[:space:]]*$/ || /^Answers:[[:space:]]*$/ {
      in_answers = 1
      next
    }
    in_answers { print }
  ' "$flag_file"
}

hitl_has_answers() {
  local flag_file="$1"
  local answers

  [[ -f "$flag_file" ]] || return 1
  answers="$(hitl_answers "$flag_file" | sed '/^[[:space:]]*$/d')"
  [[ -n "$answers" ]]
}

hitl_print_blocked() {
  local step_id="$1"
  local flag_file="$2"

  printf "Step '%s' is blocked for human input.\n" "$step_id"
  printf "Answer the questions in: %s\n" "$flag_file"
}

prompt_append_hitl_resume() {
  local prompt="$1"
  local flag_file="$2"
  local answers="$3"

  cat <<EOF
$prompt

## HITL Resume

This step was previously blocked for human input.
Use the answers below to continue from the paused point.
Do not repeat any council or review phase that already completed before the block.

Flag file: $flag_file

Human answers:
$answers
EOF
}

run_pipeline() {
  local state_file="$1"
  local workspace="$2"
  local step_limit="${3:-0}"
  local step step_id step_type log_file template_file prompt metrics_json agent_status metrics_file current_status
  local is_hitl_resume flag_file answers gated
  local steps_run=0
  local project_root
  project_root="$(jq -r '.projectRoot // empty' "$state_file")"

  mkdir -p "$workspace/logs"

  while true; do
    is_hitl_resume="false"
    answers=""

    if step="$(state_get_blocked_step "$state_file")"; then
      step_id="$(jq -r '.id' <<<"$step")"
      flag_file="$(hitl_flag_file "$workspace" "$step_id")"
      if ! hitl_has_answers "$flag_file"; then
        hitl_print_blocked "$step_id" "$flag_file"
        return 0
      fi
      answers="$(hitl_answers "$flag_file")"
      is_hitl_resume="true"
    elif ! step="$(state_get_current_step "$state_file")"; then
      break
    fi

    step_id="$(jq -r '.id' <<<"$step")"
    step_type="$(jq -r '.type' <<<"$step")"
    log_file="$workspace/logs/$step_id.log"
    template_file="$SCRIPT_DIR/prompts/$step_type.md"

    state_update_step "$state_file" "$step_id" "in_progress" "null" "null" "$$"

    # A gated step renders its prompt per provider invocation, after stamping
    # a fresh attempt; see scripts/delegation-gate.sh.
    gated="false"
    if delegation_gate_active <<<"$step"; then
      gated="true"
      DELEGATION_GATE_TEMPLATE="$template_file"
      DELEGATION_GATE_SKILLS="$SCRIPT_DIR/skills"
      DELEGATION_GATE_HITL_FLAG=""
      DELEGATION_GATE_HITL_ANSWERS=""
      if [[ "$is_hitl_resume" == "true" ]]; then
        DELEGATION_GATE_HITL_FLAG="$flag_file"
        DELEGATION_GATE_HITL_ANSWERS="$answers"
      fi
    else
      if ! prompt="$(prompt_render "$template_file" "$state_file" "$workspace" "$step" "$SCRIPT_DIR/skills")"; then
        state_update_step "$state_file" "$step_id" "failed"
        continue
      fi
      if [[ "$is_hitl_resume" == "true" ]]; then
        prompt="$(prompt_append_hitl_resume "$prompt" "$flag_file" "$answers")"
      fi
    fi

    metrics_file="$(mktemp "${workspace}/metrics.${step_id}.XXXXXX")"
    ACTIVE_STATE_FILE="$state_file"
    ACTIVE_STEP_ID="$step_id"
    ACTIVE_METRICS_FILE="$metrics_file"
    trap handle_shutdown INT TERM HUP EXIT

    set +e
    if [[ "$gated" == "true" ]]; then
      delegation_gate_run_step "$state_file" "$step_id" "$log_file" "$project_root" > "$metrics_file"
    else
      agent_run_step "$step" "$prompt" "$log_file" "$project_root" > "$metrics_file"
    fi
    agent_status=$?
    set -e

    trap - INT TERM HUP EXIT
    ACTIVE_STATE_FILE=""
    ACTIVE_STEP_ID=""
    ACTIVE_METRICS_FILE=""
    metrics_json="$(<"$metrics_file")"
    rm -f "$metrics_file"

    if [[ "$agent_status" -ne 0 ]]; then
      state_update_step "$state_file" "$step_id" "failed"
      continue
    fi

    current_status="$(state_get_step_status "$state_file" "$step_id")"
    if [[ "$current_status" == "failed" ]]; then
      state_update_step "$state_file" "$step_id" "failed" "$metrics_json"
      continue
    fi
    if [[ "$current_status" == "blocked" ]]; then
      state_update_step "$state_file" "$step_id" "blocked" "$metrics_json"
      hitl_print_blocked "$step_id" "$(hitl_flag_file "$workspace" "$step_id")"
      return 0
    fi

    state_update_step "$state_file" "$step_id" "completed" "$metrics_json"

    (( ++steps_run ))
    if [[ "$step_limit" -gt 0 && "$steps_run" -ge "$step_limit" ]]; then
      printf "Step limit reached (%d/%d). Stopping.\n" "$steps_run" "$step_limit"
      if jq -e '.steps[]? | select(.status == "failed")' "$state_file" >/dev/null; then
        return 1
      fi
      return 0
    fi
  done

  metrics_print_summary "$state_file"
  if jq -e '.steps[]? | select(.status == "failed")' "$state_file" >/dev/null; then
    return 1
  fi
}

run_pipeline_background() {
  local state_file="$1"
  local workspace="$2"
  local step_limit="${3:-0}"
  local wrapper_log="$workspace/logs/wrapper.log"
  local wrapper_pid_file="$workspace/step-runner.pid"
  local wrapper_pid

  mkdir -p "$workspace/logs"

  nohup bash -c 'exec "$1" __run_pipeline "$2" "$3" "$4"' \
    bash "$SCRIPT_DIR/ralph.sh" "$state_file" "$workspace" "$step_limit" \
    > "$wrapper_log" 2>&1 &
  wrapper_pid="$!"
  printf '%s\n' "$wrapper_pid" > "$wrapper_pid_file"
  printf "Started Ralph background pipeline wrapper PID %s\n" "$wrapper_pid"
}

poll_pipeline() {
  local state_file="$1"
  local workspace="$2"
  local interval="${RALPH_POLL_INTERVAL:-30}"
  local step step_id started_at pid wrapper_pid wrapper_pid_file elapsed elapsed_display pid_status
  local pending_count

  wrapper_pid_file="$workspace/step-runner.pid"

  while true; do
    if step="$(jq -c '
      if any(.steps[]?; .status == "failed")
        and all(.steps[]?; .alwaysRun != true or (.status != "pending" and .status != "in_progress"))
      then first(.steps[]? | select(.status == "failed")) else empty end
    ' "$state_file")" && [[ -n "$step" ]]; then
      step_id="$(jq -r '.id' <<<"$step")"
      printf "Step %s failed.\n" "$step_id" >&2
      return 1
    fi

    if step="$(jq -c 'first(.steps[]? | select(.status == "blocked")) // empty' "$state_file")" && [[ -n "$step" ]]; then
      step_id="$(jq -r '.id' <<<"$step")"
      hitl_print_blocked "$step_id" "$(hitl_flag_file "$workspace" "$step_id")"
      return 0
    fi

    step="$(jq -c 'first(.steps[]? | select(.status == "in_progress")) // empty' "$state_file")"
    pending_count="$(jq '[.steps[]? | select(.status == "pending")] | length' "$state_file")"
    if [[ -z "$step" && "$pending_count" -eq 0 ]]; then
      printf "Pipeline complete.\n"
      return 0
    fi

    if [[ -f "$wrapper_pid_file" ]]; then
      wrapper_pid="$(<"$wrapper_pid_file")"
    else
      wrapper_pid=""
    fi
    if [[ -n "$wrapper_pid" ]] && ! kill -0 "$wrapper_pid" 2>/dev/null; then
      state_validate "$state_file" >/dev/null 2>&1 || true
      if [[ -n "$step" ]]; then
        step_id="$(jq -r '.id' <<<"$step")"
        printf "Wrapper PID %s is dead while step %s is still in progress.\n" "$wrapper_pid" "$step_id" >&2
      else
        printf "Wrapper PID %s is dead with %s steps pending.\n" "$wrapper_pid" "$pending_count" >&2
      fi
      return 1
    fi

    if [[ -n "$step" ]]; then
      step_id="$(jq -r '.id' <<<"$step")"
      started_at="$(jq -r '.started_at // empty' <<<"$step")"
      pid="$(jq -r '.pid // empty' <<<"$step")"

      elapsed_display="-"
      if [[ "$started_at" =~ ^[0-9]+$ ]]; then
        elapsed=$(( $(date +%s) - started_at ))
        elapsed_display="$(_format_duration_seconds "$elapsed")"
      fi

      pid_status="dead"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        pid_status="alive"
      fi
      printf "Step %s elapsed %s PID %s.\n" "$step_id" "$elapsed_display" "$pid_status"
    else
      printf "No active step; %s pending.\n" "$pending_count"
    fi

    sleep "$interval"
  done
}

if [[ "${1:-}" == "__run_pipeline" ]]; then
  [[ $# -eq 4 ]] || die "__run_pipeline requires state file, workspace, and step limit"
  run_pipeline "$2" "$3" "$4"
  exit $?
fi

if [[ "${1:-}" == "grill" ]]; then
  shift
  grill_main "$@"
  exit $?
fi

COMMAND="run"
ISSUE=""
STEP_ID=""
STEP_LIMIT=""
BACKGROUND="false"

if [[ "${1:-}" == "status" || "${1:-}" == "logs" || "${1:-}" == "poll" ]]; then
  COMMAND="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      [[ $# -ge 2 ]] || die "--issue requires a value"
      ISSUE="$2"
      shift 2
      ;;
    --step)
      [[ $# -ge 2 ]] || die "--step requires a value"
      STEP_ID="$2"
      shift 2
      ;;
    --steps)
      [[ $# -ge 2 ]] || die "--steps requires a value"
      STEP_LIMIT="$2"
      shift 2
      ;;
    --background)
      BACKGROUND="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$ISSUE" ]] || die "--issue is required"
is_positive_integer "$ISSUE" || die "--issue must be a positive integer"

case "$COMMAND" in
  run)
    if [[ -n "$STEP_LIMIT" ]]; then
      is_positive_integer "$STEP_LIMIT" || die "--steps must be a positive integer"
    fi
    STATE_FILE="$SCRIPT_DIR/workspaces/$ISSUE/state.json"
    state_validate "$STATE_FILE"
    if ! jq -e '.steps[]? | select(.status == "completed" or .status == "failed")' "$STATE_FILE" >/dev/null 2>&1; then
      context_check "$SCRIPT_DIR" "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE"
    fi
    if [[ "$BACKGROUND" == "true" ]]; then
      run_pipeline_background "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE" "${STEP_LIMIT:-0}"
    else
      run_pipeline "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE" "${STEP_LIMIT:-0}"
    fi
    ;;
  status|logs|poll)
    STATE_FILE="$SCRIPT_DIR/workspaces/$ISSUE/state.json"
    if [[ "$COMMAND" == "poll" ]]; then
      [[ -f "$STATE_FILE" ]] || state_validate "$STATE_FILE"
      poll_pipeline "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE"
    elif [[ "$COMMAND" == "status" ]]; then
      state_validate "$STATE_FILE" --read-only
      status_print "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE"
    else
      state_validate "$STATE_FILE" --read-only
      logs_tail "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE" "$STEP_ID"
    fi
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
