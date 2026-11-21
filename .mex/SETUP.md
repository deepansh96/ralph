# Setup - mex Scaffold

This mex scaffold is already populated for Ralph.

## Recreate The Scaffold

Run from the repository root:

```bash
npx mex-agent setup
```

Choose `Codex (OpenAI)` when asked which AI tool to configure. If root `AGENTS.md` already exists, mex will skip overwriting it; keep it as the compact anchor that points to `.mex/ROUTER.md`.

## Populate Or Refresh Manually

Use the current codebase as an existing project, even though mex may detect this shell-heavy repo as fresh. Populate:

- `.mex/AGENTS.md`
- `.mex/ROUTER.md`
- `.mex/context/*.md`
- `.mex/patterns/INDEX.md`
- task patterns under `.mex/patterns/`

Only write facts derived from this repository. Do not invent services, commands, dependencies, or release flows.

## Verify

```bash
npx mex-agent check --quiet
./tests/run.sh
```
