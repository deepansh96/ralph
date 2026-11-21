#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

export GIT_AUTHOR_NAME="Ralph Test" GIT_AUTHOR_EMAIL="ralph@example.com"
export GIT_COMMITTER_NAME="Ralph Test" GIT_COMMITTER_EMAIL="ralph@example.com"

UUID_GRILLING="11111111-1111-4111-8111-111111111111"
UUID_ANSWERING="22222222-2222-4222-8222-222222222222"
THREAD_GRILLING="019a0000-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
THREAD_ANSWERING="019a0000-bbbb-7bbb-8bbb-bbbbbbbbbbbb"
REQUIREMENT_TEXT=$'# Offline Export\n\nUsers need to export reports offline.'
REQUIREMENT_SHA256="04870b16254c43c51e6e243932fb6791ff6028191de64f8b8c12472d4ce9f1b9"

GRILL_TMP=""
GRILL_REPO=""
GRILL_RALPH=""
GRILL_SESSIONS=""
REQUIREMENT_FILE=""

# Builds a temporary target repository with a local bare remote and a Ralph
# install at <repo>/ralph (symlinked to this checkout), plus fake claude,
# codex, uuidgen and gh on PATH. Both fake Agents read the same exchange
# fixtures.
setup_grill_repo() {
  GRILL_TMP="$(mktemp -d)"
  GRILL_REPO="$GRILL_TMP/repo"

  git init -q --bare -b main "$GRILL_TMP/remote.git"
  git init -q -b main "$GRILL_REPO"
  mkdir -p "$GRILL_REPO/ralph"
  ln -s "$ROOT_DIR/ralph.sh" "$GRILL_REPO/ralph/ralph.sh"
  ln -s "$ROOT_DIR/scripts" "$GRILL_REPO/ralph/scripts"
  ln -s "$ROOT_DIR/prompts" "$GRILL_REPO/ralph/prompts"
  ln -s "$ROOT_DIR/skills" "$GRILL_REPO/ralph/skills"
  cp "$ROOT_DIR/ralph.config.json" "$GRILL_REPO/ralph/ralph.config.json"
  printf '# Target project\n' > "$GRILL_REPO/README.md"
  git -C "$GRILL_REPO" add -A
  git -C "$GRILL_REPO" commit -q -m "Initial commit"
  git -C "$GRILL_REPO" remote add origin "$GRILL_TMP/remote.git"
  git -C "$GRILL_REPO" push -q -u origin main
  git -C "$GRILL_REPO" remote set-head origin main

  GRILL_RALPH="$GRILL_REPO/ralph/ralph.sh"
  GRILL_SESSIONS="$GRILL_REPO/ralph/grilling-sessions"
  REQUIREMENT_FILE="$GRILL_TMP/offline-export.md"
  printf '%s\n' "$REQUIREMENT_TEXT" > "$REQUIREMENT_FILE"

  install_fake_grill_claude "$GRILL_TMP/bin"
  install_fake_grill_codex "$GRILL_TMP/bin"
  install_fake_uuidgen "$GRILL_TMP/bin"
  install_fake_grill_gh "$GRILL_TMP/bin"
  export FAKE_CLAUDE_DIR="$GRILL_TMP/claude"
  export CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_DIR/config"
  export FAKE_CODEX_DIR="$GRILL_TMP/codex"
  export CODEX_HOME="$FAKE_CODEX_DIR/home"
  export FAKE_CODEX_THREAD_QUEUE="$GRILL_TMP/threads"
  export FAKE_UUID_QUEUE="$GRILL_TMP/uuids"
  export FAKE_GH_LOG="$GRILL_TMP/gh.log"
  export FAKE_GH_ISSUE_JSON='{"title":"Add Dark Mode!","body":"Readers want a dark theme."}'
  unset FAKE_CLAUDE_HELP_OMIT FAKE_CODEX_HELP_OMIT FAKE_CODEX_NO_READ_ONLY_NETWORK
  printf '%s\n%s\n' "$UUID_GRILLING" "$UUID_ANSWERING" > "$FAKE_UUID_QUEUE"
  printf '%s\n%s\n' "$THREAD_GRILLING" "$THREAD_ANSWERING" > "$FAKE_CODEX_THREAD_QUEUE"
  mkdir -p "$FAKE_CLAUDE_DIR/exchanges" "$FAKE_CODEX_DIR"
  ln -s "$FAKE_CLAUDE_DIR/exchanges" "$FAKE_CODEX_DIR/exchanges"
  : > "$FAKE_GH_LOG"
  queue_minimal_run
}

# Scripts the result text the fake claude returns for one exchange ID.
exchange_fixture() {
  printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/exchanges/$1.json"
}

# Scripts a shell side effect the fake claude runs in its working directory
# before answering one exchange ID.
exchange_effect() {
  printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/exchanges/$1.sh"
}

summary_fixture() {
  jq -n -c --arg id "$1" --arg summary "$2" \
    '{exchangeId: $id, decisionSummary: $summary, issueTitle: "Offline export", issueBody: "Export reports offline."}'
}

# The shortest run to the confirmation gate: an empty first Frontier, then the
# closing exchanges.
queue_minimal_run() {
  exchange_fixture ex-0003 '{"exchangeId":"ex-0003","round":1,"questions":[],"reopens":[]}'
  exchange_fixture ex-0004 "$(summary_fixture ex-0004 "- Nothing to decide.")"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","faithful":true,"discrepancies":[]}'
  exchange_fixture ex-0006 "$(summary_fixture ex-0006 "- Nothing to decide.")"
}

# Two Frontier rounds (the second reopens a decision), an empty Frontier, and
# the closing exchanges. The first round edits CONTEXT.md inline.
queue_two_round_run() {
  exchange_effect ex-0003 'printf "# Context\n\n**Offline Export**: a report saved for offline reading.\n" > CONTEXT.md'
  exchange_fixture ex-0003 '{"exchangeId":"ex-0003","round":1,
    "questions":[
      {"id":"storage-backend","title":"Where are exports stored?","body":"Pick the storage backend.",
       "choices":[{"id":"sqlite","label":"SQLite","description":"Local file"},
                  {"id":"postgres","label":"Postgres","description":"Server database"}],
       "recommendation":{"choiceId":"sqlite","rationale":"No server exists yet."}},
      {"id":"export-format","title":"Which format?","body":"Pick the export format.",
       "choices":[{"id":"csv","label":"CSV","description":"Plain text"}],
       "recommendation":{"choiceId":"csv","rationale":"Spreadsheets open it."}}],
    "reopens":[]}'
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["https://example.com/csv"]}]}'
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","round":2,
    "questions":[
      {"id":"sync-mode","title":"How do exports sync?","body":"Pick the sync mode.",
       "choices":[{"id":"manual","label":"Manual","description":"User triggers sync"}],
       "recommendation":{"choiceId":"manual","rationale":"Simplest."}}],
    "reopens":[{"questionId":"storage-backend","contradiction":"README says exports are shared across devices.","evidence":["README.md"]}]}'
  exchange_fixture ex-0006 '{"exchangeId":"ex-0006","answers":[
      {"questionId":"sync-mode","choiceId":"manual","rationale":"No background jobs exist.","evidence":["README.md"]},
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"Shared exports need a server.","evidence":["README.md"]}]}'
  exchange_fixture ex-0007 '{"exchangeId":"ex-0007","round":3,"questions":[],"reopens":[]}'
  exchange_fixture ex-0008 "$(summary_fixture ex-0008 "- Draft summary: SQLite storage.")"
  exchange_fixture ex-0009 '{"exchangeId":"ex-0009","faithful":false,
    "discrepancies":[{"questionId":"storage-backend","problem":"Summary says SQLite.","fix":"Say Postgres."}]}'
  exchange_fixture ex-0010 "$(jq -n -c '{exchangeId: "ex-0010",
    decisionSummary: "- Storage: Postgres (reopened).\n- Format: CSV.\n- Sync: manual.",
    issueTitle: "Export reports offline with Postgres storage",
    issueBody: "Readers export CSV reports stored in Postgres."}')"
}

teardown_grill_repo() {
  rm -rf "${GRILL_TMP:?}"
}

# Runs ralph.sh grill from the target repository with fakes first on PATH.
grill() {
  (cd "$GRILL_REPO" && PATH="$GRILL_TMP/bin:$PATH" "$GRILL_RALPH" grill "$@")
}

