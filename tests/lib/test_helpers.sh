#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
CLEANUP_SCRIPT="$ROOT_DIR/cleanup.sh"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
ARCHIVE_DIR="$ROOT_DIR/archive"
CONTEXT_FILE="$PROJECT_ROOT/CONTEXT.md"
INITIAL_CONTEXT_BACKUP="$(mktemp)"
INITIAL_CONTEXT_PRESENT="false"
TEST_ISSUES=(42 9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012 9013 9014 9015 9016 9018 9019 9020 9021 9022 9023 9024 9025 9026 9027 9028 9029 9030 9031 9032 9033 9034 9035 9036 9037 9038 9039 9040 9041 9042 9043 9044 9045 9046 9047 9048 9049 9050 9051 9052 9053 9054 9055 9056 9057 9058 9059 9060 9061 9062 9063 9064 9065 9066 9067 9068 9069 9070 9071 9072 9073 9076 9077 9078 9079 9080 9081 9082 9083 9084 9085 9086 9087)
export RALPH_RETRY_DELAYS="${RALPH_RETRY_DELAYS:-0 0 0}"

if [[ -f "$CONTEXT_FILE" ]]; then
  cp "$CONTEXT_FILE" "$INITIAL_CONTEXT_BACKUP"
  INITIAL_CONTEXT_PRESENT="true"
fi

# Removes what a suite leaves in the Ralph directory. Safe to run at load.
cleanup_workspaces() {
  local issue

  for issue in "${TEST_ISSUES[@]}"; do
    rm -rf "${WORKSPACES_DIR:?}/$issue"
    rm -rf "${ARCHIVE_DIR:?}/"*-"$issue"
  done
  rm -rf "${WORKSPACES_DIR:?}/fake-bin"
  rmdir "$ARCHIVE_DIR" 2>/dev/null || true
}

# Exit cleanup: also puts back the project's own CONTEXT.md. It consumes the
# backup, so it must not run at load.
cleanup() {
  if [[ "$INITIAL_CONTEXT_PRESENT" == "true" ]]; then
    [[ ! -f "$INITIAL_CONTEXT_BACKUP" ]] || cp "$INITIAL_CONTEXT_BACKUP" "$CONTEXT_FILE"
  else
    rm -f "$CONTEXT_FILE"
  fi
  rm -f "$INITIAL_CONTEXT_BACKUP"

  cleanup_workspaces
}

trap cleanup EXIT
cleanup_workspaces

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
  local agent="${4:-stub}"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg id "$step_id" \
    --arg status "$status" \
    --arg agent "$agent" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: $id,
          type: "stub",
          agent: $agent,
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c --arg prompt "$prompt" '{
  type: "result",
  subtype: "success",
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
if [[ "$prompt" == *"Intentionally incomplete fixture"* ]]; then
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: FAIL\nMissing required sections: Language, Relationships, Example dialogue, Flagged ambiguities.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
else
  jq -n -c '{
    type: "result",
    subtype: "success",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
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

