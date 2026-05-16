---
name: code-review
description: Defines the contract for the dev ↔ qa code-review collaboration loop on a pull request — round-trip timing, when to notify, how to record human authorization, what qa looks for (including unit-test review patterns), how findings are written, how to reply with `Fixed` / `Won't fix`, when to split out-of-scope work into a follow-up issue, and the stop conditions that close the loop.
---

# Code Review

## Overview

This skill is the upper layer of the code-review workflow: it defines **what good looks like** for both sides of the loop — the dev (PR author) who pushes changes and processes feedback, and the qa (independent reviewer) who reads diffs and posts findings. The mechanics of running each step live in the per-step skills:

- [`pr-review`](../pr-review/SKILL.md) — qa runs a first-time full review.
- [`pr-recheck`](../pr-recheck/SKILL.md) — qa re-evaluates after the dev responded.
- [`pr-feedback`](../pr-feedback/SKILL.md) — dev processes review feedback on the PR.
- [`review-notify`](../review-notify/SKILL.md) — either side sends the wake-up signal to the other.
- [`spells`](../spells/SKILL.md) — the chat trigger phrases (`review N`, `recheck N`, `pr N`) that hand control off between the two sides.

When this skill and one of those skills both speak to the same step, this skill states the **standard** and the per-step skill states the **procedure**.

## Roles

The loop has exactly two role names. Use these names consistently in PR descriptions, commit messages, and review comments:

- **dev** — opens the PR, lands commits, replies to findings. Authorizes their own changes only inside the limits set by the project's agent rules.
- **qa** — reads the PR independently and posts findings or approval. Does not see dev's chat context; works only from what is durable on the PR.

The two roles run in **independent contexts** and never share session state. Every signal that crosses between them — a finding, a fix, an approval, a "this is intentional" justification — must land on the PR's durable surface (review, inline review comment, conversation comment, commit message) before it counts. tmux panes, chat transcripts, and local memory do not count.

## The Round-Trip

The loop is event-driven. Each side acts only when the other has posted something durable, then signals back:

```
dev opens PR or pushes commit/reply
       │
       └─► dev sends `review N` (first time) or `recheck N` (subsequent rounds) to qa
              │
              └─► qa reads PR, posts findings or APPROVE on the PR
                     │
                     └─► qa sends `pr N` back to dev
                            │
                            └─► dev processes every finding (Fixed / Won't fix / split to issue)
                                   │
                                   └─► dev commits+pushes any code change, replies on the PR
                                          │
                                          └─► loop back to "dev sends recheck N" until a stop condition fires
```

The first round uses `review N`; every round after that uses `recheck N` — even when dev has no new code and is only replying to a finding.

## When dev Must Notify qa

Notify qa after **any** of the following on the PR. Each of these changes what the next independent reader of the PR would see, so qa's previous conclusion is no longer valid:

- Opening a new PR.
- Pushing a new commit, for any reason — fix, additional test, doc-only tweak, lint, rebase.
- Changing the PR title or description in a way that affects review scope or intent.
- Replying to **any** reviewer's finding — qa's own, a human's, or a bot's (`gemini-code-assist[bot]`, `copilot-pull-request-reviewer[bot]`, etc.) — whether or not a new commit accompanied the reply. A `Won't fix` reply still needs qa to independently judge the new reasoning.

The order is always: **commit + push (or post the reply) → notify qa → wait for qa's `pr N` callback**. Never notify before the change is visible on the remote; qa only sees what is on the PR.

## Optional Bot Review

After opening or updating a PR, dev may also request a bot review (e.g. GitHub Copilot) as **fire-and-forget**: dispatch and move on. Treat any bot finding that does appear the same as a human or qa finding — independently judged, replied to with `Fixed` or `Won't fix`. A failed or absent bot review never blocks the dev → qa loop.

## Recording Human Authorization in the PR

qa cannot see what a human said to dev in chat. If dev consciously did any of the following on the human's instruction, dev must record the authorization on the PR (in the description, in a commit message, or in a top-level comment) **before** notifying qa:

- Knowingly violated a default rule from the repo's agent instructions (scope limit, docs requirement, dependency rule, etc.).
- Pulled changes into the PR that are not directly related to its stated purpose.
- Skipped a test, validation, lint, or other check that would otherwise be expected.
- Picked a clearly non-standard implementation approach.

This is not a free pass: qa still judges independently whether the human's reasoning actually covers the risk. It just gives qa the full input so qa is not relitigating an already-authorized choice as if it had no context.

If dev forgets, qa will raise the default finding and dev can answer with `Won't fix` plus the human's reasoning — but that wastes a round. Putting the authorization on the PR upfront is the cheap path.

## Issue Linking

If the PR resolves a GitHub Issue, the PR description must use one of GitHub's closing keywords (case-insensitive):

- `Close #N` / `Closes #N` / `Closed #N`
- `Fix #N` / `Fixes #N` / `Fixed #N`
- `Resolve #N` / `Resolves #N` / `Resolved #N`

