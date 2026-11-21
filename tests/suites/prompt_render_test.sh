#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_prompt_render_replaces_all_supported_placeholders() {
  local issue workspace state_file template_file prompt

  issue="9046"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  template_file="$workspace/template.md"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      branch: "feat/issue-9046-render",
      baseBranch: "grill/issue-9046-render"
    }' > "$state_file"

  cat > "$template_file" <<'TEMPLATE'
Issue={{ISSUE}}
Repo={{REPO}}
Workspace={{WORKSPACE}}
Branch={{BRANCH}}
Base={{BASE_BRANCH}}
Step={{STEP_ID}}
Sub={{SUB_ISSUE}}
Skills={{SKILLS_DIR}}
Reviewers={{REVIEWERS}}
Agent={{AGENT}}
RalphDir={{RALPH_DIR}}
TEMPLATE

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$template_file" \
      "$state_file" \
      "$workspace" \
      '{"id":"render-step","sub_issue":1234,"reviewers":["codex","gemini"],"agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Issue=9046"
  assert_contains "$prompt" "Repo=deepansh96/ralph"
  assert_contains "$prompt" "Workspace=$workspace"
  assert_contains "$prompt" "Branch=feat/issue-9046-render"
  assert_contains "$prompt" "Base=grill/issue-9046-render"
  assert_contains "$prompt" "Step=render-step"
  assert_contains "$prompt" "Sub=1234"
  assert_contains "$prompt" "Skills=$ROOT_DIR/skills"
  assert_contains "$prompt" "Reviewers=codex,gemini"
  assert_contains "$prompt" "Agent=codex"
  assert_contains "$prompt" "RalphDir=$WORKSPACES_DIR"
}

test_prompt_render_fails_when_template_is_missing() {
  local issue workspace state_file output status

  issue="9047"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9047}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"

  set +e
  output="$(prompt_render "$workspace/missing.md" "$state_file" "$workspace" '{"id":"missing"}' "$ROOT_DIR/skills" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected missing template render to fail with 1, got $status"
  assert_contains "$output" "prompt template not found"
  assert_contains "$output" "$workspace/missing.md"
}

test_prompt_render_injects_codex_native_delegation_contract() {
  local issue workspace state_file prompt

  issue="9048"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9048}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Native Delegation Contract — Codex"
  assert_contains "$prompt" 'model: `gpt-5.6-luna`'
  assert_contains "$prompt" '`reasoning_effort`: `max`'
  assert_contains "$prompt" 'fork_turns: "none"'
  assert_contains "$prompt" "Do not omit any of these"
  assert_contains "$prompt" "every task that the step prompt marks"
  assert_contains "$prompt" "complete task packet"
  assert_contains "$prompt" "dependency order"
  [[ "$prompt" != *'{{NATIVE_DELEGATION_CONTRACT}}'* ]] || fail "expected delegation placeholder to be rendered"
  [[ "$prompt" != *'{{SUBAGENT_MODEL}}'* ]] || fail "expected subagent model placeholder to be rendered"
  [[ "$prompt" != *'{{SUBAGENT_REASONING_EFFORT}}'* ]] || fail "expected subagent effort placeholder to be rendered"
  [[ "$prompt" != *"Native Delegation Contract — Claude Code"* ]] || fail "expected only the Codex delegation contract"
}

test_prompt_render_injects_claude_native_delegation_contract() {
  local issue workspace state_file prompt

  issue="9049"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9049}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"claude"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Native Delegation Contract — Claude Code"
  assert_contains "$prompt" "native dynamic Workflow tool"
  assert_contains "$prompt" 'workflow `agent()` call'
  assert_contains "$prompt" 'model: `sonnet`'
  assert_contains "$prompt" 'effort: `high`'
  assert_contains "$prompt" '`Promise.all`'
  assert_contains "$prompt" "The plain Agent tool"
  assert_contains "$prompt" "cannot set effort per invocation"
  assert_contains "$prompt" "every task that the step prompt marks"
  assert_contains "$prompt" "dependency order"
  assert_contains "$prompt" "complete task packet"
  [[ "$prompt" != *'{{SUBAGENT_MODEL}}'* ]] || fail "expected subagent model placeholder to be rendered"
  [[ "$prompt" != *'{{SUBAGENT_REASONING_EFFORT}}'* ]] || fail "expected subagent effort placeholder to be rendered"
  [[ "$prompt" != *"gpt-5.6-luna"* ]] || fail "expected only the Claude delegation contract"
}

