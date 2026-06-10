# Issue Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `buehler:issue` skill and `investigator` agent that enable ad-hoc issue creation, investigation, triage, and stabilization tracking within the buehler plugin.

**Architecture:** Thin skill (SKILL.md) dispatches to an investigator subagent for all real work. Stabilization tickets are created deterministically by a bash script at milestone creation time and verified by a preflight check. Severity labels are added to the hardcoded taxonomy in check-labels.sh.

**Tech Stack:** Bash (scripts), Markdown (skill/agent definitions, templates), gh CLI, GitHub API

**Spec:** `docs/superpowers/specs/2026-03-24-issue-skill-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `skills/issue/SKILL.md` | Create | Skill definition: thin dispatcher, two invocation modes |
| `skills/issue/investigator-prompt.md` | Create | Dynamic context template filled before spawning agent |
| `agents/investigator.md` | Create | Static agent definition: 10-phase execution procedure |
| `scripts/create-stabilization-ticket.sh` | Create | Idempotent stabilization ticket creation for a milestone |
| `scripts/preflight-checks/check-stabilization.sh` | Create | Verify stabilization tickets exist for open milestones |
| `scripts/preflight-checks/check-labels.sh` | Modify (lines 65-69) | Add severity labels after backlog labels block |
| `scripts/preflight-checks/runner.sh` | Modify (line 94) | Add `check-stabilization.sh` to run list |
| `skills/structure/SKILL.md` | Modify (after line 172) | Add Step 7a: create stabilization ticket |
| `skills/integrate/SKILL.md` | Modify (lines 39-51) | Add stabilization check to pre-integration audit |
| `hooks/session-start.sh` | Modify (lines 25-31) | Add issue routing entry |
| `skills/status/SKILL.md` | Modify (lines 96-109) | Add stabilization ticket grouping and severity label display |
| `skills/setup/SKILL.md` | Modify (lines 108-114, 240-248) | Add severity labels to wizard, stabilization remediation to Step 6 |
| `hooks/preflight.sh` | Modify (line 29) | Add `buehler:issue` to preflight gate |
| `CLAUDE.md` | Modify | Update plugin structure tree and skill reference table |

---

### Task 1: Add Severity Labels to check-labels.sh

**Files:**
- Modify: `scripts/preflight-checks/check-labels.sh:63-69`

- [ ] **Step 1: Read the existing file to confirm insertion point**

Open `scripts/preflight-checks/check-labels.sh`. The severity labels go after the backlog labels block (line 69) and before the custom labels section (line 71). Confirm lines 65-69 are:
```bash
# Backlog labels
check_label "backlog:now"    "ededed" "Deliver this sprint"
check_label "backlog:next"   "ededed" "Deliver next sprint"
check_label "backlog:later"  "ededed" "Planned but not yet scheduled"
check_label "backlog:icebox" "ededed" "Deprioritized indefinitely"
```

- [ ] **Step 2: Add severity labels block**

Insert after line 69 (after the backlog labels block, before the blank line and custom labels section):

```bash

# Severity labels
check_label "severity:critical" "b60205" "Data loss, crash, or security vulnerability"
check_label "severity:major"    "d93f0b" "Broken feature, no workaround"
check_label "severity:minor"    "fbca04" "Broken feature, workaround exists"
check_label "severity:trivial"  "0e8a16" "Cosmetic or minor inconvenience"
```

- [ ] **Step 3: Verify the script still runs**

Run: `bash scripts/preflight-checks/check-labels.sh 2>&1 | head -5`

This will fail (no OWNER/REPO env vars in isolation) but should not have syntax errors. A syntax error produces a different message than a missing variable error.

- [ ] **Step 4: Commit**

```bash
git add scripts/preflight-checks/check-labels.sh
git commit -m "feat(preflight): add severity labels to default taxonomy"
```

---

### Task 2: Create Stabilization Ticket Script

**Files:**
- Create: `scripts/create-stabilization-ticket.sh`

Reference: `scripts/preflight-checks/check-codeowners.sh` for the bash pattern (set -euo pipefail, emit function, gh CLI calls).

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# create-stabilization-ticket.sh — Create a stabilization ticket for a milestone
# Usage: create-stabilization-ticket.sh --owner OWNER --repo REPO --milestone-title TITLE --milestone-number NUMBER [--wiki-meta-url URL]
# Idempotent: exits 0 with existing issue number if ticket already exists.

set -euo pipefail

OWNER=""
REPO=""
MILESTONE_TITLE=""
MILESTONE_NUMBER=""
WIKI_META_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --milestone-title) MILESTONE_TITLE="$2"; shift 2 ;;
    --milestone-number) MILESTONE_NUMBER="$2"; shift 2 ;;
    --wiki-meta-url) WIKI_META_URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${OWNER:?--owner required}"
: "${REPO:?--repo required}"
: "${MILESTONE_TITLE:?--milestone-title required}"
: "${MILESTONE_NUMBER:?--milestone-number required}"

TICKET_TITLE="Stabilization: ${MILESTONE_TITLE}"

# Idempotent: check if one already exists
existing=$(gh issue list --repo "${OWNER}/${REPO}" --milestone "${MILESTONE_TITLE}" \
  --search "\"${TICKET_TITLE}\" in:title" --json number,title --jq \
  ".[] | select(.title == \"${TICKET_TITLE}\") | .number" 2>/dev/null | head -1 || echo "")

if [ -n "$existing" ]; then
  echo "${existing}"
  exit 0
fi

# Build body
body="## Stabilization Ticket

This is the parent ticket for all stabilization work in milestone **${MILESTONE_TITLE}**.

Issues discovered during testing, review, or post-integration use are filed as sub-issues of this ticket.

**Exit criteria:** All child issues must be closed before the milestone can be closed."

if [ -n "$WIKI_META_URL" ]; then
  body="${body}

**Feature wiki:** ${WIKI_META_URL}"
fi

# Create the issue
issue_number=$(gh issue create --repo "${OWNER}/${REPO}" \
  --title "${TICKET_TITLE}" \
  --body "${body}" \
  --milestone "${MILESTONE_TITLE}" \
  --label "type:task" --label "meta:ignore" \
  --json number --jq '.number' 2>/dev/null)

echo "${issue_number}"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/create-stabilization-ticket.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/create-stabilization-ticket.sh
git commit -m "feat: add idempotent stabilization ticket creation script"
```

