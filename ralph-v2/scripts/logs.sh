#!/usr/bin/env bash

logs_active_step_id() {
  local state_file="$1"
  local step_id

  step_id="$(jq -r 'first(.steps[]? | select(.status == "in_progress") | .id) // empty' "$state_file")"
  [[ -n "$step_id" ]] || return 1
  printf '%s\n' "$step_id"
}

logs_tail() {
  local state_file="$1"
  local workspace="$2"
  local step_id="${3:-}"
  local log_file

  if [[ -z "$step_id" ]]; then
    step_id="$(logs_active_step_id "$state_file")" || {
      echo "Error: no active in_progress step found; pass --step <id>" >&2
      return 1
    }
  fi

  log_file="$workspace/logs/$step_id.log"
  if [[ ! -f "$log_file" ]]; then
    echo "Error: log file not found for step '$step_id': $log_file" >&2
    return 1
  fi

  tail -n 50 "$log_file"
}
