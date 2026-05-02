# Codex Review PRD

Get a second opinion from Codex on a module breakdown and test plan before finalizing a PRD.

Use after /to-prd has produced a module breakdown and test plan, and the user wants Codex to review it before the PRD is submitted.

## Process

### 1. Gather the review payload

Extract from the current conversation:

- **Decision summary**: The key decisions made during the design/grilling session (data formats, naming conventions, behavioral rules, what's in/out of scope)
- **Module breakdown**: New modules, modified modules, each module's responsibilities and public interface
- **Test plan**: Which modules to test, what behaviors to verify, testing patterns to follow

### 2. Discover context files

Search the repo for files Codex should read. Include only paths that exist:

- `CONTEXT.md` (domain vocabulary)
- `CLAUDE.md` (architecture/conventions)
- `docs/adr/*.md` (architectural decisions)

Also include skill files:

- `../to-prd/SKILL.md` (PRD template and process)
- `../domain/DOMAIN-AWARENESS.md` (domain awareness rules)

If a context file doesn't exist in the repo, omit it from the prompt. Skill files are always included.

### 3. Construct the prompt

```
Review the following module breakdown for a feature in this project. Read the referenced files for full context, then evaluate whether the breakdown is sound.

Context files to read:
- <list of discovered context and skill files>

Summary of decisions:
<decision summary extracted from conversation>

Proposed module breakdown:
<module breakdown extracted from conversation>

Proposed test plan:
<test plan extracted from conversation>

Review for:
- Missing modules or responsibilities
- Module boundary cleanliness and coupling
- Edge cases or race conditions not addressed
- Interface design quality — are the public interfaces well-defined?
- Would you restructure anything?
Keep feedback concise.
```

### 4. Run Codex

Execute `codex exec '<prompt>' < /dev/null` from the repo root. The `< /dev/null` is required — without it, Codex blocks waiting for stdin input. Do NOT use `--full-auto` — Codex needs network access for any GitHub references. Run in background and notify the user when it finishes.

### 5. Relay feedback

When Codex finishes, summarize the key feedback to the user. Group into:

- **Gaps found**: Missing modules, responsibilities, or edge cases Codex identified
- **Restructuring suggestions**: Changes to module boundaries, interface design, or coupling
- **Confirmations**: Things Codex agreed with (so the user knows what's solid)

Ask the user which feedback to incorporate before the PRD is finalized via /to-prd.
