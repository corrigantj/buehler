# Dispatch Agent Failures — Root Cause Fix

**Date:** 2026-03-17
**Status:** Design
**Scope:** buehler plugin — dispatch, setup, implementer, preflight

## Problem

Three failures occurred when `buehler:dispatch` spawned implementer agents in the wordplay project:

1. **Worktrees created in the wrong git repo.** `isolation: "worktree"` on the Agent tool creates worktrees from the session's git context. After `buehler:structure` cloned `.wiki/` (a separate git repo), the session context landed inside the wiki repo. Child worktrees were wiki worktrees, not project worktrees.

2. **Bash permission denied for subagents.** Subagents spawned via the Agent tool run non-interactively and cannot prompt for permission approval. With `defaultMode: "default"`, every Bash call was denied. Agents couldn't run `git`, `gh`, `npm`, or any shell command.

3. **Implementer agent appeared to not follow its 9-phase procedure.** Root cause was (1) and (2) — the agent followed the procedure but died at Phase 1 Step 1 when worktree creation failed. Not a separate bug.

## Root Cause: The `.wiki/` Landmine

`.wiki/` is a full git clone with its own `.git` directory, nested inside the project repo. Any tool that walks up the directory tree to find the git root (`git rev-parse --show-toplevel`, `isolation: "worktree"`, `EnterWorktree`) can land in the wiki repo instead of the main repo depending on CWD. This is a landmine for any skill that runs after `buehler:structure`.

## Design

### 1. Repo Root Resolution via Preflight

**Principle:** The repo root is deterministic — it's wherever `.github/buehler.yaml` lives. Resolve it once in a preflight script, emit the value, let skills consume it.

**Change to `check-config.sh`:** After validating the YAML, emit a `repo_root` value:

```json
{"check":"repo_root","status":"pass","value":"/absolute/path/to/project","message":"Repo root resolved from buehler.yaml location"}
```

Resolution logic: convert `CONFIG_PATH` to an absolute path (via `realpath` or `cd "$(dirname "$CONFIG_PATH")" && pwd`), then go up one level from `.github/`. This is necessary because `check-config.sh` receives `CONFIG_PATH` as a relative path (default `.github/buehler.yaml`). The emitted `value` must be an absolute path — no reliance on `git rev-parse` or CWD.

On failure (config not found):

```json
{"check":"repo_root","status":"fail","message":"Cannot resolve repo root — .github/buehler.yaml not found","fix":"Run buehler:setup to create configuration"}
```

**Consumers:** dispatch, review, integrate — any skill that needs `repo_root` reads it from preflight JSONL output instead of resolving it independently.

### 2. Dispatch Owns Worktree Creation

**Current behavior:** The dispatch SKILL.md instructs spawning agents via "the Task tool with `subagent_type: "implementer"`". At runtime, the coordinator used the Agent tool with `isolation: "worktree"`, which creates worktrees from the session's git context. Separately, the implementer agent definition (Phase 1) instructs the agent to create its own worktree via `superpowers:using-git-worktrees`. These two redundant worktree creation mechanisms were both broken by the `.wiki/` context.

**New behavior:** Dispatch creates the worktree explicitly before spawning each agent. The Agent tool is used **without** `isolation: "worktree"`.

For each issue in the batch, dispatch:

1. Reads `repo_root` from preflight JSONL output
2. Runs the existing worktree existence check using `git -C {repo_root} worktree list`
3. Creates the worktree:
   ```bash
   git -C {repo_root} worktree add \
     {repo_root}/{worktree_dir}/{branch_prefix}/{issue_number}-{slug} \
     -b {branch_prefix}/{issue_number}-{slug} \
     {feature_branch}
   ```
4. Spawns the agent **without** `isolation: "worktree"` — plain Agent tool call with the worktree's absolute path in the prompt

**Changes to dispatch SKILL.md:**
- Step 6 item 3: "Worktree creation is delegated to the agent" becomes "Dispatch creates the worktree from `repo_root`"
- Step 6 item 10: drops `isolation: "worktree"` from the Agent call
- All `git worktree` commands in the Worktree Lifecycle section use `git -C {repo_root}` prefix

**Unchanged:** Worktree Lifecycle section logic (existence check, failure handling, re-dispatch, cleanup), board status updates, batch selection, dependency graph, approval gate.

### 3. Implementer Phase 1: Validate, Don't Create

**Current Phase 1:** Create worktree via `superpowers:using-git-worktrees`, navigate to it, run setup, verify baseline.

**New Phase 1:**
1. Verify you're in the pre-created worktree at `{worktree_path}` — invoke `superpowers:using-git-worktrees` to validate the worktree (correct branch, correct repo, clean state)
2. Run setup/install command if needed
3. Verify test suite passes on feature branch (clean baseline)

The `using-git-worktrees` skill is retained for its validation and safety checks. It detects the pre-created worktree and validates rather than creating.

**Frontmatter change:**
```yaml
---
name: implementer
description: ...
model: opus
permissionMode: dontAsk
---
```

`permissionMode: dontAsk` gives a clean auto-deny with feedback for unapproved Bash calls instead of a silent hang.

**Phases 2-9 unchanged.** TDD workflow, context chain, board updates, lessons learned — all stay as-is.

### 4. Implementer Prompt Template Update

**Change to `implementer-prompt.md`:** The "Your Branch and Worktree" section updates to tell the agent the worktree is pre-created:

```markdown
## Your Branch and Worktree

- **Branch name:** {branch_prefix}/{issue_number}-{slug}
- **Branch from:** {feature_branch} (NOT main)
- **PR target:** {feature_branch} (NOT main)
- **Worktree path:** {worktree_path} (PRE-CREATED absolute path — do not create, validate only)
```

