# Ralph

Autonomous AI agent loop that implements features story-by-story from a PRD.

Ralph runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a loop. Each iteration picks one user story from a PRD, implements it completely (code + tests + commit), and stops. The loop continues until every story passes or the iteration limit is reached.

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  prd.json   │────>│  ralph.sh    │────>│  Claude Code │
│  (stories)  │     │  (loop)      │     │  (1 story)   │
└─────────────┘     └──────┬───────┘     └──────┬───────┘
                           │                     │
                    ┌──────▼───────┐     ┌──────▼───────┐
                    │  metrics/    │     │  commit +    │
                    │  diagnostics │     │  update PRD  │
                    └──────────────┘     └──────────────┘
```

**The 4-step pipeline (per iteration):**

| Step | What happens |
|------|-------------|
| 1. Read | Agent reads `prd.json`, `progress.txt`, project's `CLAUDE.md` |
| 2. Implement | Picks highest-priority story with `passes: false`, implements it |
| 3. Verify | Runs quality checks (build, test, lint) from project's `CLAUDE.md` |
| 4. Commit | Commits code, marks story as `passes: true`, logs progress, stops |

Ralph repeats this until all stories pass (`<promise>COMPLETE</promise>`) or max iterations are reached.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command available)
- `jq` (JSON processor)
- `bc` (calculator, usually pre-installed)

## Setup

### Option 1: Git Submodule (recommended)

```bash
cd your-project
git submodule add https://github.com/deepansh96/ralph.git ralph
chmod +x ralph/ralph.sh ralph/cleanup.sh
```

### Option 2: Clone directly

```bash
cd your-project
git clone https://github.com/deepansh96/ralph.git ralph
chmod +x ralph/ralph.sh ralph/cleanup.sh
```

### Install Skills (optional)

Ralph includes two Claude Code skills for PRD creation. To make them available in your project:

```bash
# Symlink skills to your project's .claude/commands/
mkdir -p .claude/commands
ln -s ../../ralph/skills/prd-creator.md .claude/commands/prd-creator.md
ln -s ../../ralph/skills/prd-to-json.md .claude/commands/prd-to-json.md
```

Or they may be auto-discovered by Claude Code from the `ralph/skills/` directory.

## Usage

### 1. Create a PRD

Write a PRD or use the included skill:

```
/prd-creator    # Interactive PRD generation with clarifying questions
```

### 2. Convert to prd.json

```
/prd-to-json    # Converts PRD markdown to ralph/prd.json
```

Or create `ralph/prd.json` manually:

```json
{
  "project": "MyApp",
  "branchName": "ralph/my-feature",
  "description": "Feature description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add database schema",
      "description": "As a developer, I need the schema for this feature.",
      "acceptanceCriteria": [
        "Migration runs successfully",
        "Unit tests pass"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

### 3. Run Ralph

```bash
# From your project root
./ralph/ralph.sh [max_iterations] [prompt_file]

# Examples
./ralph/ralph.sh              # 10 iterations (default), default prompt
./ralph/ralph.sh 15           # 15 iterations, default prompt
./ralph/ralph.sh 10 ./my-prompt.md  # Custom prompt file
```

### 4. Monitor Progress

Ralph prints a diagnostics table after each iteration:

```
┌──────────────────────────────────────────────────┐
│  ITERATION 3  DIAGNOSTICS                        │
├──────────────────────────────────────────────────┤
│  ⏱  Time:   3m 42s     API: 3m 12s              │
│  🔄 Turns:  47                                   │
├──────────────────────────────────────────────────┤
│  📥 Input:        1842 tokens                    │
│  📤 Output:      12847 tokens                    │
│  💾 Cache read:  847291 tokens                   │
│  📝 Cache new:   42918 tokens                    │
├──────────────────────────────────────────────────┤
│  📈 Context:     ~27.9% of 200k                  │
│  💰 Cost:        $1.8472                         │
└──────────────────────────────────────────────────┘
```

### 5. Archive Completed Work

After a feature is done:

```bash
./ralph/cleanup.sh
```

This moves all runtime files to `ralph/archive/{date}-{feature}/` and creates a fresh `progress.txt` with preserved codebase patterns.

## Customization

### Quality Checks

Ralph reads quality check commands from your project's `CLAUDE.md`. Add a section like:

```markdown
## Quality Checks

### Before Every Commit
- Frontend: `npm run build` (primary gate), `npm run lint`
- Backend: `pytest tests/ -v`
- E2E: `./run_tests.sh [spec-file]`
```

The agent prompt (`prompts/agent.md`) tells Claude to follow whatever quality checks your `CLAUDE.md` defines. No need to modify ralph's files.

### Custom Prompt

For project-specific agent behavior, create your own prompt and pass it as an argument:

```bash
./ralph/ralph.sh 10 ./my-ralph-prompt.md
```

The default `prompts/agent.md` works for most projects out of the box.

## File Structure

**Shipped with ralph (tracked by git):**
```
ralph/
├── ralph.sh              # Main loop script
├── cleanup.sh            # Archive completed runs
├── prompts/agent.md      # Default agent prompt
├── skills/               # Claude Code skills
│   ├── prd-creator.md
│   └── prd-to-json.md
├── test_prompt.md        # Test prompt
├── CLAUDE.md             # Dev reference
└── README.md             # This file
```

**Created during execution (gitignored):**
```
ralph/
├── prd.json              # Current feature PRD
├── prd-*.md              # PRD markdown files
├── progress.txt          # Iteration progress log
├── .last-branch          # Branch tracking
├── runs/                 # Per-iteration metrics
│   └── {timestamp}/
│       ├── iteration_001.json
│       ├── iteration_002.json
│       └── summary.json
├── ralph_runs_cumulative.json  # Cross-run totals
└── archive/              # Completed features
    └── {date}-{feature}/
        ├── prd.json
        ├── progress.txt
        └── runs/
```

## Key Design Decisions

- **One story per iteration**: Prevents context overflow. Each iteration starts fresh with no memory of previous work.
- **Progress persistence**: `progress.txt` carries learnings between iterations. Codebase Patterns section survives cleanup.
- **Quality gates from CLAUDE.md**: The agent prompt is project-agnostic. Project-specific quality checks live in the host project's `CLAUDE.md`.
- **Branch tracking**: Auto-archives when PRD branch changes, preventing stale state.
- **Metrics tracking**: Every iteration records duration, token usage, and cost as JSON for analysis.

## Companion Tool: PRAL

[PRAL](https://github.com/deepansh96/pral) (Plan Refine Agent Loop) iteratively refines plan documents before implementation. Use PRAL to refine your plan, then Ralph to execute it.

```
PRAL (refine plan) → PRD → Ralph (implement features)
```