install_fake_sleeping_claude() {
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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

sleep 2
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "completed after sleep",
  duration_ms: 2000,
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c --arg prompt "$prompt" '{
    type: "result",
    subtype: "success",
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c --arg prompt "$prompt" '{
    type: "result",
    subtype: "success",
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
[[ "$prompt" == *"nitpick"* ]] || exit 63
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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
[[ "$prompt" == *"to-spec"* ]] || exit 76
[[ "$prompt" == *"Round 1"* ]] || exit 77
[[ "$prompt" == *"Round 2"* ]] || exit 78
[[ "$prompt" == *"gh issue edit"* ]] || exit 79
[[ "$prompt" == *"Do not append a second PRD"* ]] || exit 80

if [[ ! -f "$original_file" ]]; then
  printf 'Original grilled issue body\n' > "$original_file"
fi

cat > "$issue_body_file" <<'PRD'
## Decision Summary

- Workflow: create-and-review-prd preserves original issue body and updates the issue with one PRD.

## Problem Statement

The pipeline needs a PRD before slice planning can begin.

## Solution

Create a reviewed PRD from the grilled issue decisions.

## User Stories

1. As a developer, I want the create-and-review-prd step to update the existing issue, so that the issue remains the source of truth.

## Implementation Decisions

- Prompt-driven workflow: The agent performs issue reading, review, preservation, and update.

## Testing Decisions

- Test through the Ralph pipeline and prompt contract.

## Out of Scope

- Slice creation and preflight.

## Further Notes

- Re-runs replace this body instead of appending another PRD.
PRD

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "create-and-review-prd preserved original and updated issue body",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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
[[ "$prompt" == *"to-tickets"* ]] || exit 85
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "create-and-review-slices created AFK sub-issues and linked them under parent",
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
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

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."}}'
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
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
if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."}}'
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
  exit 0
fi
[[ "$prompt" == *"Issue: 9020"* ]] || exit 101
[[ "$prompt" == *"Repo: deepansh96/ralph"* ]] || exit 102
[[ "$prompt" == *"Workspace: "*"/workspaces/9020"* ]] || exit 103
[[ "$prompt" == *"Branch: feat/issue-9020-implementation-workflow"* ]] || exit 104
[[ "$prompt" == *"Base branch: main"* ]] || exit 105
[[ "$prompt" == *"Step: implement-slice-9111"* ]] || exit 106
[[ "$prompt" == *"Sub-issue: 9111"* ]] || exit 107
[[ "$prompt" == *"Skills: "*"/skills"* ]] || exit 108
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 109
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 110
[[ "$prompt" == *"docs/adr"* ]] || exit 111
[[ "$prompt" == *"tdd/SKILL.md"* ]] || exit 112
[[ "$prompt" == *"tdd/tests.md"* ]] || exit 113
[[ "$prompt" == *"tdd/mocking.md"* ]] || exit 114
[[ "$prompt" == *"issue_dependencies_summary.blocked_by"* ]] || exit 115
[[ "$prompt" == *"seams"* ]] || exit 116
[[ "$prompt" == *"tautological"* ]] || exit 117
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

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
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

install_fake_post_implementation_claude() {
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS",
    duration_ms: 100,
    usage: {input_tokens: 1, output_tokens: 1},
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
case "$step_id" in
  final-checks)
    [[ "$prompt" == *"git diff main...HEAD"* ]] || exit 201
    [[ "$prompt" == *"read-only"* ]] || exit 202
    cat > "$workspace/final-checks.md" <<'FINAL_CHECKS'
# Final Checks

- Quality checks: passed
- Acceptance criteria: satisfied
- Outcome: PASS
FINAL_CHECKS
    ;;
  pr-creation)
    [[ "$prompt" == *"Closes #9021"* ]] || exit 203
    [[ "$prompt" == *"Do not include a review section or QA checklist"* ]] || exit 204
    if [[ ! -f "$workspace/github-pr.md" ]]; then
      printf '1\n' > "$workspace/github-pr-create-count"
      printf 'created PR #77\n' > "$workspace/github-pr.md"
      action="created"
    else
      action="updated"
    fi
    cat > "$workspace/pr-body.md" <<'PR_BODY'
## Summary

- Added the post-implementation pipeline.

## Linked Issues

- Closes #9021
- Closes #9111
PR_BODY
    printf '# PR Creation\n\n- PR: #77\n- Action: %s\n' "$action" > "$workspace/pr-creation.md"
    ;;
  prepare-qa-checklist)
    [[ "$prompt" == *"ralph:qa-checklist"* ]] || exit 205
    if [[ ! -f "$workspace/qa-comment-count" ]]; then
      printf '1\n' > "$workspace/qa-comment-count"
    fi
    cat > "$workspace/github-qa-comment.md" <<'QA_COMMENT'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: Run locally
