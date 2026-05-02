#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
CONTEXT_FILE="$PROJECT_ROOT/CONTEXT.md"
INITIAL_CONTEXT_BACKUP="$(mktemp)"
INITIAL_CONTEXT_PRESENT="false"
TEST_ISSUES=(9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012 9013 9014 9015 9016 9018 9019 9020)

if [[ -f "$CONTEXT_FILE" ]]; then
  cp "$CONTEXT_FILE" "$INITIAL_CONTEXT_BACKUP"
  INITIAL_CONTEXT_PRESENT="true"
fi

cleanup() {
  local issue

  if [[ "$INITIAL_CONTEXT_PRESENT" == "true" ]]; then
    cp "$INITIAL_CONTEXT_BACKUP" "$CONTEXT_FILE"
  else
    rm -f "$CONTEXT_FILE"
  fi
  rm -f "$INITIAL_CONTEXT_BACKUP"

  for issue in "${TEST_ISSUES[@]}"; do
    rm -rf "${WORKSPACES_DIR:?}/$issue"
  done
  rm -rf "${WORKSPACES_DIR:?}/fake-bin"
}

trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"actual: $haystack"
}

backup_context_once() {
  mkdir -p "$WORKSPACES_DIR"
}

remove_context() {
  backup_context_once
  rm -f "$CONTEXT_FILE"
}

write_valid_context() {
  backup_context_once
  cat > "$CONTEXT_FILE" <<'CONTEXT'
# Ralph

Ralph is an autonomous coding agent orchestrator.

## Language

**Pipeline**:
An ordered set of steps Ralph runs for one GitHub issue.
_Avoid_: Loop

**Step**:
A resumable unit of pipeline work tracked in state.json.
_Avoid_: Iteration

## Relationships

- A **Pipeline** contains one or more **Steps**
- A **Step** belongs to exactly one **Pipeline**

## Example dialogue

> **Dev:** "Can I restart the **Pipeline** after a failed **Step**?"
> **Domain expert:** "Yes, reset the **Step** status and rerun Ralph."

## Flagged ambiguities

- "iteration" means the v1 loop; v2 uses **Step**.
CONTEXT
}

write_insufficient_context() {
  backup_context_once
  cat > "$CONTEXT_FILE" <<'CONTEXT'
# Ralph

Intentionally incomplete fixture.
CONTEXT
}

