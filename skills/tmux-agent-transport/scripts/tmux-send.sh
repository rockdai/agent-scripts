#!/usr/bin/env bash
# tmux-send.sh — send text to a tmux pane and make sure it actually lands.
#
# Naive `tmux send-keys -t T "text" Enter` races against TUI render ticks
# (Codex CLI, Claude Code, Gemini CLI, etc.) two ways:
#   1. Enter fires before the typed text commits → the command stays
#      stranded in the input box (the original motivating bug).
#   2. The TUI ingests part of the text, then Enter catches whatever is
#      already in its buffer → a truncated spell submits silently, and a
#      naive "did the text disappear from pane" check returns success.
#
# This script handles both: it sends the literal text, polls
# `capture-pane` until the full text appears in the input area, *then*
# sends Enter, and polls again until the text leaves the input line.
# Any step that won't converge exits 3 so the caller knows to intervene.
#
# Usage:
#   scripts/tmux-send.sh [--host HOST] [--tmux PATH] [--no-verify] TARGET TEXT
#
# Flags:
#   --host HOST     run tmux over SSH on HOST (omit for local tmux)
#   --tmux PATH     tmux binary path on target (default: /opt/homebrew/bin/tmux,
#                   the homebrew install location; override when the target box
#                   has tmux elsewhere)
#   --no-verify     skip the post-Enter verification (fire-and-forget);
#                   pre-Enter verification still runs
#
# Examples:
#   # Local session
#   scripts/tmux-send.sh my-session "build frontend"
#
#   # Remote review-agent dispatch
#   scripts/tmux-send.sh --host review-host review-session "recheck 219"
#
# Exit codes:
#   0 — sent (and if verified, confirmed submitted)
#   2 — usage error
#   3 — text never fully landed in input area, or still stuck after retry
#   other non-zero — propagated from underlying commands when set -e fires
#                    (ssh auth/connect failure: 255; tmux target not found / not
#                    on PATH: 1 / 127). Treat any non-zero exit as failure.

set -euo pipefail

help_text() {
    # Emit the leading comment block (everything after the shebang up to
    # the first non-comment line) with the `# ` prefix stripped. Avoids
    # hardcoded line ranges, which drift whenever the header is edited.
    awk 'NR == 1 { next }
         /^#/   { sub(/^# ?/, ""); print; next }
                { exit }' "$0"
}

usage_error() {
    # User passed something invalid. Print help to stderr and exit 2 so
    # callers can distinguish "you asked for help" (exit 0, see -h/--help)
    # from "you invoked us wrong" (exit 2, this path).
    help_text >&2
    exit 2
}

HOST=""
TMUX_BIN="/opt/homebrew/bin/tmux"
VERIFY=1

# require_arg checks that flag $1 has a non-flag value at $2; exits 2 if
# the value is missing OR starts with `-` (which usually means the user
# forgot a value and the parser is about to silently swallow the next
# flag — e.g. `tmux-send.sh --host --no-verify dummy text` would set
# HOST=--no-verify under a naive `[[ $# -lt 2 ]]` check). Avoids both
# the `set -u` unbound-variable crash and the silent flag mis-parse.
require_arg() {
    if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
        echo "tmux-send: $1 requires a value (got: ${2:-<nothing>})" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       require_arg "$@"; HOST="$2"; shift 2 ;;
        --tmux)       require_arg "$@"; TMUX_BIN="$2"; shift 2 ;;
        --no-verify)  VERIFY=0; shift ;;
        -h|--help)    help_text; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "tmux-send: unknown flag: $1" >&2; usage_error ;;
        *)            break ;;
    esac
done