QA_COMMENT
    ;;
  runthrough-qa-checklist)
    [[ "$prompt" == *"Stub all external calls"* ]] || exit 206
    cat > "$workspace/github-qa-comment.md" <<'QA_COMMENT'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [x] [PASS] QA-01: Run locally

Summary: 1 passed.
QA_COMMENT
    ;;
  multi-axis-pr-review)
    [[ "$prompt" == *"exactly five top-level subagents in two flat batches"* ]] || exit 207
    [[ "$prompt" == *"five top-level review results"* ]] || exit 213
    [[ "$prompt" == *"matt-pocock-code-review/SKILL.md"* ]] || exit 208
    [[ "$prompt" == *"ponytail-review/SKILL.md"* ]] || exit 209
    [[ "$prompt" == *"run-codex-review/SKILL.md"* ]] || exit 210
    [[ "$prompt" == *"supe-review-code-changes/SKILL.md"* ]] || exit 211
    if [[ ! -f "$workspace/multi-axis-comment-count" ]]; then
      printf '1\n' > "$workspace/multi-axis-comment-count"
    fi
    cat > "$workspace/github-multi-axis-comment.md" <<'REVIEW_COMMENT'
<!-- ralph:multi-axis-review -->
## Kept Findings

- None.

Verdict: pass.
REVIEW_COMMENT
    ;;
  cleanup-local-resources)
    [[ "$prompt" == *"after an earlier step fails"* ]] || exit 212
    printf '%s\n' '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}' > "$workspace/local-resources.json"
    cat > "$workspace/cleanup-local-resources.md" <<'CLEANUP'
# Cleanup Local Resources

- Removed recorded resources.
CLEANUP
    ;;
  *)
    echo "unexpected step: $step_id" >&2
    exit 213
    ;;
esac

jq -n -c --arg step "$step_id" '{
  type: "result",
  subtype: "success",
  result: ($step + " completed"),
  duration_ms: 100,
  usage: {input_tokens: 3, output_tokens: 2},
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_failure_then_cleanup_claude() {
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
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  printf '%s\n' '{"type":"result","subtype":"success","result":"CONTEXT_CHECK: PASS","duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"
if [[ "$step_id" == "create-and-review-prd" ]]; then
  exit 42
fi
[[ "$step_id" == "cleanup-local-resources" ]] || exit 43
printf 'cleanup ran\n' > "$workspace/cleanup-ran"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"cleanup completed","duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
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

run_test() {
  local name="$1"
  printf 'Running %s\n' "$name"
  "$name"
}

# Shared fixture handling for the scripted grill fakes (fake claude and fake
# codex), sourced from <fake-bin>/grill-fake-common.sh. Each fake sets
# $state_dir, then:
#   fake_record_call "$@"     records calls/NNNN/{argv.json,pwd,stdin} ($call_dir)
#   fake_select_exchange P    reads P's [ralph-exchange:<id>] marker ($exchange_id,
#                             $fixture = exchanges/<id>)
#   fake_take_transient       true when this call must fail transiently:
#                             <id>.transient holds how many calls fail (empty: 1)
#   fake_maybe_kill           <id>.kill (`received` or `lost`) interrupts the
#                             whole process group once, after or before the
#                             prompt reaches the fake's store_prompt
#   fake_result_text          runs <id>.sh, then prints <id>.json (<id>.N.json
#                             for the Nth call of the exchange) or `ready`
install_grill_fake_common() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/grill-fake-common.sh" <<'FAKE_COMMON'
fake_record_call() {
  local call_count
  mkdir -p "$state_dir/calls"
  call_count="$(find "$state_dir/calls" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  call_dir="$state_dir/calls/$(printf '%04d' $((call_count + 1)))"
  mkdir -p "$call_dir"
  jq -n '$ARGS.positional' --args -- "$@" > "$call_dir/argv.json"
  pwd > "$call_dir/pwd"
  if [[ -t 0 ]]; then
    : > "$call_dir/stdin"
  else
    cat > "$call_dir/stdin" || true
  fi
}

fake_select_exchange() {
  exchange_id="$(grep -oE '\[ralph-exchange:ex-[0-9]+\]' <<<"$1" | head -n 1 | sed -E 's/^\[ralph-exchange:(.*)\]$/\1/' || true)"
  fixture="$state_dir/exchanges/$exchange_id"
}

fake_take_transient() {
  local remaining
  [[ -n "$exchange_id" && -f "$fixture.transient" ]] || return 1
  remaining="$(<"$fixture.transient")"
  remaining="${remaining:-1}"
  if [[ "$remaining" -le 1 ]]; then
    rm -f "$fixture.transient"
  else
    printf '%s\n' "$((remaining - 1))" > "$fixture.transient"
  fi
}

fake_maybe_kill() {
  local kill_mode
  [[ -n "$exchange_id" && -f "$fixture.kill" ]] || return 0
  kill_mode="$(<"$fixture.kill")"
  rm -f "$fixture.kill"
  [[ "$kill_mode" != "received" ]] || store_prompt
  kill -INT 0
  sleep 5
  exit 130
}

fake_result_text() {
  local seen
  if [[ -n "$exchange_id" ]]; then
    mkdir -p "$state_dir/seen"
    printf 'x' >> "$state_dir/seen/$exchange_id"
    seen="$(wc -c < "$state_dir/seen/$exchange_id" | tr -d ' ')"
    [[ "$seen" -lt 2 || ! -f "$fixture.$seen.json" ]] || fixture="$fixture.$seen"
  fi
  if [[ -n "$exchange_id" && -f "$fixture.sh" ]]; then
    bash "$fixture.sh" >&2
  fi
  if [[ -n "$exchange_id" && -f "$fixture.json" ]]; then
    cat "$fixture.json"
  else
    printf 'ready\n'
  fi
}
FAKE_COMMON
}