write_single_step_state() {
  local issue="$1"
  local step_id="$2"
  local status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg id "$step_id" \
    --arg status "$status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: $id,
          type: "stub",
          agent: "stub",
          status: $status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

write_two_step_state() {
  local issue="$1"
  local first_status="$2"
  local second_status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg first_status "$first_status" \
    --arg second_status "$second_status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "first-step",
          type: "stub",
          agent: "stub",
          status: $first_status,
          metrics: { duration: "1s" },
          notes: ""
        },
        {
          id: "second-step",
          type: "stub",
          agent: "stub",
          status: $second_status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

install_fake_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

jq -n --arg prompt "$prompt" '{
  result: (
    if ($prompt | contains("CONTEXT_CHECK_REQUIRED")) then
      "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."
    else
      "claude saw: " + $prompt
    end
  ),
  duration_ms: 1234,
  usage: {
    input_tokens: 11,
    output_tokens: 7
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_context_check_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"Intentionally incomplete fixture"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: FAIL\nMissing required sections: Language, Relationships, Example dialogue, Flagged ambiguities.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
else
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
fi
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_interrupt_once_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

marker="$(dirname "$0")/interrupted-once"
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

if [[ ! -f "$marker" ]]; then
  touch "$marker"
  kill -INT "$PPID"
  sleep 1
  exit 130
fi

jq -n '{
  result: "completed after interrupt",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_hitl_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace / { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step / { print $2; exit }' <<<"$prompt")"
state_file="$workspace/state.json"
flag_file="$workspace/hitl-$step_id.md"

if [[ "$prompt" == *"This step was previously blocked for human input"* ]]; then
  [[ "$prompt" == *"Use the reviewed option"* ]] || exit 41
  [[ "$prompt" == *"Do not repeat any council or review phase"* ]] || exit 42
  jq -n --arg prompt "$prompt" '{
    result: ("resumed with: " + $prompt),
    duration_ms: 222,
    usage: {
      input_tokens: 3,
      output_tokens: 2
    },
    total_cost_usd: 0.03
  }'
  exit 0
fi

jq --arg id "$step_id" '
  .steps |= map(if .id == $id then .status = "blocked" else . end)
' "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

cat > "$flag_file" <<'FLAG'
## Questions

Which option should the review continue with?

## Answers
FLAG

jq -n '{
  result: "blocked for human input",
  duration_ms: 111,
  usage: {
    input_tokens: 2,
    output_tokens: 1
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_review_decisions_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"
state_file="$workspace/state.json"
flag_file="$workspace/hitl-$step_id.md"
findings_file="$workspace/review-decisions.md"

if [[ "$prompt" == *"This step was previously blocked for human input"* ]]; then
  [[ "$prompt" == *"complete WITHOUT re-running council review"* ]] || exit 51
  [[ "$prompt" == *"Use the architecture option"* ]] || exit 52
  jq -n --arg prompt "$prompt" '{
    result: ("completed without rerunning council: " + $prompt),
    duration_ms: 222,
    usage: {
      input_tokens: 3,
      output_tokens: 2
    },
    total_cost_usd: 0.03
  }'
  exit 0
fi

[[ "$prompt" == *"scripts/council-review.sh"* ]] || exit 61
[[ "$prompt" == *"Major feedback"* ]] || exit 62
[[ "$prompt" == *"nitpicks"* ]] || exit 63
[[ "$prompt" == *"review-decisions.md"* ]] || exit 64

cat > "$findings_file" <<'FINDINGS'
# Review Decisions

## Major feedback

- Major issue: baseBranch must be explicit before preflight.

## Open questions

- Which architecture option should Ralph use?
FINDINGS

jq --arg id "$step_id" '
  .steps |= map(if .id == $id then .status = "blocked" else . end)
' "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

cat > "$flag_file" <<'FLAG'
## Questions

Which architecture option should Ralph use?

## Answers
FLAG

jq -n '{
  result: "blocked after review-decisions council feedback",
  duration_ms: 111,
  usage: {
    input_tokens: 2,
    output_tokens: 1
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_create_prd_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
original_file="$workspace/original-issue.md"
issue_body_file="$workspace/github-issue-body.md"

[[ "$prompt" == *"gh issue view"* ]] || exit 71
[[ "$prompt" == *"--repo"* ]] || exit 70
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 72
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 73
[[ "$prompt" == *"docs/adr"* ]] || exit 74
[[ "$prompt" == *"Explore the codebase"* ]] || exit 75
[[ "$prompt" == *"to-prd"* ]] || exit 76
[[ "$prompt" == *"Round 1"* ]] || exit 77
[[ "$prompt" == *"Round 2"* ]] || exit 78
[[ "$prompt" == *"gh issue edit"* ]] || exit 79
[[ "$prompt" == *"Do not append a second PRD"* ]] || exit 80

if [[ ! -f "$original_file" ]]; then
  printf 'Original grilled issue body\n' > "$original_file"
fi

cat > "$issue_body_file" <<'PRD'
## Decision Summary

- Workflow: create-prd preserves original issue body and updates the issue with one PRD.

## Problem Statement

The pipeline needs a PRD before slice planning can begin.

## Solution

Create a reviewed PRD from the grilled issue decisions.

## User Stories

1. As a developer, I want the create-prd step to update the existing issue, so that the issue remains the source of truth.

## Implementation Decisions

- Prompt-driven workflow: The agent performs issue reading, review, preservation, and update.

## Testing Decisions

- Test through the Ralph pipeline and prompt contract.

## Out of Scope

- Slice creation and preflight.

## Further Notes

- Re-runs replace this body instead of appending another PRD.
PRD

jq -n '{
  result: "create-prd preserved original and updated issue body",
  duration_ms: 333,
  usage: {
    input_tokens: 5,
    output_tokens: 4
  },
  total_cost_usd: 0.04
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_create_slices_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
slices_file="$workspace/slices.md"
sub_issues_file="$workspace/github-sub-issues.md"

[[ "$prompt" == *"gh issue view"* ]] || exit 81
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 82
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 83
[[ "$prompt" == *"docs/adr"* ]] || exit 84
[[ "$prompt" == *"to-issues"* ]] || exit 85
[[ "$prompt" == *"tracer bullets"* ]] || exit 86
[[ "$prompt" == *"Round 1"* ]] || exit 87
[[ "$prompt" == *"Round 2"* ]] || exit 88
[[ "$prompt" == *"gh issue create"* ]] || exit 89
[[ "$prompt" == *"addSubIssue"* ]] || exit 90
[[ "$prompt" == *"AFK"* ]] || exit 91
[[ "$prompt" == *"duplicates"* ]] || exit 92

if [[ ! -f "$sub_issues_file" ]]; then
  cat > "$sub_issues_file" <<'ISSUES'
# Created Sub-Issues

- #9101 Slice: prompt contract (AFK: true, linked via addSubIssue)
- #9102 Slice: idempotent creation (AFK: true, linked via addSubIssue)
ISSUES
fi

cat > "$slices_file" <<'SLICES'
# Slices

## Created or reused sub-issues

- #9101 newly created and linked
- #9102 newly created and linked
SLICES

jq -n '{
  result: "create-slices created AFK sub-issues and linked them under parent",
  duration_ms: 444,
  usage: {
    input_tokens: 6,
    output_tokens: 5
  },
  total_cost_usd: 0.05
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_failing_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  jq -n '{
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

echo "agent failed deliberately" >&2
exit 42
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_codex() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
if [[ -n "$last_message_file" ]]; then
  printf 'codex saw: %s\n' "$prompt" > "$last_message_file"
fi

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

jq -n '{
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_implement_slice_codex() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
[[ "$prompt" == *"Issue: 9020"* ]] || exit 101
[[ "$prompt" == *"Repo: deepansh96/ralph"* ]] || exit 102
[[ "$prompt" == *"Workspace: "*"/ralph-v2/workspaces/9020"* ]] || exit 103
[[ "$prompt" == *"Branch: feat/issue-9020-implementation-workflow"* ]] || exit 104
[[ "$prompt" == *"Base branch: main"* ]] || exit 105
[[ "$prompt" == *"Step: implement-slice-9111"* ]] || exit 106
[[ "$prompt" == *"Sub-issue: 9111"* ]] || exit 107
[[ "$prompt" == *"Skills: "*"/ralph-v2/skills"* ]] || exit 108
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 109
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 110
[[ "$prompt" == *"docs/adr"* ]] || exit 111
[[ "$prompt" == *"tdd/SKILL.md"* ]] || exit 112
[[ "$prompt" == *"tdd/tests.md"* ]] || exit 113
[[ "$prompt" == *"tdd/mocking.md"* ]] || exit 114
[[ "$prompt" == *"tdd/deep-modules.md"* ]] || exit 115
[[ "$prompt" == *"tdd/interface-design.md"* ]] || exit 116
[[ "$prompt" == *"tdd/refactoring.md"* ]] || exit 117
[[ "$prompt" == *"gh issue view 9020 --repo deepansh96/ralph"* ]] || exit 118
[[ "$prompt" == *"gh issue view 9111 --repo deepansh96/ralph"* ]] || exit 119
[[ "$prompt" == *"Write one failing test first"* ]] || exit 120
[[ "$prompt" == *"Run quality checks from CLAUDE.md"* ]] || exit 121
[[ "$prompt" == *"git checkout feat/issue-9020-implementation-workflow"* ]] || exit 122
[[ "$prompt" == *"git commit"* ]] || exit 123
[[ "$prompt" == *"#9111"* ]] || exit 124
[[ "$prompt" == *"git push"* ]] || exit 125
[[ "$prompt" == *"gh issue close 9111 --repo deepansh96/ralph"* ]] || exit 126
[[ "$prompt" == *"agent: codex"* ]] || exit 127
[[ "$prompt" == *"AFK"* ]] || exit 128

if [[ -n "$last_message_file" ]]; then
  printf 'implemented, committed, pushed, and closed sub-issue\n' > "$last_message_file"
fi

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":21,"output_tokens":34}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

jq -n '{
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_council_success() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
status_file="$(dirname "$0")/council-status-count"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-123","members":["codex"],"dataDir":".council/run-123"}'
    ;;
  status)
    count=0
    [[ -f "$status_file" ]] && count="$(<"$status_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$status_file"
    if [[ "$count" -lt 2 ]]; then
      printf '%s\n' '{"run_id":"run-123","running":true,"members":{"codex":{"status":"working","bytes":0,"elapsed_seconds":1}}}'
    else
      printf '%s\n' '{"run_id":"run-123","running":false,"members":{"codex":{"status":"done","exit_code":0,"bytes":10,"elapsed_seconds":2}}}'
    fi
    ;;
  read)
    printf '%s\n' '{"run_id":"run-123","members":{"codex":{"status":"done","exit_code":0,"output":"Major issue: baseBranch is still null before preflight."}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

install_fake_council_failure() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-456","members":["codex"],"dataDir":".council/run-456"}'
    ;;
  status)
    printf '%s\n' '{"run_id":"run-456","running":false,"members":{"codex":{"status":"failed","exit_code":42,"bytes":0,"elapsed_seconds":2}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

install_fake_council_timeout() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-789","members":["codex"],"dataDir":".council/run-789"}'
    ;;
  status)
    printf '%s\n' '{"run_id":"run-789","running":true,"members":{"codex":{"status":"working","bytes":0,"elapsed_seconds":2}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

