---
name: issue-triage
description: Use when an agent must handle an issue request, including project aliases like "issue N", issue verification, source investigation, reproducing or disproving the report, fixing valid issues, testing, opening a PR, or explaining invalid reports.
---

# Issue Triage

## Overview

Treat an issue as a report to verify, not an instruction to blindly implement. Read the issue, inspect the relevant code and behavior, decide whether the problem is real, then either fix it through the project's PR workflow or explain why it is not valid.

Project-specific trigger aliases such as `issue N` are compatibility shims. The reusable concept is "verify and handle an issue".

## Gather Facts

Read the issue body, comments, labels, linked PRs, and related files. Use the provider tool available to the project, for example:

```bash
gh issue view N --comments
```

Then inspect the code paths involved. Reproduce the reported behavior when practical. If reproduction requires credentials, devices, or external services, follow the consuming repository's instructions for those resources.

## Decide

- If the issue is valid and in scope, implement the smallest fix that addresses the verified problem.
- If the issue is valid but too large or partially out of scope, split follow-up issues with enough context.
- If the issue is invalid, outdated, duplicate, or already fixed, explain the evidence to the human or on the issue according to project rules.

## Fix Workflow

Follow the consuming project's branch, test, commit, push, and PR rules. When opening a PR that should close the issue on merge, use the hosting provider's official closing keyword, such as `Closes #N` on GitHub.

Do not claim the issue is fixed until the fix is committed, pushed, and represented in the project tracking system.