claude_call_count() {
  find "$FAKE_CLAUDE_DIR/calls" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

claude_argv() {
  cat "$FAKE_CLAUDE_DIR/calls/$1/argv.json"
}

claude_flag_value() {
  jq -r --arg flag "$2" '. as $a | [range(0; length) | select($a[.] == $flag) | $a[. + 1]] | first // ""' \
    "$FAKE_CLAUDE_DIR/calls/$1/argv.json"
}

codex_call_count() {
  find "$FAKE_CODEX_DIR/calls" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

codex_argv() {
  cat "$FAKE_CODEX_DIR/calls/$1/argv.json"
}

codex_prompt() {
  cat "$FAKE_CODEX_DIR/calls/$1/stdin"
}

# Prints the argument after `exec resume` and its options: the resumed thread.
codex_resumed_thread() {
  jq -r '(index("resume") // -1) as $r | if $r < 0 then "" else
    [.[($r + 1):][] ] as $rest
    | [range(0; $rest | length) as $i
       | select(($rest[$i] | startswith("-") | not)
                and ($i == 0 or (($rest[$i - 1] | IN("--output-schema", "-o", "-c", "-m")) | not)))
       | $rest[$i]] | first // "" end' "$FAKE_CODEX_DIR/calls/$1/argv.json"
}

session_count() {
  find "$GRILL_SESSIONS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

only_session_dir() {
  find "$GRILL_SESSIONS" -mindepth 1 -maxdepth 1 -type d | head -n 1
}

expect_start_failure() {
  local expected="$1"
  shift
  local output status

  set +e
  output="$(grill start "$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected grill start $* to fail"
  assert_contains "$output" "$expected"
  [[ "$(session_count)" == "0" ]] || fail "expected no Grilling Session Record for: $*"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no native session for: $*"
  [[ "$(codex_call_count)" == "0" ]] || fail "expected no native codex session for: $*"
}

test_start_rejects_invalid_inputs() {
  setup_grill_repo

  expect_start_failure "exactly one of --issue or --requirement-file" \
    --issue 7 --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude
  expect_start_failure "exactly one of --issue or --requirement-file" \
    --grilling-agent claude --answering-agent claude
  expect_start_failure "--grilling-agent is required" \
    --requirement-file "$REQUIREMENT_FILE" --answering-agent claude
  expect_start_failure "--answering-agent is required" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude
  expect_start_failure "unsupported --answering-agent 'deepseek'" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent deepseek
  expect_start_failure "requirement file not found" \
    --requirement-file "$GRILL_TMP/missing.md" --grilling-agent claude --answering-agent claude

  teardown_grill_repo
}

test_start_creates_owner_only_record_with_frozen_config() {
  local output session_id session_dir record start_head

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  start_head="$(git -C "$GRILL_REPO" rev-parse HEAD)"

  output="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude \
    --answering-model sonnet --answering-effort high)"

  session_id="$(tail -n 1 <<<"$output")"
  [[ "$session_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || fail "expected session ID as last line, got: $output"
  session_dir="$GRILL_SESSIONS/$session_id"
  [[ -d "$session_dir" ]] || fail "expected session dir $session_dir"
  [[ "$(file_mode "$GRILL_SESSIONS")" == "700" ]] || fail "expected grilling-sessions/ mode 700"
  [[ "$(file_mode "$session_dir")" == "700" ]] || fail "expected session dir mode 700"
  [[ "$(file_mode "$session_dir/session.json")" == "600" ]] || fail "expected session.json mode 600"
  [[ "$(file_mode "$session_dir/requirement.md")" == "600" ]] || fail "expected requirement.md mode 600"
  [[ "$(<"$session_dir/requirement.md")" == "$REQUIREMENT_TEXT" ]] || fail "expected requirement snapshot"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.id' <<<"$record")" == "$session_id" ]] || fail "expected record id"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  [[ "$(jq -r '.input.kind' <<<"$record")" == "requirement_file" ]] || fail "expected input kind"
  [[ "$(jq -r '.input.requirementSha256' <<<"$record")" == "$REQUIREMENT_SHA256" ]] || fail "expected requirement sha256"
  [[ "$(jq -r '.input.requirementPath' <<<"$record")" == "requirement.md" ]] || fail "expected requirement path"
  [[ "$(jq -r '.repo.root' <<<"$record")" == "$(cd "$GRILL_REPO" && pwd -P)" ]] || fail "expected repo root"
  [[ "$(jq -r '.repo.remote' <<<"$record")" == "origin" ]] || fail "expected remote"
  [[ "$(jq -r '.repo.startBranch' <<<"$record")" == "feature-work" ]] || fail "expected start branch"
  [[ "$(jq -r '.repo.branch' <<<"$record")" == "feature-work" ]] || fail "expected branch to stay off default"
  [[ "$(jq -r '.repo.startHead' <<<"$record")" == "$start_head" ]] || fail "expected start head"
  [[ "$(jq -r '.repo.defaultBranch' <<<"$record")" == "main" ]] || fail "expected default branch"
  [[ "$(jq -c '.agents.grilling | {provider, model, reasoningEffort}' <<<"$record")" \
    == '{"provider":"claude","model":"opus","reasoningEffort":"medium"}' ]] \
    || fail "expected grilling config from ralph.config.json defaults"
  [[ "$(jq -c '.agents.answering | {provider, model, reasoningEffort}' <<<"$record")" \
    == '{"provider":"claude","model":"sonnet","reasoningEffort":"high"}' ]] \
    || fail "expected answering config from flags"
  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "feature-work" ]] || fail "expected no branch switch"

  teardown_grill_repo
}

test_start_opens_two_distinct_native_claude_sessions() {
  local session_dir record grilling_prompt answering_prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude \
    --grilling-model opus --answering-model opus >/dev/null

  [[ "$(find "$CLAUDE_CONFIG_DIR/projects" -type f -name '*.jsonl' | wc -l | tr -d ' ')" == "2" ]] \
    || fail "expected exactly two native sessions"
  [[ "$(claude_flag_value 0001 --session-id)" == "$UUID_GRILLING" ]] || fail "expected grilling session first"
  [[ "$(claude_flag_value 0002 --session-id)" == "$UUID_ANSWERING" ]] || fail "expected answering session second"
  [[ "$(claude_flag_value 0001 --model)" == "opus" ]] || fail "expected grilling model"
  [[ "$(claude_flag_value 0002 --model)" == "opus" ]] || fail "expected answering model"

  grilling_prompt="$(claude_flag_value 0001 -p)"
  answering_prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$grilling_prompt" "[ralph-exchange:ex-0001]"
  assert_contains "$grilling_prompt" "Grilling Agent"
  assert_contains "$grilling_prompt" "Users need to export reports offline."
  assert_contains "$answering_prompt" "[ralph-exchange:ex-0002]"
  assert_contains "$answering_prompt" "Answering Agent"
  assert_contains "$answering_prompt" "Users need to export reports offline."

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$UUID_GRILLING" ]] || fail "expected stored grilling native ID"
  [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$UUID_ANSWERING" ]] || fail "expected stored answering native ID"
  [[ "$(jq -c '[.exchanges[:2][] | {id, kind, role, status}]' <<<"$record")" \
    == '[{"id":"ex-0001","kind":"session_start","role":"grilling","status":"completed"},{"id":"ex-0002","kind":"session_start","role":"answering","status":"completed"}]' ]] \
    || fail "expected both start exchanges recorded"
  [[ "$(file_mode "$session_dir/logs/ex-0001-grilling.jsonl")" == "600" ]] || fail "expected grilling log mode 600"
  [[ "$(file_mode "$session_dir/logs/ex-0002-answering.jsonl")" == "600" ]] || fail "expected answering log mode 600"

  teardown_grill_repo
}

test_start_fails_when_native_ids_are_equal() {
  local output status record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '%s\n%s\n' "$UUID_GRILLING" "$UUID_GRILLING" > "$FAKE_UUID_QUEUE"

  set +e
  output="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected equal native IDs to fail start"
  assert_contains "$output" "native session IDs must differ"
  [[ "$(claude_call_count)" == "1" ]] || fail "expected answering session not to start with a duplicate ID"
  record="$(<"$(only_session_dir)/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "failed" ]] || fail "expected failed record"

  teardown_grill_repo
}

test_adapter_argv_carries_role_access_policy() {
  local grilling_argv answering_argv settings

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  grilling_argv="$(claude_argv 0001)"
  answering_argv="$(claude_argv 0002)"
  [[ "$grilling_argv" != *"--dangerously-skip-permissions"* ]] || fail "grilling argv must not skip permissions"
  [[ "$answering_argv" != *"--dangerously-skip-permissions"* ]] || fail "answering argv must not skip permissions"

  [[ "$(claude_flag_value 0001 --permission-mode)" == "acceptEdits" ]] || fail "expected grilling acceptEdits mode"
  [[ "$(<"$FAKE_CLAUDE_DIR/calls/0001/pwd")" == "$(cd "$GRILL_REPO" && pwd -P)" ]] || fail "expected grilling cwd at repo root"
  settings="$(claude_flag_value 0001 --settings)"
  [[ "$(jq -r '.sandbox.enabled' <<<"$settings")" == "true" ]] || fail "expected grilling sandbox"
  [[ "$(jq -r '.sandbox.allowUnsandboxedCommands' <<<"$settings")" == "false" ]] || fail "expected no grilling sandbox escape"
  jq -e '.permissions.deny | index("Bash(git push:*)")' <<<"$settings" >/dev/null || fail "expected grilling git push denied"
  jq -e '.permissions.deny | index("Bash(gh issue create:*)")' <<<"$settings" >/dev/null || fail "expected grilling gh writes denied"
  jq -e '.permissions.allow | index("WebFetch")' <<<"$settings" >/dev/null || fail "expected grilling web reads"
  jq -e '.permissions.allow | index("Bash(gh issue view:*)")' <<<"$settings" >/dev/null || fail "expected grilling gh reads"
  ! jq -e '.permissions.deny | index("Edit(//**)")' <<<"$settings" >/dev/null || fail "grilling must keep repo writes"

  [[ "$(claude_flag_value 0002 --permission-mode)" == "default" ]] || fail "expected answering default mode"
  assert_contains "$answering_argv" '"--disallowedTools"'
  jq -e 'index("Edit") and index("Write") and index("NotebookEdit")' <<<"$answering_argv" >/dev/null \
    || fail "expected answering write tools disallowed"
  settings="$(claude_flag_value 0002 --settings)"
  [[ "$(jq -r '.sandbox.enabled' <<<"$settings")" == "true" ]] || fail "expected answering sandbox"
  jq -e '.permissions.deny | index("Edit(//**)")' <<<"$settings" >/dev/null || fail "expected answering writes denied everywhere"
  jq -e '.permissions.deny | index("Bash(gh issue create:*)")' <<<"$settings" >/dev/null || fail "expected answering gh writes denied"
  jq -e '.permissions.allow | index("Bash(gh issue view:*)")' <<<"$settings" >/dev/null || fail "expected answering gh reads"

  teardown_grill_repo
}

test_capability_failure_refuses_before_native_sessions() {
  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  export FAKE_CLAUDE_HELP_OMIT="--settings"

  expect_start_failure "cannot express the required access policy" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude

  unset FAKE_CLAUDE_HELP_OMIT
  teardown_grill_repo
}

test_start_refuses_dirty_worktree() {
  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf 'uncommitted\n' > "$GRILL_REPO/notes.txt"

  expect_start_failure "working tree is dirty" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude

  teardown_grill_repo
}

test_start_ignores_ralph_session_storage_in_dirty_check() {
  local session_id

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  mkdir -p "$GRILL_SESSIONS/older-session" "$GRILL_REPO/ralph/archive/grilling"
  printf 'old\n' > "$GRILL_SESSIONS/older-session/session.json"
  printf 'old\n' > "$GRILL_REPO/ralph/archive/grilling/record.json"

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  [[ -f "$GRILL_SESSIONS/$session_id/session.json" ]] || fail "expected start despite Ralph session storage"

  teardown_grill_repo
}

test_start_on_default_branch_creates_issue_planning_branch() {
  local session_id record

  setup_grill_repo

  session_id="$(grill start --issue 77 --grilling-agent claude --answering-agent claude | tail -n 1)"

  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "grill/issue-77-add-dark-mode" ]] \
    || fail "expected planning branch checkout"
  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.repo.startBranch' <<<"$record")" == "main" ]] || fail "expected start branch main"
  [[ "$(jq -r '.repo.branch' <<<"$record")" == "grill/issue-77-add-dark-mode" ]] || fail "expected planning branch in record"
  [[ "$(jq -r '.input.kind' <<<"$record")" == "issue" ]] || fail "expected issue input kind"
  [[ "$(jq -r '.input.issue' <<<"$record")" == "77" ]] || fail "expected issue number"
  assert_contains "$(<"$GRILL_SESSIONS/$session_id/requirement.md")" "Readers want a dark theme."
  assert_contains "$(<"$FAKE_GH_LOG")" '["issue","view","77"'

  teardown_grill_repo
}

test_start_on_default_branch_creates_requirement_planning_branch() {
  setup_grill_repo

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "grill/offline-export" ]] \
    || fail "expected grill/<slug> planning branch"

  teardown_grill_repo
}

test_start_refuses_existing_planning_branch() {
  setup_grill_repo
  git -C "$GRILL_REPO" branch grill/offline-export

  expect_start_failure "branch 'grill/offline-export' already exists" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude
  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "main" ]] || fail "expected to stay on main"

  teardown_grill_repo
}

test_start_relays_frontier_rounds_to_the_confirmation_gate() {
  local status session_id session_dir record confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 at the confirmation gate"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  [[ "$(jq -r '.round' <<<"$record")" == "3" ]] || fail "expected three Frontier rounds"
  [[ "$(claude_call_count)" == "10" ]] || fail "expected ten exchanges"
  [[ "$(jq -c '[.exchanges[] | [.id, .kind, .role, .status]]' <<<"$record")" == "$(jq -n -c '[
      ["ex-0001","session_start","grilling","completed"],
      ["ex-0002","session_start","answering","completed"],
      ["ex-0003","frontier","grilling","completed"],
      ["ex-0004","answers","answering","completed"],
      ["ex-0005","frontier","grilling","completed"],
      ["ex-0006","answers","answering","completed"],
      ["ex-0007","frontier","grilling","completed"],
      ["ex-0008","summary_draft","grilling","completed"],
      ["ex-0009","summary_review","answering","completed"],
      ["ex-0010","summary_final","grilling","completed"]]')" ]] \
    || fail "expected sequential completed exchanges, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -r '.exchanges[4].logPath' <<<"$record")" == "logs/ex-0005-grilling.jsonl" ]] || fail "expected exchange log path"

  confirmation="$(<"$session_dir/confirmation.md")"
  [[ "$(file_mode "$session_dir/confirmation.md")" == "600" ]] || fail "expected confirmation.md mode 600"
  assert_contains "$confirmation" "- Storage: Postgres (reopened)."
  assert_contains "$confirmation" "Export reports offline with Postgres storage"
  assert_contains "$confirmation" "Readers export CSV reports stored in Postgres."
  assert_contains "$confirmation" "CONTEXT.md | 3 +++"
  assert_contains "$confirmation" "+**Offline Export**: a report saved for offline reading."
  assert_contains "$confirmation" "## Decision"
  assert_contains "$confirmation" "approve"
  assert_contains "$confirmation" "## Answers"
  [[ "$confirmation" != *"Draft summary: SQLite storage."* ]] || fail "expected the final summary, not the draft"

  teardown_grill_repo
}

test_every_exchange_after_start_resumes_the_stored_native_session() {
  local call flag expected argv

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null

  for call in 0003 0004 0005 0006 0007 0008 0009 0010; do
    case "$call" in
      0004|0006|0009) expected="$UUID_ANSWERING" ;;
      *) expected="$UUID_GRILLING" ;;
    esac
    argv="$(claude_argv "$call")"
    [[ "$(claude_flag_value "$call" --resume)" == "$expected" ]] || fail "expected call $call to resume $expected"
    [[ "$argv" != *'"--session-id"'* ]] || fail "expected call $call not to start a new session"
    assert_contains "$argv" '"--json-schema"'
    assert_contains "$(claude_flag_value "$call" -p)" "[ralph-exchange:ex-$call]"
  done
  for call in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010; do
    argv="$(claude_argv "$call")"
    for flag in --continue --last --fork-session -c; do
      ! jq -e --arg f "$flag" 'index($f)' <<<"$argv" >/dev/null || fail "call $call must not pass $flag"
    done
  done
  [[ "$(claude_flag_value 0005 --model)" == "opus" ]] || fail "expected the frozen model on resumed calls"
  [[ "$(claude_flag_value 0004 --permission-mode)" == "default" ]] || fail "expected answering policy on resumed calls"

  teardown_grill_repo
}

test_answers_merge_into_decisions_and_reopens_route_the_contradiction() {
  local session_id record answering_prompt grilling_prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -c '.decisions' <<<"$record")" == "$(jq -n -c '{
      "storage-backend": {exchangeId: "ex-0006", decision: "postgres", reopenedBy: "ex-0005"},
      "export-format": {exchangeId: "ex-0004", decision: "csv", reopenedBy: null},
      "sync-mode": {exchangeId: "ex-0006", decision: "manual", reopenedBy: null}}')" ]] \
    || fail "expected merged decisions, got: $(jq -c '.decisions' <<<"$record")"

  answering_prompt="$(claude_flag_value 0004 -p)"
  assert_contains "$answering_prompt" "Where are exports stored?"
  assert_contains "$answering_prompt" "export-format"
  answering_prompt="$(claude_flag_value 0006 -p)"
  assert_contains "$answering_prompt" "sync-mode"
  assert_contains "$answering_prompt" "README says exports are shared across devices."
  grilling_prompt="$(claude_flag_value 0005 -p)"
  assert_contains "$grilling_prompt" "Users open exports in spreadsheets."
  grilling_prompt="$(claude_flag_value 0009 -p)"
  assert_contains "$grilling_prompt" "Draft summary: SQLite storage."
  grilling_prompt="$(claude_flag_value 0010 -p)"
  assert_contains "$grilling_prompt" "Say Postgres."

  teardown_grill_repo
}

# Asserts the session blocked as invalid_message on ex-0004 after exactly one
# re-emit request in the same Answering session.
assert_invalid_message_block_after_one_reemit() {
  local record prompt

  record="$(<"$(only_session_dir)/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "invalid_message" ]] || fail "expected invalid_message"
  [[ "$(jq -c '.decisions' <<<"$record")" == "{}" ]] || fail "expected no decisions from an invalid message"
  [[ "$(claude_call_count)" == "5" ]] || fail "expected the original send plus exactly one re-emit request"
  [[ "$(claude_flag_value 0005 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the re-emit in the same session"
  prompt="$(claude_flag_value 0005 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "re-emit"
  [[ "$(jq -c '[.exchanges[] | select(.id == "ex-0004") | .reemitRequested]' <<<"$record")" == "[true]" ]] \
    || fail "expected one ex-0004 exchange with reemitRequested"
  [[ -f "$(only_session_dir)/human-input-ex-0004.md" ]] || fail "expected a human-input file for the block"
}

test_partial_answer_set_is_invalid() {
  local status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]}]}'

  set +e
  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a blocked session to exit 0"
  assert_invalid_message_block_after_one_reemit

  teardown_grill_repo
}

test_answer_without_evidence_is_invalid() {
  local status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Spreadsheets.","evidence":[]}]}'

  set +e
  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a blocked session to exit 0"
  assert_invalid_message_block_after_one_reemit

  teardown_grill_repo
}