test_issue_must_be_positive_integer() {
  local output status

  set +e
  output="$("$RALPH" --issue nope 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid issue to fail"
  assert_contains "$output" "--issue must be a positive integer"
}

test_run_requires_existing_state() {
  local issue output status

  issue="9001"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing state to fail"
  assert_contains "$output" "state.json not found"
  assert_contains "$output" "run init.md first"
}

test_run_rejects_failed_steps() {
  local issue output status

  issue="9002"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "failed"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected failed step pre-check to fail"
  assert_contains "$output" "failed steps"
  assert_contains "$output" "set status to pending or completed"
}

test_run_hard_stops_when_context_missing() {
  local issue output status status_value

  issue="9013"
  remove_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  assert_contains "$output" "CONTEXT.md not found"
  assert_contains "$output" "$CONTEXT_FILE"
}

test_run_hard_stops_when_context_is_insufficient() {
  local issue output status status_value fake_bin log_file

  issue="9014"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_insufficient_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_context_check_claude "$fake_bin"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected insufficient CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  log_file="$WORKSPACES_DIR/$issue/logs/check-context.log"
  [[ -f "$log_file" ]] || fail "expected context check log file"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

test_run_completes_pending_agent_step() {
  local issue status_value log_file fake_bin

  issue="9003"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9003-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected agent step to be completed, got $status_value"

  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"
  [[ -f "$log_file" ]] || fail "expected agent step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw"
}

test_status_prints_step_table() {
  local issue output

  issue="9004"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "in_progress"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "#"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "Type"
  assert_contains "$output" "Agent"
  assert_contains "$output" "Status"
  assert_contains "$output" "Duration"
  assert_contains "$output" "stub-step"
  assert_contains "$output" "stub"
  assert_contains "$output" "in_progress"
}

test_logs_tails_active_step_log() {
  local issue output

  issue="9005"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "active log line\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"
  printf "old log line\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"

  output="$("$RALPH" logs --issue "$issue")"

  assert_contains "$output" "active log line"
  [[ "$output" != *"old log line"* ]] || fail "expected active logs to exclude inactive step log"
}

test_logs_tails_specific_step_log() {
  local issue output

  issue="9006"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "specific completed log\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"
  printf "active log\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"

  output="$("$RALPH" logs --issue "$issue" --step first-step)"

  assert_contains "$output" "specific completed log"
  [[ "$output" != *"active log"* ]] || fail "expected --step logs to exclude active step log"
}

test_claude_agent_step_renders_prompt_logs_metrics_and_summary() {
  local issue output fake_bin log_file status_value duration_value input_tokens cost_value

  issue="9007"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9007-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          sub_issue: 77,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  duration_value="$(jq -r '.steps[0].metrics.duration_ms' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected claude step to complete, got $status_value"
  [[ "$duration_value" == "1234" ]] || fail "expected duration_ms metric, got $duration_value"
  [[ "$input_tokens" == "11" ]] || fail "expected input_tokens metric, got $input_tokens"
  [[ "$cost_value" == "0.02" ]] || fail "expected cost_usd metric, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected claude step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw: Issue 9007"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Repo deepansh96/ralph"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Workspace $WORKSPACES_DIR/$issue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Branch feat/issue-9007-fixture"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Base main"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Step claude-step"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Sub 77"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Skills $ROOT_DIR/skills"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "claude-step"
  assert_contains "$output" "completed"
  assert_contains "$output" "1234"
}

test_codex_agent_step_logs_jsonl_and_records_metrics() {
  local issue output fake_bin log_file status_value input_tokens output_tokens cost_value

  issue="9008"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9008-fixture",
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/codex-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ "$input_tokens" == "13" ]] || fail "expected codex input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "8" ]] || fail "expected codex output_tokens metric, got $output_tokens"
  [[ "$cost_value" == "null" ]] || fail "expected codex cost_usd to be null, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected codex step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "codex-step"
  assert_contains "$output" "codex"
}

