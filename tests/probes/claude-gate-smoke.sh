#!/usr/bin/env bash
# Opt-in live smoke test of the complete gated Claude QA path (#47): the real
# `ralph.sh` runner and Claude adapter run one qa-v1 step against a disposable
# local git project, a one-item checklist, and a local `gh` stub. Never part of
# ./tests/run.sh. See docs/delegation-gate.md for prerequisites.
# Exit 0 PASS, 1 FAIL, 2 SKIP (not opted in or prerequisites missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ISSUE="${RALPH_CLAUDE_SMOKE_ISSUE:-9947}"
STEP=runthrough-qa-checklist
REPO=ralph-smoke/qa-fixture
PARENT_MODEL="${RALPH_CLAUDE_SMOKE_MODEL:-opus}"
WORKER_MODEL="${RALPH_CLAUDE_SMOKE_WORKER:-claude-sonnet-5}"
WORKER_EFFORT=high

skip() { echo "SKIP (not a pass): $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "${RALPH_CLAUDE_GATE_SMOKE:-}" == 1 && $# == 1 ]] \
  || skip 'opt in with RALPH_CLAUDE_GATE_SMOKE=1 and supply one registered, empty scratch directory.'
scratch="$1"
[[ "$scratch" == /* && -d "$scratch" && -z "$(ls -A "$scratch")" ]] \
  || skip 'the scratch directory must be an existing, empty, absolute path.'
for tool in claude jq node git; do
  command -v "$tool" >/dev/null || skip "prerequisite missing: $tool"
done
[[ -n "${CLAUDE_CONFIG_DIR:-}" && -d "${CLAUDE_CONFIG_DIR:-}" ]] \
  || skip 'set CLAUDE_CONFIG_DIR to an authenticated Claude profile directory, such as ~/.claude-t4d-api.'
claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null \
  || skip "the CLAUDE_CONFIG_DIR profile is not logged in."
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || skip 'RALPH_CLAUDE_SMOKE_ISSUE must be a positive integer.'
workspace="$ROOT/workspaces/$ISSUE"
[[ ! -e "$workspace" ]] || skip "workspace $ISSUE already exists; remove it or set RALPH_CLAUDE_SMOKE_ISSUE."

project="$scratch/project"
store="$scratch/gh"
created_workspace=false
cleanup() {
  [[ "$created_workspace" != true ]] || rm -rf "$workspace"
  rm -rf "$project" "$scratch/origin.git" "$scratch/bin" "$store" "$scratch/ralph.out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# User and profile settings must be byte-identical after the run.
settings_fingerprint() {
  local path
  for path in "$CLAUDE_CONFIG_DIR/settings.json" "$CLAUDE_CONFIG_DIR/settings.local.json" "$CLAUDE_CONFIG_DIR/agents" \
    "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/agents" "$ROOT/.claude"; do
    if [[ -e "$path" ]]; then
      printf '%s %s\n' "$path" "$(find "$path" -type f -exec shasum {} + | sort | shasum)"
    else
      printf '%s absent\n' "$path"
    fi
  done
}
settings_before="$(settings_fingerprint)"

# Disposable project: a local origin, a base commit, and a one-line PR change.
# The unique token must never reach the manifest or status output.
token="RALPH_SMOKE_$(node -e 'console.log(require("node:crypto").randomBytes(8).toString("hex"))')"
branch="ralph-$ISSUE-claude-gate-smoke"
git init -q --bare "$scratch/origin.git"
git init -q "$project"
git -C "$project" symbolic-ref HEAD refs/heads/main
git -C "$project" config user.name 'Ralph Smoke'
git -C "$project" config user.email 'ralph-smoke@localhost'
printf '# Smoke fixture\n' > "$project/README.md"
git -C "$project" add README.md
git -C "$project" commit -q -m 'Base fixture'
git -C "$project" remote add origin "$scratch/origin.git"
git -C "$project" push -q origin main
git -C "$project" checkout -q -b "$branch"
printf 'smoke value: %s\n' "$token" >> "$project/README.md"
git -C "$project" commit -q -am 'Add the smoke value'
git -C "$project" push -q -u origin "$branch"
# The QA prompt sources ./ralph from the project root, as in an install.
ln -s "$ROOT" "$project/ralph"
printf '/ralph\n' >> "$project/.git/info/exclude"

mkdir -p "$store" "$scratch/bin"
jq -n --arg repo "$REPO" --argjson issue "$ISSUE" --arg project "$project" --arg branch "$branch" \
  --arg head "$(git -C "$project" rev-parse HEAD)" --arg baseSha "$(git -C "$project" rev-parse main)" '
  {repo:$repo, issue:$issue, project:$project, base:"main", baseSha:$baseSha, branch:$branch, head:$head,
   title:"Add the smoke value to the README",
   body:"Adds one README line for the Ralph Claude gate smoke test. Edit the QA checklist comment with `gh api -X PATCH repos/\($repo)/issues/comments/<id> -F body=@<file>`.",
   issueBody:"Add a smoke value line to the README. This is a disposable local fixture; every GitHub call is served by a local stub."}' \
  > "$store/meta.json"
jq -n --rawfile body /dev/stdin --arg repo "$REPO" \
  '[{id:424242, html_url:"https://github.com/\($repo)/pull/1#issuecomment-424242", user:{login:"ralph"},
     created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z", body:$body}]' > "$store/comments.json" <<'MD'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: The README states the smoke value
  - Setup: None; use the checked-out project root.
  - Action: Run `grep '^smoke value: ' README.md` from the project root.
  - Expected: It prints one line starting with `smoke value: RALPH_SMOKE_` and exits 0.
  - Isolation: Read-only; starts no process and writes no file.
MD
printf '#!/usr/bin/env bash\nexec node %q %q "$@"\n' "$ROOT/tests/probes/claude-gate-smoke-gh.cjs" "$store" > "$scratch/bin/gh"
chmod +x "$scratch/bin/gh"

# One pending gated qa-v1 step after a completed preflight.
created_workspace=true
mkdir -p "$workspace/logs"
printf '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}\n' > "$workspace/local-resources.json"
jq -n --argjson issue "$ISSUE" --arg repo "$REPO" --arg root "$project" --arg branch "$branch" --arg step "$STEP" \
  --arg model "$PARENT_MODEL" --arg worker "$WORKER_MODEL" --arg effort "$WORKER_EFFORT" '
  {issue:$issue, repo:$repo, projectRoot:$root, baseBranch:"main", branch:$branch, steps:[
    {id:"preflight", phase:"fixed", type:"preflight", status:"completed", agent:"codex", reviewers:[], hitl:false, metrics:{}, notes:""},
    {id:$step, phase:"dynamic", type:$step, status:"pending", agent:"claude", reviewers:[], hitl:false, metrics:null, notes:"",
     model:$model, reasoningEffort:"medium", subagentModel:$worker, subagentReasoningEffort:$effort,
     delegation:{schemaVersion:1, policy:"qa-v1"}}]}' > "$workspace/state.json"

printf 'Claude gate smoke test: %s, parent %s, worker %s/%s\n' "$(claude --version)" "$PARENT_MODEL" "$WORKER_MODEL" "$WORKER_EFFORT"
status=0
(cd "$project" && PATH="$scratch/bin:$PATH" "$ROOT/ralph.sh" --issue "$ISSUE") > "$scratch/ralph.out" 2>&1 || status=$?
state="$workspace/state.json"
manifest="$workspace/delegation/$STEP.manifest.json"
plan="$workspace/delegation/$STEP.plan.json"
step_status="$(jq -r --arg id "$STEP" 'first(.steps[] | select(.id == $id)) | .status' "$state")"
if [[ "$status" -ne 0 || "$step_status" != completed ]]; then
  # Only the gate's fixed, safe summary line is printed; the log stays local.
  grep '^Delegation gate:' "$scratch/ralph.out" >&2 || true
  fail "ralph.sh exited $status and the gated step is '$step_status'."
fi

# Current-attempt manifest and plan, private and passing.
attempt="$(jq -r --arg id "$STEP" 'first(.steps[] | select(.id == $id)) | .delegationAttempt.id // empty' "$state")"
[[ -n "$attempt" ]] || fail 'State has no delegationAttempt for the step.'
[[ -f "$manifest" && -f "$plan" ]] || fail 'expected a manifest and a QA plan.'
node -e 'process.exit((require("fs").statSync(process.argv[1]).mode & 0o777) === 0o600 ? 0 : 1)' "$manifest" \
  || fail 'manifest is not mode 0600.'
jq -e --arg attempt "$attempt" --argjson issue "$ISSUE" --arg step "$STEP" --arg model "$PARENT_MODEL" \
  --arg worker "$WORKER_MODEL" --arg effort "$WORKER_EFFORT" --slurpfile plan "$plan" '
  ($plan[0].assignments) as $a
  | (keys == ["attemptId","children","evidenceLevel","evidenceSource","expected","issue","mismatchCodes","observed",
       "parentId","policy","provider","requested","schemaVersion","stepId"])
  and .schemaVersion == 1 and .issue == $issue and .stepId == $step and .attemptId == $attempt
  and $plan[0].attemptId == $attempt
  and .provider == "claude" and .evidenceSource == "hooks" and .policy == "qa-v1"
  and .requested == {parent:{model:$model,reasoningEffort:"medium"},worker:{model:$worker,reasoningEffort:$effort}}
  and ($a | length) == 1 and $a[0].checklistItemIds == ["QA-01"]
  and .expected == {taskCount:1,taskIds:[$a[0].taskId]}
  and .observed == {startedCount:1,completedCount:1,selectedCount:1}
  and .mismatchCodes == [] and (.evidenceLevel == "OBSERVED" or .evidenceLevel == "VERIFIED")
  and (.children | length == 1) and (.parentId | type == "string")
  and (.children[0] | (keys == ["assignmentDigest","childId","completed","disposition","effective","endedAt","nested",
       "outcome","parentId","run","started","startedAt","taskId"]) and .disposition == "selected")
' "$manifest" >/dev/null || fail 'manifest is not a passing current-attempt qa-v1 manifest with one assignment.'

# Direct lifecycle correlation: one direct worker bound to the planned digest.
jq -e --slurpfile plan "$plan" '
  .parentId as $parent | $plan[0].assignments[0] as $a | .children[0]
  | .parentId == $parent and (.nested | not) and .started and .completed and .outcome == "completed"
    and (.startedAt | type == "number") and (.endedAt | type == "number") and .startedAt <= .endedAt
    and .run == 1 and .taskId == $a.taskId and .assignmentDigest == $a.assignmentDigest
' "$manifest" >/dev/null || fail 'the worker is not a completed direct child bound to the planned assignment.'

# Provider-reported settings when available; otherwise honestly OBSERVED.
level="$(jq -r .evidenceLevel "$manifest")"
effective="$(jq -c '.children[0].effective' "$manifest")"
if [[ "$level" == VERIFIED ]]; then
  jq -e --arg effort "$WORKER_EFFORT" '.reasoningEffort == $effort and (.model | type == "string")' <<< "$effective" >/dev/null \
    || fail "VERIFIED without provider-reported worker settings: $effective"
  [[ "$WORKER_MODEL" != claude-* ]] || [[ "$(jq -r .model <<< "$effective")" == "$WORKER_MODEL" ]] \
    || fail "VERIFIED worker model differs from the explicit request."
  settings_note="provider reported model $(jq -r .model <<< "$effective") and effort $(jq -r .reasoningEffort <<< "$effective")"
else
  jq -e '.model == null or .reasoningEffort == null' <<< "$effective" >/dev/null \
    || fail "OBSERVED although the provider reported both worker settings: $effective"
  settings_note="provider did not report $(jq -r '[if .model == null then "model" else empty end, if .reasoningEffort == null then "effort" else empty end] | join(" or ")' <<< "$effective"), so the result is honestly OBSERVED"
fi

# The parent's normal progress edit changed the comment timestamp and the
# item's progress, yet the gate still passed on unchanged instructions.
jq -e --slurpfile plan "$plan" '.[0] | .updated_at != $plan[0].checklist.updatedAt
  and (.body | test("(?m)^- \\[x\\] \\[(PASS|FAIL|BLOCKED)\\] QA-01: "))' "$store/comments.json" >/dev/null \
  || fail 'the parent made no progress edit to the checklist comment.'

# Leaks: the manifest and status output carry no prompt, response, path, or ID.
status_output="$("$ROOT/ralph.sh" status --issue "$ISSUE" 2>&1)" || fail 'ralph.sh status failed.'
[[ "$status_output" == *"Delegation: $level 1/1"* ]] || fail "status has no 'Delegation: $level 1/1' summary."
for needle in "$token" "$scratch" "$HOME" "$ROOT" 'RALPH-TASK' 'RALPH-ASSIGNMENT' 'Run Through QA Checklist' 'smoke value'; do
  if grep -qF -- "$needle" "$manifest"; then fail 'manifest leaked prompt, response, or path data.'; fi
done
for needle in "$token" 'RALPH-TASK' 'smoke value' $(jq -r '.attemptId, .parentId, .children[].childId' "$manifest"); do
  [[ "$status_output" != *"$needle"* ]] || fail 'status leaked prompt text or opaque IDs.'
done

# Cleanup: no hook inputs remain, and no user or project settings were written.
leftover="$(find "$workspace" "$scratch" -mindepth 1 \( -name 'ralph-delegation-*' -o -name 'ralph-37-claude-*' -o -name events.jsonl \) -print -quit 2>/dev/null)"
[[ -z "$leftover" ]] || fail 'temporary hook inputs were not removed.'
[[ ! -e "$project/.claude/settings.json" && ! -e "$project/.claude/settings.local.json" && ! -e "$project/.claude/agents" ]] \
  || fail 'the run wrote project Claude settings or agent definitions.'
[[ "$(settings_fingerprint)" == "$settings_before" ]] || fail 'user settings or agent definitions changed during the run.'

echo "PASS: gated Claude QA step completed at $level 1/1 with one direct worker bound to the planned assignment; $settings_note. The progress edit did not fail the gate; manifest and status leak nothing; hook inputs were removed and user settings were untouched."
