---
name: dispatch
description: Use when ready to start implementation — spawns parallel implementer agents for issues that have no unresolved dependencies, targeting the feature branch and injecting mustread context into each agent
---

# dispatch — Spawn Implementation Agents

**Type:** Rigid. Follow this process exactly.

## Inputs

- A GitHub Milestone with issues created by `buehler:structure`
- Access to the project repository (GitHub MCP + gh CLI)

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Read configuration** — load buehler.yaml, auto-detect build commands (Step 1)
2. **Fetch issues and build dependency graph** — collect milestone issues, parse dependencies, build DAG (Steps 2-3)
3. **Identify parallelizable batch** — find ready issues, check file overlaps, apply priority/size sort (Step 4)
4. **Present dispatch plan** — show batch table with branch names, file overlap check, get approval if gated (Step 5)
5. **Dispatch agents** — generate branches, label issues, fill prompt templates, spawn parallel agents (Step 6)
6. **Monitor and report** — collect results, update labels, present batch report, check for next batch (Step 7)

## Process

### Step 1: Read Configuration

Read `.github/buehler.yaml` from the project root. Extract or use defaults:
```yaml
agents:
  max_parallel: 3
  model: opus
branches:
  prefix: buehler
  feature: ""        # e.g. feature/auth-v1 — REQUIRED
worktrees:
  directory: .worktrees
approval_gates:
  before_dispatch: false
commands:
  test: ""   # auto-detect if empty
  lint: ""
  build: ""
wiki:
  directory: .wiki
  meta_page: ""      # auto-derived from epic name if empty: {wiki_directory}/{Epic-Name}.md
  prd: ""            # auto-derived from epic name if empty: {wiki_directory}/PRD-{epic}-v{Major}.md
sizing:
  token_ranges: {}   # auto-derived from sizing.buckets if empty: { "size:xs": [1000, 10000], ... }
project:
  board_number:    # GitHub Project number
  board_title: ""  # GitHub Project title
review:
  auto_request: false
  reviewers: []      # GitHub usernames to request review from
```

**Resolve `repo_root`:** Read the `repo_root` value from preflight JSONL output (emitted by `check-config.sh`). All subsequent `git worktree` and `git -C` commands use this absolute path. Do not use `git rev-parse --show-toplevel` — it can resolve to `.wiki/` if the session's CWD is inside the wiki clone.

**Auto-detect build commands** if not configured:
- `package.json` exists -> `npm test`, `npm run lint`, `npm run build`
- `Cargo.toml` exists -> `cargo test`, `cargo clippy`, `cargo build`
- `pyproject.toml` exists -> `pytest`, `ruff check .`, (no build)
- `go.mod` exists -> `go test ./...`, `golangci-lint run`, `go build ./...`
- `Makefile` exists -> `make test`, `make lint`, `make build`

### Step 2: Fetch All Issues in Milestone

Use GitHub MCP to fetch all open issues in the milestone:
```
mcp__github__list_issues with owner, repo, state: "OPEN"
```

Filter to issues belonging to the target milestone. Then:

1. **Filter out `meta:ignore`** — any issue with the `meta:ignore` label is excluded completely from all processing.
2. **Collect `meta:mustread` issues separately** — issues with the `meta:mustread` label are context documents, not work items. Read their full bodies; these will be injected into each agent's prompt context.
3. **For remaining work items**, collect:
   - Issue number, title, body, labels
   - Parse `<!-- buehler:blocked-by #N, #M -->` from each issue body
   - Parse `<!-- buehler:parent #NN -->` from each issue body

### Step 3: Build Dependency Graph

For each work item issue, extract dependencies from `<!-- buehler:blocked-by ... -->` comments.

Parse `<!-- buehler:parent #NN -->` comments to understand story-to-task hierarchy. Walk parent-to-child relationships for task-level dependency resolution: if a parent story has a `blocked-by`, all its child tasks inherit that dependency.

Build a directed acyclic graph (DAG):
- Nodes = issues (work items only, not mustread or ignore)
- Edges = "blocked-by" relationships (both explicit and inherited from parent)
- Closed issues count as resolved dependencies

Verify the graph is acyclic. If cycles detected, report to user and stop.

### Step 4: Identify Parallelizable Batch

An issue is **ready** if:
1. All its `blocked-by` issues are closed (or have `status:done` label)
2. It has the `status:ready` label (not `status:in-progress`, `status:blocked`, `status:in-review`)
3. It is not assigned to another agent already
4. It does **not** have `meta:ignore` or `meta:mustread` labels (these are not work items)

From the ready set, select up to `max_parallel` issues. Selection criteria:
1. **Priority sort** — `priority:critical` > `priority:high` > `priority:medium` > `priority:low`
2. **File overlap check** — parse file paths from the `## Files Likely Affected` section of each issue body (bulleted list of paths). If two ready issues list the same file path, only dispatch one per batch (to avoid merge conflicts)
3. **Token-based sizing preference** — when priorities are equal, prefer smaller token estimates (`size:xs` < `size:s` < `size:m` < `size:l` < `size:xl`) for faster feedback

