# Delegation completion gate

`scripts/delegation-gate.sh` connects the collectors and verifiers to the
runner. A step whose State has a `delegation` key cannot become `completed`
until its provider evidence passes the named policy at `OBSERVED` or
`VERIFIED`. Ralph only observes and gates. The provider's main agent still
chooses, groups, spawns, waits for, and replaces its workers. Ralph never
launches, schedules, or retries a worker.

Run `./tests/run.sh delegation_gate` for the end-to-end checks. The suite drives
`ralph.sh --issue N` with fake Claude, Codex (exec and App Server), and `gh`
binaries. `./tests/run.sh` includes it. Prerequisites are Bash, jq 1.6+, and
Node.js 20+. The deterministic suite needs no provider credentials. The early
collection probes passed on Claude Code 2.1.263 and Codex CLI 0.153.4 (see the
collector guides). Fake fixtures are not compatibility proof: the full gated
path is compatibility-verified only by the real smoke tests:
[Claude](#live-claude-smoke-test) and [Codex](#live-codex-smoke-test).

## Activation

Preflight writes `{"schemaVersion":1,"policy":"qa-v1"}` on new
`runthrough-qa-checklist` steps and `{"schemaVersion":1,"policy":"pr-review-v1"}`
on new `multi-axis-pr-review` steps. On every rerun,
`state_backfill_delegation_metadata STATE STEP POLICY` (`scripts/state.sh`)
fills that metadata only on an existing `pending` step with no `delegation`
key. It never changes an explicit value, even a malformed one, and never
touches completed, running, blocked, or failed steps. Completed steps are never
rechecked.

Steps without a `delegation` key take the unchanged legacy path. They get no
attempt field, no hooks, no session-local worker, and no manifest. Claude keeps
the Workflow contract for them. Always-run cleanup is unchanged; it runs after a
gated failure exactly as after any other failure.

## Runner order

For a gated step, `ralph.sh` calls `delegation_gate_run_step` in place of
`agent_run_step`:

1. **Fail closed before launch.** An agent other than `claude`/`codex`,
   metadata that is not the exact v1 shape (unknown policy or version, extra
   fields, `null`), or a missing or invalid `model`, `reasoningEffort`,
   `subagentModel`, or `subagentReasoningEffort` fails the step. No provider
   runs and no manifest is written.
2. **Stamp and prepare.** `delegation_prepare_invocation` saves a fresh
   `delegationAttempt` in State and creates a private
   `workspaces/<issue>/ralph-delegation-<attempt>/` directory. The callback
   rerenders the prompt from that State, adding HITL answers on a resume, and
   deletes the previous QA plan. For Claude, it creates new hook settings and a
   new parent session ID.
3. **Run the provider once.** Codex runs the normal `codex exec --json`
   command. Claude runs the normal CLI with these additions:
   - a session-local `--agents` `ralph-worker` definition using the step's
     worker model and effort, with Agent and Workflow disallowed;
   - `--forward-subagent-text`, the temporary `--settings` hooks, and
     `--session-id`;
   - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, set only for this invocation.

   The log goes to `logs/<step>.log`.
4. **Blocked/HITL.** If the provider exits 0 after marking the step `blocked`,
   the gate removes the invocation inputs and returns. It writes no manifest.
   A resume is a new invocation with a fresh attempt, session, hooks, and plan.
5. **Collect, write, verify.** On any other terminal result, the gate collects
   evidence bound to this attempt:
   - Claude: the hook events for this session.
   - Codex: the single `thread.started` parent in this log, read through a
     fresh App Server, plus the plan when it is schema-valid.

   Unavailable or unbound evidence becomes `null`. The gate builds the
   verification request, which carries the QA refetch facts for `qa-v1`, and
   atomically writes `workspaces/<issue>/delegation/<step>.manifest.json`
   (0600). A nonzero provider exit sets `PROVIDER_FAILED` and keeps any safe
   partial children.
6. **Complete or fail.** The step completes only at `OBSERVED` or `VERIFIED`.
   Any other level uses the existing `failed` status. stderr prints one safe
   line, such as `Delegation gate: step 'multi-axis-pr-review' is UNVERIFIED
   TASK_MISSING`. If the manifest cannot be written, the gate prints
   `MANIFEST_WRITE_FAILED` and the step fails. No manifest is claimed.

The invocation directory is removed after every result: success, failure,
block, internal retry, or interruption. `handle_shutdown` removes the live
directory before resetting the step to `pending`.

## Retries

The existing retry limit (3 invocations) and backoff (`RALPH_RETRY_DELAYS`)
still apply, and so does the retryable-log rule. Before a retry, the gate writes
the failed invocation's `UNVERIFIED`/`PROVIDER_FAILED` manifest, cleans its
inputs, and archives its log as `<step>.log.attempt-N`. It then returns to step
2, so the retry gets a new attempt, prompt, plan slot, hooks, session, and log.
Only the final invocation's manifest decides completion. A first parent that
spawned every worker and then failed cannot supply proof for the second parent.

A manifest is current only when its `attemptId` equals State's
`delegationAttempt.id`. While a retry runs, the file on disk still belongs to
the earlier attempt, so it can never look current. The final write atomically
replaces it. The final attempt stays in State after completion or failure.

## Status

`./ralph.sh status --issue N` shows delegation only for steps that have a
`delegation` key. It displays what Ralph observed and never implies that Ralph
orchestrated anything. The provider's main agent still owns every spawn,
batch, and replacement. `./tests/run.sh status_delegation` covers this output
through the CLI with fake Codex App Server pages and hand-written hook events
and manifests. It needs the same prerequisites as the gate suite and no
credentials.

- **Terminal summary.** A `completed` or `failed` gated step prints exactly one
  line under its table row:

  ```text
  2    multi-axis-pr-review     multi-axis-pr-review codex      completed    4m 2s      -
       Delegation: OBSERVED 5/5
  ```

  The level is `OBSERVED`, `VERIFIED`, or `UNVERIFIED`. `N` is
  `observed.selectedCount` and `M` is `expected.taskCount` from
  `delegation/<step>.manifest.json`, so a missing child still counts in the
  denominator. The mutable QA plan and checklist comment are never reread.
  Ralph prints the line only when the manifest's `stepId` and `attemptId`
  match the step and its State `delegationAttempt.id`. A stale-attempt or
  missing manifest prints nothing.
- **Live activity.** An `in_progress` gated step replaces the usual
  "Current activity" log snippet with best-effort lines that carry no detail:
  `[delegation] child started` and `[delegation] child completed`. Claude
  lines come from the current attempt's sanitized hook events. A child starts
  at `SubagentStart` and completes at its `completed` foreground Agent return
  after a stop. Status reads those events only when the hook context names the
  State attempt. Codex lines come from direct children of the current log's
  parent, read through a fresh App Server (`RALPH_CODEX_COLLECT_TIMEOUT`
  defaults to 10 seconds here). Status ignores a log older than the attempt's
  `startedAt`. Nested work is not listed. Missing, stale, unbound, or
  unavailable evidence prints no lines, and the status command still succeeds.
- **Redaction.** Delegation output is limited to fixed strings and manifest
  counts. It never prints prompts, tool arguments, opaque IDs, paths,
  commands, or raw events. Gated steps therefore do not show the parent log
  snippet, which can contain all of these.

Steps without a `delegation` key, including every legacy step, keep their
existing rows and log snippet unchanged.

## Live Claude smoke test

`tests/probes/claude-gate-smoke.sh` runs the complete gated Claude path once
against real Claude. It uses `ralph.sh --issue N` and the normal Claude
adapter. `./tests/run.sh` never runs it. It is a compatibility check of the gate,
not a new policy: it uses `qa-v1` unchanged, with one checklist item and one
assignment. As in production, the Claude parent owns orchestration: it writes
the plan, launches and awaits its one worker, and edits the checklist comment.
Ralph only stamps the attempt, observes, and gates.

Prerequisites:

- Bash, jq, Node.js 20+, git, and Claude Code with foreground Agent
  definitions and hooks.
- `CLAUDE_CONFIG_DIR` must point to an authenticated profile that can use the
  requested models. The documented profile is `~/.claude-t4d-api`
  (`api_key_helper`).
- An empty scratch directory with an absolute path. Register it, workspace
  `workspaces/9947`, and the process in the issue's local-resource ledger
  first.

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-t4d-api" RALPH_CLAUDE_GATE_SMOKE=1 \
  tests/probes/claude-gate-smoke.sh /absolute/registered/empty-scratch-directory
```

The test creates a disposable git project with a local `origin` and a one-line
PR change. It links `ralph` to this checkout and puts a local `gh` stub
(`tests/probes/claude-gate-smoke-gh.cjs`) first on `PATH`. The stub serves one
PR, its issue, and one marked `QA-01` checklist comment. It supports comment
edits and bumps `updated_at` on each edit. Nothing goes to GitHub. It then
writes a State with a completed preflight and one pending `claude`
`runthrough-qa-checklist` step carrying `qa-v1` metadata. It runs the real QA
prompt from the project root.
Optional `RALPH_CLAUDE_SMOKE_MODEL` (parent, default `opus`, effort `medium`),
`RALPH_CLAUDE_SMOKE_WORKER` (default `claude-sonnet-5`, effort `high`), and
`RALPH_CLAUDE_SMOKE_ISSUE` (default `9947`) change the run.

It passes only when all of these hold:

- `ralph.sh` exits 0, the step is `completed`, and the 0600 manifest and plan
  both carry State's current `delegationAttempt.id`.
- The manifest is `qa-v1` from `hooks` with no mismatch codes and
  `observed` 1/1/1. It has exactly one child: a completed, non-nested, run-1
  direct worker of the manifest parent, bound to the plan's task ID and
  assignment digest.
- A `VERIFIED` result must carry provider-reported worker effort and model,
  and an explicit requested ID must match exactly. An `OBSERVED` result must
  have a missing effective field; the output names it.
- The comment's `updated_at` changed and `QA-01` shows a `[x]` progress tag,
  yet the gate passed.
- The manifest has only the contract keys. It and the `ralph.sh status`
  output contain no fixture token, checklist text, packet markers, prompt
  heading, or scratch/home/checkout path. Status shows
  `Delegation: <level> 1/1` and no opaque IDs.
- No `ralph-delegation-*`, `ralph-37-claude-*`, or `events.jsonl` input
  remains. The project has no `.claude` settings or agents. The profile's
  and `~/.claude`'s `settings.json`, `settings.local.json`, and `agents/`,
  and this checkout's `.claude/`, are byte-identical before and after.

Exit 0 is PASS and 1 is FAIL. Exit 2 is a SKIP, never a pass: the opt-in or
scratch directory is missing, a tool is missing, `CLAUDE_CONFIG_DIR` is unset,
the profile is not logged in (`claude auth status`), or the workspace already
exists. On failure the test prints only the gate's fixed `Delegation gate:`
line. It removes the workspace and scratch contents on every exit. The log
stays inside the removed workspace. `./tests/run.sh claude_gate_smoke` checks
this harness with a fake Claude parent: skips, VERIFIED and OBSERVED passes, no
worker, no progress edit, and a user-settings change.

On 2026-09-25 the smoke test passed on Claude Code 2.1.282 with the
`claude-t4d-api` profile, an `opus`/medium parent, and a `claude-sonnet-5`/high
worker. The step completed at `VERIFIED 1/1`: the provider reported the worker
model and effort, and the progress edit did not fail the gate. Temporary inputs
were removed and user settings were unchanged.

## Live Codex smoke test

`tests/probes/codex-gate-smoke.sh` runs the complete gated Codex path once
against real Codex. It uses `ralph.sh --issue N` and the normal `codex exec`
adapter. `./tests/run.sh` never runs it. Like the Claude test, it checks
compatibility and adds no policy: it uses `qa-v1` unchanged, with one checklist
item and one assignment. The Codex parent owns orchestration: it writes the
plan, spawns and waits for its one `qa_r1_<digest>` worker, and edits the
checklist comment. Ralph only stamps the attempt, observes, and gates.

Prerequisites:

- Bash, jq, git, Node.js 22.13+ (for `--permission`), and a Codex CLI with
  `spawn_agent` and `app-server`.
- A logged-in Codex CLI (`codex login status`) that can use the requested
  models.
- An empty scratch directory with an absolute path. Before you run the test,
  register it, workspace `workspaces/9949`, and the process in the issue's
  local-resource ledger.

```bash
RALPH_CODEX_GATE_SMOKE=1 \
  tests/probes/codex-gate-smoke.sh /absolute/registered/empty-scratch-directory
```

The fixture matches the Claude test: a disposable git project, a linked
`ralph`, and the shared local `gh` stub with one `QA-01` comment. The
pending `runthrough-qa-checklist` step uses agent `codex`. During the run,
`CODEX_BIN` points the gate's collector at
`tests/probes/codex-gate-smoke-rpc.cjs`. That recorder forwards the real
`codex app-server` stdio and forces every `thread/list` page size to 1. It
records only methods, parameters, listed IDs, cursors, and read IDs.
Optional variables change the run:

- `RALPH_CODEX_SMOKE_MODEL`: the parent model. Default `gpt-5.6-sol`,
  effort `medium`.
- `RALPH_CODEX_SMOKE_WORKER` and `RALPH_CODEX_SMOKE_WORKER_EFFORT`: the
  worker model and effort. Defaults `gpt-5.6-luna` and `max`.
- `RALPH_CODEX_SMOKE_ISSUE`: the workspace issue number. Default `9949`.

It passes only when all of these hold:

- `ralph.sh` exits 0, the step is `completed`, and the 0600 manifest and plan
  both carry State's current `delegationAttempt.id`.
- The manifest is `qa-v1` from `app-server`, has no mismatch codes, and shows
  `observed` 1/1/1. Its parent is the single `thread.started` parent in this
  attempt's step log. Its one child is a completed, non-nested, run-1 direct
  worker of that parent. The child is bound to the plan's task ID and
  assignment digest.
- The gate's own App Server session sent only `initialize`, `initialized`,
  `thread/list`, and `thread/read`. Both listings (`parentThreadId`, then
  `ancestorThreadId`) used the five subagent source kinds and page size 1. The
  first request had no cursor. Each later request carried the previous
  non-null `nextCursor`, and the last page's cursor was null. The direct
  listing returned exactly the manifest child, which was then read with
  `includeTurns: true`.
- A second fresh App Server process reproduces the manifest children. This
  collector runs under `node --permission` with read access only to its own
  script, so it cannot read rollout files or any other file. The App Server
  itself is provider-owned and runs without that restriction. Unavailable
  evidence fails the test. There is no rollout-file fallback.
- A `VERIFIED` result must have thread-level worker model and effort equal to
  the request. An `OBSERVED` result must be missing an effective field, and
  the output names it.
- The comment's `updated_at` changed and `QA-01` shows a `[x]` progress tag,
  yet the gate passed.
- The manifest has only the contract keys. It contains no fixture token,
  checklist text, packet markers, prompt heading, or scratch/home/checkout
  path. The `ralph.sh status` output shows `Delegation: <level> 1/1` and
  contains no fixture token, packet markers, or checklist text. It also shows
  no attempt, parent, or child ID. No `ralph-delegation-*` input remains.

Exit 0 is PASS and 1 is FAIL. Exit 2 is a SKIP, never a pass. The test skips
when:

- the opt-in or scratch directory is missing;
- a tool is missing, or Node lacks `--permission`;
- Codex is not logged in;
- the workspace already exists.

On failure the test prints only the gate's fixed `Delegation gate:` line. It
removes the workspace, scratch contents, and RPC records on every exit. Codex
keeps its own session history under its home directory, as for any
`codex exec`. `./tests/run.sh codex_gate_smoke` checks this harness with a fake
Codex parent and a paginating fake App Server. It covers skips, VERIFIED and
OBSERVED passes that follow two page cursors, and failures for a missing
worker, an unavailable App Server, and a missing progress edit.

On 2026-09-25 the smoke test passed on Codex CLI 0.155.1 with a
`gpt-5.6-sol`/medium parent and a `gpt-5.6-luna`/max worker. The step
completed at `VERIFIED 1/1`: the App Server reported the worker model and
effort. The progress edit did not fail the gate, and the file-read-denied
collector reproduced the evidence. With one child, the real server answered
each one-item listing with a null `nextCursor`. The live run therefore
checked the page size and cursor termination. The harness covers following
several pages.

## Related guides

- `docs/delegation-contracts.md`: schemas, attempts, and private writes.
- `docs/claude-delegation.md` and `docs/codex-delegation.md`: the collectors.
- `docs/delegation-manifest.md`: the manifest, evidence levels, and `pr-review-v1`.
- `docs/qa-delegation.md`: the QA plan, checklist refetch, and `qa-v1`.
