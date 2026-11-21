---
name: decisions
description: Key Ralph architectural and workflow decisions with reasoning. Load when changing pipeline policy or understanding why behavior exists.
triggers:
  - "why do we"
  - "decision"
  - "baseBranch"
  - "review"
  - "agent"
  - "background"
  - "HITL"
edges:
  - target: context/architecture.md
    condition: when a decision relates to pipeline flow or component boundaries
  - target: context/stack.md
    condition: when a decision relates to shell, jq, gh, Claude, Codex, council, or mex
  - target: patterns/run-and-monitor-pipeline.md
    condition: when a decision affects live run behavior
  - target: patterns/initialize-issue-workspace.md
    condition: when a decision affects init or branch contracts
last_updated: 2026-09-27
---

# Decisions

## Decision Log

### Inherit context-check execution from the first runnable step
**Date:** 2026-08-30
**Status:** Active
**Decision:** The pre-run `CONTEXT.md` completeness check executes through `agent_run_step` with the first runnable step's `agent`, `model`, and `reasoningEffort`, and parses the selected provider's log format. It remains a gate outside State rather than becoming a separate Step.
**Reasoning:** A hidden Claude dependency made Codex- or DeepSeek-owned pipelines fail before their configured first step when Claude was unavailable. State already contains the auditable execution settings that should govern the run.
**Alternatives considered:** Keep Claude hardcoded (rejected because it adds an unrelated credential requirement), or add a configurable context-check pseudo-step (rejected because it duplicates settings and changes the visible pipeline for a small pre-run validation).
**Consequences:** The first runnable step's provider CLI must be available before the pipeline starts. Context-check logs may use Claude, Codex, or DeepSeek event formats, while the listed step stays pending until the gate passes.

### Keep native delegation provider-owned and config-driven
**Date:** 2026-08-24
**Status:** Active
**Decision:** Step prompts may request one reusable provider-specific native delegation contract selected from their main `agent`. Repo-wide defaults live in `ralph.config.json`: Codex parents use Sol/medium with Luna/max workers, while Claude parents use Opus/medium with Sonnet/high workers. Preflight snapshots all four effective settings onto generated delegated steps; optional step fields override those snapshots. Each step defines its own flat topology: multi-axis review launches separate Matt Standards and Spec workers together, then Ponytail, isolated Codex, and Supe together; QA lets the main agent form dependency-safe worker batches, keeps shared-resource mutations serialized, and limits the parent to evidence validation rather than QA execution. Ralph renders the instructions but never launches or coordinates workers itself.
**Reasoning:** Claude Code and Codex are post-trained to operate their own delegation tools, but workers inherit the parent configuration when the prompt does not name a model and effort. Codex can set both values on a subagent spawn. Claude Code session-local Agent definitions support both model and effort. Live testing on 2.1.263 bound foreground Agent tool returns to start/stop hooks and task markers, while Workflow evidence could not bind those links. Gated Claude prompts therefore select the configured `ralph-worker` Agent definition with invocation-local foreground enforcement; ungated prompts retain Workflow until activation. A flat topology works on both providers, keeps the main agent in control, preserves Standards/Spec context isolation, and lets the same provider contract serve review, QA, and future delegated steps without carrying step-specific policy.
**Alternatives considered:** Let workers inherit the parent (rejected because a Sol/medium parent produced Sol/medium workers), or add a Ralph-owned fan-out runner (rejected because it duplicates provider-native orchestration and cannot share one model vocabulary across providers).
**Consequences:** Delegated QA and multi-axis review steps support Claude or Codex as their main agent and fail during preflight snapshotting or prompt rendering for an unconfigured provider or incomplete configuration. Prompt fragments no longer hardcode model or effort. Changing `ralph.config.json` affects newly generated or legacy unsnapshotted delegated steps without silently changing existing snapshots. Claude main agents use the session-local Agent definition on the opt-in collection path and future gated path; no persistent settings are changed. Legacy main agents retain their session-scoped dynamic workflow; Codex main agents use native subagent calls directly. Workers never spawn workers. Review produces five independent results in flat 2+3 batches that fit the live Codex runtime. The QA parent owns assignment, shared writes, evidence completeness, reporting, cleanup, and worktree integrity, but it must re-delegate missing evidence instead of running a checklist item. Each main agent must fail rather than silently falling back when its native tool cannot apply the requested worker settings.

### Keep browser-based grilling disposable and parent-owned
**Date:** 2026-08-16
**Status:** Active
**Decision:** `quiz-grilling` wraps the existing grilling Frontier in a dependency-free local web app with optional Cloudflare/ngrok exposure. Read-only exploration may run in two subagent waves, while the parent owns questions, answers, writes, user communication, processes, and cleanup.
**Reasoning:** A one-card-at-a-time quiz makes dense decision rounds easier to answer from another device without changing grilling semantics. Explicit process records and a marked temporary directory make the public surface removable when the session closes.
**Alternatives considered:** Build a permanent hosted app (rejected as infrastructure for a temporary planning surface), or copy a new ad hoc HTML/server stack for every grilling session (rejected because behavior and cleanup drift).
**Consequences:** Node.js is required for quiz sessions; a public link additionally needs `cloudflared` or `ngrok`. Quiz payloads must contain no secrets, and every terminal path runs the bundled cleanup helper.

