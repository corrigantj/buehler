# Backlog Capability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lightweight backlog capture, brainstorming awareness, and promotion lifecycle to buehler.

**Architecture:** Three discrete changes — a new Mode 3 on the issue skill for quick capture, a standalone PreToolUse hook that injects backlog count when brainstorming is invoked, and a new promotion step in the structure skill that closes backlog items when they become real stories.

**Tech Stack:** Bash (hook script), Markdown (skill docs), gh CLI (GitHub operations)

**Spec:** `docs/superpowers/specs/2026-03-30-backlog-capability-design.md`

---

### Task 1: Add Mode 3 (Backlog) to the Issue Skill

**Files:**
- Modify: `skills/issue/SKILL.md:1-14` (frontmatter description and invocation modes list)
- Modify: `skills/issue/SKILL.md:180` (append Mode 3 section after Mode 2: Fix)

- [ ] **Step 1: Update the skill description in frontmatter**

In `skills/issue/SKILL.md`, change the `description` field on line 3 from:

```yaml
description: Use when reporting a bug, filing an issue, investigating a problem, or fixing an already-investigated issue — supports ad-hoc issue creation, duplicate detection, root-cause investigation, severity/priority recommendation, and stabilization tracking
```

to:

```yaml
description: Use when reporting a bug, filing an issue, investigating a problem, fixing an already-investigated issue, or quickly capturing a backlog idea — supports ad-hoc issue creation, duplicate detection, root-cause investigation, severity/priority recommendation, stabilization tracking, and lightweight backlog capture
```

- [ ] **Step 2: Update the invocation modes list**

In `skills/issue/SKILL.md`, change the invocation modes section (lines 10-18) from:

```markdown
This skill has two modes:

1. **Investigate** (default) — `/issue {description}`
   Human describes a bug, enhancement, or problem. The skill spawns an investigator agent.

2. **Fix** — `/issue fix #{issue_number}`
   For an already-investigated issue. The skill spawns a fix agent.
```

to:

```markdown
This skill has three modes:

1. **Investigate** (default) — `/issue {description}`
   Human describes a bug, enhancement, or problem. The skill spawns an investigator agent.

2. **Fix** — `/issue fix #{issue_number}`
   For an already-investigated issue. The skill spawns a fix agent.

3. **Backlog** — `/issue backlog "idea title"` or `/issue backlog {tier} "idea title"`
   Quick capture of a backlog idea. No investigation, no milestone. Tier is `now`, `next`, `later` (default), or `icebox`.
```

- [ ] **Step 3: Add Mode 3 section at the end of the file**

Append the following after the last line of `skills/issue/SKILL.md` (after line 180):

```markdown

## Mode 3: Backlog

### Inputs

- A title string (`/issue backlog "idea title"`)
- Optional tier keyword: `now`, `next`, `later` (default), `icebox`

### Invocation Examples

```
/issue backlog "add rate limiting to public API"
/issue backlog now "fix onboarding flow before launch"
/issue backlog icebox "explore GraphQL migration"
```

### Checklist

1. **Parse arguments and create issue** — extract tier and title, create the GitHub issue (Step 1)
2. **Offer description** — ask if the user wants to add detail (Step 2)

### Process

#### Step 1: Parse Arguments and Create Issue

Parse the arguments after `backlog`:
- If the first word is `now`, `next`, `later`, or `icebox`, use it as the tier. The rest is the title.
- Otherwise, default tier is `later`. Everything after `backlog` is the title.
- Strip surrounding quotes from the title if present.

Read `owner`/`repo` from git remote:
```bash
gh repo view --json owner,name --jq '.owner.login + "/" + .name'
```

Create the issue:
```bash
gh issue create --repo {owner}/{repo} \
  --title "{title}" \
  --label "backlog:{tier}" --label "type:task" \
  --body ""
```

Capture the issue number from the output.

Report: `Backlog item #{number} created with backlog:{tier}`

