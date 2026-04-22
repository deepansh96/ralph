# Implementation Plan: Codex CLI Support for Ralph

## Overview

Add support for OpenAI's Codex CLI as an alternative agent backend in Ralph, alongside the existing Claude Code integration. Users will pass `--agent codex` to use Codex, `--agent claude` to explicitly use Claude, or `--agent auto` (default) to auto-detect whichever CLI is available on PATH, preferring Claude.

**Why:** Ralph currently only works with Claude Code. Adding Codex support makes Ralph agent-agnostic, allowing teams to choose their preferred coding agent or switch between them. The sibling project `pral` already has working Codex support, providing a proven reference implementation.

---

## Current State

### How ralph.sh Works Today (Claude-Only)

**Invocation (line 358):**
```bash
JSON_OUTPUT=$(claude -p "$PROMPT" --dangerously-skip-permissions --output-format json 2>&1) || true
```

- Prompt passed as `-p` string argument
- `--dangerously-skip-permissions` bypasses approval prompts for autonomous operation
- `--output-format json` returns a single JSON object with all metrics
- stderr merged with stdout via `2>&1` (can corrupt JSON parsing — this change fixes that)

**Claude JSON output shape:**
```json
{
  "result": "...",
  "duration_ms": 45000,
  "duration_api_ms": 30000,
  "usage": {
    "input_tokens": 15000,
    "output_tokens": 3000,
    "cache_read_input_tokens": 12000,
    "cache_creation_input_tokens": 5000
  },
  "total_cost_usd": 0.0842,
  "num_turns": 12,
  "modelUsage": { "model": { "contextWindow": 200000 } }
}
```

**Key characteristics:**
1. Main loop (lines 345-395) calls `claude` inline — no function abstraction
2. Prompt passed as `-p` argument (not stdin)
3. Output is a single JSON object, not a stream
4. All metrics come from that one object
5. Result text extracted via `.result` field
6. Completion signal detected by grepping result for `<promise>COMPLETE</promise>`

### Agent Prompt (`prompts/agent.md`) — Provider-Specific Sections

The current prompt contains Claude-specific sections that must be addressed:
- **Lines 38-49:** Session ID discovery using `~/.claude/projects/` paths and `claude --resume` references
- **Line 70:** References `CLAUDE.md` as Claude Code context (though `CLAUDE.md` is a project convention file used by both agents)
- **Line 172:** "Read `CLAUDE.md`" instruction

These won't break Codex but will cause wasted effort (attempting Claude session discovery) and misleading progress entries.

---

## Claude vs Codex Comparison

| Aspect | Claude Code CLI | Codex CLI |
|--------|----------------|-----------|
| **CLI command** | `claude -p "$prompt"` | `printf "%s" "$prompt" \| codex exec ... -` |
| **Prompt delivery** | `-p` flag (string argument) | Piped via stdin (`-` sentinel) |
| **Non-interactive mode** | Always non-interactive with `-p` | Requires `exec` subcommand |
| **Permission bypass** | `--dangerously-skip-permissions` | `-a never --sandbox workspace-write` |
| **Output format flag** | `--output-format json` | `--json` (JSONL stream) |
| **Output structure** | Single JSON object | Newline-delimited JSON events |
| **Result text** | `.result` field in JSON | `--output-last-message <file>` |
| **Token usage location** | Top-level `.usage` object | Aggregated from `turn.completed` events |
| **Cache read field** | `.usage.cache_read_input_tokens` | `.usage.cached_input_tokens` |
| **Cache creation field** | `.usage.cache_creation_input_tokens` | Not available |
| **Cost** | `.total_cost_usd` | Not available |
| **API duration** | `.duration_api_ms` | Not available |
| **Wall-clock duration** | `.duration_ms` | Must be measured externally |
| **Turn count** | `.num_turns` | Count `turn.completed` events |
| **Context window** | `.modelUsage[].contextWindow` | Not available |
| **stderr behavior** | Currently merged via `2>&1` | Separate (progress on stderr) |

---

## Codex CLI Reference

### Invocation Pattern (from pral.sh)
```bash
printf "%s" "$prompt" | codex -a never exec \
    --skip-git-repo-check \
    --sandbox workspace-write \
    --json \
    --output-last-message "$last_message_file" \
    --enable multi_agent \
    -
```

### Key Flags

