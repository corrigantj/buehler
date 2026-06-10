---
name: structure
description: Use when converting a PRD or design document into a GitHub Wiki PRD, Meta page, Milestone with feature branch, and dependency-ordered Stories with dev task sub-issues
---

# structure -- PRD to GitHub Artifacts

**Type:** Rigid. Follow this process exactly.

## Inputs

- A PRD file (in `docs/plans/` or provided by user)
- Access to project repository (GitHub MCP + gh CLI)

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Parse PRD and read configuration** — extract epic name, stories, dependencies; read buehler.yaml (Steps 1-3)
2. **Validate inputs** — check PRD sections, story completeness, milestone uniqueness, size sanity (Step 4)
3. **Create wiki pages** — PRD page, meta page, Home page, templates; commit and push (Step 5)
4. **Create epic label and milestone** — per-epic label, milestone with PRD link (Steps 6-7)
5. **Create feature branch** — branch from base branch and push (Step 8)
6. **Create stories and tasks** — stories with BDD scenarios, dev tasks as sub-issues, dependency annotations, add all to project board (Steps 9-11a)
7. **Promote backlog items** — check for backlog items that map to new stories, offer batch promotion (Step 11b)
8. **Validate and finalize** — post-creation validation, update PRD status to Active, present summary (Steps 12-14)

## Process

### Step 1: Parse PRD

Read the PRD file. Extract:
- **Epic name** -- the high-level feature name (e.g., "Auth With Google")
- **Version** -- if present in the PRD (defaults to v1.0 if absent)
- **Stories** -- each distinct user-facing behavior becomes a product story
- **Dependencies** -- which stories depend on which
- **Shared infrastructure** -- foundation work needed before feature work

If the PRD is ambiguous, ask the user for clarification before proceeding.

### Step 2: Read Configuration

Read `.github/buehler.yaml` from the project root. Extract:
- **Wiki settings** -- `wiki.auto_clone`, template paths
- **Sizing buckets** -- `sizing.buckets` with token ranges (lower/upper) and descriptions
- **Validation settings** -- `validation.enabled`, required PRD sections
- **Approval gates** -- `approval_gates.before_wiki_update`, etc.
- **Board settings** -- `project.board_number`, `project.board_title`

Auto-detect owner/repo from git remote if not configured:
```bash
gh repo view --json owner,name --jq '.owner.login + "/" + .name'
```

If no config file exists, show defaults and continue:
```yaml
project:
  owner: (from git remote)
  repo: (from git remote)
  base_branch: (from git default branch)
wiki:
  auto_clone: true
sizing:
  metric: tokens
  buckets:
    xs: { lower: 1000, upper: 10000, description: "Trivial change, single file" }
    s: { lower: 10000, upper: 50000, description: "Small feature, few files" }
    m: { lower: 50000, upper: 200000, description: "Moderate feature, multiple files" }
    l: { lower: 200000, upper: 500000, description: "Large feature, significant scope" }
    xl: { lower: 500000, upper: null, description: "Must be split — too large for one agent session" }
validation:
  enabled: true
labels: []
```

### Step 3: Convert Naming

Convert the PRD title into lower-kebab-case and derive all artifact names:

| Artifact | Convention | Example |
|----------|-----------|---------|
| Epic name (kebab) | lower-kebab-case | `auth-with-google` |
| Milestone title | `{epic}-v{Major}.{Minor}` | `auth-with-google-v1.0` |
| Feature branch | `feature/{epic}-v{Major}` | `feature/auth-with-google-v1` |
| Epic label | `epic:{epic}` | `epic:auth-with-google` |
| PRD wiki page | `PRD-{epic}-v{Major}` | `PRD-auth-with-google-v1` |
| Meta wiki page | `{Epic-Name}` (Title-Case) | `Auth-With-Google` |

Always include the minor version in the milestone title (e.g., `v1.0` not `v1`).

### Step 4: Validate Inputs (Pre-Creation)

Before creating any GitHub artifacts, if `validation.enabled` is true:

1. **PRD sections** -- Verify the PRD has required sections: Background, Functional Requirements, Traceability
2. **Story completeness** -- Verify each extracted story has at least one acceptance scenario
3. **Milestone uniqueness** -- Verify milestone name doesn't already exist (or offer to reuse an existing one)
4. **PRD immutability** -- Verify no Approved or Superseded PRD exists for this epic version (Approved/Superseded PRDs cannot be modified -- create a new version instead)
5. **Size sanity** -- Flag any story estimated at XL (must be split before proceeding)

Loop until all checks pass. Report all failures at once so the user can fix them in batch.

### Step 5: Create/Update Wiki

**5a. Wiki availability check:**

Before any wiki operations, verify the wiki is accessible:
```bash
git clone --depth 1 https://github.com/{owner}/{repo}.wiki.git {wiki_directory} 2>&1
```

If the clone fails (wiki disabled, permissions error, network failure):
- **Wiki disabled (404):** Warn the user: "Wiki is not enabled on this repository. Skipping wiki pages (PRD, meta page, templates). Enable wiki in repository settings and re-run structure to create wiki pages." Continue with Steps 6+ (labels, milestone, issues).
- **Permission denied:** Report the error and stop. The user must fix repository access.
- **Network failure:** Retry once after 5 seconds. If still failing, report and stop.

