#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_init_prompt_defines_complete_workspace_initialization_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/init.md"
  [[ -f "$prompt_file" ]] || fail "expected init prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "command -v gh"
  assert_contains "$prompt" 'Ralph directory (`<ralph-dir>`): the folder that contains this `prompts/init.md`'
  assert_contains "$prompt" "<ralph-dir>/workspaces/{{ISSUE}}"
  [[ "$prompt" != *'`ralph/workspaces/'* && "$prompt" != *'./ralph/ralph.sh'* ]] \
    || fail "expected init prompt to use <ralph-dir> instead of a hardcoded ralph/ install path"
  assert_contains "$prompt" "must not overwrite"
  assert_contains "$prompt" '"baseBranch": null'
  assert_contains "$prompt" '"branch": null'
  assert_contains "$prompt" '"status": "initialized"'
  assert_contains "$prompt" '"phase": "fixed"'
  assert_contains "$prompt" '"metrics": null'
  assert_contains "$prompt" '"reviewers": []'
  assert_contains "$prompt" "review-decisions"
  assert_contains "$prompt" "create-and-review-prd"
  assert_contains "$prompt" "create-and-review-slices"
  assert_contains "$prompt" "preflight"
  assert_contains "$prompt" '"type": "cleanup-local-resources"'
  assert_contains "$prompt" '"alwaysRun": true'
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" "./<ralph-dir>/ralph.sh status --issue {{ISSUE}}"
  assert_contains "$prompt" '"projectRoot"'
  assert_contains "$prompt" "git rev-parse --show-toplevel"
  assert_contains "$prompt" "git status --porcelain"
  assert_contains "$prompt" "working tree"
  assert_contains "$prompt" "grill/*"
  assert_contains "$prompt" "planning branch"
  assert_contains "$prompt" 'default **0**'
  assert_contains "$prompt" "Include review-decisions steps only when the user explicitly opts in"
  assert_contains "$prompt" "If the user opts in without a count, use 1 review-decisions round"
  assert_contains "$prompt" '"reviewRounds": 0'
  assert_contains "$prompt" "Default is 0"
  [[ "$prompt" != *"reviewFixes"* ]] || fail "expected init to omit removed reviewFixes option"
}

test_initialized_workspace_status_shows_default_four_pending_fixed_steps() {
  local issue output pending_count

  issue="9012"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      createdAt: "2026-05-02T00:00:00Z",
      steps: [
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          status: "pending",
          agent: "codex",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          reviewRounds: 0,
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "create-and-review-slices",
          phase: "fixed",
          type: "create-and-review-slices",
          status: "pending",
          agent: "codex",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          reviewRounds: 0,
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          status: "pending",
          agent: "codex",
          reviewers: [],
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "cleanup-local-resources",
          phase: "fixed",
          type: "cleanup-local-resources",
          status: "pending",
          agent: "codex",
          reviewers: [],
          hitl: false,
          alwaysRun: true,
          metrics: null,
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$RALPH" status --issue "$issue")"
  pending_count="$(grep -c "pending" <<<"$output")"

  [[ "$pending_count" == "4" ]] || fail "expected 4 pending steps in status output, got $pending_count: $output"
  assert_contains "$output" "create-and-review-prd"
  assert_contains "$output" "create-and-review-slices"
  assert_contains "$output" "preflight"
  assert_contains "$output" "cleanup-local-resources"
}

test_review_decisions_prompt_defines_council_filtering_and_hitl_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/review-decisions.md"
  [[ -f "$prompt_file" ]] || fail "expected review-decisions prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "\"{{RALPH_DIR}}/scripts/council-review.sh\""
  assert_contains "$prompt" "/tmp/ralph-{{ISSUE}}-issue-body.md"
  assert_contains "$prompt" "rm -f /tmp/ralph-{{ISSUE}}-issue-body.md"
  assert_contains "$prompt" "Major feedback"
  assert_contains "$prompt" "nitpick"
  assert_contains "$prompt" "{{STEP_ID}}.md"
  assert_contains "$prompt" "hitl-{{STEP_ID}}.md"
  assert_contains "$prompt" "complete WITHOUT re-running council review"
}