#### Step 2: Offer Description

Ask the user: "Want to add any detail to the description for later?"

- If yes: take the user's input and update the issue:
  ```bash
  gh issue edit {number} --repo {owner}/{repo} --body "{user_input}"
  ```
- If no: done.

### What This Mode Does NOT Do

- No investigation or systematic debugging
- No duplicate check
- No severity/priority recommendation
- No stabilization ticket association
- No milestone assignment
- No agent spawning
```

- [ ] **Step 4: Review the full file for consistency**

Read `skills/issue/SKILL.md` end-to-end. Verify:
- Frontmatter description mentions backlog
- Invocation modes list shows three modes
- Mode 3 section follows Mode 2 cleanly
- No broken markdown formatting

- [ ] **Step 5: Commit**

```bash
git add skills/issue/SKILL.md
git commit -m "feat(issue): add Mode 3 backlog for quick idea capture"
```

---

### Task 2: Create the Brainstorming Context Hook

**Files:**
- Create: `hooks/backlog-context.sh`

- [ ] **Step 1: Create the hook script**

Create `hooks/backlog-context.sh` with the following content:

```bash
#!/usr/bin/env bash
# backlog-context.sh — PreToolUse hook for brainstorming context injection
# Injects backlog item count when superpowers:brainstorming is invoked.
# Does NOT gate — always allows. Only adds context.

set -uo pipefail

# Read tool input from stdin
input=$(cat)

# Extract skill name from the Skill tool input
skill_name=$(echo "$input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    skill = data.get('skill', '') or data.get('tool_input', {}).get('skill', '')
    print(skill)
except Exception:
    print('')
" 2>/dev/null) || skill_name=""

# Only inject context for brainstorming
if [ "$skill_name" != "superpowers:brainstorming" ]; then
  echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
  exit 0
fi

# Detect owner/repo from git remote
repo_slug=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null) || repo_slug=""

if [ -z "$repo_slug" ]; then
  echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
  exit 0
fi

# Count open backlog items across all tiers
# gh --label does AND matching, so query each tier separately
count=0
for tier in now next later icebox; do
  n=$(gh issue list --repo "$repo_slug" --label "backlog:${tier}" \
    --state open --json number --jq 'length' 2>/dev/null || echo 0)
  count=$((count + n))
done

# No backlog items — allow without context
if [ "$count" -eq 0 ]; then
  echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
  exit 0
fi

# Build the system message
read -r -d '' msg <<SYSMSG || true
This repo has ${count} open backlog items. Early in the brainstorming session, ask the user: "There are ${count} items in the backlog. Want me to check for anything relevant to what we're working on?" If they say yes, fetch the backlog issues with:
  for tier in now next later icebox; do
    gh issue list --repo ${repo_slug} --label "backlog:\${tier}" --state open --json number,title,labels
  done
Merge the results, cluster by theme, and present a summary.
SYSMSG

# Escape for JSON
escaped_msg=$(python3 -c "
import sys, json
print(json.dumps(sys.stdin.read().strip()))
" <<< "$msg" 2>/dev/null) || escaped_msg="\"backlog context unavailable\""

echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"},\"systemMessage\":${escaped_msg}}"
exit 0
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x hooks/backlog-context.sh
```

- [ ] **Step 3: Verify the script runs without errors on a bare invocation**

```bash
echo '{"skill":"not-brainstorming"}' | bash hooks/backlog-context.sh
```

Expected output:
```json
{"hookSpecificOutput":{"permissionDecision":"allow"}}
```

- [ ] **Step 4: Commit**

```bash
git add hooks/backlog-context.sh
git commit -m "feat(hooks): add backlog-context hook for brainstorming awareness"
```

---

### Task 3: Register the Hook in hooks.json

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 1: Add the second PreToolUse entry**

In `hooks/hooks.json`, change the `PreToolUse` array from:

```json
"PreToolUse": [
  {
    "matcher": "Skill",
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/preflight.sh",
        "async": false
      }
    ]
  }
]
```

to:

```json
"PreToolUse": [
  {
    "matcher": "Skill",
    "hooks": [
      {
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/preflight.sh",
        "async": false
      }
    ]
  },
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
]
```

- [ ] **Step 2: Validate the JSON**

```bash
python3 -m json.tool hooks/hooks.json > /dev/null
```

Expected: exits 0 with no output (valid JSON).

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(hooks): register backlog-context hook in hooks.json"
```

