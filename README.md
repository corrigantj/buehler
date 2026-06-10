# buehler

**Your favorite AI product squad. All GitHub-native.  Built for Claude Code.**

* Create wiki PRDs with versioned epics
* Structure work into GitHub Milestones with BDD/TDD story/task sub-issue hierarchies
* Calibrate future work estimates with token-based ticket sizing (bye bye, story points!)
* Dispatch parallel implementation agents (each in its own git worktree branching from a feature branch)
* Manage the PR review cycle with a two-wave model (worktree → feature branch → main)
* Build organizational knowledge for your AI workforce with postmortem retrospectives.

## How It Works

buehler loads automatically when you start a Claude Code session. Just describe what you want to build — the plugin handles the rest:

1. **You describe a feature** — buehler routes to `superpowers:brainstorming`, which produces a PRD saved to the project wiki.
2. **Structure** — the PRD becomes a wiki page, a GitHub Milestone, story/task issues, and a feature branch
3. **Dispatch** — parallel agents spawn in isolated worktrees, implement with TDD, and create task PRs targeting the feature branch
4. **Review** — task PRs are polled for human review, feedback is addressed, approved PRs merge into the feature branch
5. **Integrate** — the feature branch merges to main, a retrospective wiki page is created, sizing estimates are calibrated, and the milestone closes

All state lives in GitHub Issues, PRs, and Wiki — session crashes are fully recoverable. Run `/status` or simply ask `What's the project status?` in a new Claude Code session to pick up where you left off.

## Setup

### 1. Install the superpowers plugin (required dependency)

