# Meta Wiki Page Template

Used by `buehler:structure` when creating the canonical feature state page in the GitHub Wiki.
One per epic. Updated once per shipped version (~10 min maintenance).

Replace `{placeholders}` with actual content.

---

# {Epic Name}

## What This Feature Does Today

{2-3 paragraph narrative of what this feature is in production today.
For new features not yet shipped, describe the planned architecture.}

## Architecture Summary

| Aspect | Detail |
|--------|--------|
| Service/Provider | {primary service or module} |
| Key Patterns | {architectural patterns used} |
| Data Models | {main data structures} |
| Key Files | {important file paths} |
| API Endpoints | {relevant endpoints} |
| Config | {configuration files or env vars} |

## Scope Matrix

| Capability | Status |
|------------|--------|
| {capability} | In production / Planned / Out of scope |

## Version History

| Version | Milestone | PRD | Status | Date |
|---------|-----------|-----|--------|------|
| v{Major}.{Minor} | [{epic}-v{Major}.{Minor}](../../milestone/{N}) | [PRD-{epic}-v{Major}](PRD-{epic}-v{Major}) | {Shipped / In Progress / Planned} | {date} |

## Key Decisions Log

| Decision | Rationale | ADR | Date |
|----------|-----------|-----|------|

## Dependencies on Other Epics

| Epic | Nature | Issues |
|------|--------|--------|

## Known Limitations & Tech Debt

- {limitation or tech debt item}
