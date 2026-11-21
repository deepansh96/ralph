#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

suites=(
  cli_test.sh
  status_delegation_test.sh
  cleanup_test.sh
  context_test.sh
  agent_test.sh
  state_test.sh
  delegation_test.sh
  claude_delegation_test.sh
  claude_gate_smoke_test.sh
  codex_gate_smoke_test.sh
  codex_delegation_test.sh
  delegation_manifest_test.sh
  delegation_qa_test.sh
  delegation_gate_test.sh
  pipeline_test.sh
  background_poll_test.sh
  council_test.sh
  runner_test.sh
  prompt_render_test.sh
  prompt_contracts_test.sh
  skill_docs_test.sh
  parse_log_test.sh
  grill_test.sh
)

if [[ $# -gt 0 ]]; then
  suites=()
  for suite in "$@"; do
    case "$suite" in
      *.sh) suites+=("$suite") ;;
      *) suites+=("${suite}_test.sh") ;;
    esac
  done
fi

for suite in "${suites[@]}"; do
  suite_path="$TEST_DIR/suites/$suite"
  if [[ ! -x "$suite_path" ]]; then
    echo "Error: suite not found or not executable: $suite" >&2
    exit 1
  fi
  echo "==> $suite"
  "$suite_path"
done

echo "All ralph tests passed"