test_create_prd_prompt_defines_full_prd_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-and-review-prd.md"
  [[ -f "$prompt_file" ]] || fail "expected create-and-review-prd prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "original-issue.md"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "Explore the codebase"
  assert_contains "$prompt" "to-spec"
  assert_contains "$prompt" "seams"
  assert_contains "$prompt" "SEAMS"
  assert_contains "$prompt" "Decision Summary"
  assert_contains "$prompt" "Problem Statement"
  assert_contains "$prompt" "User Stories"
  assert_contains "$prompt" "Implementation Decisions"
  assert_contains "$prompt" "Testing Decisions"
  assert_contains "$prompt" "\"{{RALPH_DIR}}/scripts/council-review.sh\""
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**0 (default):** Skip council review entirely"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 0'
  assert_contains "$prompt" "incorporate"
  assert_contains "$prompt" "Compact"
  assert_contains "$prompt" "gh issue edit {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "idempotent"
}

test_create_slices_prompt_defines_full_slice_creation_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-and-review-slices.md"
  [[ -f "$prompt_file" ]] || fail "expected create-and-review-slices prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "to-tickets"
  assert_contains "$prompt" "tracer bullets"
  assert_contains "$prompt" "horizontal"
  assert_contains "$prompt" "Blocked by"
  assert_contains "$prompt" "dependency order"
  assert_contains "$prompt" "dependencies/blocked_by"
  assert_contains "$prompt" "--method DELETE"
  assert_contains "$prompt" "delete edges no longer declared"
  assert_contains "$prompt" "expand"
  assert_contains "$prompt" "prefactor"
  assert_contains "$prompt" "\"{{RALPH_DIR}}/scripts/council-review.sh\""
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**0 (default):** Skip council review entirely"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 0'
  assert_contains "$prompt" "gh issue create"
  assert_contains "$prompt" "addSubIssue"
  assert_contains "$prompt" "AFK"
  assert_contains "$prompt" "existing sub-issues"
  assert_contains "$prompt" "duplicates"
}

test_preflight_prompt_defines_full_preflight_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/preflight.md"
  [[ -f "$prompt_file" ]] || fail "expected preflight prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "baseBranch"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "clear guidance"
  assert_contains "$prompt" "feat/issue-{{ISSUE}}-<slug>"
  assert_contains "$prompt" "kebab"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "git status --porcelain"
  assert_contains "$prompt" "git ls-remote --exit-code --heads origin {{BASE_BRANCH}}"
  assert_contains "$prompt" "grill/"
  assert_contains "$prompt" "planning branch"
  assert_contains "$prompt" "branch"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "sub-issues"
  assert_contains "$prompt" "state_add_steps"
  assert_contains "$prompt" "topologically"
  assert_contains "$prompt" "implement-slice"
  assert_contains "$prompt" "final-checks"
  assert_contains "$prompt" "pr-creation"
  assert_contains "$prompt" "prepare-qa-checklist"
  assert_contains "$prompt" "runthrough-qa-checklist"
  assert_contains "$prompt" "multi-axis-pr-review"
  assert_contains "$prompt" "source \"{{RALPH_DIR}}/scripts/state.sh\""
  assert_contains "$prompt" "source \"{{RALPH_DIR}}/scripts/config.sh\""
  assert_contains "$prompt" "{{RALPH_DIR}}/ralph.config.json"
  assert_contains "$prompt" "\"{{RALPH_DIR}}/ralph.sh\" status --issue {{ISSUE}}"
  assert_contains "$prompt" "ralph_config_delegated_step_defaults"
  assert_contains "$prompt" "state_snapshot_delegated_step_defaults"
  assert_contains "$prompt" '"delegation": {"schemaVersion": 1, "policy": "pr-review-v1"}'
  assert_contains "$prompt" '`qa-v1`'
  assert_contains "$prompt" '"delegation": {"schemaVersion": 1, "policy": "qa-v1"}'
  assert_contains "$prompt" 'state_backfill_delegation_metadata'
  assert_contains "$prompt" 'runthrough-qa-checklist \
  qa-v1'
  assert_contains "$prompt" 'multi-axis-pr-review \
  pr-review-v1'
  assert_contains "$prompt" 'only on existing pending steps'
  assert_contains "$prompt" 'Never write or edit `delegationAttempt`'
  [[ "$prompt" != *'Do not write or backfill `delegation`'* ]] || fail "expected preflight to activate delegation metadata"

  assert_contains "$prompt" "runthrough-qa-checklist"
  assert_contains "$prompt" "model"
  assert_contains "$prompt" "reasoningEffort"
  assert_contains "$prompt" "subagentModel"
  assert_contains "$prompt" "subagentReasoningEffort"
  assert_contains "$prompt" "fills only missing or empty values"
  assert_contains "$prompt" 'later edits to `ralph.config.json` must not rewrite them'
  assert_contains "$prompt" "cleanup-local-resources"
  assert_contains "$prompt" '"alwaysRun": true'
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" 'If `state.json` has no step with id `cleanup-local-resources`'
  assert_contains "$prompt" $'```json\n[\n{\n  "id": "cleanup-local-resources"'
  assert_contains "$prompt" "Do not modify an existing cleanup step or overwrite an existing ledger"
  [[ "$prompt" != *'"type": "review-slice"'* ]] || fail "expected preflight to omit review-slice"
  [[ "$prompt" != *'"type": "review-fixes"'* ]] || fail "expected preflight to omit review-fixes"
  assert_contains "$prompt" "codex"
  assert_contains "$prompt" "sub_issue"
  assert_contains "$prompt" "idempotent"
}

