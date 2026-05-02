#!/usr/bin/env bash

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

  local issue repo branch base_branch step_id sub_issue reviewer
  issue="$(jq -r '.issue // ""' "$state_file")"
  repo="$(jq -r '.repo // ""' "$state_file")"
  branch="$(jq -r '.branch // ""' "$state_file")"
  base_branch="$(jq -r '.baseBranch // ""' "$state_file")"
  step_id="$(jq -r '.id // ""' <<<"$step_json")"
  sub_issue="$(jq -r '.sub_issue // .subIssue // ""' <<<"$step_json")"
  reviewer="$(jq -r '.reviewer // ""' <<<"$step_json")"

  prompt="${prompt//\{\{ISSUE\}\}/$issue}"
  prompt="${prompt//\{\{REPO\}\}/$repo}"
  prompt="${prompt//\{\{WORKSPACE\}\}/$workspace}"
  prompt="${prompt//\{\{BRANCH\}\}/$branch}"
  prompt="${prompt//\{\{BASE_BRANCH\}\}/$base_branch}"
  prompt="${prompt//\{\{STEP_ID\}\}/$step_id}"
  prompt="${prompt//\{\{SUB_ISSUE\}\}/$sub_issue}"
  prompt="${prompt//\{\{SKILLS_DIR\}\}/$skills_dir}"
  prompt="${prompt//\{\{REVIEWER\}\}/$reviewer}"

  printf '%s\n' "$prompt"
}
