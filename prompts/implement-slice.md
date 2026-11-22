# Implement Slice

Implement GitHub sub-issue `{{SUB_ISSUE}}` for parent issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Sub-issue: {{SUB_ISSUE}}
Skills: {{SKILLS_DIR}}

Default agent: codex
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, tests, quality checks), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Long-Running Commands

This step runs as a single non-interactive session: ending your turn ends the step, and Ralph treats that as done. Never end your turn while a command, test run, or background task is still running, and never end it with a "waiting for…" message. Run every command in the foreground and wait for its result. If a test run could exceed the shell tool's timeout, split it into smaller foreground runs (for example by test file or pattern) instead of backgrounding it. Only end your turn once the slice is committed, pushed, and closed, or after recording a failure per the Failure Protocol.

## Goal

Read the project context, parent issue, and assigned sub-issue; implement only the assigned sub-issue via TDD on the feature branch; run project quality checks; commit, push, and close the sub-issue after the implementation is verified.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the TDD skill workflow files from Ralph's bundled skills directory:
  - `{{SKILLS_DIR}}/tdd/SKILL.md`
  - `{{SKILLS_DIR}}/tdd/tests.md`
  - `{{SKILLS_DIR}}/tdd/mocking.md`
- Read the parent issue for overall context:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the assigned sub-issue for this slice's exact requirements:
  `gh issue view {{SUB_ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`

## Blocker Verification

Before starting implementation, check whether sub-issue `#{{SUB_ISSUE}}` has any open blockers, from both representations:

1. Native issue dependencies — the count of open blockers:

```bash
gh api repos/{{REPO}}/issues/{{SUB_ISSUE}} --jq '.issue_dependencies_summary.blocked_by // 0'
```

2. `Blocked by` references in the sub-issue body — verify each listed blocker is closed:

```bash
gh issue view <blocker-number> --repo {{REPO}} --json state -q '.state'
```

If the native count is greater than zero or any body-listed blocker is still open, set this step's status to `failed` with a note listing the open blockers, then stop.

## Scope Rules

- Implement only sub-issue `#{{SUB_ISSUE}}`.
- Stay within the acceptance criteria listed in the assigned sub-issue.
- Do not implement other parent issue slices, blocked-by issues, referenced future work, or cleanup outside this slice.
- Preserve unrelated user changes in the working tree.

## Branch

**CRITICAL**: This repo uses git submodules. You MUST run ALL git commands from the project root at `{{WORKSPACE}}/../../..` (which is the same as the `projectRoot` in state.json). Do NOT run git commands from inside the workspace directory — it is inside a submodule with a different remote.

First, change to the project root:
```bash
cd $(jq -r '.projectRoot' {{WORKSPACE}}/state.json)
```

Then checkout the feature branch:
```bash
git fetch origin
git checkout {{BRANCH}} 2>/dev/null || git checkout -b {{BRANCH}} origin/{{BRANCH}}
```

If the branch is already checked out, continue. If checkout fails, stop and report the failure.

**Stay in the project root for all subsequent commands** — do not cd back to the workspace.

## TDD Workflow

Follow the TDD skill workflow strictly.

1. Identify the public interface and behavior required by sub-issue `#{{SUB_ISSUE}}`.
2. Identify the seams to test at: the pre-agreed seams are the ones recorded in the parent PRD's Testing Decisions. If the PRD names none, use the highest existing seam and note the choice. Do not write tests at unconfirmed seams.
3. Write one failing test first for the next observable behavior.
4. Run the focused test and confirm it fails for the expected reason.
5. Implement the smallest change needed to pass that test.
6. Run the focused test and confirm it passes.
7. Repeat one behavior at a time until the sub-issue acceptance criteria are satisfied.

Use integration-style tests through public interfaces where practical. Mock only external boundaries. Expected values must come from an independent source of truth — a known-good literal, a worked example, the spec — never recomputed the way the code computes them (a tautological test passes by construction and verifies nothing).

Do not refactor beyond what the current slice needs.

Before starting a local process, container, browser/computer-use session, or
creating a temporary path, append enough ownership information to
`{{WORKSPACE}}/local-resources.json` for `cleanup-local-resources` to remove it
safely. Use names prefixed with `ralph-{{ISSUE}}-` where supported, and clean
resources started by this step before completing.

## Quality Checks

Run quality checks from CLAUDE.md before commit. If CLAUDE.md defines exact commands, run those commands. If no exact command is available, run the most relevant project tests for the files changed plus any formatter or lint command already used by the project.

Do not commit if tests or required checks fail.

## Git Commit

After tests and quality checks pass:

1. Review the changed files with `git status --short` and relevant diffs.
2. Commit only the changes for sub-issue `#{{SUB_ISSUE}}`.
3. Use a descriptive commit message that references the sub-issue, for example:

```bash
git commit -m "Implement slice #{{SUB_ISSUE}}"
```

## Push

Push the feature branch after the commit succeeds:

```bash
git push
```

If upstream tracking is missing, push with:

```bash
git push -u origin {{BRANCH}}
```

## Close Sub-Issue

Close the assigned sub-issue only after the implementation commit is pushed successfully:

```bash
gh issue close {{SUB_ISSUE}} --repo {{REPO}} --comment "Implemented in {{BRANCH}}."
```

Do not close the parent issue.

## Post-Implementation Audit

After pushing and before closing the sub-issue, run a self-review:

1. **Acceptance criteria audit** — read the diff against `{{BASE_BRANCH}}` and check each acceptance criterion from the sub-issue. Every criterion must be addressed.
2. **Scope creep check** — flag any changes that implement work belonging to other issues or beyond the stated acceptance criteria. Revert scope creep before closing.
3. **File scope check** — verify that changed files fall within the module or file scope stated in the sub-issue. Flag unexpected file changes.

If the audit finds unmet acceptance criteria, fix them before closing. If scope creep or file scope violations are found, revert the offending changes and re-run quality checks.

## Completion

Complete normally only after:

- The sub-issue acceptance criteria are implemented.
- Tests were written first and pass.
- Quality checks from CLAUDE.md pass.
- The post-implementation audit passes with no unmet criteria, scope creep, or file scope violations.
- Changes are committed with a `#{{SUB_ISSUE}}` reference.
- The feature branch is pushed.
- Sub-issue `#{{SUB_ISSUE}}` is closed on GitHub.