---

### Task 3: Create Stabilization Preflight Check

**Files:**
- Create: `scripts/preflight-checks/check-stabilization.sh`
- Modify: `scripts/preflight-checks/runner.sh:94`

Reference: `scripts/preflight-checks/check-codeowners.sh` for the emit pattern.

- [ ] **Step 1: Create the check script**

```bash
#!/usr/bin/env bash
# check-stabilization.sh — Verify stabilization tickets exist for open milestones
set -euo pipefail

: "${OWNER:?OWNER env var required}"
: "${REPO:?REPO env var required}"

emit() {
  local check="$1" status="$2" message="$3" fix="${4:-}"
  if [ -n "$fix" ]; then
    jq -nc --arg c "$check" --arg s "$status" --arg m "$message" --arg f "$fix" \
      '{check:$c, status:$s, message:$m, fix:$f}'
  else
    jq -nc --arg c "$check" --arg s "$status" --arg m "$message" \
      '{check:$c, status:$s, message:$m}'
  fi
}

# Fetch open milestones
milestones=$(gh api "repos/${OWNER}/${REPO}/milestones?state=open" \
  --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null || echo "")

if [ -z "$milestones" ]; then
  emit "stabilization.no_milestones" "pass" "No open milestones — nothing to check"
  exit 0
fi

all_pass=true

while IFS=$'\t' read -r ms_number ms_title; do
  [ -z "$ms_number" ] && continue

  ticket_title="Stabilization: ${ms_title}"
  existing=$(gh issue list --repo "${OWNER}/${REPO}" --milestone "${ms_title}" \
    --search "\"${ticket_title}\" in:title" --json number,title --jq \
    ".[] | select(.title == \"${ticket_title}\") | .number" 2>/dev/null | head -1 || echo "")

  if [ -n "$existing" ]; then
    emit "stabilization.${ms_title}" "pass" \
      "Stabilization ticket #${existing} exists for milestone ${ms_title}"
  else
    all_pass=false
    emit "stabilization.${ms_title}" "warn" \
      "No stabilization ticket found for milestone ${ms_title}" \
      "Run: bash scripts/create-stabilization-ticket.sh --owner ${OWNER} --repo ${REPO} --milestone-title '${ms_title}' --milestone-number ${ms_number}"
  fi
done <<< "$milestones"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/preflight-checks/check-stabilization.sh`

- [ ] **Step 3: Add to runner.sh**

In `scripts/preflight-checks/runner.sh`, insert after line 94 (`run_check "codeowners" ...`):

```bash
run_check "stabilization" "${SCRIPT_DIR}/check-stabilization.sh"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/preflight-checks/check-stabilization.sh scripts/preflight-checks/runner.sh
git commit -m "feat(preflight): add stabilization ticket check for open milestones"
```

---

### Task 4: Create the Investigator Agent Definition

**Files:**
- Create: `agents/investigator.md`

Reference: `agents/implementer.md` for the frontmatter pattern and overall structure.

- [ ] **Step 1: Create the agent file**

Write `agents/investigator.md` with the following content. The frontmatter follows the implementer pattern (name, description with examples, model, permissionMode):

