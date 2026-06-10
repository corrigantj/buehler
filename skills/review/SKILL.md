---
name: review
description: Use after dispatch agents create PRs — polls for human review activity on task PRs targeting the feature branch, addresses feedback, merges approved PRs, captures lessons learned with token calibration
---

# review — Poll Reviews, Address Feedback, Merge Task PRs

**Type:** Rigid. Follow this process exactly.

## Inputs

- A feature branch with open task PRs (created by `buehler:dispatch`)
- Access to the project repository (GitHub MCP + gh CLI)
- Configuration from `.github/buehler.yaml` (review section)

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Identify open task PRs** — fetch PRs targeting feature branch, collect CI and review state (Step 1)
2. **Spawn polling sub-agent** — fill polling-prompt template, launch haiku poller (Step 2)
3. **Process review activity** — route by review state: approved, changes requested, or comments only (Steps 3-4)
4. **Merge approved PRs** — rebase onto feature branch, verify CI, merge, update issue labels (Step 5)
5. **Update lessons learned** — append review round data to task issue comments (Step 6)
6. **Update scenario tracker** — mark completed scenarios on parent story (Step 7)
7. **Check for next batch** — identify newly unblocked tasks, present cycle summary (Step 8)

## Process

### Step 1: Identify Open Task PRs

Find all open PRs targeting the feature branch:
```bash
gh pr list --base feature/{epic}-v{Major} --state open --json number,title,headRefName,reviews,statusCheckRollup
```

For each PR, collect: PR number, linked issue number (from branch name or PR body), CI status, review state. Present a table showing current state:

```markdown
## Open Task PRs

| PR | Issue | Title | CI | Review State |
|----|-------|-------|----|--------------|
| #{pr} | #{issue} | {title} | pass/fail/pending | approved/changes_requested/pending |
```

### Step 2: Spawn Polling Sub-Agent

Read `polling-prompt.md` from this skill directory and fill in the template with:
- PR numbers from Step 1
- Owner/repo from config
- `review.polling_interval` (default: 60 seconds)
- `review.polling_timeout` (default: 3600 seconds)

Use the Task tool to spawn the polling agent:
- Model: `review.polling_model` from config (default: haiku)
- Prompt: filled polling-prompt.md template

The sub-agent:
- Polls GitHub API at the configured interval for review activity
- Returns a structured YAML result on first activity, timeout, or error
- Does NOT reason about code — only detects changes and returns raw data
- Backs off exponentially on rate limits
- Terminates after `polling_timeout` seconds if no activity detected

### Step 3: On Activity Detected

Main agent receives review data. Route based on review state:
- **Approved** -> proceed to Step 5
- **Changes Requested** -> proceed to Step 4
- **Comments only** (no formal review verdict) -> address comments, push, resume polling (back to Step 2)
- **No reviews / Timeout** -> report to user and **wait for direction**. Never self-merge. If polling timed out, present: "No human reviews received within the polling window. Waiting for review on {PR list}. Ask the reviewer or extend `review.polling_timeout` in `.github/buehler.yaml`."

### Step 4: Address Feedback

For each requested change or comment:

1. Read the review comment/inline comment
2. Navigate to the task's worktree. If the worktree no longer exists, re-create it from the task branch: `git worktree add {path} {branch_name}`
3. Make the requested code changes
4. Run tests to verify the fix doesn't break anything
5. Commit with descriptive message referencing the review
6. Push updated commits to the task branch
7. Post a reply on the PR addressing each comment: "Fixed in {commit_sha}" or explaining why an alternative approach was taken
8. Resume polling (back to Step 2)

### Step 5: On Approval — Merge Task PR

1. Check PR is up-to-date with feature branch:
   ```bash
   gh pr view {pr_number} --json mergeable,mergeStateStatus
   ```
   If behind, rebase onto feature branch and wait for CI.

2. **CODEOWNERS gate (default: on):** If `review.require_codeowners` is true (the default), verify a matching CODEOWNER has approved. If no CODEOWNER approval exists, **do not merge** — report the gap and resume polling. To find CODEOWNERS, check `CODEOWNERS`, `.github/CODEOWNERS`, and `docs/CODEOWNERS`.

3. Merge the task PR (task PRs always rebase into the feature branch for clean history):
   ```bash
   gh pr merge {pr_number} --rebase --delete-branch
   ```

4. Update linked issue: remove `status:in-review`, add `status:done`, close issue

### Step 6: Append Review Data to Lessons Learned

After merge, find the existing `## Lessons Learned` comment on the **task issue** (posted by the implementer agent during implementation). Append review-round data to it:

```markdown
- **Review rounds:** {count of review cycles}
- **What went well:** {summary of smooth implementation areas}
- **What went wrong:** {summary of issues encountered during review}
```

If no `## Lessons Learned` comment exists (e.g., agent crashed before posting), create a new one with the full template:

```markdown
## Lessons Learned

- **Estimated size:** {size label from issue labels}
- **Actual tokens:** (unknown — agent did not report)
- **Surprises:** (unknown — agent did not report)
- **Patterns:** (unknown — agent did not report)
- **Pitfalls:** (unknown — agent did not report)
- **Review rounds:** {count of review cycles}
- **What went well:** {summary of smooth implementation areas}
- **What went wrong:** {summary of issues encountered during review}
```

### Step 7: Update Scenario Acceptance Tracker

After merge, update the parent story's Scenario Acceptance Tracker:

1. Find the parent story (from `<!-- buehler:parent #NN -->` in the task body or sub-issue relationship)
2. For each scenario this task addressed, update the tracker table:
   - Status `-` to `done` and link the task/PR
   - If bugs were filed during implementation, status `-` to `bug` and link the bug issue
3. If you cannot edit the story body (permissions, format mismatch), post a comment on the story with the tracker update instead

### Step 8: Check for Next Batch

After all current PRs in this cycle are processed:

1. Check if new tasks are unblocked (their `blocked-by` dependencies are now closed)
2. Present cycle summary:

```markdown
## Review Cycle Complete

| PR | Issue | Title | Review Rounds | Merged |
|----|-------|-------|---------------|--------|
| #{pr} | #{issue} | {title} | {N} | Yes/No |

**Lessons Learned updated:** {count}
**Tasks still open:** {count}
**Dependencies newly unblocked:** {count}
```

3. Recommend next action:
   - If newly unblocked tasks: "Run `buehler:dispatch` to start next batch"
   - If all task PRs merged: "Run `buehler:integrate` to merge feature branch to main"
   - If PRs still awaiting review: "Waiting for human review on {list}"

## Important Rules

1. **Never merge without human approval** — always wait for at least one human review. If `review.require_codeowners` is true (the default), a matching CODEOWNER must approve. If no reviews exist yet, **continue polling** — never self-merge
2. **Always rebase onto feature branch** before merging — ensures clean history
3. **Run tests after addressing feedback** — before pushing updated commits
4. **Append review data to Lessons Learned on every merged PR** — no exceptions, this feeds the full retrospective
5. **Polling sub-agent uses cheapest model** — it only detects changes, doesn't reason about code
6. **If PR is closed/rejected** — report to user and stop processing that PR
7. **All skill references** use `buehler:{skill}` format
8. **All label references** use `:` delimiter
