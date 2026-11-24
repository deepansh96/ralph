#!/usr/bin/env bash

current_time_ms() {
  printf '%s000\n' "$(date +%s)"
}

agent_retry_delays() {
  printf '%s\n' "${RALPH_RETRY_DELAYS:-30 60 120}"
}

agent_log_has_transient_error() {
  grep -Eiq 'overloaded|529|rate limit|ETIMEDOUT|ECONNRESET' "$1"
}

agent_log_is_retryable_failure() {
  local log_file="$1"

  [[ -s "$log_file" ]] || return 0

  if agent_log_has_transient_error "$log_file"; then
    return 0
  fi

  if ! jq -s '.' "$log_file" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

agent_sleep_before_retry() {
  local attempt="$1"
  local delays delay

  read -r -a delays <<<"$(agent_retry_delays)"
  delay="${delays[$((attempt - 1))]:-0}"
  [[ "$delay" -gt 0 ]] || return 0
  sleep "$delay"
}

agent_validate_reasoning_effort() {
  local agent="$1"
  local effort="$2"

  [[ -n "$effort" ]] || return 0

  case "$agent:$effort" in
    codex:low|codex:medium|codex:high|codex:xhigh|codex:max|codex:ultra)
      return 0
      ;;
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max)
      return 0
      ;;
    deepseek:off|deepseek:minimal|deepseek:low|deepseek:medium|deepseek:high|deepseek:xhigh)
      return 0
      ;;
    gemini:low|gemini:medium|gemini:high|gemini:xhigh|gemini:max)
      return 0
      ;;
  esac

  echo "Error: unsupported reasoning effort '$effort' for agent '$agent'" >&2
  return 1
}

agent_run_with_retry() {
  local log_file="$1"
  local command_fn="$2"
  local attempt max_attempts status errexit_enabled

  max_attempts=3
  attempt=1

  while true; do
    errexit_enabled="false"
    if [[ $- == *e* ]]; then
      errexit_enabled="true"
      set +e
    fi
    "$command_fn" > "$log_file"
    status=$?
    if [[ "$errexit_enabled" == "true" ]]; then
      set -e
    fi

    if [[ "$status" -eq 0 ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]] || ! agent_log_is_retryable_failure "$log_file"; then
      return "$status"
    fi

    mv "$log_file" "$log_file.attempt-$attempt"
    agent_sleep_before_retry "$attempt"
    attempt=$((attempt + 1))
  done
}

# One Claude CLI invocation; the stream goes to stdout. EXTRA arguments are
# appended (the delegation gate adds its session-local worker and hooks).
agent_claude_command() {
  local prompt="$1" model="$2" reasoning_effort="$3"
  local -a claude_args
  shift 3

  claude_args=(-p "$prompt" --dangerously-skip-permissions --output-format stream-json --verbose)
  [[ -z "$model" ]] || claude_args+=(--model "$model")
  [[ -z "$reasoning_effort" ]] || claude_args+=(--effort "$reasoning_effort")
  claude "${claude_args[@]}" "$@"
}

# One `codex exec --json` invocation from PROJECT_ROOT; JSON events go to stdout.
agent_codex_command() {
  local prompt="$1" project_root="$2" model="$3" reasoning_effort="$4" last_message_file="$5"
  local -a codex_args

  codex_args=(-a never exec)
  [[ -z "$model" ]] || codex_args+=(--model "$model")
  [[ -z "$reasoning_effort" ]] \
    || codex_args+=(--config "model_reasoning_effort=\"$reasoning_effort\"")
  codex_args+=(
    --skip-git-repo-check
    --sandbox danger-full-access
    -C "$project_root"
    --json
    --output-last-message "$last_message_file"
    -
  )
  printf '%s' "$prompt" | (cd "$project_root" && codex "${codex_args[@]}")
}

run_claude() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"  # accepted for forward-compatibility, currently unused
  local model="${4:-}"
  local reasoning_effort="${5:-}"
  local start_ms end_ms duration_ms status

  agent_validate_reasoning_effort "claude" "$reasoning_effort" || return 1

  run_claude_command() {
    agent_claude_command "$prompt" "$model" "$reasoning_effort"
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_claude_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_claude_log "$log_file" "$duration_ms"
}

