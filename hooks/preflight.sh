#!/usr/bin/env bash
# preflight.sh — PreToolUse hook for Skill tool invocations
# Gates: structure, dispatch, review, integrate, issue
# Passes: setup, status, and all non-buehler skills

set -uo pipefail

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
" 2>/dev/null) || skill_name=""

# Pass through non-buehler skills and ungated buehler skills
case "$skill_name" in
  buehler:structure|buehler:dispatch|buehler:review|buehler:integrate|buehler:issue)
    # Gated — run preflight
    ;;
  *)
    # Not gated — allow without context
    echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
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
  # All checks passed — allow with JSONL as systemMessage
  escaped_output=$(echo "$preflight_output" | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
print(json.dumps(lines))
" 2>/dev/null) || escaped_output="\"preflight passed\""
  echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"},\"systemMessage\":${escaped_output}}"
else
  # Checks failed — deny with JSONL as systemMessage
  escaped_output=$(echo "$preflight_output" | python3 -c "
import sys, json
lines = sys.stdin.read().strip()
print(json.dumps(lines))
" 2>/dev/null) || escaped_output="\"preflight failed\""
  echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"},\"systemMessage\":${escaped_output}}"
fi

exit 0
