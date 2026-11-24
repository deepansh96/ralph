#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_parse_log_claude_extracts_text_and_tool_use() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"system","subtype":"init","session_id":"fake"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the file now to understand the structure."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/foo.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The file looks correct. I will make the changes."}]}}
{"type":"result","subtype":"success","result":"done"}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Reading the file now"
  assert_contains "$output" "[tool] Read: file_path=/tmp/foo.sh"
  assert_contains "$output" "[text] The file looks correct"
  [[ "$output" != *"system"* ]] || fail "expected system events to be filtered out"
  [[ "$output" != *"result"* ]] || fail "expected result events to be filtered out"
}

test_parse_log_codex_extracts_messages_and_commands() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"turn.started"}
{"type":"item.started","item":{"type":"command_execution"}}
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"agent_message","text":"All tests pass. Committing now."}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "codex" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[cmd] npm test"
  assert_contains "$output" "[text] All tests pass. Committing now."
  [[ "$output" != *"turn.started"* ]] || fail "expected turn.started to be filtered out"
  [[ "$output" != *"turn.completed"* ]] || fail "expected turn.completed to be filtered out"
  [[ "$output" != *"item.started"* ]] || fail "expected item.started to be filtered out"
}

test_parse_log_deepseek_extracts_pi_messages_and_tools() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"agent_start"}
{"type":"tool_execution_start","toolCallId":"1","toolName":"bash","args":{"command":"npm test"}}
{"type":"message_end","message":{"role":"toolResult","content":[{"type":"text","text":"tests passed"}]}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"All tests pass. Committing now."}]}}
{"type":"agent_end","messages":[]}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "deepseek" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[tool] bash: command=npm test"
  assert_contains "$output" "[text] All tests pass. Committing now."
  [[ "$output" != *"tests passed"* ]] || fail "expected tool result messages to be filtered out"
  [[ "$output" != *"agent_end"* ]] || fail "expected agent_end to be filtered out"
}

test_parse_log_gemini_extracts_agy_text_and_tools() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"event":"init","conversation_id":"c1","init":{"model":"gemini-4-neon","tools":["run_command"]}}
{"event":"step_update","step_update":{"step_index":0,"state":"DONE","step_type":"user_input"}}
{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"Blocking":true,"CommandLine":"npm test"}}}}
{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"npm test"},"output":"tests passed"}}}
{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"All tests pass. Committing now."}}
{"event":"step_update","step_update":{"step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"\n"}}
{"event":"result","result":{"status":"SUCCESS","response":"All tests pass. Committing now.\n"}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "gemini" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[tool] run_command: CommandLine=npm test"
  assert_contains "$output" "[text] All tests pass. Committing now."
  [[ "$output" != *"tests passed"* ]] || fail "expected tool output to be filtered out"
  [[ "$(grep -c '\[tool\]' <<<"$output")" -eq 1 ]] || fail "expected one line per tool call"
  [[ "$(grep -c '\[text\]' <<<"$output")" -eq 1 ]] || fail "expected blank text deltas and the result event to be filtered out"
}

test_parse_log_empty_file_shows_starting() {
  local log_file output

  log_file="$(mktemp)"
  : > "$log_file"

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "Starting..."

  output="$(parse_log "/nonexistent/file/does/not/exist" "claude" 10)"
  assert_contains "$output" "Starting..."
}

test_parse_log_partial_write_skips_truncated_lines() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"Valid line before truncation."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Trun
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Valid line before truncation."
  [[ "$output" != *"Trun"* ]] || fail "expected truncated line to be skipped"
}

run_test test_parse_log_claude_extracts_text_and_tool_use
run_test test_parse_log_codex_extracts_messages_and_commands
run_test test_parse_log_deepseek_extracts_pi_messages_and_tools
run_test test_parse_log_gemini_extracts_agy_text_and_tools
run_test test_parse_log_empty_file_shows_starting
run_test test_parse_log_partial_write_skips_truncated_lines

echo "parse_log_test.sh passed"
