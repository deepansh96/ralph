# Run Through QA Checklist

Execute the PR's local QA checklist.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Agent: {{AGENT}}
Mode: AFK, no HITL

{{NATIVE_DELEGATION_CONTRACT}}

## Prepare

- Read the whole PR, its diff, the parent issue, linked sub-issues, and project
  instructions.
- Fetch origin, check out `{{BRANCH}}`, resolve the actual PR head revision,
  and verify `git rev-parse HEAD` equals it.
- Require an empty `git status --porcelain`. Fail before QA if the checkout is
  stale or the worktree contains uncommitted changes.
- Find the one PR comment containing `<!-- ralph:qa-checklist -->` and record
  its numeric comment ID. Fail if there is none or more than one.
- Turn every checklist item into an ordered todo.

## Assignment Plan

Ralph verifies this step from provider evidence against an immutable plan.
Choose the task groups first (see Required Delegation). Give each group a
unique snake_case task ID such as `qa_group_1`. Before the first spawn,
snapshot the checklist and write the plan from the project root:

```bash
source ./ralph/scripts/delegation-qa.sh
delegation_qa_plan_write {{WORKSPACE}}/state.json {{STEP_ID}} {{REPO}} <comment-id> <<'JSON'
[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02"]},{"taskId":"qa_group_2","checklistItemIds":["QA-03"]}]
JSON
```

It refetches the comment, parses the instruction items, requires every item ID
in exactly one group, and atomically writes
`{{WORKSPACE}}/delegation/{{STEP_ID}}.plan.json` with mode 0600. It prints the
plan, including each group's `assignmentDigest`. If it fails, fail this step
before spawning anything. Never write, edit, or regenerate the plan by hand or
after the first spawn.

## Required Delegation

The parent is the QA orchestrator. It owns Prepare, work allocation, progress
comment updates, cleanup, and evidence validation. It must not execute checklist
items itself.

Prepare one shared QA packet containing the PR scope, actual head revision,
checklist, local environment details, project instructions, and Local-Only Rules.
Delegate execution of every checklist item through the exact provider-native
mechanism in the injected contract above. The parent may assign one item or a
dependency-safe group of items to each top-level worker. Workers must not spawn
further subagents.

Use multiple top-level workers when the checklist contains independent groups.
Do not give the whole checklist to one worker unless every item genuinely shares
one execution context or forms one strict dependency chain. Assign every item to
exactly one active worker per attempt.

The parent decides the batches and concurrency:

- Independent read-only checks may run concurrently.
- Serialize work that shares or mutates a service, database, browser session,
  worktree, temporary path, or the local-resource ledger.
- Run only one resource-mutating worker at a time. It must record owned resources
  before starting them and clean them when its assigned work is done.

### Task identity

Launch each planned group as one direct worker. The first three lines of its
packet must be exactly its planned values and run number:

```text
RALPH-TASK: <taskId>
RALPH-ASSIGNMENT: <assignmentDigest>
RALPH-RUN: <run>
```

For Codex, set the `spawn_agent` `task_name` to `qa_r<run>_<assignment-digest-hex>`:
the run number, then the 64 hex characters of `assignmentDigest` without the
`sha256:` prefix. The first run of every group is 1.

You decide whether to replace a worker; Ralph never starts a replacement.
You may replace a group's worker only when its run
failed, stopped, or never finished.
Stop a run that never finished before replacing it: Ralph accepts a
replacement only beside a failed or stopped run and treats a lower run still
in progress as a concurrent duplicate. Wait until the run has fully ended:
Ralph checks that each replaced run ended before its replacement started and
fails an overlapping replacement. Then launch one replacement with the next run number (2, then 3, and so on,
with no gaps) and the unchanged taskId and assignmentDigest. Ralph selects the
highest run, which must complete; lower runs become `superseded`. Never split
or merge a group or change its items, and
never run two workers for the same group at once. Each run, superseded or not,
must be a direct worker with the requested model and effort.
A completed run cannot be replaced, even when its returned evidence is
unusable: unusable evidence fails this step. If you stop replacing a failed
group, record its items as `[BLOCKED]` with the failure. Replacements belong to
this provider session only: if Ralph restarts the step, write the fresh plan
and start again at run 1.

Each worker must return this result for every assigned item:

- checklist item ID and exact item text
- `PASS`, `FAIL`, or `BLOCKED`
- the action it performed and the behavior it observed
- concise evidence, including relevant output or artifact paths
- resources started, ledger entries made, and cleanup completed

Workers return results only to the parent. They must not edit GitHub comments or
product code. After results return, the parent validates that every checklist
item has one supported status and enough evidence, then updates the marked PR
comment in original checklist order.

Evidence validation is not QA execution. The parent must not rerun a command,
open a browser, call the application, start a service, or query a database to
confirm a worker result. It may perform only the orchestration operations in
Prepare, Assignment Plan, Progress, cleanup, and the final worktree integrity
check. If a worker fails or returns an unusable result, the parent
must not replace the missing work by performing the QA item itself.

## Local-Only Rules

- Use only local services and free local ports.
- Stub all external calls.
- Use only local databases. A fresh seeded database is allowed.
- Use a local browser for browser items.
- Do not change product code or commit fixes during QA.

Before starting a process, container, browser/computer-use session, or creating
a temporary path, append enough ownership information to
`{{WORKSPACE}}/local-resources.json` for the cleanup step to remove it safely.
Use names prefixed with `ralph-{{ISSUE}}-` where the tool supports names.

## Progress

After each completed item result, the parent edits the same marked PR comment.
Replace only the item's `[ ] [PENDING]` prefix:

- `[x] [PASS]` when observed behavior matches
- `[x] [FAIL]` when behavior is wrong
- `[x] [BLOCKED]` when the local environment cannot exercise it

Add the observed result under the item's existing lines as `  - Result:` and
`  - Evidence:` lines; continue a longer value on lines indented by four spaces.
Never change an item's ID, behavior text, or Setup/Action/Expected/Isolation lines,
and never add or remove items: Ralph rejects the run if those instructions
differ from the plan snapshot. Do not create progress-comment spam.

After all items, append `<!-- ralph:qa-summary -->` and then a concise summary to
the same comment: what passed, failed, or was blocked; issues found; and
possible fix directions.

Clean resources started by this step before completing, including on failure.
Verify the worktree is still clean. Product failures and blocked items are
reported but do not fail this step; fail only if the checklist cannot be read
or the QA workflow itself cannot be completed and reported.
