#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

QUIZ_SESSIONS=()

cleanup_quiz_sessions() {
  local session
  [[ ${#QUIZ_SESSIONS[@]} -gt 0 ]] || return 0
  for session in "${QUIZ_SESSIONS[@]}"; do
    [[ -e "$session" ]] || continue
    "$ROOT_DIR/skills/quiz-grilling/scripts/cleanup-session.sh" "$session" >/dev/null 2>&1 || true
  done
}

trap 'cleanup_quiz_sessions; cleanup' EXIT

test_skills_bundle_is_self_contained_and_readme_documents_workflow() {
  local required_files readme agents context grilling grill_with_docs wayfinder research writing_for_agents codebase_design improve_architecture matt_review quiz_grilling tests_readme global_skill_ref stale_refs broken_links link_records file relative_file target target_without_anchor resolved

  required_files=(
    "$ROOT_DIR/skills/to-spec/SKILL.md"
    "$ROOT_DIR/skills/to-tickets/SKILL.md"
    "$ROOT_DIR/skills/grill-with-docs/SKILL.md"
    "$ROOT_DIR/skills/grilling/SKILL.md"
    "$ROOT_DIR/skills/wayfinder/SKILL.md"
    "$ROOT_DIR/skills/research/SKILL.md"
    "$ROOT_DIR/skills/matt-pocock-code-review/SKILL.md"
    "$ROOT_DIR/skills/ponytail-review/SKILL.md"
    "$ROOT_DIR/skills/run-codex-review/SKILL.md"
    "$ROOT_DIR/skills/run-codex-review/scripts/review.mjs"
    "$ROOT_DIR/skills/supe-review-code-changes/SKILL.md"
    "$ROOT_DIR/skills/tdd/SKILL.md"
    "$ROOT_DIR/skills/tdd/tests.md"
    "$ROOT_DIR/skills/tdd/mocking.md"
    "$ROOT_DIR/skills/domain-modeling/SKILL.md"
    "$ROOT_DIR/skills/domain-modeling/DOMAIN-AWARENESS.md"
    "$ROOT_DIR/skills/domain-modeling/CONTEXT-FORMAT.md"
    "$ROOT_DIR/skills/domain-modeling/ADR-FORMAT.md"
    "$ROOT_DIR/skills/wizard/SKILL.md"
    "$ROOT_DIR/skills/wizard/template.sh"
    "$ROOT_DIR/skills/wizard/agents/openai.yaml"
    "$ROOT_DIR/skills/wizard/LICENSE"
    "$ROOT_DIR/skills/quiz-grilling/SKILL.md"
    "$ROOT_DIR/skills/quiz-grilling/agents/openai.yaml"
    "$ROOT_DIR/skills/quiz-grilling/scripts/create-session.sh"
    "$ROOT_DIR/skills/quiz-grilling/scripts/serve-quiz.mjs"
    "$ROOT_DIR/skills/quiz-grilling/scripts/start-tunnel.sh"
    "$ROOT_DIR/skills/quiz-grilling/scripts/cleanup-session.sh"
    "$ROOT_DIR/skills/quiz-grilling/assets/index.html"
    "$ROOT_DIR/skills/quiz-grilling/assets/app.js"
    "$ROOT_DIR/skills/quiz-grilling/assets/styles.css"
    "$ROOT_DIR/skills/wait-what/SKILL.md"
    "$ROOT_DIR/skills/wait-what/agents/openai.yaml"
    "$ROOT_DIR/skills/wait-what/LICENSE"
    "$ROOT_DIR/skills/prototype/SKILL.md"
    "$ROOT_DIR/skills/prototype/LOGIC.md"
    "$ROOT_DIR/skills/prototype/UI.md"
    "$ROOT_DIR/skills/prototype/agents/openai.yaml"
    "$ROOT_DIR/skills/prototype/LICENSE"
    "$ROOT_DIR/skills/writing-for-agents/SKILL.md"
    "$ROOT_DIR/skills/writing-for-agents/SKILL-MECHANICS.md"
    "$ROOT_DIR/skills/writing-for-agents/agents/openai.yaml"
    "$ROOT_DIR/skills/writing-for-agents/LICENSE"
    "$ROOT_DIR/skills/codebase-design/SKILL.md"
    "$ROOT_DIR/skills/codebase-design/DEEPENING.md"
    "$ROOT_DIR/skills/codebase-design/DESIGN-IT-TWICE.md"
    "$ROOT_DIR/skills/codebase-design/agents/openai.yaml"
    "$ROOT_DIR/skills/codebase-design/LICENSE"
    "$ROOT_DIR/skills/improve-codebase-architecture/SKILL.md"
    "$ROOT_DIR/skills/improve-codebase-architecture/HTML-REPORT.md"
    "$ROOT_DIR/skills/improve-codebase-architecture/agents/openai.yaml"
    "$ROOT_DIR/skills/improve-codebase-architecture/LICENSE"
  )

  for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || fail "expected bundled skill file: $file"
  done

  global_skill_ref="~/.claude/""skills"
  stale_refs="$(grep -R "$global_skill_ref" "$ROOT_DIR/skills" 2>/dev/null || true)"
  [[ -z "$stale_refs" ]] || fail "expected no global skill directory references in bundled skills: $stale_refs"

  link_records="$(perl -ne 'if (/^```/) { $in_fence = !$in_fence; next } next if $in_fence; while (/\[[^\]]+\]\(([^)]+)\)/g) { print "$ARGV:$1\n" }' "${required_files[@]}")"
  broken_links=""
  while IFS= read -r link_record; do
    [[ -n "$link_record" ]] || continue
    file="${link_record%%:*}"
    target="${link_record#*:}"
    case "$target" in
      http://*|https://*|mailto:*|\#*|/*)
        continue
        ;;
    esac

    target_without_anchor="${target%%#*}"
    [[ -n "$target_without_anchor" ]] || continue
    resolved="$(cd "$(dirname "$file")" && cd "$(dirname "$target_without_anchor")" 2>/dev/null && pwd)/$(basename "$target_without_anchor")"
    [[ -e "$resolved" ]] || broken_links+="$file -> $target"$'\n'
  done <<< "$link_records"
  [[ -z "$broken_links" ]] || fail "expected all bundled skill relative links to resolve:"$'\n'"$broken_links"

  bash -n "$ROOT_DIR/skills/wizard/template.sh"
  bash -n "$ROOT_DIR/skills/quiz-grilling/scripts/create-session.sh"
  bash -n "$ROOT_DIR/skills/quiz-grilling/scripts/start-tunnel.sh"
  bash -n "$ROOT_DIR/skills/quiz-grilling/scripts/cleanup-session.sh"
  node --check "$ROOT_DIR/skills/quiz-grilling/scripts/serve-quiz.mjs"
  node --check "$ROOT_DIR/skills/quiz-grilling/assets/app.js"

  readme="$ROOT_DIR/README.md"
  [[ -f "$readme" ]] || fail "expected ralph README"
  assert_contains "$(<"$readme")" "ralph.sh --issue N"
  assert_contains "$(<"$readme")" "ralph.sh status --issue N"
  assert_contains "$(<"$readme")" "ralph.sh logs --issue N"
  assert_contains "$(<"$readme")" "./tests/run.sh"
  assert_contains "$(<"$readme")" "tests/suites/"
  assert_contains "$(<"$readme")" "cleanup.sh <issue-number>"
  assert_contains "$(<"$readme")" "grill"
  assert_contains "$(<"$readme")" "grill/*"
  assert_contains "$(<"$readme")" "planning branch"
  assert_contains "$(<"$readme")" "baseBranch"
  assert_contains "$(<"$readme")" "init"
  assert_contains "$(<"$readme")" "run"
  assert_contains "$(<"$readme")" "cleanup"
  assert_contains "$(<"$readme")" "state.json"
  assert_contains "$(<"$readme")" "ralph.config.json"
  assert_contains "$(<"$readme")" "subagentModel"
  assert_contains "$(<"$readme")" "subagentReasoningEffort"
  assert_contains "$(<"$readme")" "review-decisions"
  assert_contains "$(<"$readme")" "implement-slice"
  assert_contains "$(<"$readme")" "final-checks"
  assert_contains "$(<"$readme")" "pr-creation"
  assert_contains "$(<"$readme")" "prepare-qa-checklist"
  assert_contains "$(<"$readme")" "runthrough-qa-checklist"
  assert_contains "$(<"$readme")" "multi-axis-pr-review"
  assert_contains "$(<"$readme")" "cleanup-local-resources"
  assert_contains "$(<"$readme")" "wayfinder"
  assert_contains "$(<"$readme")" "wizard"
  assert_contains "$(<"$readme")" "quiz-grilling"
  assert_contains "$(<"$readme")" "writing-for-agents"
  assert_contains "$(<"$readme")" "improve-codebase-architecture"
  assert_contains "$(<"$readme")" "docs/agents/issue-tracker.md"

  agents="$ROOT_DIR/AGENTS.md"
  for file in "${required_files[@]}"; do
    [[ "$(basename "$file")" == "SKILL.md" ]] || continue
    relative_file="${file#"$ROOT_DIR"/}"
    assert_contains "$(<"$agents")" "$relative_file"
  done

  context="$ROOT_DIR/CONTEXT.md"
  grilling="$ROOT_DIR/skills/grilling/SKILL.md"
  grill_with_docs="$ROOT_DIR/skills/grill-with-docs/SKILL.md"
  wayfinder="$ROOT_DIR/skills/wayfinder/SKILL.md"
  research="$ROOT_DIR/skills/research/SKILL.md"
  writing_for_agents="$ROOT_DIR/skills/writing-for-agents/SKILL.md"
  codebase_design="$ROOT_DIR/skills/codebase-design/SKILL.md"
  improve_architecture="$ROOT_DIR/skills/improve-codebase-architecture/SKILL.md"
  matt_review="$ROOT_DIR/skills/matt-pocock-code-review/SKILL.md"
  quiz_grilling="$ROOT_DIR/skills/quiz-grilling/SKILL.md"
  assert_contains "$(<"$context")" "Decision Ticket"
  assert_contains "$(<"$grilling")" "Work the tree in **rounds**"
  assert_contains "$(<"$grilling")" "❓ **Q1**"
  assert_contains "$(<"$grilling")" "must not modify files, Git, or the tracker"
  assert_contains "$(<"$grilling")" "user confirms"
  assert_contains "$(<"$grill_with_docs")" "currently answerable question"
  assert_contains "$(<"$wayfinder")" "decision tickets"
  assert_contains "$(<"$wayfinder")" "returns cited findings only"
  assert_contains "$(<"$wayfinder")" "create-and-review-prd"
  assert_contains "$(<"$research")" "owns all file, Git, and tracker writes"
  assert_contains "$(<"$writing_for_agents")" "environment** is a source of truth"
  assert_contains "$(<"$writing_for_agents")" "**cache**"
  assert_contains "$(<"$codebase_design")" "**The deletion test.**"
  assert_contains "$(<"$improve_architecture")" "**Scope before you scan — YAGNI.**"
  assert_contains "$(<"$improve_architecture")" "Subagents return findings only"
  assert_contains "$(<"$matt_review")" 'Axis: Standards'
  assert_contains "$(<"$matt_review")" 'Axis: Spec'
  assert_contains "$(<"$matt_review")" 'Axis: Both'
  assert_contains "$(<"$matt_review")" "Never spawn subagents"
  [[ "$(<"$matt_review")" != *"Spawn both sub-agents"* ]] || fail "expected the Matt review skill to stay flat"
  assert_contains "$(<"$quiz_grilling")" "explicit read-only boundary"
  assert_contains "$(<"$quiz_grilling")" "Wait-what"
  assert_contains "$(<"$quiz_grilling")" "cleanup-session.sh"

  tests_readme="$ROOT_DIR/tests/README.md"
  [[ -f "$tests_readme" ]] || fail "expected tests README"
  assert_contains "$(<"$tests_readme")" "./tests/run.sh"
  assert_contains "$(<"$tests_readme")" "Suite Map"
  assert_contains "$(<"$tests_readme")" "prompt_contracts_test.sh"
  assert_contains "$(<"$tests_readme")" "External tools"
}

test_quiz_grilling_server_validates_and_saves_a_round() {
  local session server_pid ready_file local_url status output

  session="$("$ROOT_DIR/skills/quiz-grilling/scripts/create-session.sh")"
  QUIZ_SESSIONS+=("$session")
  ready_file="$session/server-ready.json"
  cat > "$session/questions.json" <<'JSON'
{
  "title": "Test decisions",
  "round": 1,
  "questions": [
    {
      "id": "q1",
      "title": "Choose",
      "body": "Which option should we use?",
      "recommendation": "Use A.",
      "options": [
        {"id": "a", "label": "Option A", "recommended": true},
        {"id": "b", "label": "Option B"}
      ],
      "waitWhat": {
        "context": "We need one option.",
        "question": "Should we use A?",
        "recommendation": "Yes."
      }
    }
  ]
}
JSON

  node "$ROOT_DIR/skills/quiz-grilling/scripts/serve-quiz.mjs" --session "$session" --port 0 \
    > "$session/server.log" 2>&1 &
  server_pid=$!

  for _attempt in {1..100}; do
    [[ -f "$ready_file" ]] && break
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.05
  done
  [[ -f "$ready_file" ]] || fail "expected quiz server readiness file"
  local_url="$(jq -r '.url' "$ready_file")"
  assert_contains "$(curl -fsS "$local_url/api/health")" '"ok":true'
  assert_contains "$(curl -fsS "$local_url/api/questions")" '"waitWhat"'

  set +e
  output="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$local_url/api/submit" \
    -H 'content-type: application/json' --data '{"round":1,"answers":[]}')"
  status=$?
  set -e
  [[ "$status" -eq 0 && "$output" == "400" ]] || fail "expected incomplete quiz submission to return 400"

  output="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$local_url/api/submit" \
    -H 'content-type: application/json' \
    --data '{"round":1,"answers":[{"questionId":"q1","optionId":"a","text":"also text"}]}')"
  [[ "$output" == "400" ]] || fail "expected ambiguous quiz answer to return 400"

  output="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$local_url/api/submit" \
    -H 'content-type: application/json' \
    --data '{"round":1,"answers":[{"questionId":"q1","text":"   "}]}')"
  [[ "$output" == "400" ]] || fail "expected blank free-text answer to return 400"

  output="$(curl -fsS -X POST "$local_url/api/submit" -H 'content-type: application/json' \
    --data '{"round":1,"answers":[{"questionId":"q1","optionId":"a"}]}')"
  assert_contains "$output" '"ok":true'
  [[ "$(jq -r '.answers[0].optionId' "$session/answers-round-1.json")" == "a" ]] || fail "expected saved quiz answer"

  output="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$local_url/api/submit" \
    -H 'content-type: application/json' \
    --data '{"round":1,"answers":[{"questionId":"q1","optionId":"b"}]}')"
  [[ "$output" == "409" ]] || fail "expected repeated round submission to return 409"
  [[ "$(jq -r '.answers[0].optionId' "$session/answers-round-1.json")" == "a" ]] || fail "expected first quiz answer to be kept"

  "$ROOT_DIR/skills/quiz-grilling/scripts/cleanup-session.sh" "$session" >/dev/null
  [[ ! -e "$session" ]] || fail "expected quiz session cleanup"
}

