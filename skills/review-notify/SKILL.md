---
name: review-notify
description: Use when an agent must notify the qa or dev agent about pull request state, including first review requests, recheck requests, qa callbacks, merge-sync callbacks, bot review requests, or transport failures.
---

# Review Notify

## Overview

Notify another agent only after the durable PR state is already written. The notification is a wake-up signal, not the record of truth.

Project-specific message names such as `review N`, `recheck N`, `pr N`, or `merged N` are trigger aliases. The reusable concept is "notify the right agent about the durable PR state".

## Before Dispatch

Read the consuming repository's routing table and review workflow. Confirm:

- The PR, comment, review, or commit is visible remotely.
- The target role, host, session, or provider destination is configured.
- The correct message type for the current transition is known.
- Any optional bot review request is allowed by the project.

Do not notify from memory. Verify the PR number and current head when the message depends on them.

## Common Transitions

- New PR or first review request: notify the qa with the project's full-review message.
- New commit, changed PR description, or reply to a finding: notify the qa with the project's recheck message.
- Qa has posted findings or approval: notify the dev with the project's feedback-processing message.
- PR merged: notify peer workspaces with the project's merge-sync message.

## Transport

Use the configured transport for the project. If the project uses tmux, use `tmux-send` and its routing table. If it uses GitHub mentions, issue comments, webhooks, CI jobs, or another queue, use that provider instead.

Treat any dispatch failure as real. Do not continue as if the other agent was notified. Record or report the failure according to project rules.

## Optional Bot Review

Some projects also request bot review after opening or updating a PR. Trigger it only when the project says to, and treat it as fire-and-forget unless the project defines stronger requirements.