### Review and fix every slice with a dedicated review-slice step
**Date:** 2026-07-09
**Status:** Superseded on 2026-07-30
**Decision:** Preflight appends a `review-slice` step immediately after each `implement-slice` step. It reviews only that slice's diff along the bundled code-review skill's two axes (Standards with the Fowler smell baseline, Spec against the sub-issue and PRD) and fixes what it finds before the next slice starts.
**Reasoning:** Per-slice review catches spec gaps and standards drift while the slice's context is fresh and the diff is small; deferring all review to `pr-review` makes findings expensive to fix. Refactoring was removed from the TDD loop upstream (mattpocock/skills v1.1.0), so the review step is where cleanup now lives.
**Alternatives considered:** Review only at PR time (rejected: findings arrive after all slices stack), or making review-slice opt-in like review-fixes (rejected: the user wants it default-on).
**Consequences:** Pipelines run twice as many dynamic slice steps; `prompts/review-slice.md` owns the contract; smells stay judgement calls, never hard blockers.

### Split post-implementation checks, PR creation, local QA, and review
**Date:** 2026-07-30
**Status:** Active
**Decision:** Remove per-slice review and review-fixes. After all implementation slices, run `final-checks`, `pr-creation`, `prepare-qa-checklist`, `runthrough-qa-checklist`, `multi-axis-pr-review`, and `cleanup-local-resources`. Init creates the last step with `alwaysRun: true`; the scheduler defers it behind normal work so it can still run after success or any earlier failure.
**Reasoning:** Each concern now has one auditable step and one prompt. PR creation stays free of QA/review behavior, local QA is visible and updated in one PR comment, and four specialized skills review the completed PR independently. Cleanup must cover resources and rough files from any pipeline step, including failed runs.
**Alternatives considered:** Keep the combined PR review and optional fixes (rejected: it mixes PR creation, QA planning, review, and remediation), or keep per-slice review (rejected: the requested review boundary is the completed PR).
**Consequences:** Review findings are reported but not automatically fixed. Five review passes across four skills run as two flat batches owned by the main agent: two Matt axes, then three other skills. The batch size fits Codex's live four-slot runtime while keeping every worker top-level. The runner skips normal pending steps after a failure, runs pending `alwaysRun` cleanup, and still exits non-zero with the original failure recorded, including step-limited runs.

### Declare slice dependencies as first-class blocking edges
**Date:** 2026-07-09
**Status:** Active
**Decision:** `create-and-review-slices` gives every sub-issue a `Blocked by` section and wires each edge as a native GitHub issue dependency, creating issues in dependency order. `implement-slice` checks both the native `issue_dependencies_summary.blocked_by` count and the body lines.
**Reasoning:** Adopted from mattpocock/skills v1.1.0 `to-tickets`: explicit edges make the frontier visible in GitHub's UI and open the door to parallel slice execution later. The previous rule kept blocked-by references out of sub-issues, which hid real ordering constraints.
**Alternatives considered:** Body-text references only (rejected: invisible in the UI, no machine-checkable gate), or native dependencies only (rejected: the body line is the human-readable fallback and what implement-slice checked historically).
**Consequences:** Repos without the dependencies API fall back to body lines; parallel slice implementation stays out of scope for now.

### Adopt wayfinder as a situational planning on-ramp, not the default
**Date:** 2026-07-09
**Status:** Active
**Decision:** `skills/wayfinder/` plans efforts too big for one grilling session as a map issue with child tickets on GitHub. Its destination is a decision issue that enters the pipeline through `init` unchanged; `grill-with-docs` stays the default entry for one-session features and signposts up to wayfinder.
**Reasoning:** Mirrors upstream v1.1.0, which settles wayfinder as a situational on-ramp while the grill-led chain stays the front door. Tracker operations resolve through the `Issue tracker` pointer in `AGENTS.md` to `docs/agents/issue-tracker.md`, keeping skills tracker-agnostic.
**Alternatives considered:** Replacing grill-with-docs with wayfinder (rejected: upstream explicitly declined this; most features fit one session).
**Consequences:** Target repos need the `wayfinder:*` labels created once; map sessions must respect the `grill/*` branch contract because `init`/`preflight` fail on dirty trees.