| Flag | Rationale |
|------|-----------|
| `exec` | Non-interactive mode (required for scripting) |
| `-a never` | Skip all approval prompts — equivalent to Claude's `--dangerously-skip-permissions` |
| `--sandbox workspace-write` | Allow file writes within workspace. Safer than `danger-full-access` |
| `--skip-git-repo-check` | Allow running in unusual directory structures |
| `--json` | Output JSONL event stream to stdout |
| `--output-last-message <path>` | Write final assistant message to file (only way to get result text with `--json`) |
| `-` (positional) | Read prompt from stdin |

### Optional Flags (Configurable)

| Flag | Notes |
|------|-------|
| `--enable multi_agent` | Enable sub-agent spawning. Used by pral. Requires recent Codex CLI versions. On by default; disable with Ralph's `--no-multi-agent` CLI flag. |

**Why not `--full-auto`?** Sets approval to `on-request` (not `never`), which could still pause. Explicit `-a never` is more predictable for autonomous operation.

### JSONL Output Format

Stdout becomes newline-delimited JSON events:
```jsonl
{"type":"thread.started","thread_id":"..."}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}
```

Token usage is in `turn.completed` events under `.usage`. Must be aggregated across all turns.

---

## Normalized Metrics Contract

Both `run_claude()` and `run_codex()` set two globals:

```bash
RESULT=""          # final assistant text for display and completion detection
METRICS_JSON=""    # normalized JSON object for diagnostics and persistence
```

Normalized `METRICS_JSON` shape:

```json
{
  "provider": "claude",
  "duration_ms": 12345,
  "duration_api_ms": 10000,
  "num_turns": 3,
  "input_tokens": 1000,
  "output_tokens": 500,
  "cache_read_tokens": 200,
  "cache_creation_tokens": 50,
  "context_window": 200000,
  "cost_usd": 0.1234
}
```

For Codex, unavailable fields use `null`, except `cache_creation_tokens` which uses `0`:

```json
{
  "provider": "codex",
  "duration_ms": 12345,
  "duration_api_ms": null,
  "num_turns": 3,
  "input_tokens": 1000,
  "output_tokens": 500,
  "cache_read_tokens": 200,
  "cache_creation_tokens": 0,
  "context_window": null,
  "cost_usd": null
}
```

**Null vs zero convention:** Fields that represent a genuinely unknown measurement (`cost_usd`, `duration_api_ms`, `context_window`) are `null`. Token subcategories that the provider doesn't track (`cache_creation_tokens` for Codex) use `0` because they participate in arithmetic (token totals, context percentage) and null would propagate incorrectly.

**`context_window` for Claude:** When Claude's JSON is missing `modelUsage`, the fallback is `200000` (Claude's default). This is a Claude-only legacy fallback, not a universal assumption. Codex always gets `null`.

This contract avoids passing provider-specific raw output into display and summary functions.

---

## Implementation Steps

### Step 1: Add `--agent` Flag Parsing and `usage()` Helper

Add a `usage()` function to avoid duplicating usage text, and add `--agent` parsing alongside existing `--prd` and `--context`:

```bash
# New variables (near line 27)
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

# New cases in the while loop
    --agent)
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
```

Update the `--prd` missing error to use `usage`:
```bash
if [ -z "$PRD_NAME" ]; then
  echo "Error: --prd <name> is required"
  usage
fi
```

Update the header comment:
```bash
# Usage: ./ralph.sh --prd <name> [--agent auto|claude|codex] [options] [max_iterations] [prompt_file]
#
# Required:
#   --prd <name>      Feature/workspace name (e.g., "my-feature")
#
# Options:
#   --agent <mode>      Agent backend: auto (default), claude, or codex
#                       auto prefers claude when available, then codex.
#   --context <path>    Add context file or directory (repeatable)
#   --no-multi-agent    Disable Codex multi-agent sub-spawning
```

### Step 2: Dependency and Agent Validation

Add startup checks for required dependencies and agent selection:

```bash
# Dependency checks (after argument parsing, before workspace setup)
for cmd in jq bc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: Required dependency '$cmd' is not available on PATH"
    exit 1
  }
done

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
```

Call `select_agent` after `resolve_context` and validations, before startup banner. Add to banner:
```bash
echo "Agent: $SELECTED_AGENT"
```

### Step 3: Add Utility Helpers

Add nullable-safe helpers for metrics handling:

```bash
is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

json_number_or_null() {
  local value="${1:-}"
  if is_number "$value"; then
    printf "%s" "$value"
  else
    printf "null"
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
```