test_implement_slice_prompt_defines_full_implementation_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/implement-slice.md"
  [[ -f "$prompt_file" ]] || fail "expected implement-slice prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Issue: {{ISSUE}}"
  assert_contains "$prompt" "Repo: {{REPO}}"
  assert_contains "$prompt" "Workspace: {{WORKSPACE}}"
  assert_contains "$prompt" "Branch: {{BRANCH}}"
  assert_contains "$prompt" "Base branch: {{BASE_BRANCH}}"
  assert_contains "$prompt" "Step: {{STEP_ID}}"
  assert_contains "$prompt" "Sub-issue: {{SUB_ISSUE}}"
  assert_contains "$prompt" "Skills: {{SKILLS_DIR}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "AFK"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "tdd/SKILL.md"
  assert_contains "$prompt" "tdd/tests.md"
  assert_contains "$prompt" "tdd/mocking.md"
  assert_contains "$prompt" "issue_dependencies_summary.blocked_by"
  assert_contains "$prompt" "seams"
  assert_contains "$prompt" "tautological"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "gh issue view {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Write one failing test first"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "git checkout {{BRANCH}}"
  assert_contains "$prompt" "git commit"
  assert_contains "$prompt" "#{{SUB_ISSUE}}"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "gh issue close {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "local-resources.json"
}

test_final_checks_prompt_defines_read_only_check_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/final-checks.md"
  [[ -f "$prompt_file" ]] || fail "expected final-checks prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "git diff {{BASE_BRANCH}}...HEAD"
  assert_contains "$prompt" 'quality commands in `CLAUDE.md`'
  assert_contains "$prompt" "acceptance criterion"
  assert_contains "$prompt" "cross-slice integration"
  assert_contains "$prompt" "read-only"
  assert_contains "$prompt" "{{WORKSPACE}}/final-checks.md"
  assert_contains "$prompt" "local-resources.json"
}

test_pr_creation_prompt_defines_idempotent_pr_only_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/pr-creation.md"
  [[ -f "$prompt_file" ]] || fail "expected pr-creation prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "git push -u origin {{BRANCH}}"
  assert_contains "$prompt" "gh pr list"
  assert_contains "$prompt" "--head {{BRANCH}} --state open"
  assert_contains "$prompt" "--json number,url,baseRefName"
  assert_contains "$prompt" "gh pr edit"
  assert_contains "$prompt" "gh pr create"
  assert_contains "$prompt" "If more than one exists"
  assert_contains "$prompt" "same-head PR targets a different"
  assert_contains "$prompt" "defaultBranchRef"
  assert_contains "$prompt" "git merge --no-edit"
  assert_contains "$prompt" "Closes #{{ISSUE}}"
  assert_contains "$prompt" "Closes #<sub-issue>"
  assert_contains "$prompt" "Do not include a review section or QA checklist"
  assert_contains "$prompt" "{{WORKSPACE}}/pr-creation.md"
}

