# Create Slices

Create or refresh implementation sub-issues for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

## Goal

Read the PRD from the parent GitHub issue, draft vertical implementation slices, run two independent council reviews, and create AFK-ready sub-issues linked under the parent issue.

## Required Inputs

- Read the GitHub issue body, which should now contain the PRD:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-issues/SKILL.md` if it exists. If not, still follow the slice rules below.
- Check existing sub-issues before creating anything so re-runs do not create duplicates.

## Slice Rules

Draft vertical slices following the `to-issues` skill rules:

- Use tracer bullets: each slice should deliver one end-to-end behavior that can be implemented and verified independently.
- Do not create horizontal slices by technical layer, file type, component category, or infrastructure-only work.
- Each slice must include a clear user-facing or operator-visible behavior, acceptance criteria, and focused test guidance.
- Keep slices small enough for one AFK implementation step, but complete enough that the resulting code is useful.
- Mark every generated sub-issue as AFK.
- Keep future work or blocked-by references out of the generated sub-issues unless the PRD explicitly requires them for this issue.

## Council Review

Run exactly two rounds of independent council review using the standalone wrapper.

Round 1:

```bash
./ralph-v2/scripts/council-review.sh "Review the draft vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on horizontal slicing, missing acceptance criteria, dependency problems, test gaps, and conflicts with CONTEXT.md, CLAUDE.md, or ADRs."
```

Incorporate the Round 1 feedback into the slice list. Keep major feedback that changes slice boundaries, sequencing, correctness, or testing. Drop nitpicks and style-only comments.

Round 2:

```bash
./ralph-v2/scripts/council-review.sh "Review the revised vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, duplicate or overlapping slices, missing AFK criteria, unresolved dependencies, and contradictions introduced while incorporating Round 1 feedback."
```

Incorporate the Round 2 feedback into the final slice list using the same filtering rules. Do not run additional review rounds.

## GitHub Sub-Issue Creation

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
- Out-of-scope notes where needed

After each issue is created, link it to the parent with GitHub GraphQL `addSubIssue`.

Required GraphQL flow:

1. Resolve the parent issue node ID with `gh api graphql`.
2. Resolve or capture each created sub-issue node ID.
3. Call the `addSubIssue` mutation for each missing parent/sub-issue relationship.

The mutation must use the parent issue ID and sub-issue ID; do not rely only on markdown references.

## Idempotency

This step is idempotent:

- Before creating sub-issues, inspect existing sub-issues linked to parent `#{{ISSUE}}`.
- Also check repo issues for existing slice issues that reference `Parent: #{{ISSUE}}`.
- Re-running must not create duplicate sub-issues.
- If an intended slice already exists, update or reuse it rather than creating another issue.
- If a sub-issue exists but is not linked under the parent, only run the `addSubIssue` mutation.

## Output File

Write the final slice plan to:

```text
{{WORKSPACE}}/slices.md
```

Include the created or reused sub-issue numbers and whether each was newly created, reused, or newly linked.

Complete normally only after all final AFK sub-issues exist and are linked under the parent issue.
