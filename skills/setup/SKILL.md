---
name: setup
description: Set up buehler for a repository — interactive config wizard, preflight checks, drift detection, and model-driven remediation
---

# setup — Setup, Configuration & Preflight

**Type:** Adaptive. Conversational when creating config, silent when checking drift.

## Inputs

- Access to the project repository (gh CLI)
- Optionally: existing `.github/buehler.yaml`

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Detect environment** — auto-detect owner/repo from git remote (Step 1)
2. **Check for existing config** — branch to wizard or preflight path (Step 2)
3. **Wizard OR preflight** — create config interactively or check drift silently (Steps 3-4)
4. **Run preflight** — execute runner.sh, parse JSONL results (Step 5)
5. **Remediate** — fix what the model can fix, guide the human on the rest (Step 6)
6. **Converge** — re-run preflight to confirm all green (Step 7)

## Process

### Step 1: Detect Environment

Auto-detect owner/repo from git remote:
```bash
gh repo view --json owner,name --jq '.owner.login + "/" + .name'
```

Also detect the default branch:
```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main"
```

### Step 2: Check for Existing Config

Check if `.github/buehler.yaml` exists:

- **Exists** → go to Step 4 (preflight path)
- **Does not exist** → go to Step 3 (wizard path)

### Step 3: Conversational Wizard (No Config)

Present recommended defaults section by section. For each section, show the default and ask: "Looks good, or want to change anything?"

**Section order:**

1. **Project identity**
   ```yaml
   project:
     owner: {detected}
     repo: {detected}
     base_branch: {detected}
   ```

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
   - Present **Status field update** guide first (workflows reference statuses that must exist before automations can be configured):
     > "First, update the board's Status field options. Open this URL:"
     > `https://github.com/{users|orgs}/{owner}/projects/{number}/settings/fields`
     >
     > Edit the **Status** field and ensure these options exist (rename or add as needed):
     > - **Ready**
     > - **In Progress**
     > - **In Review**
     > - **Blocked**
     > - **Done**
     >
     > Let me know when you've updated the Status field.
   - Wait for user confirmation that the Status field is updated.
   - Then present **workflow automation** guide (now that the referenced statuses exist):
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

3. **Sizing buckets**
   ```yaml
   sizing:
     metric: tokens
     buckets:
       xs: { lower: 1000, upper: 10000, description: "Trivial change, single file" }
       s: { lower: 10000, upper: 50000, description: "Small feature, few files" }
       m: { lower: 50000, upper: 200000, description: "Moderate feature, multiple files" }
       l: { lower: 200000, upper: 500000, description: "Large feature, significant scope" }
       xl: { lower: 500000, upper: null, description: "Must be split" }
   ```

4. **Wiki settings**
   ```yaml
   wiki:
     directory: .wiki
     auto_clone: true
   ```

5. **Labels** — show the full default taxonomy:
   - Priority: critical, high, medium, low
   - Meta: ignore, mustread
   - Size: xs, s, m, l, xl
   - Status: ready, in-progress, in-review, blocked, done
   - Type: story, task, bug (only if Issue Types unavailable)
   - Backlog: now, next, later, icebox
   - Severity: critical, major, minor, trivial
   - Ask: "Any custom labels to add?"

6. **Approval gates** — these control where buehler pauses to ask for your permission. Present as a checklist of plain-language descriptions (not raw YAML). Default is fully autonomous (no gates enabled):
   - **Pause before dispatching agents** — ask before spawning implementation agents (default: off)
   - **Pause before merging PRs** — ask before merging approved task PRs into the feature branch (default: off)
   - **Pause before closing milestones** — ask before closing the milestone during integrate (default: off)
   - **Pause before updating wiki** — ask before pushing changes to the project wiki (default: off)

   Ask: "These are all off by default, meaning buehler will run autonomously. Want to enable any of these checkpoints?"

   Map selections back to `approval_gates` keys in the generated YAML:
   ```yaml
   approval_gates:
     before_dispatch: false      # "Pause before dispatching agents"
     before_merge: false         # "Pause before merging PRs"
     before_close_milestone: false  # "Pause before closing milestones"
     before_wiki_update: false   # "Pause before updating wiki"
   ```

7. **Subagent permissions** — buehler agents need shell access to run git, tests, and linting.

   Auto-detect the project's stack using the same heuristics as build command detection:
   - Always include: `Bash(git:*)`, `Bash(gh:*)`, `Bash(gh issue *)`
   - `package.json` exists → add `Bash(npm:*)`, `Bash(npx:*)`, `Bash(node:*)`
   - `Cargo.toml` exists → add `Bash(cargo:*)`
   - `pyproject.toml` exists → add `Bash(python3:*)`, `Bash(pytest:*)`, `Bash(ruff:*)`
   - `go.mod` exists → add `Bash(go:*)`
   - `Makefile` exists → add `Bash(make:*)`

   Present the proposed permissions:
   ```
   buehler agents need shell access to run git, tests, and linting in parallel.
   Based on your project, here are the permissions I'd add to .claude/settings.json:

     - Bash(git:*)
     - Bash(gh:*)
     - Bash(gh issue *)
     - Bash(npm:*)       <- detected from package.json
     - Bash(npx:*)
     - Bash(node:*)

   Looks good, or want to change anything?
   ```

   After confirmation, read `.claude/settings.json` if it exists, merge the new permissions into the `permissions.allow` array (preserving existing entries), and write it back using the Write tool.

