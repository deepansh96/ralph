RALPH PIPELINE — OPERATIONAL GUIDE
======================================
Lessons from running issue #266 (Remove Eraser Tool) end-to-end.


1. NEVER PIPE RALPH THROUGH HEAD/TAIL
--------------------------------------
Ralph spawns long-running subprocesses (claude -p, codex exec, pi) that produce
output slowly. Piping through head/tail causes buffering deadlocks — the
command appears frozen with zero output.

DO:   ./ralph/ralph.sh --issue N --steps 1   (run in background mode)
DON'T: ./ralph/ralph.sh --issue N 2>&1 | head -100


2. KILL SUBPROCESSES WHEN STOPPING RALPH
-----------------------------------------
ralph.sh and the spawned agent (claude -p / codex / pi) are separate PIDs.
Killing ralph.sh alone leaves the agent running as an orphan. The orphan
may complete its step, but it will not update state.json or auto-advance
to the next step. Only ralph.sh updates state.json. If ralph.sh is killed
without resetting the active step, that step stays in_progress forever.

To stop cleanly:
  1. Kill ralph.sh
  2. ps aux | grep -E 'claude -p|codex|(/|[[:space:]])pi[[:space:]].*--provider[[:space:]]+deepseek' | grep -v grep
  3. Kill the matching agent subprocess(es)
  4. Check state.json and reset any in_progress step to pending


3. CLEAN WORKING TREE AND GRILLING DOCS BEFORE PREFLIGHT
----------------------------------------
Preflight checks git status --porcelain and fails if anything is dirty.
Common culprit: uncommitted grilling output, such as CONTEXT.md or ADR
changes created while still on main.

Fix: ask user, then commit and push those docs to the branch that should be
the feature base. For speculative work, that is usually a grill/* planning
branch, and state.json .baseBranch should point at that branch. For accepted
mainline docs, merge or push them to main and use main as .baseBranch.


4. RESETTING FAILED STEPS
---------------------------
To retry a failed step:
  1. Let cleanup-local-resources finish.
  2. Reset only that step with jq, then validate the result:

     state_file="workspaces/<issue>/state.json"
     step_id="<failed-step-id>"
     jq --arg id "$step_id" \
       '(.steps[] | select(.id == $id)) |= (.status = "pending" | .metrics = null | .notes = "")' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
     jq . "$state_file" > /dev/null

Ralph rearms completed always-run cleanup when normal work is retried.

IMPORTANT: Always mutate and validate state.json with jq.


5. CODEX CWD IN SUBMODULE SETUP
---------------------------------
When ralph is a git submodule, codex inherits the submodule's CWD by
default. The -C flag on codex only controls the file sandbox, NOT the
shell CWD. So git checkout <feature-branch> fails because the branch
doesn't exist in the ralph repo.

Fix (already applied in agent.sh):
  Wrap codex in a subshell that cds to the project root first:
    (cd "$project_root" && codex -a never exec ...)

  project_root is derived via:
    git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel


6. GITHUB ISSUE BODY VS COMMENTS
----------------------------------
gh issue view only reads the issue body, NOT comments. All downstream
steps (PRD, slices, implementation) read the issue via gh issue view.

Therefore: council findings, PRD content, and review summaries must be
written to the issue BODY using:
  gh issue edit N --repo owner/repo --body-file <file>

NOT posted as comments with gh issue comment.


7. MONITORING PROGRESS
-----------------------
Several ways to check what's happening:

a) Step status:
   cat state.json | python3 -c "import json,sys; ..."

b) Tail the agent's jsonl session:
   find ~/.claude/projects/<project> -name "*.jsonl" -exec stat -f '%m %N' {} \; | sort -rn | head -1
   Then tail the most recent file and parse the last entries.

c) Council review progress:
   ls .council/          — check for new run directories
   ls .council/<dir>/    — check which agents have *_done.txt files

d) Process check:
   ps aux | grep -E 'claude -p|codex|council-review|(/|[[:space:]])pi[[:space:]].*--provider[[:space:]]+deepseek' | grep -v grep


8. STEP TIMING EXPECTATIONS
-----------------------------
From the issue #266 run:

  review-decisions (with council):  ~13 min
  review-decisions (HITL resume):   ~1 min
  create-and-review-prd:            ~29 min  (PRD + 2 council rounds)
  create-and-review-slices:         ~37 min  (slices + 2 council rounds)
  preflight:                        ~2 min
  implement-slice (codex):          ~6-9 min each
  post-implementation steps:        not yet benchmarked after the QA/review split

  Historical total before split:    ~2.4 hours, ~$19


9. HITL (HUMAN-IN-THE-LOOP) FLOW
-----------------------------------
When a step has hitl: true and produces open questions:
  1. Ralph creates a flag file: workspaces/<N>/hitl-<step-id>.md
  2. Ralph stops and prints the flag file path
  3. Human writes answers in the ## Answers section of the flag file
  4. Re-run ralph — it detects the answered flag file and resumes
     without re-running the council review