### Keep wayfinder decisions separate from Ralph implementation
**Date:** 2026-08-06
**Status:** Active
**Decision:** Wayfinder child issues are Decision Tickets whose resolution is a decision, never a Ralph implementation Slice. A cleared map hands its destination issue to `init`; `create-and-review-prd` is the `to-spec` boundary. During charting, research subagents may read in parallel, but they return findings only and the parent session serializes every file, Git, tracker, and map write.
**Reasoning:** The explicit term prevents agents from implementing map tickets. Entering at `init` preserves Ralph's existing PRD and slice pipeline without running `to-spec` twice. Parent-owned writes avoid branch and issue races when subagents share a checkout.
**Alternatives considered:** Sync upstream Wayfinder verbatim (rejected because it drops Ralph's tracker, branch, and `init` contracts), run standalone `to-spec` before `init` (rejected as duplicate PRD generation), or let research subagents mutate branches and tickets concurrently (rejected because shared worktrees and tracker updates can collide).
**Consequences:** Research reading can run concurrently when the harness supports subagents; without subagents, research Decision Tickets remain on the Frontier for fresh sessions. The parent captures each result on its `research/<name>` branch and resolves tickets sequentially.

### Ask grilling questions in frontier rounds
**Date:** 2026-08-06
**Status:** Active
**Decision:** Grilling maps a plan, decision, or idea as a design tree and asks the whole currently answerable Frontier in a numbered round. Questions with unresolved prerequisites wait for a later round. Fact-finding subagents are read-only, decisions remain with the user, and no action starts before the user's confirmation. A user request for one question at a time overrides the round cadence.
**Reasoning:** Rounds reduce conversational turns without asking dependent questions too early or weakening the facts-versus-decisions split. The fixed format lets the user answer by number.
**Alternatives considered:** Keep one question per turn (rejected as the default because independent questions needlessly serialize), or ask every known question at once (rejected because later questions would assume unresolved answers).
**Consequences:** `grilling` owns the interview cadence; wrappers such as `grill-with-docs` and Wayfinder reference it instead of defining their own loop.

### Use mex for routed agent memory
**Date:** 2026-07-09
**Status:** Active
**Decision:** Store structured agent memory in `.mex/` while keeping root `AGENTS.md` as the tool-loaded anchor and `CLAUDE.md` as a symlink to it.
**Reasoning:** mex keeps long-lived project context, patterns, and drift checks out of one giant instruction file while remaining compatible with Codex and Claude.
**Alternatives considered:** Keep only root `AGENTS.md` with all instructions (rejected because it grows into a large prompt dump), or replace Ralph docs entirely with mex (rejected because README, CONTEXT, and prompt docs remain useful user-facing docs).
**Consequences:** Agents should read `.mex/ROUTER.md` at session start and use `npx mex-agent check` to detect scaffold drift.

### Require explicit `baseBranch` before preflight
**Date:** 2026-06-07
**Status:** Active
**Decision:** `init` writes `"baseBranch": null`, and humans or agents must set it explicitly before preflight creates a feature branch.
**Reasoning:** Grilling can create speculative `CONTEXT.md` or ADR changes that should live on a pushed `grill/*` planning branch instead of silently using `main`.
**Alternatives considered:** Default to `main` (rejected because it can drop planning context), or infer the current branch (rejected because it is fragile in automation).
**Consequences:** Preflight must fail if `baseBranch` is missing; setup and run guidance must mention the branch contract.

### Default generated steps to Codex
**Date:** 2026-06-07
**Status:** Active
**Decision:** Init creates generated non-review steps with `"agent": "codex"` by default, while allowing per-step edits before execution.
**Reasoning:** Codex is the default executor in this repository's current state schema, and explicit state keeps ownership auditable.
**Alternatives considered:** Runtime agent detection (rejected because it makes state less reproducible), or Claude-only defaults (rejected because Codex support is first-class here).
**Consequences:** `scripts/agent.sh` must keep Codex working-directory behavior correct, and tests must fake Codex paths.

### Keep Ralph state as the single source of truth
**Date:** 2026-05-02
**Status:** Active
**Decision:** Pipeline progress, branch fields, step order, statuses, metrics, HITL, reviewers, and agent assignment live in `workspaces/<issue>/state.json`.
**Reasoning:** A single state file makes recovery, retry, status, and test assertions deterministic.
**Alternatives considered:** Derive progress from logs or GitHub comments (rejected because both are incomplete and harder to mutate safely).
**Consequences:** All state edits must use `jq`; failed steps stop normal work but allow pending always-run cleanup; manual recovery must validate JSON before rerun.

### Use foreground Ralph runs in Codex automation
**Date:** 2026-06-07
**Status:** Active
**Decision:** Codex automation should run long Ralph jobs in foreground and poll status/logs from another command instead of using `--background`.
**Reasoning:** The background nohup wrapper can be torn down when a tool session returns, leaving stale `in_progress` state and empty logs.
**Alternatives considered:** Always use `--background` (rejected due to stale wrapper risk), or always run in a user terminal (rejected because Codex often controls execution).
**Consequences:** Progress updates should poll `./ralph.sh status --issue N`; stale background runs require resetting step status, PID, and pid files.

### Write downstream planning output to GitHub issue bodies
**Date:** 2026-05-02
**Status:** Active
**Decision:** PRD content, slice outputs, and downstream-readable planning summaries belong in GitHub issue bodies, not comments.
**Reasoning:** `gh issue view` reads issue bodies by default, and downstream prompts rely on that content.
**Alternatives considered:** Put council output and PRD content in comments (rejected because downstream steps can miss it).
**Consequences:** Prompts must use `gh issue edit --body-file` when later steps need the content.
