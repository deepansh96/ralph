# CONTEXT.md Completeness Check

CONTEXT_CHECK_REQUIRED

Validate the project `CONTEXT.md` before Ralph runs any pipeline step.

## Inputs

- Issue: `{{ISSUE}}`
- Repo: `{{REPO}}`
- Workspace: `{{WORKSPACE}}`
- Skills directory: `{{SKILLS_DIR}}`

## Rules

- Evaluate `CONTEXT.md` against the CONTEXT-FORMAT skill rules.
- If available, read `{{SKILLS_DIR}}/grill-with-docs/CONTEXT-FORMAT.md` for the canonical format.
- A sufficient `CONTEXT.md` must define project-specific language, relationships, example dialogue, and flagged ambiguities.
- General prose without the required sections is insufficient.
- Do not modify files.

## Required Response Format

Return exactly one of these markers at the start of the response:

```text
CONTEXT_CHECK: PASS
<one concise reason>
```

```text
CONTEXT_CHECK: FAIL
<specific missing or insufficient parts>
```
