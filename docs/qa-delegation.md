# QA checklist format, plan, replacements, and `qa-v1` verification

`scripts/delegation-qa.sh` parses the marked QA checklist comment, computes the
canonical digests, writes the immutable QA assignment plan, and refetches the
checklist for verification. `scripts/delegation-manifest.sh` verifies `qa-v1`
from those facts plus collector evidence. Source them from the project root.
Bash, jq 1.6+, Node.js 20+, and an authenticated `gh` (for the real comment
fetch) are required. Run `./tests/run.sh delegation_qa prompt_contracts` for
the focused deterministic suite; it uses a fake `gh` and needs no credentials.
`./tests/run.sh` includes it.

The runner's completion gate (`docs/delegation-gate.md`) runs this verifier
after every gated QA invocation. The QA parent still chooses the groups,
spawns, waits for, and replaces its workers. Ralph only snapshots what the parent planned and later
checks what the provider reports; it never starts a replacement.

## Checklist comment format

`prepare-qa-checklist` writes, and `runthrough-qa-checklist` updates, one PR
comment in this exact format:

```md
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: <behavior>
  - Setup: ...
  - Action: ...
  - Expected: ...
  - Isolation: ...
```

Parser rules (`delegation_qa_checklist_items`):

1. CRLF is normalized to LF. The marker appears exactly once and is the first
   nonblank line; the next nonblank line is exactly `## Local QA Checklist`.
2. The checklist ends at `<!-- ralph:qa-summary -->` or the end of the comment.
   Everything after the summary marker is ignored.
3. An item line is `- [ ] ` or `- [x] `, then one of `[PENDING]`, `[PASS]`,
   `[FAIL]`, `[BLOCKED]`, then `QA-` plus two or more digits, `: `, and the
   behavior text.
4. Instruction lines start with `  - Setup: `, `  - Action: `,
   `  - Expected: `, or `  - Isolation: `. Progress lines start with
   `  - Result: ` or `  - Evidence: `. A line indented by four or more spaces
   continues the preceding instruction or progress line. Blank lines are
   ignored. Any other line rejects the comment.
5. An item's text is its behavior plus its instruction lines, verbatim, joined
   with LF and outer whitespace trimmed. Checkbox state, status tag, progress
   lines, and the summary are excluded.
6. Zero items, a duplicate ID, or an empty text rejects the comment (exit 2).

So progress edits (checkbox, tag, Result/Evidence, summary) keep the same
items; changing an ID or instruction, or adding or removing an item, does not.

## Canonical digests

- Checklist digest: SHA-256 of compact UTF-8 JSON of the items sorted by `id`,
  each exactly `{"id":…,"text":…}` in that key order
  (`delegation_qa_checklist_digest`).
- Assignment digest: SHA-256 of compact JSON of exactly
  `{"taskId":…,"checklistItemIds":[…sorted]}` (`delegation_qa_assignment_digest`).

Both print `sha256:<64 lowercase hex>`. Vectors in `tests/suites/delegation_qa_test.sh`
were produced independently with `shasum -a 256`.

## Plan

Before its first spawn the QA parent runs:

```bash
source ./ralph/scripts/delegation-qa.sh
delegation_qa_plan_write <workspace>/state.json runthrough-qa-checklist <owner/repo> <comment-id> <<< '<assignments JSON>'
```

Assignments are `[{taskId, checklistItemIds}]`. The helper refetches the exact
comment, requires every snapshot ID in exactly one assignment, and atomically
writes `<workspace>/delegation/runthrough-qa-checklist.plan.json` (0600) in the
#37 shape: `schemaVersion`, `stepId`, `attemptId` (State's
`delegationAttempt.id`, or `ungated` for a legacy step, which no gate accepts),
`checklist {commentId, updatedAt, digest, items}`, and sorted `assignments`
with their digests. It prints the plan so the parent can copy each digest.

Each worker packet begins with:

```text
RALPH-TASK: <taskId>
RALPH-ASSIGNMENT: <assignmentDigest>
RALPH-RUN: <run>
```

Codex workers use `spawn_agent.task_name` `qa_r<run>_<assignment-digest-hex>`.
The Codex collector maps that digest back to the plan's task ID; Claude hooks
parse the three packet lines.

## Replacement runs

The parent alone decides whether to replace a worker. Every group starts at run
1. When a run failed, stopped, or never finished, the parent may end it and
launch run 2 (then 3, and so on) with the same task ID and assignment digest.
The checklist snapshot, task ID, item set, and digest never change.

Per assignment, the verifier groups direct workers of the current parent that
prove the plan's digest and task ID:

- Runs must be exactly `1..N`, each once. The highest run is `selected` and
  must complete; its lifecycle codes apply as usual.
- A lower run that ended `failed` or `stopped` is `superseded` and does not
  fail by itself. Only those outcomes prove a run ended: a lower `incomplete`
  run may still be running beside its replacement, so it fails with
  `TASK_DUPLICATED`. The parent must stop a hung run before replacing it.