test_prepare_qa_checklist_prompt_defines_local_comment_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/prepare-qa-checklist.md"
  [[ -f "$prompt_file" ]] || fail "expected prepare-qa-checklist prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "whole PR"
  assert_contains "$prompt" "never test a deployed environment"
  assert_contains "$prompt" "stub or local fake"
  assert_contains "$prompt" "remote database"
  assert_contains "$prompt" "local browser"
  assert_contains "$prompt" "<!-- ralph:qa-checklist -->"
  assert_contains "$prompt" "[PENDING]"
  assert_contains "$prompt" "edit it instead of adding another comment"
  assert_contains "$prompt" "Save no checklist"

  # One stable instruction format shared with docs/qa-delegation.md.
  assert_contains "$prompt" "docs/qa-delegation.md"
  assert_contains "$prompt" "- [ ] [PENDING] QA-01: <behavior>"
  assert_contains "$prompt" "two or more digits"
  assert_contains "$prompt" "unique"
  assert_contains "$prompt" 'directly under `<!-- ralph:qa-checklist -->`'
  assert_contains "$prompt" "No other lines"
  assert_contains "$prompt" "Result"
}

test_runthrough_qa_checklist_prompt_defines_execution_and_progress_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/runthrough-qa-checklist.md"
  [[ -f "$prompt_file" ]] || fail "expected runthrough-qa-checklist prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "<!-- ralph:qa-checklist -->"
  assert_contains "$prompt" "todo"
  assert_contains "$prompt" "free local ports"
  assert_contains "$prompt" "Stub all external calls"
  assert_contains "$prompt" "local databases"
  assert_contains "$prompt" 'check out `{{BRANCH}}`'
  assert_contains "$prompt" "actual PR head revision"
  assert_contains "$prompt" "git rev-parse HEAD"
  assert_contains "$prompt" 'empty `git status --porcelain`'
  assert_contains "$prompt" "[PASS]"
  assert_contains "$prompt" "[FAIL]"
  assert_contains "$prompt" "[BLOCKED]"
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" "do not fail this step"
  assert_contains "$prompt" "Agent: {{AGENT}}"
  assert_contains "$prompt" "{{NATIVE_DELEGATION_CONTRACT}}"
  assert_contains "$prompt" "QA orchestrator"
  assert_contains "$prompt" "must not execute checklist"
  assert_contains "$prompt" "items itself"
  assert_contains "$prompt" "Delegate execution of every checklist item"
  assert_contains "$prompt" "dependency-safe group"
  assert_contains "$prompt" "Use multiple top-level workers"
  assert_contains "$prompt" "Do not give the whole checklist to one worker"
  assert_contains "$prompt" "exactly one active worker per attempt"
  assert_contains "$prompt" "Independent read-only checks may run concurrently"
  assert_contains "$prompt" "Run only one resource-mutating worker at a time"
  assert_contains "$prompt" "Workers must not spawn"
  assert_contains "$prompt" "further subagents"
  assert_contains "$prompt" "must not edit GitHub"
  assert_contains "$prompt" "product code"
  assert_contains "$prompt" "checklist item ID and exact item text"
  assert_contains "$prompt" "the action it performed and the behavior it observed"
  assert_contains "$prompt" "Evidence validation is not QA execution"
  assert_contains "$prompt" "must not rerun a command"
  assert_contains "$prompt" "open a browser"
  assert_contains "$prompt" "query a database"
  assert_contains "$prompt" "orchestration operations"
  assert_contains "$prompt" "original checklist order"
  assert_contains "$prompt" "must not replace the missing work by performing"

  # qa-v1 plan timing, packet markers, Codex task naming, progress format.
  assert_contains "$prompt" "Before the first spawn"
  assert_contains "$prompt" "delegation_qa_plan_write {{WORKSPACE}}/state.json {{STEP_ID}} {{REPO}} <comment-id>"
  assert_contains "$prompt" "source \"{{RALPH_DIR}}/scripts/delegation-qa.sh\""
  assert_contains "$prompt" "{{WORKSPACE}}/delegation/{{STEP_ID}}.plan.json"
  assert_contains "$prompt" "Never write, edit, or regenerate the plan"
  assert_contains "$prompt" "RALPH-TASK: <taskId>"
  assert_contains "$prompt" "RALPH-ASSIGNMENT: <assignmentDigest>"
  assert_contains "$prompt" "RALPH-RUN: <run>"
  assert_contains "$prompt" "first three lines"
  assert_contains "$prompt" 'qa_r<run>_<assignment-digest-hex>'
  assert_contains "$prompt" '`spawn_agent` `task_name`'
  # qa-v1 replacements: parent-owned, sequential, never after a completed run.
  assert_contains "$prompt" "The first run of every group is 1"
  assert_contains "$prompt" "failed, stopped, or never finished"
  assert_contains "$prompt" "Stop a run that never finished before replacing it"
  assert_contains "$prompt" "the next run number"
  assert_contains "$prompt" "unchanged taskId and assignmentDigest"
  assert_contains "$prompt" "A completed run cannot be replaced"
  assert_contains "$prompt" "unusable evidence fails this step"
  assert_contains "$prompt" "Ralph never starts a replacement"
  assert_contains "$prompt" "never run two workers for the same group at once"
  [[ "$prompt" != *"Do not relaunch, replace"* ]] || fail "expected QA replacements to be allowed"
  assert_contains "$prompt" "  - Result:"
  assert_contains "$prompt" "  - Evidence:"
  assert_contains "$prompt" "<!-- ralph:qa-summary -->"
  assert_contains "$prompt" "Never change an item's ID, behavior text, or Setup/Action/Expected/Isolation lines"
  [[ "$prompt" != *"may retry or delegate the item"* ]] || fail "expected the broad QA retry wording to be removed"
}

