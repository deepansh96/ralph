---
name: router
description: Session bootstrap and navigation hub for Ralph. Read at the start of every session before any task.
edges:
  - target: context/architecture.md
    condition: when working on pipeline flow, prompt dispatch, state transitions, or integrations
  - target: context/stack.md
    condition: when working with shell, jq, gh, claude, codex, pi, deepseek, council, or mex tooling
  - target: context/conventions.md
    condition: when editing code, prompts, tests, or repository instructions
  - target: context/decisions.md
    condition: when changing pipeline policy, agent defaults, branch contracts, or review behavior
  - target: context/setup.md
    condition: when setting up the repo, running tests, or debugging environment issues
  - target: patterns/INDEX.md
    condition: when starting a concrete task, especially init, run, recovery, or pipeline changes
last_updated: 2026-09-27
---

# Session Bootstrap

If you have not already read `AGENTS.md`, read it now. It contains the compact project identity, non-negotiables, and commands.

Then read this file fully before doing anything else in this session.

## Current Project State

**Working:**
- Core CLI entrypoint `ralph.sh` supports `run`, `status`, `logs`, and `poll` for issue workspaces. Its pre-run `CONTEXT.md` completeness check inherits the first runnable step's agent, model, and reasoning effort.
- `ralph.sh grill start|resume|status|logs|cleanup` runs opt-in Automated Grilling Sessions (`scripts/grill.sh`): a Grilling Agent and an Answering Agent in persistent native Claude sessions or Codex threads, relayed by a deterministic coordinator through strict JSON messages to a human confirmation gate, then approve (commit `CONTEXT.md`/`docs/adr/`, push, create or edit the issue) or reject. Verified end to end against real `codex` and `claude`.
- Pipeline state lives in `workspaces/<issue>/state.json` with fixed steps, dynamic steps, per-step main-agent and subagent model/reasoning snapshots and overrides, metrics, HITL flags, and stale PID recovery. Repo-wide parent and worker defaults live in `ralph.config.json`.
- Prompt templates in `prompts/` render step-specific instructions and dispatch through `scripts/agent.sh` to Claude, Codex, or DeepSeek through Pi. QA execution and multi-axis review inject the same reusable provider-native worker contract for Claude or Codex, with model and effort resolved from step snapshots then Ralph config, while leaving flat spawning and coordination to the main agent. Init installs always-run local-resource cleanup; preflight appends implementation steps followed by final checks, PR creation, local QA preparation/execution, and five-pass PR review, then snapshots the delegated steps' parent and worker settings.
- Bundled skills in `skills/` provide spec/ticket planning, TDD, domain modeling, dependency-ordered grilling rounds, disposable browser quiz grilling, wayfinder decision tickets with parent-owned research fan-out, agent-document writing, deep-module architecture analysis, optional support for prototypes, manual setup, and clearer explanations, plus five PR review passes across four bundled skills without depending on global skill installs. Slices carry first-class blocking edges (native GitHub issue dependencies plus `Blocked by` body lines). Tracker operations live in `docs/agents/issue-tracker.md` behind the `Issue tracker` pointer in `AGENTS.md`.
- Deterministic shell tests under `tests/suites/` fake external tools and cover CLI, state, prompts, agents, council, polling, cleanup, and docs.
- mex scaffold is installed under `.mex/`; `CLAUDE.md` is a symlink to root `AGENTS.md`.

