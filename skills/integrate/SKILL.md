---
name: integrate
description: Use when all task PRs are merged into the feature branch — creates feature→main PR, polls for review, merges, creates retro wiki page, updates meta wiki, runs sizing calibration, closes milestone
---

# integrate — Feature Branch Merge, Retro, and Milestone Closure

**Type:** Rigid. Follow this process exactly.

## Inputs

- A GitHub Milestone with all task PRs merged into the feature branch (wave 1 complete)
- Access to the project repository (GitHub MCP + gh CLI)
- `.github/buehler.yaml` for configuration values

## Two-Wave Model Context

In buehler, merging happens in two waves:
- **Wave 1 (review):** Task branches merge into the feature branch via topological sort
- **Wave 2 (integrate — this skill):** The feature branch merges into the base branch (main)

This skill handles wave 2 plus all finalization: retro wiki page, meta wiki page update, PRD status update, sizing calibration PR, and milestone closure.

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Pre-integration audit** — verify all task PRs merged, check scenario trackers, report open issues (Step 1)
2. **Build merge plan** — determine merge order, present feature branch merge plan, get approval (Steps 2-3)
3. **Create feature PR** — open PR from feature branch to base branch with story summary (Step 4)
4. **Poll for review and merge** — spawn polling agent, address feedback, merge on approval, verify tests (Steps 5-6)
5. **Collect lessons learned** — gather all Lessons Learned comments from milestone issues (Step 8)
6. **Create retro wiki page** — fill retro template with aggregated data, commit and push (Step 9)
7. **Update wiki and PRD** — update meta page with shipped state, set PRD status to Approved (Steps 10-11)
8. **Calibrate sizing and close** — create sizing calibration PR, close milestone, present final report (Steps 12-14)

## Process

### Step 1: Pre-Integration Audit

Verify that wave 1 is complete — all task PRs should already be merged into the feature branch.

1. Fetch all issues in the milestone
2. Check scenario acceptance trackers on all stories — all scenarios should be passing
3. Verify every task issue is either:
   - Closed with `status:done` (task PR merged into feature branch)
   - Excluded by user decision
4. Fetch any still-open issues in the milestone
5. If any tasks are `status:in-progress`, `status:blocked`, or `status:ready`:
   - Report them and ask user how to proceed
   - Options: "Wait for completion", "Exclude from integration", "Cancel"
6. Check for open stabilization children:
   - Search for the stabilization ticket: `gh issue list --milestone "{milestone_title}" --search "\"Stabilization: {milestone_title}\" in:title" --json number --jq '.[0].number'`
   - If a stabilization ticket exists, fetch its sub-issues (or issues with `<!-- buehler:parent #{stabilization_number} -->`)
   - If any stabilization children are still open, report them as blockers
   - Options: "Wait for stabilization to complete", "Exclude remaining issues", "Cancel"

```bash
# Fetch open issues in milestone
gh issue list --milestone "{milestone_title}" --state open --json number,title,labels
```

### Step 2: Build Merge Order

In the two-wave model, there is typically **one feature PR** (feature→main). The per-issue topological sort is handled by `buehler:review` in wave 1.

If multiple feature branches are ready (multiple epics), use dependency ordering between epics:
- Parse epic-level dependencies from PRD wiki pages
- Merge independent epics first, dependent epics after

Present the merge plan showing the feature branch(es) to merge:
```markdown
## Feature Branch Merge Plan

| Order | Feature Branch | Epic | Stories | Tasks |
|-------|---------------|------|---------|-------|
| 1 | feature/{epic}-v{Major} | {Epic Name} | {count} | {count} |
```

### Step 3: Approval Gate

If `approval_gates.before_merge` is true, present the merge plan and wait:

```markdown
## Feature Branch Merge Plan

**Feature branch:** feature/{epic}-v{Major}
**Target:** {base_branch}
**Strategy:** squash (feature branch squashed into single commit on base branch)
**Stories included:** {count}
**Tasks completed:** {count}
**All scenario trackers passing:** Yes/No

Approve merge?
```

Even if the gate is off, **always announce** what you are about to do before starting.

### Step 4: Create Feature PR

Create a PR from the feature branch to the base branch:

```bash
gh pr create --base {base_branch} --head feature/{epic}-v{Major} \
  --title "{Epic Name} v{Major}.{Minor}" \
  --body "## {Epic Name} v{Major}.{Minor}

Milestone: #{milestone_number}
PRD: [PRD-{epic}-v{Major}](../../wiki/PRD-{epic}-v{Major})

### Stories Completed
{list of stories with issue numbers}

### Summary
{aggregate description of what this version delivers}
"
```

