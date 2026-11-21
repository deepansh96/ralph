---
name: agents
description: Always-loaded project anchor for Ralph. Read this first, then load ROUTER.md for task-specific context.
last_updated: 2026-07-09
---

# Ralph

## What This Is
Ralph is a shell-based GitHub issue pipeline that grills, plans, implements, reviews, and opens a PR for one feature.

## Non-Negotiables
- Run Ralph commands from the project root, not from inside `ralph/`.
- Never pipe `ralph.sh --issue N` through `head`, `tail`, or similar commands.
- Treat `workspaces/<issue>/state.json` as the single source of truth for pipeline progress.
- Keep `baseBranch` explicit before preflight; use a pushed `grill/*` branch for speculative planning docs.
- Do not revert user or generated workspace changes unless explicitly asked.

## Commands
- Test: `./tests/run.sh`
- Focused tests: `./tests/run.sh agent pipeline prompt_contracts`
- Run pipeline: `./ralph.sh --issue N`
- Status: `./ralph.sh status --issue N`
- Logs: `./ralph.sh logs --issue N --step step-id`
- Cleanup: `./cleanup.sh N`

## Scaffold Growth
After meaningful work, run GROW:
- Ground: what changed in reality?
- Record: update `ROUTER.md` and relevant `context/` files.
- Orient: create or update a `patterns/` runbook if this can recur.
- Write: bump `last_updated` on changed scaffold files and run `mex log` when rationale matters.

The scaffold grows from real work, not just setup. See the GROW step in `ROUTER.md`.

## Navigation
At the start of every session, read `ROUTER.md` before doing anything else. Then load only the context and patterns that match the task.
