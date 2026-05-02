# Implement Slice Using Codex

Delegate a GitHub issue slice to Codex for TDD implementation, then review the results.

## Process

### 1. Ensure correct branch

Check the current git branch. If a parent issue exists, there should be a feature branch for it (e.g. `feat/issue-35-per-cwd-multi-run`). If the branch doesn't exist yet:

- Create one from main: `git checkout -b feat/issue-<parent-number>-<short-slug> main`
- All slices for the same parent issue should be committed to this branch

If already on the correct feature branch, continue. If on main or a different branch, switch to the parent's feature branch first.

### 2. Identify the target issue

Get the issue number from the user or conversation context. Read it with `gh issue view <number>`. Extract: title, acceptance criteria, blocked-by, parent issue (if any).

### 3. Verify unblocked

If the issue lists blockers, check whether they're closed/merged via `gh issue view`. Warn the user if any are still open — do not proceed without explicit confirmation.

### 4. Discover context files

Search the repo root for files Codex should read before implementing. Include only paths that exist:

- `CONTEXT.md` (domain vocabulary)
- `CLAUDE.md` (architecture/conventions)
- `docs/adr/*.md` (architectural decisions)

Also include the TDD skill files:

- `../tdd/SKILL.md` (TDD workflow)
- `../tdd/tests.md` (test examples)
- `../tdd/mocking.md` (mocking guidelines)
- `../tdd/deep-modules.md` (deep module design)
- `../tdd/interface-design.md` (interface design for testability)
- `../tdd/refactoring.md` (refactor patterns)

If a context file doesn't exist in the repo, omit it from the prompt. The TDD skill files are always included.

### 5. Construct the prompt

Build a concise prompt with this structure:

```
Read these files first:
- <list of discovered context files and TDD skill files>

Then read the parent issue: gh issue view <parent-number> --repo <owner/repo>
Then read your assigned issue: gh issue view <number> --repo <owner/repo>

Implement ONLY issue #<number> using the TDD skill workflow. Do not implement any other issue, even if referenced in the parent or in blocked-by relationships. Stay strictly within the acceptance criteria listed in the issue. If the issue references other slices or future work, leave those completely untouched — they belong to separate issues and will be handled independently. Commit your changes when done.
```

Omit the parent issue line if there is no parent.

### 6. Run Codex

Execute `codex exec "<prompt>"` from the repo root. Do NOT use `--full-auto` — Codex needs network access for `gh` and git access to commit. Run in background and notify the user when it finishes.

### 6.1. Monitor for stalls

After launching Codex in the background, start a Monitor that checks the output file's line count every 30 seconds. Only emit a notification if the line count hasn't changed for 3+ consecutive checks (90 seconds of no output). This avoids noisy updates while catching stalls early.

If a stall notification fires, check `git status` for uncommitted changes. If the output has been frozen for 3+ minutes with no file changes, report to the user and offer to kill and re-run. Stop the monitor when Codex completes.

### 7. Review results

When Codex finishes:

- **Commit check**: Did it create a commit? (`git log`)
- **Tests**: Run the project's test command (e.g. `npm test`). Report pass/fail.
- **Build**: Run the project's build command (e.g. `npm run build`). Report pass/fail.
- **Acceptance criteria audit**: Read the diff and check each acceptance criterion from the issue. Report as a checklist with pass/fail for each.
- **Scope creep**: Flag any changes that implement work belonging to other issues or beyond the stated acceptance criteria.
- **Misses**: Flag any acceptance criteria that were not met.
- **File scope**: Check that no new files or changes fall outside the issue's stated module/file scope.

### 8. Report

Send the review summary to the user with:
- The acceptance criteria checklist (pass/fail per criterion)
- Any scope creep or misses flagged
- Test and build status
- Recommendation: accept, revise, or discard

If the user wants to discard, reset with `git reset HEAD~1 --hard` (confirm first).
If the user wants revisions, construct a follow-up prompt for Codex with specific fixes.
