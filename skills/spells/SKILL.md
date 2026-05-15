---
name: spells
description: Use when a project defines short, conversational trigger phrases (such as "pr 92", "review 92", "merged", "issue 120") that route an agent into a standard workflow. Covers spell form, dispatch via human or peer agent, handling rules, and the relationship between spells and skills.
---

# Spells

## Overview

A spell is a short trigger phrase a human or peer agent sends in chat to route the receiving agent into a standard workflow. A spell is the entry point; the actual work belongs to the skill it maps to. Spells stay short on purpose so that humans can dispatch them by hand and peer agents can dispatch them through narrow channels (tmux send, message forwarders) without having to phrase a full instruction every time.

A spell is not a slash command. Slash commands are parsed by the host CLI; spells are recognized by the agent reading natural-language input and matching it against the project's spell vocabulary.

## When to Define a Spell

Add a spell only when a workflow is triggered often enough that retyping the full instruction is friction. One-off requests should stay as plain natural language. A good spell candidate has:

- A single, well-defined workflow behind it (one skill, or a tight chain).
- A predictable argument shape (no arguments, or one obvious identifier).
- A real second caller — either a peer agent that needs a stable signal, or a human who runs it many times a week.

If only one of those is true, the workflow is not yet worth a spell. Keep using natural language.

## Form Conventions

Spells follow two interchange forms, and the form itself carries meaning.

**Bare spell** (no argument, e.g. `merged`, `记下来`): the agent is expected to resolve the target from its own current context — the PR it just pushed, the rule it just learned. Bare spells are almost always **human-triggered**, because only the human shares enough context with the active agent to make the implicit target unambiguous.

**Parameterized spell** (one argument, e.g. `pr 92`, `review 92`, `merged 92`): the target is named explicitly. Parameterized spells are the right form for **peer-agent dispatch**, because the receiving agent is in a different context and needs the target spelled out.

Treat the bare-vs-parameterized distinction as a routing signal: if you receive `merged 92` you know the sender is another agent (or a human who got the form wrong); if you receive a bare `merged` you know it came from a human who is watching this session. Document this contract in the project's agent rules so each side handles them differently — for example, the bare form may delete a local branch and re-dispatch to a peer, while the parameterized form only syncs and never re-dispatches (preventing dispatch loops).

Naming rules:

- One short word, optionally followed by one short argument. Two-word spells are tolerable; three-word spells are too long.
- Lowercase ASCII for cross-project portability. Project-local spells in another script (such as `记下来`) are fine when the team only operates in that script.
- Argument is a single token: an integer ID, a short slug, never a sentence.

## Spell-to-Skill Mapping

Each spell points to one skill (or a tight chain of skills). The skill owns the actual workflow; the spell only provides a stable entry phrase. The mapping is recorded in the consuming repository, not in this skill, because different projects can map the same spell to different transports or stop conditions.

A typical mapping table looks like:

| Spell        | Skill that runs the work                                |
| ------------ | ------------------------------------------------------- |
| `pr N`       | [`pr-feedback`](../pr-feedback/SKILL.md)                |
| `review N`   | [`pr-review`](../pr-review/SKILL.md)                    |
| `recheck N`  | [`pr-recheck`](../pr-recheck/SKILL.md)                  |
| `merged`     | [`merge-sync`](../merge-sync/SKILL.md)                  |
| `merged N`   | [`merge-sync`](../merge-sync/SKILL.md) (peer path)      |
| `issue N`    | [`issue-check`](../issue-check/SKILL.md)                |

If a project introduces a new spell, the project's agent rules should add the row and link to the skill that implements it.

## Recommended Spell Vocabulary

This is the set most projects can adopt directly. Each entry lists who normally sends it, what the receiver does at a high level, and the skill it delegates to. The skill is the source of truth for the workflow; the entry below is just the trigger contract.

- **`pr N`** — Process all reviewer feedback on pull request `N`. Sent by a human, by a review agent after a `review` / `recheck` pass, or by a notification bot. Receiver pulls every review, inline review comment, and conversation comment, judges each one independently, then either fixes it, replies `Won't fix` with evidence, or splits it into a follow-up issue. Skill: `pr-feedback`.

- **`review N`** — First-time full review of pull request `N`. Sent by the PR author (typically dev-agent) to the reviewer (typically qa-agent). Receiver reads the diff against the project's review standard, posts findings to the PR, and on completion notifies the author with `pr N`. Skill: `pr-review`.

