# GitHub Projects Integration — Design Spec

**Date:** 2026-03-17
**Status:** Draft
**Epic:** buehler plugin enhancement

## Problem

buehler creates issues via `buehler:structure` and manages their lifecycle through labels and milestones, but there is no visual project board. Issues have nowhere to live as a kanban. Both the developer and stakeholders lack a shared, visual dashboard of work status outside the CLI.

## Goals

1. Give developers a visual kanban board that reflects issue status in real time
2. Give stakeholders a shareable URL to track feature progress without Claude Code
3. Integrate with the existing `status:` label workflow — no new state machines
4. Keep the blast radius small — most skills should not need board API calls

## Non-Goals

- Replacing the CLI `/status` dashboard — the board complements it
- Programmatic view creation — GitHub's API does not expose view CRUD mutations
- Programmatic workflow automation setup — GitHub's API does not expose workflow CRUD mutations
- Per-epic boards or per-epic views — one board per repo, no view management

## Design Decisions

### One board per repo

A single GitHub Project board is created per repository, shared across all epics. This avoids board sprawl and gives stakeholders a single URL to bookmark. Filtering by epic label or milestone provides per-epic focus within the board.

### Four columns

| Column | Trigger | Managed by |
|--------|---------|------------|
| Ready | "Item added to project" workflow automation | GitHub automation (setup guides user to configure) |
| In Progress | `status:in-progress` label added | `buehler:dispatch` sets via API |
| In Review | `status:in-review` label added | `implementer` agent sets via API |
| Done | Issue closed | GitHub automation (setup guides user to configure) |

No Backlog column. Buehler's dispatch handles prioritization and batching.

Blocked issues remain in their current column with the `status:blocked` label as a visual indicator — no separate Blocked column.

### Label-driven automation with two explicit API calls

GitHub's built-in project workflow automations handle the bookends:
- Item added → Ready
- Item closed → Done
- Item reopened → Ready

The two intermediate transitions (Ready → In Progress, In Progress → In Review) require explicit `gh project item-edit` calls because GitHub workflows cannot trigger on label changes. This is a small cost (two API calls total across dispatch and implementer) for a four-column kanban.

### Board name defaults to repo name

The setup wizard recommends the repo name as the board title but asks the user to confirm or customize.

## Configuration Changes

New fields in `.github/buehler.yaml` under the existing `project` key:

```yaml
project:
  owner: ""        # existing — auto-detected from git remote
  repo: ""         # existing — auto-detected from git remote
  base_branch: ""  # existing — auto-detected from git remote
  board_number:    # NEW — GitHub Project number, populated by setup
  board_title: ""  # NEW — GitHub Project title, populated by setup
```

`board_number` is the primary key used by all skills to interact with the board. `board_title` is stored for display purposes (milestone descriptions, wiki meta page links).

## Preflight Changes

New script: `scripts/preflight-checks/check-project.sh`

Three checks:

1. **`project.exists`** — verify `board_number` is present in config. If absent, emit fail with fix suggestion to run `buehler:setup`. If present, verify the board exists and is linked to the repo via `gh project view`. If the board is missing or not linked, emit fail. Board setup is mandatory — all gated skills (structure, dispatch, review, integrate) require it.

2. **`project.linked`** — verify the project is linked to the repository (not just that it exists). An unlinked board won't trigger "Item added" automations correctly. Check via `gh project view {board_number} --owner {owner} --format json` and verify the repo appears in linked repositories.

3. **`project.status_field`** — verify the board has a "Status" field with the expected single-select options: Ready, In Progress, In Review, Done. If options are missing or renamed, emit warn. This catches configuration drift.

Preflight does **not** check workflow automation state — there is no API for reading workflow configuration. The setup wizard guidance is best-effort.

## Setup Wizard Changes

New wizard section, slotted as **Section 2** (after Project Identity, before Sizing Buckets):

**Section 2: Project Board**

1. Ask the user for a board name. Default recommendation: repo name.
2. Check if a board with that title already exists: `gh project list --owner {owner} --format json`
3. If exists: "Found existing board '{title}' (#{number}). Use this one?" — if yes, store and skip creation.
4. If not exists:
   - Create: `gh project create --owner {owner} --title "{title}" --format json` — extract `number` from response
   - Get the project's GraphQL node ID: `gh project view {number} --owner {owner} --format json --jq '.id'`
   - Get the repo's GraphQL node ID: `gh api graphql -f query='{ repository(owner: "{owner}", name: "{repo}") { id } }' --jq '.data.repository.id'`
   - Link to repo:
     ```graphql
     mutation {
       linkProjectV2ToRepository(input: {
         projectId: "{project_node_id}",
         repositoryId: "{repo_node_id}"
       }) { clientMutationId }
     }
     ```
   - Store `board_number` and `board_title` in config
5. Present workflow automation guide:
   > "Now configure the board's automation. Open this URL:"
   > `https://github.com/{users|orgs}/{owner}/projects/{number}/settings/workflows`
   >
   > (Use `users/` for personal accounts, `orgs/` for organizations. Determine via `gh api users/{owner} --jq '.type'`.)
   >
   > Enable these workflows:
   > 1. **Item added to project** → Set status to "Ready"
   > 2. **Item closed** → Set status to "Done"
   > 3. **Item reopened** → Set status to "Ready"
   >
   > Also set the default view to Board layout grouped by Status.
   >
   > Let me know when you've done this.