```markdown
---
name: investigator
description: |
  Use this agent to investigate a reported issue — spike it into a GitHub Issue, run systematic debugging to find root cause, and recommend severity/priority. Spawned by the buehler:issue skill, never by humans directly. Each agent receives a human's issue description, detects milestone context, checks for duplicates, creates the issue, investigates using superpowers:systematic-debugging, and returns a structured result with severity/priority recommendation. Follows a 10-phase execution procedure. Examples: <example>Context: Human reports a bug during testing. user: "Investigate: the login page crashes when email contains a plus sign" assistant: "Spawning investigator agent for reported issue in milestone auth-system-v1.0" <commentary>The issue skill spawns one investigator per reported issue. The agent creates the GitHub Issue, investigates, and returns a recommendation.</commentary></example>
model: sonnet  # Sonnet is sufficient — investigator reads/searches code and writes GH issues, no complex implementation. Opus reserved for implementer's TDD work.
permissionMode: dontAsk
---

You are an **investigator agent** — a subordinate agent spawned by the `buehler:issue` skill. You investigate exactly one reported issue per invocation.

## Identity and Boundaries

- You are a **subordinate agent**. You never communicate with the human user directly.
- You report progress exclusively via **GitHub Issue comments** (`gh issue comment`).
- You follow the superpowers workflow: systematic debugging, verification before completion.
- You **never fix the issue** — you investigate, document, and recommend. The human decides what happens next.

## Inputs You Receive

When spawned, your prompt will contain:

1. **Human's description** of the issue (raw text)
2. **Repo context** (owner, repo, base branch, test/lint/build commands)
3. **Active milestones** (list of open milestones with numbers and titles)
4. **Interactive flag** (true if human is waiting for approval, false if programmatic)
5. **Capability flags** (issue_types_available, sub_issues_available from preflight)

## Core Rules

### Rule 1: Never Fix
Your job ends at investigation and recommendation. Never write code, create branches, or submit PRs. The human decides the fix path.

### Rule 2: Dedup First
Before creating any issue, search for duplicates. A duplicate found saves everyone time. Add new context to the existing issue instead.

### Rule 3: Report Progress via GitHub
- Post a comment when you **create the issue**: "Created #{issue_number} for investigation"
- Post a comment when **investigation complete**: "Investigation complete. See updated issue body."
- Post a comment if **blocked**: reason and labeling

### Rule 4: Use Bug Template for Bugs
For `type:bug` issues, use the format from `skills/structure/bug-template.md` (Parent, Failing Scenario, Environment, Observed/Expected Behavior, Reproduction Steps, Fix Guidance). For `type:task` issues (enhancements/refactors), use: Objective, Context, Affected Area.

### Rule 5: Stay Honest About Confidence
When recommending severity and priority, include your reasoning and confidence level. If you're uncertain, say so — the human can override.

## Execution Procedure

### Phase 1: Parse Intent

Extract from the human's description:
- **What happened** (observed behavior)
- **What was expected** (if stated)
- **Which area** of the codebase (files, features, components mentioned)
- **Referenced issues/stories** (any `#N` references)
- **Type signal** — is this a defect (`type:bug`) or an enhancement/refactor (`type:task`)?

### Phase 2: Detect Context

1. **Milestone detection:**
   - If the human referenced specific issues, find which milestone they belong to
   - If only one open milestone exists, use it
   - If multiple open milestones and no clear match, use the most recently created one
   - If no open milestones, the issue is milestone-less (standalone backlog item)

2. **Vibe vs PR mode detection:**
   ```bash
   # Check branch protection
   protection=$(gh api "repos/{owner}/{repo}/branches/{base_branch}/protection" 2>/dev/null || echo "none")
   ```
   - If branch protection requires PR reviews → PR mode
   - If no branch protection or no review requirement → check push access:
     ```bash
     gh api "repos/{owner}/{repo}" --jq '.permissions.push'
     ```
   - Push access = vibe mode. No push access = PR mode.
   - Store the result in the report (the fix agent will use it later).

3. **Stabilization context detection:**
   - Check if the human's description contains "stabilization" or "stabilize"
   - Check if a stabilization ticket exists for the active milestone:
     ```bash
     gh issue list --repo {owner}/{repo} --milestone "{milestone_title}" \
       --search "\"Stabilization: {milestone_title}\" in:title" \
       --json number,title --jq '.[0].number'
     ```
   - If either is true → stabilization context. Record the stabilization ticket number.
   - Otherwise → standalone issue, no parent.

### Phase 3: Dedup Check

**Pass 1 — Scenario-anchored match:**
If the human references a specific story (`#N`) and scenario (`S2`), search for open issues that:
```bash
gh issue list --repo {owner}/{repo} --milestone "{milestone_title}" --state open \
  --json number,title,body --jq '.[]'
```
Filter results for issues that share the same parent story AND reference the same failing scenario in their body.

**Pass 2 — Semantic similarity fallback:**
Extract keywords from the human's description. Search open issues:
```bash
gh issue list --repo {owner}/{repo} --milestone "{milestone_title}" --state open \
  --search "{keywords}" --json number,title,body
```
Read the top candidates. Use judgment — same error messages, same files, same behavior = likely dupe.

**On dupe found:**
- Add a comment to the existing issue with the new context from the human's report
- Return structured result with `status: duplicate` and the existing issue number
- Stop execution — do not proceed to Phase 4.

**On uncertain match (interactive):**
- Return the candidate to the skill for the human to confirm
- Include: candidate issue number, title, and a brief comparison of why it might be a dupe

**On uncertain match (programmatic):**
- Create a new issue (err on the side of not losing information)

### Phase 4: Stabilization Ticket Lookup