### Step 4: Extract Claude Execution into `run_claude()`

Move inline Claude code into a function. Important improvement: separate stdout/stderr (current code merges them via `2>&1` which can corrupt JSON parsing).

```bash
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
```

Note: The `context_window` fallback of `200000` is Claude-specific (its standard context window). This preserves current behavior for Claude diagnostics display.

### Step 5: Create `run_codex()` Function

Pattern from pral.sh's `run_step_codex()`. The `--enable multi_agent` flag is controlled by the `--no-multi-agent` CLI flag (on by default):

```bash
run_codex() {
  local prompt="$1"
  local iteration="$2"
  local stdout_file stderr_file last_message_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  last_message_file=$(mktemp)

  # Build Codex flags
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

  # Parse JSONL events for metrics
  local usage_json
  if [ -s "$stdout_file" ]; then
    usage_json=$(jq -s '
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
      )' "$stdout_file" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$usage_json" ]; then
      echo "Warning: Could not parse Codex JSONL output"
      sed -n '1,20p' "$stdout_file"
      usage_json=""
    fi
  else
    usage_json=""
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
```

### Step 6: Add Dispatch Wrapper and Update Main Loop

```bash
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
```

Replace the inline Claude block in the main loop:
```bash
for i in $(seq 1 $MAX_ITERATIONS); do
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

  # Print diagnostics and save metrics (provider-agnostic)
  if [ -n "$METRICS_JSON" ] && echo "$METRICS_JSON" | jq -e '.duration_ms' > /dev/null 2>&1; then
    print_diagnostics "$METRICS_JSON" "$i"
    save_iteration_metrics "$METRICS_JSON" "$i"
  else
    echo ""
    echo "Warning: Could not parse diagnostics from output"
  fi

  # Check for completion signal (works for both agents)
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
```

### Step 7: Adapt Diagnostics to Normalized Metrics

Update `print_diagnostics()` to read from the normalized shape, using `is_number` guards for nullable fields:

```bash
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

  # Context percentage (Claude only — Codex does not expose context window)
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
```

### Step 8: Update Per-Iteration Metrics Persistence

Use `jq` to write metrics files instead of heredoc interpolation (avoids null/quoting issues):

```bash
save_iteration_metrics() {
  local json="$1"
  local iteration="$2"
  local metrics_file="$METRICS_DIR/iteration_$(printf '%03d' $iteration).json"

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
      cost_usd: .cost_usd
    }' > "$metrics_file"
}
```

### Step 9: Update Run Summaries for Null Cost

Track whether all iterations have cost data. Use `is_number` guards for all nullable arithmetic fields:

```bash
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

    # Nullable: API duration
    local iter_api_dur
    iter_api_dur=$(jq -r '.duration_api_ms // empty' "$f")
    if is_number "$iter_api_dur"; then
      total_duration_api_ms=$((total_duration_api_ms + iter_api_dur))
    else
      api_duration_available=false
    fi

    # Nullable: cost
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

  # Save run summary (use jq to handle nulls correctly)
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg provider "$SELECTED_AGENT" \
    --argjson completed "$completed" \
    --argjson iterations "$iteration_count" \
    --argjson total_duration_ms "$total_duration_ms" \
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
      total_turns: $total_turns,
      total_input_tokens: $total_input,
      total_output_tokens: $total_output,
      total_cache_read_tokens: $total_cache_read,
      total_cache_creation_tokens: $total_cache_creation,
      total_cost_usd: $cost_usd,
      cost_metrics_complete: $cost_complete
    }' > "$METRICS_DIR/summary.json"

  # Update cumulative file (see Cumulative File Migration section for handling existing files)
  # ... update logic with cost_metrics_complete and last_provider tracking
}
```

### Cumulative File Migration

When updating the cumulative file, handle pre-existing files that lack `cost_metrics_complete`:

```bash
# Reading existing cumulative file
if [ -f "$CUMULATIVE_FILE" ]; then
  local prev_cost_complete
  prev_cost_complete=$(jq -r '.cost_metrics_complete // empty' "$CUMULATIVE_FILE")
  
  # Migration: treat absent cost_metrics_complete as true only when total_cost_usd is numeric
  if [ -z "$prev_cost_complete" ] || [ "$prev_cost_complete" = "null" ]; then
    local prev_cost_val
    prev_cost_val=$(jq -r '.total_cost_usd // empty' "$CUMULATIVE_FILE")
    if is_number "$prev_cost_val"; then
      prev_cost_complete=true
    else
      prev_cost_complete=false
    fi
  fi
  
  # If either previous or current run lacks cost, mark cumulative as incomplete
  if [ "$prev_cost_complete" != "true" ] || [ "$cost_metrics_complete" != "true" ]; then
    cumulative_cost_complete=false
  fi
  
  # ... rest of cumulative update
fi
```

