#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/delegation-qa.sh"
source "$ROOT/scripts/delegation-manifest.sh"
source "$ROOT/scripts/codex-delegation.sh"
source "$ROOT/scripts/claude-delegation.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
rejects() { if "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }

# Canonical digest vectors. Expected hex values were produced independently by
# `printf '%s' '<canonical JSON>' | shasum -a 256` on hand-written strings from
# the #37 "QA plan and policy" rules, never by this implementation.
two_items='[{"id":"QA-01","text":"First check instruction"},{"id":"QA-02","text":"Second check instruction"}]'
[[ "$(delegation_qa_checklist_digest <<< "$two_items")" == sha256:7653828e34645c569ac0f74508025740903a9068d17db3aa371cf854e4673c29 ]] || fail 'checklist vector'
# Key order inside items and array order do not change the digest.
[[ "$(delegation_qa_checklist_digest <<< '[{"text":"Second check instruction","id":"QA-02"},{"text":"First check instruction","id":"QA-01"}]')" == sha256:7653828e34645c569ac0f74508025740903a9068d17db3aa371cf854e4673c29 ]] || fail 'checklist ordering'
# Compact UTF-8, not ASCII escapes.
[[ "$(delegation_qa_checklist_digest <<< '[{"id":"QA-01","text":"Café ✓ check"}]')" == sha256:1141d01da17a2df54b537c0253d9219032b9f7a8bc86514a87882544e15537b8 ]] || fail 'utf-8 vector'
[[ "$(delegation_qa_assignment_digest <<< '{"checklistItemIds":["QA-02","QA-01"],"taskId":"qa_group_1"}')" == sha256:20c0036e0e890c2de1d1b4ee23aa561cb6f6436ab765f0e0c25d60b8f5c73fb7 ]] || fail 'assignment vector'
[[ "$(delegation_qa_assignment_digest <<< '{"taskId":"qa_group_2","checklistItemIds":["QA-03"]}')" == sha256:098e8207f52e1930ba93995117125feec37564a64babac664e2a3d1c5024bef2 ]] || fail 'assignment vector 2'
rejects delegation_qa_assignment_digest <<< '{"taskId":"qa_group_1","checklistItemIds":["QA-01"],"extra":1}'

# One documented comment format (docs/qa-delegation.md). The prepared comment and
# the same comment after progress edits yield identical instruction items.
before="$(cat <<'MD'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: First check instruction
- [ ] [PENDING] QA-02: Second check instruction
- [ ] [PENDING] QA-03: Status prints one summary
  - Setup: Seed workspace 9001.
  - Action: Run `./ralph.sh status --issue 9001`.
  - Expected: One `Delegation:` line.
  - Isolation: Local files only.
MD
)"
after="$(cat <<'MD'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [x] [PASS] QA-01: First check instruction
  - Result: Output matched.
  - Evidence: `exit 0`
    second evidence line
- [x] [BLOCKED] QA-02: Second check instruction
  - Result: No local browser.
- [x] [FAIL] QA-03: Status prints one summary
  - Setup: Seed workspace 9001.
  - Action: Run `./ralph.sh status --issue 9001`.
  - Expected: One `Delegation:` line.
  - Isolation: Local files only.
  - Result: Two summary lines printed.
  - Evidence: see log

<!-- ralph:qa-summary -->
## Summary

- [x] 1 passed, 1 failed, 1 blocked.
- QA-04: not a checklist item
MD
)"
three_digest=sha256:824b66dc868ec8f188c2d5f4720e3f7f6bdf2830fbfa9c3b226f08f4b067fd4a
[[ "$(delegation_qa_checklist_items <<< "$before" | delegation_qa_checklist_digest)" == "$three_digest" ]] || fail 'before fixture digest'
[[ "$(delegation_qa_checklist_items <<< "$after" | delegation_qa_checklist_digest)" == "$three_digest" ]] || fail 'after fixture digest'
[[ "$(delegation_qa_checklist_items <<< "$before" | jq -c 'map(.id)')" == '["QA-01","QA-02","QA-03"]' ]] || fail 'item ids'
# CRLF bodies normalize to LF.
[[ "$(sed 's/$/\r/' <<< "$after" | delegation_qa_checklist_items | delegation_qa_checklist_digest)" == "$three_digest" ]] || fail 'crlf'
# Instruction and ID edits, additions, and removals change the result.
[[ "$(sed 's/Seed workspace 9001/Seed workspace 9002/' <<< "$after" | delegation_qa_checklist_items | delegation_qa_checklist_digest)" != "$three_digest" ]] || fail 'instruction edit'
[[ "$(sed 's/QA-02: Second/QA-04: Second/' <<< "$after" | delegation_qa_checklist_items | jq -c 'map(.id)')" == '["QA-01","QA-03","QA-04"]' ]] || fail 'id edit'
[[ "$(printf '%s\n- [ ] [PENDING] QA-04: Added\n' "$before" | delegation_qa_checklist_items | jq -c 'map(.id)')" == '["QA-01","QA-02","QA-03","QA-04"]' ]] || fail 'addition'
[[ "$(grep -v 'QA-02' <<< "$before" | delegation_qa_checklist_items | jq -c 'map(.id)')" == '["QA-01","QA-03"]' ]] || fail 'removal'
# Malformed, duplicated, or unmarked comments are rejected (exit 2), never repaired.
for mutation in 's/QA-02:/QA-2:/' 's/QA-02:/QA-01:/' 's/<!-- ralph:qa-checklist -->/<!-- other -->/' 's/  - Setup:/  - Notes:/' 's/^## Local QA Checklist$/stray text/'; do
  set +e; sed "$mutation" <<< "$before" | delegation_qa_checklist_items >/dev/null 2>&1; status=$?; set -e
  [[ "$status" == 2 ]] || fail "parser accepted $mutation (status $status)"
