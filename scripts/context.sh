#!/usr/bin/env bash

context_project_root() {
  local script_dir="$1"

  cd "$script_dir/.." && pwd
}

# Applies a jq filter to the log's JSON lines as one array, skipping any
# non-JSON lines such as CLI warnings.
context_log_events() {
  local log_file="$1"
  local filter="$2"

  jq -Rrn "[inputs | fromjson? | objects] | $filter" "$log_file" 2>/dev/null || true
}

context_agent_output() {
  local log_file="$1"
  local agent="$2"
  local output

  case "$agent" in
    claude)
      output="$(context_log_events "$log_file" '
        [.[] | select(.type == "result") | .result // empty]
        | last // empty
      ')"
      ;;
    codex)
      output="$(context_log_events "$log_file" '
        [
          .[]
          | select(.type == "item.completed" and .item.type == "agent_message")
          | .item.text // empty
        ]
        | last // empty
      ')"
      ;;
    deepseek)
      output="$(context_log_events "$log_file" '
        [
          .[]
          | select(.type == "message_end" and .message.role == "assistant")
          | [.message.content[]? | select(.type == "text") | .text]
          | join("\n")
        ]
        | last // empty
      ')"
      ;;
    gemini)
      output="$(context_log_events "$log_file" '
        [.[] | select(.event == "result") | .result.response // empty]
        | last // empty
      ')"
      ;;
    *)
      output=""
      ;;
  esac

  if [[ -z "$output" ]]; then
    output="$(<"$log_file")"
  fi
  printf '%s\n' "$output"
}

context_check() {
  local script_dir="$1"
  local state_file="$2"
  local workspace="$3"
  local project_root context_file step check_step agent
  local template_file log_file prompt output

  project_root="$(jq -r '.projectRoot // empty' "$state_file")"
  if [[ -z "$project_root" ]]; then
    project_root="$(context_project_root "$script_dir")"
  fi
  context_file="$project_root/CONTEXT.md"

  if [[ ! -f "$context_file" ]]; then
    echo "Error: CONTEXT.md not found at $context_file" >&2
    return 1
  fi

  template_file="$script_dir/prompts/check-context.md"
  log_file="$workspace/logs/check-context.log"
  mkdir -p "$workspace/logs"

  if ! step="$(state_get_blocked_step "$state_file")"; then
    if ! step="$(state_get_current_step "$state_file")"; then
      echo "Error: no runnable step is available for the CONTEXT.md completeness check" >&2
      return 1
    fi
  fi
  agent="$(jq -r '.agent // empty' <<<"$step")"
  check_step="$(jq -c '. + {id: "check-context", type: "check-context"}' <<<"$step")"

  if ! prompt="$(prompt_render "$template_file" "$state_file" "$workspace" "$check_step" "$script_dir/skills")"; then
    return 1
  fi

  prompt="$(cat <<EOF
$prompt

## Project Root

$project_root

## CONTEXT.md Path

$context_file

## CONTEXT.md Contents

\`\`\`md
$(<"$context_file")
\`\`\`
EOF
)"

  if ! agent_run_step "$step" "$prompt" "$log_file" "$project_root" >/dev/null; then
    echo "Error: CONTEXT.md completeness check failed to run with agent '$agent'; see $log_file" >&2
    return 1
  fi

  output="$(context_agent_output "$log_file" "$agent")"

  if grep -q '^CONTEXT_CHECK:[[:space:]]*PASS\b' <<<"$output"; then
    return 0
  fi

  if grep -q '^CONTEXT_CHECK:[[:space:]]*FAIL\b' <<<"$output"; then
    echo "Error: CONTEXT.md is insufficient." >&2
    sed '1s/^CONTEXT_CHECK:[[:space:]]*FAIL[[:space:]]*//' <<<"$output" >&2
    return 1
  fi

  echo "Error: CONTEXT.md completeness check did not return CONTEXT_CHECK: PASS or CONTEXT_CHECK: FAIL; see $log_file" >&2
  return 1
}
