# Dispatch Agent Failures — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three dispatch agent failures — wrong-repo worktrees, Bash permission denials, and implementer Phase 1 — by having dispatch own worktree creation, adding permission preflight checks, and updating the implementer to validate rather than create.

**Architecture:** Preflight scripts resolve `repo_root` deterministically from `buehler.yaml` location and verify Bash permissions. Dispatch creates worktrees explicitly via `git -C {repo_root}` before spawning agents. The implementer validates the pre-created worktree instead of creating one. A dry-run mode validates the full pipeline without spawning agents.

**Tech Stack:** Bash (preflight scripts), Markdown (skill definitions, agent definitions, prompt templates)

---

### Task 1: Emit `repo_root` from `check-config.sh`

**Files:**
- Modify: `scripts/preflight-checks/check-config.sh:19-25`

The `emit()` helper currently only supports `check`, `status`, `message`, and `fix` fields. The `repo_root` check needs a `value` field. We need to add a `value`-aware emit variant, then add the repo_root check after the config existence check passes.

- [ ] **Step 1: Read `check-config.sh` and understand the emit pattern**

The existing `emit()` function on lines 8-17 uses `jq -nc` with named args. It supports 3-4 fields: `check`, `status`, `message`, `fix` (optional). We need a new function `emit_value()` that adds a `value` field for checks that produce a result other skills consume.

- [ ] **Step 2: Add `emit_value()` function after the existing `emit()` function**

Add this after line 17 of `check-config.sh`:

```bash
emit_value() {
  local check="$1" status="$2" message="$3" value="$4"
  jq -nc --arg c "$check" --arg s "$status" --arg m "$message" --arg v "$value" \
    '{check:$c, status:$s, message:$m, value:$v}'
}
```

- [ ] **Step 3: Add repo_root resolution after the config.exists pass check**

After line 25 (`emit "config.exists" "pass" ...`), add:

```bash
# repo_root — resolve absolute path from config location
abs_config="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
repo_root="$(dirname "$(dirname "$abs_config")")"
emit_value "repo_root" "pass" "Repo root resolved from buehler.yaml location" "$repo_root"
```

This converts the relative `CONFIG_PATH` (default `.github/buehler.yaml`) to absolute, then goes up two levels (file → `.github/` → repo root).

- [ ] **Step 4: Emit repo_root fail when config doesn't exist**

In the config.exists fail block (lines 20-24), add a `repo_root` fail emit before the existing `config.exists` fail. This keeps the JSONL pattern consistent — consumers can grep for `repo_root` status rather than checking for absence.

Add before line 21 (`emit "config.exists" "fail" ...`):

```bash
  emit "repo_root" "fail" "Cannot resolve repo root — .github/buehler.yaml not found" \
    "Run buehler:setup to create .github/buehler.yaml"
```

- [ ] **Step 5: Verify the script runs without errors**

Run:
```bash
cd /Users/traviscorrigan/Documents/GitHub/buehler && CONFIG_PATH=.github/buehler.yaml bash scripts/preflight-checks/check-config.sh
```

Expected: existing checks pass plus a new `repo_root` line with an absolute path value.

Note: This repo doesn't have a `.github/buehler.yaml` (it's a plugin repo, not a consumer repo), so we expect a `config.exists` fail. That's correct — just verify no syntax errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight-checks/check-config.sh
git commit -m "feat(preflight): emit repo_root from check-config.sh

Resolves absolute repo root from buehler.yaml location. Skills
consume this value instead of using git rev-parse, which can
land in .wiki/ after buehler:structure clones the wiki repo."
```

---

### Task 2: Add `.wiki/` gitignore check to `check-wiki.sh`

**Files:**
- Modify: `scripts/preflight-checks/check-wiki.sh:54` (append after last check)

- [ ] **Step 1: Add wiki.gitignore check at the end of `check-wiki.sh`**

Append after line 54 (the last `fi`):

```bash
# wiki.gitignore — .wiki/ should be in .gitignore to prevent accidental commits
WIKI_DIR="${WIKI_DIR:-.wiki}"
if [ -f ".gitignore" ] && grep -qxF "${WIKI_DIR}/" .gitignore; then
  emit "wiki.gitignore" "pass" "${WIKI_DIR}/ is in .gitignore"
