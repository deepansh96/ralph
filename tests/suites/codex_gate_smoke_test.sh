#!/usr/bin/env bash
set -euo pipefail

# Harness checks for the opt-in live Codex gate smoke test
# (tests/probes/codex-gate-smoke.sh). A fake `codex` plays the QA parent through
# the real runner and serves a paginating fake App Server; the smoke test's
# JSON-RPC recorder and local `gh` stub are real. The live test itself never
# runs here: it needs real Codex credentials.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$ROOT/tests/probes/codex-gate-smoke.sh"
ISSUE=9950
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-codex-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP" "${ROOT:?}/workspaces/$ISSUE"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/fake-bin"
printf '{}\n' > "$TMP/threads.json"
cat > "$TMP/fake-bin/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
mode="${FAKE_SMOKE_MODE:-verified}"
case "${1:-}" in
  login)
    if [[ "$mode" == logged-out ]]; then echo 'Not logged in'; exit 1; fi
    echo 'Logged in using ChatGPT'; exit 0 ;;
  --version) echo 'codex-cli 0.155.1'; exit 0 ;;
  app-server)
    [[ "$mode" != no-server ]] || exit 1
    exec node "$FAKE_APP_SERVER" "$FAKE_THREADS" ;;
esac
[[ " $* " == *" exec "* ]] || exit 99
printf 'run\n' >> "$FAKE_CALLS"
prompt="$(cat)"
workspace="$(awk '/^Workspace:/ { print $2; exit }' <<< "$prompt")"
repo="$(awk '/^Repo:/ { print $2; exit }' <<< "$prompt")"
step="$(awk '/^Step:/ { print $2; exit }' <<< "$prompt")"
parent="parent_smoke"
# The parent finds the marked comment, plans, and spawns from the project root.
id="$(gh api "repos/$repo/issues/1/comments" --jq '.[] | select(.body | contains("<!-- ralph:qa-checklist -->")) | .id')"
source ./ralph/scripts/delegation-qa.sh
plan="$(delegation_qa_plan_write "$workspace/state.json" "$step" "$repo" "$id" <<< '[{"taskId":"qa_group_1","checklistItemIds":["QA-01"]}]')"
hex="$(jq -r '.assignments[0].assignmentDigest | ltrimstr("sha256:")' <<< "$plan")"
case "$mode" in
  no-worker) workers='[]' ;;
  observed) workers="$(jq -nc --arg name "qa_r1_$hex" '[{name:$name}]')" ;;
  *) workers="$(jq -nc --arg name "qa_r1_$hex" '[{name:$name,model:"gpt-5.6-luna",effort:"max"}]')" ;;
esac
jq --arg parent "$parent" --argjson workers "$workers" '.[$parent] = $workers' "$FAKE_THREADS" > "$FAKE_THREADS.tmp"
mv "$FAKE_THREADS.tmp" "$FAKE_THREADS"
if [[ "$mode" != no-edit ]]; then
  body="$(gh api "repos/$repo/issues/comments/$id" --jq .body | sed 's/^- \[ \] \[PENDING\] QA-01/- [x] [PASS] QA-01/')"
  gh api -X PATCH "repos/$repo/issues/comments/$id" -f body="$body" >/dev/null
fi
printf '{"type":"thread.started","thread_id":"%s"}\n' "$parent"
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"SMOKE-RESPONSE-TEXT"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
FAKE
chmod +x "$TMP/fake-bin/codex"

# Paginating App Server: honours `limit` and returns a cursor after every full
# page, so a one-item page size forces the collector to follow a cursor.
cat > "$TMP/app-server.cjs" <<'FAKE'
const fs = require('node:fs');
const readline = require('node:readline');
const parents = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const threads = {};
for (const [parent, workers] of Object.entries(parents)) {
  for (const w of workers) {
    const id = `child_${w.name.slice(0, 12)}`;
    threads[id] = { parent, thread: { id, parentThreadId: parent, preview: 'SMOKE-PROMPT-TEXT',
      source: { subAgent: { thread_spawn: { parent_thread_id: parent, depth: 1, agent_path: `/root/${w.name}` } } },
      model: w.model ?? null, reasoningEffort: w.effort ?? null,
      turns: [{ id: 't', status: 'completed', startedAt: 1, completedAt: 2, error: null }] } };
  }
}
const reply = (id, body) => process.stdout.write(JSON.stringify({ id, ...body }) + '\n');
readline.createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  if (m.method === 'initialize') return reply(m.id, { result: {} });
  if (m.method === 'thread/list') {
    const parent = m.params.parentThreadId ?? m.params.ancestorThreadId;
    const all = Object.values(threads).filter(t => t.parent === parent).map(t => ({ ...t.thread, turns: [] }));
    const start = Number(m.params.cursor || 0);
    const data = all.slice(start, start + m.params.limit);
    const nextCursor = data.length === m.params.limit ? String(start + data.length) : null;
    return reply(m.id, { result: { data, nextCursor } });
  }
  if (m.method === 'thread/read') {
    const t = threads[m.params.threadId];
    return t ? reply(m.id, { result: { thread: t.thread } }) : reply(m.id, { error: { code: -32602, message: 'missing' } });
  }
  reply(m.id, { error: { code: -32601, message: 'unsupported' } });
});
FAKE

