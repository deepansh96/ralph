# Create and Review Slices

Create or refresh implementation sub-issues for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex

## Goal

Read the PRD from the parent GitHub issue, draft vertical implementation slices, run council reviews (count determined by `reviewRounds` in state.json), and create AFK-ready sub-issues linked under the parent issue.

## Required Inputs

- Read the GitHub issue body, which should now contain the PRD:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-tickets/SKILL.md` if it exists. If not, still follow the slice rules below.
- Check existing sub-issues before creating anything so re-runs do not create duplicates.

## Slice Rules

Draft vertical slices following the `to-tickets` skill rules:

- Use tracer bullets: each slice should deliver one end-to-end behavior that can be implemented and verified independently.
- Do not create horizontal slices by technical layer, file type, component category, or infrastructure-only work.
- Each slice must include a clear user-facing or operator-visible behavior, acceptance criteria, and focused test guidance.
- Keep slices small enough for one AFK implementation step, but complete enough that the resulting code is useful — sized to fit in a single fresh context window.
- Look for opportunities to prefactor: "make the change easy, then make the easy change." Any prefactoring becomes its own slice, sequenced first.
- Mark every generated sub-issue as AFK.
- Give each slice its blocking edges: the `## Blocked by` section lists the slices that must complete before it can start, or "None - can start immediately". Only declare blockers that genuinely gate the slice — an unnecessary edge serializes work for no reason. Keep unrelated future work out of the generated sub-issues.
- When referencing dependencies between slices, always use the GitHub issue number (e.g., "Blocked by #25"), never the slice ordinal (e.g., "Blocked by Slice 7"). The implement-slice step checks blockers by running `gh issue view <number>` — ordinal references will resolve to wrong issues.

**Wide refactors are the exception to vertical slicing.** When the PRD contains one mechanical change whose blast radius fans across the whole codebase (a rename, a retyped shared symbol) so no vertical slice can land green, sequence it as expand–contract instead: an expand slice adds the new form beside the old; migrate slices move call sites over in batches sized by blast radius, each blocked by the expand; a contract slice deletes the old form, blocked by every migrate batch. CI stays green batch to batch because the old form survives until contract.

## Council Review

Before starting, read the `reviewRounds` field for this step (`{{STEP_ID}}`) from `{{WORKSPACE}}/state.json`. This controls how many council review rounds to run:

- **0 (default):** Skip council review entirely. Proceed directly to sub-issue creation.
- **1:** Run only Round 1. Skip Round 2 entirely.
- **2:** Run both Round 1 and Round 2 below.

If `reviewRounds` is missing, default to 0.

Round 1 (skip if `reviewRounds` is 0):

```bash
{{RALPH_DIR}}/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the draft vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on:
1. HORIZONTAL SLICING — Are any slices horizontal (single layer) rather than vertical (end-to-end demoable)? Exception: expand–contract slices for a wide refactor are legitimate — but check their sequencing (expand first, migrates blocked by expand, contract blocked by every migrate).
2. MISSING WORK — Is there work that no slice covers?
3. DEPENDENCY PROBLEMS — Wrong, missing, or unnecessary blocking edges, or implicit ordering constraints not declared as `Blocked by`.
4. AGENT COMPLETABILITY — Could anything block an agent from completing a slice independently in AFK mode?
5. MERGE CONFLICT RISK — Do multiple slices touch the same files? Are write boundaries between parallel slices clear?
6. TEST GAPS — Missing acceptance criteria or test guidance.
7. CONFLICTS — Contradictions with CONTEXT.md, CLAUDE.md, or existing ADRs.
For each issue found, state severity (critical/major/minor) and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Track attribution from each round for inclusion in the output file and sub-issue bodies.

Before incorporating feedback, verify each council point against the codebase. For each point: read the relevant files, modules, or docs the council references. State whether the point is valid, partially valid, or invalid, citing what you found. If valid, determine the concrete slice change needed. If invalid, drop it with evidence. Do not accept or reject council feedback based on reasoning alone.

Incorporate verified Round 1 feedback into the slice list. Keep major feedback that changes slice boundaries, sequencing, correctness, or testing. Drop nitpicks, style-only comments, and points invalidated by codebase verification.

Round 2 (skip if `reviewRounds` is less than 2):

```bash
{{RALPH_DIR}}/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the revised vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, duplicate or overlapping slices, missing AFK criteria, unresolved dependencies, merge conflict risk between parallel slices, and contradictions introduced while incorporating Round 1 feedback."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

Verify Round 2 feedback against the codebase using the same process. Incorporate verified feedback into the final slice list using the same filtering rules. Do not run additional review rounds.

## GitHub Sub-Issue Creation

Create the sub-issues in dependency order (blockers first) so each slice's `Blocked by` line can reference real issue numbers.

Create one GitHub issue per final slice using:

```bash
gh issue create --repo {{REPO}} --title "<slice title>" --body-file <slice-body-file>
```

Each sub-issue body must include:

- `AFK: true`
- Parent issue reference: `Parent: #{{ISSUE}}`
- Slice summary
- Acceptance criteria
- Testing guidance
- `Blocked by: #<n>` references, or "None - can start immediately"
- Out-of-scope notes where needed

After each issue is created, link it to the parent with GitHub GraphQL `addSubIssue`.

Required GraphQL flow:

1. Resolve the parent issue node ID with `gh api graphql`.
2. Resolve or capture each created sub-issue node ID.
3. Call the `addSubIssue` mutation for each missing parent/sub-issue relationship.

The mutation must use the parent issue ID and sub-issue ID; do not rely only on markdown references.

## Native Blocking Edges

After all sub-issues exist, wire each `Blocked by` edge as a native GitHub issue dependency so the frontier is visible in GitHub's UI:

```bash
gh api --method POST repos/{{REPO}}/issues/<blocked-number>/dependencies/blocked_by -F issue_id=<blocker-db-id>
```

`<blocker-db-id>` is the blocker's numeric database id from `gh api repos/{{REPO}}/issues/<blocker-number> --jq .id` — not the `#number` and not the GraphQL node ID.

Sync the native dependencies to the final declared `Blocked by` set, in both directions:

- List the existing edges first: `gh api repos/{{REPO}}/issues/<blocked-number>/dependencies/blocked_by`.
- Add every declared edge that is missing.
- Delete every existing edge that the final slice plan no longer declares: `gh api --method DELETE repos/{{REPO}}/issues/<blocked-number>/dependencies/blocked_by/<blocker-db-id>`. A stale native edge would keep the slice blocked forever, because implement-slice fails on any open native blocker.

If the dependencies API is unavailable on this repo, keep the `Blocked by: #<n>` body lines as the only representation and note that in the output file. The body lines stay authoritative for the implement-slice blocker check either way.

## Idempotency

This step is idempotent:

- Before creating sub-issues, inspect existing sub-issues linked to parent `#{{ISSUE}}`.
- Also check repo issues for existing slice issues that reference `Parent: #{{ISSUE}}`.
- Re-running must not create duplicate sub-issues.
- If an intended slice already exists, update or reuse it rather than creating another issue.
- If a sub-issue exists but is not linked under the parent, only run the `addSubIssue` mutation.
- Re-sync native dependencies to the final declared `Blocked by` set: add missing edges and delete edges no longer declared.

## Output File

Write the final slice plan to:

```text
{{WORKSPACE}}/slices.md
```

Include the created or reused sub-issue numbers and whether each was newly created, reused, or newly linked.

Complete normally only after all final AFK sub-issues exist and are linked under the parent issue.
