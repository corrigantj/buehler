# Issue Skill — Ad-hoc Issue Creation, Investigation, and Triage

**Date:** 2026-03-24
**Status:** Design
**Scope:** buehler plugin — new skill (`buehler:issue`), new agent (`agents/investigator.md`), label taxonomy, stabilization workflow, preflight checks

## Problem

The buehler plugin currently creates all issues in structured batches via `buehler:structure` (PRD → stories → tasks). There is no way to:

1. Capture bugs discovered during development, testing, review, or post-integration use
2. Capture insights that lead to new work (enhancements, refactors) outside the PRD workflow
3. Systematically investigate, triage, and prioritize ad-hoc issues
4. Track stabilization work as a gate to exiting a milestone

The implementer agent has lightweight bug-filing (create a sub-issue under the parent story and move on), but no dedup, no investigation, no severity/priority recommendation, and no stabilization orchestration.

## JTBD

I want to exit this milestone. If there are issues, I need to fix them before I can exit. If there are no issues, I can exit immediately.

## Design

### 1. Architecture: Skill + Agent (Approach B)

Follows the existing dispatch/implementer pattern:

- **`buehler:issue` (skill)** — Thin dispatcher. Captures human input, spawns the investigator agent, handles the approval interaction on return.
- **`agents/investigator.md` (agent)** — Full pipeline: parse → detect context → dedup → create issue → investigate → recommend severity/priority → report.

All real work happens in the subagent to keep the main session context window clean.

### 2. Invocation Modes

**Mode 1: Investigate** — `/issue {description}`

The default. Human describes what they observed. The skill spawns an investigator agent that:
- Parses the description
- Checks for duplicates
- Creates the issue
- Investigates root cause using `superpowers:systematic-debugging`
- Recommends severity and priority
- Returns to the skill for human approval of labels

**Always stops after investigation.** The human decides what happens next.

**Mode 2: Fix** — `/issue fix #N`

For an already-investigated issue. The skill spawns a fix-mode agent that:
- Reads the investigation from the issue body
- Auto-detects push access to base branch (vibe mode vs PR mode)
- **Vibe mode:** fixes directly on the base branch with TDD, commits with `Fixes #{N}`, closes issue
- **PR mode:** creates a branch, implements with TDD, creates a PR targeting the appropriate branch, leaves issue open for human merge

The human can also batch investigated issues and run `buehler:dispatch` instead.

### 3. Investigator Agent Execution Phases

The agent receives: human's raw description, repo context (owner, repo, test/build commands), active milestone info, interactive vs programmatic flag.

**Phase 1: Parse Intent**
Extract from the human's description: what happened, what was expected, which area of the codebase, any mentioned issue/story numbers.

**Phase 2: Detect Context**
- Determine active milestone. If multiple open milestones, use the one matching any referenced issues. If none, the issue is milestone-less (standalone backlog item).
- Auto-detect vibe vs PR mode: query the base branch's protection rules via `gh api repos/{owner}/{repo}/branches/{base}/protection`. If the branch requires PR reviews, use PR mode regardless of the user's push permissions. If no branch protection or no review requirement, check push access via `gh api repos/{owner}/{repo} --jq '.permissions.push'` — push access means vibe mode. Store the result for the fix phase (if invoked later).

**Phase 3: Dedup Check**
Two-pass duplicate detection against open issues in the milestone:

1. **Scenario-anchored match** (strong signal): same parent story + same failing Gherkin scenario referenced. If the human says "S2 on story #15 is broken" and an open bug already references S2 on #15, that's a dupe.
2. **Semantic similarity fallback**: search open issues with keyword extraction from description. Compare titles and bodies for overlap — same error messages, same files, same behavior. Agent uses judgment (not a numeric threshold).

On dupe found:
- Add a comment to the existing issue with the new context
- Return `status: duplicate` with the existing issue number

On uncertain match:
- If interactive: present the candidate, ask "Is this the same issue as #42?"
- If programmatic: create a new issue (err on the side of not losing information)

**Phase 4: Stabilization Ticket Lookup**
If in stabilization context (human said "stabilization" or a stabilization ticket already exists for the milestone), look up the stabilization parent ticket. If somehow missing (should have been created at milestone creation time), flag an error. Otherwise, the issue is standalone in the milestone with no parent.