# Scripted fake `claude` for Automated Grilling Sessions. Each non-help
# invocation is recorded under $FAKE_CLAUDE_DIR/calls/NNNN/ and answered from
# the per-exchange fixtures in $FAKE_CLAUDE_DIR/exchanges (see
# install_grill_fake_common). Without a fixture, result text is popped from
# $FAKE_CLAUDE_DIR/queue/* in name order, falling back to a readiness
# acknowledgement. Prompts are appended as user messages to a fake session
# store in Claude's layout, $CLAUDE_CONFIG_DIR/projects/<cwd>/<native-id>.jsonl.
# A file $FAKE_CLAUDE_DIR/lost/<native-id> makes resuming that session fail as
# not found.
# FAKE_CLAUDE_HELP_OMIT removes a flag from `--help` output so capability
# checks can be failed.
install_fake_grill_claude() {
  local fake_bin="$1"

  install_grill_fake_common "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  help_text="$(cat <<'HELP'
Usage: claude [options] [command] [prompt]
  -p, --print                           Print response and exit
  --output-format <format>              Output format
  --verbose                             Verbose output
  --model <model>                       Model for the current session
  --effort <level>                      Effort level for the current session
  --session-id <uuid>                   Use a specific session ID
  -r, --resume [value]                  Resume a conversation by session ID
  --permission-mode <mode>              Permission mode to use for the session
  --allowedTools, --allowed-tools <tools...>
  --disallowedTools, --disallowed-tools <tools...>
  --settings <file-or-json>             Path to a settings JSON file or a JSON string
  --json-schema <schema>                JSON Schema for structured output
HELP
)"
  if [[ -n "${FAKE_CLAUDE_HELP_OMIT:-}" ]]; then
    help_text="$(grep -v -F -- "$FAKE_CLAUDE_HELP_OMIT" <<<"$help_text")"
  fi
  printf '%s\n' "$help_text"
  exit 0
fi

state_dir="${FAKE_CLAUDE_DIR:?FAKE_CLAUDE_DIR is required}"
source "$(dirname "$0")/grill-fake-common.sh"
mkdir -p "$state_dir/queue"
fake_record_call "$@"

prompt=""
native_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --session-id|--resume) native_id="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -f "$state_dir/lost/${native_id:-unknown}" ]]; then
  echo "No conversation found with session ID: $native_id" >&2
  exit 1
