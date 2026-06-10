#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-.github/buehler.yaml}"

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

emit_value() {
  local check="$1" status="$2" message="$3" value="$4"
  jq -nc --arg c "$check" --arg s "$status" --arg m "$message" --arg v "$value" \
    '{check:$c, status:$s, message:$m, value:$v}'
}

# config.exists
if [ ! -f "$CONFIG_PATH" ]; then
  emit "repo_root" "fail" "Cannot resolve repo root — .github/buehler.yaml not found" \
    "Run buehler:setup to create .github/buehler.yaml"
  emit "config.exists" "fail" "Config file not found: ${CONFIG_PATH}" \
    "Run buehler:setup to create .github/buehler.yaml"
  exit 0
fi
emit "config.exists" "pass" "Config file found: ${CONFIG_PATH}"

# repo_root — resolve absolute path from config location
abs_config="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"
repo_root="$(dirname "$(dirname "$abs_config")")"
emit_value "repo_root" "pass" "Repo root resolved from buehler.yaml location" "$repo_root"

# config.yaml_valid
yaml_result="$(python3 - "$CONFIG_PATH" <<'PYEOF'
import sys
import yaml

path = sys.argv[1]
try:
    with open(path, 'r') as f:
        content = f.read()
    if not content.strip():
        print("empty")
        sys.exit(0)
    data = yaml.safe_load(content)
    if data is None:
        print("empty")
    elif not isinstance(data, dict):
        print("not_dict")
    else:
        import json
        print("valid:" + json.dumps(list(data.keys())))
except yaml.YAMLError as e:
    print("parse_error:" + str(e).replace('\n', ' '))
PYEOF
2>/dev/null || echo "python_unavailable")"

case "$yaml_result" in
  python_unavailable)
    emit "config.yaml_valid" "warn" "python3/PyYAML not available — skipping YAML validation"
    exit 0
    ;;
  empty)
    emit "config.yaml_valid" "warn" "Config file is empty: ${CONFIG_PATH}"
    exit 0
    ;;
  not_dict)
    emit "config.yaml_valid" "fail" "Config file does not contain a YAML mapping (dict) at top level"
    exit 0
    ;;
  parse_error:*)
    error_msg="${yaml_result#parse_error:}"
    emit "config.yaml_valid" "fail" "YAML parse error in ${CONFIG_PATH}: ${error_msg}"
    exit 0
    ;;
  valid:*)
    actual_keys_json="${yaml_result#valid:}"
    emit "config.yaml_valid" "pass" "Config file is valid YAML"
    ;;
  *)
    emit "config.yaml_valid" "warn" "Unexpected result from YAML validation: ${yaml_result}"
    exit 0
    ;;
esac

# config.unknown_key
while IFS= read -r key; do
  key="$(echo "$key" | tr -d '"[] ')"
  [ -z "$key" ] && continue
  found=0
  for valid_key in $VALID_KEYS; do
    if [ "$key" = "$valid_key" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    emit "config.unknown_key" "warn" "Unknown top-level key in config: '${key}'"
  fi
done < <(echo "$actual_keys_json" | python3 -c "import sys, json; keys = json.load(sys.stdin); [print(k) for k in keys]" 2>/dev/null || true)