test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up() {
  local issue output fake_bin status first_status second_status

  issue="9009"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_interrupt_once_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9009-fixture",
      steps: [
        {
          id: "interruptible-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected SIGINT handler to exit cleanly, got $status: $output"
  first_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$first_status" == "pending" ]] || fail "expected interrupted step to reset to pending, got $first_status"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null
  second_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$second_status" == "completed" ]] || fail "expected rerun to complete same step, got $second_status"
}

test_blocked_step_stops_then_resumes_with_human_answers() {
  local issue output fake_bin flag_file status_value log_file

  issue="9010"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_hitl_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9010-fixture",
      steps: [
        {
          id: "review-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"
  flag_file="$WORKSPACES_DIR/$issue/hitl-review-step.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected step to remain blocked, got $status_value"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$output" "$flag_file"

  printf "\nUse the reviewed option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-step.log"
  [[ "$status_value" == "completed" ]] || fail "expected answered HITL step to complete, got $status_value"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "resumed with"
}

test_failed_agent_invocation_marks_step_failed_and_exits_one() {
  local issue output fake_bin status status_value

  issue="9011"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_failing_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9011-fixture",
      steps: [
        {
          id: "failing-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected failed agent to make ralph exit 1, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "failed" ]] || fail "expected failed agent step to be marked failed, got $status_value"
}

test_init_prompt_defines_complete_workspace_initialization_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/init.md"
  [[ -f "$prompt_file" ]] || fail "expected init prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "command -v gh"
  assert_contains "$prompt" "workspaces/{{ISSUE}}"
  assert_contains "$prompt" "must not overwrite"
  assert_contains "$prompt" '"baseBranch": null'
  assert_contains "$prompt" '"branch": null'
  assert_contains "$prompt" '"status": "initialized"'
  assert_contains "$prompt" '"phase": "fixed"'
  assert_contains "$prompt" '"metrics": null'
  assert_contains "$prompt" '"reviewer": null'
  assert_contains "$prompt" "review-decisions"
  assert_contains "$prompt" "create-prd"
  assert_contains "$prompt" "create-slices"
  assert_contains "$prompt" "preflight"
  assert_contains "$prompt" "ralph.sh status --issue {{ISSUE}}"
}

test_initialized_workspace_status_shows_four_pending_fixed_steps() {
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
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: true,
          metrics: null,
          notes: ""
        },
        {
          id: "create-prd",
          phase: "fixed",
          type: "create-prd",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "create-slices",
          phase: "fixed",
          type: "create-slices",
          status: "pending",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          status: "pending",
          agent: "claude",
          reviewer: null,
          hitl: false,
          metrics: null,
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$RALPH" status --issue "$issue")"
  pending_count="$(grep -c "pending" <<<"$output")"

  [[ "$pending_count" == "4" ]] || fail "expected 4 pending steps in status output, got $pending_count: $output"
  assert_contains "$output" "review-decisions"
  assert_contains "$output" "create-prd"
  assert_contains "$output" "create-slices"
  assert_contains "$output" "preflight"
}

test_council_review_submits_polls_reads_cleans_up_and_prints_review() {
  local fake_bin output calls

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_success "$fake_bin"

  output="$(printf 'Review these decisions' | PATH="$fake_bin:$PATH" RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh")"
  calls="$(<"$fake_bin/council-calls")"

  assert_contains "$output" "Major issue: baseBranch is still null"
  assert_contains "$calls" "ask"
  assert_contains "$calls" "status"
  assert_contains "$calls" "read"
  assert_contains "$calls" "cleanup"
}

test_council_review_handles_member_failure_and_cleans_up() {
  local fake_bin output calls status

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_failure "$fake_bin"

  set +e
  output="$(PATH="$fake_bin:$PATH" RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh" "Review these decisions" 2>&1)"
  status=$?
  set -e
  calls="$(<"$fake_bin/council-calls")"

  [[ "$status" -ne 0 ]] || fail "expected failed council member to fail"
  assert_contains "$output" "council member failed"
  assert_contains "$calls" "cleanup"
}

test_council_review_handles_timeout_and_cleans_up() {
  local fake_bin output calls status

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_timeout "$fake_bin"

  set +e
  output="$(PATH="$fake_bin:$PATH" RALPH_COUNCIL_TIMEOUT_SECONDS=0 RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh" "Review these decisions" 2>&1)"
  status=$?
  set -e
  calls="$(<"$fake_bin/council-calls")"

  [[ "$status" -ne 0 ]] || fail "expected council timeout to fail"
  assert_contains "$output" "timed out"
  assert_contains "$calls" "cleanup"
}

test_review_decisions_prompt_defines_council_filtering_and_hitl_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/review-decisions.md"
  [[ -f "$prompt_file" ]] || fail "expected review-decisions prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Major feedback"
  assert_contains "$prompt" "nitpicks"
  assert_contains "$prompt" "review-decisions.md"
  assert_contains "$prompt" "hitl-{{STEP_ID}}.md"
  assert_contains "$prompt" "complete WITHOUT re-running council review"
}

test_create_prd_prompt_defines_full_prd_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-prd.md"
  [[ -f "$prompt_file" ]] || fail "expected create-prd prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "original-issue.md"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "Explore the codebase"
  assert_contains "$prompt" "to-prd"
  assert_contains "$prompt" "Decision Summary"
  assert_contains "$prompt" "Problem Statement"
  assert_contains "$prompt" "User Stories"
  assert_contains "$prompt" "Implementation Decisions"
  assert_contains "$prompt" "Testing Decisions"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "incorporate"
  assert_contains "$prompt" "Compact"
  assert_contains "$prompt" "gh issue edit {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "idempotent"
}