done
set +e; printf '%s\n<!-- ralph:qa-checklist -->\n' "$before" | delegation_qa_checklist_items >/dev/null 2>&1; status=$?; set -e
[[ "$status" == 2 ]] || fail 'duplicated marker accepted'
set +e; printf '<!-- ralph:qa-checklist -->\n## Local QA Checklist\n' | delegation_qa_checklist_items >/dev/null 2>&1; status=$?; set -e
[[ "$status" == 2 ]] || fail 'empty checklist accepted'

# Fake gh serves comment fixtures by ID; a missing fixture is a deleted or
# unreadable comment. It records every call so tests can prove the exact ID.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-qa.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/comments" "$tmp/workspace"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[[ "$1" == api && "$2" =~ ^repos/deepansh96/ralph/issues/comments/([0-9]+)$ ]] || exit 1
cat "$FAKE_GH_COMMENTS/${BASH_REMATCH[1]}.json" 2>/dev/null
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH_LOG="$tmp/gh.log" FAKE_GH_COMMENTS="$tmp/comments"
comment() { jq -n --arg body "$2" --arg at "$3" --argjson id "$1" '{id:$id,node_id:"IC_x",html_url:"https://example.invalid",user:{login:"ralph"},updated_at:$at,body:$body}' > "$tmp/comments/$1.json"; }
comment 123 "$before" 2026-08-25T10:00:00Z

[[ "$(delegation_qa_checklist_fetch deepansh96/ralph 123 | jq -c '[.commentId,.updatedAt,(.items|length)]')" == '["123","2026-08-25T10:00:00Z",3]' ]] || fail 'fetch'
set +e; delegation_qa_checklist_fetch deepansh96/ralph 999 >/dev/null 2>&1; status=$?; set -e
[[ "$status" == 1 ]] || fail "deleted comment status $status"
comment 124 "$(sed 's/QA-02:/QA-01:/' <<< "$before")" 2026-08-25T10:00:00Z
set +e; delegation_qa_checklist_fetch deepansh96/ralph 124 >/dev/null 2>&1; status=$?; set -e
[[ "$status" == 2 ]] || fail "duplicated IDs status $status"

# The parent writes the exact #37 plan before its first spawn: 0600, atomic,
# bound to the State attempt, assignments sorted with canonical digests.
state="$tmp/workspace/state.json"
jq -n '{issue:37,steps:[{id:"runthrough-qa-checklist",status:"in_progress",delegation:{schemaVersion:1,policy:"qa-v1"},delegationAttempt:{id:"attempt-1",startedAt:1787590000}}]}' > "$state"
assignments='[{"taskId":"qa_group_2","checklistItemIds":["QA-03"]},{"taskId":"qa_group_1","checklistItemIds":["QA-02","QA-01"]}]'
expected_plan='{"schemaVersion":1,"stepId":"runthrough-qa-checklist","attemptId":"attempt-1","checklist":{"commentId":"123","updatedAt":"2026-08-25T10:00:00Z","digest":"sha256:824b66dc868ec8f188c2d5f4720e3f7f6bdf2830fbfa9c3b226f08f4b067fd4a","items":[{"id":"QA-01","text":"First check instruction"},{"id":"QA-02","text":"Second check instruction"},{"id":"QA-03","text":"Status prints one summary\n  - Setup: Seed workspace 9001.\n  - Action: Run `./ralph.sh status --issue 9001`.\n  - Expected: One `Delegation:` line.\n  - Isolation: Local files only."}]},"assignments":[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02"],"assignmentDigest":"sha256:20c0036e0e890c2de1d1b4ee23aa561cb6f6436ab765f0e0c25d60b8f5c73fb7"},{"taskId":"qa_group_2","checklistItemIds":["QA-03"],"assignmentDigest":"sha256:098e8207f52e1930ba93995117125feec37564a64babac664e2a3d1c5024bef2"}]}'
[[ "$(delegation_qa_plan_write "$state" runthrough-qa-checklist deepansh96/ralph 123 <<< "$assignments")" == "$expected_plan" ]] || fail 'plan output'
plan_file="$tmp/workspace/delegation/runthrough-qa-checklist.plan.json"
[[ "$(cat "$plan_file")" == "$expected_plan" ]] || fail 'plan file'
node -e 'const fs=require("fs");if((fs.statSync(process.argv[1]).mode&0o777)!==0o600)process.exit(1)' "$plan_file" || fail 'plan mode'
[[ "$(find "$tmp/workspace" -name '*.tmp-*' | wc -l | tr -d ' ')" == 0 ]] || fail 'temporary leftovers'
# Incomplete, double, or foreign coverage is refused before any spawn, and the
# previous plan stays intact.
for bad in '[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02"]}]' \
  '[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02"]},{"taskId":"qa_group_2","checklistItemIds":["QA-02","QA-03"]}]' \
  '[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02","QA-03","QA-09"]}]' \
  '[{"taskId":"qa_group_1","checklistItemIds":["QA-01"]},{"taskId":"qa_group_1","checklistItemIds":["QA-02","QA-03"]}]' \
  '[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02","QA-03"],"prompt":"SECRET"}]'; do
  rejects delegation_qa_plan_write "$state" runthrough-qa-checklist deepansh96/ralph 123 <<< "$bad"
