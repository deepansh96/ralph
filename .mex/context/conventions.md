---
name: conventions
description: How code, prompts, tests, and docs are written in Ralph. Load when editing or reviewing repository changes.
triggers:
  - "convention"
  - "pattern"
  - "naming"
  - "style"
  - "prompt"
  - "test"
  - "state"
edges:
  - target: context/architecture.md
    condition: when a convention depends on the pipeline or state flow
  - target: context/stack.md
    condition: when a convention depends on shell, jq, gh, claude, codex, or council
  - target: patterns/change-pipeline-behavior.md
    condition: when editing a step prompt, script helper, or test suite
  - target: patterns/recover-failed-or-stale-step.md
    condition: when changing state recovery or PID behavior
last_updated: 2026-11-21
---

# Conventions

## Naming

- Step types use kebab-case and map directly to `prompts/<step-type>.md`.
- Step IDs are stable strings such as `create-and-review-prd`, `preflight`, or `implement-slice-14`.
- State fields use lower camelCase for JSON keys already in the schema, such as `baseBranch`, `projectRoot`, `createdAt`, and `alwaysRun`.
- Shell functions use snake_case and are grouped by helper file, for example `state_update_step` in `scripts/state.sh`.
- Test suite files end in `_test.sh` and live under `tests/suites/`.
- Workflow vocabulary uses pipeline, step, step type, phase, agent, council, reviewer, PRD, slice, seam, blocking edge, AFK, workspace, state, HITL, map, and frontier as defined in `CONTEXT.md`.

## Structure

- `ralph.sh` owns CLI parsing and the run loop; reusable behavior belongs in `scripts/*.sh`.
- Prompt behavior belongs in `prompts/<step-type>.md`, not in ad hoc shell strings.
- Bundled agent instructions belong in `skills/`, with prompt references pointing at `{{SKILLS_DIR}}`.
- Per-issue generated state, logs, artifacts, HITL flags, and PID files stay under `workspaces/<issue>/`.
- Tests are split by behavior in `tests/suites/` and share helpers/fakes from `tests/lib/test_helpers.sh`.
- Root `AGENTS.md` is the Codex/Claude-loaded anchor; `CLAUDE.md` is a symlink to it for compatibility.

## Patterns

Always mutate `state.json` with `jq`, not string substitution:

```bash
jq --arg id "$step_id" '.steps |= map(if .id == $id then .status = "pending" else . end)' "$state_file"
```

Do not pipe long Ralph runs through stream filters:

```bash
# Correct
./ralph.sh --issue 123

# Wrong
./ralph.sh --issue 123 2>&1 | tail -100
```

Run Codex-owned steps from the project root, not from the Ralph directory:

```bash
(cd "$project_root" && codex -a never exec -C "$project_root" ...)
```

Write GitHub issue outputs to the issue body when downstream steps need to read them:

```bash
gh issue edit "$issue" --repo "$repo" --body-file "$body_file"
```

## Verify Checklist

Before presenting any code or scaffold change:

- [ ] Shell syntax is valid for changed `.sh` files: `bash -n path/to/file.sh`.
- [ ] JSON state or config files validate with `jq . file`.
- [ ] Relevant deterministic tests pass, or the reason they were not run is stated.
- [ ] No long Ralph command is piped through `head`, `tail`, or similar.
- [ ] Any state mutation uses `jq` and preserves existing unrelated fields.
- [ ] Prompt placeholders match names rendered by `scripts/prompt.sh`.
- [ ] Root `CLAUDE.md` still resolves to `AGENTS.md`.
- [ ] mex scaffold changes pass `npx mex-agent check --quiet` or any remaining drift is reported.
