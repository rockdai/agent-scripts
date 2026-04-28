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
    shift 4
    local session="tmux-send-test-$$-$RANDOM"

    tmux new-session -d -s "$session" "python3 scripts/tests/$reader" 2>/dev/null
    sleep 0.3

    local actual=0
    scripts/tmux-send.sh --tmux tmux "$@" "$session" "$text" >/dev/null 2>&1 || actual=$?

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

run_case "prompt glyph text: empty prompt must not satisfy text landing check" \
    "stale-echo-reader.py" ">" 3

run_case "NBSP separator: prompt uses U+00A0 between glyph and input" \
    "nbsp-prompt-reader.py" "pr 221" 0

run_case "custom prompt regex: leading-dash prompt with figure-space separator" \
    "custom-prompt-reader.py" "pr 221" 0 --prompt-regex "->"

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

# `text_at_input_line` only examines lines that start with a prompt glyph,
# so an exact `last_prompt == TEXT` branch contradicts the input shape. Keep
# the accepted forms explicit: prompt plus ASCII space, tab, or NBSP.
if grep -qF '[[ "$last_prompt" == "$TEXT" ]]' scripts/tmux-send.sh; then
    printf 'FAIL  text_at_input_line contains exact TEXT branch despite prompt anchoring\n'
    FAIL=$((FAIL + 1))
else
    printf 'PASS  text_at_input_line has no exact TEXT branch\n'
    PASS=$((PASS + 1))
fi

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

flag_actual=0
scripts/tmux-send.sh --prompt-regex >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --prompt-regex without value returns exit 2 (not unbound-variable crash)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --prompt-regex without value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh --prompt-regex= >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --prompt-regex= with empty value returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --prompt-regex= with empty value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh --prompt-regex '[' test-session "review 221" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  invalid --prompt-regex returns exit 2 before tmux dispatch\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  invalid --prompt-regex (expected exit 2, got %s)\n' "$flag_actual"
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

flag_actual=0
scripts/tmux-send.sh --host "" test-session "review 221" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --host with empty value returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --host with empty value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh --tmux "" test-session "review 221" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  --tmux with empty value returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --tmux with empty value (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

# TEXT containing \r: many TUIs treat CR as Enter, so smuggling it past
# validation would let TEXT contain a mid-string submit. Reject like \n.
flag_actual=0
scripts/tmux-send.sh test-session $'hello\rworld' >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  TEXT with carriage return returns exit 2 (single-line message contract)\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  TEXT with carriage return (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh test-session "" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  empty TEXT returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  empty TEXT (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
scripts/tmux-send.sh test-session "   " >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  whitespace-only TEXT returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  whitespace-only TEXT (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

stdout_session="tmux-send-test-$$-$RANDOM"
tmux new-session -d -s "$stdout_session" "python3 scripts/tests/fake-tui.py" 2>/dev/null
sleep 0.3
stdout_actual=0
stdout_text="secret payload"
stdout_output=$(scripts/tmux-send.sh --tmux tmux "$stdout_session" "$stdout_text" 2>&1) || stdout_actual=$?
tmux kill-session -t "$stdout_session" 2>/dev/null || true
if [[ "$stdout_actual" == 0 ]] &&
    [[ "$stdout_output" != *"$stdout_text"* ]] &&
    [[ "$stdout_output" == *"len=14"* ]]; then
    printf 'PASS  success stdout reports length without echoing TEXT\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  success stdout redaction (exit %s, output: %s)\n' "$stdout_actual" "$stdout_output"
    FAIL=$((FAIL + 1))
fi

echo
printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