test_native_delegation_contracts_are_step_agnostic() {
  local contract

  for contract in \
    "$ROOT_DIR/prompts/native-delegation/codex.md" \
    "$ROOT_DIR/prompts/native-delegation/claude.md"; do
    [[ -f "$contract" ]] || fail "expected native delegation contract at $contract"
    [[ "$(<"$contract")" != *"Matt"* ]] || fail "expected $contract to be independent of the Matt skill"
    [[ "$(<"$contract")" != *"PR review"* ]] || fail "expected $contract to be independent of PR review"
    [[ "$(<"$contract")" != *"QA"* ]] || fail "expected $contract to be independent of QA"
    assert_contains "$(<"$contract")" "{{SUBAGENT_MODEL}}"
    assert_contains "$(<"$contract")" "{{SUBAGENT_REASONING_EFFORT}}"
    [[ "$(<"$contract")" != *"gpt-5.6-luna"* ]] || fail "expected $contract not to hardcode the Codex worker model"
    [[ "$(<"$contract")" != *'model: `sonnet`'* ]] || fail "expected $contract not to hardcode the Claude worker model"
  done
}

test_ralph_config_defines_native_delegation_defaults() {
  local config_file

  config_file="$ROOT_DIR/ralph.config.json"
  [[ -f "$config_file" ]] || fail "expected Ralph config at $config_file"
  jq -e '.' "$config_file" >/dev/null || fail "expected valid Ralph config JSON"
  [[ "$(jq -r '.agentDefaults.codex.model' "$config_file")" == "gpt-5.6-sol" ]] \
    || fail "expected the Codex main-agent model default"
  [[ "$(jq -r '.agentDefaults.codex.reasoningEffort' "$config_file")" == "medium" ]] \
    || fail "expected the Codex main-agent effort default"
  [[ "$(jq -r '.agentDefaults.claude.model' "$config_file")" == "opus" ]] \
    || fail "expected the Claude main-agent model default"
  [[ "$(jq -r '.agentDefaults.claude.reasoningEffort' "$config_file")" == "medium" ]] \
    || fail "expected the Claude main-agent effort default"
  [[ "$(jq -r '.nativeDelegation.codex.model' "$config_file")" == "gpt-5.6-luna" ]] \
    || fail "expected the Codex subagent model default"
  [[ "$(jq -r '.nativeDelegation.codex.reasoningEffort' "$config_file")" == "max" ]] \
    || fail "expected the Codex subagent effort default"
  [[ "$(jq -r '.nativeDelegation.claude.model' "$config_file")" == "sonnet" ]] \
    || fail "expected the Claude subagent model default"
  [[ "$(jq -r '.nativeDelegation.claude.reasoningEffort' "$config_file")" == "high" ]] \
    || fail "expected the Claude subagent effort default"
}

test_config_resolves_complete_delegated_step_defaults() {
  local config_file defaults

  config_file="$ROOT_DIR/ralph.config.json"
  source "$ROOT_DIR/scripts/config.sh"

  defaults="$(ralph_config_delegated_step_defaults "$config_file" codex)"

  [[ "$(jq -r '.agent' <<<"$defaults")" == "codex" ]] || fail "expected Codex agent"
  [[ "$(jq -r '.model' <<<"$defaults")" == "gpt-5.6-sol" ]] || fail "expected Sol parent"
  [[ "$(jq -r '.reasoningEffort' <<<"$defaults")" == "medium" ]] || fail "expected medium parent effort"
  [[ "$(jq -r '.subagentModel' <<<"$defaults")" == "gpt-5.6-luna" ]] || fail "expected Luna worker"
  [[ "$(jq -r '.subagentReasoningEffort' <<<"$defaults")" == "max" ]] || fail "expected max worker effort"
}

test_step_can_override_native_delegation_defaults() {
  local issue workspace state_file codex_prompt claude_prompt

  issue="9052"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9052}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  codex_prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"codex","subagentModel":"gpt-5.6-terra","subagentReasoningEffort":"high"}' \
      "$ROOT_DIR/skills"
  )"
  claude_prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"claude","subagentModel":"opus","subagentReasoningEffort":"medium"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$codex_prompt" 'model: `gpt-5.6-terra`'
  assert_contains "$codex_prompt" '`reasoning_effort`: `high`'
  [[ "$codex_prompt" != *"gpt-5.6-luna"* ]] || fail "expected the Codex step override to replace the config default"
  assert_contains "$claude_prompt" 'model: `opus`'
  assert_contains "$claude_prompt" 'effort: `medium`'
  [[ "$claude_prompt" != *'model: `sonnet`'* ]] || fail "expected the Claude step override to replace the config default"
}

