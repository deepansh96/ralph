# Review Fixes

Address automated code review findings for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: claude
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, quality checks, push), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Goal

Read the automated code review comments posted on the PR, evaluate each finding against the codebase, implement fixes for valid issues, dismiss invalid ones with reasoning, push all fixes as a single commit, and post a summary comment on the PR.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the parent issue:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`
- Read the PR review record:
  `{{WORKSPACE}}/pr-review.md`
- Read the final review summary:
  `{{WORKSPACE}}/final-review.md`
- Identify implementation sub-issues from state steps where `type` is `implement-slice`, then read each sub-issue:
  `gh issue view <sub-issue-number> --repo {{REPO}}`

## Branch

Work on the feature branch recorded in state:

```bash
git checkout {{BRANCH}}
```

If checkout fails, stop and report the failure.

## Discover PR Number

Extract the PR number from `{{WORKSPACE}}/pr-review.md`. If the file does not contain a PR number, discover it with:

```bash
gh pr list --repo {{REPO}} --head {{BRANCH}} --base {{BASE_BRANCH}} --state open --json number,url
```

If no open PR exists, stop and report the failure.

## Fetch Review Comments

Fetch all comments on the PR to find the automated review findings:

```bash
gh api repos/{{REPO}}/issues/<pr-number>/comments --paginate
```

Also fetch inline review comments:

```bash
gh api repos/{{REPO}}/pulls/<pr-number>/comments --paginate
```

Identify comments posted by the `code-review:code-review` plugin. These are the findings to evaluate. If a review comment contains multiple issues, treat each as a separate finding.

## Evaluate Each Finding

For each review finding:

1. **Understand the context.** Read the file(s) and line(s) referenced by the finding. Read related tests, interfaces, and callers.
2. **Reason about validity.** Determine whether the finding identifies a real bug, a meaningful improvement, or is a false positive. Consider:
   - Does the finding describe actual incorrect behavior?
   - Does it identify a real security, correctness, or reliability risk?
   - Is it consistent with the project conventions in `CONTEXT.md`, `CLAUDE.md`, and ADRs?
   - Would the suggested change improve the code without introducing regressions?
3. **Classify the finding** as one of:
   - **Fix**: Valid issue that should be fixed now.
   - **Dismiss**: False positive, style preference, speculative concern, or low-priority issue that does not warrant a change.

## Implement Fixes

For each finding classified as **Fix**:

1. Implement the minimal change needed to address the finding.
2. Update or add tests if the fix changes observable behavior.
3. Follow the TDD skill references at `{{SKILLS_DIR}}/tdd/` for test guidance.

Do not refactor unrelated code. Stay within the scope of addressing review findings.

## Quality Checks

After all fixes are implemented, Run quality checks from CLAUDE.md. If CLAUDE.md defines exact commands, run those commands. If no exact command is available, run the most relevant project tests for the changed files plus any formatter or lint command already used by the project.

Do not commit if tests or required checks fail.

## Git Commit

After tests and quality checks pass, and only if there are fixes to commit:

1. Review the changed files with `git status --short` and relevant diffs.
2. Commit only the review-fix changes.
3. Use a descriptive commit message:

```bash
git commit -m "Address code review findings for #{{ISSUE}}"
```

If there are no fixes (all findings were dismissed), skip the commit.

## Push

Push the feature branch after the commit succeeds:

```bash
git push
```

If there were no fixes and no commit, skip the push.

## PR Summary Comment

Post a summary comment on the PR listing the disposition of every finding:

```bash
gh pr comment <pr-number> --repo {{REPO}} --body-file {{WORKSPACE}}/review-fixes-comment.md
```

Write the comment body to `{{WORKSPACE}}/review-fixes-comment.md` before posting. The comment must include:

- A header indicating this is the review-fixes assessment.
- For each finding:
  - The original finding (quoted or summarized).
  - The disposition: **Fixed** or **Dismissed**.
  - For fixed items: what was changed and why.
  - For dismissed items: the reasoning for dismissal.
- A summary line: N fixed, M dismissed, out of total findings.

## No Findings

If the automated review posted zero actionable findings, write the output file noting zero findings, post a brief PR comment confirming the review was assessed with no changes needed, and complete normally.

## Output File

Write the review-fixes summary to:

```text
{{WORKSPACE}}/review-fixes.md
```

Use this structure:

```md
# Review Fixes

## PR

- PR number: #<number>
- PR URL: <url>

## Findings Evaluated

### 1. <short title>

**Finding:** <what the review flagged>

**Disposition:** Fixed | Dismissed

**Reasoning:** <why this was fixed or dismissed>

**Changes:** <files changed, if fixed>

### 2. ...

## Summary

- Total findings: N
- Fixed: X
- Dismissed: Y
- Commit: <hash, or "none">
- Quality checks: passed | skipped (no fixes)
```

## Completion

Complete normally only after:

- The feature branch is checked out.
- All PR review comments have been fetched and evaluated.
- Each finding has been classified as Fix or Dismiss with documented reasoning.
- Valid fixes are implemented, tested, committed, and pushed (if any).
- Quality checks pass (if fixes were made).
- A summary comment is posted on the PR.
- `{{WORKSPACE}}/review-fixes.md` exists with the full summary.