# run_smoke NAME MODE [ENV...]: fresh empty scratch directory per run, named
# like a registered ledger path.
run_smoke() {
  local name="$1" mode="$2"
  shift 2
  mkdir -p "$TMP/$name/ralph-37-codex-gate-smoke"
  printf '{}\n' > "$TMP/threads.json"
  set +e
  SMOKE_OUTPUT="$(env PATH="$TMP/fake-bin:$PATH" FAKE_SMOKE_MODE="$mode" FAKE_CALLS="$TMP/$name.calls" \
    FAKE_APP_SERVER="$TMP/app-server.cjs" FAKE_THREADS="$TMP/threads.json" \
    RALPH_CODEX_GATE_SMOKE=1 RALPH_CODEX_SMOKE_ISSUE="$ISSUE" \
    RALPH_RETRY_DELAYS="0 0 0" "$@" "$SMOKE" "$TMP/$name/ralph-37-codex-gate-smoke" 2>&1)"
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
  [[ -z "$(ls -A "$TMP/$1/ralph-37-codex-gate-smoke")" ]] || fail "expected scratch contents removed after $1"
}

# The default suite never runs the live test.
if grep -q 'probes' "$ROOT/tests/run.sh"; then fail "tests/run.sh must not reference opt-in probes"; fi
[[ ! -e "$ROOT/tests/suites/codex-gate-smoke.sh" ]] || fail "live smoke test must stay outside tests/suites"

# Without explicit opt-in it skips, never passes, and never launches Codex.
run_smoke no-opt-in verified RALPH_CODEX_GATE_SMOKE=
[[ "$SMOKE_STATUS" -eq 2 ]] || fail "expected skip exit 2 without opt-in, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'SKIP'
assert_output 'RALPH_CODEX_GATE_SMOKE=1'
assert_not_run no-opt-in

# Missing credentials are a prerequisite error, not a pass.
run_smoke logged-out logged-out
[[ "$SMOKE_STATUS" -eq 2 ]] || fail "expected prerequisite exit 2 when logged out, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'not logged in'
assert_not_run logged-out

# Thread-level worker settings: the gate passes at VERIFIED, and the gate's
# own collection followed a one-item page cursor on both listings.
run_smoke verified verified
[[ "$SMOKE_STATUS" -eq 0 ]] || fail "expected verified smoke to pass: $SMOKE_OUTPUT"
assert_output 'PASS'
assert_output 'VERIFIED 1/1'
assert_output 'followed 2 page cursors'
if grep -Eq 'SMOKE-(PROMPT|RESPONSE)-TEXT|parent_smoke|child_qa_r1' <<< "$SMOKE_OUTPUT"; then
  fail "smoke output leaked provider text or IDs: $SMOKE_OUTPUT"
fi
assert_cleaned verified

# No thread-level settings: honestly OBSERVED, still a pass.
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

# Unavailable App Server evidence fails; there is no rollout-file fallback.
run_smoke no-server no-server
[[ "$SMOKE_STATUS" -eq 1 ]] || fail "expected smoke failure without App Server evidence, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'FAIL'
assert_cleaned no-server

# The progress edit is required evidence, not optional.
run_smoke no-edit no-edit
[[ "$SMOKE_STATUS" -eq 1 ]] || fail "expected smoke failure without a progress edit, got $SMOKE_STATUS: $SMOKE_OUTPUT"
assert_output 'progress edit'
assert_cleaned no-edit

echo "codex_gate_smoke_test: ok"
