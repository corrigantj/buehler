#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"
OWNER="${OWNER:-}"
REPO="${REPO:-}"

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
# Query user first, then org. Separate assignments because gh api graphql
# exits 0 even on GraphQL errors (HTTP 200), so || chaining doesn't work.
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
" --jq '.data.user.projectV2.repositories.nodes[].name // empty' 2>/dev/null)
if [ -z "$linked_repos" ]; then
  linked_repos=$(gh api graphql -f query="
    query {
      organization(login: \"${OWNER}\") {
        projectV2(number: ${board_number}) {
          repositories(first: 50) {
            nodes { name }
          }
        }
      }
    }
  " --jq '.data.organization.projectV2.repositories.nodes[].name // empty' 2>/dev/null)
fi

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