run_codex() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"
  local model="${4:-}"
  local reasoning_effort="${5:-}"
  local last_message_file start_ms end_ms duration_ms status

  agent_validate_reasoning_effort "codex" "$reasoning_effort" || return 1
  if [[ -z "$project_root" ]]; then
    project_root="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
  fi
  last_message_file="$(mktemp)"
  run_codex_command() {
    agent_codex_command "$prompt" "$project_root" "$model" "$reasoning_effort" "$last_message_file"
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_codex_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))
  rm -f "$last_message_file"

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_codex_log "$log_file" "$duration_ms"
}

run_deepseek() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"
  local model="${4:-deepseek-v4-flash}"
  local reasoning_effort="${5:-high}"
  local start_ms end_ms duration_ms status
  local -a pi_args

  agent_validate_reasoning_effort "deepseek" "$reasoning_effort" || return 1
  if [[ -z "$project_root" ]]; then
    project_root="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
  fi
  pi_args=(--provider deepseek --mode json --print --no-session)
  pi_args+=(--model "$model")
  pi_args+=(--thinking "$reasoning_effort")
  pi_args+=("$prompt")
  run_deepseek_command() {
    (cd "$project_root" && pi "${pi_args[@]}") || return
    jq -se '
      [
        .[]
        | select(.type == "message_end" and .message.role == "assistant")
      ]
      | length > 0
        and (last.message.stopReason != "error" and last.message.stopReason != "aborted")
    ' "$log_file" >/dev/null
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_deepseek_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))

  [[ "$status" -eq 0 ]] || return "$status"
  metrics_from_pi_log "$log_file" "$duration_ms" "deepseek"
}

# One Antigravity CLI (`agy`) print-mode invocation from PROJECT_ROOT; its
# stream-json events go to stdout. The Ralph directory is added to agy's
# workspace so the agent can read skills and write workspace artifacts when
# Ralph lives outside PROJECT_ROOT.
agent_gemini_command() {
  local prompt="$1" project_root="$2" model="$3" reasoning_effort="$4"
  local ralph_dir=""
  local -a agy_args

  agy_args=(--print "$prompt" --mode accept-edits --dangerously-skip-permissions --output-format stream-json)
  [[ -z "$model" ]] || agy_args+=(--model "$model")
  [[ -z "$reasoning_effort" ]] || agy_args+=(--effort "$reasoning_effort")
  if [[ -n "${SCRIPT_DIR:-}" && -d "$SCRIPT_DIR" ]]; then
    ralph_dir="$(cd "$SCRIPT_DIR" && pwd)"
    agy_args+=(--add-dir "$ralph_dir")
  fi
  (cd "$project_root" && agy "${agy_args[@]}" < /dev/null)
}

run_gemini() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"
  local model="${4:-}"
  local reasoning_effort="${5:-}"
  local start_ms end_ms duration_ms status

  agent_validate_reasoning_effort "gemini" "$reasoning_effort" || return 1
  if [[ -z "$project_root" ]]; then
    project_root="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
  fi
  # agy can exit 0 after a turn that ended in an error, so the step succeeds
  # only when the stream's last result event reports SUCCESS.
  run_gemini_command() {
    agent_gemini_command "$prompt" "$project_root" "$model" "$reasoning_effort" || return
    jq -Rn -e '
      [inputs | fromjson? | objects | select(.event == "result")]
      | length > 0 and last.result.status == "SUCCESS"
    ' "$log_file" >/dev/null
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_gemini_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))

  [[ "$status" -eq 0 ]] || return "$status"
  metrics_from_gemini_log "$log_file" "$duration_ms"
}

agent_run_step() {
  local step_json="$1"
  local prompt="$2"
  local log_file="$3"
  local project_root="${4:-}"
  local agent model reasoning_effort

  agent="$(jq -r '.agent // empty' <<<"$step_json")"
  model="$(jq -r '.model // empty' <<<"$step_json")"
  reasoning_effort="$(jq -r '.reasoningEffort // empty' <<<"$step_json")"
  case "$agent" in
    claude)
      run_claude "$prompt" "$log_file" "$project_root" "$model" "$reasoning_effort"
      ;;
    codex)
      run_codex "$prompt" "$log_file" "$project_root" "$model" "$reasoning_effort"
      ;;
    deepseek)
      run_deepseek "$prompt" "$log_file" "$project_root" "$model" "$reasoning_effort"
      ;;
    gemini)
      run_gemini "$prompt" "$log_file" "$project_root" "$model" "$reasoning_effort"
      ;;
    *)
      echo "Error: unsupported agent '$agent'" >&2
      return 1
      ;;
  esac
}
