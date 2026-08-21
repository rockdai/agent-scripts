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

run_case "leading-dash TEXT: buffer paste -- treats it as data, not flags" \
    "fake-tui.py" "-n foo" 0

run_ssh_case "ssh path: text with space survives openssh argv joining" \
    "fake-tui.py" "review 221" 0 10

# --- Deadline cases (kongkong#339 / #343) ---
# Each case runs its wedge fixture from a per-run UNIQUE copy and asserts
# residue only against that exact path: a global `pgrep -f hang-tmux`
# would match (and a cleanup pkill would murder) fixtures belonging to a
# concurrent suite run or another checkout.

# run_deadline_case NAME FIXTURE TIMEOUT MAX_ELAPSED [--ssh]
#   Dispatches against a wedge fixture with the given TMUX_SEND_TIMEOUT,
#   expects exit 143 within MAX_ELAPSED seconds and no surviving process
#   from this run's unique fixture copy. --ssh routes through the mock
#   ssh (the fixture then wedges on the "remote" side of the dispatch).
run_deadline_case() {
    local name="$1" fixture="$2" send_timeout="$3" max_elapsed="$4" mode="${5:-local}"
    local dir unique actual=0 start elapsed residue=""
    dir=$(mktemp -d)
    unique="$dir/wedge-$$-$RANDOM"
    cp "scripts/tests/$fixture" "$unique"
    chmod +x "$unique"

    start=$SECONDS
    if [[ "$mode" == "--ssh" ]]; then
        PATH="$(pwd)/scripts/tests/mock-ssh-bin:$PATH" \
        TMUX_SEND_TIMEOUT="$send_timeout" scripts/tmux-send.sh \
            --host fake-host --tmux "$unique" dummy-session "review 221" >/dev/null 2>"$dir/stderr" || actual=$?
    else
        TMUX_SEND_TIMEOUT="$send_timeout" scripts/tmux-send.sh \
            --tmux "$unique" dummy-session "review 221" >/dev/null 2>"$dir/stderr" || actual=$?
    fi
    elapsed=$(( SECONDS - start ))

    sleep 1
    if pgrep -f "$unique" >/dev/null; then
        residue="left survivors"
        pkill -9 -f "$unique" 2>/dev/null || true
    fi
    # A deadline kill must not leak bash's asynchronous job notices
    # ("Terminated: 15", "Killed: 9") onto the caller's stderr — the
    # muting is structural (run_bounded subshell), so assert it.
    local noise=""
    if grep -qEi 'terminated|killed' "$dir/stderr" 2>/dev/null; then
        noise="job notice on stderr"
    fi
    rm -rf "$dir"

    if [[ "$actual" == 143 && "$elapsed" -le "$max_elapsed" && -z "$residue" && -z "$noise" ]]; then
        printf 'PASS  %s (exit 143 in %ss, no residue, quiet stderr)\n' "$name" "$elapsed"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (expected exit 143 within %ss + no residue + quiet stderr, got exit %s in %ss%s%s)\n' \
            "$name" "$max_elapsed" "$actual" "$elapsed" "${residue:+, $residue}" "${noise:+, $noise}"
        FAIL=$((FAIL + 1))
    fi
}

run_deadline_case "wedged tmux client: dispatch deadline fires, tree reaped" \
    "hang-tmux" 2 10

run_deadline_case "leader dies, TERM-ignoring child survives: group probe KILLs the orphan" \
    "hang-tmux-stubborn" 2 10

run_deadline_case "ssh path: remote side self-bounds and cancels its own wedge" \
    "hang-tmux" 2 10 --ssh

# Transport wedge: ssh itself ignores TERM and never returns. The local
# +15s backstop must converge it and the exit code must be the normalized
# 143 — not KILL's 137 and not ssh's own 255.
transport_actual=0
transport_errlog=$(mktemp)
transport_start=$SECONDS
PATH="$(pwd)/scripts/tests/mock-ssh-hang-bin:$PATH" \
TMUX_SEND_TIMEOUT=1 scripts/tmux-send.sh --host fake-host --tmux tmux \
    dummy-session "review 221" >/dev/null 2>"$transport_errlog" || transport_actual=$?