- A superseded run must also have ended before any later run of its chain
  started: its `endedAt` must be present and at or before every later run's
  `startedAt`. A run that failed or stopped only after its replacement started
  overlapped it, so the chain fails with `TASK_DUPLICATED`. A missing
  `endedAt` on the lower run or `startedAt` on a later run cannot prove the
  sequence and fails closed the same way. Chains without replacements never
  consult the marks.
- A completed run cannot be replaced in v1, even when its returned evidence is
  unusable: that result fails the step instead. A completed lower run fails
  with `TASK_DUPLICATED`.
- Nesting, parentage, and model/effort checks apply to every run, superseded or
  not, so supersession never hides them. `VERIFIED` needs provider-reported
  settings only on selected runs; a superseded run without them does not cap
  the level.
- A worker with a missing or foreign digest, another task ID, or another parent
  joins no chain; it never fills a gap or supersedes anything.

The marks come from the collectors. Claude: `startedAt` is the position of the
worker's PreToolUse record in the attempt's append-only hook log, and `endedAt`
the position of its last PostToolUse, PostToolUseFailure, or SubagentStop
record. The PreToolUse hook finishes before the worker starts and each end hook
runs after it returned, so "end record before start record" proves the runs did
not overlap without trusting any clock. A background launch counts as ended
only once its SubagentStop arrives. Codex: `startedAt` is the earliest turn
`startedAt` and `endedAt` the latest turn `completedAt` reported by App Server
`thread/read`, in epoch seconds, and only once every turn is terminal. Seconds
are coarse: a replacement that starts in the same second its predecessor ended
counts as sequential. Any missing turn timestamp leaves the mark null.

Replacements stay inside one provider invocation. An internal CLI retry, manual
retry, or HITL restart is a new attempt with a fresh plan, so its workers start
again at run 1 and can never supersede an old session's workers.

| Chain | Result |
| --- | --- |
| run 1 failed or stopped; run 2 completed | pass; run 1 `superseded` |
| run 1 incomplete (no end evidence); run 2 completed | `TASK_DUPLICATED` |
| run 1 failed or stopped after run 2 started (overlap) | `TASK_DUPLICATED` |
| run 1 without `endedAt`, or run 2 without `startedAt` | `TASK_DUPLICATED` |
| run 1 completed; any run 2 | `TASK_DUPLICATED` |
| two workers with the same run | `TASK_DUPLICATED` |
| runs 1 and 3, or only run 2 | `TASK_UNEXPECTED` |
| replacement with another digest or task | `ASSIGNMENT_DIGEST_MISMATCH`, and the lower run stays selected |
| superseded run nested, reparented, or on the wrong model/effort | `NESTED_WORKER`, `PARENT_MISMATCH`, `MODEL_MISMATCH`, or `EFFORT_MISMATCH` |

## Verification

After each gated provider run the runner's gate calls
`delegation_qa_verification PLAN_FILE REPO`, which prints the request's `qa`
field `{plan, checklist}`: the plan file's value (`null` when absent,
`"invalid"` when unparsable) and the refetch of the plan's exact `commentId`
as `{commentId, status: ok|unavailable|invalid, items}`. A `qa-v1` request must
carry this field; other policies must not. `updatedAt` is audit metadata and is
never compared.

| Code | Meaning |
| --- | --- |
| `PLAN_MISSING` | No plan file. |
| `PLAN_INVALID` | Unparsable, unknown fields, wrong schema version or step, malformed or duplicate IDs, bad checklist digest, or an assigned ID not in the snapshot. No task identity is judged. |
| `ATTEMPT_MISMATCH` | The plan belongs to another attempt. |
| `ASSIGNMENT_DIGEST_MISMATCH` | A plan digest is not canonical, or a direct child's digest/task pair is not one plan assignment. |
| `ASSIGNMENT_MISSING` / `ASSIGNMENT_DUPLICATED` | A snapshot ID is unassigned / assigned twice. |
| `CHECKLIST_UNAVAILABLE` | The comment is deleted, unreadable, or not the planned ID. |
| `CHECKLIST_INVALID` | The refetched comment is malformed, unmarked, or has duplicate IDs. |
| `CHECKLIST_CHANGED` | Instruction digest or ID set differs from the snapshot. |
| `TASK_MISSING` | An assignment has no bound direct worker. |
| `TASK_DUPLICATED` | Two workers share a run, a completed or unfinished lower run was replaced, or a lower run did not provably end before a later run started. |
| `TASK_UNEXPECTED` | An assignment's runs are not exactly `1..N` (a gap, or no run 1). |

Lifecycle, nesting, parent, attempt, and model/effort codes apply exactly as in
`docs/delegation-manifest.md`; child lifecycle codes (`CHILD_*`) judge only
selected children. `expected` lists the plan's task IDs. `observed` counts the
selected direct children, so after valid replacements each logical assignment
counts once. Superseded children stay in `children` with their evidence.