### Step 5: Approval Gate

If `approval_gates.before_dispatch` is true, present the batch plan and wait for human approval:

```markdown
## Dispatch Batch Plan

**Milestone:** {title}
**Feature Branch:** {feature_branch}
**Batch size:** {count} of {max_parallel} max
**Remaining issues:** {total_open - count}

| # | Title | Size | Priority | Branch |
|---|-------|------|----------|--------|
| {n} | {title} | {size} | {priority} | {branch_prefix}/{n}-{slug} from {feature_branch} |

**File overlap check:** {PASS or list conflicts}

Approve dispatch? (The agents will create branches off the feature branch, implement with TDD, and create PRs targeting the feature branch.)
```

If approval gate is off, announce the batch but proceed immediately.

### Step 5a: Resolve Board Field IDs

Before dispatching, resolve board field IDs (once per dispatch invocation):

1. Project node ID: `gh project view {board_number} --owner {owner} --format json --jq '.id'`
2. Status field ID: `gh project field-list {board_number} --owner {owner} --format json --jq '.fields[] | select(.name == "Status") | .id'`
3. Option IDs: `gh project field-list {board_number} --owner {owner} --format json --jq '.fields[] | select(.name == "Status") | .options[]'` — extract IDs for "In Progress" and "In Review"

These IDs are stable for the duration of a dispatch invocation.

### Step 5b: Dry-Run Mode (Optional)

If the user requested a dry run (`/dispatch --dry-run` or dry-run argument in the prompt), execute the full pipeline validation without spawning agents:

1. For each issue in the batch, create the worktree from `repo_root` (validates git plumbing):
   ```bash
   git -C {repo_root} worktree add \
     {repo_root}/{worktree_dir}/{branch_prefix}/{issue_number}-{slug} \
     -b {branch_prefix}/{issue_number}-{slug} \
     {feature_branch}
   ```
   Record PASS/FAIL per issue. On failure, continue to the next issue (do not abort).

2. Fill the implementer prompt template for each issue (same as Step 6 items 5-9).

3. Print each filled prompt to output.

4. Remove all worktrees created during dry run:
   ```bash
   git -C {repo_root} worktree remove {path}
   ```
   Also delete the branches created by `worktree add -b`:
   ```bash
   git -C {repo_root} branch -D {branch_prefix}/{issue_number}-{slug}
   ```

5. Report:
   ```markdown
   ## Dry Run Complete

   **Would dispatch:** {count} agents
   **Worktree creation:** {PASS/FAIL for each}
   **Bash permissions:** {PASS from preflight or FAIL}

   | # | Title | Branch | Worktree Path | Prompt Length |
   |---|-------|--------|---------------|--------------|
   | {n} | {title} | {branch} | {path} | ~{tokens} |

   Filled prompts printed above.
   No agents were spawned. Run dispatch without --dry-run to execute.
   ```

6. Stop. Do not proceed to Step 6.

### Step 6: Dispatch Agents

For each issue in the batch:

1. **Generate branch name:** `{branch_prefix}/{issue_number}-{slug}`
   - `slug` = issue title, lowercased, spaces -> hyphens, max 50 chars, alphanumeric + hyphens only

2. **Generate worktree path:** `{worktree_dir}/{branch_prefix}/{issue_number}-{slug}`

3. **Create the worktree** from `repo_root` — dispatch creates the worktree before spawning the agent. The agent receives a ready-to-use worktree and validates it (does not create it).
   ```bash
   git -C {repo_root} worktree add \
     {repo_root}/{worktree_dir}/{branch_prefix}/{issue_number}-{slug} \
     -b {branch_prefix}/{issue_number}-{slug} \
     {feature_branch}
   ```
   The worktree path passed to the agent is always an absolute path.

4. **Label the issue** `status:in-progress` (remove `status:ready`)

4a. **Update board status** — query the issue's item ID on the board, then set Status to "In Progress":
    ```bash
    # Get item ID
    gh project item-list {board_number} --owner {owner} --format json --jq '.items[] | select(.content.number == {issue_number}) | .id'
    # Set status
    gh project item-edit --id {item_id} --field-id {status_field_id} --project-id {project_node_id} --single-select-option-id {in_progress_option_id}
    ```

5. **Read the implementer prompt template** from `skills/dispatch/implementer-prompt.md` in this plugin

6. **Read the PR body template** from `skills/structure/pr-body-template.md` in this plugin

7. **Read `meta:mustread` issue bodies** collected in Step 2 and prepare them as a combined block for injection into the agent prompt under "Must-Read Context"