Only these keywords trigger GitHub's auto-close on merge. `Addresses #N`, `Related to #N`, and a bare URL do **not**, and they leave the issue dangling in OPEN after the PR merges.

When qa sees a PR that is clearly fixing an issue but the description does not contain a closing keyword, qa raises a finding. The dev fixes the description and re-notifies with `recheck N`.

Official reference: <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue#linking-a-pull-request-to-an-issue-using-a-keyword>.

## Review Scope

Default to finding problems, not summarizing the diff. A review that just narrates "this PR adds X, then Y, then Z" is a missed review. Prioritize, in this order:

1. **Behavior bugs and regressions** — code that does the wrong thing now, or that breaks something previously correct.
2. **Lifecycle and concurrency risks** — leaks, races, ordering violations, unhandled cancellation.
3. **Missing or weak tests** — see [Unit Test Review](#unit-test-review) below.
4. **Mismatches between PR, linked issue, and repo rules** — scope drift, undocumented exceptions to defaults, missing closing keyword.

When the review surfaces no findings, qa says so explicitly with `No findings` (or `No additional findings` on a recheck). A vague positive blurb ("looks good!") is not an acceptable substitute — it leaves dev unsure whether qa actually looked or skimmed.

## Unit Test Review

Tests are a first-class review surface, not an afterthought.

- **Companion tests.** Every behavior change in production code should have a corresponding test that exercises it (happy path + boundary + regression anchor). Production change with zero accompanying test is a finding unless there is a documented reason.
- **Test completeness.** Check that the tests actually pin the behavior down: exception paths, concurrency cases, state-machine branches, and the key invariants of the changed code should each be locked by at least one assertion.
- **Low-signal / no-op test patterns.** Flag any of:
  - Weak assertions like `XCTAssertNotNil(x)` or `expect(x).toBeTruthy()` where a behavior check is what's needed.
  - "It ran without throwing, so it passes" — no assertion on the actual result.
  - `fmt.Println` / `console.log` used as a stand-in for an assertion.
  - Setup-only tests with no behavior verification.
  - Tests gated off with `skip` / `xtest` / `@Disabled` and no TODO explaining why.
  - Mocks so thick that the test only verifies the mock's own configuration rather than the code's behavior.
- **Coverage regression.** A change that adds a new branch, new function, or new failure path without a test that exercises it counts as a coverage regression. Raise a finding and ask for the missing test.

## Findings Format

Write findings directly on the PR, ideally as inline review comments anchored to the smallest relevant code range. Each finding should be:

- **Specific.** Reference a commit, file, and line.
- **Actionable.** State the concrete change needed, or the specific question that needs answering.
- **Auditable.** A future reader (human or agent) should be able to reconstruct why this was raised without external context.

When qa concludes a round with no remaining findings:

- If qa has approval permission on the repo: post `APPROVE` on the PR **and** reply `:+1:`.
- If qa does not have approval permission: reply `:+1:` at minimum — that is the "no findings" signal projects rely on for stop condition 1 below.

## Replying to Findings

The dev replies to **every** actionable finding — silence is not allowed. Each reply starts with one of two literal first lines:

- `Fixed` — the change has been made. The first line is exactly `Fixed` on its own; details follow on subsequent lines. Reference the commit SHA when a code change was pushed for this finding. Do not post `Fixed` until the commit is pushed to the PR branch.
- `Won't fix` — the finding is declined. The first line is exactly `Won't fix` on its own; the explanation that follows must cite concrete evidence (a behavior, a constraint, an authorization recorded earlier in the PR). Vague refusals like "not needed" are not acceptable.

Use the platform's threaded reply on inline review comments when possible. Use a top-level PR comment only when the platform offers no threaded reply for that surface.

After replying — even with no code change — go back to [When dev Must Notify qa](#when-dev-must-notify-qa) and dispatch `recheck N`. A `Won't fix` reply still needs qa to judge the new reasoning.

## Out-of-Scope Findings

When a finding is real but does not belong in the current PR (different subsystem, larger refactor, deferred decision), dev does **not** answer with "we'll handle later". Instead:

1. Open a GitHub Issue capturing enough context for a future agent to reproduce the concern (background, affected files, suggested approach if known).
2. Reply on the original review thread with the Issue link and one sentence on why this is being split out rather than fixed in this PR.

"We'll handle later" without a tracked Issue is not an acceptable reply — it loses the finding the moment the PR merges.

## Stop Conditions

The loop should converge. The dev stops and reports current state to the human when any of these is true:

1. **qa approved.** qa posted `APPROVE` or replied `:+1:` on the PR with no open findings.
2. **Every open qa finding has a `Won't fix` reply with reasoning on the PR.** Continuing the loop would just re-receive the same findings.
3. **Ten rounds have passed.** Ten iterations of "fix → notify → respond" without convergence usually means the design itself is contested or the PR scope has crept; escalate to the human rather than spinning more.
4. **A new human instruction supersedes the loop.** Human instructions outrank the in-flight review cycle.

When stopping, the dev summarizes for the human: the current PR review decision, the list of any unresolved findings, and the recommended next action (await `merged`, split into a follow-up issue, redesign, etc.).
