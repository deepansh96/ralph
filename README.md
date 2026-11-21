# Ralph

Ralph is a GitHub issue-driven pipeline for planning, implementing, checking,
opening a PR, running local QA, and reviewing one feature. It stores progress
in a per-issue `state.json` file and runs each step with the agent assigned in
that state.

## CLI

Run commands from the repository root (examples assume the conventional `ralph/` install folder; the install directory name is not hardcoded, so any folder name works and existing `ralph-v2/` installs keep working):

```bash
./ralph/ralph.sh --issue N
./ralph/ralph.sh status --issue N
./ralph/ralph.sh logs --issue N
./ralph/ralph.sh logs --issue N --step <step-id>
./ralph/cleanup.sh <issue-number>
```

- `ralph.sh --issue N` validates state and context, then runs pending steps until the pipeline finishes or blocks. After failure it skips normal work, runs pending always-run cleanup, and exits non-zero.
- `ralph.sh status --issue N` prints a step table with step ID, type, agent, status, duration, and cost.
- `ralph.sh logs --issue N` tails the active step log. Use `--step <step-id>` to read a specific step.
- `cleanup.sh <issue-number>` archives `workspaces/<issue-number>/` into `archive/<date>-<issue-number>/`.

Before the first pipeline step, the `CONTEXT.md` completeness check inherits
that step's `agent`, `model`, and `reasoningEffort`. It is a pre-run gate, not a
separate state step.

### Automated Grilling Sessions

```bash
./ralph/ralph.sh grill start --issue N --grilling-agent claude --answering-agent claude
./ralph/ralph.sh grill start --requirement-file PATH --grilling-agent claude --answering-agent claude \
  [--grilling-model M] [--grilling-effort E] [--answering-model M] [--answering-effort E]
./ralph/ralph.sh grill resume --id SESSION_ID
./ralph/ralph.sh grill status --id SESSION_ID
./ralph/ralph.sh grill logs --id SESSION_ID
./ralph/ralph.sh grill cleanup --id SESSION_ID
```