test_invalid_message_followed_by_a_valid_reemit_continues() {
  local session_id record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  cp "$FAKE_CLAUDE_DIR/exchanges/ex-0004.json" "$FAKE_CLAUDE_DIR/exchanges/ex-0004.2.json"
  exchange_fixture ex-0004 'Here are my answers: storage-backend is sqlite.'

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the session to reach the gate"
  [[ "$(claude_call_count)" == "11" ]] || fail "expected ten exchanges plus one re-emit request"
  [[ "$(claude_flag_value 0005 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the re-emit in the same session"
  assert_contains "$(claude_flag_value 0005 -p)" "[ralph-exchange:ex-0004]"
  [[ "$(jq -c '[.exchanges[] | select(.id == "ex-0004") | [.status, .reemitRequested]]' <<<"$record")" \
    == '[["completed",true]]' ]] || fail "expected ex-0004 completed after one re-emit"
  [[ "$(jq -r '.exchanges | length' <<<"$record")" == "10" ]] || fail "expected the re-emit to reuse the exchange ID"
  [[ "$(jq -r '.decisions["storage-backend"].decision' <<<"$record")" == "postgres" ]] || fail "expected the run to continue"

  teardown_grill_repo
}

test_confirmation_flags_out_of_scope_changes_and_head_drift() {
  local session_id record start_head confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  start_head="$(git -C "$GRILL_REPO" rev-parse HEAD)"
  queue_two_round_run
  exchange_effect ex-0005 'mkdir -p docs/adr src
printf "# Use Postgres\n" > docs/adr/0001-use-postgres.md
printf "stray\n" > src/app.txt
printf "committed\n" > notes.txt
git add notes.txt && git commit -q -m "Sneaky commit"'

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  confirmation="$(<"$GRILL_SESSIONS/$session_id/confirmation.md")"
  assert_contains "$confirmation" "Changed outside CONTEXT.md and docs/adr/: \`src/app.txt\`"
  [[ "$confirmation" != *"outside CONTEXT.md and docs/adr/: \`docs/adr"* ]] || fail "ADR files are in scope"
  [[ "$confirmation" != *"grilling-sessions"* ]] || fail "Ralph session storage must not be flagged"
  assert_contains "$confirmation" "HEAD changed since start: $start_head -> $(git -C "$GRILL_REPO" rev-parse HEAD)"
  assert_contains "$confirmation" "+# Use Postgres"

  teardown_grill_repo
}

test_confirmation_without_drift_has_no_flags() {
  local session_id confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  confirmation="$(<"$GRILL_SESSIONS/$session_id/confirmation.md")"
  assert_contains "$confirmation" "- No flags."
  [[ "$confirmation" != *"Changed outside"* ]] || fail "expected no out-of-scope flag"
  [[ "$confirmation" != *"HEAD changed"* ]] || fail "expected no HEAD drift flag"

  teardown_grill_repo
}

test_provider_logs_are_owner_only_per_exchange_and_role() {
  local session_dir log

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null

  session_dir="$(only_session_dir)"
  for log in ex-0003-grilling ex-0004-answering ex-0005-grilling ex-0006-answering ex-0007-grilling \
    ex-0008-grilling ex-0009-answering ex-0010-grilling; do
    [[ -f "$session_dir/logs/$log.jsonl" ]] || fail "expected provider log $log"
    [[ "$(file_mode "$session_dir/logs/$log.jsonl")" == "600" ]] || fail "expected $log mode 600"
    assert_contains "$(<"$session_dir/logs/$log.jsonl")" '"type":"result"'
  done

  teardown_grill_repo
}

# Rewinds a gated record to the state right after both native sessions start.
rewind_to_after_start() {
  local session_dir="$1"
  local rewound

  rewound="$(jq '.status = "grilling" | .blockReason = null | .round = 0 | .decisions = {} | .exchanges |= .[:2]' \
    "$session_dir/session.json")"
  printf '%s\n' "$rewound" > "$session_dir/session.json"
  rm -f "$session_dir/confirmation.md"
}

test_resume_continues_a_grilling_session_to_the_gate() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  rewind_to_after_start "$session_dir"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(claude_call_count)" == "4" ]] || fail "expected four resumed exchanges"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_GRILLING" ]] || fail "expected resume of the grilling session"
  assert_contains "$(claude_flag_value 0001 -p)" "[ralph-exchange:ex-0003]"
  [[ -f "$session_dir/confirmation.md" ]] || fail "expected confirmation.md after resume"

  teardown_grill_repo
}

test_resume_rejects_configuration_flags() {
  local session_id flag output status before

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  rewind_to_after_start "$GRILL_SESSIONS/$session_id"
  before="$(claude_call_count)"

  for flag in --grilling-agent --answering-agent --grilling-model --grilling-effort \
    --answering-model --answering-effort; do
    set +e
    output="$(grill resume --id "$session_id" "$flag" claude 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "expected resume $flag to fail"
    assert_contains "$output" "configuration is frozen"
  done
  [[ "$(claude_call_count)" == "$before" ]] || fail "expected no Agent contact on rejected resume"

  teardown_grill_repo
}

# Writes a hand-built Grilling Session Record with the given status into a
# session directory, with a provider log beside it.
write_fixture_session() {
  local session_dir="$1"
  local session_id="$2"
  local status="$3"

  mkdir -p "$session_dir/logs"
  jq -n --arg id "$session_id" --arg status "$status" '{
    id: $id, status: $status, blockReason: null, round: 2,
    agents: {grilling: {provider: "claude", model: "opus", reasoningEffort: "medium", nativeSessionId: "g"},
             answering: {provider: "claude", model: "sonnet", reasoningEffort: "high", nativeSessionId: "a"}},
    decisions: {}, exchanges: []}' > "$session_dir/session.json"
  printf '%s\n' "$REQUIREMENT_TEXT" > "$session_dir/requirement.md"
  printf '{"type":"result","result":"done"}\n' > "$session_dir/logs/ex-0001-grilling.jsonl"
}

expect_grill_failure() {
  local expected="$1"
  shift
  local output status

  set +e
  output="$(grill "$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected grill $* to fail"
  assert_contains "$output" "$expected"
}

NEEDS_HUMAN_EX_0004='{"exchangeId":"ex-0004","needsHuman":{"questionIds":["storage-backend"],"reason":"Nothing says whether exports are shared across devices."}}'

test_needs_human_blocks_with_a_human_input_file() {
  local status session_id session_dir record input output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 "$NEEDS_HUMAN_EX_0004"

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 on a needsHuman block"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "needs_human" ]] || fail "expected needs_human"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$UUID_GRILLING" ]] || fail "expected grilling native ID kept"
  [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$UUID_ANSWERING" ]] || fail "expected answering native ID kept"
  [[ "$(jq -c '.decisions' <<<"$record")" == "{}" ]] || fail "expected no decisions from a needsHuman reply"
  [[ "$(claude_call_count)" == "4" ]] || fail "expected no exchange after needsHuman"

  input="$session_dir/human-input-ex-0004.md"
  [[ -f "$input" ]] || fail "expected human-input file $input"
  [[ "$(file_mode "$input")" == "600" ]] || fail "expected human-input file mode 600"
  assert_contains "$(<"$input")" "storage-backend"
  assert_contains "$(<"$input")" "Where are exports stored?"
  assert_contains "$(<"$input")" "Nothing says whether exports are shared across devices."
  assert_contains "$(<"$input")" "## Answers"

  output="$(grill status --id "$session_id")"
  assert_contains "$output" "State: blocked"
  assert_contains "$output" "Block reason: needs_human"

  teardown_grill_repo
}

# Starts a session that blocks on needsHuman at ex-0004 and prints its ID.
start_needs_human_session() {
  queue_two_round_run
  exchange_fixture ex-0004 "$NEEDS_HUMAN_EX_0004"
  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1
}

test_resume_with_empty_answers_prints_the_input_file_without_agent_calls() {
  local session_id session_dir output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected resume with empty answers to exit 0, got $status: $output"
  assert_contains "$output" "$session_dir/human-input-ex-0004.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls with empty answers"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "needs_human" ]] || fail "expected the block to stay"

  teardown_grill_repo
}

# Scripts the closing exchanges from the given first exchange number: an
# empty Frontier, then the summary draft, review and final.
queue_closing_from() {
  local n="$1"

  exchange_fixture "ex-$(printf '%04d' "$n")" \
    "{\"exchangeId\":\"ex-$(printf '%04d' "$n")\",\"round\":$2,\"questions\":[],\"reopens\":[]}"
  exchange_fixture "ex-$(printf '%04d' $((n + 1)))" "$(summary_fixture "ex-$(printf '%04d' $((n + 1)))" "- Storage: Postgres.")"
  exchange_fixture "ex-$(printf '%04d' $((n + 2)))" \
    "{\"exchangeId\":\"ex-$(printf '%04d' $((n + 2)))\",\"faithful\":true,\"discrepancies\":[]}"
  exchange_fixture "ex-$(printf '%04d' $((n + 3)))" "$(summary_fixture "ex-$(printf '%04d' $((n + 3)))" "- Storage: Postgres.")"
}

test_resume_routes_human_input_to_answering_then_grilling() {
  local session_id session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'Exports are shared across devices, so use Postgres.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"The human says exports are shared.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["README.md"]}]}'
  queue_closing_from 6 2
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected human input sent to the Answering session first"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0005]"
  assert_contains "$prompt" "Exports are shared across devices, so use Postgres."
  assert_contains "$prompt" "Where are exports stored?"
  [[ "$(claude_flag_value 0002 --resume)" == "$UUID_GRILLING" ]] || fail "expected the updated decision relayed to the Grilling session second"
  prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0006]"
  assert_contains "$prompt" "The human says exports are shared."
  [[ "$(claude_call_count)" == "5" ]] || fail "expected human input, relay and three closing exchanges"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -c '[.exchanges[4:6][] | [.id, .kind, .role, .status]]' <<<"$record")" \
    == '[["ex-0005","human_input","answering","completed"],["ex-0006","correction_relay","grilling","completed"]]' ]] \
    || fail "expected human_input then correction_relay exchanges, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -c '.decisions["storage-backend"]' <<<"$record")" \
    == '{"exchangeId":"ex-0005","decision":"postgres","reopenedBy":null}' ]] || fail "expected the human-informed decision"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected grilling to continue to the gate"

  teardown_grill_repo
}

test_identical_frontier_without_reopens_blocks_as_no_progress() {
  local status session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  jq -c '.exchangeId = "ex-0005" | .round = 2' "$FAKE_CLAUDE_DIR/exchanges/ex-0003.json" > "$GRILL_TMP/repeat.json"
  exchange_fixture ex-0005 "$(<"$GRILL_TMP/repeat.json")"

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 on a no_progress block"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "no_progress" ]] || fail "expected no_progress, got $(jq -r '.blockReason' <<<"$record")"
  [[ "$(claude_call_count)" == "5" ]] || fail "expected no exchange after the repeated Frontier"
  assert_contains "$(<"$session_dir/human-input-ex-0005.md")" "storage-backend"
  assert_contains "$(<"$session_dir/human-input-ex-0005.md")" "## Answers"

  teardown_grill_repo
}

# Writes a decision line into confirmation.md's ## Decision section.
write_confirmation_decision() {
  awk -v decision="$2" '/^## Answers/ { print decision; print "" } { print }' "$1" > "$1.new"
  mv "$1.new" "$1"
}

test_correct_at_the_gate_routes_answering_then_grilling_back_to_the_gate() {
  local session_id session_dir record output prompt confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  write_confirmation_decision "$session_dir/confirmation.md" correct
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  output="$(grill resume --id "$session_id" 2>&1)"
  assert_contains "$output" "$session_dir/confirmation.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls for a correction without text"

  printf 'Exports must also be available as JSON.\n' >> "$session_dir/confirmation.md"
  exchange_fixture ex-0007 '{"exchangeId":"ex-0007","answers":[
      {"questionId":"export-format","choiceId":"json","rationale":"The human asked for JSON exports.","evidence":["confirmation.md"]}]}'
  queue_closing_from 8 2

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the correction sent to the Answering session first"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0007]"
  assert_contains "$prompt" "Exports must also be available as JSON."
  [[ "$(claude_flag_value 0002 --resume)" == "$UUID_GRILLING" ]] || fail "expected the updated decision relayed to the Grilling session second"
  prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0008]"
  assert_contains "$prompt" "The human asked for JSON exports."
  [[ "$(claude_call_count)" == "5" ]] || fail "expected correction, relay and a new closing pass"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the confirmation gate again"
  [[ "$(jq -c '[.exchanges[6:][] | [.id, .kind, .role]]' <<<"$record")" == "$(jq -n -c '[
      ["ex-0007","human_input","answering"],
      ["ex-0008","correction_relay","grilling"],
      ["ex-0009","summary_draft","grilling"],
      ["ex-0010","summary_review","answering"],
      ["ex-0011","summary_final","grilling"]]')" ]] \
    || fail "expected correction exchanges then a new closing pass, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -r '.decisions["export-format"].decision' <<<"$record")" == "json" ]] || fail "expected the corrected decision"
  confirmation="$(<"$session_dir/confirmation.md")"
  assert_contains "$confirmation" "- Storage: Postgres."
  [[ "$confirmation" != *"Exports must also be available as JSON."* ]] || fail "expected a fresh confirmation file"

  teardown_grill_repo
}

test_gate_text_without_a_correct_decision_contacts_no_agent() {
  local session_id session_dir output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  printf 'Exports must also be available as JSON.\n' >> "$session_dir/confirmation.md"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  output="$(grill resume --id "$session_id" 2>&1)"

  assert_contains "$output" "## Decision"
  assert_contains "$output" "$session_dir/confirmation.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls without a decision"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] || fail "expected the gate to stay"

  teardown_grill_repo
}

