# buehler:init Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a setup/config skill (`buehler:init`), modular preflight check scripts, and a PreToolUse hook that gates downstream skills — replacing `using-buehler` entirely.

**Architecture:** Deterministic bash scripts under `scripts/preflight-checks/` validate environment against `.github/buehler.yaml` config and output JSONL. A PreToolUse hook runs these before gated skills, injecting results as `additionalContext` or blocking with `deny`. The `buehler:init` skill provides a conversational wizard for config creation and model-driven remediation for drift.

**Tech Stack:** Bash (preflight scripts), Markdown (skill definitions), JSON (hooks config)

**Spec:** `docs/plans/2026-03-13-buehler-init-design.md`

---

## Chunk 1: Preflight Check Scripts

### Task 1: check-env.sh

**Files:**
- Create: `scripts/preflight-checks/check-env.sh`

- [ ] **Step 1: Create the script with JSONL output helpers**

```bash
#!/usr/bin/env bash
# check-env.sh — Validate local environment prerequisites
# Output: JSONL lines with check, status, message, fix fields

set -euo pipefail

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

# Check: gh CLI installed
if command -v gh &>/dev/null; then
  gh_version=$(gh --version | head -1 | awk '{print $3}')
  emit "env.gh_cli" "pass" "gh ${gh_version} found"
else
  emit "env.gh_cli" "fail" "gh CLI not found in PATH" "Install GitHub CLI: https://cli.github.com/"
  # Cannot proceed with auth check if gh missing
  exit 0
fi

# Check: gh authenticated
if gh auth status &>/dev/null; then
  gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
  emit "env.gh_auth" "pass" "Authenticated as ${gh_user}"
else
  emit "env.gh_auth" "fail" "gh CLI not authenticated" "Run: gh auth login"
fi

# Check: git repo
if git rev-parse --is-inside-work-tree &>/dev/null; then
  emit "env.git_repo" "pass" "Inside a git repository"
else
  emit "env.git_repo" "fail" "Not inside a git repository" "Run: git init"
  exit 0
fi

# Check: GitHub remote
remote_url=$(git remote get-url origin 2>/dev/null || echo "")
if echo "$remote_url" | grep -qE '(github\.com|github\.dev)'; then
  emit "env.github_remote" "pass" "GitHub remote found: ${remote_url}"
else
  emit "env.github_remote" "fail" "No GitHub remote found on origin" "Run: git remote add origin https://github.com/{owner}/{repo}.git"
fi

# Check: python3 + PyYAML (needed by check-config.sh and check-labels.sh)
if command -v python3 &>/dev/null; then
  if python3 -c "import yaml" &>/dev/null; then
    emit "env.python_yaml" "pass" "python3 with PyYAML available"
  else
    emit "env.python_yaml" "warn" "python3 found but PyYAML not installed — config and label checks will be degraded" "Run: pip3 install pyyaml"
  fi
else
  emit "env.python_yaml" "warn" "python3 not found — config and label checks will be degraded" "Install Python 3: https://www.python.org/downloads/"
fi
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/check-env.sh && scripts/preflight-checks/check-env.sh`
Expected: JSONL lines, one per check, all `pass` in a properly configured repo

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-env.sh
git commit -m "feat(preflight): add check-env.sh — validate gh CLI, auth, git repo, GitHub remote"
```

---

### Task 2: check-repo.sh

**Files:**
- Create: `scripts/preflight-checks/check-repo.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# check-repo.sh — Validate GitHub repository capabilities
# Requires: OWNER and REPO env vars (set by runner.sh)
# Output: JSONL

set -euo pipefail

OWNER="${OWNER:?OWNER env var required}"
REPO="${REPO:?REPO env var required}"

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

# Check: Wiki enabled
wiki_enabled=$(gh api "repos/${OWNER}/${REPO}" --jq '.has_wiki' 2>/dev/null || echo "false")
if [ "$wiki_enabled" = "true" ]; then
  emit "repo.wiki" "pass" "Wiki is enabled"
else
  emit "repo.wiki" "fail" "Wiki not enabled" "Enable in repo Settings > General > Features > Wiki"
fi

# Check: Issue Types API
if gh api "repos/${OWNER}/${REPO}/issue-types" --jq '.' &>/dev/null; then
  emit "repo.issue_types" "pass" "Issue Types API available"
else
  emit "repo.issue_types" "warn" "Issue Types API not available — will use type: labels instead"
fi

# Check: Sub-issues API
# Find any issue number to test against
test_issue=$(gh api "repos/${OWNER}/${REPO}/issues" --jq '.[0].number' 2>/dev/null || echo "")
if [ -z "$test_issue" ]; then
  emit "repo.sub_issues" "warn" "No issues exist yet — cannot test Sub-issues API"
