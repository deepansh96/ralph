# Ralph Workspace Initialization

Initialize a Ralph workspace for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

## Required Inputs

- Issue: `{{ISSUE}}`
- Repo: `{{REPO}}`
- Ralph directory (`<ralph-dir>`): the folder that contains this `prompts/init.md`, relative to the project root. It is usually `ralph/`, but use the real folder name if Ralph was cloned under another name; every path below that starts with `<ralph-dir>/` means that folder.
- Workspace: `<ralph-dir>/workspaces/{{ISSUE}}` (`workspaces/{{ISSUE}}` relative to `<ralph-dir>/`)

## Review-Decisions Rounds

The number of review-decisions steps is configurable: **0, 1, or 2** (default **0**).

- **0 rounds (default):** No review-decisions steps. Pipeline starts at `create-and-review-prd`.
- **1 round:** `review-decisions-1` with `hitl: true`. Council feedback + human checkpoint in a single pass.
- **2 rounds:** `review-decisions-1` with `hitl: false`, then `review-decisions-2` with `hitl: true`. Two-pass review: first council feedback, then human checkpoint.

If the user does not mention review-decisions rounds, use the default of 0. Include review-decisions steps only when the user explicitly opts in (e.g. "with 1 review-decision round", "with 2 review-decision rounds", "run review decisions"). If the user opts in without a count, use 1 review-decisions round.

## Hard Requirements

- Validate that the GitHub CLI is available before doing any other work:
  `command -v gh`
- Read the GitHub issue before creating state:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Verify the working tree is clean before creating state:
  `git status --porcelain`
  If output is not empty, error that the working tree is dirty and explain the Ralph branch contract:
  - Grilling documentation changes (`CONTEXT.md`, ADRs, or similar) must be committed before `init`.
  - If those changes are speculative or feature-specific, commit and push them on a `grill/*` planning branch; when ready to build, set `.baseBranch` to that `grill/*` branch.
  - If those changes are already accepted for the mainline, commit and push or merge them into the intended base branch; then set `.baseBranch` to that updated branch.
  - Do not stash grilling docs unless the user explicitly wants `init` and downstream agents to ignore them.
- Create `<ralph-dir>/workspaces/{{ISSUE}}/`.
- Write exactly one state file at `<ralph-dir>/workspaces/{{ISSUE}}/state.json`.
- Initialize `<ralph-dir>/workspaces/{{ISSUE}}/local-resources.json` with
  `{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}`.
- Running init on an already-initialized workspace must not overwrite existing state. If `<ralph-dir>/workspaces/{{ISSUE}}/state.json` already exists, stop with a clear warning or error.
- Set both `"baseBranch": null` and `"branch": null`. Do not infer defaults.
- Capture `"projectRoot"` by running `git rev-parse --show-toplevel` from the project root (not from inside `<ralph-dir>/`). Store the absolute path.
- Hardcode the agent defaults shown below. Do not use runtime agent detection.
- After writing state, verify it with `jq` and confirm that `./<ralph-dir>/ralph.sh status --issue {{ISSUE}}` shows all steps with pending status.

## State Schema

Write `<ralph-dir>/workspaces/{{ISSUE}}/state.json` with this shape:

```json
{
  "issue": {{ISSUE}},
  "repo": "{{REPO}}",
  "baseBranch": null,
  "branch": null,
  "projectRoot": "<absolute path from git rev-parse --show-toplevel>",
  "status": "initialized",
  "createdAt": "<ISO-8601 UTC timestamp>",
  "steps": [
    {
      "id": "create-and-review-prd",
      "phase": "fixed",
      "type": "create-and-review-prd",
      "status": "pending",
      "agent": "codex",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "reviewRounds": 0,  // 0, 1, or 2 — controls how many council review rounds run inside this step
      "hitl": false,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "create-and-review-slices",
      "phase": "fixed",
      "type": "create-and-review-slices",
      "status": "pending",
      "agent": "codex",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "reviewRounds": 0,  // 0, 1, or 2 — controls how many council review rounds run inside this step
      "hitl": false,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "preflight",
      "phase": "fixed",
      "type": "preflight",
      "status": "pending",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "cleanup-local-resources",
      "phase": "fixed",
      "type": "cleanup-local-resources",
      "status": "pending",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "alwaysRun": true,
      "metrics": null,
      "notes": ""
    }
  ]
}
```

When the user explicitly opts into review-decisions, prepend these entries to `steps`:

- **1 round:** prepend only `review-decisions-1`, and set `"hitl": true`.
- **2 rounds:** prepend both entries; `review-decisions-1` keeps `"hitl": false`, and `review-decisions-2` uses `"hitl": true`.

```json
[
  {
    "id": "review-decisions-1",
    "phase": "fixed",
    "type": "review-decisions",
    "status": "pending",
    "agent": "codex",
    "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
    "hitl": false,
    "metrics": null,
    "notes": ""
  },
  {
    "id": "review-decisions-2",
    "phase": "fixed",
    "type": "review-decisions",
    "status": "pending",
    "agent": "codex",
    "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
    "hitl": true,
    "metrics": null,
    "notes": ""
  }
]
```

**Review-decisions round rules:**
- **0 rounds (default):** Omit both review-decisions steps. Steps start at `create-and-review-prd`. Total fixed steps: 4.
- **1 round:** Include only `review-decisions-1` with `hitl: true`. Total fixed steps: 5.
- **2 rounds:** Include both `review-decisions-1` (`hitl: false`) and `review-decisions-2` (`hitl: true`). Total fixed steps: 6.

`cleanup-local-resources` is present from initialization so it can run after
any earlier failure. Ralph defers this `alwaysRun` step until normal pending
work finishes.

**`reviewRounds` rules (for `create-and-review-prd` and `create-and-review-slices`):**
- **0 (default):** No council review. Draft → done.
- **1:** One council review round. Draft → council → incorporate → done.
- **2:** Two council review rounds. Draft → council → incorporate → council → incorporate.

Default is 0. If the user requests a different number of review rounds for these steps (e.g. "with 1 review round on PRD", "with 2 review rounds on slices"), set the value accordingly. Each step's `reviewRounds` is independent.

The actual `state.json` output must be valid JSON (no comments). The comments above are for your reference only.

## Implementation Steps

1. Run `command -v gh`. If it fails, stop and report that the GitHub CLI is required.
2. Run `gh issue view {{ISSUE}} --repo {{REPO}}`. If it fails, stop and report the issue lookup failure.
3. Run `git status --porcelain`. If the output is not empty, stop and report that the working tree must be clean before initializing. Include this guidance: commit grilling docs to a pushed `grill/*` planning branch and use that branch as `.baseBranch`, or merge the docs into the intended base branch and use that branch as `.baseBranch`.
4. If `<ralph-dir>/workspaces/{{ISSUE}}/state.json` exists, stop. Do not silently overwrite it.
5. Create `<ralph-dir>/workspaces/{{ISSUE}}/`.
6. Write `state.json` using the schema above. Use a current UTC ISO-8601 timestamp for `createdAt`.
7. Write `local-resources.json` using the empty ledger above.
8. Validate both JSON files with `jq`.
9. Run `./<ralph-dir>/ralph.sh status --issue {{ISSUE}}` and confirm all steps show `pending` status.

Do not run any pipeline step. This prompt only initializes the workspace state.
