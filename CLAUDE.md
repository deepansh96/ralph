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
| **Iteration loop** | `ralph.sh` runs `claude -p <prompt> --output-format json` up to N times |
| **One story per iteration** | Prompt enforces picking ONE story, implementing it, then stopping |
| **Completion signal** | Agent emits `<promise>COMPLETE</promise>` when all stories pass |
| **Branch tracking** | `.last-branch` file detects branch changes and auto-archives |
| **Metrics** | Per-iteration JSON files with duration, tokens, cost |
| **Cumulative stats** | `ralph_runs_cumulative.json` aggregates across runs |
| **Archival** | `cleanup.sh` moves completed work to `archive/{date}-{feature}/` |
| **Pattern persistence** | `progress.txt` Codebase Patterns section survives cleanup |

## Commands

```bash
# Run ralph (from the project root, not ralph/)
./ralph/ralph.sh 15                          # 15 iterations, default prompt
./ralph/ralph.sh 10 ./my-custom-prompt.md    # Custom prompt

# Archive completed feature
./ralph/cleanup.sh

# Test the setup
./ralph/ralph.sh 1 ./ralph/test_prompt.md
```

## Editing Prompts

- `prompts/agent.md` is the default agent prompt — project-agnostic
- Quality checks come from the host project's `CLAUDE.md`, not from the prompt
- To customize the prompt for a project, pass a custom prompt file as the second argument

## Runtime Files (gitignored)

These are created during execution and ignored by git:
- `prd.json` — current feature PRD
- `prd-*.md` — PRD markdown files
- `progress.txt` — iteration progress log
- `runs/` — per-iteration metrics
- `archive/` — completed feature archives
- `.last-branch` — branch tracking
