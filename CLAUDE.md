# Ralph

Autonomous AI agent loop for iterative feature implementation.

## About

Ralph orchestrates Claude Code in a loop to implement features story-by-story from a PRD (Product Requirements Document). Each iteration picks one user story, implements it, runs quality checks, commits, and stops. The loop continues until all stories pass.

## Structure

```
ralph/
├── ralph.sh              # Main loop script (~330 lines bash)
├── cleanup.sh            # Archive completed runs
├── prompts/
│   ├── agent.md          # Default agent prompt (project-agnostic)
│   ├── prd-creator.md    # Instructions for creating a PRD
│   └── prd-to-json.md    # Instructions for converting PRD to prd.json
├── test_prompt.md        # Test/debug prompt
├── CLAUDE.md             # This file
├── README.md             # User documentation
└── .gitignore            # Ignores runtime artifacts
```

## Key Mechanisms

| Mechanism | How It Works |
|-----------|-------------|
| **Iteration loop** | `ralph.sh` runs the selected agent (claude or codex) up to N times |
| **Agent selection** | `--agent auto\|claude\|codex` chooses backend; auto prefers claude |
| **Per-PRD workspaces** | `--prd <name>` creates isolated folder at `workspaces/<name>/` |
| **Context injection** | `--context` flag lists file paths in the prompt via `{{CONTEXT_SECTION}}` |
| **Prompt placeholders** | `{{WORKSPACE}}` and `{{CONTEXT_SECTION}}` are substituted at runtime |
| **One story per iteration** | Prompt enforces picking ONE story, implementing it, then stopping |
| **Completion signal** | Agent emits `<promise>COMPLETE</promise>` when all stories pass |
| **Branch tracking** | `.last-branch` file detects branch changes and auto-archives |
| **Metrics** | Per-iteration JSON files with duration, tokens, cost |
| **Cumulative stats** | `ralph_runs_cumulative.json` aggregates across runs |
| **Archival** | `cleanup.sh <name>` moves workspace to `archive/{date}-{name}/` |

## Commands

```bash
# Run ralph (from the project root, not ralph/)
./ralph/ralph.sh --prd my-feature 15                                # 15 iterations (auto-detect agent)
./ralph/ralph.sh --prd my-feature 15 --agent claude                 # Force Claude Code
./ralph/ralph.sh --prd my-feature 15 --agent codex                  # Force Codex CLI
./ralph/ralph.sh --prd my-feature 15 --agent auto                   # Auto-detect (default)
./ralph/ralph.sh --prd my-feature 15 --context docs/architecture.md # With context
./ralph/ralph.sh --prd my-feature 15 --context docs/ --context CLAUDE.md

# Archive completed feature
./ralph/cleanup.sh my-feature

# Test the setup
./ralph/ralph.sh --prd test 1 ./ralph/test_prompt.md
```

## Editing Prompts

- `prompts/agent.md` is the default agent prompt — project-agnostic
- Quality checks come from the host project's `CLAUDE.md`, not from the prompt
- To customize the prompt for a project, pass a custom prompt file as the second argument

## Runtime Files (gitignored)

These are created during execution and ignored by git:
- `workspaces/<name>/` — per-feature workspace (prd.json, progress.txt, runs/, etc.)
- `archive/` — completed feature archives