- Claude collection uses session-local foreground Agent definitions, sanitized hooks and strict current-attempt lifecycle correlation. The live two-packet probe passed on Claude 2.1.263; see `docs/claude-delegation.md`. Ungated steps keep the Workflow path.
- Codex collection reads a finished exec parent's direct children and descendants through a fresh read-only App Server process (thread listing by parent and ancestor, thread reads with turns) and normalizes lifecycle, nesting, and `task_name` identity into the shared child records; see `docs/codex-delegation.md`.
- Delegation contract helpers validate v1 metadata, child records, manifests and QA plans; prepare isolated invocation attempts; and atomically write private JSON. See `docs/delegation-contracts.md`.
- The manifest verifier (`scripts/delegation-manifest.sh`) maps either collector envelope onto one manifest, verifies `pr-review-v1` (five exact flat run-1 workers, closed mismatch codes, worker-only settings comparison with Claude family-alias rules), reports `UNVERIFIED`/`OBSERVED`/`VERIFIED`, and writes `workspaces/<issue>/delegation/<step-id>.manifest.json`. The PR-review prompt now requires the exact task IDs and packet markers. See `docs/delegation-manifest.md`. `qa-v1` now verifies the immutable QA plan, stable checklist instructions, and one selected worker per assignment with parent-owned sequential replacement runs, proven non-overlapping by per-child `startedAt`/`endedAt` lifecycle marks (Claude hook-log order, Codex turn epoch seconds) (`docs/qa-delegation.md`).
- The delegation completion gate (`scripts/delegation-gate.sh`) is active: preflight writes/backfills `qa-v1` and `pr-review-v1` metadata on pending QA/review steps; the runner stamps a fresh attempt and rerenders inputs before every provider invocation (including internal retries and HITL resumes), collects Claude hook or Codex App Server evidence for that attempt, writes the 0600 manifest, and completes only at `OBSERVED`/`VERIFIED`. Blocked runs write no manifest; unsupported providers/policies, missing settings, and write failures fail closed. Steps without metadata are unchanged. The opt-in live Claude and Codex smoke tests (`tests/probes/claude-gate-smoke.sh`, `tests/probes/codex-gate-smoke.sh`, excluded from `./tests/run.sh`) each run one real gated `qa-v1` step through `ralph.sh` against a disposable project and local `gh` stub. `ralph status` prints one manifest-only `Delegation:` line (level plus selected and expected counts) for terminal gated steps, plus safe `[delegation] child started` and `child completed` activity for in-progress ones. See `docs/delegation-gate.md`.

**Not Built:**
- No package manager wrapper or compiled artifact; this is a shell and markdown repository.
- No automated release process is documented beyond pushing commits and running the test suite.
- No first-class support for execution agents other than `claude`, `codex`, and `deepseek` in `scripts/agent.sh`.
- No persistent background supervisor; Codex automation should run long Ralph jobs in foreground and poll separately.

**Known Issues:**
- `mex setup` detects this repo as fresh because the scanner counts source extensions and ignores shell-heavy projects.
- Long-running Ralph commands can appear hung or deadlock if piped through stream consumers.
- Killing only `ralph.sh` can leave a Claude, Codex, or Pi subprocess orphaned and the step stuck `in_progress`.
- Preflight fails on any dirty working tree, including uncommitted grilling docs.

## Routing Table

Load the relevant file based on the current task. Always load `context/architecture.md` first if not already in context this session.

| Task type | Load |
|-----------|------|
| Understanding pipeline flow or state | `context/architecture.md` |
| Working with shell, jq, gh, claude, codex, pi, deepseek, council, or mex | `context/stack.md` |
| Editing scripts, prompts, tests, or docs | `context/conventions.md` |
| Changing branch, review, agent, or HITL policy | `context/decisions.md` |
| Setting up the repo or running checks | `context/setup.md` |
| Initializing an issue workspace | `patterns/initialize-issue-workspace.md` |
| Running or monitoring Ralph | `patterns/run-and-monitor-pipeline.md` |
| Recovering failed or stale steps | `patterns/recover-failed-or-stale-step.md` |
| Adding or changing pipeline behavior | `patterns/change-pipeline-behavior.md` |
| Any specific task | Check `patterns/INDEX.md` for a matching pattern |

## Behavioural Contract

For every task, follow this loop:

1. **CONTEXT** - Load the relevant context file(s) from the routing table above. Check `patterns/INDEX.md` for a matching pattern. If one exists, follow it.
2. **BUILD** - Do the work. If a pattern exists, follow its Steps. If you must deviate from an established pattern, state the deviation and why before writing code.
3. **VERIFY** - Load `context/conventions.md` and run the Verify Checklist item by item. State each item and whether the output passes.
4. **DEBUG** - If verification fails or something breaks, check `patterns/INDEX.md` for a debug pattern. Follow it, fix the issue, and re-run VERIFY.
5. **GROW** - After meaningful work, run this binary checklist:
   - **Ground:** What changed in reality? Name the changed behavior, system, command, dependency, or workflow.
   - **Record:** If project state changed, update this "Current Project State" section. If documented facts changed, update the relevant `context/` file surgically.
   - **Orient:** If this task can recur and no pattern exists, create one in `patterns/` using `patterns/README.md`, then add it to `patterns/INDEX.md`. If a pattern exists but you learned a gotcha, update it.
   - **Write:** Bump `last_updated` in every scaffold file you changed. If the why matters, run `npx mex-agent log --type decision "<what changed and why>"` or `npx mex-agent log "<note>"`.