test_create_slices_prompt_defines_full_slice_creation_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-slices.md"
  [[ -f "$prompt_file" ]] || fail "expected create-slices prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "to-issues"
  assert_contains "$prompt" "tracer bullets"
  assert_contains "$prompt" "horizontal"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
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

  assert_contains "$prompt" "git status --porcelain"
  assert_contains "$prompt" "working tree"
  assert_contains "$prompt" "baseBranch"
  assert_contains "$prompt" "clear guidance"
  assert_contains "$prompt" "feat/issue-{{ISSUE}}-<slug>"
  assert_contains "$prompt" "kebab"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "branch"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "sub-issues"
  assert_contains "$prompt" "state_add_steps"
  assert_contains "$prompt" "implement-slice"
  assert_contains "$prompt" "final-review"
  assert_contains "$prompt" "pr-review"
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
  assert_contains "$prompt" "agent: codex"
  assert_contains "$prompt" "AFK"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "tdd/SKILL.md"
  assert_contains "$prompt" "tdd/tests.md"
  assert_contains "$prompt" "tdd/mocking.md"
  assert_contains "$prompt" "tdd/deep-modules.md"
  assert_contains "$prompt" "tdd/interface-design.md"
  assert_contains "$prompt" "tdd/refactoring.md"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "gh issue view {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Write one failing test first"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "git checkout {{BRANCH}}"
  assert_contains "$prompt" "git commit"
  assert_contains "$prompt" "#{{SUB_ISSUE}}"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "gh issue close {{SUB_ISSUE}} --repo {{REPO}}"
}

