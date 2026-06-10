#!/usr/bin/env bash
set -euo pipefail

: "${OWNER:?OWNER env var required}"
: "${REPO:?REPO env var required}"

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

# wiki.cloneable
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

wiki_url="https://github.com/${OWNER}/${REPO}.wiki.git"
if ! git clone --depth 1 "$wiki_url" "$tmp_dir/wiki" &>/dev/null 2>&1; then
  emit "wiki.cloneable" "fail" "Could not clone wiki from ${wiki_url}" \
    "Ensure wiki is enabled and has at least one page: repo Settings > General > Features > Wiki"
  exit 0
fi
emit "wiki.cloneable" "pass" "Wiki cloned successfully from ${wiki_url}"

cloned_wiki="$tmp_dir/wiki"

# wiki.home_page
if [ -f "${cloned_wiki}/Home.md" ]; then
  emit "wiki.home_page" "pass" "Home.md exists in wiki"
else
  emit "wiki.home_page" "fail" "Home.md not found in wiki" \
    "Create a Home page in the wiki at https://github.com/${OWNER}/${REPO}/wiki"
fi

# wiki.meta_template
if [ -f "${cloned_wiki}/_Meta-Template.md" ]; then
  emit "wiki.meta_template" "pass" "_Meta-Template.md exists in wiki"
else
  emit "wiki.meta_template" "warn" "_Meta-Template.md not found in wiki — will be created by buehler:structure on first epic"
fi

# wiki.prd_template
if [ -f "${cloned_wiki}/_PRD-Template.md" ]; then
  emit "wiki.prd_template" "pass" "_PRD-Template.md exists in wiki"
else
  emit "wiki.prd_template" "warn" "_PRD-Template.md not found in wiki — will be created by buehler:structure on first epic"
fi

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
