# Create PRD

Create or refresh the PRD for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

## Goal

Turn the issue's grilled decisions into a complete PRD, preserve the original issue body locally, run two independent council reviews, incorporate feedback after each round, and update the same GitHub issue with the final PRD.

## Required Inputs

- Read the GitHub issue body:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-prd/SKILL.md` if it exists. If not, follow the `to-prd` structure embedded below.
- Explore the codebase for relevant modules, current patterns, test style, and risks before drafting.

## Preserve Original Issue

Before any GitHub issue mutation, save the current issue body exactly once to:

```text
{{WORKSPACE}}/original-issue.md
```

If `original-issue.md` already exists, leave it unchanged. Re-runs must preserve the first captured original issue body, not overwrite it with a later PRD.

## AFK Planning

Sketch the modules and test plan yourself. Do not ask the user to confirm modules or test coverage during this step. Use the project vocabulary from `CONTEXT.md`, and flag ADR conflicts inside the PRD if any exist.

## PRD Structure

Draft the PRD following the `to-prd` skill template. The final issue body must contain these sections, in this order:

```md
## Decision Summary

## Problem Statement

## Solution

## User Stories

## Implementation Decisions

## Testing Decisions

## Out of Scope

## Further Notes
```

Requirements:

- `Decision Summary` is a concise, scannable list of concrete decisions from the issue and discovered context.
- `User Stories` is a numbered list using: `As a <actor>, I want a <feature>, so that <benefit>`.
- `Implementation Decisions` covers modules, interfaces, architecture, schemas, API contracts, and important interactions, but avoids fragile file-path or code-snippet details.
- `Testing Decisions` explains behavior-focused tests, target modules, and relevant prior test style in the codebase.
- `Out of Scope` explicitly separates future work from this PRD.

## Council Review

Run exactly two rounds of independent council review using the standalone wrapper.

Round 1:

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWER}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the draft PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on missing requirements, unclear decisions, architecture risks, testing gaps, and conflicts with CONTEXT.md, CLAUDE.md, or ADRs."
```

Incorporate the Round 1 feedback into the PRD. Keep major feedback that changes scope, architecture, correctness, sequencing, or testing. Drop nitpicks and style-only comments.

Round 2:

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWER}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the revised PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, unresolved ambiguities, acceptance-risk gaps, and contradictions introduced while incorporating Round 1 feedback."
```

Incorporate the Round 2 feedback into the final PRD using the same filtering rules. Do not run additional review rounds.

## Compacting

Compact the issue body if it is too long for comfortable GitHub issue use. Preserve all PRD sections and all decisions needed for implementation. Prefer concise bullets over removing important requirements.

## GitHub Update

Update the existing issue with the final PRD:

```bash
gh issue edit {{ISSUE}} --repo {{REPO}} --body-file <final-prd-file>
```

Do not create a new issue. Do not append a second PRD below an existing PRD.

## Idempotency

This step is idempotent:

- If the issue body already contains a PRD, replace the PRD body with the refreshed final PRD.
- If `{{WORKSPACE}}/original-issue.md` already exists, do not overwrite it.
- Re-running the step updates the issue body rather than duplicating PRD sections.
- The final issue body should contain one `## Decision Summary`, one `## Problem Statement`, and one complete PRD.

Complete normally after the GitHub issue update succeeds so Ralph can mark the step completed.
