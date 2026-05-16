---
name: spells
description: Routes the shortcut trigger phrases an agent recognizes in chat — `pr N`, `review N`, `recheck N`, `merged`, `merged N`, `issue N` — to the corresponding skill in this repo. Apply when any of these phrases appears in an incoming message.
---

# Spells

## Overview

A spell is a short trigger phrase a human or peer agent sends in chat. Each spell is a shortcut into one of the other skills in this repo. When any of the phrases below appears in an incoming message, run the linked skill. The skill itself owns the workflow, the rules, the stop conditions, the reply format — this file is only the routing table.

Spells are recognized in natural-language input; they are not slash commands and are not parsed by the host CLI. Each spell takes at most one argument, always a single token (a PR number, an issue number) separated from the spell by one space.

## Spell → Skill Routing

| Spell        | Skill                                     | Use when                                                              |
| ------------ | ----------------------------------------- | --------------------------------------------------------------------- |
| `pr N`       | [`pr-feedback`](../pr-feedback/SKILL.md)  | Process all reviewer feedback on pull request `N`.                    |
| `review N`   | [`pr-review`](../pr-review/SKILL.md)      | First-time full review of pull request `N`.                           |
| `recheck N`  | [`pr-recheck`](../pr-recheck/SKILL.md)    | Re-evaluate pull request `N` after the author responded to findings.  |
| `merged`     | [`merge-sync`](../merge-sync/SKILL.md)    | The PR you just pushed has been merged (see form note below).         |
| `merged N`   | [`merge-sync`](../merge-sync/SKILL.md)    | Peer agent telling you PR `N` has been merged (see form note below).  |
| `issue N`    | [`issue-check`](../issue-check/SKILL.md)  | Verify and handle GitHub issue `N`.                                   |

## `merged` vs `merged N`

This is the only spell where the form (bare vs parameterized) is part of the contract — it tells the receiver who sent it and which path inside `merge-sync` to run.

- **Bare `merged`** — human-triggered, sent to the agent that just pushed the now-merged PR. Run [`merge-sync` § Human-Originated Sync](../merge-sync/SKILL.md#human-originated-sync), which includes deleting the merged feature branch locally and dispatching `merged N` to the peer.
- **`merged N`** — peer-agent dispatched, with the PR number explicit because the peer is in a different context. Run [`merge-sync` § Peer-Originated Sync](../merge-sync/SKILL.md#peer-originated-sync), which syncs trunk and rereads changed rule sources but does not delete the current branch and does not re-dispatch.
- If a human types `merged N` by mistake, treat it as the peer path (so it does no damage) and remind the human in the reply that the bare form is what triggers full local cleanup plus peer notification.

The other spells in the table do not have this dual form.

## Dispatch Channels

How a spell arrives depends on who sent it; the receiver's behavior is owned by the linked skill, not by the channel.

- **Human → agent**: typed into the agent's chat. No transport tooling needed.
- **Agent → peer agent**: use the [`tmux-send`](../tmux-send/SKILL.md) skill rather than calling `ssh` and `tmux send-keys` directly. Routing details (which host, which session, which spells are valid in which direction) live in the consuming project's configuration, not in this skill.
- **Bot or webhook → agent**: same as agent-to-agent — the trigger needs to land in the agent's input stream the same way a human message would; transport is project-specific.
