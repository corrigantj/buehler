---
name: issue
description: Use when reporting a bug, filing an issue, investigating a problem, fixing an already-investigated issue, or quickly capturing a backlog idea — supports fast ad-hoc issue capture with an explicit gate before investigation, duplicate detection, root-cause investigation, severity/priority recommendation, stabilization tracking, and lightweight backlog capture
---

# issue — Ad-hoc Issue Capture, Investigation, and Triage

**Type:** Rigid. Follow this process exactly.

## Design Principle: Capture Is Fast, Investigation Is Gated

`/issue` is usually invoked mid-session while the user is doing other work. Submission must be fast — **parse, dedup, create, report**, then stop. Investigation is expensive and must never run until the user explicitly asks for it via the `AskUserQuestion` gate in Step 5.

**Never** spawn the investigator agent before Step 5. **Never** run systematic debugging during capture.

## Invocation Modes

This skill has three modes:

1. **Capture** (default) — `/issue {description}`
   Human describes a bug, enhancement, or problem. The skill captures it as a GitHub issue fast, then asks the user whether to enrich with a description, run an investigation, both, or stop.

2. **Fix** — `/issue fix #{issue_number}`
   For an already-investigated issue. The skill executes a TDD fix.

3. **Backlog** — `/issue backlog "idea title"` or `/issue backlog {tier} "idea title"`
   Quick capture of a backlog idea with an explicit tier. No milestone, no investigation option, no dedup. Tier is `now`, `next`, `later` (default), or `icebox`.

## Mode 1: Capture

### Inputs

- A human's brief description of an issue (bug, enhancement, or problem)
- Access to the project repository (gh CLI)

### Checklist

You MUST create a task for each of these items and complete them in order:

1. **Gather context** — read buehler.yaml, detect milestones, read preflight capability flags (Step 1)
2. **Parse intent** — extract title, type (bug vs task), milestone, stabilization context (Step 2)
3. **Quick dedup check** — search for obvious duplicates (Step 3)
4. **Create issue** — fast create with placeholder body (Step 4)
5. **Gate** — ask the user what to do next via `AskUserQuestion` (Step 5)
6. **Handle response** — description / investigation / both / done (Step 6)

### Process

#### Step 1: Gather Context

Read `.github/buehler.yaml` from the project root. Extract:
- `owner` and `repo` from git remote
- `base_branch` (default: `main`)
- Build commands: `test_command`, `lint_command`, `build_command` (needed later if investigation is chosen)

Fetch open milestones:
```bash
gh api repos/{owner}/{repo}/milestones?state=open --jq '.[] | "\(.number)\t\(.title)"'
```

Read preflight capability flags from the PreToolUse hook's additionalContext (JSONL):
- `repo.issue_types` — pass/fail
- `repo.sub_issues` — pass/fail

#### Step 2: Parse Intent

From the human's description, extract **without invoking any agent**:

1. **Concise title** — one-line summary suitable for a GitHub issue title
2. **Type signal** — `type:bug` if the description mentions broken/crash/error/failing behavior; `type:task` if it's an enhancement, refactor, or improvement. Default to `type:bug` if ambiguous.
3. **Milestone** —
   - If the human referenced specific issues (`#N`), find which milestone they belong to.
   - If only one open milestone exists, use it.
   - If multiple open milestones and no clear match, use the most recently created one.
   - If no open milestones, the issue is milestone-less (standalone backlog item).
4. **Stabilization context** —
   - Check if the description contains "stabilization" or "stabilize"
   - Check if a stabilization ticket exists for the active milestone:
     ```bash
     gh issue list --repo {owner}/{repo} --milestone "{milestone_title}" \
       --search "\"Stabilization: {milestone_title}\" in:title" \
       --json number,title --jq '.[0].number'
     ```
   - If either is true → stabilization context; record the stabilization ticket number as the parent.
   - Otherwise → standalone issue, no parent.

Keep this step cheap — no file reads, no code search, no debugging. You are only parsing the human's text plus a couple of gh API calls.

#### Step 3: Quick Dedup Check

Do a single fast search — do NOT invoke an agent and do NOT read candidate issue bodies in depth.

```bash
gh issue list --repo {owner}/{repo} --state open \
  --search "{keywords from title}" \
  --json number,title --limit 5
```