done
[[ "$(cat "$plan_file")" == "$expected_plan" ]] || fail 'plan replaced by rejected input'
rejects delegation_qa_plan_write "$state" runthrough-qa-checklist deepansh96/ralph 999 <<< "$assignments"

# qa-v1 verification. The runner refetches the plan's exact commentId; the
# parent's later progress edits change updatedAt, tags, results, evidence, and
# summary but not instructions, so they pass.
comment 123 "$after" 2026-08-25T11:30:00Z
: > "$FAKE_GH_LOG"
qa="$(delegation_qa_verification "$plan_file" deepansh96/ralph)"
[[ "$(cat "$FAKE_GH_LOG")" == 'api repos/deepansh96/ralph/issues/comments/123' ]] || fail 'refetch must use the exact plan commentId'
[[ "$(jq -c '.checklist | [.commentId,.status,(.items|length)]' <<< "$qa")" == '["123","ok",3]' ]] || fail 'refetch facts'
g1=sha256:20c0036e0e890c2de1d1b4ee23aa561cb6f6436ab765f0e0c25d60b8f5c73fb7
g2=sha256:098e8207f52e1930ba93995117125feec37564a64babac664e2a3d1c5024bef2
qchild() { jq -nc --arg id "$1" --arg task "$2" --arg digest "$3" '{childId:$id,parentId:"parent-1",taskId:$task,run:1,assignmentDigest:$digest,started:true,completed:true,outcome:"completed",startedAt:1,endedAt:2,effective:{model:null,reasoningEffort:null},nested:false}'; }
two="$(jq -sc . <(qchild c-1 qa_group_1 "$g1") <(qchild c-2 qa_group_2 "$g2"))"
qa_request() { jq -nc --argjson children "$1" --argjson qa "$2" '{issue:37,stepId:"runthrough-qa-checklist",attemptId:"attempt-1",provider:"codex",policy:"qa-v1",
  requested:{parent:{model:"gpt-5.6-sol",reasoningEffort:"medium"},worker:{model:"gpt-5.6-luna",reasoningEffort:"max"}},
  providerFailed:false,evidence:{attemptId:"attempt-1",parentId:"parent-1",children:$children,modelHistory:{}},qa:$qa}'; }
# Hand-authored from #37 "Manifest" and "QA plan and policy".
expected_manifest='{"schemaVersion":1,"issue":37,"stepId":"runthrough-qa-checklist","attemptId":"attempt-1","provider":"codex","evidenceSource":"app-server","parentId":"parent-1","policy":"qa-v1","requested":{"parent":{"model":"gpt-5.6-sol","reasoningEffort":"medium"},"worker":{"model":"gpt-5.6-luna","reasoningEffort":"max"}},"expected":{"taskCount":2,"taskIds":["qa_group_1","qa_group_2"]},"observed":{"startedCount":2,"completedCount":2,"selectedCount":2},"children":[{"childId":"c-1","parentId":"parent-1","taskId":"qa_group_1","run":1,"assignmentDigest":"sha256:20c0036e0e890c2de1d1b4ee23aa561cb6f6436ab765f0e0c25d60b8f5c73fb7","started":true,"completed":true,"outcome":"completed","startedAt":1,"endedAt":2,"effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"},{"childId":"c-2","parentId":"parent-1","taskId":"qa_group_2","run":1,"assignmentDigest":"sha256:098e8207f52e1930ba93995117125feec37564a64babac664e2a3d1c5024bef2","started":true,"completed":true,"outcome":"completed","startedAt":1,"endedAt":2,"effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"}],"evidenceLevel":"OBSERVED","mismatchCodes":[]}'
[[ "$(qa_request "$two" "$qa" | delegation_manifest_build)" == "$expected_manifest" ]] || fail 'valid qa manifest'
[[ "$(qa_request "$(jq -c reverse <<< "$two")" "$qa" | delegation_manifest_build)" == "$expected_manifest" ]] || fail 'order independence'
full="$(jq -c 'map(.effective = {model:"gpt-5.6-luna",reasoningEffort:"max"})' <<< "$two")"
[[ "$(qa_request "$full" "$qa" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes]')" == '["VERIFIED",[]]' ]] || fail 'verified qa'