transport_elapsed=$(( SECONDS - transport_start ))
transport_noise=""
if grep -qEi 'terminated|killed' "$transport_errlog" 2>/dev/null; then
    transport_noise="job notice on stderr"
fi
rm -f "$transport_errlog"
if [[ "$transport_actual" == 143 && "$transport_elapsed" -le 25 && -z "$transport_noise" ]]; then
    printf 'PASS  wedged ssh transport: +15s backstop converges, exit normalized to 143 (%ss, quiet stderr)\n' "$transport_elapsed"
    PASS=$((PASS + 1))
else
    printf 'FAIL  wedged ssh transport (expected exit 143 within 25s + quiet stderr, got exit %s in %ss%s)\n' "$transport_actual" "$transport_elapsed" "${transport_noise:+, $transport_noise}"
    FAIL=$((FAIL + 1))
fi

# Success must return the moment the dispatch finishes, even when the
# caller captures stdout in $( ) — a detached watchdog timer used to hold
# the substitution pipe open for the full TMUX_SEND_TIMEOUT after exit 0.
fast_session="tmux-send-test-$$-$RANDOM"
tmux new-session -d -s "$fast_session" "python3 scripts/tests/fake-tui.py" 2>/dev/null
sleep 0.3
fast_actual=0
fast_start=$SECONDS
fast_out=$(TMUX_SEND_TIMEOUT=30 scripts/tmux-send.sh --tmux tmux "$fast_session" "review 221" 2>/dev/null) || fast_actual=$?
fast_elapsed=$(( SECONDS - fast_start ))
tmux kill-session -t "$fast_session" 2>/dev/null || true
if [[ "$fast_actual" == 0 && "$fast_elapsed" -le 10 && "$fast_out" == *"len=10"* ]]; then
    printf 'PASS  success under $( ) returns immediately (%ss, no timer holding the pipe)\n' "$fast_elapsed"
    PASS=$((PASS + 1))
else
    printf 'FAIL  success under $( ) (expected exit 0 within 10s, got exit %s in %ss)\n' "$fast_actual" "$fast_elapsed"
    FAIL=$((FAIL + 1))
fi

# Invalid TMUX_SEND_TIMEOUT must be a usage error BEFORE dispatch — a
# non-numeric value would make the watchdog's `sleep` fail instantly and
# silently drop the hang protection.
flag_actual=0
TMUX_SEND_TIMEOUT=abc scripts/tmux-send.sh test-session "review 221" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  non-numeric TMUX_SEND_TIMEOUT returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  non-numeric TMUX_SEND_TIMEOUT (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

flag_actual=0
TMUX_SEND_TIMEOUT=0 scripts/tmux-send.sh test-session "review 221" >/dev/null 2>&1 || flag_actual=$?
if [[ "$flag_actual" == 2 ]]; then
    printf 'PASS  zero TMUX_SEND_TIMEOUT returns exit 2\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  zero TMUX_SEND_TIMEOUT (expected exit 2, got %s)\n' "$flag_actual"
    FAIL=$((FAIL + 1))
fi

# `text_at_input_line` only examines lines that start with a prompt glyph,
# so an exact `last_prompt == TEXT` branch contradicts the input shape. Keep
# the accepted forms explicit: prompt plus ASCII space, tab, or NBSP.
# TEXT must reach the pane via buffer paste (one atomic pty write) —
# per-char `send-keys -l` typing is what busy TUIs dropped whole
# messages from (kongkong#339). Only control keys (C-u, Enter) may use
# send-keys.
if grep -E '"\$TMUX_CMD" send-keys' scripts/tmux-send.sh | grep -q -- ' -l'; then
    printf 'FAIL  TEXT is still typed per-char with send-keys -l instead of buffer paste\n'
    FAIL=$((FAIL + 1))
else
    printf 'PASS  TEXT reaches the pane via buffer paste, not send-keys -l\n'
    PASS=$((PASS + 1))
fi

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
