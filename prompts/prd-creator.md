# PRD Generator

Create detailed Product Requirements Documents that are clear, actionable, and suitable for implementation.

---

## The Job

1. Receive a feature description from the user
2. **Discover the project's testing setup** (see below)
3. Ask 3-5 essential clarifying questions (with lettered options)
4. Generate a structured PRD based on answers
5. Save to `ralph/workspaces/[feature-name]/prd-[feature-name].md` (create the workspace folder if it doesn't exist)

**Important:** Do NOT start implementing. Just create the PRD.

---

## Step 0: Discover Testing Setup

Before asking clarifying questions, explore the project to understand what testing infrastructure exists. This determines what test criteria go into each user story.

**What to look for:**

1. **Unit tests** — Search for test directories and config files:
   - `tests/`, `test/`, `__tests__/`, `spec/`, `**/test_*.py`, `**/*.test.ts`, `**/*.spec.ts`
   - Config: `pytest.ini`, `pyproject.toml [tool.pytest]`, `jest.config.*`, `vitest.config.*`, `karma.conf.*`
   - Run command: check `package.json` scripts, `Makefile`, `CLAUDE.md`

2. **Integration tests** — Look for:
   - Separate test directories like `tests/integration/`, `tests/api/`
   - Database fixtures, test containers, or test DB setup scripts
   - API test files (e.g., `test_api_*.py`, `*.integration.test.ts`)

3. **E2E tests** — Look for:
   - Playwright: `playwright.config.*`, `e2e/`, `**/*.spec.ts` (in e2e dir)
   - Cypress: `cypress.config.*`, `cypress/`
   - Custom runners: `run_tests.sh`, `test-e2e` scripts

4. **Build/lint checks** — Look for:
   - `npm run build`, `npm run lint`, `tsc --noEmit`
   - Pre-existing lint errors (note count if many — don't block on pre-existing ones)

5. **CLAUDE.md** — Read it if it exists. It often documents exact test commands and known issues.

**Record what you find.** Include it in the PRD's Technical Considerations section and use the exact commands in acceptance criteria. If a testing layer doesn't exist, don't invent criteria for it — only reference what the project actually has.

---

## Step 1: Clarifying Questions

Ask only critical questions where the initial prompt is ambiguous. Focus on:

- **Problem/Goal:** What problem does this solve?
- **Core Functionality:** What are the key actions?
- **Scope/Boundaries:** What should it NOT do?
- **Success Criteria:** How do we know it's done?

### Format Questions Like This:

```
1. What is the primary goal of this feature?
   A. Improve user onboarding experience
   B. Increase user retention
   C. Reduce support burden
   D. Other: [please specify]

2. Who is the target user?
   A. New users only
   B. Existing users only
   C. All users
   D. Admin users only

3. What is the scope?
   A. Minimal viable version
   B. Full-featured implementation
   C. Just the backend/API
   D. Just the UI
```

This lets users respond with "1A, 2C, 3B" for quick iteration or they can also type in detail.

---

## Step 2: PRD Structure

Generate the PRD with these sections:

### 1. Introduction/Overview
Brief description of the feature and the problem it solves.

### 2. Goals
Specific, measurable objectives (bullet list).

### 3. User Stories
Each story needs:
- **Title:** Short descriptive name
- **Description:** "As a [user], I want [feature] so that [benefit]"
- **Acceptance Criteria:** Verifiable checklist of what "done" means

Each story should be small enough to implement in one focused session.

**Format:**
```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Acceptance Criteria:**
- [ ] Specific verifiable criterion
- [ ] Another criterion
- [ ] **[Backend]** Unit tests added and passing (`<exact command from Step 0>`)
- [ ] **[Frontend]** Build passes (`<exact command from Step 0>`)
- [ ] **[UI stories only]** Verify in browser using agent-browser. (See agent-browser --help)
```

**Important:**
- Acceptance criteria must be verifiable, not vague. "Works correctly" is bad. "Button shows confirmation dialog before deleting" is good.
- **Use the exact test commands you discovered in Step 0.** Do not write generic "tests pass" — write the actual command (e.g., `cd server && python -m pytest tests/ -v`, `npm run build`, `./run_tests.sh notifications.spec.js`).
- **Only include test criteria for test types that exist.** If the project has no E2E tests, don't add E2E criteria. If there are no frontend unit tests, don't add them. Match what the project actually has.
- **For any story with UI changes:** Always include "Verify in browser using agent-browser" as acceptance criteria. This ensures visual verification of frontend work.
- **If the project has E2E tests:** Add E2E criteria to UI stories with the exact runner command and relevant spec file.
- **Note pre-existing issues:** If lint has 300+ pre-existing errors, note that in the criteria so Ralph doesn't block on them (e.g., "Lint passes — fix errors you introduced; N pre-existing errors exist").
- **Always add a final review story:** Every PRD must end with a review story that explores the codebase, reviews all changes made, and documents findings in the workspace's review file. This ensures quality control and a summary of what was accomplished.

### 4. Functional Requirements
Numbered list of specific functionalities:
- "FR-1: The system must allow users to..."
- "FR-2: When a user clicks X, the system must..."

Be explicit and unambiguous.

### 5. Non-Goals (Out of Scope)
What this feature will NOT include. Critical for managing scope.

### 6. Design Considerations (Optional)
- UI/UX requirements
- Link to mockups if available
- Relevant existing components to reuse

### 7. Technical Considerations (Optional)
- Known constraints or dependencies
- Integration points with existing systems
- Performance requirements

### 8. Success Metrics
How will success be measured?
- "Reduce time to complete X by 50%"
- "Increase conversion rate by 10%"

### 9. Open Questions
Remaining questions or areas needing clarification.

---

## Writing for Junior Developers

The PRD reader may be a junior developer or AI agent. Therefore:

- Be explicit and unambiguous
- Avoid jargon or explain it
- Provide enough detail to understand purpose and core logic
- Number requirements for easy reference
- Use concrete examples where helpful

---

## Output

- **Format:** Markdown (`.md`)
- **Location:** `ralph/workspaces/[feature-name]/`
- **Filename:** `prd-[feature-name].md` (kebab-case)

---

## Example PRD

```markdown
# PRD: Task Priority System

## Introduction

Add priority levels to tasks so users can focus on what matters most. Tasks can be marked as high, medium, or low priority, with visual indicators and filtering to help users manage their workload effectively.

## Goals

- Allow assigning priority (high/medium/low) to any task
- Provide clear visual differentiation between priority levels
- Enable filtering and sorting by priority
- Default new tasks to medium priority

## User Stories

### US-001: Add priority field to database
**Description:** As a developer, I need to store task priority so it persists across sessions.

**Acceptance Criteria:**
- [ ] Add priority column to tasks table: 'high' | 'medium' | 'low' (default 'medium')
- [ ] Generate and run migration successfully
- [ ] Unit tests added and passing

### US-002: Display priority indicator on task cards
**Description:** As a user, I want to see task priority at a glance so I know what needs attention first.

**Acceptance Criteria:**
- [ ] Each task card shows colored priority badge (red=high, yellow=medium, gray=low)
- [ ] Priority visible without hovering or clicking
- [ ] Build passes
- [ ] Verify in browser using agent-browser

### US-003: Add priority selector to task edit
**Description:** As a user, I want to change a task's priority when editing it.

**Acceptance Criteria:**
- [ ] Priority dropdown in task edit modal
- [ ] Shows current priority as selected
- [ ] Saves immediately on selection change
- [ ] Build passes
- [ ] Verify in browser using agent-browser

### US-004: Filter tasks by priority
**Description:** As a user, I want to filter the task list to see only high-priority items when I'm focused.

**Acceptance Criteria:**
- [ ] Filter dropdown with options: All | High | Medium | Low
- [ ] Filter persists in URL params
- [ ] Empty state message when no tasks match filter
- [ ] Build passes
- [ ] Verify in browser using agent-browser

### US-005: Review changes and document findings
**Description:** As a developer, I want to review all changes made during this feature implementation to ensure nothing was missed and document the results.

**Acceptance Criteria:**
- [ ] Use explore agents to understand the current state of modified files
- [ ] Review git diff to see all changes made
- [ ] Verify no unintended side effects or missing pieces
- [ ] Create `ralph/workspaces/[feature-name]/[feature]-review.txt` with concise findings (under 50 lines)
- [ ] Review file summarizes: what was done, files changed, any concerns or recommendations

## Functional Requirements

- FR-1: Add `priority` field to tasks table ('high' | 'medium' | 'low', default 'medium')
- FR-2: Display colored priority badge on each task card
- FR-3: Include priority selector in task edit modal
- FR-4: Add priority filter dropdown to task list header
- FR-5: Sort by priority within each status column (high to medium to low)

## Non-Goals

- No priority-based notifications or reminders
- No automatic priority assignment based on due date
- No priority inheritance for subtasks

## Technical Considerations

- Reuse existing badge component with color variants
- Filter state managed via URL search params
- Priority stored in database, not computed

## Success Metrics

- Users can change priority in under 2 clicks
- High-priority tasks immediately visible at top of lists
- No regression in task list performance

## Open Questions

- Should priority affect task ordering within a column?
- Should we add keyboard shortcuts for priority changes?
```

---

## Checklist

Before saving the PRD:

- [ ] **Explored project testing setup** (unit, integration, E2E, build, lint)
- [ ] Asked clarifying questions with lettered options
- [ ] Incorporated user's answers
- [ ] User stories are small and specific
- [ ] Functional requirements are numbered and unambiguous
- [ ] Non-goals section defines clear boundaries
- [ ] **Final story is a review step** (explores codebase, reviews changes, writes findings to .txt file)
- [ ] Saved to `ralph/workspaces/[feature-name]/prd-[feature-name].md`

---

## Session Tracking (Claude Code)

When working with Ralph, record your session ID in progress.txt so future iterations can reference your work if needed.

**Getting Session ID**: Run this command to get your current session ID:
```bash
project_encoded=$(pwd | tr '/' '-' | sed 's/^-//')
session_file=$(stat -f '%m %N' ~/.claude/projects/-${project_encoded}/*.jsonl 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
basename "$session_file" .jsonl
```

Future iterations can resume context using `claude --resume <session-id>` if deeper context is needed.
