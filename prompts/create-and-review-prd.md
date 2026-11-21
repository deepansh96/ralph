# Create and Review PRD

Create or refresh the PRD for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex

## Goal

Turn the issue's grilled decisions into a complete PRD, preserve the original issue body locally, run council reviews (count determined by `reviewRounds` in state.json), incorporate feedback after each round, and update the same GitHub issue with the final PRD.

## Required Inputs

- Read the GitHub issue body:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-spec/SKILL.md` if it exists. If not, follow the `to-spec` structure embedded below.
- Explore the codebase for relevant modules, current patterns, test style, and risks before drafting.

## Preserve Original Issue

Before any GitHub issue mutation, save the current issue body exactly once to:

```text
{{WORKSPACE}}/original-issue.md
```

If `original-issue.md` already exists, leave it unchanged. Re-runs must preserve the first captured original issue body, not overwrite it with a later PRD.

## AFK Planning

Sketch the modules and test plan yourself. Do not ask the user to confirm modules, seams, or test coverage during this step. Use the project vocabulary from `CONTEXT.md`, and flag ADR conflicts inside the PRD if any exist.

Sketch the testing seams per the `to-spec` skill: a seam is the public boundary tests observe behavior at. Prefer existing seams over new ones, use the highest seam possible, and keep the count low — the ideal number is one. Record the chosen seams in the Testing Decisions section; council review judges them there.

## PRD Structure

Draft the PRD following the `to-spec` skill template. The final issue body must contain these sections, in this order:

```md
## Decision Summary

## Problem Statement

## Solution

## User Stories

## Implementation Decisions

## Testing Decisions

## Out of Scope

## Further Notes

## Council Attribution

(Include one line per round actually executed. Omit this section if reviewRounds is 0.)
Round 1 — Reviewed by: <agents> · Failed: <agents or "none">
Round 2 — Reviewed by: <agents> · Failed: <agents or "none">
```

Requirements:

- `Decision Summary` is a concise, scannable list of concrete decisions from the issue and discovered context.
- `User Stories` is a numbered list using: `As a <actor>, I want a <feature>, so that <benefit>`.
- `Implementation Decisions` covers modules, interfaces, architecture, schemas, API contracts, and important interactions, but avoids fragile file-path or code-snippet details. Exception: a snippet from a prototype that encodes a decision more precisely than prose (state machine, schema, type shape) may be inlined, trimmed to the decision-rich parts.
- `Testing Decisions` names the seams tests will be written at (existing seams preferred, highest possible, as few as possible), explains behavior-focused tests, target modules, and relevant prior test style in the codebase. Expected values in tests must come from an independent source of truth, never recomputed the way the code computes them.
- `Out of Scope` explicitly separates future work from this PRD.

## Council Review

Before starting, read the `reviewRounds` field for this step (`{{STEP_ID}}`) from `{{WORKSPACE}}/state.json`. This controls how many council review rounds to run:

- **0 (default):** Skip council review entirely. Proceed directly to compacting and GitHub update.
- **1:** Run only Round 1. Skip Round 2 entirely.
- **2:** Run both Round 1 and Round 2 below.

If `reviewRounds` is missing, default to 0.

Round 1 (skip if `reviewRounds` is 0):

```bash
"{{RALPH_DIR}}/scripts/council-review.sh" --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the draft PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on:
1. MISSING REQUIREMENTS — Are any decisions or modules missing?
2. UNCLEAR DECISIONS — Are decisions specific enough to implement without guessing?
3. ARCHITECTURE RISKS — Module boundary cleanliness, coupling between modules, scaling or security concerns.
4. EDGE CASES — Race conditions, error paths, or boundary conditions not addressed.
5. INTERFACE DESIGN — Are public interfaces well-defined? Would you restructure any module boundaries?
6. TESTING GAPS — Is the test plan sufficient? Are edge cases covered?
7. SEAMS — Are tests planned at the highest existing seams? Are new seams justified, or is the plan introducing more seams than needed?
8. CONFLICTS — Contradictions with CONTEXT.md, CLAUDE.md, or existing ADRs.
For each issue found, state severity (critical/major/minor) and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Track attribution from each round for inclusion in the final PRD.

Before incorporating feedback, verify each council point against the codebase. For each point: read the relevant files, modules, or docs the council references. State whether the point is valid, partially valid, or invalid, citing what you found. If valid, determine the concrete PRD change needed. If invalid, drop it with evidence. Do not accept or reject council feedback based on reasoning alone.

Incorporate verified Round 1 feedback into the PRD. Keep major feedback that changes scope, architecture, correctness, sequencing, or testing. Drop nitpicks, style-only comments, and points invalidated by codebase verification.

Round 2 (skip if `reviewRounds` is less than 2):

```bash
"{{RALPH_DIR}}/scripts/council-review.sh" --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the revised PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, unresolved ambiguities, acceptance-risk gaps, interface design quality, and contradictions introduced while incorporating Round 1 feedback. Would you restructure anything that remains?"
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

Verify Round 2 feedback against the codebase using the same process. Incorporate verified feedback into the final PRD using the same filtering rules. Do not run additional review rounds.

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
