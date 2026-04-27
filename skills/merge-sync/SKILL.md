---
name: merge-sync
description: Use when an agent workspace must synchronize after a pull request has merged, including project aliases like "merged" or "merged N", branch cleanup, main/default-branch updates, docs or agent-rule rereads, and peer notifications.
---

# Merge Sync

## Overview

After a PR merges, each agent workspace must update to the merged default branch and refresh any changed agent rules before doing more work. The workflow differs depending on whether the message came from a human on the merged branch owner side or from another agent.

Project-specific trigger aliases such as `merged` and `merged N` are compatibility shims. The reusable concept is "sync after PR merge".

## Identify Source

Read the project instructions to decide how merge-sync is triggered. Common patterns:

- Human-originated local sync: the agent that owned the PR is on or knows the PR's head branch.
- Peer-originated sync: another agent sends the PR number so this workspace can update without deleting an unrelated current branch.

If the PR number is missing, recover it from the current branch, recent PRs, or the user before deleting any branch.

## Human-Originated Sync

1. Fetch remote state and identify the PR head branch and default branch.
2. Switch to the default branch and pull the latest remote default branch.
3. Delete the merged local feature branch only after confirming it is the PR head branch.
4. Inspect merged file paths. If agent rules, docs, or skill pointers changed, reread the affected files before starting new work.
5. If the project has peer agents, notify them with the project-defined merge-sync message after local sync completes.

## Peer-Originated Sync

1. Fetch remote state, switch to the default branch, and pull latest.
2. Inspect the merged PR's changed files. Reread changed agent rules, docs, or skill pointers.
3. Optionally delete stale local branches for that PR if they are clearly associated with the merged PR.
4. Do not notify the peer again; merge-sync notifications must not bounce forever.

## Safety Rules

- Never delete the current branch unless it is confirmed to be the merged PR head branch.
- Never treat tmux or chat output as proof of merge; verify through the VCS or hosting provider.
- If docs or agent rules changed, reread them before accepting another task.