else
  sub_status=$(gh api "repos/${OWNER}/${REPO}/issues/${test_issue}/sub_issues" --silent -i 2>&1 | head -1 | awk '{print $2}' || echo "422")
  if [ "$sub_status" = "200" ] || [ "$sub_status" = "404" ]; then
    emit "repo.sub_issues" "pass" "Sub-issues API available"
  else
    emit "repo.sub_issues" "warn" "Sub-issues API not available — will use HTML comment dependencies"
  fi
fi
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/check-repo.sh && OWNER=corrigantj REPO=buehler scripts/preflight-checks/check-repo.sh`
Expected: JSONL lines for wiki, issue_types, sub_issues

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-repo.sh
git commit -m "feat(preflight): add check-repo.sh — validate wiki, issue types, sub-issues API"
```

---

### Task 3: check-config.sh

**Files:**
- Create: `scripts/preflight-checks/check-config.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# check-config.sh — Validate .github/buehler.yaml existence and structure
# Accepts: CONFIG_PATH env var (defaults to .github/buehler.yaml)
# Output: JSONL

set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"

# Valid top-level keys from templates/buehler.yaml
VALID_KEYS="project agents branches worktrees approval_gates commands labels wiki epics validation review sizing"

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

# Check: config file exists
if [ ! -f "$CONFIG_PATH" ]; then
  emit "config.exists" "fail" "Config file not found: ${CONFIG_PATH}" "Run buehler:init to create .github/buehler.yaml"
  exit 0
fi

emit "config.exists" "pass" "Config file found: ${CONFIG_PATH}"

# Check: valid YAML syntax
# Use python (widely available) to parse YAML since bash has no native YAML parser
parse_result=$(python3 -c "
import yaml, sys, json
try:
    with open('${CONFIG_PATH}') as f:
        data = yaml.safe_load(f)
    if data is None:
        print('empty')
    elif not isinstance(data, dict):
        print('not_dict')
    else:
        print(json.dumps(list(data.keys())))
except yaml.YAMLError as e:
    print(f'error:{e}')
" 2>&1)

if [[ "$parse_result" == error:* ]]; then
  error_msg="${parse_result#error:}"
  emit "config.yaml_valid" "fail" "YAML parse error: ${error_msg}" "Fix syntax errors in ${CONFIG_PATH}"
  exit 0
fi

if [ "$parse_result" = "empty" ]; then
  emit "config.yaml_valid" "warn" "Config file is empty — defaults will apply"
  exit 0
fi

if [ "$parse_result" = "not_dict" ]; then
  emit "config.yaml_valid" "fail" "Config root must be a YAML mapping, not a scalar or list" "Check ${CONFIG_PATH} structure"
  exit 0
fi

emit "config.yaml_valid" "pass" "YAML syntax is valid"

# Check: no unknown top-level keys
actual_keys=$(echo "$parse_result" | python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)]" 2>/dev/null)
while IFS= read -r key; do
  if ! echo "$VALID_KEYS" | grep -qw "$key"; then
    emit "config.unknown_key" "warn" "Unknown top-level key: ${key}" "Valid keys: ${VALID_KEYS}"
  fi
done <<< "$actual_keys"
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/check-config.sh && scripts/preflight-checks/check-config.sh`
Expected: `config.exists` fail (no `.github/buehler.yaml` in the plugin repo itself), then exits

Run with a test file: `CONFIG_PATH=templates/buehler.yaml scripts/preflight-checks/check-config.sh`
Expected: exists pass, yaml_valid pass (templates/buehler.yaml is valid YAML)

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-config.sh
git commit -m "feat(preflight): add check-config.sh — validate buehler.yaml existence and schema"
```

---

### Task 4: check-labels.sh

**Files:**
- Create: `scripts/preflight-checks/check-labels.sh`

- [ ] **Step 1: Create the script**

This is the most complex check. It needs to:
1. Fetch existing labels from the repo
2. Build the expected label set from the taxonomy + config
3. Compare and report missing labels with exact `gh label create` commands

```bash
#!/usr/bin/env bash
# check-labels.sh — Validate label taxonomy matches config
# Requires: OWNER, REPO env vars
# Optional: CONFIG_PATH env var, ISSUE_TYPES_AVAILABLE env var ("true"/"false")
# Output: JSONL

set -euo pipefail

OWNER="${OWNER:?OWNER env var required}"
REPO="${REPO:?REPO env var required}"
CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"
ISSUE_TYPES_AVAILABLE="${ISSUE_TYPES_AVAILABLE:-false}"

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

# Fetch existing labels
existing_labels=$(gh label list --repo "${OWNER}/${REPO}" --limit 200 --json name --jq '.[].name' 2>/dev/null | sort)

check_label() {
  local name="$1" color="$2" description="$3"
  if echo "$existing_labels" | grep -qxF "$name"; then
    emit "labels.present" "pass" "Label exists: ${name}"
  else
    emit "labels.missing" "fail" "Missing label: ${name}" "gh label create \"${name}\" --color \"${color}\" --description \"${description}\" --force --repo ${OWNER}/${REPO}"
  fi
}