fi

fake_select_exchange "$prompt"
if fake_take_transient; then
  echo 'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' >&2
  exit 1
fi

store_prompt() {
  local store="${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR is required}/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$store"
  jq -n -c --arg id "$native_id" --arg prompt "$prompt" \
    '{type: "user", sessionId: $id, message: {role: "user", content: $prompt}}' >> "$store/${native_id:-unknown}.jsonl"
}

fake_maybe_kill
store_prompt
result="$(fake_result_text)"
if [[ "$result" == "ready" ]]; then
  next="$(find "$state_dir/queue" -mindepth 1 -maxdepth 1 -type f | sort | head -n 1)"
  if [[ -n "$next" ]]; then
    result="$(<"$next")"
    rm -f "$next"
  fi
fi

jq -n -c --arg id "$native_id" '{type: "system", subtype: "init", session_id: $id}'
jq -n -c --arg id "$native_id" --arg result "$result" \
  '{type: "result", subtype: "success", is_error: false, session_id: $id, result: $result}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

# Fake `uuidgen` that pops UUIDs from $FAKE_UUID_QUEUE (one per line).
install_fake_uuidgen() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/uuidgen" <<'FAKE_UUIDGEN'
#!/usr/bin/env bash
set -euo pipefail

queue="${FAKE_UUID_QUEUE:?FAKE_UUID_QUEUE is required}"
next="$(head -n 1 "$queue")"
[[ -n "$next" ]] || { echo "fake uuidgen queue is empty" >&2; exit 1; }
tail -n +2 "$queue" > "$queue.tmp"
mv "$queue.tmp" "$queue"
printf '%s\n' "$next"
FAKE_UUIDGEN
  chmod +x "$fake_bin/uuidgen"
}

# Scripted fake `codex` for Automated Grilling Sessions, answering from the
# same per-exchange fixtures as the fake claude (see install_grill_fake_common)
# through $FAKE_CODEX_DIR/exchanges. Each `exec` invocation is recorded under
# $FAKE_CODEX_DIR/calls/NNNN/; the prompt is read from stdin (`-`). `exec`
# starts a thread whose ID is popped from $FAKE_CODEX_THREAD_QUEUE and reported
# in a `thread.started` event; `exec resume <id>` continues it. Prompts are
# appended to a fake session store in Codex's layout,
# $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread-id>.jsonl, whose first
# line is the session_meta record. A file $FAKE_CODEX_DIR/lost/<thread-id>
# makes resuming that thread fail as not found.
# FAKE_CODEX_HELP_OMIT removes a flag from every `--help` output, and
# FAKE_CODEX_NO_READ_ONLY_NETWORK makes permission profiles unsupported (the
# `debug prompt-input` probe reports restricted network), so capability
# checks can be failed.
install_fake_grill_codex() {
  local fake_bin="$1"

  install_grill_fake_common "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_CODEX_DIR:?FAKE_CODEX_DIR is required}"

print_help() {
  local help_text="$1"
  if [[ -n "${FAKE_CODEX_HELP_OMIT:-}" ]]; then
    help_text="$(grep -v -F -- "$FAKE_CODEX_HELP_OMIT" <<<"$help_text")"
  fi
  printf '%s\n' "$help_text"
  exit 0
}

case "$*" in
  --help)
    print_help "Usage: codex [OPTIONS] [PROMPT]
  -c, --config <key=value>
  -m, --model <MODEL>
  -s, --sandbox <SANDBOX_MODE>  [possible values: read-only, workspace-write, danger-full-access]
  -C, --cd <DIR>
  -a, --ask-for-approval <APPROVAL_POLICY>"
    ;;
  "exec --help")
    print_help "Usage: codex exec [OPTIONS] [PROMPT]