### Step 5: Poll for Review

Use the same polling mechanism as `buehler:review` but for the feature→main PR.

Read `polling-prompt.md` from the `buehler:review` skill directory and fill in the template with the feature PR number.

1. Spawn a polling sub-agent using the filled template (use `review.polling_model` from config, default haiku)
2. Poll at `review.polling_interval` seconds (default 60), timeout at `review.polling_timeout` (default 3600)
3. On review comments: address feedback, push fixes to feature branch
4. On approval: proceed to merge
5. On timeout: report to user and wait for direction
6. **CODEOWNERS gate (default: on):** If `review.require_codeowners` is true (the default), verify a matching CODEOWNER has approved before proceeding. If no CODEOWNER approval exists, **do not merge** — report the gap and continue polling

### Step 6: On Approval — Merge

Once the feature PR is approved, merge it into the base branch.

#### 6a. Ensure Feature Branch Is Up-to-Date

```bash
gh pr view {pr_number} --json mergeable,mergeStateStatus
```

If the feature branch is behind the base branch:
```bash
git fetch origin
git checkout feature/{epic}-v{Major}
git rebase origin/{base_branch}
git push --force-with-lease origin feature/{epic}-v{Major}
```

Wait for CI to re-run after rebase.

#### 6b. Check for Conflicts

If the feature branch has merge conflicts after rebase:
- **Additive conflicts** (different files or non-overlapping sections): attempt auto-resolve with rebase
- **Overlapping conflicts** (same lines in same file): present both versions to user, ask for resolution
- **Never force-resolve conflicts** — always present to user if auto-resolve fails

#### 6c. Merge PR

Squash-merge the feature branch into the base branch (collapses all task commits into a single commit):
```bash
gh pr merge {pr_number} --squash --delete-branch
```

#### 6d. Post-Merge Test Verification

After merging, verify the base branch is healthy:
```bash
git checkout {base_branch}
git pull origin {base_branch}
{test_command}
```

If tests fail after merge:
- **STOP immediately**
- Report what failed
- Present options: "Revert last merge", "Debug and fix", "Continue anyway (dangerous)"
- Do NOT proceed unless the user explicitly says so

### Step 7: Ask User — Close or Continue?

```markdown
Feature branch merged to {base_branch}.

**Options:**
1. **Close milestone** — run retro, update wiki, create calibration PR, close
2. **Keep open** — more work planned for this epic version (invoke `buehler:dispatch` for next minor)
```

If user chooses to keep open, stop here. Otherwise proceed with steps 8-14.

### Step 8: Collect Lessons Learned

Gather all `## Lessons Learned` comments from task issues in the milestone:

```bash
# For each issue in milestone, find comments matching "## Lessons Learned"
gh issue list --milestone "{milestone_title}" --state closed --json number --jq '.[].number'
```

For each issue, fetch comments and parse the `## Lessons Learned` section:
- Estimated size (the `size:` label)
- Actual tokens consumed
- Surprises, patterns, pitfalls (posted by the agent during implementation)
- Review rounds, what went well/wrong (appended by review after merge)

### Step 9: Create Retro Wiki Page

1. Pull the wiki repo (clone if needed per `wiki.directory` config):
   ```bash
   git -C {wiki_directory} pull origin master
   ```
2. Create `Retro-{epic}-v{Major}.{Minor}.md` using `retro-template.md` from this skill directory
3. Fill with:
   - Milestone summary (dates, counts, PRD link)
   - Aggregated lessons learned data (patterns, surprises, pitfalls)
   - Token calibration table (estimated vs actual per task)
   - Calibration recommendations
   - Process notes
4. If `approval_gates.before_wiki_update` is true, present the page content and wait for approval
5. Commit and push:
   ```bash
   git -C {wiki_directory} add "Retro-{epic}-v{Major}.{Minor}.md"
   git -C {wiki_directory} commit -m "Add retro for {epic} v{Major}.{Minor}"
   git -C {wiki_directory} push origin master
   ```

### Step 10: Update Meta Wiki Page

1. Pull the wiki repo
2. Update `{Epic-Name}.md` with the following sections:
   - **"What This Feature Does Today"** — describe the shipped state after this version
   - **Scope Matrix** — reflect what is now in production
   - **Version History** — add a row marking this version as Shipped with today's date
   - **Key Decisions** — add any ADRs created during this version