[[ $# -eq 2 ]] || usage_error
TARGET="$1"
TEXT="$2"

case "$TEXT" in
    *$'\n'*|*$'\r'*)
        # Reject both LF and CR. CR also acts like Enter in many TUIs,
        # so smuggling `\r` past validation would let TEXT contain a
        # mid-string submit and break the single-line spell contract.
        echo "tmux-send: TEXT cannot contain newlines or carriage returns" >&2
        exit 2
        ;;
esac

REMOTE_BODY=$(cat <<'REMOTE'
set -euo pipefail
# Do NOT name this TMUX — that variable is reserved: tmux client reads
# it to resolve the containing session, and TMUX_CMD is a binary path.
unset TMUX

# True if TEXT is the trailing content of the CURRENT input line.
#
# "Current input line" = the LAST non-blank pane line whose first
# non-whitespace char is a prompt glyph (`> $ › ❯`). Anchoring to the
# last prompt line — instead of "anywhere in the bottom N rows" — is
# load-bearing for two distinct failure modes:
#
#   1. Partial-then-full corruption: attempt 1 of `send-keys -l` lands
#      "re", attempt 2 retypes "review 221" → input buffer becomes
#      "rereview 221". Substring `grep -qF "review 221"` would pass on
#      this corrupted line; the end-of-line `*" $TEXT"` / `== $TEXT`
#      check below rejects it because the char before "review 221" is
#      "e" (from "rereview"), not space.
#
#   2. Stale echo from a prior dispatch: the prior `> review 221` is
#      still visible in the bottom rows, the new `send-keys -l` drops
#      every char, but a "match anywhere in last 5 rows" check would
#      false-positive on the stale echo. Anchoring to the LAST prompt
#      line makes the new (empty) prompt line the comparison target,
#      because the stale echo lives ABOVE the freshly drawn prompt.
#
# Separator scope: ASCII space, tab, or NBSP (U+00A0) between prompt
# glyph and TEXT. Different TUIs pad the input area differently — Claude
# Code / Gemini CLI use ASCII space, Codex CLI uses NBSP, some box-framed
# TUIs use tab. Each accepted form has its own bash glob branch in
# `text_at_input_line` below; if a future TUI uses yet another separator
# (en/em space, etc.), add a new branch matching its byte sequence.
#
# Used for both pre-Enter verification (has the typed text landed at the
# end of the input line?) and post-Enter verification (has it left the
# input line?).
text_at_input_line() {
    # Find the LAST non-blank line in the pane whose first non-whitespace
    # char is a prompt glyph (`> $ › ❯`), then check if it ends with TEXT.
    #
    # `grep -E` with the alternation handles the multi-byte UTF-8 chars
    # (›, ❯) by byte sequence; awk strips blank pad lines first because
    # `capture-pane -p` pads up to the pane's row count with trailing
    # blanks. `|| true` swallows grep's exit-1 on no-match so it doesn't
    # trip `set -e`.
    #
    # End match accepts TEXT alone OR preceded by ASCII space / tab / NBSP
    # (U+00A0, UTF-8 bytes c2 a0). Different TUIs pad the input differently:
    # Claude Code / Gemini CLI use ASCII space; Codex CLI uses NBSP between
    # the prompt glyph and the input buffer; some box-framed TUIs use tab.
    # The C-u clear at the top of each retry attempt guarantees the input
    # is `[prompt][sep]TEXT` exactly when our send lands, so a permissive
    # whitespace predicate is safe — there's no leftover to concatenate.
    local last_prompt
    last_prompt=$("$TMUX_CMD" capture-pane -p -t "$TARGET" \
        | awk 'NF' \
        | grep -E '^[[:space:]]*(>|\$|›|❯)' \
        | tail -n 1) || true
    [[ -z "$last_prompt" ]] && return 1
    [[ "$last_prompt" == "$TEXT" ]] && return 0
    [[ "$last_prompt" == *" $TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\t'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xc2\xa0'"$TEXT" ]] && return 0
    return 1
}

# --- Pre-Enter: send text, confirm it reached the input line ---

# Up to 3 attempts. Each attempt:
#   1. Sends C-u (kill-line) to clear any leftover from a prior dispatch
#      OR a previous retry that partially landed. Without this, a TUI
#      that drops chars under render pressure leaves a partial typed
#      prefix that the next send-keys concatenates onto, producing
#      `❯ pr 221pr 221pr 221` style corruption that exits 3 with a
#      dirty input box.
#   2. Sends the literal text once.
#   3. Polls for up to 2 seconds (10 * 0.2s) for `text_at_input_line`
#      to confirm. On timeout, the next attempt's C-u re-clears.
#
# Worst case: 3 C-u + 3 send-keys; final pane state is clean even on
# exit 3 (the last C-u + send leaves at most one TEXT in the input box,
# never a concatenation).
landed=0
for send_attempt in 1 2 3; do
    "$TMUX_CMD" send-keys -t "$TARGET" C-u
    sleep 0.1
    "$TMUX_CMD" send-keys -t "$TARGET" -l "$TEXT"
    for tick in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.2
        if text_at_input_line; then
            landed=1
            break 2
        fi
    done
done

if [[ "$landed" -eq 0 ]]; then
    echo "tmux-send: TEXT never reached '$TARGET' input after 3 attempts" >&2
    exit 3
fi

# --- Enter: submit ---

"$TMUX_CMD" send-keys -t "$TARGET" Enter

[[ "$VERIFY" == "1" ]] || exit 0

# --- Post-Enter: confirm text left the input line ---

# Same anchor as pre-Enter — assert the LAST prompt line no longer ends
# with TEXT. Polling tolerates the brief moment between Enter being
# delivered and the TUI redrawing a fresh prompt below the submitted
# command. One Enter retry on timeout for TUIs that need a second Enter
# to actually submit.
submitted=0
for tick in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    if ! text_at_input_line; then
        submitted=1
        break
    fi
done

if [[ "$submitted" -eq 0 ]]; then
    "$TMUX_CMD" send-keys -t "$TARGET" Enter
    sleep 1
    if text_at_input_line; then
        echo "tmux-send: TEXT still on input line in '$TARGET' after retry" >&2
        exit 3
    fi
fi
REMOTE
)

run() {
    # Build the remote script with args inlined as shell-escaped variable
    # assignments instead of positional args via `bash -s -- a b "c d" e`.
    # openssh joins its argv[2:] with spaces into a single string before
    # sending, so remote shell re-tokenizes "c d" into two args, silently
    # truncating TEXT. printf '%q' produces a shell-safe literal that
    # survives the round-trip intact. Script body is delivered on stdin.
    local prefix script
    printf -v prefix 'TMUX_CMD=%q\nTARGET=%q\nTEXT=%q\nVERIFY=%q\n' \
        "$TMUX_BIN" "$TARGET" "$TEXT" "$VERIFY"
    script="$prefix$REMOTE_BODY"

    if [[ -n "$HOST" ]]; then
        # BatchMode=yes: never prompt for password / passphrase / new host
        # key — fail fast instead of hanging an automation dispatch waiting
        # for stdin no caller is going to provide. ConnectTimeout=10: same
        # idea against an unreachable host. Host-key bootstrap is a one-time
        # interactive `ssh` per new peer before relying on automation.
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash <<<"$script"
    else
        # Unset the ambient TMUX env so that tmux client resolves the
        # default socket, not the one pointing at our outer session.
        env -u TMUX bash <<<"$script"
    fi
}

run
echo "tmux-send: sent '$TEXT' → $TARGET${HOST:+ on $HOST}"
