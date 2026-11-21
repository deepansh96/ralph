#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR

PROMPT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$PROMPT_SCRIPT_DIR/config.sh"

# Replace every {{NAME}} in the caller's $prompt with VALUE, inserted literally.
# ${prompt//pattern/$value} is not used because bash 5.2's patsub_replacement
# expands "&" in VALUE to the matched text, and quoting VALUE instead leaves
# literal quotes behind on bash 3.2.
prompt_substitute() {
  local token="{{$1}}"
  local value="$2"
  local rest="$prompt"
  local out=""

  while [[ "$rest" == *"$token"* ]]; do
    out+="${rest%%"$token"*}$value"
    rest="${rest#*"$token"}"
  done
  prompt="$out$rest"
}

prompt_native_delegation_contract() {
  local template_file="$1"
  local agent="$2"
  local step_json="$3"
  local contract_file config_file ralph_root defaults prompt
  local subagent_model subagent_reasoning_effort

  contract_file="$(dirname "$template_file")/native-delegation/$agent.md"
  if [[ "$agent" == claude ]] && jq -e 'has("delegation")' <<< "$step_json" >/dev/null; then
    contract_file="$(dirname "$template_file")/native-delegation/claude-agent.md"
  fi
  if [[ ! -f "$contract_file" ]]; then
    echo "Error: native delegation is not configured for agent '$agent'" >&2
    return 1
  fi

  ralph_root="$(cd "$(dirname "$template_file")/.." && pwd)"
  config_file="$ralph_root/ralph.config.json"
  if ! defaults="$(ralph_config_native_delegation_defaults "$config_file" "$agent")"; then
    return 1
  fi

  subagent_model="$(jq -r '.subagentModel // empty' <<<"$step_json")"
  if [[ -z "$subagent_model" ]]; then
    subagent_model="$(jq -r '.model' <<<"$defaults")"
  fi

  subagent_reasoning_effort="$(jq -r '.subagentReasoningEffort // empty' <<<"$step_json")"
  if [[ -z "$subagent_reasoning_effort" ]]; then
    subagent_reasoning_effort="$(jq -r '.reasoningEffort' <<<"$defaults")"
  fi

  prompt="$(<"$contract_file")"
  prompt_substitute SUBAGENT_MODEL "$subagent_model"
  prompt_substitute SUBAGENT_REASONING_EFFORT "$subagent_reasoning_effort"

  printf '%s\n' "$prompt"
}

prompt_render() {
  local template_file="$1"
  local state_file="$2"
  local workspace="$3"
  local step_json="$4"
  local skills_dir="$5"
  local prompt

  if [[ ! -f "$template_file" ]]; then
    echo "Error: prompt template not found: $template_file" >&2
    return 1
  fi

  prompt="$(<"$template_file")"

  local issue repo branch base_branch step_id sub_issue reviewers agent ralph_dir
  local native_delegation_contract
  issue="$(jq -r '.issue // ""' "$state_file")"
  repo="$(jq -r '.repo // ""' "$state_file")"
  branch="$(jq -r '.branch // ""' "$state_file")"
  base_branch="$(jq -r '.baseBranch // ""' "$state_file")"
  step_id="$(jq -r '.id // ""' <<<"$step_json")"
  sub_issue="$(jq -r '.sub_issue // .subIssue // ""' <<<"$step_json")"
  reviewers="$(jq -r '(.reviewers // []) | join(",")' <<<"$step_json")"
  agent="$(jq -r '.agent // ""' <<<"$step_json")"
  ralph_dir="$(cd "$(dirname "$template_file")/.." && pwd)"

  prompt_substitute ISSUE "$issue"
  prompt_substitute REPO "$repo"
  prompt_substitute WORKSPACE "$workspace"
  prompt_substitute BRANCH "$branch"
  prompt_substitute BASE_BRANCH "$base_branch"
  prompt_substitute STEP_ID "$step_id"
  prompt_substitute SUB_ISSUE "$sub_issue"
  prompt_substitute SKILLS_DIR "$skills_dir"
  prompt_substitute REVIEWERS "$reviewers"
  prompt_substitute AGENT "$agent"
  prompt_substitute RALPH_DIR "$ralph_dir"

  if [[ "$prompt" == *'{{NATIVE_DELEGATION_CONTRACT}}'* ]]; then
    if ! native_delegation_contract="$(prompt_native_delegation_contract "$template_file" "$agent" "$step_json")"; then
      return 1
    fi
    prompt_substitute NATIVE_DELEGATION_CONTRACT "$native_delegation_contract"
  fi

  printf '%s\n' "$prompt"
}
