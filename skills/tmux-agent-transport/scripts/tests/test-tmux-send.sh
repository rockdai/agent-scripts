#!/usr/bin/env bash
# Smoke tests for scripts/tmux-send.sh.
#
# Spins up a local tmux session per case running a Python TUI stub,
# dispatches text through tmux-send.sh, asserts the expected exit code.
#
# Usage: scripts/tests/test-tmux-send.sh

set -euo pipefail

cd "$(dirname "$0")/../.."

PASS=0
FAIL=0

run_case() {
    local name="$1" reader="$2" text="$3" expected="$4"
    local session="tmux-send-test-$$-$RANDOM"

    tmux new-session -d -s "$session" "python3 scripts/tests/$reader" 2>/dev/null
    sleep 0.3

    local actual=0
    scripts/tmux-send.sh "$session" "$text" >/dev/null 2>&1 || actual=$?

    local pane
    pane=$(tmux capture-pane -p -t "$session" 2>/dev/null || echo "(pane gone)")
    tmux kill-session -t "$session" 2>/dev/null || true

    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS  %s (exit %s)\n' "$name" "$actual"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (expected exit %s, got %s)\n' "$name" "$expected" "$actual"
        printf '  pane:\n%s\n' "$(echo "$pane" | sed 's/^/    /')"
        FAIL=$((FAIL + 1))
    fi
}

run_ssh_case() {
    local name="$1" reader="$2" text="$3" expected_exit="$4" expected_submit_len="$5"
    local session="tmux-send-test-$$-$RANDOM"

    tmux new-session -d -s "$session" "python3 scripts/tests/$reader" 2>/dev/null
    sleep 0.3

    local actual=0
    PATH="$(pwd)/scripts/tests/mock-ssh-bin:$PATH" \
        scripts/tmux-send.sh --host fake-host --tmux tmux "$session" "$text" >/dev/null 2>&1 || actual=$?

    local pane
    pane=$(tmux capture-pane -p -t "$session" 2>/dev/null || echo "(pane gone)")
    tmux kill-session -t "$session" 2>/dev/null || true

    local fail_reason=""
    if [[ "$actual" != "$expected_exit" ]]; then
        fail_reason="expected exit $expected_exit, got $actual"
    elif ! echo "$pane" | grep -qF "[SUBMIT len=$expected_submit_len]"; then
        fail_reason="expected pane to show [SUBMIT len=$expected_submit_len]"
    fi

    if [[ -z "$fail_reason" ]]; then
        printf 'PASS  %s (exit %s, len=%s)\n' "$name" "$actual" "$expected_submit_len"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (%s)\n' "$name" "$fail_reason"
        printf '  pane:\n%s\n' "$(echo "$pane" | sed 's/^/    /')"
        FAIL=$((FAIL + 1))
    fi
}

run_case "happy path: fake-tui absorbs full text, Enter submits" \
    "fake-tui.py" "review 221" 0

run_case "flaky reader drops chars: pre-Enter verify catches partial arrival" \
    "flaky-reader.py" "review 221" 3

run_case "partial then full: C-u between retries lets retry recover from partial drop" \
    "partial-then-full-reader.py" "review 221" 0

run_case "stale echo: prior dispatch's echo in scrollback must not satisfy pre-Enter check" \
    "stale-echo-reader.py" "review 221" 3

run_case "NBSP separator: real Codex prompt uses U+00A0 between glyph and input" \
    "nbsp-prompt-reader.py" "pr 221" 0

run_case "text with single quote: printf %q escaping preserves apostrophe" \
    "fake-tui.py" "it's fine" 0

# TEXT containing bash glob metacharacters (*, ?, [). The pre/post-Enter
# predicates use bash `[[ ... == *" $TEXT" ]]` style patterns where $TEXT
# is inside double quotes, which makes its content match literally per the
# bash manual ("Any part of the pattern may be quoted to force the quoted
# portion to be matched as a string"). This case proves the predicate
# treats glob chars in TEXT as literals — input "review *" must land and
# verify cleanly without false positives from the literal `*`.
run_case "text with glob metachars: \$TEXT in quoted pattern is matched literally" \
    "fake-tui.py" "review *" 0

run_ssh_case "ssh path: text with space survives openssh argv joining" \
    "fake-tui.py" "review 221" 0 10

# --- Flag parsing usage errors ---
# `set -u` would crash with an unbound-variable diagnostic if --host /
# --tmux were passed without a value. The contract is "missing flag value
# is a usage error → exit 2"; lock that into a smoke test so future
# refactors don't regress to a Bash crash.

flag_actual=0
scripts/tmux-send.sh --host >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --host without value returns exit 2 (not unbound-variable crash)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --host without value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh --tmux >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --tmux without value returns exit 2 (not unbound-variable crash)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --tmux without value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

# `--host --tmux foo bar`: --host got the next flag as its "value", which is
# almost always a forgotten value, not a legitimate hostname. require_arg
# rejects flag-like values to surface the real error instead of silently
# setting HOST=--tmux and falling through to ssh.
flag_actual=0
scripts/tmux-send.sh --host --tmux foo bar >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --host with flag-like value returns exit 2 (not silent mis-parse)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --host with flag-like value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

# TEXT containing \r: many TUIs treat CR as Enter, so smuggling it past
# validation would let TEXT contain a mid-string submit. Reject like \n.
flag_actual=0
scripts/tmux-send.sh test-session $'hello\rworld' >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  TEXT with carriage return returns exit 2 (single-line contract)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  TEXT with carriage return (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

echo
printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
