#!/usr/bin/env bash

STATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ralph/scripts/config.sh
source "$STATE_SCRIPT_DIR/config.sh"
source "$STATE_SCRIPT_DIR/delegation.sh"

state_read() {
  local state_file="$1"

  jq '.' "$state_file"
}

# Pass --read-only from status and logs: they display failed steps instead of
# refusing them; only runs need the failed-step guard.
state_validate() {
  local state_file="$1" read_only="${2:-}"
  local stale_threshold now_epoch workspace

  if [[ ! -f "$state_file" ]]; then
    echo "Error: state.json not found; run init.md first" >&2
    return 1
  fi

  if [[ "$read_only" != "--read-only" ]] \
    && jq -e '.steps[]? | select(.status == "failed")' "$state_file" >/dev/null \
    && ! jq -e '.steps[]? | select(.alwaysRun == true and (.status == "pending" or .status == "in_progress"))' "$state_file" >/dev/null; then
    echo "Error: state has failed steps; set status to pending or completed before re-running" >&2
    return 1
  fi

  if ! jq -e '.steps[]? | select(.status == "failed")' "$state_file" >/dev/null \
    && jq -e '.steps[]? | select(.status == "pending" and .alwaysRun != true)' "$state_file" >/dev/null; then
    while IFS= read -r step_id; do
      [[ -n "$step_id" ]] || continue
      state_update_step "$state_file" "$step_id" "pending"
    done < <(jq -r '.steps[]? | select(.status == "completed" and .alwaysRun == true) | .id' "$state_file")
  fi

  stale_threshold="${RALPH_STALE_THRESHOLD:-3600}"
  now_epoch="$(date +%s)"
  workspace="$(dirname "$state_file")"

  while IFS=$'\t' read -r step_id state_pid; do
    local pid_file pid

    [[ -n "$step_id" ]] || continue

    pid_file="$workspace/pids/$step_id.pid"
    if [[ ! -f "$pid_file" ]]; then
      echo "Warning: resetting stale in_progress step '$step_id' to pending; PID file not found" >&2
      state_update_step "$state_file" "$step_id" "pending"
      continue
    fi

    pid="$(<"$pid_file")"
    if [[ -z "$pid" ]]; then
      pid="$state_pid"
    fi

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      echo "Warning: resetting stale in_progress step '$step_id' to pending; PID not alive" >&2
      state_update_step "$state_file" "$step_id" "pending"
    fi
  done < <(
    jq -r \
      --argjson now_epoch "$now_epoch" \
      --argjson stale_threshold "$stale_threshold" \
      '
        .steps[]?
        | select(
            .status == "in_progress"
            and (.started_at | type) == "number"
            and (($now_epoch - .started_at) > $stale_threshold)
          )
        | [.id, (.pid // "")] | @tsv
      ' "$state_file"
  )
}

state_get_current_step() {
  local state_file="$1"
  local step

  step="$(jq -c '
    if any(.steps[]?; .status == "failed") then
      first(.steps[]? | select(.status == "pending" and .alwaysRun == true)) // empty
    else
      first(.steps[]? | select(.status == "pending" and .alwaysRun != true))
        // first(.steps[]? | select(.status == "pending" and .alwaysRun == true))
        // empty
    end
  ' "$state_file")"
  [[ -n "$step" ]] || return 1
  printf '%s\n' "$step"
}

state_get_blocked_step() {
  local state_file="$1"
  local step

  step="$(jq -c 'first(.steps[]? | select(.status == "blocked")) // empty' "$state_file")"
  [[ -n "$step" ]] || return 1
  printf '%s\n' "$step"
}

state_get_step_status() {
  local state_file="$1"
  local step_id="$2"

  jq -r --arg id "$step_id" 'first(.steps[]? | select(.id == $id) | .status) // empty' "$state_file"
}

state_update_step() {
  local state_file="$1"
  local step_id="$2"
  local status="$3"
  local metrics_json="${4:-null}"
  local notes_json="${5:-null}"
  local pid="${6:-}"
  local tmp_file
  local now_epoch
  local workspace pid_dir pid_file

  now_epoch="$(date +%s)"
  workspace="$(dirname "$state_file")"
  pid_dir="$workspace/pids"
  pid_file="$pid_dir/$step_id.pid"
  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

  jq \
    --arg id "$step_id" \
    --arg status "$status" \
    --arg pid "$pid" \
    --argjson metrics "$metrics_json" \
    --argjson notes "$notes_json" \
    --argjson now_epoch "$now_epoch" \
    '
      .steps |= map(
        if .id == $id then
          .status = $status
          | if $metrics == null then . else .metrics = ((.metrics // {}) + $metrics) end
          | if $notes == null then . else .notes = $notes end
          | if $status == "in_progress" then .started_at = $now_epoch
            | .pid = (if $pid == "" then null else ($pid | tonumber) end)
            elif $status == "pending" then .started_at = null
            | .pid = null
            elif ($status == "completed" or $status == "failed") then .pid = null
            else .
            end
        else
          .
        end
      )
    ' "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"

  if [[ "$status" == "in_progress" && -n "$pid" ]]; then
    mkdir -p "$pid_dir"
    printf '%s\n' "$pid" > "$pid_file"
  elif [[ "$status" == "in_progress" ]]; then
    rm -f "$pid_file"
  elif [[ "$status" == "pending" || "$status" == "completed" || "$status" == "failed" ]]; then
    rm -f "$pid_file"
  fi
}

state_add_steps() {
  local state_file="$1"
  local steps_json="$2"
  local tmp_file

  if ! jq -e --argjson new_steps "$steps_json" '
    ($new_steps | type) == "array"
    and all($new_steps[]; (.id | type) == "string" and (.id | length) > 0)
  ' "$state_file" >/dev/null; then
    echo "Error: new steps must be a JSON array with non-empty string ids" >&2
    return 1
  fi

  if ! jq -e --argjson new_steps "$steps_json" '
    ([.steps[]?.id] + [$new_steps[].id]) as $ids
    | ($ids | length) == ($ids | unique | length)
  ' "$state_file" >/dev/null; then
    echo "Error: duplicate step id in state_add_steps input" >&2
    return 1
  fi

  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

  if ! jq \
    --argjson new_steps "$steps_json" \
    '.steps = ((.steps // []) + $new_steps)' \
    "$state_file" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$state_file"
}

state_snapshot_delegated_step_defaults() {
  local state_file="$1"
  local config_file="$2"
  local step_id="$3"
  local agent defaults tmp_file

  agent="$(
    jq -r --arg id "$step_id" \
      'first(.steps[]? | select(.id == $id) | .agent) // empty' \
      "$state_file"
  )"
  if [[ -z "$agent" ]]; then
    echo "Error: delegated step '$step_id' is missing or has no agent" >&2
    return 1
  fi

  if ! defaults="$(ralph_config_delegated_step_defaults "$config_file" "$agent")"; then
    return 1
  fi

  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
  if ! jq \
    --arg id "$step_id" \
    --argjson defaults "$defaults" \
    '
      def missing: . == null or . == "";
      .steps |= map(
        if .id == $id then
          .model = (if (.model | missing) then $defaults.model else .model end)
          | .reasoningEffort = (
              if (.reasoningEffort | missing)
              then $defaults.reasoningEffort
              else .reasoningEffort
              end
            )
          | .subagentModel = (
              if (.subagentModel | missing)
              then $defaults.subagentModel
              else .subagentModel
              end
            )
          | .subagentReasoningEffort = (
              if (.subagentReasoningEffort | missing)
              then $defaults.subagentReasoningEffort
              else .subagentReasoningEffort
              end
            )
        else
          .
        end
      )
    ' "$state_file" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$state_file"
}

# Gate activation: give one pending step the exact v1 delegation metadata when
# it has none. Completed, running, blocked, and failed steps and any explicit
# `delegation` value (even malformed, which later fails closed) stay untouched.
state_backfill_delegation_metadata() {
  local state_file="$1"
  local step_id="$2"
  local policy="$3"
  local tmp_file

  if ! jq -nc --arg policy "$policy" '{schemaVersion: 1, policy: $policy}' | delegation_validate metadata; then
    echo "Error: unknown delegation policy '$policy'" >&2
    return 1
  fi
  if ! jq -e --arg id "$step_id" 'any(.steps[]?; .id == $id)' "$state_file" >/dev/null; then
    echo "Error: delegated step '$step_id' is missing" >&2
    return 1
  fi

  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
  if ! jq \
    --arg id "$step_id" \
    --arg policy "$policy" \
    '
      .steps |= map(
        if .id == $id and .status == "pending" and (has("delegation") | not) then
          .delegation = {schemaVersion: 1, policy: $policy}
        else
          .
        end
      )
    ' "$state_file" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$state_file"
}
