# Session Auto-Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically rename new Claude Code sessions with a descriptive kebab-case name after the first response.

**Architecture:** The existing SessionStart hook conditionally injects a `__SESSION_UNNAMED__` flag on new sessions only. A prompt-type Stop hook detects this flag and calls `/rename <name>`. The feature is opt-in via `session_naming` in `buehler.yaml`, with drift detection in preflight.

**Tech Stack:** Bash (hooks), YAML (config), Claude Code hooks API (prompt-type Stop hook)

---

### Task 1: Add `__SESSION_UNNAMED__` flag to SessionStart hook

**Files:**
- Modify: `hooks/session-start.sh`

- [ ] **Step 1: Read stdin to extract source field**

Add input reading and source extraction near the top of `session-start.sh`, after `set -euo pipefail` and before the `escape_for_json` function:

```bash
# Read hook input to detect session source
input=$(cat)
source=$(echo "$input" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
```

- [ ] **Step 2: Conditionally append the flag to the routing table**

After the closing `</BUEHLER_PLUGIN>"` line that ends the `routing_table` variable, add:

```bash
# Append session-unnamed flag only on brand-new sessions
if [ "$source" = "startup" ]; then
  routing_table="${routing_table}
__SESSION_UNNAMED__"
fi
```

- [ ] **Step 3: Verify the script is valid bash**

Run: `bash -n hooks/session-start.sh`
Expected: No output (no syntax errors)

- [ ] **Step 4: Test the hook output with startup source**

Run: `echo '{"source":"startup"}' | bash hooks/session-start.sh | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['additional_context'])" | grep -c '__SESSION_UNNAMED__'`
Expected: `1`

- [ ] **Step 5: Test the hook output with resume source**

Run: `echo '{"source":"resume"}' | bash hooks/session-start.sh | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['additional_context'])" | grep -c '__SESSION_UNNAMED__'`
Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add hooks/session-start.sh
git commit -m "feat(hooks): inject __SESSION_UNNAMED__ flag on new sessions"
```

---

### Task 2: Add Stop hook entry to hooks.json

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 1: Add the Stop hook array to hooks.json**

Add a `"Stop"` key to the `"hooks"` object in `hooks/hooks.json`, after the existing `"PreToolUse"` entry:

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

- [ ] **Step 2: Validate JSON syntax**

Run: `python3 -m json.tool hooks/hooks.json > /dev/null`
Expected: No output (valid JSON)

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(hooks): add prompt-type Stop hook for session auto-rename"
```

---

### Task 3: Add `session_naming` to buehler.yaml template

**Files:**
- Modify: `templates/buehler.yaml`

- [ ] **Step 1: Add the session_naming field to the template**

Add the following block after the `# ─── Sizing ──────` section (at the end of the file):

```yaml
# ─── Session naming ─────────────────────────────────────────────────────────
# Automatically rename new Claude Code sessions with a descriptive name
# after the first response. Requires the Stop hook in hooks/hooks.json.
session_naming: false  # Set to true to enable auto-rename
```

- [ ] **Step 2: Commit**

```bash
git add templates/buehler.yaml
git commit -m "feat(config): add session_naming field to buehler.yaml template"
```

---

### Task 4: Add `session_naming` to the valid keys list in check-config.sh

**Files:**
- Modify: `scripts/preflight-checks/check-config.sh`

- [ ] **Step 1: Add session_naming to VALID_KEYS**

Change line 6 from:

```bash
VALID_KEYS="project agents branches worktrees approval_gates commands labels wiki epics validation review sizing"
```

to:

```bash
VALID_KEYS="project agents branches worktrees approval_gates commands labels wiki epics validation review sizing session_naming"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/preflight-checks/check-config.sh
git commit -m "feat(preflight): add session_naming to valid config keys"
```

---

### Task 5: Create preflight check for session naming drift

**Files:**
- Create: `scripts/preflight-checks/check-session-naming.sh`
- Modify: `scripts/preflight-checks/runner.sh`

- [ ] **Step 1: Create the preflight check script**