---

### Task 4: Add Backlog Promotion Step to Structure Skill

**Files:**
- Modify: `skills/structure/SKILL.md:24-26` (checklist item 7)
- Modify: `skills/structure/SKILL.md:279-304` (insert new step between 11a and 12)

- [ ] **Step 1: Update the checklist**

In `skills/structure/SKILL.md`, change checklist item 7 (line 26) from:

```markdown
7. **Validate and finalize** — post-creation validation, update PRD status to Active, present summary (Steps 12-14)
```

to:

```markdown
7. **Promote backlog items** — check for backlog items that map to new stories, offer batch promotion (Step 11b)
8. **Validate and finalize** — post-creation validation, update PRD status to Active, present summary (Steps 12-14)
```

- [ ] **Step 2: Insert Step 11b after Step 11a**

In `skills/structure/SKILL.md`, insert the following after the Step 11a section (after the line about "Item added to project" workflow automation, before `### Step 12`):

```markdown

### Step 11b: Promote Backlog Items

After all stories and tasks are created and added to the board, check for existing backlog items that may now be covered by the new milestone.

**11b-1. Fetch open backlog items:**

Query each tier separately (gh `--label` does AND matching):
```bash
backlog_items=""
for tier in now next later icebox; do
  items=$(gh issue list --repo {owner}/{repo} --label "backlog:${tier}" \
    --state open --json number,title,labels 2>/dev/null || echo "[]")
  backlog_items="${backlog_items}${items}"
done
```

Merge results and deduplicate by issue number.

If no backlog items exist, skip this step entirely and proceed to Step 12.

**11b-2. Match against new stories/tasks:**

Compare backlog item titles against the titles of stories and tasks just created in Steps 9-10. Look for conceptual matches: same feature area, overlapping keywords, related functionality.

If no matches are found, skip to Step 12.

**11b-3. Present matches for user approval:**

```
These backlog items appear to map to new stories:
  #{old_number} "{old_title}" → Story #{new_number} "{new_title}"
  #{old_number} "{old_title}" → Story #{new_number} "{new_title}"

Promote all, select individually, or skip?
```

- **Promote all:** process the entire batch in one go
- **Select individually:** let the user pick which items to promote
- **Skip:** leave all backlog items as-is, proceed to Step 12

**11b-4. Execute promotion (per item):**

For each promoted backlog item:

1. Append to the **new issue** body:
   ```bash
   # Get existing body, append supersedes line
   existing_body=$(gh issue view {new_number} --repo {owner}/{repo} --json body --jq '.body')
   gh issue edit {new_number} --repo {owner}/{repo} \
     --body "${existing_body}

   Supersedes backlog item #{old_number}"
   ```

2. Comment on the **backlog issue**:
   ```bash
   gh issue comment {old_number} --repo {owner}/{repo} \
     --body "Promoted to #{new_number} in milestone {milestone_title}"
   ```

3. Remove the `backlog:*` label:
   ```bash
   gh issue edit {old_number} --repo {owner}/{repo} \
     --remove-label "backlog:now,backlog:next,backlog:later,backlog:icebox"
   ```

4. Close the backlog issue:
   ```bash
   gh issue close {old_number} --repo {owner}/{repo} --reason completed
   ```
```

- [ ] **Step 3: Update step numbering references**

