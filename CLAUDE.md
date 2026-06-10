# CLAUDE.md — buehler plugin

## What This Is

A Claude Code plugin that provides GitHub-native project management. It creates wiki PRDs and meta pages, structures versioned epics into GitHub Milestones with story/task sub-issue hierarchies, dispatches parallel implementation agents (each in its own git worktree branching from a feature branch), manages the PR review cycle with polling and lessons learned, and integrates completed work with retrospectives and token-based sizing calibration.

## Plugin Structure

```
buehler/
├── .claude-plugin/plugin.json     # Plugin metadata (v0.4.0)
├── hooks/                         # SessionStart + PreToolUse hooks
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse)
│   ├── session-start.sh           # Injects slim routing table on session start
│   ├── preflight.sh               # PreToolUse gate — runs preflight before gated skills
│   └── backlog-context.sh         # Injects backlog count into brainstorming sessions
├── scripts/
│   ├── create-stabilization-ticket.sh  # Idempotent stabilization ticket creation
│   └── preflight-checks/          # Deterministic bash checks, JSONL output
│       ├── runner.sh              # Orchestrator — runs all checks, aggregates output
│       ├── check-env.sh           # gh CLI, git repo, GitHub remote
│       ├── check-repo.sh          # Wiki, Issue Types API, Sub-issues API
│       ├── check-config.sh        # buehler.yaml existence and schema
│       ├── check-labels.sh        # Label taxonomy matches config
│       ├── check-wiki.sh          # Wiki clone, Home page, templates, .gitignore
│       ├── check-permissions.sh   # Subagent Bash permissions in .claude/settings.json
│       ├── check-project.sh      # Project board existence, linkage, Status field
│       ├── check-codeowners.sh   # CODEOWNERS file exists with valid rules
│       └── check-stabilization.sh  # Stabilization tickets exist for open milestones
├── skills/                        # 7 skills: setup, structure, dispatch, status, review, integrate, issue
│   ├── setup/                     # Setup wizard, preflight runner, drift remediation
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
│   ├── integrate/                 # Feature→main PR, retro, wiki update, calibration
│   │   └── retro-template.md
│   └── issue/                     # Ad-hoc issue creation, investigation, triage
│       └── investigator-prompt.md
├── agents/
│   ├── implementer.md             # Subordinate agent: 9-phase TDD workflow
│   └── investigator.md            # Subordinate agent: 10-phase investigation workflow
├── templates/buehler.yaml          # Configuration schema with sizing buckets
├── CLAUDE.md
├── LICENSE
└── README.md
```

## Skill Flow

```
buehler:setup → .github/buehler.yaml + GitHub artifacts (labels, wiki, project board)
→ brainstorming → PRD file (use superpowers:brainstorming)
→ buehler:structure → Wiki PRD + Meta page + Milestone + Issues + feature branch + add to board
→ buehler:dispatch → Spawn agents (task branches off feature branch)
→ buehler:status → Progress dashboard (run anytime, crash recovery)
→ buehler:review → Task PRs reviewed, merged into feature branch, lessons learned
→ buehler:integrate → Feature branch → main PR, retro, wiki update, close milestone
→ buehler:issue → Ad-hoc issue spike, investigation, triage (anytime)
```

## Key Conventions

1. **GitHub Issues + Wiki are the durable state machine** — all progress survives session crashes
2. **Two-wave PR model** — task PRs → feature branch (wave 1, review), feature → main (wave 2, integrate)
3. **Dependencies encoded as HTML comments** — `<!-- buehler:blocked-by #12, #15 -->` and `<!-- buehler:parent #10 -->`
4. **Label taxonomy** — `epic:`, `priority:`, `severity:`, `meta:`, `size:`, `status:`, `type:`, `backlog:` prefixes (`:` delimiter)
5. **Versioned epics** — lower-kebab-case naming: `{epic}-v{Major}.{Minor}`
6. **PRD lifecycle** — Draft → In Review → Active → Approved → Superseded
7. **Token-based sizing** — configurable buckets in `.github/buehler.yaml`, calibrated via retros
8. **Dispatch creates worktrees, agents validate** — worktrees branch from the feature branch, created by dispatch via `git -C {repo_root}`, validated by the implementer via `superpowers:using-git-worktrees`
9. **CODEOWNERS required by default** — `review.require_codeowners` defaults to `true`; PRs are never self-merged without human CODEOWNER approval
10. **Severity + Priority** — two-axis triage: `severity:` (impact on system) + `priority:` (urgency of fix)
11. **Stabilization tickets** — one per milestone, `type:task` + `meta:ignore`, created at milestone creation time

## Prerequisites

- **superpowers plugin** — provides brainstorming, TDD, debugging, worktree, and plan skills
- **GitHub MCP server** — for issue/PR/milestone management
- **gh CLI** — for labels, milestones, wiki, and operations not covered by MCP
- **Wiki enabled** on the GitHub repository

Run `buehler:setup` to verify all prerequisites and configure the repository.

## Skill Reference

| Skill | When to Use |
|-------|------------|
| `buehler:setup` | Setup, configuration, preflight checks, drift detection and remediation |
| `buehler:structure` | Convert a PRD into Wiki pages + Milestone + Issues + feature branch |
| `buehler:dispatch` | Spawn parallel implementer agents for ready issues |
| `buehler:status` | View progress dashboard from GitHub state |
| `buehler:review` | Poll task PRs for reviews, merge into feature branch, capture lessons learned |
| `buehler:integrate` | Merge feature branch to main, create retro, update wiki, calibrate sizing |
| `buehler:issue` | Ad-hoc issue creation, investigation, triage, fix execution, and backlog capture |