elif [ -f ".gitignore" ] && grep -qxF "${WIKI_DIR}" .gitignore; then
  emit "wiki.gitignore" "pass" "${WIKI_DIR} is in .gitignore"
else
  emit "wiki.gitignore" "fail" "${WIKI_DIR}/ not in .gitignore — wiki clone could be accidentally committed" \
    "Add ${WIKI_DIR}/ to .gitignore"
fi
```

Note: `WIKI_DIR` is already exported by `runner.sh` (line 47), but we default it locally for standalone runs.

- [ ] **Step 2: Verify the script syntax**

Run:
```bash
bash -n scripts/preflight-checks/check-wiki.sh
```

Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-wiki.sh
git commit -m "feat(preflight): check .wiki/ is in .gitignore

Prevents accidental commit of the wiki clone directory into the
main repo. Remediated by buehler:setup during wiki setup."
```

---

### Task 3: Create `check-permissions.sh`

**Files:**
- Create: `scripts/preflight-checks/check-permissions.sh`
- Modify: `scripts/preflight-checks/runner.sh:92` (add to run list)

- [ ] **Step 1: Create `check-permissions.sh`**

Follow the pattern from `check-env.sh` and `check-project.sh`. The script checks `.claude/settings.json` for minimum Bash permission glob patterns in `permissions.allow`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SETTINGS_PATH=".claude/settings.json"

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

# permissions.settings_exists
if [ ! -f "$SETTINGS_PATH" ]; then
  emit "permissions.settings_exists" "fail" "No ${SETTINGS_PATH} found — subagents will not have Bash permissions" \
    "Run buehler:setup to configure subagent permissions"
  exit 0
fi
emit "permissions.settings_exists" "pass" "Settings file found: ${SETTINGS_PATH}"

# permissions.bash_git — check for Bash(git:*) or Bash(git *) in permissions.allow
if ! command -v jq &>/dev/null; then
  emit "permissions.bash_access" "warn" "jq not available — cannot verify Bash permissions"
  exit 0
fi

allow_list=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_PATH" 2>/dev/null || echo "")

if [ -z "$allow_list" ]; then
  emit "permissions.bash_access" "fail" "No permissions.allow entries in ${SETTINGS_PATH} — subagents cannot run shell commands" \
    "Run buehler:setup to configure subagent permissions"
  exit 0
fi

# Check for minimum required: git and gh
missing=""
for required in "git" "gh"; do
  if ! echo "$allow_list" | grep -qE "Bash\(${required}[: ]"; then
    missing="${missing}${required}, "
  fi
done

if [ -z "$missing" ]; then
  emit "permissions.bash_access" "pass" "Bash permissions configured for subagents (git, gh found)"
else
  missing="${missing%, }"
  emit "permissions.bash_access" "fail" "Missing Bash permissions for subagents: ${missing}" \
    "Run buehler:setup to configure subagent permissions — agents need at minimum Bash(git:*) and Bash(gh:*)"
fi
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x scripts/preflight-checks/check-permissions.sh
```

- [ ] **Step 3: Add to `runner.sh` run list**

In `runner.sh`, after line 92 (`run_check "project" ...`), add:

```bash
run_check "permissions" "${SCRIPT_DIR}/check-permissions.sh"
```

- [ ] **Step 4: Verify syntax of both files**

Run:
```bash
bash -n scripts/preflight-checks/check-permissions.sh && bash -n scripts/preflight-checks/runner.sh
```

Expected: no output (syntax OK).

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight-checks/check-permissions.sh scripts/preflight-checks/runner.sh
git commit -m "feat(preflight): add check-permissions.sh for subagent Bash access

Verifies .claude/settings.json has minimum Bash permissions (git, gh)
so subagents can run shell commands. Prevents the silent failure
where agents are spawned but can't execute any Bash tool calls."
```

