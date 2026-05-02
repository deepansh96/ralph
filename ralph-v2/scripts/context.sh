#!/usr/bin/env bash

context_project_root() {
  local script_dir="$1"

  cd "$script_dir/.." && pwd
}

context_check() {
  local script_dir="$1"
  local state_file="$2"
  local workspace="$3"
  local project_root context_file
  local template_file log_file prompt output

  project_root="$(context_project_root "$script_dir")"
  context_file="$project_root/CONTEXT.md"

  if [[ ! -f "$context_file" ]]; then
    echo "Error: CONTEXT.md not found at $context_file" >&2
    return 1
  fi

  template_file="$script_dir/prompts/check-context.md"
  log_file="$workspace/logs/check-context.log"
  mkdir -p "$workspace/logs"

  if ! prompt="$(prompt_render "$template_file" "$state_file" "$workspace" '{"id":"check-context","type":"check-context"}' "$script_dir/skills")"; then
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

  if ! run_claude "$prompt" "$log_file" >/dev/null; then
    echo "Error: CONTEXT.md completeness check failed to run; see $log_file" >&2
    return 1
  fi

  if jq -e '.' "$log_file" >/dev/null 2>&1; then
    output="$(jq -r '.result // .message // .content // empty' "$log_file")"
  else
    output="$(<"$log_file")"
  fi

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
