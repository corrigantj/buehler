---
name: status
description: View project progress with sub-issue grouping under parent stories, wiki links, feature branch awareness — builds a dashboard from GitHub Issue and PR state, categorizes by status, shows blockers and CI results, enables session crash recovery
---

# status — Progress Dashboard

**Type:** Rigid. Follow this process exactly.

## Inputs

- A GitHub Milestone (provide milestone title or number, or auto-detect the most recent open milestone)
- Access to the project repository (GitHub MCP + gh CLI)

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Fetch milestone issues** — get all open and closed issues, parse dependencies and parent relationships (Step 1)
2. **Categorize by status** — bucket issues into Done, In Review, In Progress, Blocked, Ready, Pending (Step 2)
3. **Fetch PR and CI status** — check linked PRs, CI results, feature→main PR state (Step 3)
4. **Present dashboard** — render progress bar, story hierarchy, blockers, wiki links, next actions (Step 4)

## Process

### Step 1: Fetch All Issues in Milestone

Fetch all issues (open AND closed) in the milestone:
```
mcp__github__list_issues with owner, repo (both OPEN and CLOSED state)
```

Filter to the target milestone. For each issue, collect:
- Number, title, state (open/closed), labels, assignee
- Parse `<!-- buehler:blocked-by #N, #M -->` from body
- Parse `<!-- buehler:parent #NN -->` from body to build parent→child relationships

For each story issue (labeled `type:story`), also fetch its sub-issues (tasks and bugs). Build a map of parent story → child tasks/bugs using the `<!-- buehler:parent #NN -->` comment parsed from each task/bug body.

**Skip `meta:ignore` issues** — exclude them from the dashboard entirely.

If no milestone is specified, find the most recent open milestone:
```bash
gh api repos/{owner}/{repo}/milestones --jq '.[0]'
```

### Step 2: Categorize Issues by Status

Categorize each issue into exactly one bucket based on labels and state:

| Bucket | Criteria | Display |
|--------|----------|---------|
| **Done** | Closed + `status:done` label | Checkmark |
| **In Review** | Open + `status:in-review` label | Arrow-right |
| **In Progress** | Open + `status:in-progress` label | Spinner |
| **Blocked** | Open + `status:blocked` label | X |
| **Ready** | Open + `status:ready` label + all deps resolved | Circle |
| **Pending** | Open + deps unresolved (no actionable status) | Dot |

If an issue's labels conflict (e.g., both `status:ready` and `status:blocked`), use the highest-priority bucket: Blocked > In Progress > In Review > Ready > Pending.

**Special label handling:**
- `meta:ignore` — skip the issue from display entirely (already filtered in Step 1)
- `meta:mustread` — do NOT place in a status bucket; collect separately for the "Context Documents" section

### Step 3: Fetch PR Status for In-Review Issues

For each issue labeled `status:in-review`:

1. Find the linked PR (search for PRs mentioning `Closes #{issue_number}` or with branch name matching `buehler/{issue_number}-*`)
2. PRs now target the **feature branch** (e.g., `feature/{epic}-v{Major}`), not `main`. Verify the PR base branch is the feature branch.
3. Fetch CI status:
   ```
   mcp__github__pull_request_read(method: "get_status", owner, repo, pullNumber)
   ```
4. Record: PR number, CI status (passing/failing/pending), review state (approved/changes-requested/pending)

Also check if a **feature→main PR** exists:
```bash
gh pr list --base main --head "feature/{epic}-*" --json number,state,title
```
If found, include its status in the dashboard.

### Step 4: Present Dashboard

Output a formatted dashboard:

