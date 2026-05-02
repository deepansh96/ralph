# Final Review

Review the completed implementation for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: claude
Mode: AFK, no HITL

## Goal

Review all implementation changes on the feature branch, verify every implemented sub-issue's acceptance criteria, run the project quality checks, update project documentation with newly discovered patterns, and write a final review summary.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the parent issue:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`
- Identify completed implementation sub-issues from state steps where `type` is `implement-slice`, then read each sub-issue:
  `gh issue view <sub-issue-number> --repo {{REPO}}`

## Branch

Work on the feature branch recorded in state:

```bash
git checkout {{BRANCH}}
```

If checkout fails, stop and report the failure.

## Changed Files

Read the changed file list with:

```bash
git diff --name-only {{BASE_BRANCH}}...HEAD
```

Progressively read changed files from that list. Start with files most likely to affect behavior or project workflow, then expand as needed to understand interactions and side effects. Do not review unrelated files that are not part of the branch diff.

## Quality Checks

Run quality checks from CLAUDE.md before writing the final summary. If CLAUDE.md defines exact commands, run those commands. If no exact command is available, run the most relevant project tests for the changed files plus any formatter or lint command already used by the project.

Do not complete this step if required checks fail. Report the failing command and leave the step failed so the issue can be fixed explicitly.

## Acceptance Verification

Verify acceptance criteria from each sub-issue.

For each implemented sub-issue:

1. Read its acceptance criteria from GitHub.
2. Compare the criteria against the changed files and observed behavior.
3. Confirm whether each criterion is satisfied.
4. Note any missing pieces, regressions, side effects, or scope creep.

Do not implement missing feature work in this step. This step may update project documentation as described below, but behavioral implementation gaps should be reported as blockers.

## Documentation Updates

Update CONTEXT.md and CLAUDE.md with any new project patterns discovered during implementation.
Update CLAUDE.md when implementation reveals durable commands, conventions, or workflow notes.

Only add durable, project-level patterns:

- vocabulary, relationships, example dialogue, or flagged ambiguities for `CONTEXT.md`
- reusable commands, conventions, workflow notes, or implementation patterns for `CLAUDE.md`

Do not add one-off review notes, temporary branch details, sub-issue checklists, or anything better suited to the final review summary.

## Output File

Write the review summary to:

```text
{{WORKSPACE}}/final-review.md
```

Use this structure:

```md
# Final Review

## Changed files reviewed

- ...

## Quality checks

- ...

## Acceptance criteria verification

- #<sub-issue>: ...

## Documentation updates

- ...

## Findings

- ...

## Outcome

Pass or fail, with the reason.
```

## Completion

Complete normally only after:

- Changed files were read from `git diff --name-only {{BASE_BRANCH}}...HEAD`.
- Quality checks from CLAUDE.md passed.
- Acceptance criteria were verified per sub-issue.
- Side effects, missing pieces, and scope creep were checked.
- CONTEXT.md and CLAUDE.md were updated if new durable patterns were discovered.
- `{{WORKSPACE}}/final-review.md` exists with the review summary.
