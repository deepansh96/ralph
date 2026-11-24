---
name: architecture
description: How Ralph pipeline pieces connect and flow. Load when working on system design, integrations, prompt dispatch, or state behavior.
triggers:
  - "architecture"
  - "pipeline"
  - "state"
  - "prompt"
  - "agent"
  - "integration"
edges:
  - target: context/stack.md
    condition: when specific shell, jq, GitHub, Claude, Codex, Pi, DeepSeek, or council details are needed
  - target: context/decisions.md
    condition: when understanding why the pipeline, branch, review, or agent defaults exist
  - target: context/conventions.md
    condition: when editing scripts, prompts, tests, or docs in this architecture
  - target: patterns/run-and-monitor-pipeline.md
    condition: when executing or observing a live pipeline
last_updated: 2026-11-24
---

# Architecture

## System Overview

User starts with a GitHub issue -> `prompts/init.md` creates `workspaces/<issue>/state.json`, the local-resource ledger, and the always-run cleanup step -> `ralph.sh --issue N` validates state and runs the context gate with the first runnable step's execution settings -> `prompt_render` combines a step prompt with state/workspace values -> `agent_run_step` dispatches to Claude, Codex, or DeepSeek through Pi (steps with `delegation` metadata go through `delegation_gate_run_step`, which completes them only on verified delegation evidence) -> the agent edits project files, GitHub issues, PR comments, or workspace artifacts -> `state_update_step` records completion, failure, HITL, metrics, PID, and notes -> preflight appends dynamic implementation/check/PR/QA/review steps -> post-merge `cleanup.sh` archives the workspace.

The pipeline is issue-driven and state-driven. `ralph.sh` does not infer missing branch contracts once running; `state.json` decides which step runs next and which agent owns it. Repo-wide provider defaults live in `ralph.config.json`; preflight snapshots parent and worker settings onto generated delegated steps, and explicit step fields override defaults for that issue.

## Key Components