```markdown
## Project Status: {milestone_title}

**Progress:** {done_count}/{total_count} issues complete ({percentage}%)
```
███████████░░░░░░░░░ 55%
```

### Stories

#### #{N}: {story title} [`size:m`] [`status:in-review`]
  - Task #{N}: {title} [`status:done`]
  - Task #{N}: {title} [`status:in-review`]
  - Bug  #{N}: {title} [`status:ready`]
  - **Scenarios:** S1 ✅ | S2 🐛 (#{bug_number}) | S2a ✅
  - **Lessons:** {count} Lessons Learned captured

#### #{N}: {story title} [`size:s`] [`status:in-progress`]
  - Task #{N}: {title} [`status:in-progress`]
  - Task #{N}: {title} [`status:ready`]

{Repeat for each story. Tasks/bugs without a parent story are listed under an "Ungrouped Tasks" heading.}

### Stabilization
{If a stabilization ticket exists in the milestone (title matches "Stabilization: {milestone_title}"):}

#### #{N}: Stabilization: {milestone_title} [`meta:ignore`]
  - Bug  #{N}: {title} [`severity:major`] [`priority:high`] [`status:ready`]
  - Task #{N}: {title} [`severity:minor`] [`priority:medium`] [`status:in-progress`]
  - **Exit criteria:** {open_count}/{total_count} children remaining

{Stabilization children are grouped here instead of under "Ungrouped Tasks". Display severity labels alongside status labels for all issues that have them.}

### CI Status (In-Review PRs)
| Issue | PR | Base Branch | CI | Review |
|-------|----|----|--------|--------|
| #{issue} | #{pr} | feature/{epic}-v{X} | {pass/fail/pending} | {approved/changes-requested/pending} |

{If a feature→main PR exists:}
| Feature PR | #{pr} | main | {pass/fail/pending} | {approved/changes-requested/pending} |

### Blockers
{For each blocked issue:}
- **#{number}: {title}** — {reason from latest issue comment or label}
  - Blocked by: #{deps that are still open}

### Remaining Dependency Graph
{Show only unresolved portions of the DAG}

### Wiki
- **Meta page:** [{Epic Name}](wiki_link)
- **PRD:** [PRD-{epic}-v{X}](wiki_link)
- **Feature branch:** `feature/{epic}-v{Major}`

### Project Board
- **Board:** [View board](https://github.com/{users|orgs}/{owner}/projects/{board_number})
  (Determine `users/` vs `orgs/` from `gh api users/{owner} --jq '.type'`)

### Context Documents
{For each issue labeled `meta:mustread`:}
- **#{number}: {title}** — {brief description or first line of body}

### Recommended Next Actions
{Based on current state:}
- {If task PRs awaiting review: "Run `buehler:review` to process PR reviews"}
- {If all tasks merged to feature branch: "Run `buehler:integrate` to merge feature branch to main"}
- {If tasks still in progress: "Wait for agents to complete, or check for blockers"}
- {If issues ready: "Run `buehler:dispatch` to start next batch"}
- {If blockers exist: "Resolve blocker on #{N}: {description}"}
- {If stabilization ticket has open children: "Stabilization in progress — {open_count} issues remaining. Run `buehler:issue` to capture more issues or `buehler:issue fix #N` to fix them."}
- {If stabilization ticket exists and all children closed: "Stabilization complete — all issues resolved. Safe to run `buehler:integrate`."}
```

## Session Recovery

This skill is the **session crash recovery mechanism**. When starting a new session after a crash:

1. Run `buehler:status` — it reads all state from GitHub, not from conversation memory
2. The dashboard shows exactly where the project stands
3. Based on the dashboard, the user can:
   - Re-dispatch blocked or failed issues
   - Continue with `buehler:integrate` if PRs are ready
   - Manually fix blockers and re-dispatch

No state is lost because GitHub Issues and PRs are the durable state machine.

## Progress Bar Rendering

Use block characters for the progress bar:
```
Full block:  █ (U+2588)
Light shade: ░ (U+2591)
Width: 20 characters
Each character = 5%
```

Example at 55% (11 full, 9 light):
```
███████████░░░░░░░░░ 55%
```

## Important Rules

1. **Always show all issues** — including closed ones (they're the "done" count), but exclude `meta:ignore` issues
2. **Group tasks under parent stories** — use the `<!-- buehler:parent #NN -->` relationship to nest tasks/bugs under their parent story
3. **Parse dependencies fresh** — don't cache from a previous session
4. **CI status is live** — always fetch current status, not cached
5. **Be actionable** — the "Recommended Next Actions" section must give concrete next steps with full skill names (`buehler:dispatch`, `buehler:integrate`, etc.)
6. **Handle milestone not found** — if no milestone exists, tell the user to run `buehler:structure` first
7. **Show wiki links** — always include the Wiki section with links to the meta page, PRD, and feature branch
8. **Show context documents** — always include a Context Documents section if any `meta:mustread` issues exist