codes() { qa_request "$1" "$2" | delegation_manifest_build | jq -c '.mismatchCodes'; }
summary() { qa_request "$1" "$2" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes,.expected.taskCount,.observed.startedCount,.observed.completedCount,.observed.selectedCount]'; }
with_plan() { jq -c --argjson plan "$1" '.plan = $plan' <<< "$qa"; }
plan="$(cat "$plan_file")"
# Missing or structurally invalid plans.
[[ "$(summary "$two" "$(delegation_qa_verification "$tmp/absent.plan.json" deepansh96/ralph)")" == '["UNVERIFIED",["PLAN_MISSING"],0,2,2,2]' ]] || fail 'missing plan'
printf 'not json' > "$tmp/broken.plan.json"
[[ "$(codes "$two" "$(delegation_qa_verification "$tmp/broken.plan.json" deepansh96/ralph)")" == '["PLAN_INVALID"]' ]] || fail 'unparsable plan'
for mutation in '.extra = 1' '.checklist.items[0].raw = "x"' '.assignments[0].prompt = "x"' '.schemaVersion = 2' \
  '.checklist.items[1].id = "QA-2"' '.checklist.items[1].id = "QA-01"' '.assignments[1].taskId = "qa_group_1"' \
  '.assignments[1].checklistItemIds = ["QA-03","QA-09"]' '.checklist.digest = "sha256:\("0" * 64)"' '.stepId = "multi-axis-pr-review"'; do
  [[ "$(codes "$two" "$(with_plan "$(jq -c "$mutation" <<< "$plan")")")" == '["PLAN_INVALID"]' ]] || fail "plan mutation $mutation"
done
# Assignment coverage and digests, with correctly recomputed digests so only
# the intended rule fires.
redigest() { jq -c '.' <<< "$1" | while read -r p; do
  for i in $(jq -r '.assignments | keys[]' <<< "$p"); do
    d="$(jq -c ".assignments[$i] | {taskId,checklistItemIds}" <<< "$p" | delegation_qa_assignment_digest)"
    p="$(jq -c --arg d "$d" ".assignments[$i].assignmentDigest = \$d" <<< "$p")"
  done; printf '%s\n' "$p"; done; }