Cumulative file target shape:
```json
{
  "total_runs": 4,
  "total_iterations": 12,
  "total_duration_ms": 123456,
  "total_input_tokens": 100000,
  "total_output_tokens": 50000,
  "total_cost_usd": null,
  "cost_metrics_complete": false,
  "last_provider": "codex",
  "last_run": "20260422_120000",
  "last_updated": "2026-04-22T12:05:00+00:00"
}
```

### Step 10: Make Agent Prompt Provider-Aware

Update `prompts/agent.md` to handle the session ID section gracefully for non-Claude agents:

**Change the "Getting Session ID" section (lines 38-49) to be conditional:**

Replace:
```markdown
**Getting Session ID**: Run this command to get your current session ID:
```bash
# macOS
project_encoded=$(pwd | tr '/' '-' | sed 's/^-//')
session_file=$(stat -f '%m %N' ~/.claude/projects/-${project_encoded}/*.jsonl 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
basename "$session_file" .jsonl
```

Include the session ID so future iterations can resume context if needed using `claude --resume <session-id>`.
```

With:
```markdown
**Getting Session ID (Claude Code only)**: If running under Claude Code, capture your session ID for potential resume:
```bash
# macOS — skip this if not running under Claude Code
project_encoded=$(pwd | tr '/' '-' | sed 's/^-//')
session_file=$(stat -f '%m %N' ~/.claude/projects/-${project_encoded}/*.jsonl 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
basename "$session_file" .jsonl 2>/dev/null || echo "no-session"
```

If a session ID is available, include it in the progress entry. Otherwise, write `Session: n/a`.
```

**Update progress report template (line 27):**
```
Session: <session-id or n/a>
```

**Clarify CLAUDE.md references (line 70, 172):**

`CLAUDE.md` is a project convention file, not specific to Claude Code. Both Claude and Codex should read it. The references are correct as-is; no change needed here. Add a one-line clarification to the prompt:

```markdown
4. Read `CLAUDE.md` at the project root (project-wide patterns, commands, and quality checks — this is a project convention file, not agent-specific)
```

### Step 11: Update Documentation

**ralph.sh header:** Updated in Step 1.

**CLAUDE.md:** Add `--agent` to the Commands section:
```bash
./ralph/ralph.sh --prd my-feature 15 --agent codex              # Use Codex
./ralph/ralph.sh --prd my-feature 15 --agent auto               # Auto-detect (default)
```

**README.md:**
- Document `--agent auto|claude|codex` flag
- List required Codex CLI version/features: `codex exec`, `--json`, `--output-last-message`, `--sandbox workspace-write`
- Note that `--enable multi_agent` is on by default and can be disabled with `--no-multi-agent`
- Document cost tracking differences (Codex shows "n/a" for cost)
- Note that `CLAUDE.md` is a project convention file used by both agents

---

## Recommended Function Layout in ralph.sh

```
1. Defaults and argument parsing
2. usage() helper
3. Utility helpers: is_number, json_number_or_null, format_time, format_optional_time, empty_metrics_json
4. resolve_context
5. Dependency checks (jq, bc)
6. Workspace validation
7. select_agent
8. Startup banner
9. Metrics functions: print_diagnostics, save_iteration_metrics, summarize_run
10. Agent runners: run_claude, run_codex, run_agent
11. Main iteration loop
```

This keeps agent-specific code isolated and metrics code provider-agnostic.

---

## Edge Cases

### 1. Missing CLI
- `--agent claude` + no `claude` on PATH: fail before execution
- `--agent codex` + no `codex` on PATH: fail before execution
- `--agent auto` + neither: fail with clear message listing both
- `--agent auto` + both: choose Claude (matches pral)

### 2. Non-Zero Exit from Agent
Both agents can exit non-zero (timeout, API error, etc.). Use `if !` pattern (not `|| true`) so `set -e` doesn't kill the script. Always attempt to extract whatever output was produced — partial results and metrics are still valuable.

### 3. Empty/Invalid Codex JSONL Output
- Empty stdout: skip JSONL parsing entirely, use `empty_metrics_json`
- Invalid JSONL (jq parse failure): warn, print first 20 lines of stdout for debugging, use `empty_metrics_json`
- Missing last-message file: `RESULT=""`, completion won't trigger, iteration continues with warning

### 4. Large Prompts
Claude's `-p` flag passes prompt as command-line argument (OS limit ~256KB on macOS). Codex's stdin approach avoids this. Not a new problem for Claude, but worth noting Codex handles it better.

### 5. Mixed-Provider Cost Tracking
If user switches agents between runs, cumulative metrics have partial cost data. Track `cost_metrics_complete: false` and display "n/a" rather than misleading `$0.0000`. Never add null cost as zero.

### 6. Context Window Percentage for Codex
Codex JSONL does not expose context window size. Display `Context: n/a` for Codex rather than assuming a model window.

### 7. Current Working Directory
Ralph derives `PROJECT_ROOT="$(pwd)"` and invokes Claude without changing directories. Keep this for both agents. Do not run Codex from `$RALPH_DIR` unless it's also the project root, because the agent needs to edit the user's project files.

### 8. Temporary File Cleanup
Use `mktemp` for stdout, stderr, and last-message files. Always `rm -f` before returning from runner functions. A future hardening pass could add a `trap` to clean up on unexpected exits.

### 9. `set -e` Interaction
Ralph uses `set -e`. Agent invocations must be inside `if ! command; then ... fi` blocks so non-zero exits don't terminate the script before diagnostics and partial result extraction run.

### 10. Prompt Compatibility
The agent prompt (`prompts/agent.md`) has Claude-specific session ID discovery that must be made conditional (see Step 10). The core workflow (read PRD, implement story, run checks, commit, emit completion signal) is agent-agnostic. Both Claude and Codex will follow the `<promise>COMPLETE</promise>` instruction.

### 11. Cumulative File Backward Compatibility
Existing cumulative files lack `cost_metrics_complete` and `last_provider`. The migration rule: treat absent `cost_metrics_complete` as `true` only when `total_cost_usd` is numeric (see Cumulative File Migration section).

---

## Testing Plan

### 1. Static Checks
```bash
bash -n ralph.sh
shellcheck ralph.sh  # if available
```

### 2. Argument Parsing
```bash
./ralph.sh --prd test --agent claude 1
./ralph.sh --prd test --agent=codex 1
./ralph.sh --prd test --agent auto 1
./ralph.sh --prd test --agent nope 1   # expect: "Error: Invalid --agent value"
./ralph.sh --prd test 1                 # expect: auto (default)
```

### 3. Fake CLI Smoke Tests

Create temp directory with fake `claude` and `codex` scripts on PATH to avoid spending real tokens:

**Fake Claude** — prints single JSON object:
```json
{
  "result": "working\n<promise>COMPLETE</promise>",
  "duration_ms": 1000,
  "duration_api_ms": 800,
  "num_turns": 1,
  "usage": {
    "input_tokens": 10,
    "output_tokens": 5,
    "cache_read_input_tokens": 2,
    "cache_creation_input_tokens": 1
  },
  "total_cost_usd": 0.01,
  "modelUsage": { "x": { "contextWindow": 200000 } }
}
```

**Fake Codex** — parses `--output-last-message <file>` from args, writes result to that file, prints JSONL to stdout:
```jsonl
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":2}}
{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3,"cached_input_tokens":1}}
```

**Expected Claude normalized metrics:**
- `input_tokens`: 10
- `output_tokens`: 5
- `cache_read_tokens`: 2
- `cache_creation_tokens`: 1
- `num_turns`: 1
- `cost_usd`: 0.01
- `duration_api_ms`: 800
- `context_window`: 200000

**Expected Codex metrics after aggregation:**
- `input_tokens`: 17
- `output_tokens`: 8
- `cache_read_tokens`: 3
- `cache_creation_tokens`: 0
- `num_turns`: 2
- `cost_usd`: null
- `duration_api_ms`: null
- `context_window`: null

**Verify for both agents:**
- Correct agent is selected and invoked
- Metrics match expected values above
- Completion signal is detected
- Codex cost shows "n/a", Claude cost shows "$0.0100"

### 4. Completion Signal Tests

**Positive case:** Include `<promise>COMPLETE</promise>` in fake output. Verify Ralph exits 0 with "completed all tasks" message before max iterations.

**Negative case:** Omit `<promise>COMPLETE</promise>` from fake output. Verify Ralph continues to max iterations and exits 1 with "reached max iterations" message.

Test both cases for both agents.

### 5. Real Single-Iteration Tests
```bash
# Create minimal test workspace first
mkdir -p ralph/workspaces/smoke-test
cat > ralph/workspaces/smoke-test/prd.json << 'EOF'
{
  "name": "smoke-test",
  "branchName": "main",
  "stories": [
    {
      "id": "S1",
      "title": "Test story",
      "passes": false,
      "tasks": ["Create a test file"]
    }
  ]
}
EOF

./ralph/ralph.sh --prd smoke-test --agent codex 1
./ralph/ralph.sh --prd smoke-test --agent claude 1
```

### 6. Metrics File Verification
```bash
# After a Codex run:
jq . workspaces/smoke-test/runs/*/iteration_001.json
# Verify: provider is "codex", cost_usd is null, token totals are non-zero

# After a Claude run:
jq . workspaces/smoke-test/runs/*/iteration_001.json
# Verify: provider is "claude", cost_usd is numeric, matches old behavior
```

### 7. Regression: Claude Semantics Preserved
```bash
./ralph.sh --prd test 1 ./ralph/test_prompt.md --agent claude
```
Verify: result display, completion detection, token/cost metrics, and summaries work identically to current behavior. Note that stderr handling is intentionally improved (separated from stdout), so raw output may differ, but all user-visible behavior and metrics should match.

### 8. Diagnostics Box Visual Check
Run both agents and visually verify the diagnostics box renders correctly with proper alignment for:
- Provider label in header
- "n/a" for Codex cost, API time, and context
- Dollar values for Claude cost
- All column widths remain consistent

---

## Acceptance Criteria

- [ ] `./ralph.sh --prd <name> --agent claude` preserves Claude semantics (result display, completion detection, metrics, summaries)
- [ ] `./ralph.sh --prd <name> --agent codex` invokes Codex with stdin prompt, workspace-write sandbox, JSONL output, and `--output-last-message`
- [ ] `./ralph.sh --prd <name> --agent auto` chooses Claude first, then Codex
- [ ] `./ralph.sh --prd <name>` (no --agent) defaults to auto
- [ ] Invalid `--agent` values produce clear error messages
- [ ] Main loop has no inline provider-specific invocation
- [ ] Both agents use the normalized `METRICS_JSON` contract
- [ ] Completion detection works for both providers using `RESULT`
- [ ] Iteration metrics include `provider` field
- [ ] Codex metrics are correctly aggregated from `turn.completed` events
- [ ] Codex `cost_usd` and API duration stored as JSON `null`, displayed as `n/a`
- [ ] Run summaries and cumulative metrics do not treat missing Codex cost as `$0.0000`
- [ ] Cumulative file migration handles pre-existing files without `cost_metrics_complete`
- [ ] Invalid Codex JSONL output produces a warning and stdout preview, not silent failure
- [ ] `--enable multi_agent` is on by default, disabled via `--no-multi-agent` CLI flag
- [ ] `prompts/agent.md` session ID section is conditional (Claude Code only)
- [ ] `jq` and `bc` are checked at startup
- [ ] Temporary files are cleaned up
- [ ] Claude stderr is no longer merged with stdout
- [ ] `bash -n ralph.sh` passes
- [ ] `usage()` helper prevents usage string drift

---

## File Changes Summary

| File | Changes |
|------|---------|
| `ralph.sh` | Add `--agent` and `--no-multi-agent` flags, `usage()` helper, dependency checks, `select_agent()`, utility helpers (`is_number`, `json_number_or_null`, `format_optional_time`, `empty_metrics_json`), `run_claude()` (extracted + stderr fix), `run_codex()` (new), `run_agent()` dispatcher, update `print_diagnostics`/`save_iteration_metrics`/`summarize_run` for normalized metrics with nullable field handling, cumulative file migration, update startup banner |
| `prompts/agent.md` | Make session ID section conditional ("Claude Code only"), add `2>/dev/null` fallback, clarify `CLAUDE.md` is a project convention file |
| `README.md` | Document `--agent` flag, Codex CLI requirements and recommended version, cost tracking differences, `CODEX_EXTRA_FLAGS` configuration |
| `CLAUDE.md` | Add `--agent` to Commands section |

**Estimated scope:** ~250 lines of new/refactored code in `ralph.sh`, ~10 lines changed in `prompts/agent.md`. No new files needed.