- **If no plausible match** → proceed to Step 4.
- **If an obvious match exists** (near-identical title, same component) → present the candidate to the human:
  > "This looks similar to #{N} — {title}. Attach your context as a comment on that issue instead? (yes / no — create a new one)"
  - On `yes`: `gh issue comment {N} --body "{human description}"` and stop. Report `Added context to #{N}`.
  - On `no`: proceed to Step 4.

#### Step 4: Create Issue

Create the GitHub Issue with a placeholder body. This is a fast capture — do not enrich yet.

For `type:bug`:
```bash
gh issue create --repo {owner}/{repo} \
  --title "{concise_title}" \
  --milestone "{milestone_title}" \
  --label "type:bug" \
  --body "$(cat <<'BODY'
**Parent:** #{stabilization_ticket_number_or_parent_story_or_none}

## Initial Report

{human description — verbatim}

## Fix Guidance

<!-- Investigation pending — run `/issue` investigation gate to populate -->
BODY
)"
```

For `type:task`:
```bash
gh issue create --repo {owner}/{repo} \
  --title "{concise_title}" \
  --milestone "{milestone_title}" \
  --label "type:task" \
  --body "$(cat <<'BODY'
## Objective

{one sentence derived from the human's description}

## Initial Report

{human description — verbatim}

## Investigation

<!-- Investigation pending — run `/issue` investigation gate to populate -->
BODY
)"
```

If in stabilization context, link as sub-issue of the stabilization ticket:
```bash
# If Sub-issues API available:
gh api graphql -f query='mutation { addSubIssue(input: {issueId: "{stabilization_ticket_node_id}", subIssueId: "{new_issue_node_id}"}) { issue { id } } }'
# Fallback: include <!-- buehler:parent #{stabilization_ticket_number} --> in the body
```

Capture the new issue number. Report to the human in one line:
> `Captured #{issue_number}: {title}` (milestone: {milestone_title or "none"}, type: {type})

#### Step 5: Gate — AskUserQuestion

This is the hard gate. Invoke `AskUserQuestion` **exactly once** with these options:

```
questions:
  - question: "Issue #{issue_number} is captured. What would you like to do next?"
    header: "Next step"
    multiSelect: false
    options:
      - label: "Add description"
        description: "I'll ask you for details and update the issue body. No investigation."
      - label: "Run investigation"
        description: "Spawn the investigator agent to find root cause and recommend severity/priority."
      - label: "Both"
        description: "Add a description first, then run the investigation."
      - label: "Done — leave as-is"
        description: "Keep the fast-capture body. You can run investigation later with `/issue` on the same description."
```

**Do not proceed past this gate without a user selection.** Do not spawn the investigator unless the user chose "Run investigation" or "Both".

#### Step 6: Handle Response

**If "Done — leave as-is":**
- Stop. The issue stands with its fast-capture body. Done.

**If "Add description":**
- Ask the human: "Share any detail you want in the body." Wait for their reply.
- Update the issue body, preserving the existing structure:
  ```bash
  gh issue edit {issue_number} --repo {owner}/{repo} --body "{updated_body}"
  ```
- Done.

**If "Run investigation":**
- Read `skills/issue/investigator-prompt.md`
- Replace all `{placeholders}` with values from Steps 1–4, including `{issue_number}`, `{issue_title}`, `{issue_type}`, and `{milestone_title}`
- Set `{interactive_flag}` to `true`
- Spawn the investigator agent:
  ```
  Agent tool:
    subagent_type: "buehler:investigator"
    prompt: {filled_prompt}
  ```
- Wait for the agent to return. Parse its structured YAML result.
- Present the recommendation to the human:
  ```
  Investigation complete for #{issue_number}.

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
- Done.

**If "Both":**
- Run the "Add description" flow first (ask, update body).
- Then run the "Run investigation" flow (spawn agent, present recommendation, apply labels).
- Done.

### What Mode 1 Does NOT Do

- Does **not** spawn the investigator before Step 5
- Does **not** run systematic debugging during capture
- Does **not** read code or files during Steps 1–4 (just the human's text plus gh API calls)
- Does **not** assume the user wants investigation — that decision belongs to the gate

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

Verify the issue has investigation findings (Fix Guidance or Investigation section populated, not the `<!-- Investigation pending -->` placeholder). If not investigated yet, tell the human: "This issue hasn't been investigated yet. Run `/issue` on the same description and choose 'Run investigation' at the gate, or manually add investigation findings to the issue body."

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
- No `AskUserQuestion` gate (backlog mode is already fast-capture by contract)