8. **Read wiki context** — fetch the wiki meta page and PRD (from config `wiki.meta_page` and `wiki.prd`) and prepare excerpts for injection under "Context Chain"

9. **Fill the prompt template** with:
   - Issue number, title, body
   - Owner, repo, feature branch
   - Branch name, worktree path
   - Test/lint/build commands
   - PR body template content
   - Must-Read Context (mustread issue bodies, or "None" if no mustread issues)
   - Context Chain (wiki meta page excerpt, PRD excerpt)
   - Size label and token range from `sizing.token_ranges`
   - Board IDs for implementer: project node ID, Status field ID, "In Review" option ID, board_number, owner

10. **Spawn the agent** using the Agent tool (no `isolation: "worktree"` — the worktree was already created in step 3):
    ```
    Agent tool with subagent_type: "buehler:implementer"
    prompt: {filled implementer prompt}
    model: {from config, default opus}
    ```
    Do NOT use `isolation: "worktree"` — this creates worktrees from the session's git context, which may be `.wiki/` after `buehler:structure`. Dispatch owns worktree creation.

Spawn all agents in a single message (parallel tool calls) for maximum concurrency.

### Step 7: Monitor and Report

After all agents in the batch complete:

1. **Collect results** — parse each agent's structured YAML result
2. **Update issue labels** based on results:
   - `status: success` -> issue already labeled `status:in-review` by agent
   - `status: error` -> label `status:blocked`, post failure details
   - `status: blocked` -> already labeled by agent
3. **Present batch report:**

```markdown
## Dispatch Batch Complete

| # | Title | Status | PR | Tests |
|---|-------|--------|-----|-------|
| {n} | {title} | {status} | #{pr} | {pass/fail} |

**Succeeded:** {count}
**Failed/Blocked:** {count}
```

4. **Check for next batch** — re-run Step 4 to identify newly-unblocked issues
   - If more issues are ready, ask: "Ready to dispatch next batch?" (or auto-dispatch if gate is off)
   - If no more issues ready and some are blocked, suggest investigating blockers
   - If all issues are in-review or done, suggest `buehler:review`

## Slug Generation

```
title = "Add user authentication middleware"
slug  = "add-user-authentication-middleware"

title = "Fix: Handle NULL values in CSV export (#42)"
slug  = "fix-handle-null-values-in-csv-export"
```

Rules:
- Lowercase
- Replace spaces and special chars with hyphens
- Remove consecutive hyphens
- Strip leading/trailing hyphens
- Truncate to 50 characters at word boundary
- Alphanumeric and hyphens only

## Worktree Lifecycle

Worktrees are created by dispatch (Step 6 item 3) and need lifecycle management across dispatch, review, and integration.

### Before Dispatch: Existence Check

Before spawning an agent for an issue, check if a worktree already exists at the target path:
```bash
git -C {repo_root} worktree list | grep "{worktree_path}"
```

| Condition | Action |
|-----------|--------|
| No worktree exists | Normal path — dispatch creates it in Step 6 item 3 |
| Worktree exists, branch matches | Re-dispatch scenario (agent failed/blocked previously). Remove the stale worktree first: `git -C {repo_root} worktree remove {path} --force`, then dispatch normally |
| Worktree exists, branch differs | Conflict — another issue was assigned this path. Report error, skip this issue |

### On Agent Failure

If an agent returns `status: error` or `status: blocked`:
- The worktree is left in place (it may contain useful diagnostic state)
- If the issue is re-dispatched later, the existence check above handles cleanup
- If the issue is abandoned, worktree is cleaned up during `buehler:integrate` Step 14

### During Review (review Step 4)

When `buehler:review` needs to address feedback on a task PR:
1. Check if the worktree still exists at the original path
2. If yes: reuse it (navigate to it, pull latest)
3. If no: re-create it from the task branch (`git worktree add {path} {branch_name}`)

### After Integration (integrate Step 14)

All worktrees for the milestone are cleaned up after merge:
```bash
git -C {repo_root} worktree remove {path}  # for each completed worktree
git -C {repo_root} worktree prune
```

## Important Rules

1. **Never dispatch more than `max_parallel` agents** — even if more issues are ready
2. **File overlap = sequential** — issues touching the same files must be in different batches
3. **Check dependencies are truly resolved** — a closed issue with a reverted PR is NOT resolved
4. **Each agent gets a fresh context** — pass all needed information in the prompt, don't assume shared state
5. **Use the Agent tool** — agents are spawned via `Agent` with `subagent_type: "buehler:implementer"`, NOT via bash. Do NOT use `isolation: "worktree"`.
6. **Branch from the feature branch** — never branch from main; agents PR back to the feature branch
7. **Inject mustread context** — every agent receives the bodies of all `meta:mustread` issues as context
8. **Check worktree existence** before dispatch — handle re-dispatch and conflict scenarios