If stabilization context was detected in Phase 2:
- Look up the stabilization ticket number (already found in Phase 2)
- If no stabilization ticket exists (it should — created at milestone creation): report a warning in the result. Create the issue as standalone instead.

### Phase 5: Create Issue

Create the GitHub Issue — fast capture before investigation.

For `type:bug`:
```bash
gh issue create --repo {owner}/{repo} \
  --title "{concise summary}" \
  --milestone "{milestone_title}" \
  --label "type:bug" \
  --body "$(cat <<'BODY'
**Parent:** #{stabilization_ticket_number_or_parent_story}
**Failing Scenario:** {scenario_if_known}

## Environment

{branch, commit, platform from description}

## Observed Behavior

{what actually happens}

## Expected Behavior

{what should happen}

## Reproduction Steps

1. {step from description}

## Fix Guidance

<!-- Investigation pending — will be updated by investigator agent -->
BODY
)"
```

For `type:task`:
```bash
gh issue create --repo {owner}/{repo} \
  --title "{concise summary}" \
  --milestone "{milestone_title}" \
  --label "type:task" \
  --body "$(cat <<'BODY'
## Objective

{one sentence: what should change}

## Context

{why this matters, what triggered it}
{Link to related feature story: #{story_number} if identifiable}

## Affected Area

{component/module/files mentioned}

## Investigation

<!-- Investigation pending — will be updated by investigator agent -->
BODY
)"
```

If in stabilization context, create as sub-issue of the stabilization ticket:
```bash
# If Sub-issues API available:
gh api graphql -f query='mutation { addSubIssue(input: {issueId: "{stabilization_ticket_node_id}", subIssueId: "{new_issue_node_id}"}) { issue { id } } }'
# Fallback: add <!-- buehler:parent #{stabilization_ticket_number} --> to the issue body
```

Post comment: "Created #{issue_number} for investigation"

### Phase 6: Context Load

If a parent story or related story was referenced:
```bash
gh issue view {story_number} --repo {owner}/{repo} --json body --jq '.body'
```
Read the story's Gherkin scenarios, acceptance criteria, and architecture context.

If a wiki meta page exists for the epic:
- Identify the epic from the milestone title (e.g., `auth-system-v1.0` → epic is `auth-system`)
- Read the meta page for architecture summary, key files, known limitations

This context informs the investigation.

### Phase 7: Investigate

Invoke `superpowers:systematic-debugging`:

1. **Root cause analysis** — trace through the code from the reproduction steps to identify what's actually broken
2. **Reproduction verification** — confirm the issue reproduces (if possible without running the full app, e.g., via tests)
3. **Affected files** — list the specific files involved in the issue
4. **Blast radius assessment:**
   - **Isolated** — affects only this specific behavior
   - **Cross-scenario** — affects other scenarios in the same story
   - **Cross-story** — affects scenarios in other stories
5. **Proposed fix approach** — high-level description of what needs to change (not code)

### Phase 8: Update Issue

Edit the issue body to replace the `<!-- Investigation pending -->` placeholder with actual findings:

```bash
gh issue edit {issue_number} --repo {owner}/{repo} --body "{updated_body}"
```

For `type:bug`, update the Fix Guidance section:
```markdown
## Fix Guidance

**Root cause:** {what's actually broken}
**Affected files:**
- `{path/to/file1}` — {what's wrong here}
- `{path/to/file2}` — {what's wrong here}

**Blast radius:** {isolated | cross-scenario | cross-story}
**Proposed fix:** {high-level approach}
```

For `type:task`, update the Investigation section:
```markdown
## Investigation

**Analysis:** {what needs to change and why}
**Affected files:**
- `{path/to/file1}` — {what to modify}

**Blast radius:** {isolated | cross-scenario | cross-story}
**Proposed approach:** {high-level approach}
```

Post comment: "Investigation complete. See updated issue body."

### Phase 9: Recommend Severity + Priority

Based on investigation findings, recommend:

**Severity** (impact on the system):
| Label | Criteria |
|-------|----------|
| `severity:critical` | Data loss, crash, or security vulnerability |
| `severity:major` | Broken feature, no workaround |
| `severity:minor` | Broken feature, workaround exists |
| `severity:trivial` | Cosmetic or minor inconvenience |

**Priority** (urgency of fix):
| Label | Criteria |
|-------|----------|
| `priority:critical` | Fix now — blocks other work or users |
| `priority:high` | Fix this milestone |
| `priority:medium` | Fix next milestone |
| `priority:low` | Backlog — fix when convenient |

If **programmatic invocation** (interactive flag is false):
- Apply labels directly:
  ```bash
  gh issue edit {issue_number} --repo {owner}/{repo} --add-label "{severity_label},{priority_label}"
  ```

If **interactive invocation** (interactive flag is true):
- Do NOT apply labels. Include recommendation and reasoning in the structured result for the skill to present to the human.

### Phase 10: Report

Return a structured YAML result:

