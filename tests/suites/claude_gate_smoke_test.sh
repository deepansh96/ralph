#!/usr/bin/env bash
set -euo pipefail

# Harness checks for the opt-in live Claude gate smoke test
# (tests/probes/claude-gate-smoke.sh). A fake `claude` plays the QA parent
# through the real runner, real hooks, and the smoke test's local `gh` stub.
# The live test itself never runs here: it needs real Claude credentials.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$ROOT/tests/probes/claude-gate-smoke.sh"
ISSUE=9948
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP" "${ROOT:?}/workspaces/$ISSUE"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/fake-bin" "$TMP/profile"
cat > "$TMP/fake-bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
mode="${FAKE_SMOKE_MODE:-verified}"
case "${1:-}" in
  auth)
    if [[ "$mode" == logged-out ]]; then echo '{"loggedIn":false}'; exit 1; fi
    echo '{"loggedIn":true}'; exit 0 ;;
  --version) echo '2.1.282 (Claude Code)'; exit 0 ;;
esac
printf 'run\n' >> "$FAKE_CALLS"
prompt="" settings="" session=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --settings) settings="$2"; shift 2 ;;
    --session-id) session="$2"; shift 2 ;;
    *) shift ;;
  esac
done
workspace="$(awk '/^Workspace:/ { print $2; exit }' <<< "$prompt")"
repo="$(awk '/^Repo:/ { print $2; exit }' <<< "$prompt")"
step="$(awk '/^Step:/ { print $2; exit }' <<< "$prompt")"
# The parent finds the marked comment, plans, and spawns from the project root.
id="$(gh api "repos/$repo/issues/1/comments" --jq '.[] | select(.body | contains("<!-- ralph:qa-checklist -->")) | .id')"
source ./ralph/scripts/delegation-qa.sh
plan="$(delegation_qa_plan_write "$workspace/state.json" "$step" "$repo" "$id" <<< '[{"taskId":"qa_group_1","checklistItemIds":["QA-01"]}]')"
digest="$(jq -r '.assignments[0].assignmentDigest' <<< "$plan")"
hook() {
  local command
  command="$(jq -r --arg event "$1" '.hooks[$event][0].hooks[0].command' "$settings")"
  jq -c --arg event "$1" --arg session "$session" '. + {hook_event_name: $event, session_id: $session}' <<< "$2" | bash -c "$command"
}
if [[ "$mode" != no-worker ]]; then
  packet="$(printf 'RALPH-TASK: qa_group_1\nRALPH-ASSIGNMENT: %s\nRALPH-RUN: 1\nSMOKE-PROMPT-TEXT' "$digest")"
  hook PreToolUse "$(jq -nc --arg packet "$packet" '{tool_name:"Agent",tool_use_id:"toolu_smoke1",tool_input:{subagent_type:"ralph-worker",prompt:$packet}}')"
  hook SubagentStart '{"agent_id":"agent_smoke1","agent_type":"ralph-worker"}'
  if [[ "$mode" == observed ]]; then
    hook SubagentStop '{"agent_id":"agent_smoke1","agent_type":"ralph-worker","last_assistant_message":"SMOKE-RESPONSE-TEXT"}'
    hook PostToolUse '{"tool_name":"Agent","tool_use_id":"toolu_smoke1","tool_response":{"agentId":"agent_smoke1","status":"completed","content":"SMOKE-RESPONSE-TEXT"}}'
  else
    hook SubagentStop '{"agent_id":"agent_smoke1","agent_type":"ralph-worker","effort":{"level":"high"},"last_assistant_message":"SMOKE-RESPONSE-TEXT"}'
    hook PostToolUse '{"tool_name":"Agent","tool_use_id":"toolu_smoke1","tool_response":{"agentId":"agent_smoke1","status":"completed","resolvedModel":"claude-sonnet-5","modelsUsed":["claude-sonnet-5"],"content":"SMOKE-RESPONSE-TEXT"}}'
  fi
fi
if [[ "$mode" == tamper ]]; then
  printf '{"hooks":{}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
fi
if [[ "$mode" != no-edit ]]; then
  body="$(gh api "repos/$repo/issues/comments/$id" --jq .body | sed 's/^- \[ \] \[PENDING\] QA-01/- [x] [PASS] QA-01/')"
  gh api -X PATCH "repos/$repo/issues/comments/$id" -f body="$body" >/dev/null
fi
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"done","duration_ms":5,"usage":{"input_tokens":3,"output_tokens":2},"total_cost_usd":0.01}'
FAKE
chmod +x "$TMP/fake-bin/claude"