Verify that the existing Step 12, Step 13, and Step 14 headings and any cross-references remain correct. The step numbers themselves don't change — only the checklist gains item 7 (backlog) and the old item 7 becomes item 8. The step headings (Step 12, 13, 14) stay the same.

- [ ] **Step 4: Review the full structure skill for consistency**

Read `skills/structure/SKILL.md` end-to-end. Verify:
- Checklist has 8 items
- Step 11b appears between Step 11a and Step 12
- No broken markdown formatting
- No dangling references

- [ ] **Step 5: Commit**

```bash
git add skills/structure/SKILL.md
git commit -m "feat(structure): add backlog promotion step (Step 11b)"
```

---

### Task 5: Update CLAUDE.md and Session-Start Hook

**Files:**
- Modify: `CLAUDE.md` (skill routing table, plugin structure, skill reference)
- Modify: `hooks/session-start.sh` (routing table)

- [ ] **Step 1: Update the plugin structure tree in CLAUDE.md**

In `CLAUDE.md`, change the hooks directory section from:

```
├── hooks/                         # SessionStart + PreToolUse hooks
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse)
│   ├── session-start.sh           # Injects slim routing table on session start
│   └── preflight.sh               # PreToolUse gate — runs preflight before gated skills
```

to:

```
├── hooks/                         # SessionStart + PreToolUse hooks
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse)
│   ├── session-start.sh           # Injects slim routing table on session start
│   ├── preflight.sh               # PreToolUse gate — runs preflight before gated skills
│   └── backlog-context.sh         # Injects backlog count into brainstorming sessions
```

- [ ] **Step 2: Update the issue skill description in CLAUDE.md**

In `CLAUDE.md`, change the Skill Reference table entry for issue from:

```markdown
| `buehler:issue` | Ad-hoc issue creation, investigation, triage, and fix execution |
```

to:

```markdown
| `buehler:issue` | Ad-hoc issue creation, investigation, triage, fix execution, and backlog capture |
```

- [ ] **Step 3: Add backlog routing to session-start.sh**

In `hooks/session-start.sh`, add a new row to the routing table. Change:

```
| \"Fix issue #N\" | buehler:issue |
```

to:

```
| \"Fix issue #N\" | buehler:issue |
| \"Backlog\" / \"Remember this idea\" / \"Quick capture\" | buehler:issue (backlog mode) |
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md hooks/session-start.sh
git commit -m "docs: update CLAUDE.md and routing table for backlog capability"
```

---

### Task 6: End-to-End Verification

**Files:** (no changes — verification only)

- [ ] **Step 1: Verify all modified files parse correctly**

```bash
# JSON validation
python3 -m json.tool hooks/hooks.json > /dev/null

# Shell syntax check
bash -n hooks/backlog-context.sh
bash -n hooks/session-start.sh

# Verify executable bit
test -x hooks/backlog-context.sh && echo "executable" || echo "NOT executable"
```

Expected: all pass.

- [ ] **Step 2: Verify the hook passthrough for non-brainstorming skills**

```bash
echo '{"skill":"buehler:structure"}' | bash hooks/backlog-context.sh
```

Expected:
```json
{"hookSpecificOutput":{"permissionDecision":"allow"}}
```

- [ ] **Step 3: Verify the hook fires for brainstorming**

```bash
echo '{"skill":"superpowers:brainstorming"}' | bash hooks/backlog-context.sh
```

Expected: either a bare `allow` (if no backlog items exist in the repo) or an `allow` with a `systemMessage` containing the backlog count.

- [ ] **Step 4: Spot-check skill markdown rendering**

Read the top of `skills/issue/SKILL.md` and confirm:
- Three modes listed
- Mode 3 description is clear
- No formatting artifacts

Read `skills/structure/SKILL.md` checklist and confirm:
- 8 items listed
- Item 7 is "Promote backlog items"
- Item 8 is "Validate and finalize"

- [ ] **Step 5: Verify git status is clean**

```bash
git status
```

Expected: clean working tree, all changes committed across Tasks 1-5.