test_multi_axis_pr_review_prompt_defines_four_skill_vote_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/multi-axis-pr-review.md"
  [[ -f "$prompt_file" ]] || fail "expected multi-axis-pr-review prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Agent: {{AGENT}}"
  assert_contains "$prompt" "{{NATIVE_DELEGATION_CONTRACT}}"
  assert_contains "$prompt" "review orchestrator"
  assert_contains "$prompt" "not one of the five review workers"
  assert_contains "$prompt" "exactly five top-level subagents in two flat batches"
  assert_contains "$prompt" "Every worker is a direct"
  assert_contains "$prompt" "no worker may spawn another worker"
  assert_contains "$prompt" "Batch 1"
  assert_contains "$prompt" "these two workers concurrently"
  assert_contains "$prompt" "Matt Standards"
  assert_contains "$prompt" "only its Standards"
  assert_contains "$prompt" "Matt Spec"
  assert_contains "$prompt" "only its Spec"
  assert_contains "$prompt" "Wait for both Matt results"
  assert_contains "$prompt" "batch 2 with these three workers"
  assert_contains "$prompt" "return findings only"
  assert_contains "$prompt" "to the parent"
  assert_contains "$prompt" "replace missing delegated work"
  assert_contains "$prompt" "Do not"
  assert_contains "$prompt" "begin Consolidate"
  assert_contains "$prompt" "five top-level review results"
  assert_contains "$prompt" "matt-pocock-code-review/SKILL.md"
  assert_contains "$prompt" "ponytail-review/SKILL.md"
  assert_contains "$prompt" "run-codex-review/SKILL.md"
  assert_contains "$prompt" "supe-review-code-changes/SKILL.md"
  assert_contains "$prompt" "run-codex-review/scripts/review.mjs"
  assert_contains "$prompt" "git rev-parse HEAD"
  assert_contains "$prompt" "actual PR head revision"
  assert_contains "$prompt" "KEEP"
  assert_contains "$prompt" "DISCARD"
  assert_contains "$prompt" "Deduplicate"
  assert_contains "$prompt" "<!-- ralph:multi-axis-review -->"
  assert_contains "$prompt" "Do not apply"

  # pr-review-v1 identity: exact snake_case task IDs and packet markers.
  assert_contains "$prompt" '`matt_standards`'
  assert_contains "$prompt" '`matt_spec`'
  assert_contains "$prompt" '`ponytail`'
  assert_contains "$prompt" '`isolated_codex`'
  assert_contains "$prompt" '`supe`'
  assert_contains "$prompt" "RALPH-TASK: <task-id>"
  assert_contains "$prompt" "RALPH-RUN: 1"
  assert_contains "$prompt" "first two lines"
  assert_contains "$prompt" '`task_name`'
  assert_contains "$prompt" "exactly once"
  assert_contains "$prompt" "no retries"
  assert_contains "$prompt" "Do not relaunch"
}