**Phase 5: Create Issue**
Minimal spike — fast capture before investigation begins. Uses the existing `skills/structure/bug-template.md` format for `type:bug` issues (Parent, Failing Scenario, Environment, Observed/Expected Behavior, Reproduction Steps, Fix Guidance). For `type:task` issues (enhancements/refactors), uses a lightweight format: Objective, Context, Affected Area.

- Title: concise summary
- Body: template-appropriate format with parent link (stabilization ticket if applicable, none otherwise)
- Labels: `type:bug` or `type:task` (defect vs enhancement)
- If in stabilization context: create as sub-issue of stabilization ticket (via GitHub Sub-issues API, falling back to `<!-- buehler:parent #N -->`)
- If a related feature story is identifiable: include a URL link in the description for progressive context loading

**Phase 6: Context Load**
If a parent story is referenced, read it for Gherkin scenarios and architecture context. If a wiki meta page exists for the epic, read it. This informs the investigation.

**Phase 7: Investigate**
Invoke `superpowers:systematic-debugging`:
- Identify root cause
- Document reproduction steps (verified)
- Identify affected files
- Assess blast radius (isolated issue or affects other scenarios?)
- Propose fix approach

**Phase 8: Update Issue**
Edit the issue body with investigation findings:
- Root cause analysis
- Verified reproduction steps
- Affected files list
- Proposed fix approach
- Blast radius assessment

**Phase 9: Recommend Severity + Priority**
Based on investigation findings:

Severity (impact on the system):
- `severity:critical` — data loss, crash, or security vulnerability
- `severity:major` — broken feature, no workaround
- `severity:minor` — broken feature, workaround exists
- `severity:trivial` — cosmetic or minor inconvenience

Priority (urgency of fix):
- `priority:critical` — fix now
- `priority:high` — fix this milestone
- `priority:medium` — fix next milestone
- `priority:low` — backlog

Include reasoning with the recommendation.

- If interactive: return recommendation to skill, which presents it for human approval before applying labels
- If programmatic: apply labels directly

**Phase 10: Report**
Return structured result:

```yaml
result:
  issue_number: {N}
  status: created | duplicate
  duplicate_of: {N or null}
  severity_recommendation: {label}
  priority_recommendation: {label}
  reasoning: "{why these levels}"
  fix_mode: vibe | pr
  affected_files: [{list}]
  blast_radius: isolated | cross-scenario | cross-story
  proposed_fix: "{summary}"
```

### 4. Label Taxonomy: Adding Severity

New `severity:` labels added to the hardcoded default taxonomy in `scripts/preflight-checks/check-labels.sh`, consistent with how existing taxonomy labels (`priority:`, `size:`, `status:`, `type:`, `backlog:`) are defined. The `labels:` key in `buehler.yaml` is reserved for user-defined custom labels and is not used for the default taxonomy.

New severity labels:

| Label | Color | Description |
|-------|-------|-------------|
| `severity:critical` | `b60205` (red) | Data loss, crash, or security vulnerability |
| `severity:major` | `d93f0b` (orange) | Broken feature, no workaround |
| `severity:minor` | `fbca04` (yellow) | Broken feature, workaround exists |
| `severity:trivial` | `0e8a16` (green) | Cosmetic or minor inconvenience |

Existing `priority:` labels unchanged.

### 5. Stabilization Ticket

A stabilization ticket is created deterministically at milestone creation time, not lazily by the investigator.

**Script: `scripts/create-stabilization-ticket.sh`**
- Called by `buehler:structure` after milestone creation
- Creates a `type:task` issue titled "Stabilization: {epic}-v{Major}.{Minor}"
- Assigned to the milestone
- Labeled with `meta:ignore` to prevent `buehler:dispatch` from picking it up as a dispatchable task
- Body contains a link to the feature's wiki meta page
- Idempotent — if one already exists for this milestone, no-op

**Preflight check: `scripts/preflight-checks/check-stabilization.sh`**
- For each open milestone, verify a stabilization ticket exists
- Emits JSONL warning/failure if missing
- `buehler:setup` can remediate drift by creating missing stabilization tickets