buehler depends on [superpowers](https://github.com/obra/superpowers) for brainstorming, TDD, git worktrees, and systematic debugging. Install it first:

```
/plugin marketplace add obra/superpowers
/plugin install superpowers@obra-superpowers
```

### 2. Install buehler

```
/plugin marketplace add corrigantj/buehler
/plugin install buehler@corrigantj-buehler
```

### 3. Verify prerequisites

buehler needs these to be available in your environment:

- **GitHub MCP server** — configured in your Claude Code settings (for issue/PR/milestone management)
- **`gh` CLI** — authenticated (`gh auth status`)
- **A GitHub remote** — the repository you're working in must have a GitHub remote
- **Wiki enabled** — go to your repo's Settings > Features > Wiki and enable it

## Quick Start

### 1. Describe What You Want to Build

The `setup` skill is loaded automatically on session start. Just describe your project — it routes to `superpowers:brainstorming`, which produces a PRD saved to the project wiki. For example:

```
I want to build a user authentication system with Google OAuth
```

This kicks off `superpowers:brainstorming` to interactively research and explore requirements, then saves a PRD to `docs/plans/`.

### 2. Structure into Wiki + GitHub Issues

Once you have a PRD, `buehler:setup` routes to `buehler:structure` (or you can invoke it directly):

```
Structure this PRD into GitHub issues
```

This creates:
- A wiki PRD page and meta page
- A GitHub Milestone with a feature branch
- Story issues with task/bug sub-issues
- Gherkin acceptance criteria and dependency annotations
- Labels (`epic:`, `size:`, `status:`, `priority:`)

### 3. Dispatch Implementation Agents

```
/dispatch or "Start implementing"
```

This spawns parallel agents (default: 3), each:
- Working in its own git worktree
- Branching from the feature branch
- Following TDD (tests first from Gherkin scenarios)
- Creating a task PR targeting the feature branch

### 4. Check Progress

```
/status or "What's the project status?"
```

Dashboard shows: progress bar, sub-issue grouping by story, CI status, blockers, next actions.

### 5. Review and Merge Task PRs

```
/review or "Check on task PRs"
```

Polls task PRs for review status, merges approved PRs into the feature branch, and captures lessons learned for each completed task.

### 6. Integrate and Ship

```
/integrate or "Merge the feature branch"
```

Merges the feature branch to main, creates a retrospective wiki page, calibrates token-based sizing estimates versus actual tokens used to complete work, and closes the milestone.

## Architecture

### Two-Wave PR Model

Task PRs target the feature branch (wave 1, managed by `review`). Once all tasks are merged, the feature branch is merged to main (wave 2, managed by `integrate`). This isolates in-progress work from the main branch and enables parallel development without conflicts.

### Wiki Management

buehler maintains a project wiki with three page types:
- **PRD pages** — living design documents with a lifecycle: Draft, In Review, Active, Approved, Superseded
- **Meta pages** — index pages linking milestones, issues, and PRDs for an epic
- **Retro pages** — retrospective summaries created during integrate with sizing calibration data

### Versioned Epics

Epics use lower-kebab-case naming with semantic versioning: `{epic}-v{Major}.{Minor}`. This allows multiple versions of the same epic to coexist (e.g., `auth-system-v1.0` and `auth-system-v2.0`), with wiki pages and milestones scoped to each version.

### Token-Based Sizing

Issues are sized based on estimated token consumption, configured as buckets in `.github/buehler.yaml`. During `integrate`, actual token usage is compared against estimates, and the sizing calibration is updated in the retrospective wiki page. This feedback loop improves future estimates.

### Label Taxonomy

Labels use a `:` delimiter with standardized prefixes:
- `epic:` — associates issues with a versioned epic
- `priority:` — urgency (critical, high, medium, low)
- `meta:` — metadata labels (e.g., `meta:ignore`, `meta:mustread`)
- `size:` — token-based sizing (xs, s, m, l, xl)
- `status:` — workflow state (ready, in-progress, in-review, done, blocked)

### Sub-Issue Hierarchy

Work is organized as stories containing task and bug sub-issues. Stories represent product-level requirements with Gherkin acceptance criteria. Tasks and bugs are implementation-level work items linked to their parent story via `<!-- buehler:parent #N -->` comments.

## Skill Reference

| Skill | Purpose |
|-------|---------|
| `buehler:setup` | Setup, configuration, preflight checks, drift detection and remediation |
| `buehler:structure` | Convert PRD into Wiki pages + Milestone + Issues + feature branch |
| `buehler:dispatch` | Spawn parallel agents for ready issues |
| `buehler:status` | Live progress dashboard from GitHub state |
| `buehler:review` | Poll task PRs, merge into feature branch, capture lessons learned |
| `buehler:integrate` | Merge feature branch to main, create retro, calibrate sizing |

## Configuration

Create `.github/buehler.yaml` in your project repository:

```yaml
# buehler configuration
# All values shown are defaults and can be omitted if unchanged.

# Project identity (auto-detected from git remote if omitted)
project:
  owner: ""
  repo: ""
  base_branch: ""

# Agent execution
agents:
  max_parallel: 3    # Max concurrent agents
  model: opus        # Model for agents (opus | sonnet)

# Branch naming
branches:
  prefix: buehler     # Branches: buehler/{issue}-{slug}

# Worktree management
worktrees:
  directory: .worktrees

# Approval gates
approval_gates:
  before_dispatch: false
  before_merge: false
  before_close_milestone: false
  before_wiki_update: false

# Build commands (auto-detected if omitted)
commands:
  test: ""
  lint: ""
  build: ""

# Additional labels beyond the default taxonomy
labels: []

# Wiki management
wiki:
  directory: .wiki    # Wiki clone location relative to repo root
  auto_clone: true    # Automatically clone the wiki repo on first use
  meta_page: ""       # Path to wiki meta page (auto-derived from epic name if empty)
  prd: ""             # Path to PRD wiki page (auto-derived from epic name if empty)

# Epics
epics:
  naming: kebab-case  # kebab-case | snake_case | camelCase

# Validation
validation:
  enabled: true   # Run validation checks
  strict: false   # Treat warnings as errors

# Review polling
review:
  polling_interval: 60    # Seconds between review-state polls
  polling_timeout: 3600   # Max seconds before polling gives up (default: 1 hour)
  polling_model: haiku    # Model used for polling (haiku | sonnet)
  require_codeowners: false

# Token-based sizing
sizing:
  metric: tokens   # tokens | lines | files
  token_ranges:    # Flat lookup for agents (auto-derived from buckets if empty)
  buckets:
    xs:
      lower: 1000
      upper: 10000
      description: "Trivial change, single file"
    s:
      lower: 10000
      upper: 50000
      description: "Small feature, few files"
    m:
      lower: 50000
      upper: 200000
      description: "Moderate feature, multiple files"
    l:
      lower: 200000
      upper: 500000
      description: "Large feature, significant scope"
    xl:
      lower: 500000
      upper: null
      description: "Must be split — too large for one agent session"
```

All values have sensible defaults. The file is optional.

## Plugin Structure

```
buehler/
├── .claude-plugin/plugin.json     # Plugin metadata (v0.2.0)
├── hooks/                         # SessionStart + PreToolUse hooks
│   ├── hooks.json                 # Hook event definitions (SessionStart, PreToolUse)
│   ├── session-start.sh           # Injects slim routing table on session start
│   └── preflight.sh               # PreToolUse gate — runs preflight before gated skills
├── scripts/
│   └── preflight-checks/          # Deterministic bash checks, JSONL output
├── skills/                        # 6 skills: setup, structure, dispatch, status, review, integrate
│   ├── setup/                     # Setup wizard, preflight runner, drift remediation
│   ├── structure/                 # PRD → Wiki + Milestone + Issues + feature branch
│   │   ├── story-template.md      # Product story template
│   │   ├── task-template.md       # Dev task sub-issue template
│   │   ├── bug-template.md        # Bug sub-issue template
│   │   ├── prd-template.md        # Wiki PRD page template
│   │   ├── meta-template.md       # Wiki meta page template
│   │   ├── pr-body-template.md    # PR body template
│   │   └── gherkin-guide.md       # BDD scenario writing guide
│   ├── dispatch/                  # Spawn parallel agents on feature branch
│   ├── status/                    # Progress dashboard with sub-issue grouping
│   ├── review/                    # Task PR polling, merge to feature branch, lessons learned
│   │   └── polling-prompt.md      # Polling sub-agent prompt template
│   └── integrate/                 # Feature→main PR, retro, wiki update, calibration
│       └── retro-template.md      # Retrospective wiki page template
├── agents/implementer.md          # Subordinate agent: 9-phase TDD workflow
├── templates/buehler.yaml          # Configuration schema with sizing buckets
├── CLAUDE.md
├── LICENSE
└── README.md
```

## License

MIT