test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates() {
  local issue state_file duplicate_output status ids agents sub_issues output

  issue="9019"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9019-fixture",
      steps: [
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          agent: "claude",
          reviewer: null,
          hitl: false,
          status: "completed",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  state_add_steps "$state_file" '[
    {
      "id": "implement-slice-9101",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewer": null,
      "hitl": false,
      "status": "pending",
      "sub_issue": 9101,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "implement-slice-9102",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewer": null,
      "hitl": false,
      "status": "pending",
      "sub_issue": 9102,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "final-review",
      "phase": "dynamic",
      "type": "final-review",
      "agent": "claude",
      "reviewer": null,
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    },
    {
      "id": "pr-review",
      "phase": "dynamic",
      "type": "pr-review",
      "agent": "claude",
      "reviewer": null,
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    }
  ]'

  ids="$(jq -r '.steps[].id' "$state_file" | tr '\n' ' ')"
  agents="$(jq -r '.steps[] | select(.phase == "dynamic") | "\(.type):\(.agent)"' "$state_file" | tr '\n' ' ')"
  sub_issues="$(jq -r '.steps[] | select(.type == "implement-slice") | .sub_issue' "$state_file" | tr '\n' ' ')"

  assert_contains "$ids" "preflight implement-slice-9101 implement-slice-9102 final-review pr-review"
  assert_contains "$agents" "implement-slice:codex"
  assert_contains "$agents" "final-review:claude"
  assert_contains "$agents" "pr-review:claude"
  assert_contains "$sub_issues" "9101 9102"

  output="$("$RALPH" status --issue "$issue")"
  assert_contains "$output" "implement-slice-9101"
  assert_contains "$output" "implement-slice-9102"
  assert_contains "$output" "final-review"
  assert_contains "$output" "pr-review"

  set +e
  duplicate_output="$(state_add_steps "$state_file" '[{"id":"implement-slice-9101","phase":"dynamic","type":"implement-slice","agent":"codex","status":"pending"}]' 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected duplicate dynamic step id to fail"
  assert_contains "$duplicate_output" "duplicate step id"
  [[ "$(jq '.steps | length' "$state_file")" == "5" ]] || fail "expected duplicate failure not to append steps"
}