Commands:
  resume  Resume a previous session by id or pick the most recent with --last
      --json
      --output-schema <FILE>"
    ;;
  "exec resume --help")
    print_help "Usage: codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]
      --last
      --json
      --output-schema <FILE>"
    ;;
esac

# `debug prompt-input` renders the permission instructions for the given
# global options, as the real CLI does: an explicit --sandbox wins over a
# default_permissions profile (dropping the profile's network grant), and
# workspace-write has network only with sandbox_workspace_write.network_access.
if [[ " $* " == *" debug prompt-input "* ]]; then
  mkdir -p "$state_dir"
  jq -n -c '$ARGS.positional' --args -- "$@" >> "$state_dir/probes.log"
  sandbox="" profile="" workspace_network=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      -s|--sandbox) sandbox="${args[i + 1]}" ;;
      -c|--config)
        case "${args[i + 1]}" in
          'default_permissions="ralph-answering"') profile=1 ;;
          sandbox_workspace_write.network_access=true) workspace_network=1 ;;
        esac
        ;;
    esac
  done
  network="restricted"
  if [[ -z "$sandbox" && -n "$profile" && -z "${FAKE_CODEX_NO_READ_ONLY_NETWORK:-}" ]]; then
    sandbox="read-only" network="enabled"
  elif [[ "$sandbox" == "workspace-write" && -n "$workspace_network" ]]; then
    network="enabled"
  fi
  printf '"<permissions instructions>\\n`sandbox_mode` is `%s`: ... Network access is %s.\\n</permissions instructions>"\n' \
    "${sandbox:-read-only}" "$network"
  exit 0
fi

source "$(dirname "$0")/grill-fake-common.sh"
fake_record_call "$@"
prompt="$(<"$call_dir/stdin")"

# Global options come before `exec`; `exec resume` takes the thread ID as its
# first positional argument.
while [[ $# -gt 0 && "$1" != "exec" ]]; do
  case "$1" in
    -c|-m|-s|-C|-a|--config|--model|--sandbox|--cd|--ask-for-approval) shift 2 ;;
    *) shift ;;
  esac
done
[[ "${1:-}" == "exec" ]] || { echo "fake codex: expected exec" >&2; exit 2; }
shift
thread_id=""
if [[ "${1:-}" == "resume" ]]; then
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-schema|-o|--output-last-message|-c|-m) shift 2 ;;
      -*) shift ;;
      *) thread_id="$1"; break ;;
    esac
  done
  [[ -n "$thread_id" ]] || { echo "fake codex: resume needs a thread ID" >&2; exit 2; }
  if [[ -f "$state_dir/lost/$thread_id" ]]; then
    echo "Error: thread/resume: thread/resume failed: no rollout found for thread id $thread_id (code -32600)" >&2
    exit 1
  fi
else
  queue="${FAKE_CODEX_THREAD_QUEUE:?FAKE_CODEX_THREAD_QUEUE is required}"
  thread_id="$(head -n 1 "$queue")"
  [[ -n "$thread_id" ]] || { echo "fake codex thread queue is empty" >&2; exit 1; }
  tail -n +2 "$queue" > "$queue.tmp"
  mv "$queue.tmp" "$queue"
fi

fake_select_exchange "$prompt"
if fake_take_transient; then
  jq -n -c --arg id "$thread_id" '{type: "thread.started", thread_id: $id}'
  jq -n -c '{type: "turn.failed", error: {message: "stream error: exceeded retry limit, last status: 429 Too Many Requests, rate limit reached"}}'
  exit 1
fi