- **`ralph.sh`** - CLI entrypoint and run loop; handles `run`, `status`, `logs`, `poll`, HITL resume, foreground/background dispatch, step limits, and shutdown reset.
- **`scripts/config.sh`** - validates `ralph.config.json` and resolves one provider's complete delegated-step parent and worker defaults.
- **`scripts/delegation.sh`** - shared delegation schemas, stable ordering, private atomic JSON writes, and fresh invocation preparation; see `docs/delegation-contracts.md`. Called by the completion gate. Node supplies fsync; jq owns State transformations. Provider orchestration remains with the main agent.
- **`scripts/claude-delegation.sh`** - Claude probe adapter and sourced collector; session-local `ralph-worker` Agent definitions pin configurable worker model/effort. Five sanitized hooks correlate current-attempt lifecycle and retain model history. The parent orchestrates; the gate uses prepare/evidence/cleanup for gated Claude steps. See `docs/claude-delegation.md`.
- **`scripts/delegation-manifest.sh`** - manifest builder and `pr-review-v1` verifier; consumes collector envelopes plus State attempt/settings, emits the fixed v1 manifest with sorted mismatch codes and evidence level, and writes it privately under `workspaces/<issue>/delegation/`. Called by the gate; see `docs/delegation-manifest.md`. It also verifies `qa-v1` from facts supplied by `scripts/delegation-qa.sh`.
- **`scripts/delegation-qa.sh`** - QA plan support: parses the one documented checklist comment format into canonical `{id,text}` instructions (progress lines excluded), computes canonical checklist/assignment digests in Node, writes the parent's 0600 plan before its first spawn, and refetches the plan's exact comment for `qa-v1`. The manifest verifier accepts parent-owned sequential QA replacement runs (lower failed/stopped/incomplete runs `superseded`); see `docs/qa-delegation.md`.
- **`scripts/codex-delegation.sh`** - Codex collector; reads the exec parent from `thread.started`, then a Node client starts a fresh read-only `codex app-server`, paginates direct and descendant threads, reads turns, and prints allowlisted facts that jq normalizes into shared child records. Fails closed on unavailable or inconsistent evidence. Called by the gate after every gated Codex invocation. See `docs/codex-delegation.md`.
- **`scripts/delegation-gate.sh`** - runner completion gate for steps with `delegation` metadata: fails closed before launch on unsupported provider/metadata/settings, stamps a fresh attempt and rerenders inputs per provider invocation (existing retry limit/backoff), runs Claude with a session-local `ralph-worker`, hooks, and a known session, collects attempt-bound evidence, writes the manifest, and completes only at `OBSERVED`/`VERIFIED`. Blocked runs write no manifest. The opt-in live smoke tests `tests/probes/claude-gate-smoke.sh` and `tests/probes/codex-gate-smoke.sh` prove the real Claude and Codex paths end to end. See `docs/delegation-gate.md`.
- **`scripts/state.sh`** - state access and mutation layer; validates failed/stale steps, selects pending or blocked steps, defers `alwaysRun` cleanup behind normal work while prioritizing it after failure, rearms completed cleanup when normal work is retried, appends dynamic steps, snapshots missing delegated-step defaults without overwriting explicit values, backfills delegation metadata on pending steps only, and writes PID files.
- **`scripts/agent.sh`** - execution adapter for `claude`, `codex`, `deepseek`, and `gemini`; maps optional per-step model and `reasoningEffort` overrides to Claude, Codex, Pi, or agy CLI flags, exposes single-invocation Claude/Codex command builders shared with the gate, then wraps retries, logging, working directory handling, and metrics extraction.
- **`scripts/prompt.sh`** - renders prompt templates by replacing `{{ISSUE}}`, `{{REPO}}`, `{{WORKSPACE}}`, `{{BRANCH}}`, `{{BASE_BRANCH}}`, `{{STEP_ID}}`, `{{SUB_ISSUE}}`, `{{SKILLS_DIR}}`, `{{REVIEWERS}}`, `{{AGENT}}`, and `{{RALPH_DIR}}`. Templates that request `{{NATIVE_DELEGATION_CONTRACT}}` receive the matching reusable Claude or Codex prompt fragment; Claude selects foreground Agent instructions only when delegation metadata is present, retaining Workflow for legacy steps. Worker model and effort resolve from per-step `subagentModel` / `subagentReasoningEffort` overrides, then `ralph.config.json` provider defaults; rendering fails when the provider or required settings are missing.
- **`ralph.config.json`** - repo-wide defaults for delegated parent and worker execution. Codex parents default to Sol/medium with Luna/max workers; Claude parents default to Opus/medium with Sonnet/high workers. Preflight snapshots these settings into new delegated steps; individual state steps may override them.
- **`prompts/`** - one markdown contract per step type; downstream agents initialize workspaces, plan, implement, check, create the PR, prepare/run local QA, consolidate five review passes across four skills, and clean local resources. QA and PR review leave flat worker orchestration to their main agent while the provider fragment pins supported worker settings. Preflight backfills missing cleanup artifacts for older initialized workspaces.
- **`skills/`** - bundled task guidance includes planning/TDD/domain skills plus `matt-pocock-code-review`, `ponytail-review`, `run-codex-review`, and `supe-review-code-changes`; grilling asks dependency-ordered question rounds; `quiz-grilling` can present those rounds through a disposable local web app and temporary tunnel; Wayfinder uses decision tickets and may fan out read-only research subagents while the parent owns all writes; `writing-for-agents`, `codebase-design`, `improve-codebase-architecture`, `prototype`, `wizard`, and `wait-what` are optional support outside the fixed pipeline. Prompt references stay inside the repository. Tracker operations live in `docs/agents/issue-tracker.md`, referenced from `AGENTS.md`.
- **`scripts/grill.sh`** - Automated Grilling Session coordinator behind `ralph.sh grill` (`start`, `resume`, `status`, `logs`, `cleanup`), dispatched before the `--issue` parser. `start` and `resume` run under a supervisor child so INT/TERM stop the Agent call's process tree at once. `start` validates inputs, checks adapter capabilities, enforces branch safety in the target repository (Git toplevel above the Ralph directory; the default branch comes from `origin/HEAD` or the remote's HEAD, never a guess), writes the Grilling Session Record, starts the Grilling then Answering native sessions with distinct IDs, then runs the relay loop (Frontier → Answers → merged `decisions` → next Frontier; on an empty Frontier, summary draft → one review → summary final) and writes `confirmation.md` at the `blocked/awaiting_confirmation` gate. Blocks (`needs_human`, `no_progress`, `invalid_message`, `transient_failure`) keep both native sessions. Exchanges are sequential (`ex-NNNN`), recorded `intent` → `sent` → `completed`, and validated with jq after null members are dropped; answers exchanges are marked `effectsApplied` so a crash never loses merged decisions or a block. At the gate, `approve` rechecks the branch and flags, then commits only `CONTEXT.md`/`docs/adr/`, pushes, and edits or creates the issue (a session marker in the body prevents duplicate creates); `reject` discards only those docs. It is the only component that writes the record or runs Git/`gh` writes for grilling.
- **`scripts/grill-record.sh`** - Grilling Session Record store at `grilling-sessions/<id>/session.json`; jq-only atomic write-then-rename under umask 077 (dirs `0700`, files `0600`). The session lock is a `lock` symlink naming the owner PID, reclaimed from a dead owner only under a `lock.reclaim` guard. Separate from pipeline State.
- **`scripts/grill-adapters.sh`** - session-adapter contract (`adapter_capabilities`, `adapter_new_native_id`, `adapter_start`, `adapter_send`, `adapter_exchange_received`) with Claude and Codex implementations. Claude: coordinator-generated `--session-id`, `--resume <id>` with a `--json-schema` hint for every later exchange (never `--continue`/`--last`/`--fork-session`), `acceptEdits` in the repo for the Grilling Agent, `default` mode with write tools disallowed for the Answering Agent, and sandboxed Bash limited to GitHub domains with Git/`gh` writes denied. Codex: thread ID from `thread.started`, `exec resume <id>` with a strict `--output-schema`, `workspace-write` for the Grilling Agent and a network-enabled read-only permission profile (no `--sandbox`) for the Answering Agent, probed with `codex debug prompt-input`. Transient failures are retried in the same session; exhausting retries returns a distinct status that blocks the session.
- **`prompts/grill/`** - Grilling Agent and Answering Agent role prompts plus per-exchange fragments (session start, round, closing, human input, correction, re-emit, recover) carrying `[ralph-exchange:<id>]`, and strict message JSON Schemas in `prompts/grill/schemas/` (every property required, unused ones null, no `$schema` key).
- **`tests/`** - deterministic shell suite with shared fakes for external tools; validates behavior without real GitHub, Claude, Codex, Pi, or council calls.