If `wiki.auto_clone` is false and no wiki directory exists, skip wiki steps with a warning.

**5b. Create or update wiki pages:**

If wiki is available, pull latest, then create or update these pages:

1. **`Home.md`** -- If it doesn't exist, create a landing page that links to all meta pages and milestones
2. **Meta page `{Epic-Name}.md`** -- If this is the first version of this epic, create using `meta-template.md` from this skill directory
3. **PRD page `PRD-{epic}-v{Major}.md`** -- Create using `prd-template.md` from this skill directory. Set Status to **Draft**
4. **`_Meta-Template.md`** and **`_PRD-Template.md`** -- If they don't exist, create hidden templates (copies of `meta-template.md` and `prd-template.md`) so wiki editors can create pages manually

**5c. Commit and push:**

Respect `approval_gates.before_wiki_update` -- if set, confirm with user before pushing.

```bash
git -C {wiki_directory} add -A
git -C {wiki_directory} commit -m "structure: add PRD and meta page for {epic} v{Major}"
git -C {wiki_directory} push origin master
```

If push fails (merge conflict, network error):
- **Merge conflict:** Pull with rebase, attempt auto-resolve. If conflict persists, present diff to user.
- **Network error:** Retry once. If still failing, report the error. Wiki pages are committed locally and can be pushed manually later.

### Step 6: Create Epic Label

Create `epic:{epic}` with color `0052cc` (blue) if it doesn't already exist:
```bash
gh label create "epic:{epic}" --color "0052cc" --description "Epic: {Epic Name}" --force
```

Taxonomy labels (priority, meta, size, status, backlog, type) are created by `buehler:setup` and should already exist. If they don't, run `buehler:setup` first.

Read capability flags from the preflight JSONL injected as additionalContext by the PreToolUse hook:
- Issue Types: look for `"repo.issue_types"` with `"status":"pass"`
- Sub-issues API: look for `"repo.sub_issues"` with `"status":"pass"`

### Step 7: Create Milestone

Create the milestone via `gh api`:
```bash
gh api repos/{owner}/{repo}/milestones --method POST \
  -f title="{epic}-v{Major}.{Minor}" \
  -f description="PRD: [PRD-{epic}-v{X}](../../wiki/PRD-{epic}-v{X})
Feature branch: feature/{epic}-v{Major}" \
  -f state="open"
```

The milestone description **must** include:
- Link to the PRD wiki page
- Feature branch name
- Project board URL: `https://github.com/{users|orgs}/{owner}/projects/{board_number}` (determine `users/` vs `orgs/` via `gh api users/{owner} --jq '.type'`)

If a milestone with this title already exists, use it instead of creating a duplicate.

Capture the milestone number from the response for use in subsequent steps.

### Step 7a: Create Stabilization Ticket

Create a stabilization ticket for the new milestone. This is the parent ticket for any issues discovered during testing, review, or post-integration stabilization.

Run the creation script:

    bash scripts/create-stabilization-ticket.sh \
      --owner {owner} --repo {repo} \
      --milestone-title "{epic}-v{Major}.{Minor}" \
      --milestone-number {milestone_number} \
      --wiki-meta-url "../../wiki/{Epic-Name}"

The script is idempotent — if a stabilization ticket already exists for this milestone, it returns the existing issue number.

The stabilization ticket is labeled `meta:ignore` so that `buehler:dispatch` will not attempt to dispatch it for implementation.

### Step 8: Create Feature Branch

Create and push the feature branch from the configured base branch:
```bash
git checkout -b feature/{epic}-v{Major} {base_branch}
git push -u origin feature/{epic}-v{Major}
```

If the feature branch already exists, check it out instead.

### Step 9: Create Stories

For each product story extracted from the PRD, compose the issue body using `story-template.md` from this skill directory. Fill in:

- **PRD link** -- `[PRD-{epic}-v{X}](../../wiki/PRD-{epic}-v{X})`
- **Feature wiki link** -- `[{Epic Name}](../../wiki/{Epic-Name})`
- **User story** -- As a {persona}, I want to {action} so that {benefit}
- **Context** -- Why this matters (2-3 sentences)
- **Acceptance criteria** -- BDD scenarios numbered S1, S2, etc.
- **Definition of Done** -- Standard checklist
- **Agent instructions** -- Technical guidance, key files, constraints

Apply labels:
- `epic:{name}` -- links story to the epic
- `priority:{level}` -- from PRD priority or inferred
- `size:{bucket}` -- estimated from `sizing.buckets` config ranges
- `status:ready` or `status:blocked` -- based on dependency analysis

Use Issue Type `story` if available, otherwise apply `type:story` label.

Assign to the milestone created in Step 7.

Size estimation: use the `sizing.buckets` config to determine the appropriate size label. If a story estimates at `size:xl`, it must be split into smaller stories before creation.

Create stories in dependency order:
1. **Foundation / infra stories first** -- no dependencies
2. **Feature stories next** -- may depend on infra
3. **Integration / polish stories last** -- depend on features