# Priority labels
check_label "priority:critical" "b60205" "Must have -- blocks project"
check_label "priority:high" "d93f0b" "Should have -- core functionality"
check_label "priority:medium" "fbca04" "Nice to have -- enhances project"
check_label "priority:low" "0e8a16" "Could defer -- not blocking"

# Meta labels
check_label "meta:ignore" "006b75" "Exclude from PM tracking"
check_label "meta:mustread" "006b75" "Required reading for agents"

# Size labels
check_label "size:xs" "bfd4f2" "Trivial change, single file"
check_label "size:s" "bfd4f2" "Small feature, few files"
check_label "size:m" "bfd4f2" "Moderate feature, multiple files"
check_label "size:l" "bfd4f2" "Large feature, significant scope"
check_label "size:xl" "bfd4f2" "Must be split -- too large for one agent session"

# Status labels
check_label "status:ready" "0e8a16" "Ready for implementation"
check_label "status:in-progress" "fbca04" "Agent is working on this"
check_label "status:in-review" "1d76db" "PR created, awaiting review"
check_label "status:blocked" "d73a4a" "Blocked by dependency or question"
check_label "status:done" "333333" "Completed and merged"

# Type labels (only if Issue Types unavailable)
if [ "$ISSUE_TYPES_AVAILABLE" != "true" ]; then
  check_label "type:story" "cccccc" "Product story"
  check_label "type:task" "cccccc" "Dev task"
  check_label "type:bug" "cccccc" "Bug report"
fi

# Backlog labels
check_label "backlog:now" "ededed" "Current sprint"
check_label "backlog:next" "ededed" "Next sprint"
check_label "backlog:later" "ededed" "Future sprint"
check_label "backlog:icebox" "ededed" "Deprioritized"

# Custom labels from config
if [ -f "$CONFIG_PATH" ]; then
  custom_labels=$(python3 -c "
import yaml, json, sys
try:
    with open('${CONFIG_PATH}') as f:
        data = yaml.safe_load(f) or {}
    labels = data.get('labels', []) or []
    for label in labels:
        if isinstance(label, dict):
            print(json.dumps(label))
except Exception:
    pass
" 2>/dev/null)

  while IFS= read -r label_json; do
    [ -z "$label_json" ] && continue
    lname=$(echo "$label_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))")
    lcolor=$(echo "$label_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('color','ededed'))")
    ldesc=$(echo "$label_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('description',''))")
    [ -n "$lname" ] && check_label "$lname" "$lcolor" "$ldesc"
  done <<< "$custom_labels"
fi
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/check-labels.sh && OWNER=corrigantj REPO=buehler scripts/preflight-checks/check-labels.sh`
Expected: Mix of pass/fail depending on what labels exist in the repo

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-labels.sh
git commit -m "feat(preflight): add check-labels.sh — validate label taxonomy against config"
```

---

### Task 5: check-wiki.sh

**Files:**
- Create: `scripts/preflight-checks/check-wiki.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# check-wiki.sh — Validate wiki accessibility and baseline pages
# Requires: OWNER, REPO env vars
# Optional: WIKI_DIR env var (defaults to .wiki)
# Output: JSONL

set -euo pipefail

OWNER="${OWNER:?OWNER env var required}"
REPO="${REPO:?REPO env var required}"
WIKI_DIR="${WIKI_DIR:-.wiki}"

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

# Check: wiki cloneable
# Use a temp dir for the test clone, not the actual wiki dir
tmp_wiki=$(mktemp -d)
trap "rm -rf $tmp_wiki" EXIT

if git clone --depth 1 "https://github.com/${OWNER}/${REPO}.wiki.git" "$tmp_wiki/wiki" &>/dev/null; then
  emit "wiki.cloneable" "pass" "Wiki repo is cloneable"

  # Check: Home.md exists
  if [ -f "$tmp_wiki/wiki/Home.md" ]; then
    emit "wiki.home_page" "pass" "Home.md exists"
  else
    emit "wiki.home_page" "fail" "Home.md does not exist" "Create a Home.md wiki page via the GitHub wiki UI or buehler:init remediation"
  fi

  # Check: templates (warn only — created by structure on first epic)
  if [ -f "$tmp_wiki/wiki/_Meta-Template.md" ]; then
    emit "wiki.meta_template" "pass" "_Meta-Template.md exists"
  else
    emit "wiki.meta_template" "warn" "_Meta-Template.md does not exist yet — will be created by buehler:structure on first epic"
  fi

  if [ -f "$tmp_wiki/wiki/_PRD-Template.md" ]; then
    emit "wiki.prd_template" "pass" "_PRD-Template.md exists"
  else
    emit "wiki.prd_template" "warn" "_PRD-Template.md does not exist yet — will be created by buehler:structure on first epic"
  fi
else
  emit "wiki.cloneable" "fail" "Cannot clone wiki repo" "Enable wiki in repo Settings > General > Features > Wiki, then create at least one page"
fi
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/check-wiki.sh && OWNER=corrigantj REPO=buehler scripts/preflight-checks/check-wiki.sh`
Expected: JSONL lines — cloneable pass/fail, then page checks if cloneable

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/check-wiki.sh
git commit -m "feat(preflight): add check-wiki.sh — validate wiki clone, Home.md, templates"
```

---

### Task 6: runner.sh

**Files:**
- Create: `scripts/preflight-checks/runner.sh`

- [ ] **Step 1: Create the orchestrator script**

```bash
#!/usr/bin/env bash
# runner.sh — Run all preflight checks and aggregate JSONL output
# Usage: runner.sh [--config PATH] [--check NAME]
# Exit: 0 if all pass (warnings ok), 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH=".github/buehler.yaml"
SINGLE_CHECK=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --check) SINGLE_CHECK="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect owner/repo from git remote
remote_url=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  export OWNER="${BASH_REMATCH[1]}"
  export REPO="${BASH_REMATCH[2]}"
