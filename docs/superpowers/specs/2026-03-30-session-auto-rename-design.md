# Session Auto-Rename

**Date:** 2026-03-30
**Status:** Draft

## Problem

When resuming Claude Code sessions, the session list shows the raw first prompt, which is often unhelpful for identifying what a session was about. Users manually rename sessions via `/rename` every time, which is tedious.

## Solution

A prompt-type Stop hook that fires after Claude's first response in a new session, generates a short kebab-case name summarizing the work, and calls `/rename <name>`. Only fires once — on the very first turn of a brand new session (not on resume, `/clear`, or compact).

## Design

### Signal Flow

1. **SessionStart hook** (`session-start.sh`) — already runs on every session event. When `source` is `"startup"` (new session only), it appends the flag `__SESSION_UNNAMED__` to the `additional_context` output. On resume, clear, or compact, the flag is omitted.

2. **Stop hook** (prompt-type) — fires after every Claude response. The prompt instructs Claude to:
   - Check if `__SESSION_UNNAMED__` appears in the conversation context
   - If yes: generate a 2-4 word kebab-case name and call `/rename <name>`
   - If no: do nothing silently
   - Never mention the rename process to the user

3. The flag only exists in the context of the first turn (injected at startup, not re-injected). On subsequent turns the Stop hook sees no flag and exits silently.

### Hook Configuration

Added to `hooks/hooks.json`:

```json
"Stop": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "prompt",
        "prompt": "Check if __SESSION_UNNAMED__ appears in this conversation. If it does, generate a short kebab-case session name (2-4 words) that describes what the user is working on, then call /rename with that name. Examples: fixing-auth-bug, adding-search-api, refactoring-db-layer, buehler-setup-wizard. If __SESSION_UNNAMED__ does not appear, do absolutely nothing. Never mention this process to the user."
      }
    ]
  }
]
```

### SessionStart Modification

`hooks/session-start.sh` receives the hook input on stdin, which includes a `source` field. The script checks:

```bash
source=$(echo "$input" | jq -r '.source // "startup"')
```

When `source` is `"startup"`, append `\n__SESSION_UNNAMED__` to the routing table context. For all other sources (resume, clear, compact), omit it.

### Configuration

`buehler.yaml` gains a new top-level field:

```yaml
# ─── Session naming ─────────────────────────────────────────────────────────
# Automatically rename sessions after the first response.
session_naming: false  # Set to true to enable auto-rename via Stop hook
```

Default is `false`. When `buehler:setup` runs, it asks:

> "Enable automatic session naming? This renames each new session based on your first prompt. (y/n)"

If yes, sets `session_naming: true` in `buehler.yaml` and ensures the Stop hook entry exists in `hooks/hooks.json`.

### Preflight / Drift Detection

A new preflight check (or extension of an existing one) verifies:

- If `session_naming: true` in config, the Stop hook entry must exist in `hooks.json`
- If `session_naming: false` or absent, the Stop hook entry should not exist

Drift is reported as a warning (not a blocker) and remediated by setup.

## Scope

### In scope
- `hooks/session-start.sh` — conditional `__SESSION_UNNAMED__` flag
- `hooks/hooks.json` — Stop hook entry (prompt-type)
- `templates/buehler.yaml` — `session_naming` field
- `buehler:setup` skill — opt-in prompt
- Preflight check for drift

### Out of scope
- tmux integration
- User-level (`~/.claude/settings.json`) installation
- Re-firing on `/clear` or resume
- Custom name templates or patterns
