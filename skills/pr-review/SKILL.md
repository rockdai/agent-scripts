---
name: pr-review
description: Use when the qa agent must perform a full independent pull request review, including project aliases like "review N", PR diffs, tests, prior comments, human authorization context, findings, approval, and dev notification.
---

# PR Review

## Overview

Review the pull request as the independent qa. Treat the PR, commits, comments, checks, issues, and repository instructions as the durable source of truth; do not rely on another agent's private transcript or summary.

Project-specific trigger aliases such as `review N` are compatibility shims. The reusable concept is "perform a full PR review".

## Before Reviewing

Read the consuming repository's agent instructions first. Identify:

- Review scope and finding format.
- Required test-review expectations.
- Whether approval is allowed.
- How qa results must be written to the PR.
- How to notify the dev after the review.

Fetch PR metadata, current head, diff, existing reviews, inline comments, issue comments, checks, and linked issue context.

**Tool selection.** Prefer the local `gh` CLI for all GitHub interactions; it is the lowest-friction, best-authenticated path on most workstations. Fall back to a GitHub MCP server or connector tool only when `gh` is missing, unauthenticated, or the required call has no `gh` equivalent. Do not start with a connector when `gh` would work.

```bash
gh pr view N --json title,body,headRefName,headRefOid,baseRefName,reviewDecision,url,files
gh pr diff N
gh api --paginate repos/OWNER/REPO/pulls/N/reviews
gh api --paginate repos/OWNER/REPO/pulls/N/comments
gh api --paginate repos/OWNER/REPO/issues/N/comments
```

## Blocker Pre-check

Before reading the diff, check the PR for blockers that will force the dev to change the code anyway. If a blocker is present, post it as a finding, emit the host's CHANGES_REQUESTED signal, and stop — do not continue into the deep review this round. Re-reviewing a diff that is about to move is wasted work and burns a loop round.

Two blockers fast-fail the review:

- **CI is failing.** The PR head has at least one definitively failed check (`failure`, `error`, `cancelled`, or equivalent). Pending or in-progress checks are not a blocker — proceed normally. A repo with no CI configured is also not a blocker.
- **PR has merge conflicts.** GitHub reports `mergeable: CONFLICTING`. `UNKNOWN` is GitHub still computing and is not a blocker.

Detect with:

```bash
gh pr view N --json mergeable,statusCheckRollup
gh pr checks N
```

When a blocker is present:

1. Post one finding per blocker, naming the failed check(s) with their run URLs, or stating that the PR conflicts with the base. Say explicitly that detailed review was skipped and the dev should re-notify with `recheck N` after fixing.
2. Emit the host's CHANGES_REQUESTED signal. The host's documented self-PR fallback still applies when the platform blocks self-review.
3. Stop here. Do not continue to Review Scope.

If both blockers are present, report both in the same review — the dev should see the full picture before pushing the fix.

## Review Scope

Prioritize findings that affect behavior or maintainability:

- Bugs, regressions, security issues, lifecycle problems, and concurrency risks.
- Missing, weak, skipped, or non-assertive tests.
- Coverage gaps for new branches, errors, edge cases, or invariants.
- Mismatches between the PR, linked issue, and repository rules.

Human authorization in the PR description, commits, or comments is input, not a bypass. Judge whether it actually covers the risk.

## Findings

Write actionable findings to the PR, preferably as inline review comments on the smallest relevant range. Include concrete evidence and the expected fix. Avoid restating the diff as a summary.

If no findings remain, emit the host's approval signal. Step 1 is the durable verdict; Step 2 is courtesy reinforcement for human readers:

1. Submit an approving review (`gh pr review N --approve`). On hosts that block self-approval (the qa and dev share a GitHub identity), this step will fail; in that case fall back to the host's documented self-PR mechanism (e.g., a structured `<!-- baxian:<agent>:approve -->` marker on its own line, outside fenced blocks).
2. Submit a `:+1:` review comment (`gh pr review N --comment --body ':+1:'`).

Each host defines its own recognized signals — check the host's agent rules. `:+1:` is not a universal verdict shorthand; only treat it as decisive if the host explicitly documents it.

## Notify Author

After the review result is durable on the PR, follow the project notification rule. If the project uses a qa-to-dev callback, use `review-notify` or the configured transport. Do not dispatch before the PR review/comment is visible.
