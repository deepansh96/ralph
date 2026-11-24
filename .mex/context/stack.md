---
name: stack
description: Technology stack, tool choices, and version constraints for Ralph. Load when working with shell, jq, GitHub, Claude, Codex, Pi, council, or mex.
triggers:
  - "library"
  - "dependency"
  - "tool"
  - "shell"
  - "jq"
  - "gh"
  - "codex"
  - "claude"
  - "pi"
  - "deepseek"
  - "gemini"
  - "agy"
  - "council"
edges:
  - target: context/decisions.md
    condition: when the reasoning behind a tool or dependency choice is needed
  - target: context/conventions.md
    condition: when using these tools in scripts, prompts, or tests
  - target: context/setup.md
    condition: when installing or validating local command availability
  - target: patterns/change-pipeline-behavior.md
    condition: when a stack choice affects a new or changed pipeline step
last_updated: 2026-11-24
---

# Stack

## Core Technologies

- **Bash** - primary implementation language for CLI, pipeline, state helpers, logs, metrics, and tests.
- **Markdown** - prompt templates, skills, project context, ADR conventions, and mex scaffold files are plain markdown.
- **JSON** - `workspaces/<issue>/state.json`, metrics payloads, and agent/council logs use JSON or JSONL.
- **GitHub Issues and PRs** - the product surface Ralph automates; issues drive PRD, slices, implementation, and review.
- **Git** - branch contracts, clean-tree validation, project-root discovery, and push flows.

## Key Libraries

- **`jq`** - mandatory JSON mutation and validation tool; do not replace with fragile sed/awk JSON edits.
- **`gh`** - GitHub API access; prompts rely on issue body edits, issue views, sub-issue creation, and PR operations.
- **`claude` CLI** - executes Claude-owned steps; per-step model and `reasoningEffort` map to `--model` and `--effort`. The context completeness check uses the CLI selected by the first runnable step rather than requiring Claude.
- **`codex` CLI** - default step executor for generated state; run from project root in `scripts/agent.sh`, with per-step model and `reasoningEffort` mapped to `--model` and `model_reasoning_effort`.
- **`pi` CLI** - executes `deepseek` steps from the project root with `--provider deepseek`; defaults are `deepseek-v4-flash` and `high` reasoning effort, and per-step model and `reasoningEffort` map to `--model` and `--thinking`.
- **`agy` CLI** - executes `gemini` steps in print mode from the project root with `--mode accept-edits`, `--dangerously-skip-permissions`, and stream-json output; per-step model and `reasoningEffort` map to `--model` and `--effort`, and the Ralph directory is added with `--add-dir`. A step succeeds only when the stream's last result event reports `SUCCESS`.
- **Node.js** - runs the bundled isolated Codex App Server reviewer, the read-only Codex delegation evidence client, the dependency-free temporary quiz-grilling server, and private atomic delegation artifact writes (fsync and secure attempt IDs).
- **`cloudflared` or `ngrok`** - optional tunnel client for exposing a temporary quiz-grilling link; Cloudflare Quick Tunnels are preferred.
- **`council` CLI** - fan-out review runner for decision, PRD, and slice-planning workflows.
- **Shell test fakes** - tests fake `claude`, `codex`, `pi`, `agy`, `gh`, and `council`; never make deterministic tests depend on real services.

## What We Deliberately Do NOT Use

- No Python or compiled app runtime for the core pipeline; Node is limited to the bundled isolated Codex reviewer, Codex delegation evidence reads, quiz-grilling support, delegation file primitives, and mex.
- No real external services in tests; use fake commands under `tests/lib/`.
- No background mode from Codex automation; foreground Ralph plus separate status polling is safer.
- No implicit branch defaults; `.baseBranch` must be set explicitly before preflight.
- No global skill dependency; bundled skills live under `skills/`.

## Version Constraints

- `jq`, `git`, `gh`, and Node.js must be available on PATH for the full pipeline. Public quiz-grilling links additionally require `cloudflared` or `ngrok`.
- `claude`, `codex`, `pi`, `agy`, and `council` must be available only for steps or prompts that invoke them. DeepSeek steps require Pi 0.70.1+ and credentials in its auth store or `DEEPSEEK_API_KEY`.
- mex requires Node.js 20+ when using `npx mex-agent`.
