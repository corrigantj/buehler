# Backlog Capability Design

**Date:** 2026-03-30
**Status:** Draft
**Origin:** Travis & Derek working session transcript (2026-03-24)

## Summary

Add a lightweight backlog capture and lifecycle to buehler. Backlog items are GitHub issues with no milestone — "digital sticky notes" that can be quickly created, surfaced during brainstorming, and promoted into structured work during milestone planning.

Three components:
1. **Quick capture** — new `backlog` mode on `buehler:issue`
2. **Brainstorming awareness** — standalone PreToolUse hook injects backlog count when `superpowers:brainstorming` is invoked
3. **Promotion during structure** — close backlog items with cross-references when they become real stories/tasks

## Component 1: Issue Skill — Mode 3: Backlog

### Invocation

```
/issue backlog "idea title"
/issue backlog now "idea title"
/issue backlog next "idea title"
/issue backlog later "idea title"
/issue backlog icebox "idea title"
```

### Behavior

1. Parse arguments:
   - Optional tier keyword: `now`, `next`, `later`, `icebox` (default: `later`)
   - Required: quoted title string
2. Read `owner`/`repo` from git remote (same as existing issue modes)
3. Create a GitHub issue:
   - **Title:** the provided string
   - **Labels:** `backlog:{tier}`, `type:task`
   - **Milestone:** none
   - **Body:** empty
4. Report: `Backlog item #{number} created with backlog:{tier}`
5. Ask: "Want to add any detail to the description for later?"
   - If yes: take user input, update the issue body via `gh issue edit`
   - If no: done

### What This Mode Does NOT Do

- No investigation
- No duplicate check
- No severity/priority recommendation
- No stabilization ticket association
- No milestone assignment

### Changes to `skills/issue/SKILL.md`

Add a "Mode 3: Backlog" section after the existing Mode 2 (Fix). Update the invocation modes list at the top to include the third mode.

## Component 2: Brainstorming Hook — `backlog-context.sh`

### New File

`hooks/backlog-context.sh` — a standalone PreToolUse hook.

### Registration

Add a second entry to the `PreToolUse` array in `hooks/hooks.json`:

```json
{
  "matcher": "Skill",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/hooks/backlog-context.sh",
      "async": false
    }
  ]
}
```

This runs alongside `preflight.sh` — both match on `Skill`, both execute independently.

### Behavior

1. Read stdin JSON, extract skill name (same parsing pattern as `preflight.sh`)
2. If skill is not `superpowers:brainstorming`:
   - Return `{"hookSpecificOutput":{"permissionDecision":"allow"}}`
   - Exit
3. Read `owner`/`repo` from git remote
4. Query GitHub for open backlog items. Note: `gh issue list --label` does AND matching, so we must query each tier separately and combine:
   ```bash
   count=0
   for tier in now next later icebox; do
     n=$(gh issue list --repo {owner}/{repo} --label "backlog:${tier}" \
       --state open --json number --jq 'length' 2>/dev/null || echo 0)
     count=$((count + n))
   done
   ```
5. If count is 0:
   - Return bare `allow`
   - Exit
6. If count > 0:
   - Return `allow` with `systemMessage`:
     ```
     This repo has {N} open backlog items. Early in the brainstorming
     session, ask the user: "There are {N} items in the backlog. Want
     me to check for anything relevant to what we're working on?"
     If they say yes, fetch the backlog issues with:
       for tier in now next later icebox; do
         gh issue list --repo {owner}/{repo} --label "backlog:${tier}" \
           --state open --json number,title,labels
       done
     Merge the results, cluster by theme, and present a summary.
     ```

### Design Decisions

- **Standalone hook, not part of preflight.sh** — separation of concerns. Preflight gates buehler skills; this injects context into a superpowers skill.
- **Count-only query first** — avoids fetching full issue list when there are no backlog items. The full fetch only happens if the user opts in during brainstorming.
- **`systemMessage` contains the follow-up query** — Claude knows how to fetch the details if the user says yes, without the hook needing to pre-fetch everything.

## Component 3: Structure Promotion Step

### Where

`skills/structure/SKILL.md` — new step after stories and tasks are created (after current Step 11a, before validation in Step 12).

### Behavior

After all stories and tasks are created for the new milestone:

1. Fetch open backlog items (query each tier separately since `--label` does AND matching):
   ```bash
   for tier in now next later icebox; do
     gh issue list --repo {owner}/{repo} --label "backlog:${tier}" \
       --state open --json number,title,labels
   done
   ```
   Merge results and deduplicate by issue number.
2. If none exist, skip this step.
3. Compare backlog item titles against newly created story/task titles. Look for conceptual matches (same feature area, overlapping keywords).
4. If matches are found, present them to the user:
   ```
   These backlog items appear to map to new stories:
     #14 "rate limiting" → Story #28 "API Rate Limiting"
     #19 "audit logging" → Story #30 "Audit Trail"

   Promote all, select individually, or skip?
   ```
5. On **promote all**: process entire batch
6. On **select individually**: let user pick which to promote
7. On **skip**: leave backlog items as-is

### Promotion Action (per item)

For each promoted backlog item:
1. Add a line to the **new issue** body: `Supersedes backlog item #{old_number}`
2. Add a comment to the **backlog issue**: `Promoted to #{new_number} in milestone {milestone_title}`
3. Remove the `backlog:*` label from the backlog issue
4. Close the backlog issue:
   ```bash
   gh issue close {old_number} --repo {owner}/{repo} --reason completed
   ```

## Files Changed

| File | Change |
|------|--------|
| `skills/issue/SKILL.md` | Add Mode 3: Backlog section |
| `hooks/backlog-context.sh` | New file — brainstorming context injection hook |
| `hooks/hooks.json` | Add second PreToolUse entry for backlog-context.sh |
| `skills/structure/SKILL.md` | Add backlog promotion step after story/task creation |
| `CLAUDE.md` | Update skill routing table to mention backlog mode |

## Files NOT Changed

| File | Reason |
|------|--------|
| `superpowers:brainstorming` | Not our plugin; context injection via hook is sufficient |
| `scripts/preflight-checks/check-labels.sh` | `backlog:*` labels already exist |
| `templates/buehler.yaml` | No new configuration needed |
| `agents/implementer.md` | Backlog items are not dispatched |

## Out of Scope

- **Standalone backlog sweep command** — can be added later if brainstorming integration proves insufficient
- **Automatic duplicate detection on backlog capture** — intentionally omitted for speed; backlog is low-rigor
- **Backlog item enrichment/investigation** — use the existing `/issue {description}` investigate mode if an item needs proper triage