store_prompt() {
  local store="${CODEX_HOME:?CODEX_HOME is required}/sessions/2026/09/25"
  local rollout="$store/rollout-2026-09-25T00-00-00-$thread_id.jsonl"
  mkdir -p "$store"
  [[ -f "$rollout" ]] || jq -n -c --arg id "$thread_id" --arg cwd "$(pwd)" \
    '{type: "session_meta", payload: {id: $id, cwd: $cwd}}' > "$rollout"
  jq -n -c --arg prompt "$prompt" \
    '{type: "response_item", payload: {type: "message", role: "user", content: [{type: "input_text", text: $prompt}]}}' >> "$rollout"
}

fake_maybe_kill
store_prompt
result="$(fake_result_text)"

jq -n -c --arg id "$thread_id" '{type: "thread.started", thread_id: $id}'
jq -n -c '{type: "turn.started"}'
jq -n -c --arg text "$result" '{type: "item.completed", item: {id: "item_0", type: "agent_message", text: $text}}'
jq -n -c '{type: "turn.completed", usage: {input_tokens: 1, output_tokens: 1}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"
}

# Fake `gh` that records argv to $FAKE_GH_LOG and answers `gh issue view`
# with the JSON in $FAKE_GH_ISSUE_JSON. Created issues are kept in
# $FAKE_GH_LOG.created and listed by `gh issue list`. FAKE_GH_FAIL_ONCE names a
# marker file that fails the next write; FAKE_GH_CREATE_CRASH_ONCE names one
# that lets the next create succeed but exit non-zero, as a crash after the
# issue exists would.
install_fake_grill_gh() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

jq -n -c '$ARGS.positional' --args -- "$@" >> "${FAKE_GH_LOG:?FAKE_GH_LOG is required}"
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
  printf '%s\n' "${FAKE_GH_ISSUE_JSON:?FAKE_GH_ISSUE_JSON is required}"
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  if [[ -f "$FAKE_GH_LOG.created" ]]; then
    jq -s -c '.' "$FAKE_GH_LOG.created"
  else
    printf '[]\n'
  fi
  exit 0
fi
# FAKE_GH_FAIL_ONCE names a marker file: while it exists, the first write
# (issue edit or create) removes it and fails.
if [[ -n "${FAKE_GH_FAIL_ONCE:-}" && -f "$FAKE_GH_FAIL_ONCE" ]]; then
  rm -f "$FAKE_GH_FAIL_ONCE"
  echo "fake gh: HTTP 502 (scripted failure)" >&2
  exit 1
fi
if [[ "${1:-}" == "issue" && ( "${2:-}" == "edit" || "${2:-}" == "create" ) ]]; then
  # The --body-file content is copied beside the log, since the coordinator
  # may move its session directory afterwards.
  args=("$@")
  for ((i = 0; i < ${#args[@]} - 1; i++)); do
    [[ "${args[i]}" != "--body-file" ]] || cat "${args[i + 1]}" > "$FAKE_GH_LOG.body"
  done
  if [[ "$2" == "edit" ]]; then
    printf 'https://github.com/acme/target/issues/%s\n' "$3"
  else
    url="https://github.com/acme/target/issues/${FAKE_GH_CREATED_ISSUE:-77}"
    jq -n -c --arg url "$url" --rawfile body "$FAKE_GH_LOG.body" \
      '{number: ($url | split("/") | last | tonumber), url: $url, body: $body}' >> "$FAKE_GH_LOG.created"
    if [[ -n "${FAKE_GH_CREATE_CRASH_ONCE:-}" && -f "$FAKE_GH_CREATE_CRASH_ONCE" ]]; then
      rm -f "$FAKE_GH_CREATE_CRASH_ONCE"
      echo "fake gh: connection reset after the issue was created" >&2
      exit 1
    fi
    printf '%s\n' "$url"
  fi
  exit 0
fi
echo "fake gh: unsupported command: $*" >&2
exit 1
FAKE_GH
  chmod +x "$fake_bin/gh"
}

# Fake Codex with an `exec --json` mode that reports the fixture parent thread
# and a JSON-RPC `app-server` mode that serves hand-written thread pages and
# records every request. Unknown methods are recorded and rejected.
install_fake_codex_app_server() {
  local fake_bin="$1"
  local fixture="$2"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<FAKE_CODEX
#!/usr/bin/env bash
set -euo pipefail
fixture="$fixture"
requests="$fake_bin/app-server-requests.jsonl"
FAKE_CODEX
  cat >> "$fake_bin/codex" <<'FAKE_CODEX'
mode="${1:-}"
shift || true
case "$mode" in
  exec)
    last_message_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output-last-message) last_message_file="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    prompt="$(cat)"
    [[ -z "$last_message_file" ]] || printf 'codex saw: %s\n' "$prompt" > "$last_message_file"
    jq -c '{type:"thread.started",thread_id:.parent}' "$fixture"
    printf '%s\n' '{"type":"turn.started"}' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
    ;;
  app-server)
    exec node "$(dirname "$0")/fake-app-server.cjs" "$fixture" "$requests"
    ;;
  *)
    echo "unexpected codex command: $mode" >&2
    exit 99
    ;;
