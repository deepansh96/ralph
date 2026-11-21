# Ralph

Ralph is a GitHub issue-driven pipeline that grills, plans, implements,
checks, opens a PR, runs local QA, reviews, and cleans local resources for one
feature.

## Start Here

Read `.mex/ROUTER.md` before doing task work. Load only the context and patterns it routes you to.

## Non-Negotiables

- Run Ralph commands from the project root, not from inside `ralph/`.
- Never pipe `ralph.sh --issue N` through `head`, `tail`, or similar commands.
- Treat `workspaces/<issue>/state.json` as the single source of truth.
- Set `.baseBranch` explicitly before preflight.
- Preserve `CLAUDE.md -> AGENTS.md`.

## Planning sessions

Read these before starting, in order. Also read the target project's `CONTEXT.md` and `docs/adr/` if they exist (see `skills/domain-modeling/DOMAIN-AWARENESS.md`).

**Grilling session** (default entry, one-session features):

1. `skills/grill-with-docs/SKILL.md` — the session contract (branch safety, wrap-up issue)
2. `skills/grilling/SKILL.md` — dependency-ordered question rounds (facts from the environment, decisions from the human, confirmation gate)
3. `skills/domain-modeling/SKILL.md` — glossary and ADR discipline
4. `skills/domain-modeling/CONTEXT-FORMAT.md` and `ADR-FORMAT.md` — only when writing those files

**Wayfinder session** (efforts too big for one grilling session):

1. `skills/wayfinder/SKILL.md` — the map, decision-ticket types, chart/work modes, and research fan-out
2. `docs/agents/issue-tracker.md` — the "Wayfinding operations" section (map, tickets, blocking, frontier, claim)
3. `skills/grilling/SKILL.md` and `skills/domain-modeling/SKILL.md` — for naming the destination and grilling tickets
4. `skills/research/SKILL.md` — only when resolving a research ticket
5. `skills/prototype/SKILL.md` — only when resolving a prototype ticket

**Pipeline steps** need no manual reading list: each `prompts/<step-type>.md` names the skill files its agent must read.

## Skill catalog

**Planning entry points:**

- `skills/grill-with-docs/SKILL.md` — grill a feature, update domain docs, and leave a build-ready issue
- `skills/wayfinder/SKILL.md` — map work too large for one grilling session into linked decision tickets

**Supporting skills outside the pipeline:**

- `skills/writing-for-agents/SKILL.md` — model-invoked guidance for writing skills and agent-facing documents
- `skills/codebase-design/SKILL.md` — model-invoked vocabulary and principles for designing deep modules
- `skills/improve-codebase-architecture/SKILL.md` — user-invoked architecture scan, visual report, and grilling flow
- `skills/prototype/SKILL.md` — model-invoked support that builds a throwaway logic or UI prototype as branch-linked evidence
- `skills/wizard/SKILL.md` — model-invoked support that generates an interactive wizard for manual human-only steps
- `skills/quiz-grilling/SKILL.md` — model-invoked browser quiz wrapper for remote grilling rounds with temporary tunnels and owned cleanup
- `skills/wait-what/SKILL.md` — user-invoked re-pitch of the previous response with simpler language and missing context

**Shared planning skills:**

- `skills/grilling/SKILL.md` — resolve a decision tree in rounds of currently answerable questions
- `skills/domain-modeling/SKILL.md` — maintain shared domain language, context documents, and ADRs
- `skills/research/SKILL.md` — investigate a decision-ticket question and leave cited findings

**Ralph pipeline skills:**

- `skills/to-spec/SKILL.md` — turn confirmed decisions into an implementation-ready specification
- `skills/to-tickets/SKILL.md` — split a specification into ordered, independently buildable slices
- `skills/tdd/SKILL.md` — implement slices with a focused red-green test loop
- `skills/matt-pocock-code-review/SKILL.md` — review changes against repository standards and the originating specification
- `skills/ponytail-review/SKILL.md` — find unnecessary complexity and opportunities to delete code
- `skills/run-codex-review/SKILL.md` — run an isolated Codex review through the App Server
- `skills/supe-review-code-changes/SKILL.md` — review correctness, security, compatibility, and test coverage

## Issue tracker

GitHub, via the `gh` CLI. Tracker operations — sub-issues, native blocking edges, wayfinding operations — live in `docs/agents/issue-tracker.md`. Skills resolve the tracker through this pointer; do not hardcode tracker commands elsewhere.

## Commands

- Test: `./tests/run.sh`
- Focused tests: `./tests/run.sh agent pipeline prompt_contracts`
- Run pipeline: `./ralph.sh --issue N`
- Status: `./ralph.sh status --issue N`
- Logs: `./ralph.sh logs --issue N --step step-id`
- Cleanup: `./cleanup.sh N`
- Automated grilling: `./ralph.sh grill start (--issue N | --requirement-file PATH) --grilling-agent claude --answering-agent claude`, then `./ralph.sh grill resume --id ID` (coordinator `scripts/grill.sh`, record store `scripts/grill-record.sh`, adapters `scripts/grill-adapters.sh`, role prompts and message schemas `prompts/grill/`)
- mex drift: `npx mex-agent check --quiet`
