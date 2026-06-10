# GitHub Projects Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Projects board integration to buehler so issues are visually tracked on a four-column kanban (Ready, In Progress, In Review, Done).

**Architecture:** One board per repo, created by setup, populated by structure, with status transitions driven by dispatch and implementer via `gh project item-edit`. GitHub's built-in workflow automations handle item-added→Ready and item-closed→Done; buehler handles the two intermediate transitions.

**Tech Stack:** `gh project` CLI, GitHub GraphQL API (for `linkProjectV2ToRepository`), bash (preflight script)

**Spec:** `docs/plans/2026-03-17-github-projects-integration-design.md`

---

### Task 1: Add `check-project.sh` preflight script

**Files:**
- Create: `scripts/preflight-checks/check-project.sh`
- Modify: `scripts/preflight-checks/runner.sh:91` (add run_check line)

This is the foundation — other tasks depend on preflight passing with project checks.

- [ ] **Step 1: Create `check-project.sh`**

Follow the same pattern as `check-env.sh` (emit function, JSONL output, `set -euo pipefail`). Three checks:

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"
OWNER="${OWNER:-}"

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

# Read board_number from config
board_number=""
if [ -f "$CONFIG_PATH" ] && command -v python3 &>/dev/null; then
  board_number=$(python3 -c "
import yaml
try:
    with open('${CONFIG_PATH}') as f:
        data = yaml.safe_load(f) or {}
    bn = data.get('project', {}).get('board_number', '')
    print(bn if bn else '')
except Exception:
    print('')
" 2>/dev/null)
fi

# project.exists — board_number must be in config
if [ -z "$board_number" ]; then
  emit "project.exists" "fail" "No board_number in config" \
    "Run buehler:setup to create a GitHub Project board"
  exit 0
fi

# Verify the board actually exists
if ! gh project view "$board_number" --owner "$OWNER" --format json &>/dev/null; then
  emit "project.exists" "fail" "Project board #${board_number} not found for owner ${OWNER}" \
    "Run buehler:setup to create or reconfigure the project board"
  exit 0
fi
emit "project.exists" "pass" "Project board #${board_number} exists"

# project.linked — verify repo is linked to the project
linked_repos=$(gh api graphql -f query="
  query {
    user(login: \"${OWNER}\") {
      projectV2(number: ${board_number}) {
        repositories(first: 50) {
          nodes { name }
        }
      }
    }
  }
" --jq '.data.user.projectV2.repositories.nodes[].name' 2>/dev/null || \
gh api graphql -f query="
  query {
    organization(login: \"${OWNER}\") {
      projectV2(number: ${board_number}) {
        repositories(first: 50) {
          nodes { name }
        }
      }
    }
  }
" --jq '.data.organization.projectV2.repositories.nodes[].name' 2>/dev/null || echo "")

if echo "$linked_repos" | grep -qx "${REPO}"; then
  emit "project.linked" "pass" "Project board is linked to ${OWNER}/${REPO}"
else
  emit "project.linked" "fail" "Project board #${board_number} is not linked to ${OWNER}/${REPO}" \
    "Run buehler:setup to link the project board to this repository"
fi

# project.status_field — verify Status field has expected options
status_options=$(gh project field-list "$board_number" --owner "$OWNER" --format json 2>/dev/null | \
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for f in data.get('fields', []):
        if f.get('name') == 'Status':
            opts = [o.get('name','') for o in f.get('options', [])]
            print('\n'.join(opts))
            break
except Exception:
    pass
" 2>/dev/null || echo "")

all_found=true
missing=""
for expected in "Ready" "In Progress" "In Review" "Done"; do
  if ! echo "$status_options" | grep -qxF "$expected"; then
    all_found=false
    missing="${missing}${expected}, "
  fi
done

if $all_found; then
  emit "project.status_field" "pass" "Status field has all expected options: Ready, In Progress, In Review, Done"
else
  missing="${missing%, }"
  emit "project.status_field" "warn" "Status field missing options: ${missing}" \
    "Open the project board settings and add the missing Status options"
fi
```

Make the script executable: `chmod +x scripts/preflight-checks/check-project.sh`

- [ ] **Step 2: Test the script locally**

Run: `OWNER=corrigantj REPO=buehler CONFIG_PATH=.github/buehler.yaml bash scripts/preflight-checks/check-project.sh`

Expected: fail on `project.exists` (no board_number in config yet). Each line should be valid JSONL.

- [ ] **Step 3: Add run_check to runner.sh**

In `scripts/preflight-checks/runner.sh`, add after line 91 (`run_check "wiki"...`):

```bash
run_check "project" "${SCRIPT_DIR}/check-project.sh"
```

- [ ] **Step 4: Test runner with new check**

Run: `scripts/preflight-checks/runner.sh`

Expected: project.exists should fail (no board_number), other existing checks unchanged.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight-checks/check-project.sh scripts/preflight-checks/runner.sh
git commit -m "feat(preflight): add check-project.sh — verify board exists, linked, and has Status field"
```

---

### Task 2: Add board config fields to `templates/buehler.yaml`

**Files:**
- Modify: `templates/buehler.yaml:8-11` (add board_number and board_title under project)

- [ ] **Step 1: Add new fields to the project section**

After line 11 (`base_branch: ""`), add:

```yaml
  board_number:    # GitHub Project number (populated by buehler:setup)
  board_title: ""  # GitHub Project title (populated by buehler:setup)
```

- [ ] **Step 2: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('templates/buehler.yaml'))"`

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add templates/buehler.yaml
git commit -m "feat(config): add board_number and board_title to buehler.yaml template"
```

---

### Task 3: Add Project Board wizard section to setup skill

**Files:**
- Modify: `skills/setup/SKILL.md:59-61` (insert new Section 2 between Project Identity and Sizing Buckets, renumber remaining sections)

- [ ] **Step 1: Insert Section 2 (Project Board) after Section 1 (Project Identity)**

After the Project Identity section (line 59, closing of section 1's yaml block), insert:

```markdown
2. **Project board** — create or reuse a GitHub Project board for visual tracking.
   - Ask: "What would you like to name your project board?" Default recommendation: the repo name.
   - Check if a board with that title already exists: `gh project list --owner {owner} --format json`
   - If exists: "Found existing board '{title}' (#{number}). Use this one?" — if yes, store and skip creation.
   - If not:
     - Create: `gh project create --owner {owner} --title "{title}" --format json` — extract `number`
     - Get the project's GraphQL node ID: `gh project view {number} --owner {owner} --format json --jq '.id'`
     - Get the repo's GraphQL node ID: `gh api graphql -f query='{ repository(owner: "{owner}", name: "{repo}") { id } }' --jq '.data.repository.id'`
     - Link to repo:
       ```graphql
       mutation { linkProjectV2ToRepository(input: { projectId: "{project_node_id}", repositoryId: "{repo_node_id}" }) { clientMutationId } }
       ```
     - Store `board_number` and `board_title` in config
   - Determine owner type for URL: `gh api users/{owner} --jq '.type'` (returns "User" or "Organization")
   - Present workflow automation guide:
     > "Now configure the board's automation. Open this URL:"
     > `https://github.com/{users|orgs}/{owner}/projects/{number}/settings/workflows`
     >
     > Enable these workflows:
     > 1. **Item added to project** → Set status to "Ready"
     > 2. **Item closed** → Set status to "Done"
     > 3. **Item reopened** → Set status to "Ready"
     >
     > Also set the default view to Board layout grouped by Status.
     >
     > Let me know when you've done this.
   - Wait for user confirmation before proceeding.
```

- [ ] **Step 2: Renumber remaining sections**

Current sections 2-5 become 3-6:
- Sizing buckets: 2 → 3
- Wiki settings: 3 → 4
- Labels: 4 → 5
- Approval gates: 5 → 6

- [ ] **Step 3: Update the "Remaining config sections" text**

The paragraph after section 6 references "after init completes" — update to "after setup completes".

- [ ] **Step 4: Add board to remediation (Step 6)**

In the Step 6: Remediate section, add under "Model can execute directly":
- Missing board → run the board creation commands from the `fix` field
- Board not linked → run the `linkProjectV2ToRepository` mutation

Add under "Needs human action":
- Workflow automations not configured → present the settings URL and ask user to configure

- [ ] **Step 5: Commit**

```bash
git add skills/setup/SKILL.md
git commit -m "feat(setup): add Project Board wizard section — create board, link repo, guide automations"
```

---

### Task 4: Update structure skill to add issues to the board

**Files:**
- Modify: `skills/structure/SKILL.md:24-25` (update checklist item 6)
- Modify: `skills/structure/SKILL.md:153-170` (after Step 7 milestone creation, before Step 8)
- Modify: `skills/structure/SKILL.md:280-307` (Step 14 summary — add board URL)

- [ ] **Step 1: Add board step to the structure checklist**

Update checklist item 6 (line 24) to include board population:

```markdown
6. **Create stories and tasks** — stories with BDD scenarios, dev tasks as sub-issues, dependency annotations, add all to project board (Steps 9-11)
```

- [ ] **Step 2: Read board_number in Step 2 (Read Configuration)**

Add to the list of extracted config values at line 43-46:

```markdown
- **Board settings** -- `project.board_number`, `project.board_title`
```

- [ ] **Step 3: Add board URL to Step 7 (Create Milestone)**

After the milestone description content (line 159-160), add a line for the board URL:

```markdown
The milestone description **must** include:
- Link to the PRD wiki page
- Feature branch name
- Project board URL: `https://github.com/{users|orgs}/{owner}/projects/{board_number}`
  (Determine users/orgs via `gh api users/{owner} --jq '.type'`)
```

- [ ] **Step 4: Add new Step 11a: Add Issues to Project Board**

After Step 11 (Annotate Dependencies) and before Step 12 (Post-Creation Validation), insert:

```markdown
### Step 11a: Add Issues to Project Board

Read `board_number` from config. For each created issue (stories and tasks):

\`\`\`bash
gh project item-add {board_number} --owner {owner} --url https://github.com/{owner}/{repo}/issues/{issue_number}
\`\`\`

`gh project item-add` is idempotent — adding an already-added issue is a no-op, so retries are safe.

If an individual `item-add` fails (rate limit, transient error), log a warning and continue with remaining issues. Do not fail the entire structure run — issues and milestone are the critical artifacts, the board is supplementary.

The "Item added to project" workflow automation automatically sets the board Status to Ready.
```

- [ ] **Step 5: Add board URL to wiki meta page in Step 5b**

In Step 5b (Create or update wiki pages), when creating the Meta page, add the board URL. After the Version History table in `meta-template.md`, the structure skill should populate a project board link.

- [ ] **Step 6: Add board URL to Step 14 summary**

Add to the summary output (after Wiki Meta line):

```markdown
**Project Board:** [Board](https://github.com/{users|orgs}/{owner}/projects/{board_number})
```

- [ ] **Step 7: Commit**

```bash
git add skills/structure/SKILL.md
git commit -m "feat(structure): add issues to project board, include board URL in milestone and wiki"
```

---

### Task 5: Update dispatch skill to set board Status to "In Progress"

**Files:**
- Modify: `skills/dispatch/SKILL.md:30-55` (Step 1: Read Configuration — add board fields)
- Modify: `skills/dispatch/SKILL.md:129-167` (Step 6: Dispatch Agents — add board status update and pass IDs to implementer)

- [ ] **Step 1: Add board config to Step 1 (Read Configuration)**

Add to the config extraction section (after line 51):

```yaml
project:
  board_number:    # GitHub Project number
  board_title: ""  # GitHub Project title
```

- [ ] **Step 2: Add board ID resolution to Step 6 (before dispatching)**

After Step 5 (Approval Gate) and before the per-issue loop in Step 6, add:

```markdown
**Resolve board field IDs** (once per dispatch invocation):

1. Project node ID: `gh project view {board_number} --owner {owner} --format json --jq '.id'`
2. Status field ID: `gh project field-list {board_number} --owner {owner} --format json --jq '.fields[] | select(.name == "Status") | .id'`
3. Option IDs: `gh project field-list {board_number} --owner {owner} --format json --jq '.fields[] | select(.name == "Status") | .options[]'` — extract IDs for "In Progress" and "In Review"

These IDs are stable for the duration of a dispatch invocation.
```

- [ ] **Step 3: Add board status update to the per-issue dispatch loop**

After item 4 (label the issue `status:in-progress`) in Step 6, add:

```markdown
4a. **Update board status** — query the issue's item ID on the board, then set Status to "In Progress":
    \`\`\`bash
    # Get item ID
    gh project item-list {board_number} --owner {owner} --format json --jq '.items[] | select(.content.number == {issue_number}) | .id'
    # Set status
    gh project item-edit --id {item_id} --field-id {status_field_id} --project-id {project_node_id} --single-select-option-id {in_progress_option_id}
    \`\`\`
```

- [ ] **Step 4: Add board IDs to implementer prompt injection**

In Step 6, item 9 (Fill the prompt template), add to the list of injected values:

```markdown
   - Board IDs for implementer: project node ID, Status field ID, "In Review" option ID, board_number, owner
```

- [ ] **Step 5: Commit**

```bash
git add skills/dispatch/SKILL.md
git commit -m "feat(dispatch): set board Status to In Progress, pass board IDs to implementer"
```

---

### Task 6: Update implementer prompt template and agent definition

**Files:**
- Modify: `skills/dispatch/implementer-prompt.md:48-52` (add board IDs section)
- Modify: `agents/implementer.md:123-126` (Phase 8 — add board status update)

- [ ] **Step 1: Add board IDs section to implementer prompt template**

After the "Sizing" section (line 52) in `implementer-prompt.md`, add:

```markdown
## Board IDs

- **Board number:** {board_number}
- **Owner:** {owner}
- **Project node ID:** {project_node_id}
- **Status field ID:** {status_field_id}
- **"In Review" option ID:** {in_review_option_id}
```

- [ ] **Step 2: Add board status update to Phase 8 in implementer agent**

In `agents/implementer.md`, after line 124 (Phase 8, step 21: label update), add:

```markdown
21a. Update board status to "In Review":
    - Query your issue's item ID: `gh project item-list {board_number} --owner {owner} --format json --jq '.items[] | select(.content.number == {issue_number}) | .id'`
    - Set Status: `gh project item-edit --id {item_id} --field-id {status_field_id} --project-id {project_node_id} --single-select-option-id {in_review_option_id}`
    - Board IDs (project_node_id, status_field_id, in_review_option_id) are provided in your prompt inputs under "Board IDs".
```

- [ ] **Step 3: Add board IDs to "Inputs You Receive" section**

In `agents/implementer.md`, after item 10 (PR body template, line 31), add:

```markdown
11. **Board IDs** (project node ID, Status field ID, "In Review" option ID, board_number, owner)
```

- [ ] **Step 4: Commit**

```bash
git add skills/dispatch/implementer-prompt.md agents/implementer.md
git commit -m "feat(implementer): add board status update to In Review in Phase 8"
```

---

### Task 7: Update status skill to show board URL

**Files:**
- Modify: `skills/status/SKILL.md:127-131` (Wiki section in dashboard — add board URL)

- [ ] **Step 1: Add board URL to dashboard Wiki section**

In `skills/status/SKILL.md`, in the Step 4 dashboard template, after the Wiki section (line 131), add:

```markdown
### Project Board
- **Board:** [View board](https://github.com/{users|orgs}/{owner}/projects/{board_number})
  (Determine `users/` vs `orgs/` from `gh api users/{owner} --jq '.type'`)
```

- [ ] **Step 2: Add board_number to Step 1 config reading**

The status skill needs to read `project.board_number` from config. It currently auto-detects owner/repo from milestones. Add a note to read board_number from `buehler.yaml` if available.

- [ ] **Step 3: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "feat(status): show project board URL in dashboard"
```

---

### Task 8: Update CLAUDE.md and README.md documentation

**Files:**
- Modify: `CLAUDE.md:24` (add check-project.sh to plugin structure tree)
- Modify: `CLAUDE.md:50` (update skill flow to mention board)
- Modify: `README.md:265` (add check-project.sh to plugin structure tree)

- [ ] **Step 1: Add check-project.sh to CLAUDE.md plugin structure tree**

After `check-wiki.sh` line in the tree (line 24), add:

```
│       ├── check-project.sh        # Project board existence, linkage, Status field
```

- [ ] **Step 2: Add check-project.sh to README.md plugin structure tree**

Same addition in the README.md tree.

- [ ] **Step 3: Update skill flow in CLAUDE.md if needed**

The skill flow description may need a note that setup now creates a board, and structure populates it.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: add project board references to CLAUDE.md and README.md"
```