esac
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/fake-app-server.cjs" <<'FAKE_APP_SERVER'
const fs = require('node:fs');
const readline = require('node:readline');
const [fixturePath, requestsPath] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const pageIndex = { direct: 0, descendants: 0 };
const summary = thread => { const copy = { ...thread }; copy.turns = []; return copy; };
const reply = (id, body) => process.stdout.write(JSON.stringify({ id, ...body }) + '\n');
const handle = (id, method, params) => {
  if (method === 'initialize') {
    if (fixture.initialize && fixture.initialize.error) return reply(id, { error: fixture.initialize.error });
    return reply(id, { result: { userAgent: 'fake-codex' } });
  }
  if (method === 'thread/list') {
    const hasParent = params && Object.hasOwn(params, 'parentThreadId');
    const hasAncestor = params && Object.hasOwn(params, 'ancestorThreadId');
    if (hasParent === hasAncestor) return reply(id, { error: { code: -32602, message: 'exactly one relation filter expected' } });
    const kind = hasParent ? 'direct' : 'descendants';
    const relation = hasParent ? params.parentThreadId : params.ancestorThreadId;
    if (relation !== fixture.parent) return reply(id, { result: { data: [], nextCursor: null } });
    const pages = fixture[kind] || [{ ids: [], nextCursor: null }];
    const index = pageIndex[kind];
    if (index >= pages.length) return reply(id, { error: { code: -32602, message: 'no further pages' } });
    const expectedCursor = index === 0 ? undefined : pages[index - 1].nextCursor;
    if (params.cursor !== expectedCursor) return reply(id, { error: { code: -32602, message: 'unexpected cursor' } });
    pageIndex[kind] += 1;
    const page = pages[index];
    if (page.error) return reply(id, { error: page.error });
    if (page.malformed) return reply(id, { result: { data: 'not-a-list' } });
    return reply(id, { result: { data: page.ids.map(threadId => summary(fixture.threads[threadId])), nextCursor: page.nextCursor ?? null } });
  }
  if (method === 'thread/read') {
    const override = (fixture.reads || {})[params && params.threadId];
    if (override && override.error) return reply(id, { error: override.error });
    const thread = fixture.threads[params && params.threadId];
    if (!thread) return reply(id, { error: { code: -32602, message: 'thread not found' } });
    return reply(id, { result: { thread: params.includeTurns ? thread : summary(thread) } });
  }
  return reply(id, { error: { code: -32601, message: 'method not supported by the fake' } });
};
readline.createInterface({ input: process.stdin }).on('line', line => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  fs.appendFileSync(requestsPath, JSON.stringify({ method: message.method, params: message.params === undefined ? null : message.params }) + '\n');
  if (message.id === undefined) return;
  handle(message.id, message.method, message.params);
});
FAKE_APP_SERVER
}
