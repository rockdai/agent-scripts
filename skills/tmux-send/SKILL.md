---
name: tmux-send
description: Use when an agent needs to send a short one-line command, trigger alias, or handoff message to another agent running in a local or remote tmux session, or when installing, validating, or troubleshooting scripts/tmux-send.sh.
---

# Tmux Send

## Overview

Use tmux only as a transport for short, one-line signals between already-running agent sessions. Do not use tmux pane contents as the source of truth for decisions, findings, or status; durable project systems such as PR comments, issues, commits, and logs must hold the actual record.

This skill provides `scripts/tmux-send.sh`, a safer wrapper around `tmux send-keys` that verifies the text reaches the target TUI input line before pressing Enter.

This skill assumes the target agent sessions already exist. It borrows only the lightweight tmux operations that are useful for persistent sessions: list sessions, capture recent output for troubleshooting, attach when a human needs to watch live, and kill stale sessions when the project explicitly allows it. It does not introduce a generic agent spawner or model launcher.

## Boundary

This skill owns:

- Sending one-line messages to a tmux target.
- Remote dispatch over SSH to a tmux target on another host.
- Installing and validating `tmux-send.sh`.
- Transport troubleshooting.

This skill does not own:

- Spawning new agent sessions.
- Choosing model providers or local/cloud execution modes.
- The meaning of messages such as `review 12`, `pr 12`, or `merged 12`.
- PR review rules, issue handling rules, or merge sync rules.
- Reading another agent's conclusions from a tmux pane.

## Configuration

Read the consuming repository's agent docs before dispatching. Look for:

- Agent role names and target tmux sessions.
- Hostnames for remote sessions.
- Allowed message names or trigger aliases.
- Fallback commands for status checks.
- Whether tmux transport is allowed for the task.

Use a project-local mapping when present. A typical mapping looks like:

```yaml
agents:
  dev:
    host: dev-machine
    session: project-dev
  review:
    host: review-machine
    session: project-review
transport:
  script: scripts/tmux-send.sh
```

If no mapping exists, ask the human for the target host/session before sending anything.

## Dispatch Workflow

1. Confirm the durable state is already written.

   Examples: PR comment submitted, commit pushed, issue created, or review posted. Do not dispatch first and write the durable state later.

2. Choose the target from the project mapping.

   Use the role and message semantics from the consuming project. Do not invent new trigger aliases unless the project explicitly asks for them.

3. Send exactly one line.

   ```bash
   skills/tmux-send/scripts/tmux-send.sh <session> "<message>"
   skills/tmux-send/scripts/tmux-send.sh --host <host> <session> "<message>"
   ```

4. Treat any non-zero exit as a dispatch failure.

   Do not continue as if the peer was notified. Inspect the error, run the fallback status command if the project defines one, and report the failed dispatch in the durable project record when it matters.

## Session Checks

Use these only for transport troubleshooting or human observation. They are not substitutes for PR comments, issues, commits, or logs.

```bash
tmux list-sessions
tmux capture-pane -t <session> -p -S -50
tmux attach -t <session>
tmux kill-session -t <session>
```

Do not kill a session unless it is clearly stale or the project/human asked for cleanup.

## Script Contract

`scripts/tmux-send.sh` accepts:

```bash
scripts/tmux-send.sh [--host HOST] [--tmux PATH] [--prompt-regex ERE] [--prompt-regex=ERE] [--no-verify] TARGET TEXT
```

Exit codes:

- `0`: sent. With default verification, the text was confirmed submitted.
- `2`: usage error.
- `3`: text did not fully land in the input line or remained stuck after submit.
- Other non-zero: propagated from `ssh`, `tmux`, or the shell.

Constraints:

- `TEXT` must be a non-empty single line, and cannot be whitespace-only.
- Prefer default verification. Use `--no-verify` only for explicit fire-and-forget cases.
- The default tmux binary is `tmux` from `PATH`, with `/opt/homebrew/bin/tmux` as a fallback when present. Use `--tmux` for hosts with a different tmux location.
- The default prompt matcher recognizes `>`, `$`, `›`, and `❯`. Use `--prompt-regex` when the target TUI uses a different prompt token. Use `--prompt-regex=ERE` when the pattern itself starts with `--`.
- For remote dispatch, bootstrap SSH host keys interactively before relying on non-interactive sends.

## Troubleshooting

- `Host key verification failed`: SSH to the target host once interactively and accept the host key.
- `tmux target not found`: verify the session name and the tmux binary path.
- Exit `3`: capture the target pane and check whether the TUI prompt is blocked, not focused, or needs a project-specific `--prompt-regex`.
- Text appears typed but not submitted: rerun without `--no-verify`, then inspect the pane.

Never replace the script with bare `tmux send-keys` for agent dispatch. Bare sends can race agent TUIs and silently submit partial or stale text.

## Validation

After copying or editing the script, run:

```bash
skills/tmux-send/scripts/tmux-send.sh --help
skills/tmux-send/scripts/tests/test-tmux-send.sh
```

The smoke tests require local `tmux` and `python3`.
