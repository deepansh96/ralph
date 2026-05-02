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
