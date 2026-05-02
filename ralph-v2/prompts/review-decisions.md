# Review Decisions

Review the decisions in GitHub issue `{{ISSUE}}` for repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

## Required Inputs

- Read the issue with `gh issue view {{ISSUE}} --repo {{REPO}}`.
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.

## HITL Resume

If this prompt includes a `## HITL Resume` section, use the human answers in that section and complete WITHOUT re-running council review.

On HITL resume:

1. Read `{{WORKSPACE}}/review-decisions.md`.
2. Update the GitHub issue with the findings and the human answers where useful.
3. Do not call `scripts/council-review.sh`.
4. Do not repeat any council or review phase.
5. Do not delete the HITL flag file — it serves as an audit trail.
6. Finish normally so Ralph can mark the step completed.

## Council Review

For a first run, call the standalone wrapper:

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWER}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the decisions in GitHub issue {{ISSUE}} (repo {{REPO}}). Evaluate each decision against:
1. DESIGN GAPS — Are any decisions missing that a developer would need before implementation? Are scope boundaries explicit?
2. ARCHITECTURE RISKS — Could any decision lead to performance, scaling, security, or maintainability problems?
3. CODEBASE CONFLICTS — Do any decisions contradict patterns in CONTEXT.md, CLAUDE.md, or existing ADRs?
4. IMPLEMENTATION CLARITY — Is each decision specific enough to implement without guessing? Are acceptance criteria testable?
5. DEPENDENCY & SEQUENCING — Are there implicit ordering constraints or external dependencies that are not called out?
6. TESTABILITY — Can the proposed approach be verified with automated tests? Are edge cases addressed?
For each issue found, state the severity (critical / major / minor), the specific decision it applies to, and a concrete recommendation."
```

Use the council feedback as an independent review of the issue's decisions.

## Filtering

Keep:

- Critical or major feedback that could change scope, architecture, sequencing, correctness, or operator workflow.
- Questions that require human judgment and cannot be resolved from the codebase alone.
- Conflicts with `CONTEXT.md`, `CLAUDE.md`, or ADRs.

Drop:

- Minor or nitpick-level feedback
- Wording preferences that do not change behavior
- Style-only comments
- Speculative future work outside this issue

## Output File

Write findings to `{{WORKSPACE}}/review-decisions.md`. For every point (kept or dropped), include the council's original point, your analysis, and your recommendation.

Structure:

```md
# Review Decisions

## Major feedback

### 1. <short title>

**Council:** <what the council said>

**Analysis:** <your take — why this matters, how it affects implementation, whether you agree/disagree and why>

**Recommendation:** <concrete action — what should change, or why no change is needed>

### 2. ...

## Open questions

### 1. <short title>

**Council:** <what the council raised>

**Analysis:** <why this can't be resolved from the codebase alone>

**Recommendation:** <what the human should decide and what the tradeoffs are>

### 2. ...

## Dropped feedback

### 1. <short title>

**Council:** <what the council said>

**Why dropped:** <why this is a nitpick, style-only, or out of scope>

### 2. ...
```

## Blocking Protocol

If there are open questions requiring human judgment:

1. Set this step status to `blocked` in `{{WORKSPACE}}/state.json`.
2. Create `{{WORKSPACE}}/hitl-{{STEP_ID}}.md`.
3. Include the questions and an `## Answers` section in the flag file.
4. Stop after writing the flag file.

If there are no open questions, complete normally so Ralph marks the step completed.
