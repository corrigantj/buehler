#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:?OWNER env var required}"
: "${REPO:?REPO env var required}"

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

# Fetch existing labels once
existing_labels="$(gh label list --repo "${OWNER}/${REPO}" --limit 200 --json name --jq '.[].name' 2>/dev/null | sort || echo "")"

check_label() {
  local name="$1" color="$2" description="$3"
  if echo "$existing_labels" | grep -qxF "$name"; then
    emit "labels.${name}" "pass" "Label exists: ${name}"
  else
    emit "labels.${name}" "fail" "Label missing: ${name}" \
      "gh label create \"${name}\" --color \"${color}\" --description \"${description}\" --force --repo ${OWNER}/${REPO}"
  fi
}

# Priority labels
check_label "priority:critical" "b60205" "Must have -- blocks project"
check_label "priority:high"     "d93f0b" "Should have -- core functionality"
check_label "priority:medium"   "fbca04" "Nice to have -- enhances project"
check_label "priority:low"      "0e8a16" "Could defer -- not blocking"

# Meta labels
check_label "meta:ignore"   "006b75" "Exclude from PM tracking"
check_label "meta:mustread" "006b75" "Required reading for agents"

# Size labels
check_label "size:xs" "bfd4f2" "Trivial change, single file"
check_label "size:s"  "bfd4f2" "Small feature, few files"
check_label "size:m"  "bfd4f2" "Moderate feature, multiple files"
check_label "size:l"  "bfd4f2" "Large feature, significant scope"
check_label "size:xl" "bfd4f2" "Must be split -- too large for one agent session"

# Status labels
check_label "status:ready"       "0e8a16" "Ready for implementation"
check_label "status:in-progress" "fbca04" "Currently being implemented"
check_label "status:in-review"   "1d76db" "PR open, awaiting review"
check_label "status:blocked"     "d73a4a" "Blocked by dependency or issue"
check_label "status:done"        "333333" "Completed and merged"

# Type labels (only if Issue Types API is not available)
if [ "$ISSUE_TYPES_AVAILABLE" != "true" ]; then
  check_label "type:story" "cccccc" "Product story (user-facing feature)"
  check_label "type:task"  "cccccc" "Dev task (implementation sub-issue)"
  check_label "type:bug"   "cccccc" "Bug report or fix"
fi

# Backlog labels
check_label "backlog:now"    "ededed" "Deliver this sprint"
check_label "backlog:next"   "ededed" "Deliver next sprint"
check_label "backlog:later"  "ededed" "Planned but not yet scheduled"
check_label "backlog:icebox" "ededed" "Deprioritized indefinitely"

# Severity labels
check_label "severity:critical" "b60205" "Data loss, crash, or security vulnerability"
check_label "severity:major"    "d93f0b" "Broken feature, no workaround"
check_label "severity:minor"    "fbca04" "Broken feature, workaround exists"
check_label "severity:trivial"  "0e8a16" "Cosmetic or minor inconvenience"

# Custom labels from config
if [ -f "$CONFIG_PATH" ] && command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null; then
  custom_labels="$(python3 - "$CONFIG_PATH" <<'PYEOF'
import sys
import yaml
import json

path = sys.argv[1]
try:
    with open(path, 'r') as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        sys.exit(0)
    labels = data.get('labels', [])
    if not isinstance(labels, list):
        sys.exit(0)
    for label in labels:
        if isinstance(label, dict) and 'name' in label:
            print(json.dumps({
                'name': label.get('name', ''),
                'color': label.get('color', 'ededed').lstrip('#'),
                'description': label.get('description', '')
            }))
except Exception:
    pass
PYEOF
2>/dev/null || true)"

  if [ -n "$custom_labels" ]; then
    while IFS= read -r label_json; do
      [ -z "$label_json" ] && continue
      name="$(echo "$label_json" | jq -r '.name')"
      color="$(echo "$label_json" | jq -r '.color')"
      description="$(echo "$label_json" | jq -r '.description')"
      check_label "$name" "$color" "$description"
    done <<< "$custom_labels"
  fi
fi
