---
name: setup
description: Dev environment setup and commands for Ralph. Load when setting up the repo, running tests, or debugging local environment issues.
triggers:
  - "setup"
  - "install"
  - "environment"
  - "getting started"
  - "run tests"
  - "local development"
edges:
  - target: context/stack.md
    condition: when specific tool availability or version requirements matter
  - target: context/architecture.md
    condition: when understanding how commands move through the pipeline
  - target: patterns/run-and-monitor-pipeline.md
    condition: when starting or observing a real Ralph run
  - target: patterns/recover-failed-or-stale-step.md
    condition: when status, logs, or stale PID checks fail
last_updated: 2026-11-21
---

# Setup

## Prerequisites

- `bash` with `set -euo pipefail` compatible behavior.
- `git`, `jq`, `gh`, and `curl` on PATH.
- `gh` authenticated for the target GitHub repo.
- `claude` CLI for Claude-owned steps.
- `codex` CLI for default generated steps. The context check uses whichever CLI owns the first runnable step.
- Pi CLI 0.70.1+ and DeepSeek credentials in Pi's auth store or `DEEPSEEK_API_KEY` for DeepSeek-owned steps.
- `council` CLI for council review steps.
- Node.js 20+ for the isolated Codex review and mex.
- `cloudflared` or `ngrok` only when a quiz-grilling session needs a temporary public link.

## First-time Setup

1. Clone this repository into a target project root when using it as a project-local pipeline (`ralph/` is the convention, though the install folder name is no longer hardcoded — any directory name works and existing `ralph-v2/` installs keep working).
2. Ensure the target project root has `CONTEXT.md` and `CLAUDE.md` or `AGENTS.md` with the target project's instructions.
3. Authenticate GitHub CLI: `gh auth status`.
4. From the project root, create a GitHub issue through the grilling flow or manually.
5. Run the init prompt for the issue: `Read ralph/prompts/init.md and execute it for issue N in repo owner/repo` (adjusting `ralph/` if installed under another directory name).
6. Set `.baseBranch` in `ralph/workspaces/N/state.json` before preflight.
7. Run the pipeline from the project root: `./ralph/ralph.sh --issue N`.

For this repository's own tests and maintenance, run commands from this repository root, where the scripts are `./ralph.sh`, `./tests/run.sh`, and `./cleanup.sh`.

## Environment Variables

- `RALPH_STALE_THRESHOLD` (optional) - seconds before `state_validate` considers an `in_progress` step eligible for stale PID recovery; defaults to `3600`.
- `RALPH_RETRY_DELAYS` (optional) - retry sleep sequence for transient agent failures; defaults to `30 60 120`.
- `RALPH_POLL_INTERVAL` (optional) - seconds between `ralph.sh poll` status checks; defaults to `30`.
- `RALPH_WORKSPACES_DIR` (optional) - base directory for per-issue workspaces archived by `cleanup.sh`; falls back to legacy `RALPH_V2_WORKSPACES_DIR` when unset or empty, and otherwise defaults to `<ralph-dir>/workspaces`.

## Common Commands

- `./tests/run.sh` - run the full deterministic shell test suite.
- `./tests/run.sh agent pipeline prompt_contracts` - run focused suites.
- `./ralph.sh --issue N` - run pending steps for an initialized workspace.
- `./ralph.sh --issue N --steps 1` - run one pending step.
- `./ralph.sh status --issue N` - print step table, duration, process state, and current activity.
- `./ralph.sh logs --issue N` - show active step logs.
- `./ralph.sh logs --issue N --step step-id` - show a specific step log.
- `./cleanup.sh N` - archive `workspaces/N/` after merge.
- `npx mex-agent check --quiet` - check `.mex/` drift without installing mex globally.

## Common Issues

**Dirty tree before init or preflight:** Commit accepted docs to the intended base branch, or commit speculative grilling docs to a pushed `grill/*` branch and set `.baseBranch` to that branch.

**Long run appears frozen:** Do not pipe Ralph output. Keep the foreground command running and poll status or logs from another command.

**Stale `in_progress` step:** Check PID files under `workspaces/<issue>/pids/`, reset the affected step to `pending` with `jq`, clear stale PID fields, remove stale pid files, and rerun.

**Failed step:** Ralph first runs pending `alwaysRun` cleanup, then exits non-zero. Inspect `workspaces/<issue>/logs/<step-id>.log`, fix the root cause, set that step back to `pending`, clear metrics/notes if needed, validate with `jq`, and rerun.

**Codex branch checkout fails in submodule use:** Ensure Codex runs from the target project root; `scripts/agent.sh` already wraps Codex in `(cd "$project_root" && codex ...)`.
