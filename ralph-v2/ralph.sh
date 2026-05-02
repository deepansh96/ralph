#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ralph-v2/scripts/state.sh
source "$SCRIPT_DIR/scripts/state.sh"
# shellcheck source=ralph-v2/scripts/status.sh
source "$SCRIPT_DIR/scripts/status.sh"
# shellcheck source=ralph-v2/scripts/logs.sh
source "$SCRIPT_DIR/scripts/logs.sh"
# shellcheck source=ralph-v2/scripts/prompt.sh
source "$SCRIPT_DIR/scripts/prompt.sh"
# shellcheck source=ralph-v2/scripts/metrics.sh
source "$SCRIPT_DIR/scripts/metrics.sh"
# shellcheck source=ralph-v2/scripts/agent.sh
source "$SCRIPT_DIR/scripts/agent.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  ralph.sh --issue N
  ralph.sh status --issue N
  ralph.sh logs --issue N [--step step-id]
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

handle_sigint() {
  if [[ -n "$ACTIVE_STATE_FILE" && -n "$ACTIVE_STEP_ID" ]]; then
    state_update_step "$ACTIVE_STATE_FILE" "$ACTIVE_STEP_ID" "pending"
  fi
  if [[ -n "$ACTIVE_METRICS_FILE" ]]; then
    rm -f "$ACTIVE_METRICS_FILE"
  fi
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
  local step step_id step_type log_file template_file prompt metrics_json agent_status metrics_file current_status
  local is_hitl_resume flag_file answers

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

    state_update_step "$state_file" "$step_id" "in_progress"

    if ! prompt="$(prompt_render "$template_file" "$state_file" "$workspace" "$step" "$SCRIPT_DIR/skills")"; then
      state_update_step "$state_file" "$step_id" "failed"
      return 1
    fi
    if [[ "$is_hitl_resume" == "true" ]]; then
      prompt="$(prompt_append_hitl_resume "$prompt" "$flag_file" "$answers")"
    fi

    metrics_file="$(mktemp "${workspace}/metrics.${step_id}.XXXXXX")"
    ACTIVE_STATE_FILE="$state_file"
    ACTIVE_STEP_ID="$step_id"
    ACTIVE_METRICS_FILE="$metrics_file"
    trap handle_sigint INT

    set +e
    agent_run_step "$step" "$prompt" "$log_file" > "$metrics_file"
    agent_status=$?
    set -e

    trap - INT
    ACTIVE_STATE_FILE=""
    ACTIVE_STEP_ID=""
    ACTIVE_METRICS_FILE=""
    metrics_json="$(<"$metrics_file")"
    rm -f "$metrics_file"

    if [[ "$agent_status" -ne 0 ]]; then
      state_update_step "$state_file" "$step_id" "failed"
      return 1
    fi

    current_status="$(state_get_step_status "$state_file" "$step_id")"
    if [[ "$current_status" == "blocked" ]]; then
      state_update_step "$state_file" "$step_id" "blocked" "$metrics_json"
      hitl_print_blocked "$step_id" "$(hitl_flag_file "$workspace" "$step_id")"
      return 0
    fi

    state_update_step "$state_file" "$step_id" "completed" "$metrics_json"
  done

  metrics_print_summary "$state_file"
}

COMMAND="run"
ISSUE=""
STEP_ID=""

if [[ "${1:-}" == "status" || "${1:-}" == "logs" ]]; then
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
    STATE_FILE="$SCRIPT_DIR/workspaces/$ISSUE/state.json"
    state_validate "$STATE_FILE"
    run_pipeline "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE"
    ;;
  status|logs)
    STATE_FILE="$SCRIPT_DIR/workspaces/$ISSUE/state.json"
    state_validate "$STATE_FILE"
    if [[ "$COMMAND" == "status" ]]; then
      status_print "$STATE_FILE"
    else
      logs_tail "$STATE_FILE" "$SCRIPT_DIR/workspaces/$ISSUE" "$STEP_ID"
    fi
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