test_review_decisions_runs_after_context_check_and_blocks_then_resumes() {
  local issue fake_bin output flag_file findings_file status_value log_file status

  issue="9015"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_review_decisions_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewer: "codex",
          hitl: true,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "expected review-decisions first run to block cleanly, got $status: $output"
  flag_file="$WORKSPACES_DIR/$issue/hitl-review-decisions.md"
  findings_file="$WORKSPACES_DIR/$issue/review-decisions.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected review-decisions to block, got $status_value"
  [[ -f "$WORKSPACES_DIR/$issue/logs/check-context.log" ]] || fail "expected context check log file"
  [[ -f "$findings_file" ]] || fail "expected review-decisions findings file"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$(<"$findings_file")" "Major issue"
  [[ "$(<"$findings_file")" != *"nitpick"* ]] || fail "expected findings to filter nitpicks"

  printf "\nUse the architecture option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-decisions.log"
  [[ "$status_value" == "completed" ]] || fail "expected review-decisions to complete after answers, got $status_value"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "completed without rerunning council"
}

test_create_prd_pipeline_preserves_original_and_updates_single_prd_body() {
  local issue fake_bin original_file issue_body_file status_value log_file decision_count problem_count

  issue="9016"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_create_prd_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewer: "codex",
          hitl: true,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-prd",
          phase: "fixed",
          type: "create-prd",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  original_file="$WORKSPACES_DIR/$issue/original-issue.md"
  issue_body_file="$WORKSPACES_DIR/$issue/github-issue-body.md"
  log_file="$WORKSPACES_DIR/$issue/logs/create-prd.log"
  status_value="$(jq -r '.steps[1].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-prd to complete, got $status_value"
  [[ -f "$original_file" ]] || fail "expected original issue body to be preserved"
  [[ -f "$issue_body_file" ]] || fail "expected issue body fixture to be updated"
  assert_contains "$(<"$original_file")" "Original grilled issue body"
  assert_contains "$(<"$issue_body_file")" "## Decision Summary"
  assert_contains "$(<"$issue_body_file")" "## Problem Statement"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "create-prd preserved original"

  jq '.steps[1].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"
  printf 'Original grilled issue body\nHuman note that must stay preserved\n' > "$original_file"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  assert_contains "$(<"$original_file")" "Human note that must stay preserved"
  decision_count="$(grep -c '^## Decision Summary$' "$issue_body_file")"
  problem_count="$(grep -c '^## Problem Statement$' "$issue_body_file")"
  [[ "$decision_count" == "1" ]] || fail "expected one Decision Summary after rerun, got $decision_count"
  [[ "$problem_count" == "1" ]] || fail "expected one Problem Statement after rerun, got $problem_count"
}