else
  export OWNER=""
  export REPO=""
fi

export CONFIG_PATH

# Detect wiki directory from config (default .wiki)
if [ -f "$CONFIG_PATH" ] && command -v python3 &>/dev/null; then
  WIKI_DIR=$(python3 -c "
import yaml
try:
    with open('${CONFIG_PATH}') as f:
        data = yaml.safe_load(f) or {}
    print(data.get('wiki', {}).get('directory', '.wiki'))
except Exception:
    print('.wiki')
" 2>/dev/null)
else
  WIKI_DIR=".wiki"
fi
export WIKI_DIR

# Collect all output, track failures
all_output=""
has_fail=false

run_check() {
  local name="$1" script="$2"
  if [ -n "$SINGLE_CHECK" ] && [ "$SINGLE_CHECK" != "$name" ]; then
    return
  fi
  if [ ! -x "$script" ]; then
    return
  fi

  # Parse issue_types result from previous checks for check-labels
  if [ "$name" = "labels" ] && echo "$all_output" | grep -q '"repo.issue_types".*"pass"'; then
    export ISSUE_TYPES_AVAILABLE="true"
  else
    export ISSUE_TYPES_AVAILABLE="false"
  fi

  local output
  output=$("$script" 2>/dev/null) || true
  if [ -n "$output" ]; then
    all_output="${all_output}${output}"$'\n'
    echo "$output"
    if echo "$output" | grep -q '"status":"fail"'; then
      has_fail=true
    fi
  fi
}

# Run checks in order (env must come first — later checks depend on gh/git)
run_check "env" "${SCRIPT_DIR}/check-env.sh"

# If env checks failed on gh or git, skip downstream checks
if echo "$all_output" | grep -q '"env.gh_cli".*"fail"\|"env.git_repo".*"fail"'; then
  if $has_fail; then exit 1; else exit 0; fi
fi

run_check "repo" "${SCRIPT_DIR}/check-repo.sh"
run_check "config" "${SCRIPT_DIR}/check-config.sh"
run_check "labels" "${SCRIPT_DIR}/check-labels.sh"
run_check "wiki" "${SCRIPT_DIR}/check-wiki.sh"

if $has_fail; then exit 1; else exit 0; fi
```

- [ ] **Step 2: Make executable and test manually**

Run: `chmod +x scripts/preflight-checks/runner.sh && scripts/preflight-checks/runner.sh`
Expected: Aggregated JSONL from all checks. Exit code 1 if any failures (likely config.exists fail since no `.github/buehler.yaml` in plugin repo).

Run single check: `scripts/preflight-checks/runner.sh --check env`
Expected: Only env check output.

- [ ] **Step 3: Commit**

```bash
git add scripts/preflight-checks/runner.sh
git commit -m "feat(preflight): add runner.sh — orchestrate all checks, aggregate JSONL, exit codes"
```

---

## Chunk 2: Hook Updates

### Task 7: preflight.sh hook wrapper

**Files:**
- Create: `hooks/preflight.sh`

- [ ] **Step 1: Create the PreToolUse hook wrapper**

This script receives the Skill tool input on stdin, parses the skill name, and gates or passes through.

```bash
#!/usr/bin/env bash
# preflight.sh — PreToolUse hook for Skill tool invocations
# Gates: structure, dispatch, review, integrate
# Passes: init, status, and all non-buehler skills

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${PLUGIN_ROOT}/scripts/preflight-checks/runner.sh"

# Read tool input from stdin
input=$(cat)

# Extract skill name from the Skill tool input
# The input JSON has a "skill" field
skill_name=$(echo "$input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Handle both direct input and nested tool_input
    skill = data.get('skill', '') or data.get('tool_input', {}).get('skill', '')
    print(skill)
except Exception:
    print('')
" 2>/dev/null)

# Pass through non-buehler skills and ungated buehler skills
case "$skill_name" in
  buehler:structure|buehler:dispatch|buehler:review|buehler:integrate)
    # Gated — run preflight
    ;;
  *)
    # Not gated — allow without context
    echo '{"decision":"allow"}'
    exit 0
    ;;
esac

