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
| First-time setup / \"setup\" / fix drift | buehler:setup |
| New feature / project / \"plan this\" | superpowers:brainstorming then buehler:structure |
| \"Break this down\" / has a PRD | buehler:structure |
| \"Start working\" / \"Dispatch\" | buehler:dispatch |
| \"What's the status?\" | buehler:status |
| \"Review PRs\" / \"Check feedback\" | buehler:review |
| \"Merge\" / \"Ship it\" / \"Integrate\" | buehler:integrate |
| \"File a bug\" / \"Report issue\" / \"Investigate\" | buehler:issue |
| \"Fix issue #N\" | buehler:issue |
| \"Backlog\" / \"Remember this idea\" / \"Quick capture\" | buehler:issue (backlog mode) |

## Flow

setup -> brainstorming -> structure -> dispatch -> status -> review -> integrate
issue (can be invoked at any point in the lifecycle)

## Preflight

A hook runs preflight checks before structure, dispatch, review, and integrate (not setup or status).
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
