#!/bin/bash
# Ralph - Autonomous AI agent loop for feature implementation
# Usage: ./ralph.sh [options] [max_iterations] [prompt_file]
#
# Arguments:
#   max_iterations  Maximum number of iterations (default: 10)
#   prompt_file     Path to custom prompt file (default: prompts/agent.md)
#
# Options:
#   --context <path>  Add context file or directory (repeatable)
#                     Files are listed in the prompt for the agent to read.
#                     Directories are recursively expanded to all files within.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DIR="$SCRIPT_DIR"

# Parse arguments
MAX_ITERATIONS=10
PROMPT_FILE=""
CONTEXT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      CONTEXT_ARGS+=("$2")
      shift 2
      ;;
    --context=*)
      CONTEXT_ARGS+=("${1#*=}")
      shift
      ;;
    *)
      # Positional args: first is max_iterations, second is prompt_file
      if [ -z "$PROMPT_FILE" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      elif [ -z "$PROMPT_FILE" ]; then
        PROMPT_FILE="$1"
      fi
      shift
      ;;
  esac
done

# Default prompt file
if [ -z "$PROMPT_FILE" ]; then
  PROMPT_FILE="$RALPH_DIR/prompts/agent.md"
elif [[ "$PROMPT_FILE" != /* ]]; then
  # Relative path - resolve from current directory
  PROMPT_FILE="$(pwd)/$PROMPT_FILE"
fi

# Resolve context paths and build context section
resolve_context() {
  local RESOLVED=()
  for arg in "${CONTEXT_ARGS[@]}"; do
    # Resolve to absolute path
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

  # Build context section text
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

PRD_FILE="$RALPH_DIR/prd.json"
PROGRESS_FILE="$RALPH_DIR/progress.txt"
ARCHIVE_DIR="$RALPH_DIR/archive"
LAST_BRANCH_FILE="$RALPH_DIR/.last-branch"

# Metrics tracking
RUN_ID=$(date +%Y%m%d_%H%M%S)
METRICS_DIR="$RALPH_DIR/runs/$RUN_ID"
CUMULATIVE_FILE="$RALPH_DIR/ralph_runs_cumulative.json"
mkdir -p "$METRICS_DIR"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

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

echo "Starting Ralph - Max iterations: $MAX_ITERATIONS"
echo "Using prompt: $PROMPT_FILE"

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

# Function to print diagnostics from JSON output
print_diagnostics() {
  local json="$1"
  local iteration="$2"

  # Extract values using jq
  local duration_ms=$(echo "$json" | jq -r '.duration_ms // 0')
  local duration_api_ms=$(echo "$json" | jq -r '.duration_api_ms // 0')
  local input_tokens=$(echo "$json" | jq -r '.usage.input_tokens // 0')
  local output_tokens=$(echo "$json" | jq -r '.usage.output_tokens // 0')
  local cache_read=$(echo "$json" | jq -r '.usage.cache_read_input_tokens // 0')
  local cache_creation=$(echo "$json" | jq -r '.usage.cache_creation_input_tokens // 0')
  local cost_usd=$(echo "$json" | jq -r '.total_cost_usd // 0')
  local context_window=$(echo "$json" | jq -r '.modelUsage | to_entries[0].value.contextWindow // 200000')
  local num_turns=$(echo "$json" | jq -r '.num_turns // 0')

  # Calculate totals
  local total_input=$((input_tokens + cache_read + cache_creation))
  local total_tokens=$((total_input + output_tokens))

  # Estimate max context: cache_creation (unique cached content) + output_tokens (accumulated responses)
  local estimated_context=$((cache_creation + output_tokens))
  local context_pct=$(echo "scale=1; ($estimated_context * 100) / $context_window" | bc)

  # Convert duration to seconds (integer for formatting)
  local duration_sec=$((duration_ms / 1000))
  local duration_api_sec=$((duration_api_ms / 1000))
  local time_str=$(format_time $duration_sec)
  local api_time_str=$(format_time $duration_api_sec)

  echo ""
  echo "┌──────────────────────────────────────────────────┐"
  printf "│  ITERATION %-2d DIAGNOSTICS                       │\n" "$iteration"
  echo "├──────────────────────────────────────────────────┤"
  printf "│  ⏱  Time:   %-10s  API: %-10s       │\n" "$time_str" "$api_time_str"
  printf "│  🔄 Turns:  %-3d                                 │\n" "$num_turns"
  echo "├──────────────────────────────────────────────────┤"
  printf "│  📥 Input:       %8d tokens               │\n" "$input_tokens"
  printf "│  📤 Output:      %8d tokens               │\n" "$output_tokens"
  printf "│  💾 Cache read:  %8d tokens               │\n" "$cache_read"
  printf "│  📝 Cache new:   %8d tokens               │\n" "$cache_creation"
  echo "├──────────────────────────────────────────────────┤"
  printf "│  📈 Context:     ~%5.1f%% of %dk               │\n" "$context_pct" "$((context_window / 1000))"
  printf "│  💰 Cost:        \$%-7.4f                      │\n" "$cost_usd"
  echo "└──────────────────────────────────────────────────┘"
}

# Function to save iteration metrics to JSON
save_iteration_metrics() {
  local json="$1"
  local iteration="$2"
  local metrics_file="$METRICS_DIR/iteration_$(printf '%03d' $iteration).json"

  # Extract values
  local duration_ms=$(echo "$json" | jq -r '.duration_ms // 0')
  local duration_api_ms=$(echo "$json" | jq -r '.duration_api_ms // 0')
  local input_tokens=$(echo "$json" | jq -r '.usage.input_tokens // 0')
  local output_tokens=$(echo "$json" | jq -r '.usage.output_tokens // 0')
  local cache_read=$(echo "$json" | jq -r '.usage.cache_read_input_tokens // 0')
  local cache_creation=$(echo "$json" | jq -r '.usage.cache_creation_input_tokens // 0')
  local cost_usd=$(echo "$json" | jq -r '.total_cost_usd // 0')
  local num_turns=$(echo "$json" | jq -r '.num_turns // 0')

  cat > "$metrics_file" <<EOF
{
  "iteration": $iteration,
  "timestamp": "$(date -Iseconds)",
  "duration_ms": $duration_ms,
  "duration_api_ms": $duration_api_ms,
  "num_turns": $num_turns,
  "input_tokens": $input_tokens,
  "output_tokens": $output_tokens,
  "cache_read_tokens": $cache_read,
  "cache_creation_tokens": $cache_creation,
  "cost_usd": $cost_usd
}
EOF
}

# Function to summarize run and update cumulative file
summarize_run() {
  local completed=$1
  local total_iterations=$2

  # Aggregate all iteration JSONs
  local total_duration_ms=0
  local total_duration_api_ms=0
  local total_input=0
  local total_output=0
  local total_cache_read=0
  local total_cache_creation=0
  local total_cost=0
  local total_turns=0
  local iteration_count=0

  for f in "$METRICS_DIR"/iteration_*.json; do
    [ -f "$f" ] || continue
    total_duration_ms=$((total_duration_ms + $(jq -r '.duration_ms // 0' "$f")))
    total_duration_api_ms=$((total_duration_api_ms + $(jq -r '.duration_api_ms // 0' "$f")))
    total_input=$((total_input + $(jq -r '.input_tokens // 0' "$f")))
    total_output=$((total_output + $(jq -r '.output_tokens // 0' "$f")))
    total_cache_read=$((total_cache_read + $(jq -r '.cache_read_tokens // 0' "$f")))
    total_cache_creation=$((total_cache_creation + $(jq -r '.cache_creation_tokens // 0' "$f")))
    total_cost=$(echo "$total_cost + $(jq -r '.cost_usd // 0' "$f")" | bc)
    total_turns=$((total_turns + $(jq -r '.num_turns // 0' "$f")))
    iteration_count=$((iteration_count + 1))
  done

  local total_time_str=$(format_time $((total_duration_ms / 1000)))
  local total_api_time_str=$(format_time $((total_duration_api_ms / 1000)))

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║            RUN SUMMARY ($RUN_ID)           ║"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  Iterations:   %-3d                              ║\n" "$iteration_count"
  printf "║  Total Time:   %-12s API: %-10s   ║\n" "$total_time_str" "$total_api_time_str"
  printf "║  Total Turns:  %-3d                              ║\n" "$total_turns"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  📥 Input:       %10d tokens             ║\n" "$total_input"
  printf "║  📤 Output:      %10d tokens             ║\n" "$total_output"
  printf "║  💾 Cache read:  %10d tokens             ║\n" "$total_cache_read"
  printf "║  📝 Cache new:   %10d tokens             ║\n" "$total_cache_creation"
  echo "╠══════════════════════════════════════════════════╣"
  printf "║  💰 Total Cost:  \$%-8.4f                     ║\n" "$total_cost"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "Metrics saved to: $METRICS_DIR"

  # Save run summary
  cat > "$METRICS_DIR/summary.json" <<EOF
{
  "run_id": "$RUN_ID",
  "completed": $completed,
  "iterations": $iteration_count,
  "total_duration_ms": $total_duration_ms,
  "total_duration_api_ms": $total_duration_api_ms,
  "total_turns": $total_turns,
  "total_input_tokens": $total_input,
  "total_output_tokens": $total_output,
  "total_cache_read_tokens": $total_cache_read,
  "total_cache_creation_tokens": $total_cache_creation,
  "total_cost_usd": $total_cost
}
EOF

  # Update cumulative file
  if [ -f "$CUMULATIVE_FILE" ]; then
    # Add to existing cumulative data
    local prev_runs=$(jq -r '.total_runs // 0' "$CUMULATIVE_FILE")
    local prev_iterations=$(jq -r '.total_iterations // 0' "$CUMULATIVE_FILE")
    local prev_duration=$(jq -r '.total_duration_ms // 0' "$CUMULATIVE_FILE")
    local prev_cost=$(jq -r '.total_cost_usd // 0' "$CUMULATIVE_FILE")
    local prev_input=$(jq -r '.total_input_tokens // 0' "$CUMULATIVE_FILE")
    local prev_output=$(jq -r '.total_output_tokens // 0' "$CUMULATIVE_FILE")

    cat > "$CUMULATIVE_FILE" <<EOF
{
  "total_runs": $((prev_runs + 1)),
  "total_iterations": $((prev_iterations + iteration_count)),
  "total_duration_ms": $((prev_duration + total_duration_ms)),
  "total_input_tokens": $((prev_input + total_input)),
  "total_output_tokens": $((prev_output + total_output)),
  "total_cost_usd": $(echo "$prev_cost + $total_cost" | bc),
  "last_run": "$RUN_ID",
  "last_updated": "$(date -Iseconds)"
}
EOF
  else
    # Create new cumulative file
    cat > "$CUMULATIVE_FILE" <<EOF
{
  "total_runs": 1,
  "total_iterations": $iteration_count,
  "total_duration_ms": $total_duration_ms,
  "total_input_tokens": $total_input,
  "total_output_tokens": $total_output,
  "total_cost_usd": $total_cost,
  "last_run": "$RUN_ID",
  "last_updated": "$(date -Iseconds)"
}
EOF
  fi
}

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"

  # Run claude with the ralph prompt and capture JSON output
  PROMPT=$(cat "$PROMPT_FILE")
  # Substitute {{CONTEXT_SECTION}} placeholder with resolved context paths
  PROMPT="${PROMPT//\{\{CONTEXT_SECTION\}\}/$CONTEXT_SECTION}"
  ITERATION_START=$(date +%s)

  JSON_OUTPUT=$(claude -p "$PROMPT" --dangerously-skip-permissions --output-format json 2>&1) || true

  # Extract and display the result text
  RESULT=$(echo "$JSON_OUTPUT" | jq -r '.result // empty' 2>/dev/null)
  if [ -n "$RESULT" ]; then
    echo ""
    echo "$RESULT"
  fi

  # Print diagnostics and save metrics
  if echo "$JSON_OUTPUT" | jq -e '.duration_ms' > /dev/null 2>&1; then
    print_diagnostics "$JSON_OUTPUT" "$i"
    save_iteration_metrics "$JSON_OUTPUT" "$i"
  else
    echo ""
    echo "⚠️  Could not parse diagnostics from output"
    echo "$JSON_OUTPUT" | head -20
  fi

  # Check for completion signal
  if echo "$RESULT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "✅ Ralph completed all tasks!"
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