```yaml
result:
  issue_number: {N}
  status: created | duplicate
  duplicate_of: {N or null}
  type: bug | task
  milestone: "{milestone_title or null}"
  stabilization_ticket: {N or null}
  severity_recommendation: "{label}"
  priority_recommendation: "{label}"
  reasoning: "{why these levels}"
  fix_mode: vibe | pr
  affected_files:
    - "{path/to/file1}"
    - "{path/to/file2}"
  blast_radius: isolated | cross-scenario | cross-story
  proposed_fix: "{summary}"
```

## Failure Handling

| Failure | Action |
|---------|--------|
| Cannot determine issue type (bug vs task) | Default to `type:bug`. Note uncertainty in report. |
| Dedup search fails (API error) | Log warning, proceed with issue creation. |
| Cannot reproduce the issue | Note in investigation. Recommend `severity:minor` with low confidence. |
| Stabilization ticket missing (should exist) | Log warning in report. Create issue as standalone. |
| Cannot access referenced story/wiki | Note in investigation. Proceed with available context. |

## Prohibited Actions

- **Never fix the issue** — no code changes, no branches, no PRs
- **Never communicate with the human** — use GitHub Issue comments only
- **Never apply labels in interactive mode** — return recommendation only
- **Never skip the dedup check** — Phase 3 is mandatory
- **Never create duplicate issues** — if in doubt, add a comment to the candidate
```

- [ ] **Step 2: Commit**

```bash
git add agents/investigator.md
git commit -m "feat: add investigator agent definition (10-phase procedure)"
```

---

### Task 5: Create the Investigator Prompt Template

**Files:**
- Create: `skills/issue/investigator-prompt.md`

Reference: `skills/dispatch/implementer-prompt.md` for the template pattern.

- [ ] **Step 1: Create the prompt template**

```markdown
# Investigator Prompt Template

This template is filled by `buehler:issue` for each reported issue.
The skill replaces all `{placeholders}` before spawning the agent.

---

You are an investigator agent. Investigate the following reported issue.

## Reported Issue

**Description from human:**

{human_description}

## Repository

- **Owner:** {owner}
- **Repo:** {repo}
- **Base branch:** {base_branch}

## Build Commands

- **Test:** `{test_command}`
- **Lint:** `{lint_command}`
- **Build:** `{build_command}`

## Active Milestones

{milestone_list_or_none}

## Capability Flags

- **Issue Types API:** {issue_types_available}
- **Sub-issues API:** {sub_issues_available}

## Invocation Context

- **Interactive:** {interactive_flag}
- **Invoked by:** {invoked_by_skill_or_human}

## Instructions

1. Read the `agents/investigator.md` agent definition in the buehler plugin for your full procedure
2. Follow the 10-phase execution procedure exactly
3. **Never fix the issue** — investigate, document, recommend only
4. Dedup check is mandatory before creating any issue
5. Use `superpowers:systematic-debugging` for investigation
6. Return a structured YAML result when done

Begin.
```

- [ ] **Step 2: Commit**

```bash
git add skills/issue/investigator-prompt.md
git commit -m "feat: add investigator prompt template for issue skill"
```

---

### Task 6: Create the Issue Skill Definition

**Files:**
- Create: `skills/issue/SKILL.md`

Reference: `skills/dispatch/SKILL.md` for the skill structure pattern (frontmatter, type declaration, inputs, checklist, process).

- [ ] **Step 1: Create the skill file**

```markdown
---
name: issue
description: Use when reporting a bug, filing an issue, investigating a problem, or fixing an already-investigated issue — supports ad-hoc issue creation, duplicate detection, root-cause investigation, severity/priority recommendation, and stabilization tracking
---

# issue — Ad-hoc Issue Creation, Investigation, and Triage

**Type:** Rigid. Follow this process exactly.

## Invocation Modes

This skill has two modes:

1. **Investigate** (default) — `/issue {description}`
   Human describes a bug, enhancement, or problem. The skill spawns an investigator agent.

2. **Fix** — `/issue fix #{issue_number}`
   For an already-investigated issue. The skill spawns a fix agent.

## Mode 1: Investigate

### Inputs

- A human's description of an issue (bug, enhancement, or problem)
- Access to the project repository (gh CLI)

### Checklist

You MUST create a task for each of these items and complete them in order:

1. **Gather context** — read buehler.yaml, detect milestones, read preflight capability flags (Step 1)
2. **Fill prompt and spawn investigator** — fill the investigator-prompt.md template and spawn the agent (Step 2)
3. **Handle result** — process the agent's structured result, handle approval if interactive (Step 3)

### Process

#### Step 1: Gather Context

Read `.github/buehler.yaml` from the project root. Extract:
- `owner` and `repo` from git remote
- `base_branch` (default: `main`)
- Build commands: `test_command`, `lint_command`, `build_command`

Fetch open milestones:
```bash
gh api repos/{owner}/{repo}/milestones?state=open --jq '.[] | "\(.number)\t\(.title)"'
```

Read preflight capability flags from the PreToolUse hook's additionalContext (JSONL):
- `repo.issue_types` — pass/fail
- `repo.sub_issues` — pass/fail

#### Step 2: Fill Prompt and Spawn Investigator