- `grill start` opens an opt-in Automated Grilling Session: a Grilling Agent and a separate Answering Agent, each in its own native Claude session or Codex thread. It needs exactly one of `--issue` or `--requirement-file`, and both agent flags (`codex|claude`, in any pairing). Omitted model/effort flags fall back to `agentDefaults` in `ralph.config.json`, and the resolved values are frozen in the record.
- Access: the Answering Agent never writes, the Grilling Agent writes only inside the repository, and both get read-only web and `gh` access. Claude runs sandboxed Bash (GitHub domains only; WebFetch/WebSearch cover the rest of the web) with Git index/ref/remote writes and `gh` writes denied. Codex runs the Answering Agent under a read-only permission profile with network enabled (no `--sandbox` flag, which would override the profile and drop network) and the Grilling Agent under `workspace-write` rooted at the repository. `start` refuses before any native session exists when the installed CLI cannot express that policy (for Codex, it renders each role's effective permissions with `codex debug prompt-input`). It never uses `--dangerously-skip-permissions`.
- `start` refuses a dirty worktree in the target repository (the Git toplevel above the Ralph directory; Ralph's own `grilling-sessions/` and `archive/` are ignored). On the default branch (from `refs/remotes/origin/HEAD`, else the remote's own HEAD; `start` refuses rather than guess) it creates `grill/issue-<N>-<slug>` or `grill/<slug>` and refuses if that branch already exists.
- The Grilling Session Record lives at `grilling-sessions/<id>/session.json` (gitignored, dirs `0700`, files `0600`) with the requirement snapshot in `requirement.md`, validated messages in `messages/`, and raw provider logs in `logs/`. `start` prints the session ID.
- After both sessions start, the coordinator relays rounds: Frontier (Grilling Agent) → Answers (Answering Agent) → answers merged into `decisions` → next Frontier, until the Frontier is empty. Then the Grilling Agent drafts the decision summary and issue, the Answering Agent reviews it once for faithfulness, and the Grilling Agent resolves the review. Every call resumes the stored native session by ID, and every prompt carries `[ralph-exchange:ex-NNNN]`. The message schemas in `prompts/grill/schemas/` are strict (every property required, unused ones `null`) so Codex accepts them as `--output-schema`; the coordinator drops null members and validates each message itself. A `reopens` entry sends the contradiction to the Answering Agent, and the new answer records `reopenedBy`.
- The session blocks for a human, keeping both native sessions, on a `needsHuman` answer, an unchanged Frontier (`no_progress`), a message still invalid after one re-emit request (`invalid_message`), or transient provider failures that outlast every retry (`transient_failure`; just run `resume` when the provider recovers). Other blocks write `human-input-<exchange>.md`; write under `## Answers` and run `resume`, which sends the input to the Answering Agent first and then relays its answers to the Grilling Agent.
- The run stops at the confirmation gate: `confirmation.md` in the session directory holds the summary, the issue draft, the diff, and flags for changes outside `CONTEXT.md`/`docs/adr/` and HEAD/branch drift. The record becomes `blocked/awaiting_confirmation` and the command exits 0. Write `approve`, `reject`, or `correct` (with the correction under `## Answers`) under `## Decision` and run `resume`.
- `approve` waits while another branch is checked out, and rewrites `confirmation.md` for a fresh decision when the flags changed after the gate. It then commits only `CONTEXT.md` and `docs/adr/`, pushes the branch, and edits (`--issue`) or creates (`--requirement-file`) the issue. Each action is recorded as it succeeds and `resume` retries only unfinished ones; a created issue carries a `ralph-grill-session` marker so a create interrupted before it was recorded is found rather than duplicated. `reject` also waits for the session's branch, then discards only the `CONTEXT.md`/`docs/adr/` changes. Finished sessions move to `archive/grilling/<date>-<id>/`.
- `resume --id` continues the session with the frozen configuration and rejects agent/model/effort flags. One coordinator holds a session at a time (a lock symlink naming its PID; a dead owner's lock is reclaimed under a guard). A native session that cannot be found ends the session as `context_lost`; no replacement session is ever started. Ctrl-C or TERM stops the running Agent call at once and leaves the exchange in flight: `resume` asks the Agent to re-emit its reply when its native store shows (or cannot rule out) that it received the exchange, and resends it otherwise. Effects of a completed exchange that a crash left unapplied are applied on resume.
- `status` prints the state and next action without raw logs or the requirement; `logs` summarizes each exchange's log plus its failed retry attempts, re-emit, and recovery logs; `cleanup` deletes a finished, failed, or crashed-start session.
- Modules: `scripts/grill.sh` (coordinator), `scripts/grill-record.sh` (record store), `scripts/grill-adapters.sh` (session adapters). Role prompts live in `prompts/grill/`.

## Monitoring

To monitor a running pipeline, poll with sleep intervals rather than continuously:

```bash
sleep 120 && ./ralph/ralph.sh status --issue N 2>&1
```

## Tests

Run the full deterministic shell suite from the repository root:

```bash
./tests/run.sh
```

Run specific suites by name:

```bash
./tests/run.sh agent pipeline prompt_contracts
```

`tests/test_ralph_v2.sh` is a compatibility wrapper around `tests/run.sh`. The suite is split by behavior under `tests/suites/`, with shared fixtures and fake external tools in `tests/lib/`. See `tests/README.md` for the suite map.

## Workflow

1. Grill the feature into a GitHub issue using the project context and decision workflow (`skills/grill-with-docs/`). For an effort too big or foggy for one grilling session, chart a wayfinder map first (`skills/wayfinder/`): a map issue with child decision tickets resolved one per session, except for read-only research subagents fanned out in parallel. The cleared map's destination decision issue enters Ralph at `init`, where `create-and-review-prd` performs the `to-spec` handoff. If grilling produces speculative `CONTEXT.md` or ADR changes, keep them on a pushed `grill/*` planning branch instead of committing them directly to `main`.
2. Run the `init.md` prompt for that issue so an agent creates `ralph/workspaces/<issue>/state.json`. By default, init skips review-decisions steps and PRD/slice council review rounds. Opt in with "with 1 review-decision round" or "with 1 review round on PRD".
3. Set `.baseBranch` explicitly in `state.json` before preflight reaches branch creation. Use the branch that already contains the grilling context: usually `main` for accepted docs, or the pushed `grill/*` planning branch for speculative feature docs.
4. Run `./ralph/ralph.sh --issue N`.
5. If a step blocks, answer the questions in `workspaces/<issue>/hitl-<step-id>.md`, then run the same command again.
6. After the PR workflow completes, run `./ralph/cleanup.sh <issue-number>`.

Grilling asks every currently answerable question in a numbered round, then recomputes the next frontier from the answers. Ask for one question at a time when that cadence is easier to work through.

The fixed flow is:

```text
grill -> init -> run -> cleanup
```

When grilling docs are not ready for `main`, use a stacked branch flow:

```text
main
  -> grill/issue-123-short-slug      # CONTEXT.md / ADR / issue shaping commits
      -> feat/issue-123-short-slug   # Ralph implementation branch
```

In that flow, set `.baseBranch` to `grill/issue-123-short-slug`. At PR time,
the `pr-creation` step merges the planning branch into the feature branch (so
the PR carries the planning docs) and opens the implementation PR against the
repository default branch, not the planning branch. One merge lands docs and
implementation together; delete the planning branch afterwards.

During `run`, Ralph executes:

```text
review-decisions (0-2 rounds, default 0)
-> create-and-review-prd
-> create-and-review-slices
-> preflight
-> implement-slice...
-> final-checks
-> pr-creation
-> prepare-qa-checklist
-> runthrough-qa-checklist
-> multi-axis-pr-review
-> cleanup-local-resources
```

## Configuration

Repo-wide delegated parent and worker defaults live in
`ralph/ralph.config.json`:

```json
{
  "agentDefaults": {
    "codex": {
      "model": "gpt-5.6-sol",
      "reasoningEffort": "medium"
    },
    "claude": {
      "model": "opus",
      "reasoningEffort": "medium"
    }
  },
  "nativeDelegation": {
    "codex": {
      "model": "gpt-5.6-luna",
      "reasoningEffort": "max"
    },
    "claude": {
      "model": "sonnet",
      "reasoningEffort": "high"
    }
  }
}
```

`agentDefaults` defines the parent settings and `nativeDelegation` defines the
worker settings. During preflight, Ralph snapshots both onto the generated
`runthrough-qa-checklist` and `multi-axis-pr-review` steps. Existing non-empty
step values are preserved, so later config edits affect new workspaces without
silently changing an existing workspace. To override one delegated step, edit
its `model`, `reasoningEffort`, `subagentModel`, and/or
`subagentReasoningEffort` fields in `state.json`. Prompt files contain no
concrete model or effort choices.

## State

Each issue has one workspace. Init creates both `state.json` and the empty
`local-resources.json` ledger, including the fixed always-run cleanup step:

```text
ralph/workspaces/<issue-number>/
```

The workspace contains `state.json`, logs, human-input flag files, and review artifacts.

Top-level `state.json` fields:

```json
{
  "issue": 2,
  "repo": "owner/repo",
  "baseBranch": "main",
  "branch": "feat/issue-2-short-slug",
  "status": "initialized",
  "createdAt": "2026-05-02T00:00:00Z",
  "steps": []
}
```

Each step has this shape:

```json
{
  "id": "implement-slice-14",
  "phase": "fixed",
  "type": "implement-slice",
  "status": "pending",
  "agent": "codex",
  "model": "<provider-model>",
  "reasoningEffort": "high",
  "subagentModel": "<provider-subagent-model>",
  "subagentReasoningEffort": "max",
  "reviewers": [],
  "hitl": false,
  "sub_issue": 14,
  "metrics": null,
  "notes": ""
}
```

Generated steps use `"agent": "codex"` by default. The two native-delegation
steps also receive explicit parent and worker model/reasoning snapshots during
preflight. Before a step runs, you can set `agent` to `claude` or `codex` and
edit all four settings in `state.json`; keep the parent and worker values valid
for the selected provider. Older delegated steps without snapshots still fall
back to the matching provider's `ralph.config.json` worker defaults. Other
steps may set `agent` to `deepseek` and edit their optional `model` and
`reasoningEffort` fields. DeepSeek
steps run through Pi and require Pi 0.70.1+ plus DeepSeek credentials in Pi's
auth store or `DEEPSEEK_API_KEY`; their defaults are `deepseek-v4-flash` with
`high` reasoning effort:

- Codex: `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`
- Claude: `low`, `medium`, `high`, `xhigh`, or `max`
- DeepSeek via Pi: `off`, `minimal`, `low`, `medium`, `high`, or `xhigh`

Effort availability still depends on the selected model and account. Omit a
field to use the CLI's configured default, except DeepSeek uses the defaults
stated above.

Step statuses are:

```text
pending -> in_progress -> completed
                       -> blocked
                       -> failed
```

After a failed step, Ralph skips remaining normal steps, runs pending steps
marked `"alwaysRun": true`, then exits non-zero. The failed step must still be
reset to `pending` or marked `completed` before normal work can resume. When
normal work is retried, completed always-run cleanup is automatically rearmed.

## Step Types

- `review-decisions`: reviews issue decisions against `CONTEXT.md`, `CLAUDE.md`, and ADRs; may block for human input.
- `create-and-review-prd`: preserves the original issue body, drafts the PRD following the `to-spec` skill (including the testing seams), runs council reviews (controlled by `reviewRounds`, default 0), and updates the parent issue.
- `create-and-review-slices`: drafts vertical AFK slices following the `to-tickets` skill with explicit blocking edges (native GitHub issue dependencies plus `Blocked by` body lines), runs council reviews (controlled by `reviewRounds`, default 0), creates GitHub sub-issues, and links them under the parent.
- `preflight`: backfills missing cleanup artifacts for older initialized workspaces, checks the working tree and `baseBranch` contract, creates/pushes the feature branch, appends the dynamic implementation and post-implementation steps, snapshots parent/worker settings onto delegated QA and review steps, and writes or backfills their delegation gate metadata on pending steps only.
- `implement-slice`: reads the assigned sub-issue, verifies blockers are closed, follows TDD at the PRD's pre-agreed seams, commits, pushes, and closes the sub-issue.
- `final-checks`: reads the complete branch diff, runs project checks, verifies every slice's acceptance criteria, and writes `final-checks.md` without changing product code.
- `pr-creation`: pushes the feature branch and idempotently creates or updates a PR with a summary and issue-closing links.
- `prepare-qa-checklist`: posts or updates one PR comment containing local-only manual QA items in the stable format from `docs/qa-delegation.md`.
- `runthrough-qa-checklist`: injects the provider-native delegation contract;
  the main agent snapshots an immutable assignment plan before its first spawn,
  safely batches QA checklist work across its own workers (packets open with
  `RALPH-TASK`, `RALPH-ASSIGNMENT`, and `RALPH-RUN: 1`), then validates their
  evidence and updates the same PR comment without executing a
  QA item itself.
- `multi-axis-pr-review`: injects a provider-specific native delegation contract,
  runs five flat review workers named `matt_standards`, `matt_spec`,
  `ponytail`, `isolated_codex`, and `supe` in two capacity-safe batches, each
  packet opening with `RALPH-TASK` and `RALPH-RUN: 1`, verifies and votes
  on their findings, and posts one consolidated PR comment. Two Matt workers run
  Standards and Spec in parallel; then three workers run Ponytail, isolated
  Codex, and Supe in parallel. By default, Codex workers use Luna with `max`
  reasoning and Claude workers use Sonnet with `high` effort through native
  foreground Agent calls to a session-local `ralph-worker` (ungated legacy
  steps keep the dynamic Workflow tool). Preflight snapshots the configured
  parent and worker settings into state, and they can be overridden per step.
- `cleanup-local-resources`: always runs after success or failure and removes pipeline-owned processes, containers, sessions, temporary files, and worktree leftovers.

## Delegation gate

Steps with `delegation` metadata (preflight writes it for
`runthrough-qa-checklist` and `multi-axis-pr-review`) complete only when the
[completion gate](docs/delegation-gate.md) verifies provider evidence at
`OBSERVED` or `VERIFIED`. Before every provider invocation, including internal
retries and HITL resumes, the runner stamps a fresh `delegationAttempt` and
rerenders the prompt. It then collects evidence bound to that attempt only:
[Claude hooks](docs/claude-delegation.md) for a session-local foreground
`ralph-worker`, or the exec parent's children read through a fresh
[Codex App Server](docs/codex-delegation.md). The gate writes one private 0600
[manifest](docs/delegation-manifest.md) to
`workspaces/<issue>/delegation/<step>.manifest.json`; `qa-v1` also checks the
[immutable QA plan and stable checklist](docs/qa-delegation.md). Any other
result, a provider failure (`PROVIDER_FAILED`), an unsupported provider or
policy, missing worker settings, or a manifest write failure marks the step
`failed`, and always-run cleanup still runs. A blocked (HITL) run writes no
manifest until it reaches a terminal result. Steps without metadata behave
exactly as before. The provider's main agent owns all worker orchestration;
Ralph only observes and gates. Run
`./tests/run.sh delegation_gate claude_delegation codex_delegation delegation_manifest delegation_qa`
for deterministic coverage; the linked guides document prerequisites and the
separate opt-in live collection probes. The opt-in live smoke tests,
`tests/probes/claude-gate-smoke.sh` and `tests/probes/codex-gate-smoke.sh`, each
run one real gated QA step end to end
([Claude](docs/delegation-gate.md#live-claude-smoke-test),
[Codex](docs/delegation-gate.md#live-codex-smoke-test)).

## Bundled Skills

`ralph/skills/` contains pipeline and supporting skills:

- `to-spec/` — turn grilled decisions into a spec/PRD (with testing seams)
- `to-tickets/` — break a spec into tracer-bullet slices with blocking edges
- `tdd/` — the red → green loop, seams, and test anti-patterns
- `matt-pocock-code-review/` — two-axis Standards and Spec review
- `ponytail-review/` — over-engineering and deletion-focused review
- `run-codex-review/` — isolated Codex App Server review
- `supe-review-code-changes/` — correctness, security, compatibility, and test review
- `domain-modeling/` — glossary and ADR discipline, plus domain awareness for consumers
- `grilling/` — the round-based interview loop (facts from the environment, decisions from the human)
- `grill-with-docs/` — grilling plus inline `CONTEXT.md`/ADR updates; the default entry point
- `wayfinder/` — map an effort too big for one session as decision tickets; hands its destination issue to `init` for `to-spec`
- `research/` — investigate a question against primary sources, leave a cited note
- `writing-for-agents/` — model-invoked guidance from `mattpocock/skills` v1.2.2 for skills and agent-facing documents
- `codebase-design/` — deep-module vocabulary required by the architecture improvement skill
- `improve-codebase-architecture/` — user-driven architecture scan from `mattpocock/skills` v1.2.2 with a visual report and grilling follow-up
- `prototype/` — supporting skill from `mattpocock/skills` v1.2.2 for shareable logic demos and switchable UI variants
- `wizard/` — supporting skill from `mattpocock/skills` v1.2.2 for interactive human-only setup; not part of the fixed pipeline
- `quiz-grilling/` — browser quiz wrapper for grilling rounds with recommended and free-text answers, Wait-what views, temporary Cloudflare/ngrok links, and owned cleanup
- `wait-what/` — user-driven skill from `mattpocock/skills` v1.2.2 that re-pitches the previous response more clearly

Tracker operations (sub-issues, native blocking edges, wayfinding operations) live in `docs/agents/issue-tracker.md`, referenced from the `Issue tracker` section of `AGENTS.md`.

The bundle is self-contained. Skill references point at files inside `ralph/skills/`, not at the user's global skill directory.