missing_plan="$(redigest "$(jq -c '.assignments |= .[0:1]' <<< "$plan")")"
[[ "$(codes "$(jq -c '.[0:1]' <<< "$two")" "$(with_plan "$missing_plan")")" == '["ASSIGNMENT_MISSING"]' ]] || fail 'assignment missing'
double_plan="$(redigest "$(jq -c '.assignments[1].checklistItemIds = ["QA-02","QA-03"]' <<< "$plan")")"
double_digest="$(jq -r '.assignments[1].assignmentDigest' <<< "$double_plan")"
[[ "$(codes "$(jq -c --arg d "$double_digest" '.[1].assignmentDigest = $d' <<< "$two")" "$(with_plan "$double_plan")")" == '["ASSIGNMENT_DUPLICATED"]' ]] || fail 'assignment duplicated'
bad_digest="sha256:$(printf 'f%.0s' {1..64})"
[[ "$(codes "$(jq -c --arg d "$bad_digest" '.[1].assignmentDigest = $d' <<< "$two")" "$(with_plan "$(jq -c --arg d "$bad_digest" '.assignments[1].assignmentDigest = $d' <<< "$plan")")")" == '["ASSIGNMENT_DIGEST_MISMATCH"]' ]] || fail 'bad assignment digest'
[[ "$(codes "$two" "$(with_plan "$(jq -c '.attemptId = "attempt-0"' <<< "$plan")")")" == '["ATTEMPT_MISMATCH"]' ]] || fail 'stale plan attempt'
# Refetched checklist: instruction/ID edits, additions, and removals change it;
# deletion or unreadable fails closed; malformed or duplicated is invalid.
refetched() { comment 123 "$1" 2026-08-25T12:00:00Z; codes "$two" "$(delegation_qa_verification "$plan_file" deepansh96/ralph)"; }
[[ "$(refetched "$(sed 's/Seed workspace 9001/Seed workspace 9002/' <<< "$after")")" == '["CHECKLIST_CHANGED"]' ]] || fail 'instruction edit'
[[ "$(refetched "$(sed 's/QA-02: Second/QA-04: Second/' <<< "$after")")" == '["CHECKLIST_CHANGED"]' ]] || fail 'id edit'
[[ "$(refetched "$(printf '%s\n- [ ] [PENDING] QA-04: Added\n' "$before")")" == '["CHECKLIST_CHANGED"]' ]] || fail 'addition'
[[ "$(refetched "$(grep -v 'QA-02' <<< "$before")")" == '["CHECKLIST_CHANGED"]' ]] || fail 'removal'
[[ "$(refetched "$(sed 's/QA-02:/QA-01:/' <<< "$after")")" == '["CHECKLIST_INVALID"]' ]] || fail 'duplicated ids'
[[ "$(refetched "$(sed 's/<!-- ralph:qa-checklist -->//' <<< "$after")")" == '["CHECKLIST_INVALID"]' ]] || fail 'marker removed'
rm "$tmp/comments/123.json"
[[ "$(codes "$two" "$(delegation_qa_verification "$plan_file" deepansh96/ralph)")" == '["CHECKLIST_UNAVAILABLE"]' ]] || fail 'deleted comment'
printf '{"id":123' > "$tmp/comments/123.json"
[[ "$(codes "$two" "$(delegation_qa_verification "$plan_file" deepansh96/ralph)")" == '["CHECKLIST_UNAVAILABLE"]' ]] || fail 'unreadable comment'
comment 123 "$after" 2026-08-25T12:30:00Z
# Children must prove the immutable assignment digest. Without replacements,
# each assignment needs one successful direct run-1 worker.
[[ "$(summary "$(jq -c '.[0:1]' <<< "$two")" "$qa")" == '["UNVERIFIED",["TASK_MISSING"],2,1,1,1]' ]] || fail 'missing worker'
[[ "$(codes "$(jq -c --arg d "$bad_digest" '.[1].assignmentDigest = $d' <<< "$two")" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","TASK_MISSING"]' ]] || fail 'unknown digest'
[[ "$(codes "$(jq -c '.[1].assignmentDigest = null' <<< "$two")" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","TASK_MISSING"]' ]] || fail 'null digest'
[[ "$(codes "$(jq -c --arg d "$g1" '.[1].assignmentDigest = $d' <<< "$two")" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","TASK_MISSING"]' ]] || fail 'digest of another task'
[[ "$(summary "$(jq -c '. + [.[1] | .childId = "c-2b"]' <<< "$two")" "$qa")" == '["UNVERIFIED",["TASK_DUPLICATED"],2,3,3,3]' ]] || fail 'duplicate run'

# Replacement runs (#37 "QA plan and policy"). The parent may replace a run
# that ended failed or stopped with the next run of the same unchanged
# assignment. The highest run is selected and must complete; lower runs are
# superseded. Counts describe the selected logical assignments.
# Spec: id/digest/run/outcome[/startedAt/endedAt]. By default each run starts
# at run*10 and, once finished, ends at run*10+5: strictly sequential.
qrun() { jq -nc --arg id "$1" --arg digest "$2" --argjson run "$3" --arg outcome "$4" --argjson start "${5:-null}" --argjson end "${6:-null}" '{childId:$id,parentId:"parent-1",taskId:"qa_group_2",run:$run,assignmentDigest:$digest,
  started:($outcome != "unstarted"),completed:($outcome == "completed"),outcome:(if $outcome == "unstarted" then "incomplete" else $outcome end),
  startedAt:(if $start != null then $start elif $outcome == "unstarted" then null else $run * 10 end),
  endedAt:(if $end != null then $end elif ($outcome | IN("completed","failed","stopped")) then $run * 10 + 5 else null end),
  effective:{model:null,reasoningEffort:null},nested:false}'; }
g2_runs() { jq -c '.[0:1]' <<< "$two" | jq -c --argjson runs "$(for spec in "$@"; do qrun ${spec//\// }; done | jq -sc .)" '. + $runs'; }
dispositions() { qa_request "$1" "$qa" | delegation_manifest_build | jq -c '[.children[] | [.childId,.run,.disposition]]'; }
for lower in failed stopped; do
  replaced="$(g2_runs "c-2/$g2/1/$lower" "c-2r/$g2/2/completed")"
  [[ "$(summary "$replaced" "$qa")" == '["OBSERVED",[],2,2,2,2]' ]] || fail "replacement after $lower run"
  [[ "$(dispositions "$replaced")" == '[["c-1",1,"selected"],["c-2",1,"superseded"],["c-2r",2,"selected"]]' ]] || fail "dispositions after $lower run"
done
# An incomplete or unstarted lower run has no evidence that it ended; it may
# still be running beside its replacement, a concurrent duplicate.
for lower in incomplete unstarted; do
  [[ "$(codes "$(g2_runs "c-2/$g2/1/$lower" "c-2r/$g2/2/completed")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail "replacement beside $lower run"
done
[[ "$(codes "$(g2_runs "c-2a/$g2/1/failed" "c-2b/$g2/2/incomplete" "c-2c/$g2/3/completed")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'running middle run replaced'
chain="$(g2_runs "c-2a/$g2/1/failed" "c-2b/$g2/2/stopped" "c-2c/$g2/3/failed" "c-2d/$g2/4/completed")"
[[ "$(summary "$chain" "$qa")" == '["OBSERVED",[],2,2,2,2]' ]] || fail 'sequential replacements'
[[ "$(dispositions "$chain")" == '[["c-1",1,"selected"],["c-2a",1,"superseded"],["c-2b",2,"superseded"],["c-2c",3,"superseded"],["c-2d",4,"selected"]]' ]] || fail 'sequential dispositions'
# VERIFIED needs provider-reported settings on selected workers only; a
# superseded run that never reported a model or effort does not cap the level.
[[ "$(qa_request "$(jq -c 'map(if .childId == "c-1" or .childId == "c-2d" then .effective = {model:"gpt-5.6-luna",reasoningEffort:"max"} else . end)' <<< "$chain")" "$qa" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes]')" == '["VERIFIED",[]]' ]] || fail 'verified replacements'
# A superseded run must provably end before every later run of its chain
# starts (#37, #46: overlapping runs fail). Timing marks are provider-scoped
# (Claude hook-event order, Codex App Server turn seconds); ending exactly when
# the replacement starts is sequential.
[[ "$(summary "$(g2_runs "c-2/$g2/1/failed/10/20" "c-2r/$g2/2/completed/20/30")" "$qa")" == '["OBSERVED",[],2,2,2,2]' ]] || fail 'replacement at run end'
for lower in failed stopped; do
  [[ "$(codes "$(g2_runs "c-2/$g2/1/$lower/10/25" "c-2r/$g2/2/completed/20/30")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail "replacement overlapping $lower run"
done
[[ "$(codes "$(g2_runs "c-2a/$g2/1/failed/10/15" "c-2b/$g2/2/stopped/20/35" "c-2c/$g2/3/completed/30/40")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'overlap later in chain'
[[ "$(codes "$(g2_runs "c-2a/$g2/1/failed/10/35" "c-2b/$g2/2/stopped/20/25" "c-2c/$g2/3/completed/40/50")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'run 1 outlived run 2'
# Missing timing evidence on a replaced run or its replacement fails closed.
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/completed" | jq -c '.[1].endedAt = null')" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'superseded run without end'
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/completed" | jq -c '.[2].startedAt = null')" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'replacement without start'
# Without a replacement, missing timing evidence changes nothing.
[[ "$(summary "$(jq -c 'map(.startedAt = null | .endedAt = null)' <<< "$two")" "$qa")" == '["OBSERVED",[],2,2,2,2]' ]] || fail 'timing needed only for replacements'
# The highest run must itself complete.
[[ "$(summary "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/failed")" "$qa")" == '["UNVERIFIED",["CHILD_FAILED"],2,2,1,2]' ]] || fail 'failed replacement'
[[ "$(summary "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/incomplete")" "$qa")" == '["UNVERIFIED",["CHILD_INCOMPLETE"],2,2,1,2]' ]] || fail 'incomplete replacement'
# A completed run cannot be replaced, even when the next run also completes.
[[ "$(codes "$(g2_runs "c-2/$g2/1/completed" "c-2r/$g2/2/completed")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'completed run replaced'
[[ "$(codes "$(g2_runs "c-2/$g2/1/completed" "c-2r/$g2/2/failed")" "$qa")" == '["CHILD_FAILED","TASK_DUPLICATED"]' ]] || fail 'completed run replaced by failure'
[[ "$(codes "$(g2_runs "c-2a/$g2/1/failed" "c-2b/$g2/2/completed" "c-2c/$g2/3/completed")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'completed middle run replaced'
# Duplicate or overlapping runs are ambiguous and fail closed.
[[ "$(codes "$(g2_runs "c-2a/$g2/1/failed" "c-2b/$g2/1/failed" "c-2r/$g2/2/completed")" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'duplicate lower run'
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2a/$g2/2/completed" "c-2b/$g2/2/failed")" "$qa")" == '["CHILD_FAILED","TASK_DUPLICATED"]' ]] || fail 'overlapping replacement runs'
# Runs start at 1 and increase by exactly one.
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/3/completed")" "$qa")" == '["TASK_UNEXPECTED"]' ]] || fail 'run gap'
[[ "$(codes "$(g2_runs "c-2r/$g2/2/completed")" "$qa")" == '["TASK_UNEXPECTED"]' ]] || fail 'replacement without run 1'
# A replacement must keep the assignment digest and task ID; a changed one binds
# to nothing, so the failed run stays selected.
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$bad_digest/2/completed")" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","CHILD_FAILED"]' ]] || fail 'replacement changed digest'
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g1/2/completed")" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","CHILD_FAILED"]' ]] || fail 'replacement took another assignment'
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/completed" | jq -c '.[2].taskId = "qa_group_3"')" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","CHILD_FAILED"]' ]] || fail 'replacement changed task'
# Missing identity proof on a lower run is never guessed into the chain.
[[ "$(codes "$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/completed" | jq -c '.[1].assignmentDigest = null')" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","CHILD_FAILED","TASK_UNEXPECTED"]' ]] || fail 'unbound lower run'
# Supersession never hides nesting or wrong exposed settings of an earlier run.
replaced="$(g2_runs "c-2/$g2/1/failed" "c-2r/$g2/2/completed")"
[[ "$(codes "$(jq -c --argjson n "$(qchild c-3 qa_group_2 "$g2" | jq -c '.parentId = "c-2" | .nested = true')" '. + [$n]' <<< "$replaced")" "$qa")" == '["NESTED_WORKER"]' ]] || fail 'nested under superseded run'
[[ "$(codes "$(jq -c '.[1].effective.model = "gpt-5.6-sol"' <<< "$replaced")" "$qa")" == '["MODEL_MISMATCH"]' ]] || fail 'superseded wrong model'
[[ "$(codes "$(jq -c '.[1].effective.reasoningEffort = "medium"' <<< "$replaced")" "$qa")" == '["EFFORT_MISMATCH"]' ]] || fail 'superseded wrong effort'
[[ "$(qa_request "$replaced" "$qa" | jq -c '.evidence.modelHistory = {"c-2":["gpt-5.6-sol"]}' | delegation_manifest_build | jq -c '.mismatchCodes')" == '["MODEL_MISMATCH"]' ]] || fail 'superseded model history'
# Replacements live inside one provider invocation: workers from an old parent
# session cannot be superseded, and a fresh session restarts at run 1.
[[ "$(codes "$(jq -c '.[1].parentId = "parent-0"' <<< "$replaced")" "$qa")" == '["CHILD_FAILED","PARENT_MISMATCH","TASK_UNEXPECTED"]' ]] || fail 'old-session run superseded'
[[ "$(dispositions "$(jq -c '.[1].parentId = "parent-0"' <<< "$replaced")")" == '[["c-1",1,"selected"],["c-2",1,"selected"],["c-2r",2,"selected"]]' ]] || fail 'old-session disposition'
[[ "$(codes "$(jq -c '.[1] += {completed:false,outcome:"incomplete"}' <<< "$two")" "$qa")" == '["CHILD_INCOMPLETE"]' ]] || fail 'incomplete worker'
nested="$(qchild c-3 qa_group_1 "$g1" | jq -c '.parentId = "c-1" | .nested = true')"
[[ "$(summary "$(jq -c --argjson n "$nested" '. + [$n]' <<< "$two")" "$qa")" == '["UNVERIFIED",["NESTED_WORKER"],2,2,2,2]' ]] || fail 'nested worker'
[[ "$(codes "$(jq -c '.[0].effective.model = "gpt-5.6-sol"' <<< "$two")" "$qa")" == '["MODEL_MISMATCH"]' ]] || fail 'wrong model'
[[ "$(codes "$(jq -c '.[0].effective.reasoningEffort = "medium"' <<< "$two")" "$qa")" == '["EFFORT_MISMATCH"]' ]] || fail 'wrong effort'
# The Codex task name qa_r<run>_<hex> binds a thread to the plan's assignment.
threads="$(jq -nc --arg h1 "${g1#sha256:}" --arg h2 "${g2#sha256:}" '{parentId:"parent-1",threads:[
  {id:"c-1",parentId:"parent-1",direct:true,depth:1,spawnParent:"parent-1",task:("qa_r1_" + $h1),model:"gpt-5.6-luna",reasoningEffort:"max",turns:[{status:"completed",startedAt:1,completedAt:2,failed:false}]},
  {id:"c-2",parentId:"parent-1",direct:true,depth:1,spawnParent:"parent-1",task:("qa_r1_" + $h2),model:"gpt-5.6-luna",reasoningEffort:"max",turns:[{status:"completed",startedAt:1,completedAt:2,failed:false}]}]}')"
codex_children="$(codex_delegation_normalize parent-1 "$plan_file" <<< "$threads")"
[[ "$(qa_request "$codex_children" "$qa" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes,[.children[].taskId]]')" == '["VERIFIED",[],["qa_group_1","qa_group_2"]]' ]] || fail 'codex task names'
codex_replaced="$(jq -c --arg h2 "${g2#sha256:}" '.threads[1].turns = [{status:"failed",startedAt:1,completedAt:2,failed:true}]
  | .threads += [.threads[1] | .id = "c-2r" | .task = ("qa_r2_" + $h2) | .turns = [{status:"completed",startedAt:3,completedAt:4,failed:false}]]' <<< "$threads" | codex_delegation_normalize parent-1 "$plan_file")"
[[ "$(qa_request "$codex_replaced" "$qa" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes,[.children[] | [.taskId,.run,.disposition]]]')" == '["VERIFIED",[],[["qa_group_1",1,"selected"],["qa_group_2",1,"superseded"],["qa_group_2",2,"selected"]]]' ]] || fail 'codex replacement task names'
# Collector seam: a Codex replacement whose turn started before the failed run's
# turn completed overlapped it; an interrupted run without completedAt has no
# end proof. Both fail closed.
codex_overlap="$(jq -c '.threads[1].turns = [{status:"failed",startedAt:1,completedAt:5,failed:true}]' <<< "$(jq -c --arg h2 "${g2#sha256:}" '.threads += [.threads[1] | .id = "c-2r" | .task = ("qa_r2_" + $h2) | .turns = [{status:"completed",startedAt:3,completedAt:6,failed:false}]]' <<< "$threads")" | codex_delegation_normalize parent-1 "$plan_file")"
[[ "$(codes "$codex_overlap" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'codex overlapping replacement'
codex_unended="$(jq -c '.threads[1].turns = [{status:"interrupted",startedAt:1,completedAt:null,failed:false}]' <<< "$(jq -c --arg h2 "${g2#sha256:}" '.threads += [.threads[1] | .id = "c-2r" | .task = ("qa_r2_" + $h2) | .turns = [{status:"completed",startedAt:3,completedAt:4,failed:false}]]' <<< "$threads")" | codex_delegation_normalize parent-1 "$plan_file")"
[[ "$(codes "$codex_unended" "$qa")" == '["TASK_DUPLICATED"]' ]] || fail 'codex replacement without end proof'
# Collector seam: Claude hook-log order proves (or disproves) the sequence.
cev() { jq -nc --arg tool "$1" --arg child "$2" --arg task "$3" --arg digest "$4" --argjson run "$5" --arg status "$6" '[
  {event:"PreToolUse",tool_use_id:$tool,agent_id:null,subagent_type:"ralph-worker",model:null,taskId:$task,assignmentDigest:$digest,run:$run},
  {event:"SubagentStart",agent_id:$child,agent_type:"ralph-worker"},
  {event:"SubagentStop",agent_id:$child,agent_type:"ralph-worker",status:$status,effort:{level:"max"}},
  {event:"PostToolUse",tool_use_id:$tool,agentId:$child,status:$status,resolvedModel:null,modelsUsed:[]}]'; }
c1="$(cev t-1 c-1 qa_group_1 "$g1" 1 completed)"; c2="$(cev t-2 c-2 qa_group_2 "$g2" 1 failed)"; c2r="$(cev t-2r c-2r qa_group_2 "$g2" 2 completed)"
claude_codes() { jq -c --argjson a "$c1" --argjson b "$c2" --argjson r "$c2r" "$1" <<< null | claude_delegation_normalize parent-1 | { read -r children; codes "$children" "$qa"; }; }
[[ "$(claude_codes '$a + $b + $r')" == '[]' ]] || fail 'claude sequential replacement'
[[ "$(claude_codes '$a + [$b[0],$b[1],$r[0],$r[1],$b[2],$b[3],$r[2],$r[3]]')" == '["TASK_DUPLICATED"]' ]] || fail 'claude overlapping replacement'
foreign="$(jq -c --arg h "$(printf 'a%.0s' {1..64})" '.threads[1].task = ("qa_r1_" + $h)' <<< "$threads" | codex_delegation_normalize parent-1 "$plan_file")"
[[ "$(codes "$foreign" "$qa")" == '["ASSIGNMENT_DIGEST_MISMATCH","TASK_MISSING"]' ]] || fail 'foreign codex task name'
# Provider failure and missing evidence still produce QA manifests.
[[ "$(qa_request "$two" "$qa" | jq -c '.providerFailed = true | .evidence = null' | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes,.expected.taskCount]')" == '["UNVERIFIED",["EVIDENCE_UNAVAILABLE","PROVIDER_FAILED"],2]' ]] || fail 'provider failure'
# The qa field is required for qa-v1 and forbidden for pr-review-v1.
rejects delegation_manifest_build <<< "$(qa_request "$two" "$qa" | jq -c 'del(.qa)')"
rejects delegation_manifest_build <<< "$(qa_request "$two" "$qa" | jq -c '.policy = "pr-review-v1"')"
rejects delegation_manifest_build <<< "$(qa_request "$two" "$qa" | jq -c '.qa.checklist.status = "maybe"')"

echo 'delegation_qa_test.sh passed'