test_unrecognized_gate_decision_prints_what_to_write_without_agent_calls() {
  local session_id session_dir output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  write_confirmation_decision "$session_dir/confirmation.md" maybe
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected an unrecognized decision to exit 0, got $status: $output"
  assert_contains "$output" "approve, reject or correct under ## Decision"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls for an unrecognized decision"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] || fail "expected the gate to stay"

  teardown_grill_repo
}

# Scripts ex-0005 to add an ADR and a file outside CONTEXT.md and docs/adr/
# on top of queue_two_round_run's CONTEXT.md edit.
queue_run_with_adr_and_out_of_scope_file() {
  queue_two_round_run
  exchange_effect ex-0005 'mkdir -p docs/adr src
printf "# Use Postgres\n" > docs/adr/0001-use-postgres.md
printf "stray\n" > src/app.txt'
}

# Prints the archived session directory for a session ID, or nothing.
archived_session_dir() {
  find "$GRILL_REPO/ralph/archive/grilling" -mindepth 1 -maxdepth 1 -type d -name "*-$1" 2>/dev/null | head -n 1
}

assert_archived() {
  local session_id="$1"
  local status="$2"
  local archived

  archived="$(archived_session_dir "$session_id")"
  [[ -n "$archived" ]] || fail "expected session $session_id under archive/grilling/"
  [[ "$(basename "$archived")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-$session_id$ ]] \
    || fail "expected archive/grilling/<YYYY-MM-DD>-$session_id, got $archived"
  [[ ! -e "$GRILL_SESSIONS/$session_id" ]] || fail "expected the session moved out of grilling-sessions/"
  [[ "$(jq -r '.status' "$archived/session.json")" == "$status" ]] || fail "expected archived status $status"
  [[ ! -e "$archived/lock" ]] || fail "expected the archived session unlocked"
}

# Prints the gh write calls (issue edit/create) the fake gh recorded.
gh_writes() {
  jq -c 'select(.[0] == "issue" and (.[1] == "edit" or .[1] == "create"))' "$FAKE_GH_LOG"
}

test_approve_on_an_issue_session_commits_docs_pushes_and_edits_the_issue() {
  local session_id output record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_run_with_adr_and_out_of_scope_file
  session_id="$(grill start --issue 51 --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  write_confirmation_decision "$GRILL_SESSIONS/$session_id/confirmation.md" approve
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  : > "$FAKE_GH_LOG"

  output="$(grill resume --id "$session_id" 2>/dev/null)"

  [[ "$(git -C "$GRILL_REPO" show --name-only --format= HEAD)" == $'CONTEXT.md\ndocs/adr/0001-use-postgres.md' ]] \
    || fail "expected a commit of only CONTEXT.md and the ADR, got: $(git -C "$GRILL_REPO" show --name-only --format= HEAD)"
  assert_contains "$(git -C "$GRILL_REPO" status --porcelain --untracked-files=all)" "?? src/app.txt"
  [[ "$(git -C "$GRILL_TMP/remote.git" rev-parse refs/heads/feature-work)" == "$(git -C "$GRILL_REPO" rev-parse HEAD)" ]] \
    || fail "expected feature-work pushed to the bare remote"
  [[ "$(git -C "$GRILL_REPO" rev-parse --abbrev-ref "feature-work@{upstream}")" == "origin/feature-work" ]] \
    || fail "expected the branch to track origin/feature-work"
  [[ "$(gh_writes | jq -c '.[0:5] + [.[5]]')" \
    == '["issue","edit","51","--title","Export reports offline with Postgres storage","--body-file"]' ]] \
    || fail "expected gh issue edit 51 with the fixture title, got: $(gh_writes)"
  [[ "$(<"$FAKE_GH_LOG.body")" == "Readers export CSV reports stored in Postgres."$'\n\n'"<!-- ralph-grill-session: $session_id -->" ]] \
    || fail "expected the fixture issue body with the session marker, got: $(<"$FAKE_GH_LOG.body")"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls during approve"

  assert_archived "$session_id" completed
  record="$(<"$(archived_session_dir "$session_id")/session.json")"
  [[ "$(jq -r '.apply.commit.sha' <<<"$record")" == "$(git -C "$GRILL_REPO" rev-parse HEAD)" ]] || fail "expected apply.commit"
  [[ "$(jq -r '.apply.issue.url' <<<"$record")" == "https://github.com/acme/target/issues/51" ]] || fail "expected apply.issue"
  assert_contains "$output" "https://github.com/acme/target/issues/51"
  assert_contains "$output" "Branch: feature-work"
  assert_contains "$output" "baseBranch"

  teardown_grill_repo
}

test_approve_on_a_requirement_file_session_creates_the_issue() {
  local session_id record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  write_confirmation_decision "$GRILL_SESSIONS/$session_id/confirmation.md" approve
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  : > "$FAKE_GH_LOG"

  FAKE_GH_CREATED_ISSUE=88 grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(gh_writes | jq -c '.[0:4] + [.[4]]')" \
    == '["issue","create","--title","Export reports offline with Postgres storage","--body-file"]' ]] \
    || fail "expected gh issue create with the fixture title, got: $(gh_writes)"
  [[ "$(<"$FAKE_GH_LOG.body")" == "Readers export CSV reports stored in Postgres."$'\n\n'"<!-- ralph-grill-session: $session_id -->" ]] \
    || fail "expected the fixture issue body with the session marker, got: $(<"$FAKE_GH_LOG.body")"
  assert_archived "$session_id" completed
  record="$(<"$(archived_session_dir "$session_id")/session.json")"
  [[ "$(jq -c '.apply.issue | {number, url}' <<<"$record")" \
    == '{"number":88,"url":"https://github.com/acme/target/issues/88"}' ]] || fail "expected the created issue recorded"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls during approve"

  teardown_grill_repo
}

test_failed_push_leaves_applying_and_resume_retries_only_push_and_issue() {
  local session_id session_dir output status record commits

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  write_confirmation_decision "$session_dir/confirmation.md" approve
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  : > "$FAKE_GH_LOG"
  touch "$GRILL_TMP/push-fails-once"
  cat > "$GRILL_TMP/remote.git/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
if [[ -f "$GRILL_TMP/push-fails-once" ]]; then
  rm -f "$GRILL_TMP/push-fails-once"
  echo "remote rejected (scripted failure)" >&2
  exit 1
fi
HOOK
  chmod +x "$GRILL_TMP/remote.git/hooks/pre-receive"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected a failed push to exit non-zero"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "applying" ]] || fail "expected applying after a failed push, got $(jq -r '.status' <<<"$record")"
  [[ "$(jq -r '.apply.commit.sha' <<<"$record")" == "$(git -C "$GRILL_REPO" rev-parse HEAD)" ]] || fail "expected apply.commit recorded"
  [[ "$(jq -c '[.apply.push, .apply.issue]' <<<"$record")" == "[null,null]" ]] || fail "expected push and issue unrecorded"
  [[ -z "$(gh_writes)" ]] || fail "expected no issue write after a failed push"
  commits="$(git -C "$GRILL_REPO" rev-list --count HEAD)"

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(git -C "$GRILL_REPO" rev-list --count HEAD)" == "$commits" ]] || fail "expected no new commit on retry"
  [[ "$(git -C "$GRILL_TMP/remote.git" rev-parse refs/heads/feature-work)" == "$(git -C "$GRILL_REPO" rev-parse HEAD)" ]] \
    || fail "expected the retry to push"
  [[ "$(gh_writes | wc -l | tr -d ' ')" == "1" ]] || fail "expected exactly one gh issue create, got: $(gh_writes)"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls while applying"
  assert_archived "$session_id" completed

  teardown_grill_repo
}

test_reject_restores_docs_and_leaves_out_of_scope_changes() {
  local session_id output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '# Context\n\nOriginal glossary.\n' > "$GRILL_REPO/CONTEXT.md"
  git -C "$GRILL_REPO" add CONTEXT.md
  git -C "$GRILL_REPO" commit -q -m "Add CONTEXT.md"
  queue_two_round_run
  exchange_effect ex-0005 'mkdir -p docs/adr
printf "# Use Postgres\n" > docs/adr/0001-use-postgres.md
printf "# Target project\n\nEdited outside scope.\n" > README.md'
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  assert_contains "$(<"$GRILL_REPO/CONTEXT.md")" "Offline Export"
  write_confirmation_decision "$GRILL_SESSIONS/$session_id/confirmation.md" reject
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  : > "$FAKE_GH_LOG"

  output="$(grill resume --id "$session_id" 2>/dev/null)"

  [[ "$(<"$GRILL_REPO/CONTEXT.md")" == $'# Context\n\nOriginal glossary.' ]] || fail "expected CONTEXT.md restored"
  [[ ! -e "$GRILL_REPO/docs/adr/0001-use-postgres.md" ]] || fail "expected the new ADR removed"
  [[ "$(<"$GRILL_REPO/README.md")" == $'# Target project\n\nEdited outside scope.' ]] || fail "expected README.md untouched"
  [[ "$(git -C "$GRILL_REPO" status --porcelain --untracked-files=all -- . ':(exclude)ralph')" == " M README.md" ]] \
    || fail "expected only the out-of-scope change left, got: $(git -C "$GRILL_REPO" status --porcelain)"
  [[ -z "$(gh_writes)" ]] || fail "expected no gh writes on reject"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls during reject"
  assert_archived "$session_id" rejected
  assert_contains "$output" "rejected"

  teardown_grill_repo
}

test_status_logs_and_cleanup_require_a_known_id() {
  local subcommand

  setup_grill_repo

  for subcommand in status logs cleanup; do
    expect_grill_failure "Usage:" "$subcommand"
    expect_grill_failure "no Grilling Session Record for 20260101-000000-abcd" "$subcommand" --id 20260101-000000-abcd
  done

  teardown_grill_repo
}

test_status_shows_state_agents_and_next_action_without_raw_content() {
  local session_id session_dir output log line

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude \
    --answering-model sonnet --answering-effort high 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"

  output="$(grill status --id "$session_id")"
  assert_contains "$output" "State: blocked"
  assert_contains "$output" "Block reason: awaiting_confirmation"
  assert_contains "$output" "Round: 1"
  assert_contains "$output" "Grilling Agent: claude (model opus, effort medium)"
  assert_contains "$output" "Answering Agent: claude (model sonnet, effort high)"
  assert_contains "$output" "Next action: edit $session_dir/confirmation.md, then run: ralph.sh grill resume --id $session_id"

  for log in "$session_dir"/logs/*.jsonl; do
    while IFS= read -r line; do
      [[ -z "$line" || "$output" != *"$line"* ]] || fail "expected status to exclude raw log line: $line"
    done < "$log"
  done
  [[ "$output" != *"Users need to export reports offline."* ]] || fail "expected status to exclude the requirement"
  [[ "$output" != *"Offline Export"* ]] || fail "expected status to exclude the requirement title"

  jq '.status = "blocked" | .blockReason = "needs_human" | .humanInputPath = "human-input-ex-0004.md"' \
    "$session_dir/session.json" > "$GRILL_TMP/needs-human.json"
  cp "$GRILL_TMP/needs-human.json" "$session_dir/session.json"
  output="$(grill status --id "$session_id")"
  assert_contains "$output" "Block reason: needs_human"
  assert_contains "$output" "Next action: write your input under ## Answers in $session_dir/human-input-ex-0004.md, then run: ralph.sh grill resume --id $session_id"

  jq '.blockReason = "transient_failure"' "$session_dir/session.json" > "$GRILL_TMP/transient.json"
  cp "$GRILL_TMP/transient.json" "$session_dir/session.json"
  output="$(grill status --id "$session_id")"
  assert_contains "$output" "Next action: when the provider recovers, run: ralph.sh grill resume --id $session_id"

  teardown_grill_repo
}

test_logs_summarize_activity_per_role_and_exchange() {
  local session_id session_dir output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude \
    2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  cat > "$session_dir/logs/ex-0003-grilling.jsonl" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading CONTEXT.md before the first Frontier."},{"type":"tool_use","name":"Read","input":{"file_path":"CONTEXT.md"}}]}}
LOG
  cat > "$session_dir/logs/ex-0005-answering.jsonl" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"Checked the draft against the decisions."}]}}
LOG

  output="$(grill logs --id "$session_id")"
  assert_contains "$output" "ex-0003 frontier (grilling Agent, claude)"
  assert_contains "$output" "[text] Reading CONTEXT.md before the first Frontier."
  assert_contains "$output" "[tool] Read: file_path=CONTEXT.md"
  assert_contains "$output" "ex-0005 summary_review (answering Agent, claude)"
  assert_contains "$output" "[text] Checked the draft against the decisions."
  [[ "$output" != *'"type":"assistant"'* ]] || fail "expected logs to exclude raw provider events"

  teardown_grill_repo
}

test_cleanup_deletes_terminal_sessions_and_refuses_active_ones() {
  local archive_dir status session_id n=0

  setup_grill_repo
  archive_dir="$GRILL_REPO/ralph/archive/grilling"

  write_fixture_session "$GRILL_SESSIONS/20260924-100000-0001" 20260924-100000-0001 failed
  write_fixture_session "$GRILL_SESSIONS/20260924-100000-0002" 20260924-100000-0002 context_lost
  write_fixture_session "$archive_dir/2026-09-24-20260924-100000-0003" 20260924-100000-0003 completed
  write_fixture_session "$archive_dir/2026-09-24-20260924-100000-0004" 20260924-100000-0004 rejected

  grill cleanup --id 20260924-100000-0001 >/dev/null
  [[ ! -e "$GRILL_SESSIONS/20260924-100000-0001" ]] || fail "expected failed session deleted"
  grill cleanup --id 20260924-100000-0002 >/dev/null
  [[ ! -e "$GRILL_SESSIONS/20260924-100000-0002" ]] || fail "expected context_lost session deleted"
  grill cleanup --id 20260924-100000-0003 >/dev/null
  [[ ! -e "$archive_dir/2026-09-24-20260924-100000-0003" ]] || fail "expected archived completed session deleted"
  grill cleanup --id 20260924-100000-0004 >/dev/null
  [[ ! -e "$archive_dir/2026-09-24-20260924-100000-0004" ]] || fail "expected archived rejected session deleted"

  for status in grilling blocked applying; do
    n=$((n + 1))
    session_id="20260924-110000-000$n"
    write_fixture_session "$GRILL_SESSIONS/$session_id" "$session_id" "$status"
    expect_grill_failure "session $session_id is $status" cleanup --id "$session_id"
    [[ -f "$GRILL_SESSIONS/$session_id/session.json" ]] || fail "expected $status session record intact"
    [[ -f "$GRILL_SESSIONS/$session_id/logs/ex-0001-grilling.jsonl" ]] || fail "expected $status session logs intact"
  done

  teardown_grill_repo
}

test_cleanup_deletes_a_crashed_start_but_not_a_running_one() {
  local holder

  setup_grill_repo
  write_fixture_session "$GRILL_SESSIONS/20260924-120000-0001" 20260924-120000-0001 starting
  write_fixture_session "$GRILL_SESSIONS/20260924-120000-0002" 20260924-120000-0002 starting
  sleep 30 &
  holder=$!
  ln -s "$holder" "$GRILL_SESSIONS/20260924-120000-0002/lock"

  expect_grill_failure "is starting: its start was interrupted" resume --id 20260924-120000-0001
  grill cleanup --id 20260924-120000-0001 >/dev/null
  [[ ! -e "$GRILL_SESSIONS/20260924-120000-0001" ]] || fail "expected the crashed start deleted"
  expect_grill_failure "is locked by another coordinator (PID $holder)" cleanup --id 20260924-120000-0002
  [[ -f "$GRILL_SESSIONS/20260924-120000-0002/session.json" ]] || fail "expected the running start kept"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  teardown_grill_repo
}

test_grilling_sessions_are_gitignored() {
  grep -qx 'grilling-sessions/' "$ROOT_DIR/.gitignore" || fail "expected grilling-sessions/ in .gitignore"
}

# Starts a claude/claude session to the gate and rewinds it to right after
# both native sessions started, with no Agent calls recorded. Prints its ID.
start_then_rewind() {
  local session_id

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  rewind_to_after_start "$GRILL_SESSIONS/$session_id"
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  printf '%s\n' "$session_id"
}

# Runs grill in its own process group, as a terminal job would, so the fake
# claude can interrupt the whole group like Ctrl-C. Prints the exit status.
grill_as_job() {
  local pid status=0

  set -m
  grill "$@" > "$GRILL_TMP/job.out" 2>&1 &
  pid=$!
  set +m
  wait "$pid" || status=$?
  printf '%s\n' "$status"
}

exchange_status() {
  jq -r --arg id "$2" '[.exchanges[] | select(.id == $id) | .status] | join(",")' "$1/session.json"
}

test_resume_fails_on_a_live_lock_and_reclaims_a_dead_one() {
  local session_id session_dir holder output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  [[ ! -e "$session_dir/lock" ]] || fail "expected start to release its lock"

  sleep 30 &
  holder=$!
  ln -s "$holder" "$session_dir/lock"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected resume to fail on a live lock"
  assert_contains "$output" "is locked by another coordinator (PID $holder)"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls while locked"
  [[ "$(readlink "$session_dir/lock")" == "$holder" ]] || fail "expected the live lock untouched"

  kill "$holder"
  wait "$holder" 2>/dev/null || true
  grill resume --id "$session_id" >/dev/null

  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] \
    || fail "expected resume to proceed after reclaiming a dead lock"
  [[ ! -e "$session_dir/lock" ]] || fail "expected resume to release the reclaimed lock"

  teardown_grill_repo
}

# A coordinator that finds a dead owner's lock while another is reclaiming it
# refuses instead of removing it, and the lock is created with its owner PID
# in one step, so no lock is ever left without an owner.
test_lock_reclaim_is_guarded_and_never_steals_a_fresh_lock() {
  local session_id session_dir dead output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  sleep 0 &
  dead=$!
  wait "$dead" 2>/dev/null || true

  ln -s "$dead" "$session_dir/lock"
  mkdir "$session_dir/lock.reclaim"
  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected resume to refuse while another coordinator reclaims the lock"
  assert_contains "$output" "another coordinator is reclaiming the lock"
  [[ "$(readlink "$session_dir/lock")" == "$dead" ]] || fail "expected the lock left to the reclaiming coordinator"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls while the lock is being reclaimed"

  rmdir "$session_dir/lock.reclaim"
  (
    source "$ROOT_DIR/scripts/grill-record.sh"
    grill_record_lock "$session_dir"
    [[ "$(readlink "$session_dir/lock")" == "$BASHPID" || "$(readlink "$session_dir/lock")" == "$$" ]] \
      || fail "expected the reclaimed lock to name its new owner"
    [[ ! -e "$session_dir/lock.reclaim" ]] || fail "expected the reclaim guard released"
  )

  teardown_grill_repo
}

test_sessions_with_different_ids_hold_their_locks_at_once() {
  local first second holder

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '%s\n' "$UUID_GRILLING" "$UUID_ANSWERING" \
    33333333-3333-4333-8333-333333333333 44444444-4444-4444-8444-444444444444 > "$FAKE_UUID_QUEUE"
  first="$(start_then_rewind)"
  second="$(start_then_rewind)"
  [[ "$first" != "$second" ]] || fail "expected two sessions"

  sleep 30 &
  holder=$!
  ln -s "$holder" "$GRILL_SESSIONS/$first/lock"
  exchange_effect ex-0003 "[[ -L '$GRILL_SESSIONS/$first/lock' && -L '$GRILL_SESSIONS/$second/lock' ]] && touch '$GRILL_TMP/both-locked'"

  grill resume --id "$second" >/dev/null

  [[ -f "$GRILL_TMP/both-locked" ]] || fail "expected both sessions locked during the second resume"
  [[ "$(jq -r '.blockReason' "$GRILL_SESSIONS/$second/session.json")" == "awaiting_confirmation" ]] \
    || fail "expected the second session to reach the gate"
  [[ "$(readlink "$GRILL_SESSIONS/$first/lock")" == "$holder" ]] || fail "expected the first session lock untouched"
  kill "$holder"
  wait "$holder" 2>/dev/null || true

  teardown_grill_repo
}

test_kill_mid_exchange_leaves_it_in_flight_and_resume_reemits_when_received() {
  local status session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  printf 'received\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0004.kill"

  status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude)"

  [[ "$status" -ne 0 ]] || fail "expected the killed coordinator to exit non-zero"
  session_dir="$(only_session_dir)"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "grilling" ]] || fail "expected the record to stay grilling"
  [[ "$(exchange_status "$session_dir" ex-0004)" =~ ^(intent|sent)$ ]] || fail "expected ex-0004 left in flight"
  [[ "$(jq -c '.decisions' "$session_dir/session.json")" == "{}" ]] || fail "expected no decisions before recovery"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the killed coordinator to release its lock"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$(basename "$session_dir")" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006","ex-0007","ex-0008","ex-0009","ex-0010"]' ]] \
    || fail "expected no duplicated exchange, got $(jq -c '[.exchanges[].id]' <<<"$record")"
  [[ "$(jq -c '.decisions | map_values(.exchangeId)' <<<"$record")" \
    == '{"storage-backend":"ex-0006","export-format":"ex-0004","sync-mode":"ex-0006"}' ]] \
    || fail "expected each decision once, got $(jq -c '.decisions' <<<"$record")"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one call per remaining exchange"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the answering session resumed"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "Re-emit your reply to exchange ex-0004"
  [[ "$prompt" != *"Where are exports stored?"* ]] || fail "expected a re-emit request, not the original round"

  teardown_grill_repo
}

test_resume_after_a_kill_resends_an_exchange_the_session_never_received() {
  local status session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  printf 'lost\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0004.kill"

  status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude)"

  [[ "$status" -ne 0 ]] || fail "expected the killed coordinator to exit non-zero"
  session_dir="$(only_session_dir)"
  [[ "$(exchange_status "$session_dir" ex-0004)" =~ ^(intent|sent)$ ]] || fail "expected ex-0004 left in flight"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$(basename "$session_dir")" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006","ex-0007","ex-0008","ex-0009","ex-0010"]' ]] \
    || fail "expected no duplicated exchange"
  [[ "$(jq -c '.decisions | map_values(.exchangeId)' <<<"$record")" \
    == '{"storage-backend":"ex-0006","export-format":"ex-0004","sync-mode":"ex-0006"}' ]] \
    || fail "expected each decision once"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one call per remaining exchange"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the answering session resumed"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "Where are exports stored?"
  [[ "$prompt" != *"Re-emit your reply"* ]] || fail "expected the original round, not a re-emit"

  teardown_grill_repo
}

test_transient_failure_is_retried_within_the_same_exchange_and_session() {
  local session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  touch "$FAKE_CLAUDE_DIR/exchanges/ex-0003.transient"

  RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the retry to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006"]' ]] || fail "expected no new exchange for the retry"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one extra call for the retry"
  [[ "$(claude_flag_value 0003 --resume)" == "$UUID_GRILLING" ]] || fail "expected the failed call to resume the grilling session"
  [[ "$(claude_flag_value 0004 --resume)" == "$UUID_GRILLING" ]] || fail "expected the retry to resume the grilling session"
  assert_contains "$(claude_flag_value 0003 -p)" "[ralph-exchange:ex-0003]"
  assert_contains "$(claude_flag_value 0004 -p)" "[ralph-exchange:ex-0003]"
  [[ -z "$(claude_flag_value 0004 --session-id)" ]] || fail "expected no new native session on retry"
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl.attempt-1")" "529"

  teardown_grill_repo
}

test_session_not_found_on_resume_is_context_lost() {
  local session_id session_dir output status call

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  mkdir -p "$FAKE_CLAUDE_DIR/lost"
  touch "$FAKE_CLAUDE_DIR/lost/$UUID_GRILLING"

  set +e
  output="$(RALPH_RETRY_DELAYS=0 grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected a lost native session to fail resume"
  assert_contains "$output" "context_lost"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "context_lost" ]] || fail "expected context_lost record"
  [[ "$(claude_call_count)" == "1" ]] || fail "expected no retry or replacement after not found"
  for call in "$FAKE_CLAUDE_DIR"/calls/*; do
    [[ -z "$(claude_flag_value "$(basename "$call")" --session-id)" ]] || fail "expected no replacement session start"
  done
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl")" "No conversation found"
  [[ -f "$session_dir/logs/ex-0001-grilling.jsonl" ]] || fail "expected earlier logs retained"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the lock released"
  expect_grill_failure "start a new session" resume --id "$session_id"

  teardown_grill_repo
}

test_resume_on_a_terminal_record_fails() {
  local status session_id n=0

  setup_grill_repo

  for status in completed rejected context_lost failed; do
    n=$((n + 1))
    session_id="20260925-120000-000$n"
    write_fixture_session "$GRILL_SESSIONS/$session_id" "$session_id" "$status"
    expect_grill_failure "start a new session" resume --id "$session_id"
    [[ "$(jq -r '.status' "$GRILL_SESSIONS/$session_id/session.json")" == "$status" ]] || fail "expected $status record untouched"
  done
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls for terminal records"

  teardown_grill_repo
}

# Runs start with an Answering-side effect at the given exchange and asserts
# the record fails as policy_violation with a non-zero exit, keeping its logs.
assert_answering_mutation_is_policy_violation() {
  local exchange_id="$1"
  local effect="$2"
  local output status session_dir

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_effect "$exchange_id" "$effect"

  set +e
  output="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected an Answering-side mutation at $exchange_id to exit non-zero"
  assert_contains "$output" "policy_violation"
  session_dir="$(only_session_dir)"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "failed" ]] || fail "expected a failed record"
  [[ "$(jq -r '.failureReason' "$session_dir/session.json")" == "policy_violation" ]] \
    || fail "expected failureReason policy_violation, got: $(jq -r '.failureReason' "$session_dir/session.json")"
  [[ -f "$session_dir/logs/$exchange_id-answering.jsonl" ]] || fail "expected the exchange log kept"
  [[ ! -f "$session_dir/confirmation.md" ]] || fail "expected no confirmation gate after a policy violation"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the lock released"

  teardown_grill_repo
}

test_answering_agent_creating_a_file_fails_as_policy_violation() {
  assert_answering_mutation_is_policy_violation ex-0004 'printf "leak\n" > leak.txt'
}

test_answering_agent_modifying_a_file_in_summary_review_fails_as_policy_violation() {
  assert_answering_mutation_is_policy_violation ex-0009 'printf "edited\n" >> README.md'
}

test_answering_agent_commit_fails_as_policy_violation() {
  assert_answering_mutation_is_policy_violation ex-0006 'git commit -q --allow-empty -m "Answering commit"'
}

test_answering_agent_mutation_during_human_input_fails_as_policy_violation() {
  local session_id session_dir output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'Use Postgres.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_effect ex-0005 'printf "leak\n" > leak.txt'
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"The human says so.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Spreadsheets.","evidence":["README.md"]}]}'

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected resume to exit non-zero on a policy violation"
  assert_contains "$output" "policy_violation"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "failed" ]] || fail "expected a failed record"
  [[ "$(jq -r '.failureReason' "$session_dir/session.json")" == "policy_violation" ]] || fail "expected policy_violation"

  teardown_grill_repo
}

test_grilling_agent_doc_edits_are_not_a_policy_violation() {
  local session_id record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_effect ex-0005 'mkdir -p docs/adr && printf "# Use Postgres\n" > docs/adr/0001-use-postgres.md
printf "\n**Sync**: manual.\n" >> CONTEXT.md'

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] \
    || fail "expected Grilling Agent doc edits to reach the gate, got: $(jq -c '{status, failureReason}' <<<"$record")"
  [[ "$(jq -r '.failureReason // "none"' <<<"$record")" == "none" ]] || fail "expected no failure reason"

  teardown_grill_repo
}

codex_flag_value() {
  jq -r --arg flag "$2" '. as $a | [range(0; length) | select($a[.] == $flag) | $a[. + 1]] | first // ""' \
    "$FAKE_CODEX_DIR/calls/$1/argv.json"
}

codex_config_values() {
  jq -c '. as $a | [range(0; length) | select($a[.] == "-c") | $a[. + 1]]' "$FAKE_CODEX_DIR/calls/$1/argv.json"
}

test_codex_pair_stores_two_distinct_captured_thread_ids() {
  local record call expected argv

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent codex --answering-agent codex \
    --grilling-model gpt-5.6-sol --answering-model gpt-5.6-sol >/dev/null

  record="$(<"$(only_session_dir)/session.json")"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$THREAD_GRILLING" ]] \
    || fail "expected the captured grilling thread ID, got $(jq -r '.agents.grilling.nativeSessionId' <<<"$record")"
  [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$THREAD_ANSWERING" ]] \
    || fail "expected the captured answering thread ID"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected a codex pair to reach the gate"
  [[ "$(codex_call_count)" == "10" ]] || fail "expected one codex call per exchange, got $(codex_call_count)"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no claude calls"

  for call in 0001 0002; do
    ! jq -e 'index("resume")' <<<"$(codex_argv "$call")" >/dev/null || fail "expected call $call to start a new thread"
    assert_contains "$(codex_prompt "$call")" "[ralph-exchange:ex-$call]"
  done
  for call in 0003 0004 0005 0006 0007 0008 0009 0010; do
    case "$call" in
      0004|0006|0009) expected="$THREAD_ANSWERING" ;;
      *) expected="$THREAD_GRILLING" ;;
    esac
    argv="$(codex_argv "$call")"
    jq -e 'index("exec") as $e | $e != null and .[$e + 1] == "resume"' <<<"$argv" >/dev/null \
      || fail "expected call $call to be exec resume"
    [[ "$(codex_resumed_thread "$call")" == "$expected" ]] || fail "expected call $call to resume $expected"
    assert_contains "$argv" '"--output-schema"'
    assert_contains "$(codex_prompt "$call")" "[ralph-exchange:ex-$call]"
  done
  for call in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010; do
    ! jq -e 'index("--last")' <<<"$(codex_argv "$call")" >/dev/null || fail "call $call must not pass --last"
    [[ "$(codex_flag_value "$call" --model)" == "gpt-5.6-sol" ]] || fail "expected the frozen model on call $call"
  done

  teardown_grill_repo
}

test_mixed_agent_pairs_reach_the_confirmation_gate() {
  local pair grilling answering record expected_grilling expected_answering grilling_calls answering_calls

  for pair in "codex claude $THREAD_GRILLING $UUID_GRILLING 6 4" "claude codex $UUID_GRILLING $THREAD_GRILLING 6 4"; do
    read -r grilling answering expected_grilling expected_answering grilling_calls answering_calls <<<"$pair"
    setup_grill_repo
    git -C "$GRILL_REPO" checkout -q -b feature-work
    queue_two_round_run

    grill start --requirement-file "$REQUIREMENT_FILE" \
      --grilling-agent "$grilling" --answering-agent "$answering" >/dev/null

    record="$(<"$(only_session_dir)/session.json")"
    [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] \
      || fail "expected $grilling/$answering to reach the gate, got $(jq -c '{status, blockReason, failureReason}' <<<"$record")"
    [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$expected_grilling" ]] \
      || fail "expected $grilling/$answering grilling ID $expected_grilling"
    [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$expected_answering" ]] \
      || fail "expected $grilling/$answering answering ID $expected_answering"
    [[ "$(jq -c '.decisions | map_values(.decision)' <<<"$record")" \
      == '{"storage-backend":"postgres","export-format":"csv","sync-mode":"manual"}' ]] \
      || fail "expected $grilling/$answering decisions, got $(jq -c '.decisions' <<<"$record")"
    if [[ "$grilling" == "codex" ]]; then
      [[ "$(codex_call_count)" == "$grilling_calls" && "$(claude_call_count)" == "$answering_calls" ]] \
        || fail "expected codex to grill and claude to answer"
    else
      [[ "$(claude_call_count)" == "$grilling_calls" && "$(codex_call_count)" == "$answering_calls" ]] \
        || fail "expected claude to grill and codex to answer"
    fi
    teardown_grill_repo
  done
}

test_codex_argv_carries_role_access_policy() {
  local call argv config repo

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  repo="$(cd "$GRILL_REPO" && pwd -P)"

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent codex --answering-agent codex >/dev/null

  # Minimal run: calls 0002 and 0005 are the Answering Agent's.
  [[ "$(codex_call_count)" == "6" ]] || fail "expected six codex calls, got $(codex_call_count)"
  for call in 0001 0002 0003 0004 0005 0006; do
    argv="$(codex_argv "$call")"
    config="$(codex_config_values "$call")"
    [[ "$argv" != *"danger-full-access"* ]] || fail "call $call must never use danger-full-access"
    [[ "$argv" != *"--dangerously"* ]] || fail "call $call must never bypass the sandbox"
    [[ "$(codex_flag_value "$call" --ask-for-approval)" == "never" ]] || fail "expected call $call never to ask for approval"
    [[ "$(codex_flag_value "$call" --cd)" == "$repo" ]] || fail "expected call $call rooted at the repository"
    [[ "$(<"$FAKE_CODEX_DIR/calls/$call/pwd")" == "$repo" ]] || fail "expected call $call to run in the repository"
    case "$call" in
      0002|0005)
        # The profile alone sets read-only: an explicit --sandbox would
        # override it and drop its network grant.
        [[ -z "$(codex_flag_value "$call" --sandbox)" ]] || fail "expected answering call $call without --sandbox"
        jq -e 'index("default_permissions=\"ralph-answering\"")
          and index("permissions.ralph-answering.extends=\":read-only\"")
          and index("permissions.ralph-answering.network.enabled=true")' <<<"$config" >/dev/null \
          || fail "expected answering call $call to enable network under read-only, got $config"
        ! jq -e 'any(.[]; startswith("sandbox_workspace_write"))' <<<"$config" >/dev/null \
          || fail "expected no workspace-write settings on answering call $call"
        ;;
      *)
        [[ "$(codex_flag_value "$call" --sandbox)" == "workspace-write" ]] || fail "expected grilling call $call workspace-write"
        jq -e 'index("sandbox_workspace_write.network_access=true")
          and index("sandbox_workspace_write.exclude_tmpdir_env_var=true")
          and index("sandbox_workspace_write.exclude_slash_tmp=true")' <<<"$config" >/dev/null \
          || fail "expected grilling call $call with network and no tmp write roots, got $config"
        ;;
    esac
  done
  # The capability probe renders the same policies the calls use.
  [[ "$(jq -c 'map(select(. != "debug" and . != "prompt-input"))' "$FAKE_CODEX_DIR/probes.log" | sort -u | wc -l | tr -d ' ')" == "2" ]] \
    || fail "expected one probe policy per role"
  jq -e 'index("default_permissions=\"ralph-answering\"") and (index("--sandbox") | not)' \
    <<<"$(grep ralph-answering "$FAKE_CODEX_DIR/probes.log" | head -n 1)" >/dev/null \
    || fail "expected the answering probe to use the profile without --sandbox"

  teardown_grill_repo
}

test_codex_capability_failure_refuses_before_native_sessions() {
  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  export FAKE_CODEX_NO_READ_ONLY_NETWORK=1
  expect_start_failure "cannot express the required access policy" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent codex
  unset FAKE_CODEX_NO_READ_ONLY_NETWORK

  export FAKE_CODEX_HELP_OMIT="--output-schema"
  expect_start_failure "cannot express the required access policy" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent codex --answering-agent codex
  unset FAKE_CODEX_HELP_OMIT

  teardown_grill_repo
}

start_codex_then_rewind() {
  local session_id

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent codex --answering-agent codex | tail -n 1)"
  rewind_to_after_start "$GRILL_SESSIONS/$session_id"
  rm -rf "$FAKE_CODEX_DIR/calls"
  printf '%s\n' "$session_id"
}

test_codex_session_not_found_on_resume_is_context_lost() {
  local session_id session_dir output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_codex_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  mkdir -p "$FAKE_CODEX_DIR/lost"
  touch "$FAKE_CODEX_DIR/lost/$THREAD_GRILLING"

  set +e
  output="$(RALPH_RETRY_DELAYS=0 grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected a lost codex thread to fail resume"
  assert_contains "$output" "context_lost"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "context_lost" ]] || fail "expected context_lost record"
  [[ "$(codex_call_count)" == "1" ]] || fail "expected no retry or replacement after not found"
  [[ "$(codex_resumed_thread 0001)" == "$THREAD_GRILLING" ]] || fail "expected the stored thread resumed"
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl")" "no rollout found"

  teardown_grill_repo
}

test_codex_transient_failure_is_retried_in_the_same_thread() {
  local session_dir

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  touch "$FAKE_CODEX_DIR/exchanges/ex-0003.transient"

  RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent codex --answering-agent codex >/dev/null

  session_dir="$(only_session_dir)"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] || fail "expected the retry to reach the gate"
  [[ "$(codex_call_count)" == "7" ]] || fail "expected one extra call for the retry"
  [[ "$(codex_resumed_thread 0003)" == "$THREAD_GRILLING" ]] || fail "expected the failed call to resume the grilling thread"
  [[ "$(codex_resumed_thread 0004)" == "$THREAD_GRILLING" ]] || fail "expected the retry to resume the grilling thread"
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl.attempt-1")" "429"

  teardown_grill_repo
}

test_codex_kill_recovery_reemits_when_received_and_resends_when_not() {
  local mode session_dir record prompt status

  for mode in received lost; do
    setup_grill_repo
    git -C "$GRILL_REPO" checkout -q -b feature-work
    queue_two_round_run
    printf '%s\n' "$mode" > "$FAKE_CODEX_DIR/exchanges/ex-0004.kill"

    status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" --grilling-agent codex --answering-agent codex)"

    [[ "$status" -ne 0 ]] || fail "expected the killed coordinator to exit non-zero ($mode)"
    session_dir="$(only_session_dir)"
    [[ "$(exchange_status "$session_dir" ex-0004)" =~ ^(intent|sent)$ ]] || fail "expected ex-0004 left in flight ($mode)"
    rm -rf "$FAKE_CODEX_DIR/calls"

    grill resume --id "$(basename "$session_dir")" >/dev/null

    record="$(<"$session_dir/session.json")"
    [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate ($mode)"
    [[ "$(jq -r '.exchanges[] | select(.id == "ex-0004") | .received' <<<"$record")" \
      == "$([[ "$mode" == "received" ]] && echo yes || echo no)" ]] || fail "expected received answer for $mode"
    [[ "$(codex_resumed_thread 0001)" == "$THREAD_ANSWERING" ]] || fail "expected the answering thread resumed ($mode)"
    prompt="$(codex_prompt 0001)"
    assert_contains "$prompt" "[ralph-exchange:ex-0004]"
    if [[ "$mode" == "received" ]]; then
      assert_contains "$prompt" "Re-emit your reply to exchange ex-0004"
    else
      assert_contains "$prompt" "Where are exports stored?"
      [[ "$prompt" != *"Re-emit your reply"* ]] || fail "expected the original round, not a re-emit"
    fi
    teardown_grill_repo
  done
}

# --- Review fixes for PR #61 ---

# Codex sends --output-schema as a strict response format: every object must
# set additionalProperties false and list every property as required, and a
# union may only make a value nullable.
test_output_schemas_are_strict() {
  local schema

  for schema in "$ROOT_DIR"/prompts/grill/schemas/*.schema.json; do
    jq -e '[.. | objects | select(has("properties"))]
      | length > 0
        and all(.[]; .additionalProperties == false and ((.required // []) | sort) == (.properties | keys | sort))' \
      "$schema" >/dev/null || fail "expected every object in $(basename "$schema") strict"
    jq -e '[.. | objects | select(has("oneOf") or has("allOf"))] | length == 0' "$schema" >/dev/null \
      || fail "expected no oneOf/allOf in $(basename "$schema")"
    # The Claude CLI rejects a $schema dialect it cannot resolve.
    jq -e 'has("$schema") | not' "$schema" >/dev/null || fail "expected no \$schema key in $(basename "$schema")"
    jq -e '[.. | objects | select(has("anyOf")) | .anyOf | any(.[]; . == {"type": "null"})] | all' "$schema" >/dev/null \
      || fail "expected anyOf only for nullable values in $(basename "$schema")"
  done
}

# Messages in the strict shape (unused members null) validate like their
# sparse equivalents, and nulls never reach the record.
test_strict_shape_messages_with_nulls_reach_the_gate() {
  local session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  exchange_fixture ex-0003 '{"exchangeId":"ex-0003","round":1,
    "questions":[{"id":"storage-backend","title":"Where are exports stored?","body":"Pick one.",
      "choices":[{"id":"sqlite","label":"SQLite","description":null}],
      "recommendation":{"choiceId":null,"text":"Use a local file","rationale":"No server."},
      "challenges":null}],
    "reopens":null}'
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":null,"text":"A local SQLite file","rationale":"No server.","evidence":["README.md"]}],
    "needsHuman":null}'
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","round":2,"questions":[],"reopens":null}'
  exchange_fixture ex-0006 "$(summary_fixture ex-0006 "- Storage: SQLite.")"
  exchange_fixture ex-0007 '{"exchangeId":"ex-0007","faithful":false,
    "discrepancies":[{"questionId":null,"problem":"Tone.","fix":"None needed."}]}'
  exchange_fixture ex-0008 "$(summary_fixture ex-0008 "- Storage: SQLite.")"

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected strict-shape messages to reach the gate"
  [[ "$(jq -c '.decisions["storage-backend"].decision' <<<"$record")" == '"A local SQLite file"' ]] \
    || fail "expected the free-text decision, got $(jq -c '.decisions' <<<"$record")"
  ! grep -q 'null' "$session_dir/messages/ex-0004.json" || fail "expected null members dropped from the saved message"

  teardown_grill_repo
}

# An `&` (and other replacement metacharacters) in the requirement reaches
# both Agents verbatim.
test_requirement_text_reaches_the_agents_verbatim() {
  local prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '# R&D export\n\nRun make && make test, then copy a\\&b and {{REPO_ROOT}}.\n' > "$REQUIREMENT_FILE"

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1

  for call in 0001 0002; do
    prompt="$(claude_flag_value "$call" -p)"
    assert_contains "$prompt" "# R&D export"
    assert_contains "$prompt" 'Run make && make test, then copy a\&b and {{REPO_ROOT}}.'
    [[ "$prompt" != *"{{REQUIREMENT}}"* ]] || fail "expected no placeholder in call $call"
  done

  teardown_grill_repo
}

# Without refs/remotes/origin/HEAD the default branch comes from the remote's
# own HEAD, and an unknown default branch refuses to start instead of
# guessing.
test_default_branch_falls_back_to_the_remote_head_and_never_guesses() {
  local branch

  setup_grill_repo
  git -C "$GRILL_REPO" remote set-head origin -d
  git -C "$GRILL_REPO" config init.defaultBranch trunk

  grill start --issue 51 --grilling-agent claude --answering-agent claude >/dev/null 2>&1
  branch="$(git -C "$GRILL_REPO" branch --show-current)"
  [[ "$branch" == "grill/issue-51-add-dark-mode" ]] || fail "expected a planning branch from the remote HEAD, got $branch"
  [[ "$(jq -r '.repo.defaultBranch' "$(only_session_dir)/session.json")" == "main" ]] || fail "expected default branch main"

  git -C "$GRILL_REPO" checkout -q main
  rm -rf "$GRILL_SESSIONS" "$FAKE_CLAUDE_DIR/calls"
  git -C "$GRILL_REPO" remote set-url origin "$GRILL_TMP/missing.git"
  expect_start_failure "could not determine the default branch of remote 'origin'" \
    --issue 52 --grilling-agent claude --answering-agent claude
  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "main" ]] || fail "expected no branch change on refusal"

  teardown_grill_repo
}

# Starts a two-round session on feature-work with an approve decision written
# at the gate and prints its ID.
start_approved_session() {
  local session_id

  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  write_confirmation_decision "$GRILL_SESSIONS/$session_id/confirmation.md" approve
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  : > "$FAKE_GH_LOG"
  printf '%s\n' "$session_id"
}

test_approve_waits_for_the_session_branch_to_be_checked_out() {
  local session_id session_dir head output

  setup_grill_repo
  session_id="$(start_approved_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  git -C "$GRILL_REPO" checkout -q -b elsewhere
  head="$(git -C "$GRILL_REPO" rev-parse HEAD)"

  output="$(grill resume --id "$session_id" 2>&1)"

  assert_contains "$output" "Not approved: the session's branch is feature-work but elsewhere is checked out"
  [[ "$(git -C "$GRILL_REPO" rev-parse HEAD)" == "$head" ]] || fail "expected no commit on the wrong branch"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "blocked" ]] || fail "expected the session to stay at the gate"
  [[ -z "$(gh_writes)" ]] || fail "expected no issue write"

  git -C "$GRILL_REPO" checkout -q feature-work
  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(git -C "$GRILL_REPO" show --name-only --format= feature-work)" == "CONTEXT.md" ]] \
    || fail "expected the docs commit on feature-work"
  [[ "$(git -C "$GRILL_REPO" rev-parse elsewhere)" == "$head" ]] || fail "expected elsewhere untouched"
  assert_archived "$session_id" completed

  teardown_grill_repo
}

test_approve_refuses_an_applying_commit_on_another_branch() {
  local session_id session_dir output status

  setup_grill_repo
  session_id="$(start_approved_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  jq '.status = "applying" | .blockReason = null' "$session_dir/session.json" > "$GRILL_TMP/applying.json"
  cp "$GRILL_TMP/applying.json" "$session_dir/session.json"
  git -C "$GRILL_REPO" checkout -q -b elsewhere

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected applying on the wrong branch to fail"
  assert_contains "$output" "the session's branch feature-work is not checked out"
  [[ "$(jq -c '.apply.commit' "$session_dir/session.json")" == "null" ]] || fail "expected no commit recorded"
  [[ "$(git -C "$GRILL_REPO" rev-parse elsewhere)" == "$(git -C "$GRILL_REPO" rev-parse main)" ]] \
    || fail "expected no commit on elsewhere"

  teardown_grill_repo
}

# A change made after the gate was written is flagged before anything is
# committed: approve rewrites confirmation.md and asks again.
test_approve_reflags_changes_made_after_the_gate() {
  local session_id session_dir output confirmation

  setup_grill_repo
  session_id="$(start_approved_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'x\n' > "$GRILL_REPO/notes.txt"

  output="$(grill resume --id "$session_id" 2>&1)"

  assert_contains "$output" "Not approved: the repository changed after the gate was written"
  confirmation="$(<"$session_dir/confirmation.md")"
  assert_contains "$confirmation" 'Changed outside CONTEXT.md and docs/adr/: `notes.txt`'
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "blocked" ]] || fail "expected the session to stay at the gate"
  [[ "$(git -C "$GRILL_REPO" rev-list --count HEAD)" == "1" ]] || fail "expected no commit"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls"

  write_confirmation_decision "$session_dir/confirmation.md" approve
  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(git -C "$GRILL_REPO" show --name-only --format= HEAD)" == "CONTEXT.md" ]] || fail "expected only CONTEXT.md committed"
  assert_contains "$(git -C "$GRILL_REPO" status --porcelain --untracked-files=all)" "?? notes.txt"
  assert_archived "$session_id" completed

  teardown_grill_repo
}

# A crash after an answers exchange completes but before its decisions are
# merged loses nothing: resume applies them first.
test_resume_applies_answers_a_crash_left_unapplied() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  jq '.status = "grilling" | .blockReason = null | .round = 1 | .decisions = {}
    | .exchanges |= (.[:4] | map(del(.effectsApplied)))' "$session_dir/session.json" > "$GRILL_TMP/crashed.json"
  cp "$GRILL_TMP/crashed.json" "$session_dir/session.json"
  rm -f "$session_dir/confirmation.md"
  rm -rf "$FAKE_CLAUDE_DIR/calls" "$FAKE_CLAUDE_DIR/seen"

  grill resume --id "$session_id" >/dev/null 2>&1

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(jq -c '.decisions | map_values(.exchangeId)' <<<"$record")" \
    == '{"storage-backend":"ex-0006","export-format":"ex-0004","sync-mode":"ex-0006"}' ]] \
    || fail "expected ex-0004's decisions applied on resume, got $(jq -c '.decisions' <<<"$record")"
  assert_contains "$(claude_flag_value 0001 -p)" "[ralph-exchange:ex-0005]"
  assert_contains "$(claude_flag_value 0001 -p)" "export-format"

  teardown_grill_repo
}

test_resume_blocks_on_a_needs_human_reply_a_crash_left_unapplied() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  jq '.status = "grilling" | .blockReason = null | .humanInputPath = null
    | .exchanges |= map(del(.effectsApplied))' "$session_dir/session.json" > "$GRILL_TMP/crashed.json"
  cp "$GRILL_TMP/crashed.json" "$session_dir/session.json"
  rm -f "$session_dir/human-input-ex-0004.md"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "needs_human" ]] || fail "expected the needsHuman reply to block on resume"
  [[ -f "$session_dir/human-input-ex-0004.md" ]] || fail "expected the human-input file rewritten"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent call before the human answers"

  teardown_grill_repo
}

# A crash right after leaving the block, before the human_input exchange is
# recorded, still sends the human's input on resume.
test_resume_sends_human_input_a_crash_left_unsent() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'Exports are shared across devices, so use Postgres.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"The human says exports are shared.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["README.md"]}]}'
  queue_closing_from 6 2
  jq '.status = "grilling" | .lastBlockReason = .blockReason | .blockReason = null
    | .pendingHumanInput = {blockReason: "needs_human", afterExchanges: (.exchanges | length)}' \
    "$session_dir/session.json" > "$GRILL_TMP/crashed.json"
  cp "$GRILL_TMP/crashed.json" "$session_dir/session.json"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the human input sent to the Answering session"
  assert_contains "$(claude_flag_value 0001 -p)" "Exports are shared across devices, so use Postgres."
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -c '[.exchanges[4:6][] | [.id, .kind]]' <<<"$record")" \
    == '[["ex-0005","human_input"],["ex-0006","correction_relay"]]' ]] || fail "expected human_input then correction_relay"
  [[ "$(jq -c '.pendingHumanInput' <<<"$record")" == "null" ]] || fail "expected pendingHumanInput cleared"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected grilling to continue to the gate"

  teardown_grill_repo
}

test_transient_failures_past_the_last_retry_block_and_resume_retries() {
  local session_dir record output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '2\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0003.transient"

  RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null 2>&1

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected blocked, got $(jq -r '.status' <<<"$record")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "transient_failure" ]] || fail "expected transient_failure"
  [[ "$(exchange_status "$session_dir" ex-0003)" == "sent" ]] || fail "expected ex-0003 kept in flight"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$UUID_GRILLING" ]] || fail "expected the native session kept"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  output="$(grill resume --id "$(basename "$session_dir")" 2>&1)"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate: $output"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006"]' ]] || fail "expected no new exchange for the retry"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_GRILLING" ]] || fail "expected the same native session resumed"

  teardown_grill_repo
}

test_retried_provider_logs_stay_owner_only_and_appear_in_logs() {
  local session_dir log output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  touch "$FAKE_CLAUDE_DIR/exchanges/ex-0003.transient"

  (umask 022 && RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null 2>&1)

  session_dir="$(only_session_dir)"
  for log in "$session_dir"/logs/*; do
    [[ "$(file_mode "$log")" == "600" ]] || fail "expected $(basename "$log") mode 600, got $(file_mode "$log")"
  done
  [[ -f "$session_dir/logs/ex-0003-grilling.jsonl.attempt-1" ]] || fail "expected the failed attempt kept"

  output="$(grill logs --id "$(basename "$session_dir")")"
  assert_contains "$output" "-- log, failed attempt 1"

  teardown_grill_repo
}

test_codex_retried_logs_stay_owner_only() {
  local session_dir log

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  touch "$FAKE_CLAUDE_DIR/exchanges/ex-0003.transient"

  (umask 022 && RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent codex --answering-agent codex >/dev/null 2>&1)

  session_dir="$(only_session_dir)"
  [[ -f "$session_dir/logs/ex-0003-grilling.jsonl.attempt-1" ]] || fail "expected the failed codex attempt kept"
  for log in "$session_dir"/logs/*; do
    [[ "$(file_mode "$log")" == "600" ]] || fail "expected $(basename "$log") mode 600, got $(file_mode "$log")"
  done

  teardown_grill_repo
}

# When the native store gives no answer (unknown), a crashed exchange is
# re-emitted, never resent.
test_kill_recovery_reemits_when_receipt_is_unknown() {
  local provider status session_dir prompt

  for provider in claude codex; do
    setup_grill_repo
    git -C "$GRILL_REPO" checkout -q -b feature-work
    queue_two_round_run
    printf 'received\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0004.kill"

    status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" \
      --grilling-agent "$provider" --answering-agent "$provider")"
    [[ "$status" -ne 0 ]] || fail "expected the killed $provider coordinator to exit non-zero"
    session_dir="$(only_session_dir)"
    rm -rf "$CLAUDE_CONFIG_DIR/projects" "$CODEX_HOME/sessions"
    rm -rf "$FAKE_CLAUDE_DIR/calls" "$FAKE_CODEX_DIR/calls"

    grill resume --id "$(basename "$session_dir")" >/dev/null 2>&1

    [[ "$(jq -r '.exchanges[] | select(.id == "ex-0004") | [.received, .recovery] | join(":")' "$session_dir/session.json")" \
      == "unknown:reemit" ]] || fail "expected $provider unknown receipt to re-emit"
    if [[ "$provider" == "claude" ]]; then
      prompt="$(claude_flag_value 0001 -p)"
    else
      prompt="$(codex_prompt 0001)"
    fi
    assert_contains "$prompt" "Re-emit your reply to exchange ex-0004"
    [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] \
      || fail "expected $provider recovery to reach the gate"
    assert_contains "$(grill logs --id "$(basename "$session_dir")")" "-- recovery"

    teardown_grill_repo
  done
}

# TERM to the coordinator alone stops the running Agent call at once,
# releases the lock and leaves the exchange in flight for resume.
test_term_to_the_coordinator_stops_the_agent_call_and_releases_the_lock() {
  local pid session_dir started elapsed status=0

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  exchange_effect ex-0003 "touch '$GRILL_TMP/in-ex-0003'; sleep 37"

  (cd "$GRILL_REPO" && PATH="$GRILL_TMP/bin:$PATH" exec "$GRILL_RALPH" grill start \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude) >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [[ ! -f "$GRILL_TMP/in-ex-0003" ]] || break
    sleep 0.1
  done
  [[ -f "$GRILL_TMP/in-ex-0003" ]] || fail "expected ex-0003 to start"

  started="$(date +%s)"
  kill -TERM "$pid"
  wait "$pid" || status=$?
  elapsed=$(( $(date +%s) - started ))

  [[ "$status" -eq 143 ]] || fail "expected exit 143 on TERM, got $status"
  [[ "$elapsed" -le 5 ]] || fail "expected the coordinator to stop within 5s, took ${elapsed}s"
  ! pgrep -f "sleep 37" >/dev/null || fail "expected the Agent call's processes stopped"
  session_dir="$(only_session_dir)"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the lock released"
  [[ "$(exchange_status "$session_dir" ex-0003)" == "sent" ]] || fail "expected ex-0003 left in flight"

  rm -f "$FAKE_CLAUDE_DIR/exchanges/ex-0003.sh"
  grill resume --id "$(basename "$session_dir")" >/dev/null 2>&1
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"

  teardown_grill_repo
}

# A create that succeeded before a crash is found by its session marker on
# retry, so no duplicate issue is created.
test_interrupted_issue_create_is_found_instead_of_duplicated() {
  local session_id session_dir status=0 record

  setup_grill_repo
  session_id="$(start_approved_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  touch "$GRILL_TMP/create-crash"

  FAKE_GH_CREATE_CRASH_ONCE="$GRILL_TMP/create-crash" FAKE_GH_CREATED_ISSUE=91 \
    grill resume --id "$session_id" >/dev/null 2>&1 || status=$?

  [[ "$status" -ne 0 ]] || fail "expected the interrupted create to fail"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "applying" ]] || fail "expected applying"
  [[ "$(jq -c '.apply.issue' "$session_dir/session.json")" == "null" ]] || fail "expected the issue unrecorded"

  FAKE_GH_CREATED_ISSUE=92 grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(jq -c 'select(.[0] == "issue" and .[1] == "create")' "$FAKE_GH_LOG" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "expected exactly one gh issue create"
  jq -e 'select(.[0] == "issue" and .[1] == "list")' "$FAKE_GH_LOG" >/dev/null || fail "expected the retry to look for the issue"
  record="$(<"$(archived_session_dir "$session_id")/session.json")"
  [[ "$(jq -r '.apply.issue.url' <<<"$record")" == "https://github.com/acme/target/issues/91" ]] \
    || fail "expected the first created issue recorded, got $(jq -c '.apply.issue' <<<"$record")"

  teardown_grill_repo
}

test_failed_issue_edit_is_retried_alone_on_resume() {
  local session_id session_dir status=0 commits

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --issue 51 --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  write_confirmation_decision "$session_dir/confirmation.md" approve
  : > "$FAKE_GH_LOG"
  touch "$GRILL_TMP/gh-fail"

  FAKE_GH_FAIL_ONCE="$GRILL_TMP/gh-fail" grill resume --id "$session_id" >/dev/null 2>&1 || status=$?

  [[ "$status" -ne 0 ]] || fail "expected the failed edit to exit non-zero"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "applying" ]] || fail "expected applying"
  [[ "$(jq -c '.apply.push != null' "$session_dir/session.json")" == "true" ]] || fail "expected the push recorded"
  commits="$(git -C "$GRILL_REPO" rev-list --count HEAD)"

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(git -C "$GRILL_REPO" rev-list --count HEAD)" == "$commits" ]] || fail "expected no new commit"
  [[ "$(gh_writes | wc -l | tr -d ' ')" == "2" ]] || fail "expected the failed edit and its retry, got: $(gh_writes)"
  assert_archived "$session_id" completed

  teardown_grill_repo
}

# Target repositories often ignore the Ralph directory (or its session
# storage); the gate's diff must still work there.
test_gate_works_when_ralph_session_storage_is_gitignored() {
  local session_dir

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf 'ralph/grilling-sessions/\nralph/archive/\n' >> "$GRILL_REPO/.git/info/exclude"
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1

  session_dir="$(only_session_dir)"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] \
    || fail "expected the gate with ignored session storage, got $(jq -r '.status' "$session_dir/session.json")"
  assert_contains "$(<"$session_dir/confirmation.md")" "Offline Export"
  assert_contains "$(<"$session_dir/confirmation.md")" "- No flags."

  teardown_grill_repo
}

# A crash after a needsHuman block is written but before its exchange is
# marked applied must not re-block on resume and wipe the human's input.
test_resume_keeps_human_input_when_the_blocking_exchange_was_left_unmarked() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  jq '.exchanges |= map(del(.effectsApplied))' "$session_dir/session.json" > "$GRILL_TMP/crashed.json"
  cp "$GRILL_TMP/crashed.json" "$session_dir/session.json"
  printf 'Exports are shared across devices, so use Postgres.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"The human says exports are shared.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["README.md"]}]}'
  queue_closing_from 6 2
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  assert_contains "$(<"$session_dir/human-input-ex-0004.md")" "Exports are shared across devices, so use Postgres."
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the human input sent"
  assert_contains "$(claude_flag_value 0001 -p)" "Exports are shared across devices, so use Postgres."
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected grilling to continue to the gate"

  teardown_grill_repo
}

test_reject_waits_for_the_session_branch_to_be_checked_out() {
  local session_id session_dir output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  write_confirmation_decision "$session_dir/confirmation.md" reject
  git -C "$GRILL_REPO" checkout -q -b elsewhere

  output="$(grill resume --id "$session_id" 2>&1)"

  assert_contains "$output" "Not rejected: the session's branch is feature-work but elsewhere is checked out"
  assert_contains "$(<"$GRILL_REPO/CONTEXT.md")" "Offline Export"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "blocked" ]] || fail "expected the session to stay at the gate"

  git -C "$GRILL_REPO" checkout -q feature-work
  grill resume --id "$session_id" >/dev/null 2>&1
  [[ ! -e "$GRILL_REPO/CONTEXT.md" ]] || fail "expected the session's CONTEXT.md discarded on its branch"
  assert_archived "$session_id" rejected

  teardown_grill_repo
}

# Placeholders are filled in one pass: text a human (or an Agent) writes that
# quotes another placeholder reaches the Agents verbatim.
test_human_input_quoting_placeholders_reaches_the_agent_verbatim() {
  local session_id session_dir

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'Please reconsider {{DECISIONS}} and {{QUESTIONS}}; R&D says \\1.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"Human input.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Spreadsheets.","evidence":["README.md"]}]}'
  queue_closing_from 6 2
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  assert_contains "$(claude_flag_value 0001 -p)" 'Please reconsider {{DECISIONS}} and {{QUESTIONS}}; R&D says \1.'

  teardown_grill_repo
}

# A crash after an exchange's one re-emit request was sent spends that
# re-emit: an invalid reply to the recovery blocks instead of earning another.
test_invalid_reply_after_a_crashed_reemit_blocks_without_another_reemit() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  jq '.exchanges += [{id: "ex-0003", kind: "frontier", role: "grilling", status: "sent", reemitRequested: true,
        logPath: "logs/ex-0003-grilling.jsonl", reemitLogPath: "logs/ex-0003-grilling-reemit.jsonl",
        received: "yes", recovery: "reemit"}] | .round = 1' "$session_dir/session.json" > "$GRILL_TMP/crashed.json"
  cp "$GRILL_TMP/crashed.json" "$session_dir/session.json"
  exchange_fixture ex-0003 'not json'

  grill resume --id "$session_id" >/dev/null 2>&1

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "invalid_message" ]] || fail "expected invalid_message, got $(jq -r '.status' <<<"$record")"
  [[ "$(claude_call_count)" == "1" ]] || fail "expected only the recovery call, got $(claude_call_count)"
  assert_contains "$(claude_flag_value 0001 -p)" "## Recover"

  teardown_grill_repo
}

test_claude_settings_deny_git_index_and_gh_write_commands() {
  local settings rule

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1

  for call in 0001 0002; do
    settings="$(claude_flag_value "$call" --settings)"
    jq -e '.permissions.deny | index("Edit(./.git/**)")' <<<"$settings" >/dev/null \
      || fail "expected call $call to keep .git unwritable"
    for rule in "Bash(git add:*)" "Bash(git rm:*)" "Bash(git restore:*)" "Bash(git clean:*)" \
      "Bash(gh release create:*)" "Bash(gh label create:*)" "Bash(gh repo edit:*)" \
      "Bash(gh workflow run:*)" "Bash(gh pr close:*)" "Bash(gh pr review:*)"; do
      jq -e --arg rule "$rule" '.permissions.deny | index($rule)' <<<"$settings" >/dev/null \
        || fail "expected call $call to deny $rule"
    done
    ! jq -e '.permissions.deny | index("Bash(gh run view:*)") or index("Bash(gh release view:*)")' <<<"$settings" >/dev/null \
      || fail "expected gh reads left allowed"
    jq -e '.sandbox.network.allowedDomains | index("api.github.com")' <<<"$settings" >/dev/null \
      || fail "expected sandboxed gh to reach the GitHub API in call $call"
    [[ "$(jq -r '.sandbox.enableWeakerNetworkIsolation' <<<"$settings")" == "true" ]] \
      || fail "expected gh TLS verification allowed in call $call"
  done

  teardown_grill_repo
}

run_test test_start_rejects_invalid_inputs
run_test test_start_creates_owner_only_record_with_frozen_config
run_test test_start_opens_two_distinct_native_claude_sessions
run_test test_start_fails_when_native_ids_are_equal
run_test test_adapter_argv_carries_role_access_policy
run_test test_capability_failure_refuses_before_native_sessions
run_test test_start_refuses_dirty_worktree
run_test test_start_ignores_ralph_session_storage_in_dirty_check
run_test test_start_on_default_branch_creates_issue_planning_branch
run_test test_start_on_default_branch_creates_requirement_planning_branch
run_test test_start_refuses_existing_planning_branch
run_test test_grilling_sessions_are_gitignored
run_test test_start_relays_frontier_rounds_to_the_confirmation_gate
run_test test_every_exchange_after_start_resumes_the_stored_native_session
run_test test_answers_merge_into_decisions_and_reopens_route_the_contradiction
run_test test_partial_answer_set_is_invalid
run_test test_answer_without_evidence_is_invalid
run_test test_invalid_message_followed_by_a_valid_reemit_continues
run_test test_confirmation_flags_out_of_scope_changes_and_head_drift
run_test test_confirmation_without_drift_has_no_flags
run_test test_provider_logs_are_owner_only_per_exchange_and_role
run_test test_resume_continues_a_grilling_session_to_the_gate
run_test test_resume_rejects_configuration_flags
run_test test_needs_human_blocks_with_a_human_input_file
run_test test_resume_with_empty_answers_prints_the_input_file_without_agent_calls
run_test test_resume_routes_human_input_to_answering_then_grilling
run_test test_identical_frontier_without_reopens_blocks_as_no_progress
run_test test_correct_at_the_gate_routes_answering_then_grilling_back_to_the_gate
run_test test_gate_text_without_a_correct_decision_contacts_no_agent
run_test test_unrecognized_gate_decision_prints_what_to_write_without_agent_calls
run_test test_approve_on_an_issue_session_commits_docs_pushes_and_edits_the_issue
run_test test_approve_on_a_requirement_file_session_creates_the_issue
run_test test_failed_push_leaves_applying_and_resume_retries_only_push_and_issue
run_test test_reject_restores_docs_and_leaves_out_of_scope_changes
run_test test_status_logs_and_cleanup_require_a_known_id
run_test test_status_shows_state_agents_and_next_action_without_raw_content
run_test test_logs_summarize_activity_per_role_and_exchange
run_test test_cleanup_deletes_terminal_sessions_and_refuses_active_ones
run_test test_cleanup_deletes_a_crashed_start_but_not_a_running_one

run_test test_resume_fails_on_a_live_lock_and_reclaims_a_dead_one
run_test test_lock_reclaim_is_guarded_and_never_steals_a_fresh_lock
run_test test_sessions_with_different_ids_hold_their_locks_at_once
run_test test_kill_mid_exchange_leaves_it_in_flight_and_resume_reemits_when_received
run_test test_resume_after_a_kill_resends_an_exchange_the_session_never_received
run_test test_transient_failure_is_retried_within_the_same_exchange_and_session
run_test test_session_not_found_on_resume_is_context_lost
run_test test_resume_on_a_terminal_record_fails
run_test test_answering_agent_creating_a_file_fails_as_policy_violation
run_test test_answering_agent_modifying_a_file_in_summary_review_fails_as_policy_violation
run_test test_answering_agent_commit_fails_as_policy_violation
run_test test_answering_agent_mutation_during_human_input_fails_as_policy_violation
run_test test_grilling_agent_doc_edits_are_not_a_policy_violation
run_test test_codex_pair_stores_two_distinct_captured_thread_ids
run_test test_mixed_agent_pairs_reach_the_confirmation_gate
run_test test_codex_argv_carries_role_access_policy
run_test test_codex_capability_failure_refuses_before_native_sessions
run_test test_codex_session_not_found_on_resume_is_context_lost
run_test test_codex_transient_failure_is_retried_in_the_same_thread
run_test test_codex_kill_recovery_reemits_when_received_and_resends_when_not

run_test test_output_schemas_are_strict
run_test test_strict_shape_messages_with_nulls_reach_the_gate
run_test test_requirement_text_reaches_the_agents_verbatim
run_test test_default_branch_falls_back_to_the_remote_head_and_never_guesses
run_test test_approve_waits_for_the_session_branch_to_be_checked_out
run_test test_approve_refuses_an_applying_commit_on_another_branch
run_test test_approve_reflags_changes_made_after_the_gate
run_test test_resume_applies_answers_a_crash_left_unapplied
run_test test_resume_blocks_on_a_needs_human_reply_a_crash_left_unapplied
run_test test_resume_sends_human_input_a_crash_left_unsent
run_test test_transient_failures_past_the_last_retry_block_and_resume_retries
run_test test_retried_provider_logs_stay_owner_only_and_appear_in_logs
run_test test_codex_retried_logs_stay_owner_only
run_test test_kill_recovery_reemits_when_receipt_is_unknown
run_test test_term_to_the_coordinator_stops_the_agent_call_and_releases_the_lock
run_test test_interrupted_issue_create_is_found_instead_of_duplicated
run_test test_failed_issue_edit_is_retried_alone_on_resume
run_test test_claude_settings_deny_git_index_and_gh_write_commands
run_test test_gate_works_when_ralph_session_storage_is_gitignored
run_test test_resume_keeps_human_input_when_the_blocking_exchange_was_left_unmarked
run_test test_reject_waits_for_the_session_branch_to_be_checked_out
run_test test_human_input_quoting_placeholders_reaches_the_agent_verbatim
run_test test_invalid_reply_after_a_crashed_reemit_blocks_without_another_reemit

echo "grill_test.sh passed"