The Instructions section removes "create your worktree" and replaces with "validate your pre-created worktree."

### 5. Setup Wizard: Subagent Permissions

**New wizard section** (section 5, after approval gates):

Setup auto-detects the project's stack (same detection logic used for build commands) and proposes a Bash allowlist:

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

After confirmation, setup writes (or merges into) `.claude/settings.json` in the project root.

### 6. Preflight: Permission Verification

**New script: `check-permissions.sh`**

Verifies `.claude/settings.json` exists and its `permissions.allow` array contains minimum Bash permission glob patterns for subagents (at minimum `Bash(git:*)` and `Bash(gh:*)`).

```json
{"check":"subagent_permissions","status":"pass","message":"Bash permissions configured for subagents"}
```

On failure:

```json
{"check":"subagent_permissions","status":"fail","message":"Missing Bash permissions for subagents — agents cannot run shell commands","fix":"Run buehler:setup to configure subagent permissions"}
```

**Runner change:** Add `check-permissions.sh` to the run list in `runner.sh`.

### 7. Wiki `.gitignore` Entry

**Change to `check-wiki.sh`:** New check verifying `.wiki/` is in `.gitignore`.

```json
{"check":"wiki.gitignore","status":"pass","message":".wiki/ is in .gitignore"}
```

On failure:

```json
{"check":"wiki.gitignore","status":"fail","message":".wiki/ not in .gitignore — wiki clone could be accidentally committed","fix":"Add .wiki/ to .gitignore"}
```

**Remediation in setup:** After wiki clone during setup, add `.wiki/` to `.gitignore` if not already present. Idempotent.

### 8. Dispatch Dry-Run Mode

**Trigger:** User runs `/dispatch --dry-run` or dispatch skill prompt includes a dry-run argument.

**Behavior:** Runs Steps 1-5 of dispatch normally (read config, fetch issues, build DAG, identify batch, approval gate). Then instead of spawning agents:

1. Creates the worktree for each issue (validates git plumbing works from `repo_root`)
2. Fills the implementer prompt template for each issue
3. Prints each filled prompt
4. Removes the worktrees it just created (via `git -C {repo_root} worktree remove {path}`)
5. Reports:

```markdown
## Dry Run Complete

**Would dispatch:** {count} agents
**Worktree creation:** {PASS/FAIL for each}
**Bash permissions:** {PASS/FAIL}

| # | Title | Branch | Worktree Path | Prompt Length |
|---|-------|--------|---------------|--------------|
| {n} | {title} | {branch} | {path} | ~{tokens} |

Filled prompts printed above.
No agents were spawned. Run dispatch without --dry-run to execute.
```

**Change to dispatch SKILL.md:** New section between Step 5 (Approval Gate) and Step 6 (Dispatch Agents) that checks for dry-run mode and short-circuits.

Dry-run creates actual worktrees to validate the exact operation that failed in production. If worktree creation fails in dry-run, it fails with the same error the real dispatch would hit.

## Files Changed

| File | Change |
|------|--------|
| `scripts/preflight-checks/check-config.sh` | Emit `repo_root` value resolved from `buehler.yaml` location |
| `scripts/preflight-checks/check-wiki.sh` | New check: `.wiki/` in `.gitignore` |
| `scripts/preflight-checks/check-permissions.sh` | **New file.** Verify `.claude/settings.json` has minimum Bash permissions |
| `scripts/preflight-checks/runner.sh` | Add `check-permissions.sh` to run list |
| `skills/setup/SKILL.md` | New wizard section 5 (subagent permissions); `.wiki/` to `.gitignore` during wiki remediation |
| `skills/dispatch/SKILL.md` | Dispatch creates worktrees via `git -C {repo_root}`; drop `isolation: "worktree"`; new dry-run section; all worktree lifecycle commands use `repo_root` |
| `skills/dispatch/implementer-prompt.md` | Worktree section says pre-created; remove create instruction |
| `agents/implementer.md` | Add `permissionMode: dontAsk` to frontmatter; Phase 1 becomes validate, not create |
| `CLAUDE.md` | Add `check-permissions.sh` to directory tree; note worktree ownership in Key Conventions |

## Not Changed

- `skills/structure/SKILL.md` — wiki clone behavior unchanged
- `skills/status/SKILL.md` — read-only dashboard, no worktree interaction
- `skills/review/SKILL.md` — uses worktrees but inherits `repo_root` from preflight (same pattern)
- `skills/integrate/SKILL.md` — same; worktree cleanup uses `repo_root`
- Hooks, plugin.json, templates (other than implementer-prompt.md)

## Key Decisions

1. **Dispatch owns worktree creation, implementer validates.** The agent receives a ready-to-use worktree. `superpowers:using-git-worktrees` is retained for validation/safety, not creation.
2. **Repo root resolved from `buehler.yaml` location.** No reliance on `git rev-parse --show-toplevel` which can land in `.wiki/`. Preflight emits the value; skills consume it.
3. **Permissions configured during setup, verified during preflight.** Two-layer approach: setup writes `.claude/settings.json`, preflight verifies it's correct.
4. **`permissionMode: dontAsk` in implementer frontmatter.** Clean failure mode for unapproved commands.
5. **Dry-run creates actual worktrees.** Validates the exact operation that failed, not a simulation of it.
6. **`.wiki/` in `.gitignore`** added during setup after wiki clone. Prevents accidental commit of wiki clone into main repo.