**Stabilization context detection** (by the investigator agent):
- Explicit: human says "stabilization" or "stabilize" in their description
- Implicit: a stabilization ticket already exists for the active milestone and human references it
- Otherwise: standalone issue, no parent

**Exit criteria:** The milestone can be exited when all children of the stabilization ticket are closed. `buehler:integrate` checks this in its pre-integration audit.

### 6. Integration with Existing Skills

**`buehler:structure`** — After Step 7 (Create Milestone), add a new sub-step (7a) with instructions to create the stabilization ticket by running `create-stabilization-ticket.sh` or creating the ticket via `gh` directly, consistent with how the rest of the structure skill operates. No other changes.

**`buehler:status`** — Shows the stabilization ticket with its children in the dashboard, same grouping pattern as stories with tasks. Includes severity labels in display.

**`buehler:dispatch`** — No changes. Investigated issues have the right shape (affected files, parent link, milestone) to be dispatched normally.

**`buehler:review`** — No changes. PRs from `/issue fix` flow through the normal review pipeline.

**`buehler:integrate`** — Pre-integration audit (step 1) additionally checks: if a stabilization ticket exists, are all its children closed? If not, flag as blockers.

**`buehler:setup`** — Adds `severity:` labels to label creation/verification. Preflight checks validate they exist. Remediates missing stabilization tickets for existing milestones.

**Implementer agent** — No changes. Its lightweight bug-filing behavior stays as-is. Those bugs are visible to `/issue` during dedup.

### 7. File Structure

New files:

```
buehler/
├── skills/
│   └── issue/
│       ├── SKILL.md                # Thin dispatcher: capture input, spawn agent, handle approval
│       └── investigator-prompt.md  # Dynamic context template filled by the skill before spawning
├── agents/
│   └── investigator.md             # Static agent definition: persona, phases, rules
├── scripts/
│   ├── create-stabilization-ticket.sh  # Called by structure at milestone creation
│   └── preflight-checks/
│       └── check-stabilization.sh      # Verify stabilization tickets exist
```

The relationship between `investigator-prompt.md` and `agents/investigator.md` mirrors the existing `dispatch/implementer-prompt.md` and `agents/implementer.md` pattern: the agent file defines the static persona, rules, and execution phases; the prompt template is filled by the skill with dynamic context (human description, repo info, milestone data) and injected into the agent spawn call.

**Migration note:** Existing milestones (created before this feature) will not have stabilization tickets. The `check-stabilization.sh` preflight check will flag these as warnings. Running `buehler:setup` will remediate by backfilling stabilization tickets for any open milestones missing them.

Changes to existing files:

| File | Change |
|------|--------|
| `scripts/preflight-checks/check-labels.sh` | Add `severity:` labels to hardcoded default taxonomy |
| `scripts/preflight-checks/runner.sh` | Include `check-stabilization.sh` |
| `skills/structure/SKILL.md` | Add Step 7a: create stabilization ticket after milestone creation |
| `skills/integrate/SKILL.md` | Add stabilization ticket children check to pre-integration audit (Step 1) |
| `hooks/session-start.sh` | Add `/issue` routing: `"File a bug" / "Report issue" / "Investigate" / "Fix issue"` → `buehler:issue` |
| `CLAUDE.md` | Update plugin structure and skill reference table |

### 8. Procedural Context: Stabilization Loop

The `/issue` skill enables a stabilization loop that fits between `buehler:integrate` (or `buehler:review`) and milestone exit:

1. **Deploy** — Completed milestone work is deployed to an environment
2. **Test/Review** — Automated evals, TDD, human review. Human provides feedback.
3. **Capture** — `/issue {description}` for each problem or enhancement found. Agent investigates, recommends severity/priority, human approves.
4. **Fix** — Human decides per-issue: `/issue fix #N` for single fixes, or `buehler:dispatch` for batches. Vibe mode (direct commit) or PR mode (human merge) auto-detected.
5. **Retest** — Another round of evaluation
6. **Repeat** steps 3-5 until stabilization ticket children are all closed
7. **Exit** — `buehler:integrate` confirms stabilization complete, proceeds with milestone close and retrospective