# run_smoke NAME MODE [ENV...]: fresh empty scratch directory per run, named
# like a registered ledger path (which itself matches the hook-input prefix).
run_smoke() {
  local name="$1" mode="$2"
  shift 2
  mkdir -p "$TMP/$name/ralph-37-claude-gate-smoke"
  set +e
  SMOKE_OUTPUT="$(env PATH="$TMP/fake-bin:$PATH" FAKE_SMOKE_MODE="$mode" FAKE_CALLS="$TMP/$name.calls" \
    RALPH_CLAUDE_GATE_SMOKE=1 RALPH_CLAUDE_SMOKE_ISSUE="$ISSUE" CLAUDE_CONFIG_DIR="$TMP/profile" \
    RALPH_RETRY_DELAYS="0 0 0" "$@" "$SMOKE" "$TMP/$name/ralph-37-claude-gate-smoke" 2>&1)"
  SMOKE_STATUS=$?
  set -e
}

assert_output() {
  [[ "$SMOKE_OUTPUT" == *"$1"* ]] || fail "expected smoke output to contain '$1': $SMOKE_OUTPUT"
}

assert_not_run() {
  [[ ! -e "$TMP/$1.calls" ]] || fail "expected no provider run for $1"
}

assert_cleaned() {
  [[ ! -e "$ROOT/workspaces/$ISSUE" ]] || fail "expected smoke workspace removed after $1"
  [[ -z "$(ls -A "$TMP/$1/ralph-37-claude-gate-smoke")" ]] || fail "expected scratch contents removed after $1"
}

# The default suite never runs the live test.
if grep -q 'probes' "$ROOT/tests/run.sh"; then fail "tests/run.sh must not reference opt-in probes"; fi
[[ ! -e "$ROOT/tests/suites/claude-gate-smoke.sh" ]] || fail "live smoke test must stay outside tests/suites"

# Without explicit opt-in it skips, never passes, and never launches Claude.
run_smoke no-opt-in verified RALPH_CLAUDE_GATE_SMOKE=
[[ "$SMOKE_STATUS" -eq 2 ]] || fail "expected skip exit 2 without opt-in, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'SKIP'
assert_output 'RALPH_CLAUDE_GATE_SMOKE=1'
assert_not_run no-opt-in

# Missing profile configuration is a prerequisite error.
run_smoke no-profile verified CLAUDE_CONFIG_DIR=
[[ "$SMOKE_STATUS" -eq 2 ]] || fail "expected prerequisite exit 2 without CLAUDE_CONFIG_DIR, got $SMOKE_STATUS"
assert_output 'CLAUDE_CONFIG_DIR'
assert_not_run no-profile

# Missing credentials are a prerequisite error, not a pass.
run_smoke logged-out logged-out
[[ "$SMOKE_STATUS" -eq 2 ]] || fail "expected prerequisite exit 2 when logged out, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'not logged in'
assert_not_run logged-out

# Provider-reported model and effort: the gate passes at VERIFIED.
run_smoke verified verified
[[ "$SMOKE_STATUS" -eq 0 ]] || fail "expected verified smoke to pass: $SMOKE_OUTPUT"
assert_output 'PASS'
assert_output 'VERIFIED 1/1'
if grep -Eq 'SMOKE-(PROMPT|RESPONSE)-TEXT|toolu_smoke1|agent_smoke1' <<< "$SMOKE_OUTPUT"; then
  fail "smoke output leaked provider text or IDs: $SMOKE_OUTPUT"
fi
assert_cleaned verified

# No provider-reported settings: honestly OBSERVED, still a pass.
run_smoke observed observed
[[ "$SMOKE_STATUS" -eq 0 ]] || fail "expected observed smoke to pass: $SMOKE_OUTPUT"
assert_output 'OBSERVED 1/1'
assert_output 'did not report'
assert_cleaned observed

# No real worker: the gate fails the step and the smoke test fails.
run_smoke no-worker no-worker
[[ "$SMOKE_STATUS" -eq 1 ]] || fail "expected smoke failure without a worker, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'FAIL'
assert_cleaned no-worker

# The progress edit is required evidence, not optional.
run_smoke no-edit no-edit
[[ "$SMOKE_STATUS" -eq 1 ]] || fail "expected smoke failure without a progress edit, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'progress edit'
assert_cleaned no-edit

# Any change to user Claude settings fails the smoke test.
rm -f "$TMP/profile/settings.json"
run_smoke tamper tamper
[[ "$SMOKE_STATUS" -eq 1 ]] || fail "expected smoke failure when user settings change, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'user settings'
assert_cleaned tamper

echo "claude_gate_smoke_test: ok"
