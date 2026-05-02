#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

read_prompt() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$*"
  else
    cat
  fi
}

council_cleanup_run() {
  local run_id="$1"

  [[ -n "$run_id" ]] || return 0
  council cleanup --run "$run_id" >/dev/null 2>&1 || true
}

command -v council >/dev/null 2>&1 || die "council CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

ONLY=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ $# -ge 2 ]] || die "--only requires a value"
      ONLY="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

PROMPT="$(read_prompt "${ARGS[@]+"${ARGS[@]}"}")"
[[ -n "${PROMPT//[[:space:]]/}" ]] || die "review prompt is required via argument or stdin"

WORK_DIR="${RALPH_COUNCIL_DIR:-$(pwd)}"
TIMEOUT_SECONDS="${RALPH_COUNCIL_TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL="${RALPH_COUNCIL_POLL_INTERVAL:-5}"

ASK_CMD=(council ask --dir "$WORK_DIR" --json)
[[ -z "$ONLY" ]] || ASK_CMD+=(--only "$ONLY")

ASK_JSON="$(printf '%s' "$PROMPT" | "${ASK_CMD[@]}")" || die "council ask failed"
RUN_ID="$(jq -r '.runId // .run_id // empty' <<<"$ASK_JSON")"
[[ -n "$RUN_ID" ]] || die "council ask did not return a run id"

START_SECONDS="$(date +%s)"
STATUS_JSON=""

while true; do
  STATUS_JSON="$(council status --run "$RUN_ID" --json)" || {
    council_cleanup_run "$RUN_ID"
    die "council status failed for run $RUN_ID"
  }

  if jq -e '
    (.running == false)
    or ([.members[]?.status] | all(. != "working"))
  ' <<<"$STATUS_JSON" >/dev/null; then
    break
  fi

  now_seconds="$(date +%s)"
  if (( now_seconds - START_SECONDS >= TIMEOUT_SECONDS )); then
    council_cleanup_run "$RUN_ID"
    die "council review timed out after ${TIMEOUT_SECONDS}s for run $RUN_ID"
  fi

  sleep "$POLL_INTERVAL"
done

if jq -e '.members[]? | select(.status == "failed" or .status == "not_running")' <<<"$STATUS_JSON" >/dev/null; then
  council_cleanup_run "$RUN_ID"
  die "council member failed for run $RUN_ID"
fi

READ_JSON="$(council read --run "$RUN_ID" --json)" || {
  council_cleanup_run "$RUN_ID"
  die "council read failed for run $RUN_ID"
}

jq -r '
  .members
  | to_entries[]
  | select(.value.status == "done")
  | .value.output
  | select(. != null and . != "")
' <<<"$READ_JSON"

council_cleanup_run "$RUN_ID"