1. Read `skills/issue/investigator-prompt.md`
2. Replace all `{placeholders}` with values from Step 1 and the human's description
3. Set `{interactive_flag}` to `true` (human is present in the conversation)
4. Spawn the investigator agent:

```
Agent tool:
  subagent_type: "buehler:investigator"
  prompt: {filled_prompt}
```

Wait for the agent to return.

#### Step 3: Handle Result

Parse the agent's structured YAML result.

**If `status: duplicate`:**
- Report to the human: "This looks like a duplicate of #{duplicate_of}. I added your context as a comment on the existing issue."
- Done.

**If `status: created` (interactive):**
- Present the investigation summary:
  ```
  Issue #{issue_number} created and investigated.

  Recommended severity: {severity_recommendation}
  Recommended priority: {priority_recommendation}
  Reasoning: {reasoning}

  Blast radius: {blast_radius}
  Fix mode: {fix_mode} (auto-detected)
  Proposed fix: {proposed_fix}

  Apply these labels? (yes / override with different values / skip)
  ```
- On approval: apply labels via `gh issue edit --add-label`
- On override: apply the human's chosen labels
- On skip: leave unlabeled

**If `status: created` (programmatic — this path is for when other skills invoke /issue):**
- Labels already applied by the agent. Return the result silently.

## Mode 2: Fix

### Inputs

- An issue number (`/issue fix #N`)
- The issue must already be investigated (has root cause, affected files, proposed fix in its body)

### Checklist

1. **Read the issue** — fetch issue body, extract investigation findings (Step 1)
2. **Detect fix mode** — check vibe vs PR mode (Step 2)
3. **Execute fix** — TDD implementation (Step 3)

### Process

#### Step 1: Read the Issue

```bash
gh issue view {issue_number} --repo {owner}/{repo} --json body,title,labels,milestone
```

Verify the issue has investigation findings (Fix Guidance or Investigation section populated, not the `<!-- Investigation pending -->` placeholder). If not investigated yet, tell the human: "This issue hasn't been investigated yet. Run `/issue {description}` first or manually add investigation findings to the issue body."

Extract: root cause, affected files, proposed fix approach, severity, priority.

#### Step 2: Detect Fix Mode

Auto-detect vibe vs PR mode:
```bash
# Check branch protection
gh api repos/{owner}/{repo}/branches/{base_branch}/protection 2>/dev/null
```
- Branch protection with required reviews → PR mode
- No protection or no review requirement → check push access:
  ```bash
  gh api repos/{owner}/{repo} --jq '.permissions.push'
  ```
- Push access → vibe mode. No push access → PR mode.

Tell the human which mode was detected and what will happen.

#### Step 3: Execute Fix

**Vibe mode:**
1. Ensure you're on the base branch and it's up to date
2. Invoke `superpowers:test-driven-development`
3. Write a failing test that reproduces the issue
4. Implement the minimal fix to make it pass
5. Run full test suite — verify no regressions
6. Invoke `superpowers:verification-before-completion`
7. Commit with message: `fix: {description} (Fixes #{issue_number})`
8. Push to base branch
9. Close the issue:
   ```bash
   gh issue close {issue_number} --repo {owner}/{repo} --reason completed
   ```

**PR mode:**
1. Create a branch: `fix/{issue_number}-{slug}`
2. Invoke `superpowers:test-driven-development`
3. Write a failing test that reproduces the issue
4. Implement the minimal fix to make it pass
5. Run full test suite — verify no regressions
6. Invoke `superpowers:verification-before-completion`
7. Commit with message: `fix: {description}`
8. Push branch and create PR:
   ```bash
   gh pr create --title "Fix #{issue_number}: {title}" \
     --body "Fixes #{issue_number}

   ## Root Cause
   {from investigation}

   ## Fix
   {what was changed}

   ## Test Plan
   - [ ] New test reproduces the issue
   - [ ] Fix makes the test pass
   - [ ] Full test suite passes with no regressions"
   ```
9. Tell the human the PR is ready for review. Do NOT close the issue — the PR merge will close it via the `Fixes #N` reference.
```

- [ ] **Step 2: Commit**

```bash
git add skills/issue/SKILL.md
git commit -m "feat: add buehler:issue skill definition (investigate + fix modes)"
```

---

### Task 7: Update Structure Skill — Add Step 7a

**Files:**
- Modify: `skills/structure/SKILL.md` (after line 172, which is the end of Step 7)

- [ ] **Step 1: Read the target area to confirm insertion point**

Read `skills/structure/SKILL.md` lines 154-180. Confirm line 172 is "Capture the milestone number from the response for use in subsequent steps." and line 174 is "### Step 8: Create Feature Branch".

- [ ] **Step 2: Insert Step 7a**

After line 172 (after "Capture the milestone number..."), insert:

```markdown

### Step 7a: Create Stabilization Ticket

Create a stabilization ticket for the new milestone. This is the parent ticket for any issues discovered during testing, review, or post-integration stabilization.

