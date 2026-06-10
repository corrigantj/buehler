# Retrospective Wiki Page Template

Used by `buehler:integrate` when creating retrospective pages in the GitHub Wiki
after a milestone is completed and merged. Replace `{placeholders}` with actual content.

---

# Retro: {Epic Name} v{Major}.{Minor}

## Milestone Summary

| Metric | Value |
|--------|-------|
| Milestone | [{epic}-v{Major}.{Minor}](../../milestone/{N}) |
| PRD | [PRD-{epic}-v{Major}](PRD-{epic}-v{Major}) |
| Started | {date} |
| Completed | {date} |
| Stories Completed | {count} |
| Tasks Completed | {count} |
| Bugs Filed | {count} |

## Lessons Learned

{Aggregated from ## Lessons Learned comments on individual task issues, posted by implementer agents and appended by review.}

### What Went Well

- {lesson}

### What Went Wrong

- {lesson}

### Surprises

- {unexpected finding}

### Patterns Discovered

- {reusable insight}

## Token Calibration

| Task | Issue | Estimated Size | Actual Tokens | Delta % |
|------|-------|----------------|---------------|---------|
| {task_title} | #{N} | size:{bucket} | ~{N}K | {+/-N%} |

### Calibration Recommendations

{Based on the data above, recommended adjustments to sizing buckets in buehler.yaml.}

| Bucket | Current Range | Proposed Range | Reason |
|--------|--------------|----------------|--------|
| size:{bucket} | {lower}-{upper} | {new_lower}-{new_upper} | {evidence} |

## Process Notes

### What Worked About the Process

- {process observation}

### What Needs Improvement

- {process observation}

## Action Items

- [ ] {action item for next milestone}