8. **CODEOWNERS** — buehler requires human review approval before merging PRs (`review.require_codeowners` defaults to true). This means a CODEOWNERS file must exist.

   Check for existing CODEOWNERS in standard locations (`CODEOWNERS`, `.github/CODEOWNERS`, `docs/CODEOWNERS`):
   - If found: "Found CODEOWNERS at {path}. Using existing file."
   - If not found:
     - Detect the repo owner: `gh api repos/{owner}/{repo} --jq '.owner.login'`
     - Propose a default CODEOWNERS file at `.github/CODEOWNERS`:
       ```
       # Default: repo owner is responsible for all files
       * @{owner}
       ```
     - Ask: "Who should be listed as code owners? Default is @{owner} for all files. You can add team-specific rules later."
     - After confirmation, write `.github/CODEOWNERS` using the Write tool

   If the user explicitly opts out of CODEOWNERS, set `review.require_codeowners: false` in the config and warn: "Without CODEOWNERS, buehler may self-merge PRs without human review."

Remaining config sections (`branches`, `worktrees`, `commands`, `epics`, `validation`, `review`) use sensible defaults and can be customized by editing `.github/buehler.yaml` directly after setup completes.

After all sections are confirmed, write `.github/buehler.yaml` using the Write tool directly (do NOT run `mkdir` first — Write creates parent directories automatically, and a separate `mkdir` triggers an unnecessary permission prompt).

### Step 4: Preflight Path (Config Exists)

Run preflight silently:
```bash
{PLUGIN_ROOT}/scripts/preflight-checks/runner.sh
```

Parse the JSONL output. Three outcomes:

- **All pass (exit 0, no fail lines):** Report "Everything's in sync." and stop.
- **Drift found (exit 1, has fail lines):** Present the drift report and offer two paths:
  - **"Fix drift"** → proceed to Step 6 (remediation)
  - **"Edit config"** → reopen the wizard (Step 3) for relevant sections, then re-run preflight
- **Warnings only (exit 0, has warn lines):** Report warnings for awareness, but do not block.

### Step 5: Run Preflight

Run the full preflight suite:
```bash
{PLUGIN_ROOT}/scripts/preflight-checks/runner.sh
```

Parse each JSONL line. Present results grouped by category:

```markdown
## Preflight Results

### Environment
- [pass] gh 2.45.0 authenticated as {user}
- [pass] Inside a git repository
- [pass] GitHub remote found

### Repository Capabilities
- [pass] Wiki is enabled
- [warn] Issue Types API not available — will use type: labels
- [pass] Sub-issues API available

### Configuration
- [pass] Config file found
- [pass] YAML syntax valid

### Labels
- [fail] Missing label: priority:critical
- [fail] Missing label: status:ready
- [pass] Label exists: size:m
{...}

### Wiki
- [pass] Wiki repo is cloneable
- [fail] Home.md does not exist
- [warn] _Meta-Template.md does not exist yet
```

If any failures, proceed to Step 6. If all pass, report success and stop.

### Step 6: Remediate

Read each failed check's `fix` field. Decide per-check:

**Model can execute directly:**
- Missing labels → run the `gh label create` commands from the `fix` fields
- Missing Home.md → clone wiki, create Home.md with a landing page, commit and push
- Missing config → should not happen here (wizard creates it), but generate defaults if needed
- Deprecated `merge` key in config → suggest removing it: "The `merge` section is no longer used — merge strategy is now hardcoded. Remove the `merge:` block from your `.github/buehler.yaml`."
- Missing board → create the board and link it to the repo using the commands from the wizard Section 2
- Board not linked → run the `linkProjectV2ToRepository` GraphQL mutation
- Missing .wiki/ in .gitignore → append `.wiki/` (or configured `wiki.directory` value) to `.gitignore`
- Missing subagent permissions → read `.claude/settings.json`, merge required Bash permissions into `permissions.allow`, write back
- Missing CODEOWNERS → create `.github/CODEOWNERS` with `* @{owner}` as default, confirm with user
- Missing stabilization ticket → run `bash scripts/create-stabilization-ticket.sh --owner {owner} --repo {repo} --milestone-title '{title}' --milestone-number {number}` for each flagged milestone

**Needs human action:**
- Wiki not enabled → tell the user: "Wiki is not enabled. Enable it in repo Settings > General > Features > Wiki. Let me know when it's done and I'll re-check."
- gh CLI not authenticated → tell the user: "Run `gh auth login` and let me know when done."
- No GitHub remote → tell the user: "Add a GitHub remote: `git remote add origin https://github.com/{owner}/{repo}.git`"
- Workflow automations not configured → present the project board settings URL and walk the user through enabling the three workflows (Item added → Ready, Item closed → Done, Item reopened → Ready)

After executing all model-fixable items and confirming human-fixable items, proceed to Step 7.

### Step 7: Converge

Re-run the preflight to confirm all checks now pass:
```bash
{PLUGIN_ROOT}/scripts/preflight-checks/runner.sh
```

- **All green:** "buehler is fully configured. You're ready to go. Next step: describe what you want to build (routes to `superpowers:brainstorming` to create a PRD), or if you already have a PRD, run `/structure` to convert it into GitHub issues and a milestone."
- **Still has failures:** Report remaining issues. If they're human-fixable, wait. If model-fixable items failed, investigate and retry (max 3 attempts).

## Important Rules

1. **Never mutate in preflight scripts** — only the model remediates, reading the `fix` suggestions
2. **Idempotent** — running init multiple times is safe and expected
3. **Wizard is conversational** — one section at a time, confirm before moving on
4. **Config is the source of truth** — preflight checks desired state against config, not hardcoded values
5. **Labels use `:` delimiter** — never `/`
6. **All skill references** use `buehler:{skill}` format
