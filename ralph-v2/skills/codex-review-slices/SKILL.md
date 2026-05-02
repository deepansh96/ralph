# Codex Review Slices

Get a second opinion from Codex on a vertical slice breakdown before creating GitHub issues.

Use after /to-issues has proposed a breakdown of a PRD into vertical slices, and the user wants Codex to review it before the issues are created.

## Process

### 1. Gather the review payload

Extract from the current conversation:

- **The PRD or parent issue**: The GitHub issue number or URL containing the full PRD
- **The proposed slice breakdown**: Each slice with its title, type (HITL/AFK), blockers, and description

### 2. Discover context files

Search the repo for files Codex should read. Include only paths that exist:

- `CONTEXT.md` (domain vocabulary)
- `CLAUDE.md` (architecture/conventions)
- `docs/adr/*.md` (architectural decisions)

Also include the to-issues skill file:

- `../to-issues/SKILL.md` (vertical slice methodology)

If a context file doesn't exist in the repo, omit it from the prompt. The skill file is always included.

### 3. Construct the prompt

```
Review this issue breakdown for <PRD issue link>. The PRD is in the issue body. Read the referenced files for full context.

Context files to read:
- <list of discovered context, source, and skill files>

Proposed issues:
<numbered list of slices with title, type, blockers, and brief description>

Review for:
- Are all slices vertical (end-to-end demoable), not horizontal (single layer)?
- Missing work that no slice covers
- Wrong dependency relationships
- Slices that should be split or merged
- Anything that would block an agent from completing a slice independently
- Merge conflict risk (multiple slices touching the same files)
- Clear write boundaries between parallel slices
Keep feedback concise.
```

If the PRD is a GitHub issue, include `gh issue view <number> --repo <owner/repo>` in the prompt so Codex can read it directly.

### 4. Run Codex

Execute `codex exec "<prompt>"` from the repo root. Do NOT use `--full-auto` — Codex needs network access for `gh issue view`. Run in background and notify the user when it finishes.

### 5. Relay feedback

When Codex finishes, summarize the key feedback to the user. Group into:

- **Slice quality**: Any slices flagged as horizontal rather than vertical
- **Gaps**: Missing work or acceptance criteria
- **Dependency issues**: Wrong blockers or missing dependencies
- **Conflict risks**: Parallel slices that would touch the same files
- **Split/merge suggestions**: Slices that are too broad or too thin

Ask the user which feedback to incorporate before creating the GitHub issues via /to-issues.