test_native_delegation_fragments_stay_policy_free() {
  local fragment
  for fragment in "$ROOT_DIR"/prompts/native-delegation/*.md; do
    if grep -q -e matt_standards -e isolated_codex -e pr-review-v1 -e qa-v1 "$fragment"; then
      fail "expected $fragment to carry no step policy"
    fi
  done
}

test_cleanup_local_resources_prompt_defines_owned_always_run_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/cleanup-local-resources.md"
  [[ -f "$prompt_file" ]] || fail "expected cleanup-local-resources prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "after an earlier step fails"
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" "Docker containers"
  assert_contains "$prompt" "browser or computer-use sessions"
  assert_contains "$prompt" "project worktree"
  assert_contains "$prompt" "Never use"
  assert_contains "$prompt" "ralph-{{ISSUE}}-"
  assert_contains "$prompt" '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}'
  assert_contains "$prompt" "Keep any entry whose resource could not be cleaned"
  [[ "$prompt" != *"Delete the resource ledger"* ]] || fail "expected cleanup to preserve an empty ledger"
  assert_contains "$prompt" 'Do not invoke the post-merge `cleanup.sh`'
  assert_contains "$prompt" "cleanup-local-resources.md"
}

test_removed_review_prompts_are_absent() {
  local name

  for name in review-slice final-review pr-review review-fixes; do
    [[ ! -e "$ROOT_DIR/prompts/$name.md" ]] || fail "expected removed prompt to be absent: $name"
  done
}

test_grill_with_docs_skill_defines_planning_branch_contract() {
  local skill_file skill

  skill_file="$ROOT_DIR/skills/grill-with-docs/SKILL.md"
  [[ -f "$skill_file" ]] || fail "expected grill-with-docs skill at $skill_file"

  skill="$(<"$skill_file")"

  assert_contains "$skill" "git status --short --branch"
  assert_contains "$skill" "git branch --show-current"
  assert_contains "$skill" "refs/remotes/origin/HEAD"
  assert_contains "$skill" "working tree is already dirty"
  assert_contains "$skill" "planning branch"
  assert_contains "$skill" "grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "git checkout -b grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "git push -u origin grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "baseBranch"
  assert_contains "$skill" 'do not run `init` yet'
  assert_contains "$skill" "Facts vs. decisions"
  assert_contains "$skill" "Confirmation gate"
  assert_contains "$skill" "wayfinder"
}

test_grilling_agent_prompt_defines_frontier_only_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/grill/grilling-agent.md"
  [[ -f "$prompt_file" ]] || fail "expected Grilling Agent prompt at $prompt_file"
  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "{{SKILLS_DIR}}/grilling/SKILL.md"
  assert_contains "$prompt" "{{SKILLS_DIR}}/grill-with-docs/SKILL.md"
  assert_contains "$prompt" "{{SKILLS_DIR}}/domain-modeling/SKILL.md"
  assert_contains "$prompt" "Frontier JSON only"
  assert_contains "$prompt" "Never create or switch branches, commit, push, or run \`gh\` write commands"
  assert_contains "$prompt" "Look up facts yourself"
  assert_contains "$prompt" "never replace an answer"
  assert_contains "$prompt" "reopened only through an explicit \`reopens\` entry that names the contradiction"
  assert_contains "$prompt" "[ralph-exchange:<id>]"
}

test_answering_agent_prompt_defines_evidence_and_read_only_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/grill/answering-agent.md"
  [[ -f "$prompt_file" ]] || fail "expected Answering Agent prompt at $prompt_file"
  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "You own every decision"
  assert_contains "$prompt" "Cite evidence for every answer"
  assert_contains "$prompt" "needsHuman"
  assert_contains "$prompt" "Never guess"
  assert_contains "$prompt" "Never create, edit, or delete files"
  assert_contains "$prompt" "Never run Git writes"
  assert_contains "$prompt" "exactly one answer per question ID"
  assert_contains "$prompt" "reopened only through such a contradiction"
  assert_contains "$prompt" "[ralph-exchange:<id>]"
}

test_session_start_fragment_carries_exchange_marker_and_requirement() {
  local prompt

  prompt="$(<"$ROOT_DIR/prompts/grill/session-start.md")"

  assert_contains "$prompt" "[ralph-exchange:{{EXCHANGE_ID}}]"
  assert_contains "$prompt" "{{REQUIREMENT}}"
}

test_exchange_fragments_carry_exchange_marker_and_json_only_reply() {
  local name prompt

  for name in round-frontier round-answers closing-draft closing-review closing-final reemit recover human-input correction; do
    prompt="$(<"$ROOT_DIR/prompts/grill/$name.md")"
    assert_contains "$prompt" "[ralph-exchange:{{EXCHANGE_ID}}]"
    assert_contains "$prompt" "JSON only"
  done
  assert_contains "$(<"$ROOT_DIR/prompts/grill/round-answers.md")" "contradiction"
  assert_contains "$(<"$ROOT_DIR/prompts/grill/closing-final.md")" "there is no further review"
}

test_grill_message_schemas_are_checked_in() {
  local name

  for name in frontier answers summary summary-review; do
    jq -e '.title and .type == "object" and .additionalProperties == false and (.required | index("exchangeId"))' \
      "$ROOT_DIR/prompts/grill/schemas/$name.schema.json" >/dev/null \
      || fail "expected a JSON Schema for $name messages"
  done
}

test_human_grilling_skills_carry_no_automated_grilling_contract() {
  local file

  while IFS= read -r file; do
    ! grep -qE 'ralph-exchange|Answering Agent|Grilling Agent|Frontier JSON|needsHuman' "$file" \
      || fail "expected human-grilling skill to stay unchanged: $file"
  done < <(find "$ROOT_DIR/skills/grill-with-docs" "$ROOT_DIR/skills/grilling" "$ROOT_DIR/skills/quiz-grilling" -type f)
}

test_rendered_step_prompts_resolve_ralph_dir_without_hardcoded_install_paths() {
  local issue workspace state_file custom_root prompt stale_refs step_file source_line

  issue="9087"
  workspace="$WORKSPACES_DIR/$issue"
  # A space and an "&" in the install path catch unquoted snippets and bash 5.2
  # patsub_replacement expanding "&" during placeholder substitution.
  custom_root="$workspace/R&D install/ralph-v2"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$custom_root/prompts/native-delegation"
  state_file="$workspace/state.json"
  jq -n --arg issue "$issue" '{
    issue: ($issue | tonumber),
    repo: "deepansh96/ralph",
    branch: "feat/issue-9087-ralph-dir",
    baseBranch: "main"
  }' > "$state_file"
  cp "$ROOT_DIR/ralph.config.json" "$custom_root/ralph.config.json"
  cp "$ROOT_DIR/prompts/native-delegation/codex.md" "$custom_root/prompts/native-delegation/codex.md"
  for step_file in \
    preflight.md \
    runthrough-qa-checklist.md \
    create-and-review-prd.md \
    create-and-review-slices.md \
    review-decisions.md; do
    cp "$ROOT_DIR/prompts/$step_file" "$custom_root/prompts/$step_file"
  done

  source "$ROOT_DIR/scripts/prompt.sh"

  prompt="$(prompt_render "$custom_root/prompts/preflight.md" "$state_file" "$workspace" '{"id":"preflight","agent":"codex"}' "$custom_root/skills")"
  assert_contains "$prompt" "source \"$custom_root/scripts/state.sh\""
  assert_contains "$prompt" "source \"$custom_root/scripts/config.sh\""
  assert_contains "$prompt" "\"$custom_root/ralph.config.json\""
  assert_contains "$prompt" "\"$custom_root/ralph.sh\" status --issue $issue"
  [[ "$prompt" != *'{{RALPH_DIR}}'* ]] || fail "expected {{RALPH_DIR}} to be rendered in preflight prompt"
  [[ "$prompt" != *'./ralph/'* ]] || fail "expected no hardcoded ./ralph/ path in rendered preflight prompt"

  # The rendered snippet must run as-is from a path with a space and an "&".
  mkdir -p "$custom_root/scripts"
  printf 'RALPH_DIR_PROBE=sourced\n' > "$custom_root/scripts/state.sh"
  source_line="$(grep -m1 '^source .*/scripts/state\.sh"$' <<< "$prompt")"
  [[ -n "$source_line" ]] || fail "expected a rendered source line for state.sh"
  [[ "$(bash -c "$source_line"' && printf %s "$RALPH_DIR_PROBE"')" == "sourced" ]] \
    || fail "expected rendered source line to run from a path with spaces: $source_line"

  prompt="$(prompt_render "$custom_root/prompts/runthrough-qa-checklist.md" "$state_file" "$workspace" '{"id":"runthrough-qa-checklist","agent":"codex"}' "$custom_root/skills")"
  assert_contains "$prompt" "source \"$custom_root/scripts/delegation-qa.sh\""
  [[ "$prompt" != *'{{RALPH_DIR}}'* ]] || fail "expected {{RALPH_DIR}} to be rendered in runthrough-qa-checklist prompt"
  [[ "$prompt" != *'./ralph/'* ]] || fail "expected no hardcoded ./ralph/ path in rendered runthrough-qa-checklist prompt"

  for step_file in review-decisions.md create-and-review-prd.md create-and-review-slices.md; do
    prompt="$(prompt_render "$custom_root/prompts/$step_file" "$state_file" "$workspace" '{"id":"review-step","agent":"codex","reviewers":["codex"]}' "$custom_root/skills")"
    assert_contains "$prompt" "\"$custom_root/scripts/council-review.sh\" --only codex"
    [[ "$prompt" != *'{{RALPH_DIR}}'* ]] || fail "expected {{RALPH_DIR}} to be rendered in $step_file"
    [[ "$prompt" != *'./ralph/'* ]] || fail "expected no hardcoded ./ralph/ path in rendered $step_file"
  done

  stale_refs="$(grep -Rn "ralph-v2" "$ROOT_DIR/prompts" 2>/dev/null || true)"
  [[ -z "$stale_refs" ]] || fail "expected no ralph-v2 install path references in prompts/: $stale_refs"
}

