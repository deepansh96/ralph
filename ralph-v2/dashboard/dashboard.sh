#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKSPACES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/workspaces"

usage() {
  cat >&2 <<'USAGE'
Usage:
  dashboard.sh aggregate [--workspaces-dir <path>]
USAGE
}

resolve_workspaces_dir() {
  local workspaces_dir="${RALPH_WORKSPACES_DIR:-$DEFAULT_WORKSPACES_DIR}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspaces-dir)
        [[ $# -ge 2 ]] || {
          echo "Error: --workspaces-dir requires a path" >&2
          return 1
        }
        workspaces_dir="$2"
        shift 2
        ;;
      *)
        echo "Error: unknown aggregate option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  printf '%s\n' "$workspaces_dir"
}

aggregate() {
  local workspaces_dir workspaces_file warnings_file state_file

  workspaces_dir="$(resolve_workspaces_dir "$@")"
  workspaces_file="$(mktemp)"
  warnings_file="$(mktemp)"

  shopt -s nullglob
  for state_file in "$workspaces_dir"/*/state.json; do
    if ! jq empty "$state_file" >/dev/null 2>&1; then
      jq -Rn --arg warning "$state_file: invalid JSON" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '(.issue | type) == "number"' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: .issue must be numeric" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '(.steps | type) == "array"' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: .steps must be an array" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '
      all(.steps[]; (.status // null) as $status
        | ["pending", "in_progress", "completed", "blocked", "failed"] | index($status))
    ' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: step status must be one of pending, in_progress, completed, blocked, failed" '$warning' >> "$warnings_file"
      continue
    fi

    jq -c '
      def step_count($status):
        [.steps[] | select(.status == $status)] | length;

      def first_step_id($status):
        first(.steps[]? | select(.status == $status) | .id) // null;

      def current_step:
        first_step_id("failed")
        // first_step_id("blocked")
        // first_step_id("in_progress")
        // first_step_id("pending")
        // (last(.steps[]? | .id) // null);

      def derived_status:
        if any(.steps[]; .status == "failed") then "failed"
        elif any(.steps[]; .status == "blocked") then "blocked"
        elif any(.steps[]; .status == "in_progress") then "in_progress"
        elif all(.steps[]; .status == "completed") then "completed"
        else "pending"
        end;

      def total_cost:
        [.steps[] | .metrics.cost_usd? | select(. != null)] as $costs
        | if ($costs | length) == 0 then null else ($costs | add) end;

      {
        issue,
        repo: (.repo // ""),
        branch: (.branch // ""),
        createdAt: (.createdAt // ""),
        derivedStatus: derived_status,
        currentStep: current_step,
        steps: [
          .steps[] | {
            id,
            type,
            agent,
            status,
            duration_ms: (.metrics.duration_ms // 0),
            cost_usd: (.metrics.cost_usd // null)
          }
        ],
        totalDuration_ms: ([.steps[] | .metrics.duration_ms? // 0] | add // 0),
        totalCost_usd: total_cost,
        stepCounts: {
          completed: step_count("completed"),
          pending: step_count("pending"),
          in_progress: step_count("in_progress"),
          blocked: step_count("blocked"),
          failed: step_count("failed")
        }
      }
    ' "$state_file" >> "$workspaces_file"
  done
  shopt -u nullglob

  jq -n \
    --slurpfile workspaces "$workspaces_file" \
    --slurpfile warnings "$warnings_file" \
    '{workspaces: ($workspaces | sort_by(.issue)), warnings: $warnings}'
  rm -f "$workspaces_file" "$warnings_file"
}

main() {
  local command="${1:-}"

  case "$command" in
    aggregate)
      shift
      aggregate "$@"
      ;;
    *)
      usage
      return 1
      ;;
  esac
}

main "$@"