test_quiz_grilling_tunnel_records_and_cleans_owned_process() {
  local fake_bin session manifest tunnel_pid

  fake_bin="$WORKSPACES_DIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/cloudflared" <<'FAKE'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
echo 'Quick Tunnel available at https://quiz-test.trycloudflare.com' >&2
while true; do sleep 1; done
FAKE
  chmod +x "$fake_bin/cloudflared"

  session="$("$ROOT_DIR/skills/quiz-grilling/scripts/create-session.sh")"
  QUIZ_SESSIONS+=("$session")
  manifest="$(PATH="$fake_bin:$PATH" "$ROOT_DIR/skills/quiz-grilling/scripts/start-tunnel.sh" \
    --session "$session" --url "http://127.0.0.1:4173")"
  assert_contains "$manifest" '"provider": "cloudflare"'
  assert_contains "$manifest" 'https://quiz-test.trycloudflare.com'
  tunnel_pid="$(jq -r '.pid' <<< "$manifest")"
  kill -0 "$tunnel_pid" 2>/dev/null || fail "expected recorded tunnel process to be running"

  "$ROOT_DIR/skills/quiz-grilling/scripts/cleanup-session.sh" "$session" >/dev/null
  [[ ! -e "$session" ]] || fail "expected tunnel session cleanup"
  ! kill -0 "$tunnel_pid" 2>/dev/null || fail "expected recorded tunnel process to stop"
}