6. Wait for user confirmation before proceeding.

**Updated wizard section order:**
1. Project identity
2. Project board *(new)*
3. Sizing buckets
4. Wiki settings
5. Labels
6. Approval gates

Config file is written using the Write tool directly (no `mkdir` — Write creates parent directories automatically).

## Resolving Board Field and Option IDs

The `gh project item-edit` command requires GraphQL node IDs for the project, the Status field, and the target option (e.g., "In Progress"). These IDs are not the same as the project number.

**How to resolve IDs:**

1. **Project node ID** — obtained from `gh project view {board_number} --owner {owner} --format json --jq '.id'`
2. **Status field ID** — obtained from `gh project field-list {board_number} --owner {owner} --format json --jq '.fields[] | select(.name == "Status") | .id'`
3. **Option IDs** — obtained from the same field-list query: `--jq '.fields[] | select(.name == "Status") | .options[] | {name, id}'`
4. **Item ID** (per issue) — obtained from `gh project item-list {board_number} --owner {owner} --format json --jq '.items[] | select(.content.number == {issue_number}) | .id'`

**Who resolves what:**

- **`buehler:dispatch`** resolves IDs 1-3 once per invocation (they don't change between issues), then resolves item IDs per issue. Dispatch also passes all resolved IDs (project node ID, field ID, option ID for "In Review") to each implementer agent via the agent prompt, so the implementer only needs to resolve its own item ID.
- **`implementer` agent** receives pre-resolved IDs from dispatch. Only queries its own item ID at runtime.

This minimizes API calls: dispatch does one field-list query, implementer agents do one item-list query each.

## Skill Changes

### `buehler:structure`

After creating all issues (stories + tasks) and assigning to the milestone:

- Read `board_number` and `owner` from config
- For each created issue: `gh project item-add {board_number} --owner {owner} --url {issue_url}`
- `gh project item-add` is idempotent — adding an already-added issue is a no-op, so retries are safe
- If an individual `item-add` fails (rate limit, transient error), log a warning and continue with remaining issues. Do not fail the entire structure run for a board error — the issues and milestone are the critical artifacts, the board is supplementary
- The "Item added to project" workflow automatically sets Status to Ready
- Add the board URL to:
  - Milestone description (alongside PRD link and feature branch name)
  - Wiki meta page (alongside existing links)

No conditional board checks — if structure is executing, preflight already passed and validated the board.

### `buehler:dispatch`

After labeling each dispatched issue `status:in-progress`:

1. Query the board for field IDs (once per dispatch invocation):
   - Project node ID via `gh project view`
   - Status field ID and option IDs via `gh project field-list`
2. Per dispatched issue, query the item ID via `gh project item-list`
3. Set the Status field to "In Progress": `gh project item-edit --id {item_id} --field-id {status_field_id} --project-id {project_id} --single-select-option-id {in_progress_option_id}`
4. Pass the following resolved IDs to each implementer agent prompt: project node ID, Status field ID, "In Review" option ID

### `implementer` agent

After creating the PR and updating labels to `status:in-review` (Phase 8):

1. Read pre-resolved IDs from the agent prompt (project node ID, Status field ID, "In Review" option ID — injected by dispatch)
2. Query its own item ID via `gh project item-list`
3. Set the Status field to "In Review": `gh project item-edit --id {item_id} --field-id {status_field_id} --project-id {project_id} --single-select-option-id {in_review_option_id}`

### `buehler:review`

No board changes. Issue closure triggers the "Item closed → Done" workflow automation automatically.

### `buehler:status`

Include the board URL in the dashboard output:
```
**Project Board:** https://github.com/{users|orgs}/{owner}/projects/{number}
```

The URL path segment (`users/` vs `orgs/`) depends on whether `owner` is a personal account or an organization. Determine at runtime: `gh api users/{owner} --jq '.type'` returns `"User"` or `"Organization"`.

### `buehler:integrate`

No board changes. Completed issues stay in the Done column. The board persists across epics.

## Manual Steps (One-Time During Setup)

These cannot be automated via API:

1. **Workflow automations** — three rules configured in project Settings > Workflows
2. **Default view layout** — set to Board, grouped by Status field

The setup wizard provides the exact URL and step-by-step instructions. These only need to be done once per board.

## File Changes Summary

| File | Change |
|------|--------|
| `skills/setup/SKILL.md` | New Section 2 (Project Board) in wizard |
| `skills/structure/SKILL.md` | Add issues to board, add board URL to milestone + wiki |
| `skills/dispatch/SKILL.md` | Set board Status to "In Progress" |
| `agents/implementer.md` | Set board Status to "In Review" |
| `skills/status/SKILL.md` | Show board URL in dashboard |
| `templates/buehler.yaml` | Add `board_number` and `board_title` fields |
| `scripts/preflight-checks/check-project.sh` | New preflight script |
| `scripts/preflight-checks/runner.sh` | Add `run_check "project" "${SCRIPT_DIR}/check-project.sh"` |
| `CLAUDE.md` | Update plugin structure and references |
| `README.md` | Update documentation |
