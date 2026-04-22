#!/bin/bash
# Ralph - Autonomous AI agent loop for feature implementation
# Usage: ./ralph.sh --prd <name> [--agent auto|claude|codex] [options] [max_iterations] [prompt_file]
#
# Required:
#   --prd <name>      Feature/workspace name (e.g., "my-feature")
#                     Creates workspace at ralph/workspaces/<name>/
#
# Options:
#   --agent <mode>      Agent backend: auto (default), claude, or codex
#                       auto prefers claude when available, then codex.
#   --context <path>    Add context file or directory (repeatable)
#                       Files are listed in the prompt for the agent to read.
#                       Directories are recursively expanded to all files within.
#   --no-multi-agent    Disable Codex multi-agent sub-spawning

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DIR="$SCRIPT_DIR"

# Parse arguments
MAX_ITERATIONS=10
PROMPT_FILE=""
CONTEXT_ARGS=()
PRD_NAME=""
AGENT_MODE="auto"
MULTI_AGENT=true

usage() {
  echo "Usage: ./ralph.sh --prd <name> [--agent auto|claude|codex] [max_iterations] [prompt_file] [--context <path>...]"
  echo ""
  echo "Required:"
  echo "  --prd <name>      Feature/workspace name"
  echo ""
  echo "Options:"
  echo "  --agent <mode>      Agent backend: auto (default), claude, or codex"
  echo "  --context <path>    Add context file or directory (repeatable)"
  echo "  --no-multi-agent    Disable Codex multi-agent sub-spawning"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prd)
      [[ -n "${2:-}" ]] || { echo "Error: --prd requires a value"; usage; }
      PRD_NAME="$2"
      shift 2
      ;;
    --prd=*)
      PRD_NAME="${1#*=}"
      shift
      ;;
    --agent)
      [[ -n "${2:-}" ]] || { echo "Error: --agent requires a value"; usage; }
      AGENT_MODE="$2"
      shift 2
      ;;
    --agent=*)
      AGENT_MODE="${1#*=}"
      shift
      ;;
    --no-multi-agent)
      MULTI_AGENT=false
      shift
      ;;
    --context)
      [[ -n "${2:-}" ]] || { echo "Error: --context requires a value"; usage; }
      CONTEXT_ARGS+=("$2")
      shift 2
      ;;
    --context=*)
      CONTEXT_ARGS+=("${1#*=}")
      shift
      ;;
    *)
      # Positional args: first numeric is max_iterations, first non-numeric is prompt_file
      if [ -z "$PROMPT_FILE" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      elif [ -z "$PROMPT_FILE" ]; then
        PROMPT_FILE="$1"
      fi
      shift
      ;;
  esac
done

# Validate --prd is provided
if [ -z "$PRD_NAME" ]; then
  echo "Error: --prd <name> is required"
  usage
fi

# Default prompt file
if [ -z "$PROMPT_FILE" ]; then
  PROMPT_FILE="$RALPH_DIR/prompts/agent.md"
elif [[ "$PROMPT_FILE" != /* ]]; then
  PROMPT_FILE="$(pwd)/$PROMPT_FILE"
fi

# --- Utility helpers ---

is_number() {
  [[ "$1" =~ ^[0-9]*\.?[0-9]+$ ]]
}

json_number_or_null() {
  local value="${1:-}"
  if is_number "$value"; then
    printf "%s" "$value"
  else
    printf "null"
  fi
}

# Function to format seconds as human readable time
format_time() {
  local total_sec=$1
  local hours=$((total_sec / 3600))
  local minutes=$(((total_sec % 3600) / 60))
  local seconds=$((total_sec % 60))

  if [ $hours -gt 0 ]; then
    printf "%dh %dm %ds" $hours $minutes $seconds
  elif [ $minutes -gt 0 ]; then
    printf "%dm %ds" $minutes $seconds
  else
    printf "%ds" $seconds
  fi
}

format_optional_time() {
  local duration_ms="${1:-}"
  if [[ -z "$duration_ms" || "$duration_ms" == "null" ]] || ! [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
    printf "n/a"
    return
  fi
  format_time "$((duration_ms / 1000))"
}

empty_metrics_json() {
  local provider="$1"
  local duration_ms="$2"
  cat <<EOF
{
  "provider": "$provider",
  "duration_ms": $duration_ms,
  "duration_api_ms": null,
  "num_turns": 0,
  "input_tokens": 0,
  "output_tokens": 0,
  "cache_read_tokens": 0,
  "cache_creation_tokens": 0,
  "context_window": null,
  "cost_usd": null
}
EOF
}

# Resolve context paths and build context section
resolve_context() {
  local RESOLVED=()
  for arg in "${CONTEXT_ARGS[@]}"; do
    local abs_path
    if [[ "$arg" = /* ]]; then
      abs_path="$arg"
    else
      abs_path="$(pwd)/$arg"
    fi

    if [ -f "$abs_path" ]; then
      RESOLVED+=("$abs_path")
    elif [ -d "$abs_path" ]; then
      while IFS= read -r -d '' f; do
        RESOLVED+=("$f")
      done < <(find "$abs_path" -type f -print0 | sort -z)
    else
      echo "Error: Context path not found: $arg"
      exit 1
    fi
  done

  if [ ${#RESOLVED[@]} -gt 0 ]; then
    CONTEXT_SECTION="Context files (read all of these before starting work):"
    for f in "${RESOLVED[@]}"; do
      CONTEXT_SECTION="$CONTEXT_SECTION
- $f"
    done
  else
    CONTEXT_SECTION=""
  fi
}

resolve_context

# --- Dependency checks ---

for cmd in jq bc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: Required dependency '$cmd' is not available on PATH"
    exit 1
  }
done

# --- Agent selection ---

SELECTED_AGENT=""

select_agent() {
  case "$AGENT_MODE" in
    auto)
      if command -v claude >/dev/null 2>&1; then
        SELECTED_AGENT="claude"
      elif command -v codex >/dev/null 2>&1; then
        SELECTED_AGENT="codex"
      else
        echo "Error: Neither claude nor codex CLI is available on PATH"
        exit 1
      fi
      ;;
    claude|codex)
      command -v "$AGENT_MODE" >/dev/null 2>&1 || {
        echo "Error: Requested agent '$AGENT_MODE' is not available on PATH"
        exit 1
      }
      SELECTED_AGENT="$AGENT_MODE"
      ;;
    *)
      echo "Error: Invalid --agent value '$AGENT_MODE'. Use auto, claude, or codex."
      exit 1
      ;;
  esac
}

# --- Workspace setup ---

WORKSPACE_DIR="$RALPH_DIR/workspaces/$PRD_NAME"
mkdir -p "$WORKSPACE_DIR"

PRD_FILE="$WORKSPACE_DIR/prd.json"
PROGRESS_FILE="$WORKSPACE_DIR/progress.txt"

PROJECT_ROOT="$(pwd)"
WORKSPACE_REL="${WORKSPACE_DIR#"$PROJECT_ROOT"/}"

RUN_ID=$(date +%Y%m%d_%H%M%S)
METRICS_DIR="$WORKSPACE_DIR/runs/$RUN_ID"
CUMULATIVE_FILE="$WORKSPACE_DIR/ralph_runs_cumulative.json"
mkdir -p "$METRICS_DIR"

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# Verify prompt file exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Verify prd.json exists in workspace
if [ ! -f "$PRD_FILE" ]; then
  echo "Error: prd.json not found in workspace: $PRD_FILE"
  echo "Create a PRD first using: @ralph/prompts/prd-creator.md"
  echo "Then convert it: @ralph/prompts/prd-to-json.md"
  exit 1
fi

select_agent

echo "Starting Ralph - PRD: $PRD_NAME | Max iterations: $MAX_ITERATIONS"
echo "Agent: $SELECTED_AGENT"
echo "Workspace: $WORKSPACE_DIR"
echo "Using prompt: $PROMPT_FILE"

# --- Diagnostics and metrics ---

print_diagnostics() {
  local json="$1"
  local iteration="$2"

  local provider=$(echo "$json" | jq -r '.provider // "unknown"')
  local duration_ms=$(echo "$json" | jq -r '.duration_ms // 0')
  local duration_api_ms=$(echo "$json" | jq -r '.duration_api_ms // empty')
  local input_tokens=$(echo "$json" | jq -r '.input_tokens // 0')
  local output_tokens=$(echo "$json" | jq -r '.output_tokens // 0')
  local cache_read=$(echo "$json" | jq -r '.cache_read_tokens // 0')
  local cache_creation=$(echo "$json" | jq -r '.cache_creation_tokens // 0')
  local cost_usd=$(echo "$json" | jq -r '.cost_usd // empty')
  local context_window=$(echo "$json" | jq -r '.context_window // empty')
  local num_turns=$(echo "$json" | jq -r '.num_turns // 0')

  local time_str=$(format_time $((duration_ms / 1000)))
  local api_time_str=$(format_optional_time "$duration_api_ms")

  local cost_str="n/a"
  if is_number "$cost_usd"; then
    cost_str=$(printf '$%.4f' "$cost_usd")
  fi

  echo ""
  echo "┌──────────────────────────────────────────────────┐"
  printf "│  ITERATION %-2d DIAGNOSTICS (%-6s)              │\n" "$iteration" "$provider"
  echo "├──────────────────────────────────────────────────┤"
  printf "│  ⏱  Time:   %-10s  API: %-10s       │\n" "$time_str" "$api_time_str"
  printf "│  🔄 Turns:  %-3d                                 │\n" "$num_turns"
  echo "├──────────────────────────────────────────────────┤"
  printf "│  📥 Input:       %8d tokens               │\n" "$input_tokens"
  printf "│  📤 Output:      %8d tokens               │\n" "$output_tokens"
  printf "│  💾 Cache read:  %8d tokens               │\n" "$cache_read"
  printf "│  📝 Cache new:   %8d tokens               │\n" "$cache_creation"
  echo "├──────────────────────────────────────────────────┤"

  if is_number "$context_window" && [ "$context_window" -gt 0 ]; then
    local estimated_context=$((cache_creation + output_tokens))
    local context_pct=$(echo "scale=1; ($estimated_context * 100) / $context_window" | bc)
    printf "│  📈 Context:     ~%5.1f%% of %dk               │\n" "$context_pct" "$((context_window / 1000))"
  else
    printf "│  📈 Context:     %-33s │\n" "n/a"
  fi

  printf "│  💰 Cost:        %-33s │\n" "$cost_str"
  echo "└──────────────────────────────────────────────────┘"
}

save_iteration_metrics() {
  local json="$1"
  local iteration="$2"
  local metrics_file="$METRICS_DIR/iteration_$(printf '%03d' "$iteration").json"

  echo "$json" | jq \
    --argjson iteration "$iteration" \
    --arg timestamp "$(date -Iseconds)" '
    {
      iteration: $iteration,
      provider: .provider,
      timestamp: $timestamp,
      duration_ms: .duration_ms,
      duration_api_ms: .duration_api_ms,
      num_turns: .num_turns,
      input_tokens: .input_tokens,
      output_tokens: .output_tokens,
      cache_read_tokens: .cache_read_tokens,
      cache_creation_tokens: .cache_creation_tokens,
      context_window: .context_window,
      cost_usd: .cost_usd
    }' > "$metrics_file"
}

summarize_run() {
  local completed=$1
  local total_iterations=$2

  local total_duration_ms=0
  local total_duration_api_ms=0
  local total_input=0
  local total_output=0
  local total_cache_read=0
  local total_cache_creation=0
  local total_cost=0
  local total_turns=0
  local iteration_count=0
  local cost_metrics_complete=true
  local api_duration_available=true

  for f in "$METRICS_DIR"/iteration_*.json; do
    [ -f "$f" ] || continue

    total_duration_ms=$((total_duration_ms + $(jq -r '.duration_ms // 0' "$f")))
    total_input=$((total_input + $(jq -r '.input_tokens // 0' "$f")))
    total_output=$((total_output + $(jq -r '.output_tokens // 0' "$f")))
    total_cache_read=$((total_cache_read + $(jq -r '.cache_read_tokens // 0' "$f")))
    total_cache_creation=$((total_cache_creation + $(jq -r '.cache_creation_tokens // 0' "$f")))
    total_turns=$((total_turns + $(jq -r '.num_turns // 0' "$f")))
    iteration_count=$((iteration_count + 1))

    local iter_api_dur
    iter_api_dur=$(jq -r '.duration_api_ms // empty' "$f")
    if is_number "$iter_api_dur"; then
      total_duration_api_ms=$((total_duration_api_ms + iter_api_dur))
    else
      api_duration_available=false
    fi

    local iter_cost
    iter_cost=$(jq -r '.cost_usd // empty' "$f")
    if is_number "$iter_cost"; then
      total_cost=$(echo "$total_cost + $iter_cost" | bc)
    else
      cost_metrics_complete=false
    fi
  done

  local total_time_str=$(format_time $((total_duration_ms / 1000)))
  local total_api_time_str="n/a"
  if [ "$api_duration_available" = true ]; then
    total_api_time_str=$(format_time $((total_duration_api_ms / 1000)))
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║            RUN SUMMARY ($RUN_ID)           ║"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  Agent:        %-33s ║\n" "$SELECTED_AGENT"
  printf "║  Iterations:   %-3d                              ║\n" "$iteration_count"
  printf "║  Total Time:   %-12s API: %-10s   ║\n" "$total_time_str" "$total_api_time_str"
  printf "║  Total Turns:  %-3d                              ║\n" "$total_turns"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  📥 Input:       %10d tokens             ║\n" "$total_input"
  printf "║  📤 Output:      %10d tokens             ║\n" "$total_output"
  printf "║  💾 Cache read:  %10d tokens             ║\n" "$total_cache_read"
  printf "║  📝 Cache new:   %10d tokens             ║\n" "$total_cache_creation"
  echo "╠══════════════════════════════════════════════════╣"
  if [ "$cost_metrics_complete" = true ]; then
    printf "║  💰 Total Cost:  \$%-8.4f                     ║\n" "$total_cost"
  else
    printf "║  💰 Total Cost:  %-33s ║\n" "n/a"
  fi
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "Metrics saved to: $METRICS_DIR"

  # Save run summary
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg provider "$SELECTED_AGENT" \
    --argjson completed "$completed" \
    --argjson iterations "$iteration_count" \
    --argjson total_duration_ms "$total_duration_ms" \
    --argjson total_duration_api_ms "$(json_number_or_null "$( [ "$api_duration_available" = true ] && echo "$total_duration_api_ms" || echo "")")" \
    --argjson total_turns "$total_turns" \
    --argjson total_input "$total_input" \
    --argjson total_output "$total_output" \
    --argjson total_cache_read "$total_cache_read" \
    --argjson total_cache_creation "$total_cache_creation" \
    --argjson cost_usd "$(json_number_or_null "$( [ "$cost_metrics_complete" = true ] && echo "$total_cost" || echo "")")" \
    --argjson cost_complete "$([ "$cost_metrics_complete" = true ] && echo true || echo false)" '
    {
      run_id: $run_id,
      provider: $provider,
      completed: $completed,
      iterations: $iterations,
      total_duration_ms: $total_duration_ms,
      total_duration_api_ms: $total_duration_api_ms,
      total_turns: $total_turns,
      total_input_tokens: $total_input,
      total_output_tokens: $total_output,
      total_cache_read_tokens: $total_cache_read,
      total_cache_creation_tokens: $total_cache_creation,
      total_cost_usd: $cost_usd,
      cost_metrics_complete: $cost_complete
    }' > "$METRICS_DIR/summary.json"

  # Update cumulative file
  if [ -f "$CUMULATIVE_FILE" ]; then
    local prev_runs=$(jq -r '.total_runs // 0' "$CUMULATIVE_FILE")
    local prev_iterations=$(jq -r '.total_iterations // 0' "$CUMULATIVE_FILE")
    local prev_duration=$(jq -r '.total_duration_ms // 0' "$CUMULATIVE_FILE")
    local prev_input=$(jq -r '.total_input_tokens // 0' "$CUMULATIVE_FILE")
    local prev_output=$(jq -r '.total_output_tokens // 0' "$CUMULATIVE_FILE")

    local prev_cost_complete
    prev_cost_complete=$(jq -r '.cost_metrics_complete // empty' "$CUMULATIVE_FILE")

    if [ -z "$prev_cost_complete" ] || [ "$prev_cost_complete" = "null" ]; then
      local prev_cost_val
      prev_cost_val=$(jq -r '.total_cost_usd // empty' "$CUMULATIVE_FILE")
      if is_number "$prev_cost_val"; then
        prev_cost_complete=true
      else
        prev_cost_complete=false
      fi
    fi

    local cumulative_cost_complete=true
    if [ "$prev_cost_complete" != "true" ] || [ "$cost_metrics_complete" != "true" ]; then
      cumulative_cost_complete=false
    fi

    local prev_cost
    prev_cost=$(jq -r '.total_cost_usd // empty' "$CUMULATIVE_FILE")
    local new_total_cost
    if [ "$cumulative_cost_complete" = true ] && is_number "$prev_cost"; then
      new_total_cost=$(echo "$prev_cost + $total_cost" | bc)
    else
      new_total_cost=""
    fi

    jq -n \
      --argjson total_runs "$((prev_runs + 1))" \
      --argjson total_iterations "$((prev_iterations + iteration_count))" \
      --argjson total_duration_ms "$((prev_duration + total_duration_ms))" \
      --argjson total_input "$((prev_input + total_input))" \
      --argjson total_output "$((prev_output + total_output))" \
      --argjson cost_usd "$(json_number_or_null "$new_total_cost")" \
      --argjson cost_complete "$([ "$cumulative_cost_complete" = true ] && echo true || echo false)" \
      --arg last_provider "$SELECTED_AGENT" \
      --arg last_run "$RUN_ID" \
      --arg last_updated "$(date -Iseconds)" '
      {
        total_runs: $total_runs,
        total_iterations: $total_iterations,
        total_duration_ms: $total_duration_ms,
        total_input_tokens: $total_input,
        total_output_tokens: $total_output,
        total_cost_usd: $cost_usd,
        cost_metrics_complete: $cost_complete,
        last_provider: $last_provider,
        last_run: $last_run,
        last_updated: $last_updated
      }' > "$CUMULATIVE_FILE"
  else
    jq -n \
      --argjson total_iterations "$iteration_count" \
      --argjson total_duration_ms "$total_duration_ms" \
      --argjson total_input "$total_input" \
      --argjson total_output "$total_output" \
      --argjson cost_usd "$(json_number_or_null "$( [ "$cost_metrics_complete" = true ] && echo "$total_cost" || echo "")")" \
      --argjson cost_complete "$([ "$cost_metrics_complete" = true ] && echo true || echo false)" \
      --arg last_provider "$SELECTED_AGENT" \
      --arg last_run "$RUN_ID" \
      --arg last_updated "$(date -Iseconds)" '
      {
        total_runs: 1,
        total_iterations: $total_iterations,
        total_duration_ms: $total_duration_ms,
        total_input_tokens: $total_input,
        total_output_tokens: $total_output,
        total_cost_usd: $cost_usd,
        cost_metrics_complete: $cost_complete,
        last_provider: $last_provider,
        last_run: $last_run,
        last_updated: $last_updated
      }' > "$CUMULATIVE_FILE"
  fi
}

# --- Agent runner functions ---

RESULT=""
METRICS_JSON=""

run_claude() {
  local prompt="$1"
  local iteration="$2"
  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)

  local start_ms end_ms duration_ms
  start_ms=$(( $(date +%s) * 1000 ))
  if ! claude -p "$prompt" \
      --dangerously-skip-permissions \
      --output-format json >"$stdout_file" 2>"$stderr_file"; then
    echo "Warning: Claude exited non-zero for iteration $iteration"
  fi
  end_ms=$(( $(date +%s) * 1000 ))
  duration_ms=$((end_ms - start_ms))

  local json_output
  json_output=$(cat "$stdout_file")
  RESULT=$(echo "$json_output" | jq -r '.result // empty' 2>/dev/null)

  if [ -s "$stderr_file" ]; then
    echo "Claude stderr:"
    sed -n '1,40p' "$stderr_file"
  fi

  if echo "$json_output" | jq -e '.usage' >/dev/null 2>&1; then
    METRICS_JSON=$(echo "$json_output" | jq \
      --arg provider "claude" \
      --argjson fallback_duration "$duration_ms" '
      {
        provider: $provider,
        duration_ms: (.duration_ms // $fallback_duration),
        duration_api_ms: (.duration_api_ms // null),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_tokens: (.usage.cache_creation_input_tokens // 0),
        context_window: ((.modelUsage // {} | to_entries[0].value.contextWindow?) // 200000),
        cost_usd: (.total_cost_usd // null)
      }')
  else
    METRICS_JSON=$(empty_metrics_json "claude" "$duration_ms")
  fi

  rm -f "$stdout_file" "$stderr_file"
}

run_codex() {
  local prompt="$1"
  local iteration="$2"
  local stdout_file stderr_file last_message_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  last_message_file=$(mktemp)

  local codex_flags=(--skip-git-repo-check --sandbox workspace-write --json --output-last-message "$last_message_file")
  if [ "$MULTI_AGENT" = true ]; then
    codex_flags+=(--enable multi_agent)
  fi

  local start_ms end_ms duration_ms
  start_ms=$(( $(date +%s) * 1000 ))
  if ! printf "%s" "$prompt" | codex -a never exec \
      "${codex_flags[@]}" \
      - >"$stdout_file" 2>"$stderr_file"; then
    echo "Warning: Codex exited non-zero for iteration $iteration"
  fi
  end_ms=$(( $(date +%s) * 1000 ))
  duration_ms=$((end_ms - start_ms))

  RESULT=""
  [ -f "$last_message_file" ] && RESULT=$(cat "$last_message_file")

  if [ -s "$stderr_file" ]; then
    echo "Codex stderr:"
    sed -n '1,40p' "$stderr_file"
  fi

  local usage_json=""
  if [ -s "$stdout_file" ]; then
    if ! usage_json=$(jq -s '
      reduce .[] as $event (
        {
          input_tokens: 0,
          output_tokens: 0,
          cache_read_tokens: 0,
          num_turns: 0
        };
        if $event.type == "turn.completed" then
          .input_tokens += ($event.usage.input_tokens // 0) |
          .output_tokens += ($event.usage.output_tokens // 0) |
          .cache_read_tokens += ($event.usage.cached_input_tokens // 0) |
          .num_turns += 1
        else
          .
        end
      )' "$stdout_file" 2>/dev/null) || [ -z "$usage_json" ]; then
      echo "Warning: Could not parse Codex JSONL output"
      sed -n '1,20p' "$stdout_file"
      usage_json=""
    fi
  fi

  if [ -n "$usage_json" ]; then
    METRICS_JSON=$(echo "$usage_json" | jq \
      --arg provider "codex" \
      --argjson duration_ms "$duration_ms" '
      {
        provider: $provider,
        duration_ms: $duration_ms,
        duration_api_ms: null,
        num_turns: (.num_turns // 0),
        input_tokens: (.input_tokens // 0),
        output_tokens: (.output_tokens // 0),
        cache_read_tokens: (.cache_read_tokens // 0),
        cache_creation_tokens: 0,
        context_window: null,
        cost_usd: null
      }')
  else
    METRICS_JSON=$(empty_metrics_json "codex" "$duration_ms")
  fi

  rm -f "$stdout_file" "$stderr_file" "$last_message_file"
}

run_agent() {
  local prompt="$1"
  local iteration="$2"

  RESULT=""
  METRICS_JSON=""

  case "$SELECTED_AGENT" in
    claude) run_claude "$prompt" "$iteration" ;;
    codex)  run_codex "$prompt" "$iteration" ;;
    *)      echo "Error: Unsupported agent backend: $SELECTED_AGENT"; exit 1 ;;
  esac
}

# --- Main iteration loop ---

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS [$PRD_NAME] ($SELECTED_AGENT)"
  echo "═══════════════════════════════════════════════════════"

  PROMPT=$(cat "$PROMPT_FILE")
  PROMPT="${PROMPT//\{\{CONTEXT_SECTION\}\}/$CONTEXT_SECTION}"
  PROMPT="${PROMPT//\{\{WORKSPACE\}\}/$WORKSPACE_REL}"

  run_agent "$PROMPT" "$i"

  if [ -n "$RESULT" ]; then
    echo ""
    echo "$RESULT"
  fi

  if [ -n "$METRICS_JSON" ] && echo "$METRICS_JSON" | jq -e '.duration_ms' > /dev/null 2>&1; then
    print_diagnostics "$METRICS_JSON" "$i"
    save_iteration_metrics "$METRICS_JSON" "$i"
  else
    echo ""
    echo "Warning: Could not parse diagnostics from output"
  fi

  if echo "$RESULT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    summarize_run true "$i"
    exit 0
  fi

  echo ""
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
summarize_run false "$MAX_ITERATIONS"
exit 1