test_isolated_codex_review_timeout_exits() {
  local fake_bin output_file pid status alive attempt

  fake_bin="$WORKSPACES_DIR/fake-bin"
  output_file="$fake_bin/review-output"
  rm -rf "$fake_bin"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/codex" <<'FAKE'
#!/usr/bin/env bash
count=0
while IFS= read -r line; do
  count=$((count + 1))
  case "$count" in
    1) printf '{"id":1,"result":{}}\n' ;;
    3) printf '{"id":2,"result":{"thread":{"id":"thread-1"}}}\n' ;;
    4)
      printf '{"id":3,"result":{"turn":{"id":"turn-1"}}}\n'
      printf reached-review-start > "${CODEX_REVIEW_MARKER:?}"
      ;;
  esac
done
FAKE
  chmod +x "$fake_bin/codex"

  set +e
  CODEX_REVIEW_MARKER="$fake_bin/reached-review-start" \
    CODEX_BIN="$fake_bin/codex" \
    node "$ROOT_DIR/skills/run-codex-review/scripts/review.mjs" \
      --cwd "$ROOT_DIR" --custom smoke --timeout 1 \
      > "$output_file" 2>&1 &
  pid=$!
  set -e

  alive="true"
  for attempt in {1..60}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      alive="false"
      break
    fi
    sleep 0.05
  done

  if [[ "$alive" == "true" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "expected timed-out isolated review process to exit"
  fi

  set +e
  wait "$pid"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected timed-out isolated review to fail"
  [[ -f "$fake_bin/reached-review-start" ]] || fail "expected fake App Server to reach review/start"
  assert_contains "$(<"$output_file")" "Review timed out after 1 seconds"
}

run_test test_skills_bundle_is_self_contained_and_readme_documents_workflow
run_test test_quiz_grilling_server_validates_and_saves_a_round
run_test test_quiz_grilling_tunnel_records_and_cleans_owned_process
run_test test_isolated_codex_review_timeout_exits

echo "skill_docs_test.sh passed"
