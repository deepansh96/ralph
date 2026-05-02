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

run_pipeline() {
  local state_file="$1"
  local workspace="$2"
  local step step_id step_type log_file template_file prompt metrics_json agent_status

  mkdir -p "$workspace/logs"

  while step="$(state_get_current_step "$state_file")"; do
    step_id="$(jq -r '.id' <<<"$step")"
    step_type="$(jq -r '.type' <<<"$step")"
    log_file="$workspace/logs/$step_id.log"
    template_file="$SCRIPT_DIR/prompts/$step_type.md"

    state_update_step "$state_file" "$step_id" "in_progress"

    if ! prompt="$(prompt_render "$template_file" "$state_file" "$workspace" "$step" "$SCRIPT_DIR/skills")"; then
      state_update_step "$state_file" "$step_id" "failed"
      return 1
    fi

    set +e
    metrics_json="$(agent_run_step "$step" "$prompt" "$log_file")"
    agent_status=$?
    set -e

    if [[ "$agent_status" -ne 0 ]]; then
      state_update_step "$state_file" "$step_id" "failed"
      return "$agent_status"
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