---

### Task 4: Update setup wizard with subagent permissions section

**Files:**
- Modify: `skills/setup/SKILL.md:117-134` (insert new section after approval gates)

- [ ] **Step 1: Add new wizard section 6 after approval gates**

After the approval gates section (line 132, the closing ` ``` ` of the approval_gates YAML), and before the "Remaining config sections" paragraph (line 134), insert:

```markdown
7. **Subagent permissions** — buehler agents need shell access to run git, tests, and linting.

   Auto-detect the project's stack using the same heuristics as build command detection:
   - Always include: `Bash(git:*)`, `Bash(gh:*)`
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
     - Bash(npm:*)       <- detected from package.json
     - Bash(npx:*)
     - Bash(node:*)

   Looks good, or want to change anything?
   ```

   After confirmation, read `.claude/settings.json` if it exists, merge the new permissions into the `permissions.allow` array (preserving existing entries), and write it back using the Write tool.
```

- [ ] **Step 2: Renumber existing sections**

The current sections are numbered 1-6. Insert the new section as 7 (after 6. Approval gates). Update the "Remaining config sections" paragraph to reference the correct count.

Actually, looking at the current file: sections are 1. Project identity, 2. Project board, 3. Sizing buckets, 4. Wiki settings, 5. Labels, 6. Approval gates. The new section becomes 7. Subagent permissions.

- [ ] **Step 3: Add `.wiki/` gitignore to wiki remediation**

In Step 6 (Remediate), under "Model can execute directly:", add:

```markdown
- Missing .wiki/ in .gitignore → append `.wiki/` (or configured `wiki.directory` value) to `.gitignore`
```

- [ ] **Step 4: Add permission remediation to Step 6**

In Step 6 (Remediate), under "Model can execute directly:", add:

```markdown
- Missing subagent permissions → read `.claude/settings.json`, merge required Bash permissions into `permissions.allow`, write back
```

- [ ] **Step 5: Commit**

```bash
git add skills/setup/SKILL.md
git commit -m "feat(setup): add subagent permissions wizard section

New section 7 auto-detects project stack and proposes Bash
permissions for .claude/settings.json. Also adds .wiki/ gitignore
and permission remediation to the preflight fix steps."
```

---

### Task 5: Update dispatch SKILL.md — worktree creation and dry-run

**Files:**
- Modify: `skills/dispatch/SKILL.md:129-189` (Step 5a through Step 6), and `skills/dispatch/SKILL.md:236-284` (Worktree Lifecycle and Important Rules)

This is the largest task. Three changes: (1) dispatch creates worktrees, (2) add dry-run mode, (3) update worktree lifecycle to use `repo_root`.

- [ ] **Step 1: Add repo_root resolution to Step 1**

After the config YAML block in Step 1 (line 58), add a paragraph:

```markdown
**Resolve `repo_root`:** Read the `repo_root` value from preflight JSONL output (emitted by `check-config.sh`). All subsequent `git worktree` and `git -C` commands use this absolute path. Do not use `git rev-parse --show-toplevel` — it can resolve to `.wiki/` if the session's CWD is inside the wiki clone.
```

- [ ] **Step 2: Rewrite Step 6 item 3 — dispatch creates worktrees**

Replace line 151 (Step 6 item 3):

Current:
```
3. **Worktree creation is delegated to the agent** — the implementer agent creates its own worktree via `superpowers:using-git-worktrees` in Phase 1. dispatch does NOT create the worktree or branch; it only provides the branch name and worktree path in the agent prompt.
```

New:
```
3. **Create the worktree** from `repo_root` — dispatch creates the worktree before spawning the agent. The agent receives a ready-to-use worktree and validates it (does not create it).
   ```bash
   git -C {repo_root} worktree add \
     {repo_root}/{worktree_dir}/{branch_prefix}/{issue_number}-{slug} \
     -b {branch_prefix}/{issue_number}-{slug} \
     {feature_branch}
   ```
   The worktree path passed to the agent is always an absolute path.
```

- [ ] **Step 3: Rewrite Step 6 item 10 — drop isolation: "worktree"**

Replace lines 182-187 (Step 6 item 10):

Current:
```
10. **Spawn the agent** using the Task tool:
    ```
    Task tool with subagent_type: "implementer"
    prompt: {filled implementer prompt}
    model: {from config, default opus}
    ```
```

New:
```
10. **Spawn the agent** using the Agent tool (no `isolation: "worktree"` — the worktree was already created in step 3):
    ```
    Agent tool with subagent_type: "buehler:implementer"
    prompt: {filled implementer prompt}
    model: {from config, default opus}
    ```
    Do NOT use `isolation: "worktree"` — this creates worktrees from the session's git context, which may be `.wiki/` after `buehler:structure`. Dispatch owns worktree creation.
```

- [ ] **Step 4: Add dry-run section between Step 5a and Step 6**

After Step 5a (Resolve Board Field IDs, line 140), add:

```markdown
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
```

- [ ] **Step 5: Update Worktree Lifecycle section to use `repo_root`**

In the "Worktree Lifecycle" section (starting line 236):

Replace line 238 ("Worktrees are created by the implementer agent (Phase 1)..."):
```
Worktrees are created by dispatch (Step 6 item 3) and need lifecycle management across dispatch, review, and integration.
```

Replace line 244 (`git worktree list | grep "{worktree_path}"`):
```bash
git -C {repo_root} worktree list | grep "{worktree_path}"
```

Update the table on line 249:
```
| No worktree exists | Normal path — dispatch creates it in Step 6 item 3 |
```

Replace line 250:
```
| Worktree exists, branch matches | Re-dispatch scenario (agent failed/blocked previously). Remove the stale worktree first: `git -C {repo_root} worktree remove {path} --force`, then dispatch normally |
```

Replace lines 270-273 (After Integration):
```bash
git -C {repo_root} worktree remove {path}  # for each completed worktree
git -C {repo_root} worktree prune
```

- [ ] **Step 6: Update Important Rules**

Replace line 281 ("Use the Task tool"):
```
5. **Use the Agent tool** — agents are spawned via `Agent` with `subagent_type: "buehler:implementer"`, NOT via bash. Do NOT use `isolation: "worktree"`.
```

- [ ] **Step 7: Commit**

```bash
git add skills/dispatch/SKILL.md
git commit -m "feat(dispatch): own worktree creation, add dry-run mode

Dispatch creates worktrees via git -C {repo_root} before spawning
agents. Removes isolation: worktree from Agent calls. Adds Step 5b
dry-run mode that validates the full pipeline without spawning.
All worktree lifecycle commands anchored to repo_root from preflight."
```

---

### Task 6: Update implementer prompt template

**Files:**
- Modify: `skills/dispatch/implementer-prompt.md:35-41` (Your Branch and Worktree section)
- Modify: `skills/dispatch/implementer-prompt.md:65-74` (Instructions section)

- [ ] **Step 1: Update the "Your Branch and Worktree" section**

Replace lines 35-41:

Current:
```markdown
## Your Branch and Worktree

- **Branch name:** {branch_prefix}/{issue_number}-{slug}
- **Branch from:** {feature_branch} (NOT main)
- **PR target:** {feature_branch} (NOT main)
- **Worktree path:** {worktree_dir}/{branch_prefix}/{issue_number}-{slug}
```

New:
```markdown
## Your Branch and Worktree

- **Branch name:** {branch_prefix}/{issue_number}-{slug}
- **Branch from:** {feature_branch} (NOT main)
- **PR target:** {feature_branch} (NOT main)
- **Worktree path:** {worktree_path} (PRE-CREATED absolute path — do not create, validate only)
```

- [ ] **Step 2: Update the Instructions section**

Replace lines 65-74:

Current:
```markdown
## Instructions

1. Read the `agents/implementer.md` agent definition in the buehler plugin for your full procedure
2. Follow the 9-phase execution procedure exactly
3. **Branch from and PR back to the FEATURE BRANCH**, not main
4. Use TDD — write failing tests first for each scenario
5. Report progress via GitHub Issue comments
6. Record token calibration in your lessons-learned comment
7. Return a structured YAML result when done

Begin.
```

New:
```markdown
## Instructions

1. Read the `agents/implementer.md` agent definition in the buehler plugin for your full procedure
2. Follow the 9-phase execution procedure exactly
3. **Your worktree is pre-created** at the path above — validate it, do not create a new one
4. **Branch from and PR back to the FEATURE BRANCH**, not main
5. Use TDD — write failing tests first for each scenario
6. Report progress via GitHub Issue comments
7. Record token calibration in your lessons-learned comment
8. Return a structured YAML result when done

Begin.
```

- [ ] **Step 3: Commit**

```bash
git add skills/dispatch/implementer-prompt.md
git commit -m "feat(dispatch): update implementer prompt for pre-created worktrees

Worktree path is now an absolute pre-created path. Instructions
tell the agent to validate, not create. Adds instruction 3."
```

---

### Task 7: Update implementer agent definition

**Files:**
- Modify: `agents/implementer.md:1-6` (frontmatter)
- Modify: `agents/implementer.md:25-26` (Inputs — worktree path description)
- Modify: `agents/implementer.md:36-39` (Rule 1)
- Modify: `agents/implementer.md:75-79` (Phase 1)

- [ ] **Step 1: Add `permissionMode: dontAsk` to frontmatter**

Replace lines 1-6:

Current:
```yaml
---
name: implementer
description: |
  Use this agent to implement a single GitHub Issue in an isolated git worktree. Spawned by dispatch, never by humans directly. Each agent receives an issue number, branches from a feature branch (not main), reads the full context chain (wiki meta page, PRD, mustread issues, parent story, task), implements with TDD, creates a PR targeting the feature branch, records token calibration data, and reports structured results. Follows a 9-phase execution procedure. Examples: <example>Context: dispatch has identified issue #7 as ready for implementation. user: "Implement issue #7: Add user authentication middleware" assistant: "Spawning implementer agent for issue #7 in worktree .worktrees/buehler/7-add-auth-middleware, branching from feature/auth-v1.0" <commentary>dispatch spawns one implementer per ready issue, each in its own worktree branching from the feature branch.</commentary></example>
model: opus
---
```

New:
```yaml
---
name: implementer
description: |
  Use this agent to implement a single GitHub Issue in an isolated git worktree. Spawned by dispatch, never by humans directly. Each agent receives an issue number, branches from a feature branch (not main), reads the full context chain (wiki meta page, PRD, mustread issues, parent story, task), implements with TDD, creates a PR targeting the feature branch, records token calibration data, and reports structured results. Follows a 9-phase execution procedure. Examples: <example>Context: dispatch has identified issue #7 as ready for implementation. user: "Implement issue #7: Add user authentication middleware" assistant: "Spawning implementer agent for issue #7 in worktree .worktrees/buehler/7-add-auth-middleware, branching from feature/auth-v1.0" <commentary>dispatch spawns one implementer per ready issue, each in its own worktree branching from the feature branch.</commentary></example>
model: opus
permissionMode: dontAsk
---
```

- [ ] **Step 2: Update Inputs item 5 — worktree path is pre-created**

Replace line 26:

Current:
```
5. **Worktree path** (e.g., `.worktrees/buehler/7-add-auth-middleware`)
```

New:
```
5. **Worktree path** (pre-created absolute path, e.g., `/Users/dev/project/.worktrees/buehler/7-add-auth-middleware`)
```

- [ ] **Step 3: Rewrite Rule 1**

Replace lines 36-39:

Current:
```markdown
### Rule 1: Isolated Worktree, Branch from Feature Branch
- Invoke the `superpowers:using-git-worktrees` skill to create your worktree
- All work happens in your worktree — never touch the main working directory
- **Branch from the feature branch, NOT main** — your parent branch is the feature branch provided in your inputs
```

New:
```markdown
### Rule 1: Isolated Worktree, Branch from Feature Branch
- Your worktree is **pre-created by dispatch** at the path provided in your inputs
- Invoke the `superpowers:using-git-worktrees` skill to **validate** the worktree (correct branch, correct repo, clean state) — do NOT create a new one
- All work happens in your worktree — never touch the main working directory
- **Branch from the feature branch, NOT main** — your parent branch is the feature branch provided in your inputs
```

- [ ] **Step 4: Rewrite Phase 1**

Replace lines 75-79:

Current:
```markdown
### Phase 1: Setup
1. Create worktree at the specified path, branching from the **feature branch** (not main)
2. Navigate to worktree directory
3. Run the project's setup/install command if needed
4. Verify the test suite passes on the feature branch (clean baseline)
```

New:
```markdown
### Phase 1: Setup
1. Validate you're in the pre-created worktree at `{worktree_path}` — invoke `superpowers:using-git-worktrees` to verify the worktree (correct branch, correct repo, clean state). Do NOT create a new worktree.
2. Navigate to the worktree directory if not already there
3. Run the project's setup/install command if needed
4. Verify the test suite passes on the feature branch (clean baseline)
```

- [ ] **Step 5: Commit**

```bash
git add agents/implementer.md
git commit -m "feat(implementer): validate pre-created worktrees, add permissionMode

Phase 1 now validates the worktree dispatch created instead of
creating its own. permissionMode: dontAsk gives clean auto-deny
for unapproved Bash calls instead of silent hang. Rule 1 updated
to clarify using-git-worktrees is for validation, not creation."
```

---

### Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:17-24` (Plugin Structure — preflight scripts list)
- Modify: `CLAUDE.md:68-69` (Key Conventions — worktree ownership)

- [ ] **Step 1: Add `check-permissions.sh` to the directory tree**

In the Plugin Structure block, after `check-wiki.sh` line and before `check-project.sh`, add:

```
│       ├── check-permissions.sh      # Subagent Bash permissions in .claude/settings.json
```

- [ ] **Step 2: Update worktree convention**

Replace line 69:

Current:
```
8. **Each agent gets its own worktree** — branching from the feature branch, not main
```

New:
```
8. **Dispatch creates worktrees, agents validate** — worktrees branch from the feature branch, created by dispatch via `git -C {repo_root}`, validated by the implementer via `superpowers:using-git-worktrees`
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for worktree ownership and check-permissions.sh

Directory tree now includes check-permissions.sh. Convention 8
updated to reflect dispatch owning worktree creation."
```

---

### Task 9: Integration test — run preflight with all new checks

**Files:** None (verification only)

- [ ] **Step 1: Run the full preflight suite**

```bash
cd /Users/traviscorrigan/Documents/GitHub/buehler && bash scripts/preflight-checks/runner.sh
```

Since this is the plugin repo (no `.github/buehler.yaml`, no `.claude/settings.json`), we expect:
- `config.exists`: fail (no buehler.yaml — correct)
- No `repo_root` line (correct — config missing)
- `permissions.settings_exists`: fail (no settings.json — correct)
- All other checks may fail or be skipped

The goal is to verify no syntax errors and no crashes across all scripts.

- [ ] **Step 2: Run individual new/modified checks**

```bash
bash scripts/preflight-checks/check-permissions.sh
```

Expected: fail on missing settings file, clean JSONL output.

```bash
OWNER=corrigantj REPO=buehler bash scripts/preflight-checks/check-wiki.sh
```

Expected: wiki checks plus the new `wiki.gitignore` check (fail since no .gitignore in this repo with .wiki/ entry).

- [ ] **Step 3: Verify all scripts are executable**

```bash
ls -la scripts/preflight-checks/check-*.sh
```

Verify `check-permissions.sh` has execute bit. If not:
```bash
chmod +x scripts/preflight-checks/check-permissions.sh
```

- [ ] **Step 4: Final commit if any fixes needed**

Only if verification uncovered issues.