### Step 10: Create Dev Tasks

For each story, create dev tasks as sub-issues. Compose bodies using `task-template.md` from this skill directory. Fill in:

- **Parent link** -- `#{parent_issue_number}`
- **Scenarios addressed** -- which parent scenarios (S1, S2, etc.) this task covers
- **Objective** -- one sentence describing what this task produces
- **Files Likely Affected** -- bulleted list of file paths this task will create or modify (used by `buehler:dispatch` for file-overlap detection and by `implementer` as a scope guardrail)
- **Implementation notes** -- function signatures, architectural decisions
- **Done when** -- concrete, verifiable checklist items

If Sub-issues API is available, create tasks as sub-issues of their parent story.

If Sub-issues API is unavailable, create as regular issues with `<!-- buehler:parent #NN -->` in the body to link to the parent story.

**Always assign tasks to the milestone** created in Step 7, regardless of whether they are sub-issues or regular issues. Sub-issues do not inherit milestone assignment from their parent.

Apply labels:
- `epic:{name}` -- links task to the epic
- `size:{bucket}` -- estimated from scope
- `status:ready` or `status:blocked` -- based on dependency analysis

Use Issue Type `task` if available, otherwise apply `type:task` label.

### Step 11: Annotate Dependencies

For each story that depends on other stories, ensure the body contains:
```html
<!-- buehler:blocked-by #12, #15 -->
```

This HTML comment is invisible to human readers but machine-parseable by `buehler:dispatch`.

Also label dependent stories as `status:blocked` (not `status:ready`).

Dependencies must be annotated both ways:
- The HTML comment in the issue body (for machine parsing)
- The `status:blocked` label (for visual scanning)

### Step 11a: Add Issues to Project Board

Read `board_number` from config. For each created issue (stories and tasks):

```bash
gh project item-add {board_number} --owner {owner} --url https://github.com/{owner}/{repo}/issues/{issue_number}
```

`gh project item-add` is idempotent — adding an already-added issue is a no-op, so retries are safe.

If an individual `item-add` fails (rate limit, transient error), log a warning and continue with remaining issues. Do not fail the entire structure run — issues and milestone are the critical artifacts, the board is supplementary.

The "Item added to project" workflow automation automatically sets the board Status to Ready.

### Step 11b: Promote Backlog Items

After all stories and tasks are created and added to the board, check for existing backlog items that may now be covered by the new milestone.

**11b-1. Fetch open backlog items:**

Query each tier separately (gh `--label` does AND matching):
```bash
backlog_items=""
for tier in now next later icebox; do
  items=$(gh issue list --repo {owner}/{repo} --label "backlog:${tier}" \
    --state open --json number,title,labels --limit 1000 2>/dev/null || echo "[]")
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

### Step 12: Post-Creation Validation

After all artifacts are created, verify each one:

**Stories must have:**
- PRD link in body
- Wiki link in body
- At least one numbered scenario (S1+)
- Definition of Done section

**Tasks must have:**
- Parent link in body
- Scenarios addressed listed
- Objective section
- Files Likely Affected section (at least one file path)
- Done When checklist

**Milestone must have:**
- PRD link in description
- Feature branch name in description
- Project board URL in description

Report any validation failures. Fix them before proceeding.

### Step 13: Update PRD Status

Update the wiki PRD page:
- Set Status from **Draft** to **Active**
- Populate the Traceability section with issue numbers and milestone link
- Commit and push wiki changes

### Step 14: Present Summary

Output a summary for the user:

```markdown
## Structured: {epic}-v{Major}.{Minor}

**Milestone:** #{N} -- {title}
**Feature branch:** feature/{epic}-v{Major}
**Wiki PRD:** [PRD-{epic}-v{X}](../../wiki/PRD-{epic}-v{X})
**Wiki Meta:** [{Epic Name}](../../wiki/{Epic-Name})
**Project Board:** [Board](https://github.com/{users|orgs}/{owner}/projects/{board_number})
**Issues:** {story_count} stories, {task_count} tasks

### Dependency Graph
{visual representation using indentation or ASCII}

### Ready for Dispatch
| # | Title | Type | Size | Priority |
|---|-------|------|------|----------|
| {number} | {title} | {type} | {size} | {priority} |

### Blocked
| # | Title | Blocked By |
|---|-------|-----------|
| {number} | {title} | #{deps} |

**Next:** invoke `buehler:dispatch` to start implementation.
```

## Important Rules

1. **Never create duplicate issues** -- check existing milestone issues first
2. **Every story must have BDD acceptance criteria** -- numbered scenarios S1, S2, etc.
3. **Dependencies annotated both ways** -- HTML comment in body + `status:blocked` label
4. **Size XL issues must be split** -- create smaller stories instead
5. **Foundation/infra first** -- create in dependency order
6. **One behavior per story** -- split if covering multiple behaviors
7. **Validation must pass before creation** -- measure twice, cut once (Step 4)
8. **Approved/Superseded PRDs cannot be modified** -- create a new version instead
9. **All skill references use `buehler:{skill}` format**