# Run preflight checks — capture exit code before || true
if preflight_output=$("$RUNNER" 2>/dev/null); then
  runner_exit=0
else
  runner_exit=$?
fi

if [ $runner_exit -eq 0 ]; then
  # All checks passed — allow with JSONL as additionalContext
  escaped_output=$(echo "$preflight_output" | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
print(json.dumps(lines))
" 2>/dev/null)
  echo "{\"decision\":\"allow\",\"additionalContext\":${escaped_output}}"
else
  # Checks failed — deny with JSONL as reason
  escaped_output=$(echo "$preflight_output" | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
print(json.dumps(lines))
" 2>/dev/null)
  echo "{\"decision\":\"deny\",\"permissionDecisionReason\":${escaped_output}}"
fi

exit 0
```

- [ ] **Step 2: Make executable and test manually**

Test with a gated skill:
```bash
chmod +x hooks/preflight.sh
echo '{"skill":"buehler:structure"}' | hooks/preflight.sh
```
Expected: JSON with `decision: deny` (since no `.github/buehler.yaml` exists) and JSONL in reason.

Test with an ungated skill:
```bash
echo '{"skill":"buehler:status"}' | hooks/preflight.sh
```
Expected: `{"decision":"allow"}`

- [ ] **Step 3: Commit**

```bash
git add hooks/preflight.sh
git commit -m "feat(hooks): add preflight.sh — PreToolUse gate for buehler skills"
```

---

### Task 8: Update hooks.json

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 1: Read current hooks.json**

Current content (verified from codebase):
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "async": false
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Add PreToolUse hook entry**

Replace the entire file with:
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "async": false
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/preflight.sh",
            "async": false
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(hooks): add PreToolUse hook entry for preflight gating"
```

---

### Task 9: Update session-start.sh

**Files:**
- Modify: `hooks/session-start.sh`

- [ ] **Step 1: Read current session-start.sh**

Currently reads the full `using-buehler/SKILL.md` content and injects it into context. Replace with a slim routing table.

- [ ] **Step 2: Replace the script**

```bash
#!/usr/bin/env bash
# SessionStart hook for buehler plugin
# Injects a slim routing table — replaces the old using-buehler skill injection

set -euo pipefail

# Escape string for JSON embedding
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

routing_table="<BUEHLER_PLUGIN>
You have project management capabilities via the buehler plugin.

## Skill Routing

| User Intent | Skill |
|---|---|
| First-time setup / \"init\" / fix drift | buehler:init |
| New feature / project / \"plan this\" | superpowers:brainstorming then buehler:structure |
| \"Break this down\" / has a PRD | buehler:structure |
| \"Start working\" / \"Dispatch\" | buehler:dispatch |
| \"What's the status?\" | buehler:status |
| \"Review PRs\" / \"Check feedback\" | buehler:review |
| \"Merge\" / \"Ship it\" / \"Integrate\" | buehler:integrate |

## Flow

init -> brainstorming -> structure -> dispatch -> status -> review -> integrate

## Preflight

A hook runs preflight checks before structure, dispatch, review, and integrate (not init or status).
If checks fail, read the JSONL report and remediate before proceeding.
</BUEHLER_PLUGIN>"

escaped=$(escape_for_json "$routing_table")

cat <<EOF
{
  "additional_context": "${escaped}",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped}"
  }
}
EOF

exit 0
```

- [ ] **Step 3: Test the hook**

Run: `hooks/session-start.sh`
Expected: JSON output with the routing table embedded in `additional_context`

- [ ] **Step 4: Commit**

```bash
git add hooks/session-start.sh
git commit -m "refactor(hooks): replace using-buehler injection with slim routing table"
```

---

## Chunk 3: Init Skill + Delete using-buehler

### Task 10: Create buehler:init skill

**Files:**
- Create: `skills/init/SKILL.md`

- [ ] **Step 1: Create the skill directory and SKILL.md**

```markdown
---
name: init
description: Set up buehler for a repository — interactive config wizard, preflight checks, drift detection, and model-driven remediation
---

# init — Setup, Configuration & Preflight

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

2. **Agent settings**
   ```yaml
   agents:
     max_parallel: 3
     model: opus
   ```

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
   - Ask: "Any custom labels to add?"

6. **Approval gates**
   ```yaml
   approval_gates:
     before_dispatch: false
     before_merge: false
     before_close_milestone: false
     before_wiki_update: false
   ```

Remaining config sections (`branches`, `worktrees`, `commands`, `epics`, `validation`, `review`) use sensible defaults and can be customized by editing `.github/buehler.yaml` directly after init completes.

After all sections are confirmed, write `.github/buehler.yaml` and proceed to Step 5.

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

**Needs human action:**
- Wiki not enabled → tell the user: "Wiki is not enabled. Enable it in repo Settings > General > Features > Wiki. Let me know when it's done and I'll re-check."
- gh CLI not authenticated → tell the user: "Run `gh auth login` and let me know when done."
- No GitHub remote → tell the user: "Add a GitHub remote: `git remote add origin https://github.com/{owner}/{repo}.git`"

After executing all model-fixable items and confirming human-fixable items, proceed to Step 7.

### Step 7: Converge

Re-run the preflight to confirm all checks now pass:
```bash
{PLUGIN_ROOT}/scripts/preflight-checks/runner.sh
```

- **All green:** "buehler is fully configured. You're ready to go."
- **Still has failures:** Report remaining issues. If they're human-fixable, wait. If model-fixable items failed, investigate and retry (max 3 attempts).

## Important Rules

1. **Never mutate in preflight scripts** — only the model remediates, reading the `fix` suggestions
2. **Idempotent** — running init multiple times is safe and expected
3. **Wizard is conversational** — one section at a time, confirm before moving on
4. **Config is the source of truth** — preflight checks desired state against config, not hardcoded values
5. **Labels use `:` delimiter** — never `/`
6. **All skill references** use `buehler:{skill}` format
```

- [ ] **Step 2: Commit**

```bash
git add skills/init/SKILL.md
git commit -m "feat(skills): add buehler:init — setup wizard, preflight runner, drift remediation"
```

---

### Task 11: Delete using-buehler skill

**Files:**
- Delete: `skills/using-buehler/SKILL.md`

- [ ] **Step 1: Remove the using-buehler skill directory**

```bash
rm -rf skills/using-buehler/
```

- [ ] **Step 2: Commit**

```bash
git add -A skills/using-buehler/
git commit -m "refactor: delete using-buehler skill — replaced by init + session-start routing table"
```

---

## Chunk 4: Modify Existing Components

### Task 12: Update structure skill — remove taxonomy label creation

**Files:**
- Modify: `skills/structure/SKILL.md`

- [ ] **Step 1: Read the current structure skill**

Read `skills/structure/SKILL.md` and identify:
- Checklist item 4 (line ~24): "Create labels and milestone — epic label, label taxonomy, milestone with PRD link (Steps 6-8)"
- Step 7 (lines ~149-186): full taxonomy label creation
- Steps 8-15 which need renumbering to 7-14

- [ ] **Step 2: Update checklist item 4**

Change:
```
4. **Create labels and milestone** — epic label, label taxonomy, milestone with PRD link (Steps 6-8)
```
To:
```
4. **Create epic label and milestone** — per-epic label, milestone with PRD link (Steps 6-7)
```

- [ ] **Step 3: Update Step 6 — keep only epic label creation**

Replace Step 6 content. Keep only:
```markdown
### Step 6: Create Epic Label

Create `epic:{epic}` with color `0052cc` (blue) if it doesn't already exist:
\`\`\`bash
gh label create "epic:{epic}" --color "0052cc" --description "Epic: {Epic Name}" --force
\`\`\`

Also create any custom labels from `buehler.yaml` that are specific to this epic.
```

- [ ] **Step 4: Delete Step 7 (taxonomy creation) entirely**

Remove the entire "Step 7: Create Label Taxonomy" section (lines ~149-186).

- [ ] **Step 5: Renumber Steps 8-15 → Steps 7-14**

- Step 8: Create Milestone → Step 7
- Step 9: Create Feature Branch → Step 8
- Step 10: Create Stories → Step 9
- Step 11: Create Dev Tasks → Step 10
- Step 12: Annotate Dependencies → Step 11
- Step 13: Post-Creation Validation → Step 12
- Step 14: Update PRD Status → Step 13
- Step 15: Present Summary → Step 14

Update all internal cross-references to match new numbering.

- [ ] **Step 6: Update checklist items to match new step numbers**

Update checklist items 5-7 to reference correct new step numbers:
```
5. **Create feature branch** — branch from base branch and push (Step 8)
6. **Create stories and tasks** — stories with BDD scenarios, dev tasks as sub-issues, dependency annotations (Steps 9-11)
7. **Validate and finalize** — post-creation validation, update PRD status to Active, present summary (Steps 12-14)
```

- [ ] **Step 7: Remove capability detection instructions**

If the structure skill has any inline capability detection logic (checking for Issue Types, Sub-issues API), replace with a note:
```
Read capability flags from the preflight JSONL injected as additionalContext by the PreToolUse hook:
- Issue Types: look for `"repo.issue_types"` with `"status":"pass"`
- Sub-issues API: look for `"repo.sub_issues"` with `"status":"pass"`
```

- [ ] **Step 8: Commit**

```bash
git add skills/structure/SKILL.md
git commit -m "refactor(structure): remove taxonomy label creation, read capabilities from preflight context"
```

---

### Task 13: Update review skill — hardcode merge strategy

**Files:**
- Modify: `skills/review/SKILL.md`

- [ ] **Step 1: Read and identify merge config references**

Lines to change in `skills/review/SKILL.md`:
- Line 96: `Merge using \`merge.task_strategy\` from config (default: \`rebase\`...)`
- Line 98: `gh pr merge {pr_number} --{task_strategy} --delete-branch`
- Line 100: `(respect \`merge.delete_branch\` config)`

- [ ] **Step 2: Replace merge config references with hardcoded values**

Replace Step 5, item 3:

From:
```markdown
3. Merge using `merge.task_strategy` from config (default: `rebase` — task PRs rebase into feature branch for clean history):
   ```bash
   gh pr merge {pr_number} --{task_strategy} --delete-branch
   ```
   (respect `merge.delete_branch` config)
```

To:
```markdown
3. Merge the task PR (task PRs always rebase into the feature branch for clean history):
   ```bash
   gh pr merge {pr_number} --rebase --delete-branch
   ```
```

- [ ] **Step 3: Commit**

```bash
git add skills/review/SKILL.md
git commit -m "refactor(review): hardcode rebase merge strategy, remove merge config references"
```

---

### Task 14: Update integrate skill — hardcode merge strategy

**Files:**
- Modify: `skills/integrate/SKILL.md`

- [ ] **Step 1: Read and identify merge config references**

Lines to change in `skills/integrate/SKILL.md`:
- Line 84: `**Strategy:** {squash|merge|rebase from config}`
- Line 158: `gh pr merge {pr_number} --{feature_strategy}`
- Line 161: `Where \`{feature_strategy}\` is \`squash\`, \`merge\`, or \`rebase\` from \`merge.feature_strategy\` in config (default: \`squash\`).`
- Line 163: `If \`merge.delete_branch\` is true, add \`--delete-branch\`.`

- [ ] **Step 2: Update Step 3 approval gate**

Change line 84 from:
```
**Strategy:** {squash|merge|rebase from config}
```
To:
```
**Strategy:** squash (feature branch squashed into single commit on base branch)
```

- [ ] **Step 3: Update Step 6c merge command**

Replace:
```markdown
#### 6c. Merge PR

Use the configured feature merge strategy:
```bash
gh pr merge {pr_number} --{feature_strategy}
```

Where `{feature_strategy}` is `squash`, `merge`, or `rebase` from `merge.feature_strategy` in config (default: `squash`).

If `merge.delete_branch` is true, add `--delete-branch`.
```

With:
```markdown
#### 6c. Merge PR

Squash-merge the feature branch into the base branch (collapses all task commits into a single commit):
```bash
gh pr merge {pr_number} --squash --delete-branch
```
```

- [ ] **Step 4: Commit**

```bash
git add skills/integrate/SKILL.md
git commit -m "refactor(integrate): hardcode squash merge strategy, remove merge config references"
```

---

### Task 15: Remove merge section from buehler.yaml template

**Files:**
- Modify: `templates/buehler.yaml`

- [ ] **Step 1: Read and identify the merge section**

Lines 38-47 in `templates/buehler.yaml`:
```yaml
# ─── Merge strategy ─────────────────────────────────────────────────────────
# Two-wave model uses separate strategies for task PRs and feature PRs.
# task_strategy: how task PRs merge into the feature branch (wave 1, review)
#   Default: rebase — task PRs always rebase into feature branch for clean history.
# feature_strategy: how the feature branch merges into the base branch (wave 2, integrate)
#   Default: squash — collapses the feature branch into a single commit on main.
merge:
  task_strategy: rebase    # squash | merge | rebase (wave 1: task → feature)
  feature_strategy: squash # squash | merge | rebase (wave 2: feature → main)
  delete_branch: true
```

- [ ] **Step 2: Remove the entire merge section**

Delete lines 38-47 (the merge section including its header comment).

- [ ] **Step 3: Commit**

```bash
git add templates/buehler.yaml
git commit -m "refactor(config): remove merge section — strategy is now hardcoded"
```

---

## Chunk 5: Documentation

### Task 16: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update Plugin Structure tree**

Add `scripts/preflight-checks/` and `skills/init/`, remove `skills/using-buehler/`.

Replace the Plugin Structure section with:
```
## Plugin Structure

\`\`\`
buehler/
├── .claude-plugin/plugin.json     # Plugin metadata (v0.2.0)
├── hooks/                         # SessionStart + PreToolUse hooks
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse)
│   ├── session-start.sh           # Injects slim routing table on session start
│   └── preflight.sh               # PreToolUse gate — runs preflight before gated skills
├── scripts/
│   └── preflight-checks/          # Deterministic bash checks, JSONL output
│       ├── runner.sh              # Orchestrator — runs all checks, aggregates output
│       ├── check-env.sh           # gh CLI, git repo, GitHub remote
│       ├── check-repo.sh          # Wiki, Issue Types API, Sub-issues API
│       ├── check-config.sh        # buehler.yaml existence and schema
│       ├── check-labels.sh        # Label taxonomy matches config
│       └── check-wiki.sh          # Wiki clone, Home page, templates
├── skills/                        # 6 skills: init, structure, dispatch, status, review, integrate
│   ├── init/                      # Setup wizard, preflight runner, drift remediation
│   ├── structure/                 # PRD → Wiki + Milestone + Issues + feature branch
│   │   ├── story-template.md
│   │   ├── task-template.md
│   │   ├── bug-template.md
│   │   ├── prd-template.md
│   │   ├── meta-template.md
│   │   ├── pr-body-template.md
│   │   └── gherkin-guide.md
│   ├── dispatch/                  # Spawn parallel agents on feature branch
│   ├── status/                    # Progress dashboard with sub-issue grouping
│   ├── review/                    # Task PR polling, merge to feature branch, lessons learned
│   │   └── polling-prompt.md
│   └── integrate/                 # Feature→main PR, retro, wiki update, calibration
│       └── retro-template.md
├── agents/implementer.md          # Subordinate agent: 9-phase TDD workflow
├── templates/buehler.yaml          # Configuration schema with sizing buckets
├── CLAUDE.md
├── LICENSE
└── README.md
\`\`\`
```

- [ ] **Step 2: Update Skill Flow**

Replace:
```
brainstorming → PRD file
→ buehler:structure → ...
```
With:
```
buehler:init → .github/buehler.yaml + GitHub artifacts (labels, wiki)
→ brainstorming → PRD file
→ buehler:structure → Wiki PRD + Meta page + Milestone + Issues + feature branch
→ buehler:dispatch → Spawn agents (task branches off feature branch)
→ buehler:status → Progress dashboard (run anytime, crash recovery)
→ buehler:review → Task PRs reviewed, merged into feature branch, lessons learned
→ buehler:integrate → Feature branch → main PR, retro, wiki update, close milestone
```

- [ ] **Step 3: Update Key Conventions**

Update label taxonomy line to:
```
4. **Label taxonomy** — `epic:`, `priority:`, `meta:`, `size:`, `status:`, `type:`, `backlog:` prefixes (`:` delimiter)
```

- [ ] **Step 4: Update Prerequisites**

Replace the Prerequisites section:
```
## Prerequisites

- **superpowers plugin** — provides brainstorming, TDD, debugging, worktree, and plan skills
- **GitHub MCP server** — for issue/PR/milestone management
- **gh CLI** — for labels, milestones, wiki, and operations not covered by MCP
- **Wiki enabled** on the GitHub repository

Run `buehler:init` to verify all prerequisites and configure the repository.
```

- [ ] **Step 5: Update Skill Reference table**

Replace `buehler:using-buehler` row with `buehler:init`:

| Skill | When to Use |
|-------|------------|
| `buehler:init` | Setup, configuration, preflight checks, drift detection and remediation |
| `buehler:structure` | Convert a PRD into Wiki pages + Milestone + Issues + feature branch |
| `buehler:dispatch` | Spawn parallel implementer agents for ready issues |
| `buehler:status` | View progress dashboard from GitHub state |
| `buehler:review` | Poll task PRs for reviews, merge into feature branch, capture lessons learned |
| `buehler:integrate` | Merge feature branch to main, create retro, update wiki, calibrate sizing |

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for init skill, preflight hooks, remove using-buehler references"
```

---

### Task 17: Update .claude-plugin/plugin.json description

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Verify if description needs updating**

Read `.claude-plugin/plugin.json`. If the description mentions `using-buehler` or omits `init`, update it.

- [ ] **Step 2: Update if needed**

The current description is fine — it describes capabilities, not specific skill names. No change needed unless `using-buehler` is mentioned.

- [ ] **Step 3: Commit (only if changed)**

```bash
git add .claude-plugin/plugin.json
git commit -m "docs: update plugin.json description"
```

---

### Task 18: Final verification

- [ ] **Step 1: Verify all files exist**

```bash
ls -la scripts/preflight-checks/
ls -la skills/init/SKILL.md
ls -la hooks/preflight.sh
```

- [ ] **Step 2: Verify using-buehler is deleted**

```bash
ls skills/using-buehler/ 2>&1 || echo "Correctly deleted"
```

- [ ] **Step 3: Run the full preflight suite**

```bash
scripts/preflight-checks/runner.sh
```
Expected: JSONL output. Failures for missing config and labels are expected in the plugin repo itself.

- [ ] **Step 4: Test the preflight hook**

```bash
echo '{"skill":"buehler:structure"}' | hooks/preflight.sh
echo '{"skill":"buehler:status"}' | hooks/preflight.sh
echo '{"skill":"superpowers:brainstorming"}' | hooks/preflight.sh
```
Expected: deny for structure, allow for status, allow for non-buehler skills.

- [ ] **Step 5: Verify no broken cross-references**

Search for any remaining references to `using-buehler` across the codebase:
```bash
grep -r "using-buehler" skills/ hooks/ CLAUDE.md templates/ agents/ 2>/dev/null || echo "No stale references"
```

Search for any remaining references to `merge.task_strategy` or `merge.feature_strategy`:
```bash
grep -r "merge\.\(task_strategy\|feature_strategy\|delete_branch\)" skills/ templates/ 2>/dev/null || echo "No stale merge config references"
```