3. If `approval_gates.before_wiki_update` is true, present changes and wait for approval
4. Commit and push:
   ```bash
   git -C {wiki_directory} add "{Epic-Name}.md"
   git -C {wiki_directory} commit -m "Update meta page for {epic} v{Major}.{Minor} — shipped"
   git -C {wiki_directory} push origin master
   ```

### Step 11: Update PRD Status

1. Set the PRD wiki page status from **Active** to **Approved**
2. Commit and push:
   ```bash
   git -C {wiki_directory} add "PRD-{epic}-v{Major}.md"
   git -C {wiki_directory} commit -m "PRD-{epic}-v{Major}: status Active → Approved"
   git -C {wiki_directory} push origin master
   ```

### Step 12: Create Sizing Calibration PR

Using the token data collected in Step 8:

1. Tabulate estimated vs actual tokens from all Lessons Learned comments
2. Calculate delta percentages for each task
3. Identify systematic drift (e.g., consistent underestimation of a size bucket)
4. Generate recommended bucket adjustments if data shows consistent drift
5. Create a branch and PR modifying the `sizing.buckets` section of `.github/buehler.yaml`:
   ```bash
   git checkout -b calibrate/sizing-{epic}-v{Major}.{Minor} origin/{base_branch}
   # Apply sizing bucket updates to .github/buehler.yaml
   git add .github/buehler.yaml
   git commit -m "chore: calibrate sizing buckets from {epic} v{Major}.{Minor} retro"
   git push -u origin calibrate/sizing-{epic}-v{Major}.{Minor}
   gh pr create --base {base_branch} \
     --head calibrate/sizing-{epic}-v{Major}.{Minor} \
     --title "Calibrate sizing buckets from {epic} v{Major}.{Minor}" \
     --body "## Sizing Calibration

   Evidence from {epic} v{Major}.{Minor} retro:

   | Task | Issue | Estimated Size | Actual Tokens | Delta % |
   |------|-------|----------------|---------------|---------|
   {evidence rows}

   ### Recommendations
   {bucket adjustment rationale}

   See [Retro-{epic}-v{Major}.{Minor}](../../wiki/Retro-{epic}-v{Major}.{Minor}) for full details.
   "
   ```

### Step 13: Close Milestone

```bash
gh api repos/{owner}/{repo}/milestones/{milestone_number} \
  --method PATCH -f state="closed"
```

If `approval_gates.before_close_milestone` is true, ask for confirmation first.

### Step 14: Final Report

```markdown
## Integration Complete

**Milestone:** {title} — CLOSED
**Feature branch:** feature/{epic}-v{Major} → {base_branch}
**Merge strategy:** {strategy}
**Stories completed:** {count}
**Tasks completed:** {count}

### Wiki Updates
- **Retro:** [Retro-{epic}-v{X}.{Y}](wiki_link)
- **Meta page:** [{Epic Name}](wiki_link) — updated
- **PRD:** [PRD-{epic}-v{X}](wiki_link) — status: Approved

### Sizing Calibration
- **Calibration PR:** #{pr_number}
- **Tasks analyzed:** {count}
- **Bucket adjustments proposed:** {count}

### Post-Merge Tests
- **Status:** PASSING
- **Total tests:** {count}

### Cleanup
- Feature branch deleted: {yes/no}
- Worktrees to clean: `rm -rf {worktree_dir}/{branch_prefix}/`
```

## Conflict Resolution Strategies

| Conflict Type | Detection | Resolution |
|---|---|---|
| **Additive** — different files or non-overlapping sections | `git rebase` succeeds | Automatic via rebase |
| **Overlapping** — same lines in same file | `git rebase` fails with conflict markers | Present both versions to user, ask for resolution |
| **Semantic** — no textual conflict but broken behavior | Tests fail after merge | Revert merge, dispatch fix agent to reconcile |

## Worktree Cleanup

After integration, remind the user to clean up worktrees:
```bash
rm -rf {worktree_dir}/{branch_prefix}/
```

Or if using git worktree tracking:
```bash
git worktree list
git worktree remove {path}  # for each completed worktree
git worktree prune
```

## Important Rules

1. Always verify all task PRs merged before creating feature PR
2. Always verify tests after merge
3. Never force-merge conflicts — present to user
4. Stop on test failure
5. **Always create retro wiki page** before closing milestone
6. **Always update meta wiki page** after merge
7. **Always create sizing calibration PR** with evidence table
8. **PRD status → Approved** after merge
9. All label references use `:` delimiter (e.g., `status:done`, `size:m`)
10. All skill references use `buehler:{skill}` format