- **`recheck N`** — Re-evaluate pull request `N` after the author has responded. More focused than `review`: only verifies whether the previous round's findings are now resolved. Same direction and notification rule as `review`. Skill: `pr-recheck`.

- **`merged`** (bare) — Pull request the receiver just pushed has been merged to the trunk. Sent by a human to the agent that opened the PR. Receiver syncs trunk, deletes the merged feature branch locally, refreshes any rule-source files the merge touched, and dispatches `merged N` to the peer agent. Skill: `merge-sync`.

- **`merged N`** — Peer-side counterpart of `merged`. Sent by the agent that just handled the bare `merged`. Receiver syncs trunk and refreshes rule sources but does **not** delete any local branch and does **not** re-dispatch (avoids dispatch loops). Skill: `merge-sync`.

- **`issue N`** — Verify and handle GitHub issue `N`. Sent by a human. Receiver reads the issue and the relevant source independently, decides whether the report reproduces, and either opens a fix PR or replies on the issue with the reason it is being declined. Skill: `issue-check`.

Projects may extend this vocabulary, but the conventions above (form, dispatch direction, independent verification) are inherited.

## Handling Rules

Whatever spell triggers the workflow, the following rules apply to the receiver. They exist because spells are concise and lossy: the spell tells you *what to start*, never *what is true*.

- **Verify independently.** Treat every claim referenced by the spell — a finding to address, a bug report, a "this is fine" reply — as unconfirmed until you have read the relevant code, run the relevant tests, or reproduced the relevant behavior. Do not act on someone else's conclusion just because it was loud.

- **Decide every item explicitly.** For each actionable input (review comment, issue claim, peer instruction), produce a clear outcome: fix, decline with reason, or split into a tracked follow-up. Silence is not a valid outcome.

- **Anchor results in durable state.** Conclusions that other agents and humans need to see must land on the durable surface (PR review, PR comment, issue comment, commit message). Do not rely on tmux scrollback or the agent's own chat transcript — peer agents cannot read those, and humans cannot audit them later.

- **Push before announcing.** Do not say "fixed", "done", or "addressed" until the relevant commits are pushed to the remote branch the spell named. Peer agents and reviewers re-fetch from remote; in-progress local work is invisible to them.

- **Re-trigger after every observable change.** If you take any action that changes what the next reader of the PR/issue would see — new commit, edited description, new reply — re-dispatch the appropriate notification spell (typically `recheck N` toward a reviewer, or `pr N` toward an author) so the peer is operating on the current snapshot.

## Dispatch Channels

How a spell is delivered depends on who is sending it.

- **Human → agent**: the human types the spell into the agent's chat. No transport skill required.

- **Agent → peer agent**: use a project-defined transport. For tmux-based setups, use the [`tmux-send`](../tmux-send/SKILL.md) skill rather than calling `ssh` and `tmux send-keys` directly — the latter is racy with TUI render ticks and can drop characters silently. Routing tables (which host, which session, which spells are valid in which direction) belong in the project's own configuration, not in this skill.

- **Bot or webhook → agent**: same constraint as agent-to-agent. The trigger needs to land in the agent's input stream the same way a human message would; the transport is project-specific.

In every case the receiving agent should treat the spell as recognition input only — the actual context (which PR, which issue, which commit) is reconstructed by the receiver from the spell argument plus its own remote queries, not from anything the sender said in the same channel.

## Stop Conditions

A spell-triggered workflow should converge, not loop forever. Stop and report state to the human when:

- The triggering condition is satisfied (PR approved, issue closed or declined with reason, branch deleted).
- All remaining items have been answered with `Won't fix` and explanations are on the PR.
- The project-defined maximum loop count is reached (a common ceiling is ten "fix → notify → respond" rounds; if you have not converged by then, the design itself is probably the issue).
- A new human instruction supersedes the current loop. Human instructions outrank in-flight spell loops.

When stopping, summarize the current decision, the unresolved items if any, and the exact next action you are waiting on.

## Adding a Spell to a Project

1. Pick a name that satisfies the form conventions above. Confirm it does not already mean something else in any of the project's agent rule files.
2. Decide which existing skill it routes to. If no skill fits, write the skill first; do not let the spell's behavior live only inside the trigger phrase's documentation.
3. Add a row to the project's spell mapping (typically the root `AGENTS.md` or equivalent), naming the sender, receiver, the skill, and any project-local stop conditions.
4. If peer-agent dispatch is involved, add the spell to the project's routing table so transport tooling can validate the direction.
5. If both bare and parameterized forms exist, document the difference between them in the same place — that contract is what lets the receiver tell a human-triggered call apart from a peer-triggered call.
