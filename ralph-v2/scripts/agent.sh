#!/usr/bin/env bash

current_time_ms() {
  printf '%s000\n' "$(date +%s)"
}

run_claude() {
  local prompt="$1"
  local log_file="$2"
  local start_ms end_ms duration_ms status

  start_ms="$(current_time_ms)"
  claude -p "$prompt" --dangerously-skip-permissions --output-format json > "$log_file"
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_claude_log "$log_file" "$duration_ms"
}

run_codex() {
  local prompt="$1"
  local log_file="$2"
  local last_message_file start_ms end_ms duration_ms status

  last_message_file="$(mktemp)"
  start_ms="$(current_time_ms)"
  printf '%s' "$prompt" | codex -a never exec \
    --skip-git-repo-check \
    --sandbox danger-full-access \
    --json \
    --output-last-message "$last_message_file" \
    - > "$log_file"
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))
  rm -f "$last_message_file"

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_codex_log "$log_file" "$duration_ms"
}

agent_run_step() {
  local step_json="$1"
  local prompt="$2"
  local log_file="$3"
  local agent

  agent="$(jq -r '.agent // empty' <<<"$step_json")"
  case "$agent" in
    claude)
      run_claude "$prompt" "$log_file"
      ;;
    codex)
      run_codex "$prompt" "$log_file"
      ;;
    *)
      echo "Error: unsupported agent '$agent'" >&2
      return 1
      ;;
  esac
}
