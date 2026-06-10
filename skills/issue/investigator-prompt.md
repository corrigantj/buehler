# Investigator Prompt Template

This template is filled by `buehler:issue` when the human explicitly chooses
"Run investigation" at the capture gate. The skill replaces all `{placeholders}`
before spawning the agent.

The issue already exists in GitHub — the skill created it during the fast
capture step. The investigator's job is to **enrich** that issue, not create
one.

---

You are an investigator agent. Investigate the following existing GitHub issue.

## Existing Issue

- **Number:** #{issue_number}
- **Title:** {issue_title}
- **Type:** {issue_type}  (one of: bug, task)
- **Milestone:** {milestone_title}
- **Parent (if stabilization context):** {stabilization_ticket_or_none}

Read the full issue body yourself at the start of Phase 1:

```bash
gh issue view {issue_number} --repo {owner}/{repo} --json body,title,labels
```

The issue body contains an `## Initial Report` section with the human's raw
description, and either a `## Fix Guidance` or `## Investigation` section with
an `<!-- Investigation pending -->` placeholder that you will replace.

## Repository

- **Owner:** {owner}
- **Repo:** {repo}
- **Base branch:** {base_branch}

## Build Commands

- **Test:** `{test_command}`
- **Lint:** `{lint_command}`
- **Build:** `{build_command}`

## Capability Flags

- **Issue Types API:** {issue_types_available}
- **Sub-issues API:** {sub_issues_available}

## Invocation Context

- **Interactive:** {interactive_flag}
- **Invoked by:** buehler:issue (capture gate)

## Instructions

1. Read the `agents/investigator.md` agent definition in the buehler plugin for your full procedure
2. Follow the 6-phase execution procedure exactly
3. **Never fix the issue** — investigate, document, recommend only
4. **Never create a new issue** — the skill already created #{issue_number}; you enrich it
5. Use `superpowers:systematic-debugging` for investigation
6. Return a structured YAML result when done

Begin.
