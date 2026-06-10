# PRD Wiki Page Template

Used by `buehler:structure` when creating versioned PRD pages in the GitHub Wiki.
Replace `{placeholders}` with actual content.

## PRD Lifecycle

| Status | Meaning | Agent Behavior |
|--------|---------|----------------|
| **Draft** | Actively being written/revised | Free to edit any section |
| **In Review** | Circulated for feedback | Only edit in response to review comments |
| **Active** | Being implemented against | Read-only for requirements; Changelog can be appended |
| **Approved** | Scope locked or milestone shipped | **Cannot be modified.** Create a new version instead. |
| **Superseded** | Replaced by newer major version | Read-only archival. Header links to successor. |

---

# PRD: {Epic Name} v{Major}

**Status:** Draft

## Table of Contents

## Background

{User research, business context, core issues motivating this work}

## Objectives

{Goals with measurable success metrics}

## Target Users

{Personas and their characteristics}

## Scope Matrix

| Capability | User Type A | User Type B | In/Out |
|------------|-------------|-------------|--------|

## Functional Requirements

{Each requirement maps to a product ticket (story). Reference issue numbers once created.}

## Non-Functional Requirements

{Performance, security, accessibility, scalability, compliance — include only sections that apply.}

## Dependencies & Risks

{External dependencies, risks with mitigations}

## Open Questions

{Unresolved items — consult CODEOWNERS for routing to appropriate owners}

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| v{Major}.0 | {date} | Initial |

## Traceability

| Artifact | Link |
|----------|------|
| Meta Page | [{Epic Name}]({Epic-Name}) |
| Milestone | [{epic}-v{Major}.{Minor}](../../milestone/{N}) |
| Product Tickets | #{issue_numbers} |