Run the creation script:
```bash
bash scripts/create-stabilization-ticket.sh \
  --owner {owner} --repo {repo} \
  --milestone-title "{epic}-v{Major}.{Minor}" \
  --milestone-number {milestone_number} \
  --wiki-meta-url "../../wiki/{Epic-Name}"
```

The script is idempotent — if a stabilization ticket already exists for this milestone, it returns the existing issue number.

The stabilization ticket is labeled `meta:ignore` so that `buehler:dispatch` will not attempt to dispatch it for implementation.
```

- [ ] **Step 3: Commit**

```bash
git add skills/structure/SKILL.md
git commit -m "feat(structure): add Step 7a — create stabilization ticket at milestone creation"
```

---

### Task 8: Update Integrate Skill — Add Stabilization Check

**Files:**
- Modify: `skills/integrate/SKILL.md` (lines 39-51, Step 1: Pre-Integration Audit)

- [ ] **Step 1: Read the target area to confirm insertion point**

Read `skills/integrate/SKILL.md` lines 39-56. Confirm lines 48-51 are the "If any tasks are `status:in-progress`..." block.

- [ ] **Step 2: Add stabilization check**

After the existing step 5 ("If any tasks are `status:in-progress`...") and before the `gh issue list` code block, insert a new check item (becomes item 6):

```markdown
6. Check for open stabilization children:
   - Search for the stabilization ticket: `gh issue list --milestone "{milestone_title}" --search "\"Stabilization: {milestone_title}\" in:title" --json number --jq '.[0].number'`
   - If a stabilization ticket exists, fetch its sub-issues (or issues with `<!-- buehler:parent #{stabilization_number} -->`)
   - If any stabilization children are still open, report them as blockers
   - Options: "Wait for stabilization to complete", "Exclude remaining issues", "Cancel"
```

- [ ] **Step 3: Commit**

```bash
git add skills/integrate/SKILL.md
git commit -m "feat(integrate): check stabilization ticket children in pre-integration audit"
```

---

### Task 9: Update Session Start Hook — Add Issue Routing

**Files:**
- Modify: `hooks/session-start.sh` (lines 25-31, routing table)

- [ ] **Step 1: Read the file to confirm insertion point**

Read `hooks/session-start.sh`. Confirm lines 25-31 contain the routing table entries ending with the integrate row.

- [ ] **Step 2: Add the issue routing entry**

After line 31 (`| \"Merge\" / \"Ship it\" / \"Integrate\" | buehler:integrate |`), add:

```
| \"File a bug\" / \"Report issue\" / \"Investigate\" | buehler:issue |
| \"Fix issue #N\" | buehler:issue |
```

- [ ] **Step 3: Update the flow line**

On line 35, update the flow to include issue:

```
setup -> brainstorming -> structure -> dispatch -> status -> review -> integrate
                                                                  \\-> issue (anytime)
```

Note: the issue skill sits alongside the flow, not in it linearly, since it can be invoked at any point.

- [ ] **Step 4: Commit**

```bash
git add hooks/session-start.sh
git commit -m "feat(hooks): add buehler:issue routing to session-start"
```

---

### Task 10: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Plugin Structure tree**

In the `## Plugin Structure` section, add the new files to the tree:

Under `scripts/`:
```
│   ├── create-stabilization-ticket.sh  # Idempotent stabilization ticket creation
```

Under `scripts/preflight-checks/`:
```
│       ├── check-stabilization.sh  # Stabilization tickets exist for open milestones
```

Under `skills/`:
```
│   ├── issue/                     # Ad-hoc issue creation, investigation, triage
│   │   └── investigator-prompt.md
```

Under `agents/`:
```
├── agents/
│   ├── implementer.md             # Subordinate agent: 9-phase TDD workflow
│   └── investigator.md            # Subordinate agent: 10-phase investigation workflow
```

Update the skills comment from "6 skills" to "7 skills" and add "issue" to the list.

- [ ] **Step 2: Update Key Conventions**

Add to the Key Conventions list:
```markdown
10. **Severity + Priority** — two-axis triage: `severity:` (impact on system) + `priority:` (urgency of fix)
11. **Stabilization tickets** — one per milestone, `type:task` + `meta:ignore`, created at milestone creation time
```

- [ ] **Step 3: Update the label taxonomy convention**

On line 67, update convention 4 to include severity:
```markdown
4. **Label taxonomy** — `epic:`, `priority:`, `severity:`, `meta:`, `size:`, `status:`, `type:`, `backlog:` prefixes (`:` delimiter)
```

- [ ] **Step 4: Update Skill Reference table**

Add the new skill row:
```markdown
| `buehler:issue` | Ad-hoc issue creation, investigation, triage, and fix execution |
```

- [ ] **Step 5: Update Skill Flow**

Add issue to the flow:
```
→ buehler:issue → Ad-hoc issue spike, investigation, triage (anytime)
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with issue skill, investigator agent, and severity labels"
```

---

### Task 11: Update Status Skill — Stabilization Ticket Display

**Files:**
- Modify: `skills/status/SKILL.md` (lines 96-109, Step 4 dashboard rendering)

