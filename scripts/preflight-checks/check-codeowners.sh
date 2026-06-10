#!/usr/bin/env bash
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

# Read require_codeowners from config (default: true)
require_codeowners="true"
if [ -f "${CONFIG_PATH:-}" ] && command -v python3 &>/dev/null; then
  require_codeowners=$(python3 -c "
import yaml
try:
    with open('${CONFIG_PATH}') as f:
        data = yaml.safe_load(f) or {}
    val = data.get('review', {}).get('require_codeowners', True)
    print(str(val).lower())
except Exception:
    print('true')
" 2>/dev/null)
fi

# If require_codeowners is false, skip with info
if [ "$require_codeowners" = "false" ]; then
  emit "codeowners.enabled" "warn" \
    "review.require_codeowners is false — PRs can be merged without CODEOWNERS approval. Set to true in .github/buehler.yaml for human review enforcement."
  exit 0
fi

# codeowners.file_exists — check standard locations
codeowners_path=""
for candidate in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS"; do
  if [ -f "$candidate" ]; then
    codeowners_path="$candidate"
    break
  fi
done

if [ -z "$codeowners_path" ]; then
  emit "codeowners.file_exists" "fail" \
    "No CODEOWNERS file found (checked CODEOWNERS, .github/CODEOWNERS, docs/CODEOWNERS) — review.require_codeowners is true but no owners are defined" \
    "Create a CODEOWNERS file (e.g., .github/CODEOWNERS) with at least one rule. Run buehler:setup to generate one interactively."
  exit 0
fi
emit "codeowners.file_exists" "pass" "CODEOWNERS file found: ${codeowners_path}"

# codeowners.has_rules — check the file has at least one non-comment, non-empty rule
rule_count=$(grep -cE '^[^#[:space:]]' "$codeowners_path" 2>/dev/null || echo "0")
if [ "$rule_count" -eq 0 ]; then
  emit "codeowners.has_rules" "fail" \
    "CODEOWNERS file exists but contains no ownership rules" \
    "Add at least one ownership rule to ${codeowners_path}, e.g.: * @${OWNER:-your-username}"
  exit 0
fi
emit "codeowners.has_rules" "pass" "CODEOWNERS has ${rule_count} ownership rule(s)"

# codeowners.owners_valid — verify referenced users/teams exist on GitHub
# Only check the first few owners to avoid rate limiting
owners=$(grep -oE '@[a-zA-Z0-9_/-]+' "$codeowners_path" 2>/dev/null | sort -u | head -5)
invalid_owners=""
for owner_ref in $owners; do
  # Strip the @ prefix
  name="${owner_ref#@}"

  # Check if it's a team reference (org/team-name)
  if [[ "$name" == */* ]]; then
    # Team reference — check team exists
    org="${name%%/*}"
    team="${name#*/}"
    if ! gh api "orgs/${org}/teams/${team}" --silent 2>/dev/null; then
      invalid_owners="${invalid_owners}${owner_ref}, "
    fi
  else
    # User reference — check user exists
    if ! gh api "users/${name}" --silent 2>/dev/null; then
      invalid_owners="${invalid_owners}${owner_ref}, "
    fi
  fi
done

if [ -n "$invalid_owners" ]; then
  invalid_owners="${invalid_owners%, }"
  emit "codeowners.owners_valid" "warn" \
    "Some CODEOWNERS references could not be verified: ${invalid_owners} — they may be private teams or the API rate-limited"
else
  emit "codeowners.owners_valid" "pass" "CODEOWNERS references are valid"
fi
