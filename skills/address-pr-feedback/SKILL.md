---
name: address-pr-feedback
description: Process pull request feedback end to end. Use when receiving a request such as "pr N", when a review agent notifies the author that a review or recheck is complete, or when an agent must fetch all PR reviews/comments, independently judge every finding, make fixes, reply Fixed or Won't fix, create follow-up issues for out-of-scope problems, and trigger any project-specific recheck notification.
---

# Address PR Feedback

## Overview

Treat the pull request as the only durable source of review feedback. Fetch every review, inline comment, and conversation comment; judge each actionable item independently; then either fix it, decline it with a reason, or move out-of-scope work into a tracked issue.

## Before You Start

Read the consuming repository's agent instructions first. In particular, find:

- Required PR feedback format.
- Required test and push rules.
- How to identify already-addressed comments.
- Whether out-of-scope feedback must become an issue.
- How to notify a review agent after replies or new commits.
- The transport skill or script used for notification, if any.

Do not rely on another agent's chat transcript or tmux pane output. If the feedback is not in the PR, ask that it be written there before treating it as official review input.

## Fetch Feedback

Use the best available provider tool for the project. For GitHub, collect all three surfaces:

```bash
gh api repos/OWNER/REPO/pulls/N/reviews
gh api repos/OWNER/REPO/pulls/N/comments
gh api repos/OWNER/REPO/issues/N/comments
```

Also fetch PR metadata and current head:

```bash
gh pr view N --json title,body,headRefName,headRefOid,baseRefName,reviewDecision,url
```

If a connector or MCP tool is available instead of `gh`, use the equivalent calls. The required result is the same: full PR metadata plus every review body, inline review comment, and top-level conversation comment.

## Classify Items

Build a working list of every actionable item. Include comments from humans, review agents, and review bots. For each item, record:

- Author and comment URL or ID.
- File and line, when available.
- Current status: unresolved, already fixed, invalid, duplicate, or out of scope.
- The evidence you used to decide.

Do not batch-dismiss findings because another reviewer said the same thing. Confirm each one against the code and tests.

## Decide and Act

For each actionable item:

1. If it is correct and in scope, fix it.

   Keep the change focused. Add or update tests for the behavior. Run the relevant local tests. Commit and push before claiming the fix is done.

2. If it is incorrect or not appropriate for this PR, reply with a reason.

   The first line must be:

   ```text
   Won't fix
   ```

   Then explain the concrete evidence. Do not use vague phrases such as "not needed" without backing.

3. If it is real but out of scope, create a follow-up issue first.

   Include enough context for a future agent to reproduce the concern, then reply to the review item with the issue link and why it is being split out.

4. If it is already fixed by current head, verify that in the code and tests before replying.

   The first line must be:

   ```text
   Fixed
   ```

   Include the commit SHA when a code change was pushed for that item.

## Reply Rules

Reply to every actionable item. Do not silently ignore duplicates; say they are duplicates and link or reference the primary response.

Use the review platform's threaded reply for inline review comments when possible. Use a top-level PR comment only when the platform has no threaded reply surface for that item.

Never announce "fixed", "done", or "complete" before code changes are committed and pushed to the PR branch.

## Recheck Notification

After all replies and commits are visible on the PR, follow the consuming repository's notification rule. Common patterns include:

- Dispatching `recheck N` to a review agent.
- Requesting another review from a human or bot.
- Leaving the PR ready for manual merge.

If the project uses tmux for agent notification, use the `tmux-agent-transport` skill and the project-local routing table. Do not hardcode hostnames or session names in this skill.

## Stop Conditions

Stop and report current state to the human when:

- The PR is approved and no actionable findings remain.
- The remaining findings have all been answered with `Won't fix`.
- The project-defined maximum review loop count is reached.
- A new human instruction changes the task.

When stopping, summarize the PR decision, unresolved items if any, and the exact next action.