- [ ] **Step 1: Read the target area to confirm insertion point**

Read `skills/status/SKILL.md` lines 84-147. Confirm lines 96-109 are the Stories section of the dashboard rendering, ending with the "Ungrouped Tasks" note at line 109.

- [ ] **Step 2: Add stabilization ticket grouping**

After line 109 (`{Repeat for each story. Tasks/bugs without a parent story are listed under an "Ungrouped Tasks" heading.}`), insert a new section for stabilization:

```markdown

### Stabilization
{If a stabilization ticket exists in the milestone (title matches "Stabilization: {milestone_title}"):}

#### #{N}: Stabilization: {milestone_title} [`meta:ignore`]
  - Bug  #{N}: {title} [`severity:major`] [`priority:high`] [`status:ready`]
  - Task #{N}: {title} [`severity:minor`] [`priority:medium`] [`status:in-progress`]
  - **Exit criteria:** {open_count}/{total_count} children remaining

{Stabilization children are grouped here instead of under "Ungrouped Tasks". Display severity labels alongside status labels for all issues that have them.}
```

- [ ] **Step 3: Add severity labels to label display**

In the Stories section (lines 98-101), update the task/bug display format to include severity labels when present:

```markdown
  - Task #{N}: {title} [`severity:major`] [`status:done`]
  - Bug  #{N}: {title} [`severity:critical`] [`status:ready`]
```

Add a note: "Display `severity:` labels (if present) before `status:` labels for all issues."

- [ ] **Step 4: Add stabilization to Recommended Next Actions**

In the Recommended Next Actions section (lines 140-146), add:
```markdown
- {If stabilization ticket has open children: "Stabilization in progress — {open_count} issues remaining. Run `buehler:issue` to capture more issues or `buehler:issue fix #N` to fix them."}
- {If stabilization ticket exists and all children closed: "Stabilization complete — all issues resolved. Safe to run `buehler:integrate`."}
```

- [ ] **Step 5: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "feat(status): display stabilization tickets and severity labels in dashboard"
```

---

### Task 12: Update Setup Skill — Severity Labels and Stabilization Remediation

**Files:**
- Modify: `skills/setup/SKILL.md` (lines 108-114 wizard labels, lines 240-248 remediation)

- [ ] **Step 1: Read the target areas to confirm insertion points**

Read `skills/setup/SKILL.md` lines 108-116 (wizard labels section) and lines 235-256 (remediation section). Confirm:
- Lines 108-114 list the label taxonomy in the wizard
- Lines 240-248 list model-fixable remediation items

- [ ] **Step 2: Add severity labels to wizard**

In the wizard labels section (after line 114, after `- Backlog: now, next, later, icebox`), add:
```markdown
   - Severity: critical, major, minor, trivial
```

- [ ] **Step 3: Add stabilization remediation to Step 6**

In the remediation section (after line 248, after the CODEOWNERS bullet), add:
```markdown
- Missing stabilization ticket → run `bash scripts/create-stabilization-ticket.sh --owner {owner} --repo {repo} --milestone-title '{title}' --milestone-number {number}` for each flagged milestone
```

- [ ] **Step 4: Commit**

```bash
git add skills/setup/SKILL.md
git commit -m "feat(setup): add severity labels to wizard and stabilization remediation"
```

---

### Task 13: Add buehler:issue to Preflight Gate

**Files:**
- Modify: `hooks/preflight.sh` (line 29)

The `buehler:issue` skill needs preflight capability flags (issue_types_available, sub_issues_available) injected as systemMessage context. It must be gated so the investigator agent receives these flags.

- [ ] **Step 1: Read the file to confirm insertion point**

Read `hooks/preflight.sh`. Confirm line 29 is `buehler:structure|buehler:dispatch|buehler:review|buehler:integrate)`.

- [ ] **Step 2: Add buehler:issue to the gate**

Change line 29 from:
```bash
  buehler:structure|buehler:dispatch|buehler:review|buehler:integrate)
```
to:
```bash
  buehler:structure|buehler:dispatch|buehler:review|buehler:integrate|buehler:issue)
```

- [ ] **Step 3: Update the comment**

Change line 3 from:
```bash
# Gates: structure, dispatch, review, integrate
```
to:
```bash
# Gates: structure, dispatch, review, integrate, issue
```

- [ ] **Step 4: Commit**

```bash
git add hooks/preflight.sh
git commit -m "feat(preflight): gate buehler:issue for capability flag injection"
```

---

## Task Dependency Order

Tasks 1-3 are independent infrastructure changes (labels, scripts, preflight). Tasks 4-5 are the core new agent and template. Task 6 is the skill that ties it all together. Tasks 7-13 are integration updates to existing files.

Recommended execution order for parallelization:
- **Parallel batch 1:** Tasks 1, 2, 3 (independent infrastructure)
- **Parallel batch 2:** Tasks 4, 5 (agent + template, independent of each other)
- **Sequential:** Task 6 (depends on 4, 5 existing)
- **Parallel batch 3:** Tasks 7, 8, 9, 10, 11, 12, 13 (independent modifications to existing files)
