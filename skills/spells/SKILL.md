---
name: spells
description: Defines the trigger phrases an agent recognizes in chat — `pr N`, `review N`, `recheck N`, `merged`, `merged N`, `issue N` — as shortcut entry points into the other skills in this repo (`pr-feedback`, `pr-review`, `pr-recheck`, `merge-sync`, `issue-check`). Apply when any of these phrases appears in a message from the human or from a peer agent.
---

# Spells

## Overview

A spell is a short trigger phrase a human or peer agent sends in chat to launch a standard workflow on the receiving agent. **Each spell defined here is a shortcut into one of the other skills in this repo** — the spell is the trigger phrase, the other skill is the workflow that runs. The mapping is:

| Spell        | Skill that runs the work                                |
| ------------ | ------------------------------------------------------- |
| `pr N`       | [`pr-feedback`](../pr-feedback/SKILL.md)                |
| `review N`   | [`pr-review`](../pr-review/SKILL.md)                    |
| `recheck N`  | [`pr-recheck`](../pr-recheck/SKILL.md)                  |
| `merged`     | [`merge-sync`](../merge-sync/SKILL.md) (local-side path) |
| `merged N`   | [`merge-sync`](../merge-sync/SKILL.md) (peer-side path) |
| `issue N`    | [`issue-check`](../issue-check/SKILL.md)                |

When any of the phrases above appears in an incoming message, the agent runs the corresponding workflow without further prompting. Spells are recognized in natural-language input; they are not slash commands and they are not parsed by the host CLI.

Each spell takes at most one argument, always a single token (a PR number, an issue number, etc.). The argument follows the spell with one space.

## Form: Bare vs Parameterized

Two spells (`merged` and `merged N`) come in both forms, and the form itself is meaningful — it tells the receiver who sent the spell.

