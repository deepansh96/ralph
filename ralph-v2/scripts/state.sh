#!/usr/bin/env bash

state_read() {
  local state_file="$1"

  jq '.' "$state_file"
}

state_validate() {
  local state_file="$1"

  if [[ ! -f "$state_file" ]]; then
    echo "Error: state.json not found; run init.md first" >&2
    return 1
  fi

  if jq -e '.steps[]? | select(.status == "failed")' "$state_file" >/dev/null; then
    echo "Error: state has failed steps; set status to pending or completed before re-running" >&2
    return 1
  fi
}

state_get_current_step() {
  local state_file="$1"
  local step

  step="$(jq -c 'first(.steps[]? | select(.status == "pending")) // empty' "$state_file")"
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
  local tmp_file

  tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"

  jq \
    --arg id "$step_id" \
    --arg status "$status" \
    --argjson metrics "$metrics_json" \
    --argjson notes "$notes_json" \
    '
      .steps |= map(
        if .id == $id then
          .status = $status
          | if $metrics == null then . else .metrics = ((.metrics // {}) + $metrics) end
          | if $notes == null then . else .notes = $notes end
        else
          .
        end
      )
    ' "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"
}