test_prompt_render_reads_native_delegation_defaults_from_ralph_config() {
  local issue workspace state_file test_root prompt

  issue="9053"
  workspace="$WORKSPACES_DIR/$issue"
  test_root="$workspace/ralph"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$test_root/prompts/native-delegation"
  state_file="$workspace/state.json"
  jq -n '{issue: 9053}' > "$state_file"
  cp "$ROOT_DIR/prompts/runthrough-qa-checklist.md" "$test_root/prompts/runthrough-qa-checklist.md"
  cp "$ROOT_DIR/prompts/native-delegation/codex.md" "$test_root/prompts/native-delegation/codex.md"
  jq -n '{nativeDelegation:{codex:{model:"gpt-5.6-terra",reasoningEffort:"xhigh"}}}' \
    > "$test_root/ralph.config.json"

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$test_root/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" 'model: `gpt-5.6-terra`'
  assert_contains "$prompt" '`reasoning_effort`: `xhigh`'
  [[ "$prompt" != *"gpt-5.6-luna"* ]] || fail "expected rendering to use the colocated Ralph config"
}

test_prompt_render_rejects_incomplete_native_delegation_config() {
  local issue workspace state_file test_root output status

  issue="9054"
  workspace="$WORKSPACES_DIR/$issue"
  test_root="$workspace/ralph"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$test_root/prompts/native-delegation"
  state_file="$workspace/state.json"
  jq -n '{issue: 9054}' > "$state_file"
  cp "$ROOT_DIR/prompts/runthrough-qa-checklist.md" "$test_root/prompts/runthrough-qa-checklist.md"
  cp "$ROOT_DIR/prompts/native-delegation/codex.md" "$test_root/prompts/native-delegation/codex.md"
  jq -n '{nativeDelegation:{codex:{model:"gpt-5.6-terra"}}}' > "$test_root/ralph.config.json"

  source "$ROOT_DIR/scripts/prompt.sh"
  set +e
  output="$(
    prompt_render \
      "$test_root/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"codex"}' \
      "$ROOT_DIR/skills" 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected incomplete native delegation config to fail"
  assert_contains "$output" "native delegation defaults are incomplete for agent 'codex'"
}

test_prompt_render_injects_native_delegation_into_qa() {
  local issue workspace state_file codex_prompt claude_prompt

  issue="9051"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9051}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  codex_prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"
  claude_prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/runthrough-qa-checklist.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"runthrough-qa-checklist","agent":"claude"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$codex_prompt" "Agent: codex"
  assert_contains "$codex_prompt" "Native Delegation Contract — Codex"
  assert_contains "$codex_prompt" "QA orchestrator"
  assert_contains "$claude_prompt" "Agent: claude"
  assert_contains "$claude_prompt" "Native Delegation Contract — Claude Code"
  assert_contains "$claude_prompt" "QA orchestrator"
  [[ "$codex_prompt" != *'{{NATIVE_DELEGATION_CONTRACT}}'* ]] || fail "expected Codex QA delegation placeholder to be rendered"
  [[ "$claude_prompt" != *'{{NATIVE_DELEGATION_CONTRACT}}'* ]] || fail "expected Claude QA delegation placeholder to be rendered"
}

test_prompt_render_rejects_unconfigured_native_delegation_agent() {
  local issue workspace state_file output status

  issue="9050"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9050}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  set +e
  output="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"deepseek"}' \
      "$ROOT_DIR/skills" 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unconfigured delegation agent to fail with 1, got $status"
  assert_contains "$output" "native delegation is not configured for agent 'deepseek'"
}

run_test test_prompt_render_replaces_all_supported_placeholders
run_test test_prompt_render_fails_when_template_is_missing
run_test test_prompt_render_injects_codex_native_delegation_contract
run_test test_prompt_render_injects_claude_native_delegation_contract
run_test test_native_delegation_contracts_are_step_agnostic
run_test test_ralph_config_defines_native_delegation_defaults
run_test test_config_resolves_complete_delegated_step_defaults
run_test test_step_can_override_native_delegation_defaults
run_test test_prompt_render_reads_native_delegation_defaults_from_ralph_config
run_test test_prompt_render_rejects_incomplete_native_delegation_config
run_test test_prompt_render_injects_native_delegation_into_qa
run_test test_prompt_render_rejects_unconfigured_native_delegation_agent

echo "prompt_render_test.sh passed"
