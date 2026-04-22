# Ralph

Autonomous AI agent loop that implements features story-by-story from a PRD.

Ralph runs a coding agent ([Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex)) in a loop. Each iteration picks one user story from a PRD, implements it completely (code + tests + commit), and stops. The loop continues until every story passes or the iteration limit is reached.

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐
│  prd.json   │────>│  ralph.sh    │────>│  Claude / Codex  │
│  (stories)  │     │  (loop)      │     │  (1 story)       │
└─────────────┘     └──────┬───────┘     └──────┬───────────┘
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

- At least one agent CLI:
  - [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command)
  - [Codex CLI](https://github.com/openai/codex) (`codex` command) — requires `codex exec`, `--json`, `--output-last-message`, `--sandbox workspace-write`
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

## Usage

### 1. Create a PRD

Tag the prompt file and ask Claude to create a PRD for your feature:

```
@ralph/prompts/prd-creator.md create a prd for [describe your feature]
```

### 2. Convert to prd.json

Tag the converter prompt and point it at your PRD:

```
@ralph/prompts/prd-to-json.md convert this prd
```

Both steps create a workspace folder at `ralph/workspaces/[feature-name]/` containing the PRD files.

### 3. Run Ralph

```bash
# From your project root
./ralph/ralph.sh --prd <name> [--agent auto|claude|codex] [max_iterations] [prompt_file] [--context <path>...]

# Examples
./ralph/ralph.sh --prd my-feature                                       # 10 iterations, auto-detect agent
./ralph/ralph.sh --prd my-feature 15                                    # 15 iterations
./ralph/ralph.sh --prd my-feature 15 --agent codex                      # Use Codex CLI
./ralph/ralph.sh --prd my-feature 15 --agent claude                     # Use Claude Code
./ralph/ralph.sh --prd my-feature 15 --context docs/architecture.md     # With context file
./ralph/ralph.sh --prd my-feature 15 --context docs/ --context CLAUDE.md  # Multiple context sources
./ralph/ralph.sh --prd my-feature 15 --no-multi-agent                   # Disable Codex sub-agent spawning
```

- `--prd` is required — identifies the workspace at `ralph/workspaces/<name>/`
- `--agent` selects the backend: `auto` (default, prefers Claude), `claude`, or `codex`
- `--context` is repeatable — files are listed in the prompt for the agent to read at the start of each iteration. Directories are recursively expanded.
- `--no-multi-agent` disables Codex's `--enable multi_agent` flag (on by default)

### Agent Differences

| Aspect | Claude Code | Codex CLI |
|--------|------------|-----------|
| Cost tracking | Per-iteration USD cost | Not available (shows "n/a") |
| API duration | Available | Not available (shows "n/a") |
| Context window % | Displayed | Not available (shows "n/a") |
| Prompt delivery | `-p` flag | Piped via stdin |
| Output format | Single JSON object | JSONL event stream |

`CLAUDE.md` is a project convention file read by both agents — it is not specific to Claude Code.

### 4. Monitor Progress

Ralph prints a diagnostics table after each iteration:

```
┌──────────────────────────────────────────────────┐
│  ITERATION 3  DIAGNOSTICS (claude)               │
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
./ralph/cleanup.sh my-feature
```

This moves the entire workspace `ralph/workspaces/my-feature/` to `ralph/archive/{date}-my-feature/`.

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

The agent prompt (`prompts/agent.md`) tells the agent to follow whatever quality checks your `CLAUDE.md` defines. No need to modify ralph's files.

### Custom Prompt

For project-specific agent behavior, create your own prompt and pass it as an argument:

```bash
./ralph/ralph.sh --prd my-feature 10 ./my-ralph-prompt.md
```

The default `prompts/agent.md` works for most projects out of the box.

## File Structure

**Shipped with ralph (tracked by git):**
```
ralph/
├── ralph.sh              # Main loop script
├── cleanup.sh            # Archive completed runs
├── prompts/
│   ├── agent.md          # Default agent prompt
│   ├── prd-creator.md    # PRD creation instructions (tag with @)
│   └── prd-to-json.md    # PRD-to-JSON conversion instructions (tag with @)
├── test_prompt.md        # Test prompt
├── CLAUDE.md             # Dev reference
└── README.md             # This file
```

**Created during execution (gitignored):**
```
ralph/
├── workspaces/                    # Active feature workspaces
│   └── my-feature/                # One folder per PRD
│       ├── prd.json               # Feature PRD
│       ├── prd-my-feature.md      # PRD markdown
│       ├── progress.txt           # Iteration progress log
│       ├── runs/                  # Per-iteration metrics
│       │   └── {timestamp}/
│       │       ├── iteration_001.json
│       │       └── summary.json
│       └── ralph_runs_cumulative.json
└── archive/                       # Completed features
    └── {date}-my-feature/         # Archived workspace
        └── (same contents)
```

## Key Design Decisions

- **Agent-agnostic**: Works with Claude Code or Codex CLI. Auto-detection prefers Claude when both are available.
- **One story per iteration**: Prevents context overflow. Each iteration starts fresh with no memory of previous work.
- **Per-PRD workspaces**: Each feature gets its own folder at `ralph/workspaces/<name>/`. All state (prd.json, progress.txt, metrics) is isolated. Archive moves the whole folder.
- **Progress persistence**: `progress.txt` carries learnings between iterations within a workspace.
- **Quality gates from CLAUDE.md**: The agent prompt is project-agnostic. Project-specific quality checks live in the host project's `CLAUDE.md`.
- **Context via `--context` flag**: Pass architecture docs, feature plans, or entire directories as context. Paths are listed in the prompt; the agent reads them at runtime. Like pral's `--context` flag.
- **Metrics tracking**: Every iteration records duration, token usage, and cost as JSON for analysis. Metrics unavailable from a given agent (e.g., Codex cost) are stored as `null` and displayed as "n/a".

## Companion Tool: PRAL

[PRAL](https://github.com/deepansh96/pral) (Plan Refine Agent Loop) iteratively refines plan documents before implementation. Use PRAL to refine your plan, then Ralph to execute it.

```
PRAL (refine plan) → PRD → Ralph (implement features)
```
