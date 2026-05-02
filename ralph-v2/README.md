# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline for planning, implementing, reviewing, and opening a PR for one feature. It stores progress in a per-issue `state.json` file and runs each step with the agent assigned in that state.

## CLI

Run commands from the repository root:

```bash
./ralph-v2/ralph.sh --issue N
./ralph-v2/ralph.sh status --issue N
./ralph-v2/ralph.sh logs --issue N
./ralph-v2/ralph.sh logs --issue N --step <step-id>
./ralph-v2/cleanup.sh <issue-number>
```

- `ralph.sh --issue N` validates state and context, then runs pending steps until the pipeline finishes, fails, or blocks for human input.
- `ralph.sh status --issue N` prints a step table with step ID, type, agent, status, duration, and cost.
- `ralph.sh logs --issue N` tails the active step log. Use `--step <step-id>` to read a specific step.
- `cleanup.sh <issue-number>` archives `workspaces/<issue-number>/` into `archive/<date>-<issue-number>/`.

## Workflow

1. Grill the feature into a GitHub issue using the project context and decision workflow.
2. Run the `init.md` prompt for that issue so an agent creates `ralph-v2/workspaces/<issue>/state.json`.
3. Set `.baseBranch` explicitly in `state.json` before preflight reaches branch creation.
4. Run `./ralph-v2/ralph.sh --issue N`.
5. If a step blocks, answer the questions in `workspaces/<issue>/hitl-<step-id>.md`, then run the same command again.
6. After the PR workflow completes, run `./ralph-v2/cleanup.sh <issue-number>`.

The fixed flow is:

```text
grill -> init -> run -> cleanup
```

During `run`, Ralph executes:

```text
review-decisions -> create-prd -> create-slices -> preflight -> implement-slice... -> final-review -> pr-review
```

## State

Each issue has one workspace:

```text
ralph-v2/workspaces/<issue-number>/
```

The workspace contains `state.json`, logs, human-input flag files, and review artifacts.

Top-level `state.json` fields:

```json
{
  "issue": 2,
  "repo": "owner/repo",
  "baseBranch": "main",
  "branch": "feat/issue-2-short-slug",
  "status": "initialized",
  "createdAt": "2026-05-02T00:00:00Z",
  "steps": []
}
```

Each step has this shape:

```json
{
  "id": "implement-slice-14",
  "phase": "fixed",
  "type": "implement-slice",
  "status": "pending",
  "agent": "codex",
  "reviewer": null,
  "hitl": false,
  "sub_issue": 14,
  "metrics": null,
  "notes": ""
}
```

Step statuses are:

```text
pending -> in_progress -> completed
                       -> blocked
                       -> failed
```

Failed steps stop the pipeline until the user explicitly resets the step to `pending` or marks it `completed`.

## Step Types

- `review-decisions`: reviews issue decisions against `CONTEXT.md`, `CLAUDE.md`, and ADRs; may block for human input.
- `create-prd`: preserves the original issue body, drafts the PRD, runs two council reviews, and updates the parent issue.
- `create-slices`: drafts vertical AFK slices, reviews them, creates GitHub sub-issues, and links them under the parent.
- `preflight`: checks the working tree and `baseBranch`, creates/pushes the feature branch, and appends dynamic steps.
- `implement-slice`: reads the assigned sub-issue, follows TDD, commits, pushes, and closes the sub-issue.
- `final-review`: reviews branch changes, runs quality checks, verifies acceptance criteria, and writes `final-review.md`.
- `pr-review`: creates or updates the PR and invokes `code-review:code-review`.

## Bundled Skills

`ralph-v2/skills/` contains the skills used by the prompts:

- `to-prd/`
- `to-issues/`
- `codex-review-prd/`
- `codex-review-slices/`
- `codex-implement-slice/`
- `tdd/`
- `domain/`

The bundle is self-contained. Skill references point at files inside `ralph-v2/skills/`, not at the user's global skill directory.
