# Ralph Test Suite

Run the full suite from the repository root:

```bash
./tests/run.sh
```

Run one or more suites by name:

```bash
./tests/run.sh prompt_contracts agent
```

`tests/test_ralph_v2.sh` remains as a compatibility wrapper for older commands.

## Suite Map

- `cli_test.sh`: CLI argument validation, status output, logs, and activity snippets.
- `cleanup_test.sh`: workspace archival and cleanup error handling.
- `context_test.sh`: `CONTEXT.md` gate behavior before pipeline execution.
- `agent_test.sh`: Claude, Codex, and DeepSeek/Pi dispatch, retries, metrics, logs, and working directory handling.
- `state_test.sh`: state transitions, dynamic step appends, metrics fields, and stale PID recovery.
- `delegation_test.sh`: shared delegation schemas, safe artifact writes, and fresh invocation preparation.
- `claude_delegation_test.sh`: opt-in Claude hook sanitization, lifecycle correlation, and the fake foreground Agent CLI seam.
- `claude_gate_smoke_test.sh`: the opt-in live Claude gate smoke harness, run with a fake Claude parent and its local `gh` stub: skip/prerequisite exits, VERIFIED and honest OBSERVED passes, and failures on a missing worker, a missing progress edit, or a user-settings change. It never runs the live test.
- `codex_gate_smoke_test.sh`: the opt-in live Codex gate smoke harness, run with a fake Codex parent, a paginating fake App Server, the real JSON-RPC recorder, and the local `gh` stub: skip/prerequisite exits, VERIFIED and honest OBSERVED passes with followed page cursors, and failures on a missing worker, unavailable App Server evidence, or a missing progress edit. It never runs the live test.
- `codex_delegation_test.sh`: opt-in Codex App Server collection through a fake JSON-RPC server: exact read-only requests, pagination, lifecycle, nesting, task identity, and fail-closed evidence.
- `delegation_qa_test.sh`: QA checklist parsing across progress edits, canonical digest vectors, plan writes, exact-comment refetch through a fake `gh`, QA replacement and supersession chains, and every `qa-v1` mismatch code.
- `delegation_gate_test.sh`: end-to-end runner gate through `ralph.sh` with fake Claude hooks, a fake Codex exec/App Server, and fake `gh`: passing PR-review and QA runs for both providers, UNVERIFIED and PROVIDER_FAILED manifests, retry attempt isolation, HITL deferral, fail-closed configuration and artifact errors, interruption cleanup, and unchanged legacy steps.
- `delegation_manifest_test.sh`: provider-neutral manifest assembly, the `pr-review-v1` verifier and its exact mismatch codes, model alias rules, evidence levels, provider-failure manifests, and private atomic manifest writes.
- `pipeline_test.sh`: run-loop behavior, HITL resume, failed-step handling, and simulated workflow steps.
- `background_poll_test.sh`: background wrapper and polling behavior.
- `council_test.sh`: council submit/status/read/cleanup wrapper behavior.
- `runner_test.sh`: suite selection and missing-suite errors for `tests/run.sh`.
- `prompt_render_test.sh`: prompt placeholder rendering and missing-template failures.
- `prompt_contracts_test.sh`: prompt and skill contracts that downstream agents must follow.
- `skill_docs_test.sh`: bundled skill/link integrity and workflow documentation.
- `parse_log_test.sh`: log summarization for Claude, Codex, and Pi JSONL output.
- `grill_test.sh`: `ralph.sh grill` Automated Grilling Sessions against a temporary target repository with a local bare remote and scripted fake `claude`, `codex`, `uuidgen`, and `gh`. The fake `claude` and `codex` share one per-exchange fixture library (`install_grill_fake_common` in `tests/lib/test_helpers.sh`).

Opt-in live checks live in `tests/probes/` and never run from `./tests/run.sh`: the Claude and Codex collection probes (`docs/claude-delegation.md`, `docs/codex-delegation.md`) and the Claude and Codex gate smoke tests (`docs/delegation-gate.md`). Each requires an explicit environment opt-in and real credentials; a missing opt-in, credential, or prerequisite is never a pass.

External tools such as `claude`, `codex`, `pi`, `gh`, and `council` are faked inside the suite. Tests must be deterministic, offline, and safe to run repeatedly.
