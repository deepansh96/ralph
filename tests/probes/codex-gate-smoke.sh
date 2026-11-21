#!/usr/bin/env bash
# Opt-in live smoke test of the complete gated Codex QA path (#48): the real
# `ralph.sh` runner and normal `codex exec` adapter run one qa-v1 step against a
# disposable local git project, a one-item checklist, and a local `gh` stub.
# The gate's App Server reads pass through a recorder that forces one-item
# pages. Never part of ./tests/run.sh. See docs/delegation-gate.md.
# Exit 0 PASS, 1 FAIL, 2 SKIP (not opted in or prerequisites missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/codex-delegation.sh"
ISSUE="${RALPH_CODEX_SMOKE_ISSUE:-9949}"
STEP=runthrough-qa-checklist
REPO=ralph-smoke/qa-fixture
PARENT_MODEL="${RALPH_CODEX_SMOKE_MODEL:-gpt-5.6-sol}"
WORKER_MODEL="${RALPH_CODEX_SMOKE_WORKER:-gpt-5.6-luna}"
WORKER_EFFORT="${RALPH_CODEX_SMOKE_WORKER_EFFORT:-max}"
COLLECTOR="$ROOT/scripts/codex-delegation-collect.cjs"

skip() { echo "SKIP (not a pass): $*" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "${RALPH_CODEX_GATE_SMOKE:-}" == 1 && $# == 1 ]] \
  || skip 'opt in with RALPH_CODEX_GATE_SMOKE=1 and supply one registered, empty scratch directory.'
scratch="$1"
[[ "$scratch" == /* && -d "$scratch" && -z "$(ls -A "$scratch")" ]] \
  || skip 'the scratch directory must be an existing, empty, absolute path.'
for tool in codex jq node git; do
  command -v "$tool" >/dev/null || skip "prerequisite missing: $tool"
done
node --permission -e 0 2>/dev/null || skip 'Node.js must support --permission (22.13+).'
codex login status >/dev/null 2>&1 || skip 'Codex is not logged in (codex login status).'
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || skip 'RALPH_CODEX_SMOKE_ISSUE must be a positive integer.'
workspace="$ROOT/workspaces/$ISSUE"
[[ ! -e "$workspace" ]] || skip "workspace $ISSUE already exists; remove it or set RALPH_CODEX_SMOKE_ISSUE."

project="$scratch/project"
store="$scratch/gh"
created_workspace=false
cleanup() {
  [[ "$created_workspace" != true ]] || rm -rf "$workspace"
  rm -rf "$project" "$scratch/origin.git" "$scratch/bin" "$store" "$scratch/ralph.out" "$scratch/rpc-gate.jsonl" "$scratch/rpc-reread.jsonl"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Disposable project: a local origin, a base commit, and a one-line PR change.
# The unique token must never reach the manifest or status output.
token="RALPH_SMOKE_$(node -e 'console.log(require("node:crypto").randomBytes(8).toString("hex"))')"
branch="ralph-$ISSUE-codex-gate-smoke"
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
printf 'ralph\n' >> "$project/.git/info/exclude"

mkdir -p "$store" "$scratch/bin"
jq -n --arg repo "$REPO" --argjson issue "$ISSUE" --arg project "$project" --arg branch "$branch" \
  --arg head "$(git -C "$project" rev-parse HEAD)" --arg baseSha "$(git -C "$project" rev-parse main)" '
  {repo:$repo, issue:$issue, project:$project, base:"main", baseSha:$baseSha, branch:$branch, head:$head,
   title:"Add the smoke value to the README",
   body:"Adds one README line for the Ralph Codex gate smoke test. Edit the QA checklist comment with `gh api -X PATCH repos/\($repo)/issues/comments/<id> -F body=@<file>`.",
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
# CODEX_BIN for the collector: the real App Server behind a one-item-page recorder.
# Node passes --permission to child processes through NODE_OPTIONS; the
# re-read wrapper drops it so only Ralph's collector is file-read-denied, never
# the provider-owned App Server.
rpc_bin() {
  printf '#!/usr/bin/env bash\n%sexec node %q %q 1 "$@"\n' "$3" "$ROOT/tests/probes/codex-gate-smoke-rpc.cjs" "$1" > "$2"
  chmod +x "$2"
}
rpc_bin "$scratch/rpc-gate.jsonl" "$scratch/bin/ralph-codex-rpc-gate" ''
rpc_bin "$scratch/rpc-reread.jsonl" "$scratch/bin/ralph-codex-rpc-reread" $'unset NODE_OPTIONS\n'
chmod +x "$scratch/bin/gh"

# One pending gated qa-v1 step after a completed preflight.
created_workspace=true
mkdir -p "$workspace/logs"
printf '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}\n' > "$workspace/local-resources.json"
jq -n --argjson issue "$ISSUE" --arg repo "$REPO" --arg root "$project" --arg branch "$branch" --arg step "$STEP" \
  --arg model "$PARENT_MODEL" --arg worker "$WORKER_MODEL" --arg effort "$WORKER_EFFORT" '
  {issue:$issue, repo:$repo, projectRoot:$root, baseBranch:"main", branch:$branch, steps:[
    {id:"preflight", phase:"fixed", type:"preflight", status:"completed", agent:"codex", reviewers:[], hitl:false, metrics:{}, notes:""},
    {id:$step, phase:"dynamic", type:$step, status:"pending", agent:"codex", reviewers:[], hitl:false, metrics:null, notes:"",
     model:$model, reasoningEffort:"medium", subagentModel:$worker, subagentReasoningEffort:$effort,
     delegation:{schemaVersion:1, policy:"qa-v1"}}]}' > "$workspace/state.json"

printf 'Codex gate smoke test: %s, parent %s, worker %s/%s\n' "$(codex --version)" "$PARENT_MODEL" "$WORKER_MODEL" "$WORKER_EFFORT"
status=0
(cd "$project" && PATH="$scratch/bin:$PATH" CODEX_BIN="$scratch/bin/ralph-codex-rpc-gate" "$ROOT/ralph.sh" --issue "$ISSUE") \
  > "$scratch/ralph.out" 2>&1 || status=$?
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
  and .provider == "codex" and .evidenceSource == "app-server" and .policy == "qa-v1"
  and .requested == {parent:{model:$model,reasoningEffort:"medium"},worker:{model:$worker,reasoningEffort:$effort}}
  and ($a | length) == 1 and $a[0].checklistItemIds == ["QA-01"]
  and .expected == {taskCount:1,taskIds:[$a[0].taskId]}
  and .observed == {startedCount:1,completedCount:1,selectedCount:1}
  and .mismatchCodes == [] and (.evidenceLevel == "OBSERVED" or .evidenceLevel == "VERIFIED")
  and (.children | length == 1) and (.parentId | type == "string")
  and (.children[0] | (keys == ["assignmentDigest","childId","completed","disposition","effective","endedAt","nested",
       "outcome","parentId","run","started","startedAt","taskId"]) and .disposition == "selected")
' "$manifest" >/dev/null || fail 'manifest is not a passing current-attempt qa-v1 manifest with one assignment.'

# The manifest parent is this attempt's exec parent, and its one direct worker
# is bound to the planned digest.
parent="$(codex_delegation_parent_id "$workspace/logs/$STEP.log")" || fail 'the step log has no single exec parent.'
jq -e --arg parent "$parent" --slurpfile plan "$plan" '
  .parentId == $parent and ($plan[0].assignments[0] as $a | .children[0]
  | .parentId == $parent and (.nested | not) and .started and .completed and .outcome == "completed"
    and (.startedAt | type == "number") and (.endedAt | type == "number") and .startedAt <= .endedAt
    and .run == 1 and .taskId == $a.taskId and .assignmentDigest == $a.assignmentDigest)
' "$manifest" >/dev/null || fail 'the worker is not a completed direct child of the exec parent bound to the planned assignment.'
child="$(jq -r '.children[0].childId' "$manifest")"

# The gate read the child from a fresh App Server using the exact JSON-RPC
# contract: only initialize, thread/list, and thread/read; both listings follow
# every one-item-page cursor to a null cursor; the child is read with turns.
cursors="$(jq -rs --arg parent "$parent" --arg child "$child" '
  def chain($rel): [.[] | select(.method == "thread/list" and .dir == "request" and .params[$rel] == $parent)] as $req
    | [.[] | select(.method == "thread/list" and .dir == "response" and (.id as $id | $req | any(.id == $id)))] as $res
    | if ($req | length) > 0 and ($req | length) == ($res | length)
        and ($req[0].params | has("cursor") | not) and all($req[]; .params.limit == 1 and (.params.sourceKinds | length) == 5)
        and all(range(1; $req | length); $req[.].params.cursor == $res[. - 1].nextCursor and $res[. - 1].nextCursor != null)
        and ($res | last | .nextCursor == null) and all($res[]; .error | not)
      then {cursors: (($req | length) - 1), ids: [$res[].ids[]]} else error("broken pagination") end;
  (map(select(.params.parentThreadId == $parent)) | last | .session) as $s
  | map(select(.session == $s)) as $rpc
  | ($rpc | map(select(.dir == "request")) | map(.method) | unique) as $methods
  | ($rpc | chain("parentThreadId")) as $direct | ($rpc | chain("ancestorThreadId")) as $all
  | if $methods == ["initialize","initialized","thread/list","thread/read"]
      and $direct.ids == [$child] and ($all.ids | index($child)) != null
      and ($rpc | any(.dir == "request" and .method == "thread/read" and .params == {threadId:$child,includeTurns:true}))
      and ($rpc | any(.dir == "response" and .method == "thread/read" and .threadId == $child and (.error | not)))
    then $direct.cursors + $all.cursors else error("contract") end
' "$scratch/rpc-gate.jsonl" 2>/dev/null)" || fail "the gate's App Server reads did not follow the #37 JSON-RPC pagination and read contract."

# An independent collection from a fresh App Server process under Node's
# permission model: the collector may read no file at all, so the evidence
# cannot come from rollout files. Unavailable evidence fails.
threads="$(CODEX_BIN="$scratch/bin/ralph-codex-rpc-reread" \
  node --permission --allow-child-process --allow-fs-read="$COLLECTOR" "$COLLECTOR" "$parent" 2>/dev/null)" \
  || fail 'a fresh App Server process could not supply the evidence; there is no rollout-file fallback.'
reread="$(codex_delegation_normalize "$parent" "$plan" <<< "$threads")" || fail 'the fresh App Server evidence is unbound or ambiguous.'
jq -e --argjson reread "$reread" '[.children[] | del(.disposition)] == $reread' "$manifest" >/dev/null \
  || fail 'the fresh App Server evidence differs from the manifest.'

# Thread-level settings when available; otherwise honestly OBSERVED.
level="$(jq -r .evidenceLevel "$manifest")"
effective="$(jq -c '.children[0].effective' "$manifest")"
if [[ "$level" == VERIFIED ]]; then
  jq -e --arg model "$WORKER_MODEL" --arg effort "$WORKER_EFFORT" '.model == $model and .reasoningEffort == $effort' <<< "$effective" >/dev/null \
    || fail "VERIFIED without matching provider-reported worker settings: $effective"
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
for needle in "$token" 'RALPH-TASK' 'smoke value' "$attempt" "$parent" "$child"; do
  [[ "$status_output" != *"$needle"* ]] || fail 'status leaked prompt text or opaque IDs.'
done
leftover="$(find "$workspace" -mindepth 1 -name 'ralph-delegation-*' -print -quit 2>/dev/null)"
[[ -z "$leftover" ]] || fail 'temporary delegation inputs were not removed.'

echo "PASS: gated Codex QA step completed at $level 1/1 with one direct worker of the exec parent bound to the planned assignment; $settings_note. The gate read it from a fresh App Server with one-item pages and followed $cursors page cursors; a file-read-denied fresh collector reproduced the evidence. The progress edit did not fail the gate; manifest and status leak nothing."
