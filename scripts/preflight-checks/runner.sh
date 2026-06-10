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
run_check "project" "${SCRIPT_DIR}/check-project.sh"
run_check "permissions" "${SCRIPT_DIR}/check-permissions.sh"
run_check "codeowners" "${SCRIPT_DIR}/check-codeowners.sh"
run_check "stabilization" "${SCRIPT_DIR}/check-stabilization.sh"

if $has_fail; then exit 1; else exit 0; fi