Create `scripts/preflight-checks/check-session-naming.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HOOKS_JSON="${PLUGIN_ROOT}/hooks/hooks.json"

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

# Read session_naming from config (default: false)
session_naming=$(python3 -c "
import yaml, sys
with open('$CONFIG_PATH') as f:
    data = yaml.safe_load(f) or {}
print(str(data.get('session_naming', False)).lower())
" 2>/dev/null || echo "false")

# Check if Stop hook exists in hooks.json
stop_hook_exists="false"
if [ -f "$HOOKS_JSON" ]; then
  stop_hook_exists=$(python3 -c "
import json, sys
with open('$HOOKS_JSON') as f:
    data = json.load(f)
hooks = data.get('hooks', {}).get('Stop', [])
for entry in hooks:
    for hook in entry.get('hooks', []):
        if hook.get('type') == 'prompt' and '__SESSION_UNNAMED__' in hook.get('prompt', ''):
            print('true')
            sys.exit(0)
print('false')
" 2>/dev/null || echo "false")
fi

# Compare config vs hook state
if [ "$session_naming" = "true" ] && [ "$stop_hook_exists" = "false" ]; then
  emit "session_naming.hook" "warn" \
    "session_naming is enabled in config but Stop hook is missing from hooks.json" \
    "Add the session auto-rename Stop hook entry to hooks/hooks.json"
elif [ "$session_naming" = "false" ] && [ "$stop_hook_exists" = "true" ]; then
  emit "session_naming.hook" "warn" \
    "Stop hook for session naming exists but session_naming is not enabled in config" \
    "Set session_naming: true in .github/buehler.yaml or remove the Stop hook from hooks/hooks.json"
elif [ "$session_naming" = "true" ] && [ "$stop_hook_exists" = "true" ]; then
  emit "session_naming.hook" "pass" "Session naming is enabled and Stop hook is configured"
else
  emit "session_naming.hook" "pass" "Session naming is disabled (default)"
fi
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/preflight-checks/check-session-naming.sh`

- [ ] **Step 3: Add check-session-naming.sh to runner.sh**

In `runner.sh`, find the list of check scripts that get executed. Add `check-session-naming.sh` to the list, following the same pattern as the other checks. Look for the section where individual check scripts are sourced or run, and add:

```bash
run_check "check-session-naming.sh"
```

(Use whatever invocation pattern the runner already uses for other checks.)

- [ ] **Step 4: Validate syntax**

Run: `bash -n scripts/preflight-checks/check-session-naming.sh`
Expected: No output (no syntax errors)

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight-checks/check-session-naming.sh scripts/preflight-checks/runner.sh
git commit -m "feat(preflight): add drift detection for session naming hook"
```

---

### Task 6: Update buehler:setup skill to offer session naming opt-in

**Files:**
- Modify: `skills/setup/SKILL.md`

- [ ] **Step 1: Add session naming as wizard Section 9**

After Section 8 (CODEOWNERS) and before the paragraph about remaining config sections, add:

```markdown
9. **Session naming** — buehler can automatically rename new sessions with a descriptive name after your first prompt.

   Ask: "Enable automatic session naming? This renames each new session based on your first prompt so you can identify sessions when resuming. (y/n)"

   - If yes: set `session_naming: true` in the generated config
   - If no: set `session_naming: false` (the default)

   This controls whether the Stop hook for session renaming is active. The hook is always present in `hooks/hooks.json` but only acts when the `__SESSION_UNNAMED__` flag is injected by `session-start.sh`, which only happens when `session_naming` is enabled in the config.
```

- [ ] **Step 2: Update the SessionStart hook to read config**

Wait — this reveals a design consideration. The `session-start.sh` hook needs to know whether `session_naming` is enabled in the config. Currently it doesn't read the config. We need it to check `.github/buehler.yaml` for the `session_naming` field before injecting the flag.

Update the flag injection logic in `session-start.sh` (from Task 1, Step 2) to also check the config:

```bash
# Append session-unnamed flag only on brand-new sessions with naming enabled
if [ "$source" = "startup" ]; then
  naming_enabled="false"
  if [ -f ".github/buehler.yaml" ]; then
    naming_enabled=$(python3 -c "
import yaml
with open('.github/buehler.yaml') as f:
    data = yaml.safe_load(f) or {}
print(str(data.get('session_naming', False)).lower())
" 2>/dev/null || echo "false")
  fi
  if [ "$naming_enabled" = "true" ]; then
    routing_table="${routing_table}
__SESSION_UNNAMED__"
  fi
fi
```

- [ ] **Step 3: Update the remediation section of the setup skill**

In Step 6 (Remediate) of the setup SKILL.md, add a bullet for session naming drift:

```markdown
- Session naming drift → if `session_naming: true` but hook missing, add the Stop hook entry to `hooks/hooks.json`; if hook present but config says `false`, remove the Stop hook entry
```

- [ ] **Step 4: Commit**

```bash
git add skills/setup/SKILL.md hooks/session-start.sh
git commit -m "feat(setup): add session naming opt-in to wizard and config-aware flag injection"
```

---

### Task 7: Update CLAUDE.md and plugin structure docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add session naming to Key Conventions**

Add a new convention entry after item 11 (Stabilization tickets):

```markdown
12. **Session auto-rename** — opt-in via `session_naming: true` in config; a prompt-type Stop hook renames new sessions after the first response
```

- [ ] **Step 2: Update the Plugin Structure tree**

In the `hooks/` section of the structure tree, add:
```
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse, Stop)
```

(Update the existing comment from `(SessionStart, PreToolUse)` to include `Stop`.)

In the `scripts/preflight-checks/` section, add:
```
│       ├── check-session-naming.sh  # Session naming config/hook drift
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add session auto-rename to CLAUDE.md conventions and structure"
```