run_test test_init_prompt_defines_complete_workspace_initialization_contract
run_test test_initialized_workspace_status_shows_default_four_pending_fixed_steps
run_test test_review_decisions_prompt_defines_council_filtering_and_hitl_contract
run_test test_create_prd_prompt_defines_full_prd_workflow_contract
run_test test_create_slices_prompt_defines_full_slice_creation_contract
run_test test_preflight_prompt_defines_full_preflight_workflow_contract
run_test test_implement_slice_prompt_defines_full_implementation_workflow_contract
run_test test_final_checks_prompt_defines_read_only_check_contract
run_test test_pr_creation_prompt_defines_idempotent_pr_only_contract
run_test test_prepare_qa_checklist_prompt_defines_local_comment_contract
run_test test_runthrough_qa_checklist_prompt_defines_execution_and_progress_contract
run_test test_multi_axis_pr_review_prompt_defines_four_skill_vote_contract
run_test test_native_delegation_fragments_stay_policy_free
run_test test_cleanup_local_resources_prompt_defines_owned_always_run_contract
run_test test_removed_review_prompts_are_absent
run_test test_grill_with_docs_skill_defines_planning_branch_contract
run_test test_grilling_agent_prompt_defines_frontier_only_contract
run_test test_answering_agent_prompt_defines_evidence_and_read_only_contract
run_test test_session_start_fragment_carries_exchange_marker_and_requirement
run_test test_exchange_fragments_carry_exchange_marker_and_json_only_reply
run_test test_grill_message_schemas_are_checked_in
run_test test_human_grilling_skills_carry_no_automated_grilling_contract
run_test test_rendered_step_prompts_resolve_ralph_dir_without_hardcoded_install_paths

echo "prompt_contracts_test.sh passed"
