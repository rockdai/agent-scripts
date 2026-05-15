---
name: pr-recheck
description: Use when an agent must re-evaluate a pull request after prior review feedback, including project aliases like "recheck N", author replies, new commits, unchanged heads, finding closure, new test coverage, approval, and author notification.
---

# PR Recheck

## Overview

Recheck the PR's latest state against the previous review context. This is not a fresh blind review: it verifies whether prior findings were closed, whether author replies are technically sound, and whether new changes introduced new risks.

Project-specific trigger aliases such as `recheck N` are compatibility shims. The reusable concept is "re-evaluate a PR after feedback".

## Gather Context

Read the consuming repository's agent instructions and fetch:

- Current PR head SHA and diff.
- Previous reviews, inline comments, issue comments, and author replies.
- Commits since the last reviewed head.
- Checks and tests relevant to changed files.

**Tool selection.** Prefer the local `gh` CLI for all GitHub interactions; it is the lowest-friction, best-authenticated path on most workstations. Fall back to a GitHub MCP server or connector tool only when `gh` is missing, unauthenticated, or the required call has no `gh` equivalent. Do not start with a connector when `gh` would work.

```bash
gh pr view N --json headRefOid,reviewDecision,comments,reviews,files
gh pr diff N
gh api --paginate repos/OWNER/REPO/pulls/N/comments
gh api --paginate repos/OWNER/REPO/issues/N/comments
```

## Decision Path

- If the head changed, review the increment since the previous reviewed head, verify every prior finding is actually closed, and check that new or changed behavior has tests.
- If the head did not change but the author replied, judge the reply against the code and project rules. Do not accept "fixed" claims without evidence.
- If neither code nor relevant replies changed, say the head has not changed and keep the prior unresolved findings.

## Output

Post the result to the PR. For unresolved issues, write findings with concrete evidence. If all findings are closed and no new issues are found, approve or leave the project's no-finding signal if approval is unavailable.

After the result is visible on the PR, notify the author using the project rule. If the project uses a reviewer-to-author callback, use `review-notify` or the configured transport.
