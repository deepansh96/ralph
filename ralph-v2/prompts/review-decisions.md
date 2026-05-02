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
5. Finish normally so Ralph can mark the step completed.

## Council Review

For a first run, call the standalone wrapper:

```bash
./ralph-v2/scripts/council-review.sh "Review GitHub issue {{ISSUE}} decisions for design gaps, conflicts with CONTEXT.md, conflicts with CLAUDE.md, and conflicts with ADRs. Focus on major product or architecture risks."
```

Use the council feedback as an independent review of the issue's decisions.

## Filtering

Keep:

- Major feedback that could change scope, architecture, sequencing, correctness, or operator workflow.
- Questions that require human judgment.
- Conflicts with `CONTEXT.md`, `CLAUDE.md`, or ADRs.

Drop:

- nitpicks
- wording preferences that do not change behavior
- style-only comments
- speculative future work outside this issue

## Output File

Write findings to `{{WORKSPACE}}/review-decisions.md` with this structure:

```md
# Review Decisions

## Major feedback

- ...

## Open questions

- ...

## Dropped feedback

- ...
```

The `Dropped feedback` section may summarize why nitpicks were dropped, but do not preserve long nitpick lists.

## Blocking Protocol

If there are open questions requiring human judgment:

1. Set this step status to `blocked` in `{{WORKSPACE}}/state.json`.
2. Create `{{WORKSPACE}}/hitl-{{STEP_ID}}.md`.
3. Include the questions and an `## Answers` section in the flag file.
4. Stop after writing the flag file.

If there are no open questions, complete normally so Ralph marks the step completed.