## External Dependencies

- **GitHub CLI (`gh`)** - required by init and agent prompts to read/edit issues, create sub-issues, push branches, and create/update PRs.
- **Claude CLI (`claude`)** - used by steps whose `agent` is `claude`; emits stream JSON logs consumed for metrics. The context gate uses it only when the first runnable step is Claude-owned.
- **Codex CLI (`codex`)** - default generated step agent; `scripts/agent.sh` runs it from the project root with danger-full-access sandbox and JSON logging.
- **Pi CLI (`pi`)** - runs steps whose `agent` is `deepseek`; `scripts/agent.sh` selects the DeepSeek provider and consumes Pi's JSON event stream.
- **Antigravity CLI (`agy`)** - runs steps whose `agent` is `gemini`; `scripts/agent.sh` runs it in print mode from the project root and consumes its stream-json events for the result, metrics, and status activity.
- **Council CLI (`council`)** - multi-agent review harness used by review prompts and `scripts/council-review.sh`.
- **Cloudflare Quick Tunnels or ngrok** - optionally expose a quiz-grilling session's loopback server to another device; the session records and cleans up the tunnel process.
- **Git** - branch creation, status checks, pushes, and project-root discovery underpin preflight and agent working directories.
- **`jq`** - required for all state manipulation, prompt rendering fields, status tables, and JSON validation.
- **mex (`npx mex-agent`)** - repository memory scaffold under `.mex/`; use `npx mex-agent check` and `npx mex-agent sync` unless mex is installed globally.

## What Does NOT Exist Here

- No deployed web service, database, daemon, or long-running server lives in this repo; `quiz-grilling` starts only a session-owned temporary local server.
- No package manager build step is needed for Ralph itself.
- No runtime persistence outside Git, GitHub, per-issue workspaces, logs, and `.mex/events`.
- No automatic recovery for failed work; Ralph runs pending `alwaysRun` cleanup and then a human or agent must reset the failed step intentionally.
- No safe default `baseBranch`; init writes it as `null` and preflight requires an explicit value.