test_create_slices_pipeline_creates_linked_afk_sub_issues_idempotently() {
  local issue fake_bin slices_file sub_issues_file status_value log_file issue_count

  issue="9018"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_create_slices_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewer: "codex",
          hitl: true,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-prd",
          phase: "fixed",
          type: "create-prd",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-slices",
          phase: "fixed",
          type: "create-slices",
          agent: "claude",
          reviewer: "codex",
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  slices_file="$WORKSPACES_DIR/$issue/slices.md"
  sub_issues_file="$WORKSPACES_DIR/$issue/github-sub-issues.md"
  log_file="$WORKSPACES_DIR/$issue/logs/create-slices.log"
  status_value="$(jq -r '.steps[2].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-slices to complete, got $status_value"
  [[ -f "$slices_file" ]] || fail "expected final slices file"
  [[ -f "$sub_issues_file" ]] || fail "expected sub-issue fixture file"
  assert_contains "$(<"$sub_issues_file")" "AFK: true"
  assert_contains "$(<"$sub_issues_file")" "addSubIssue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "create-slices created AFK sub-issues"

  jq '.steps[2].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  issue_count="$(grep -c '^-' "$sub_issues_file")"
  [[ "$issue_count" == "2" ]] || fail "expected rerun not to create duplicate sub-issues, got $issue_count entries"
}

test_implement_slice_pipeline_runs_codex_with_sub_issue_context() {
  local issue fake_bin status_value log_file input_tokens output_tokens output

  issue="9020"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_implement_slice_codex "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9020-implementation-workflow",
      status: "initialized",
      steps: [
        {
          id: "implement-slice-9111",
          phase: "dynamic",
          type: "implement-slice",
          agent: "codex",
          reviewer: null,
          hitl: false,
          status: "pending",
          sub_issue: 9111,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/implement-slice-9111.log"

  [[ "$status_value" == "completed" ]] || fail "expected implement-slice to complete, got $status_value"
  [[ "$input_tokens" == "21" ]] || fail "expected implement-slice input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "34" ]] || fail "expected implement-slice output_tokens metric, got $output_tokens"
  [[ -f "$log_file" ]] || fail "expected implement-slice log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "implement-slice-9111"
  assert_contains "$output" "codex"
}

test_issue_must_be_positive_integer
test_run_requires_existing_state
test_run_rejects_failed_steps
test_run_hard_stops_when_context_missing
test_run_hard_stops_when_context_is_insufficient
test_run_completes_pending_agent_step
test_status_prints_step_table
test_logs_tails_active_step_log
test_logs_tails_specific_step_log
test_claude_agent_step_renders_prompt_logs_metrics_and_summary
test_codex_agent_step_logs_jsonl_and_records_metrics
test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up
test_blocked_step_stops_then_resumes_with_human_answers
test_failed_agent_invocation_marks_step_failed_and_exits_one
test_init_prompt_defines_complete_workspace_initialization_contract
test_initialized_workspace_status_shows_four_pending_fixed_steps
test_council_review_submits_polls_reads_cleans_up_and_prints_review
test_council_review_handles_member_failure_and_cleans_up
test_council_review_handles_timeout_and_cleans_up
test_review_decisions_prompt_defines_council_filtering_and_hitl_contract
test_create_prd_prompt_defines_full_prd_workflow_contract
test_create_slices_prompt_defines_full_slice_creation_contract
test_preflight_prompt_defines_full_preflight_workflow_contract
test_implement_slice_prompt_defines_full_implementation_workflow_contract
test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates
test_review_decisions_runs_after_context_check_and_blocks_then_resumes
test_create_prd_pipeline_preserves_original_and_updates_single_prd_body
test_create_slices_pipeline_creates_linked_afk_sub_issues_idempotently
test_implement_slice_pipeline_runs_codex_with_sub_issue_context

echo "All ralph-v2 tests passed"