- **Bare form** (no argument, e.g. `merged`): always **human-triggered**. The human shares enough context with this agent to leave the target implicit (it's the PR you just pushed, the rule we just discussed). Resolve the target from the active conversation.
- **Parameterized form** (one argument, e.g. `merged 92`): always **peer-agent dispatched**. A peer agent has no shared context, so it must name the target explicitly. Treat parameterized arrivals as if a peer sent them.

If a human types the parameterized form by mistake, handle it as a peer dispatch and tell the human in the reply that the bare form is what triggers the full local-side workflow.

## Universal Handling Rules

These apply to every spell below. Skill files referenced from each spell may add more, but never remove these.

- **Verify independently.** Treat every claim referenced by a spell — a finding to address, a bug report, a "this is fine" reply — as unconfirmed until you have read the relevant code, run the relevant tests, or reproduced the relevant behavior. Do not act on someone else's conclusion just because it was loud.
- **Decide every item explicitly.** For each actionable input (review comment, issue claim, peer instruction), produce a clear outcome: fix, decline with reason, or split into a tracked follow-up. Silence is not a valid outcome.
- **Anchor results in durable state.** Conclusions other agents and humans need to see must land on the durable surface (PR review, PR comment, issue comment, commit message). Do not rely on tmux scrollback or this agent's own chat transcript — peer agents cannot read those, and humans cannot audit them later.
- **Push before announcing.** Do not say "fixed", "done", or "addressed" until the relevant commits are pushed to the remote branch the spell named. Peer agents and reviewers re-fetch from remote; in-progress local work is invisible to them.
- **Re-trigger after every observable change.** If you take any action that changes what the next reader of the PR or issue would see — new commit, edited description, new reply — re-dispatch the appropriate notification spell (typically `recheck N` toward a reviewer, or `pr N` toward an author) so the peer is operating on the current snapshot.

## Spell: `pr N`

**Triggered by:** the human, the reviewer agent (after a `review` or `recheck` pass), or a notification bot.

**Action:** process every reviewer comment on pull request `N`. Pull all reviews, all inline review comments, and all conversation comments. For each actionable item, judge it independently against the code and tests, then either fix it (commit + push, reply with first line `Fixed`), decline it (reply with first line `Won't fix` plus concrete evidence), or split it into a follow-up issue (open the issue, then reply with the link and the reason for the split). Do not batch-dismiss findings just because another reviewer raised the same point — confirm each one.

**Workflow:** [`pr-feedback`](../pr-feedback/SKILL.md).

**Completion:** every actionable item has a reply on the PR; any required commits are pushed; the appropriate `recheck N` notification has been re-dispatched to the reviewer.

## Spell: `review N`

**Triggered by:** the PR author (typically a dev-side agent) toward the reviewer (typically a qa-side agent). First-time review only — second and subsequent rounds use `recheck N`.

**Action:** perform a full independent review of pull request `N`. Read the diff against the project's review standard. Default to looking for problems, not summarizing changes. Treat unit tests as a first-class review surface (presence of tests for each behavior change, real assertions, no silent skips, no over-mocking). Post findings on the PR — do not leave them in chat or in the tmux pane.

**Workflow:** [`pr-review`](../pr-review/SKILL.md).

**Completion:** review is posted on the PR (either with findings or with `APPROVE` / `:+1:` if no findings remain); a `pr N` notification is dispatched back to the author so they pick up the review.

## Spell: `recheck N`

**Triggered by:** the PR author toward the reviewer, after responding to a previous round's findings.

**Action:** re-evaluate pull request `N` with focus on whether the previous round's findings are now resolved. This is more focused than `review` — it is not a fresh full review. Verify each previously-raised finding against the current head: did the fix actually address it, or only paper over it? If a finding was answered with `Won't fix`, decide independently whether the reasoning holds; if it does, drop the finding; if not, raise it again with the new context.

**Workflow:** [`pr-recheck`](../pr-recheck/SKILL.md).

**Completion:** same as `review N` — conclusion posted on the PR, `pr N` dispatched back to the author.

## Spell: `merged` (bare)

**Triggered by:** the human, sent to the agent that just pushed the now-merged PR. The agent is normally still on the merged feature branch and knows the PR number from its own session context.

**Action:** synchronize this workspace to the new trunk and notify the peer.

1. `git fetch origin && git checkout <trunk> && git pull` (`<trunk>` is typically `main`).
2. Delete the merged feature branch locally: `git branch -d <feature-branch>`. Resolve `<feature-branch>` from session context, or via `gh pr view N --json headRefName --jq .headRefName` if the PR number is known.
3. If the project uses git submodules, run `git submodule update --init --recursive`. A plain `git pull` does not initialize newly-added submodules.
4. List the merged file paths: `gh pr view N --json files --jq '.files[].path'`. If any path falls under a rule source the project tracks (typically `docs/`, any `AGENTS.md`, vendored skill submodules, routing config), re-read those files (and any linked `SKILL.md`) before starting the next task. This prevents the agent from operating on stale rules.
5. Dispatch `merged N` to the peer agent through the project's tmux routing so they can sync too.

**Workflow:** [`merge-sync`](../merge-sync/SKILL.md).

**Completion:** trunk is current locally, the merged branch is deleted, rule-source changes are re-read, and the peer has been notified.

## Spell: `merged N`

**Triggered by:** a peer agent (after that peer handled its own bare `merged`). Distinguishable from the human form by the presence of the argument.

**Action:** synchronize this workspace to the new trunk **without** the local-side cleanup the bare form does. The peer is not necessarily on PR `N`'s feature branch (they may have been on trunk the whole time, or never had that branch checked out), so blind branch deletion would be wrong.

1. `git fetch origin && git checkout <trunk> && git pull`.
2. `git submodule update --init --recursive` if the project uses submodules.
3. Same rule-source check as the bare form: read merged file paths via `gh pr view N --json files --jq '.files[].path'` and re-read any rule sources the merge touched.
4. If a local copy of PR `N`'s branch happens to be present (for example from an earlier `gh pr checkout N`), `git branch -D` it. If it is not present, skip — do not search for it.
5. **Do not re-dispatch.** Sending `merged N` back to the original sender would create a loop. The bare-form sender is the only side that dispatches.

**Workflow:** [`merge-sync`](../merge-sync/SKILL.md).

**Completion:** trunk is current, rule sources re-read, no peer notification sent.

## Spell: `issue N`

**Triggered by:** the human.

**Action:** verify and handle GitHub issue `N`. Read the issue body and every comment. Then verify the report independently: read the relevant source, write a reproduction if the issue describes a bug, check whether the described behavior actually exists at the current head. Do not take the reporter's framing on faith.

- If the issue reproduces and is in scope, open a fix PR. Use a closing keyword (`Fixes #N`, `Closes #N`, `Resolves #N` — case-insensitive) in the PR description so the issue auto-closes on merge.
- If the issue does not reproduce or is invalid, comment on the issue explaining what you checked and what you found. Do not silently close it; let the human or the reporter decide what to do with the conclusion.
- If the issue is real but out of scope for an immediate fix, comment with the analysis and leave the issue open.

**Workflow:** [`issue-check`](../issue-check/SKILL.md).

**Completion:** either a fix PR is open and linked to the issue with a closing keyword, or a comment is posted on the issue stating what was verified and the conclusion.

## Dispatch Channels

How a spell arrives depends on who sent it. The receiver's behavior is identical in either case.

- **Human → agent:** the human types the spell into the agent's chat. No transport tooling needed.
- **Agent → peer agent:** project-defined transport. For tmux-based setups, use the [`tmux-send`](../tmux-send/SKILL.md) skill rather than calling `ssh` and `tmux send-keys` directly — the latter is racy with TUI render ticks and can drop characters silently. Routing details (which host, which session, which spells are valid in which direction) live in the project's own configuration, not in this skill.
- **Bot or webhook → agent:** same constraint as agent-to-agent. The trigger needs to land in the agent's input stream the same way a human message would; the transport is project-specific.

Treat the spell as recognition input only. Reconstruct the actual context (which PR, which issue, which commit) from the spell argument plus your own queries against the durable surface (GitHub, git remote), not from anything the sender said in the same channel.

## Stop Conditions

A spell-triggered workflow should converge, not loop forever. Stop and report state to the human when:

- The triggering condition is satisfied (PR approved, issue closed or declined with reason, branch deleted).
- All remaining items have been answered with `Won't fix` and explanations are on the PR.
- The project-defined maximum loop count is reached (a common ceiling is ten "fix → notify → respond" rounds; if you have not converged by then, the design itself is probably the issue).
- A new human instruction supersedes the current loop. Human instructions outrank in-flight spell loops.

When stopping, summarize the current decision, the unresolved items if any, and the exact next action you are waiting on.
