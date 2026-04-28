#!/usr/bin/env bash
# tmux-send.sh — send text to a tmux pane and make sure it actually lands.
#
# Naive `tmux send-keys -t T "text" Enter` races against agent TUI render ticks
# two ways:
#   1. Enter fires before the typed text commits → the command stays
#      stranded in the input box (the original motivating bug).
#   2. The TUI ingests part of the text, then Enter catches whatever is
#      already in its buffer → a truncated message submits silently, and a
#      naive "did the text disappear from pane" check returns success.
#
# This script handles both: it sends the literal text, polls
# `capture-pane` until the full text appears in the input area, *then*
# sends Enter, and polls again until the text leaves the input line.
# Any step that won't converge exits 3 so the caller knows to intervene.
#
# Usage:
#   scripts/tmux-send.sh [--host HOST] [--tmux PATH] [--prompt-regex ERE]
#                       [--prompt-regex=ERE]
#                       [--no-verify] TARGET TEXT
#
# Flags:
#   --host HOST     run tmux over SSH on HOST (omit for local tmux)
#   --tmux PATH     tmux binary path on target (default: tmux from PATH, then
#                   /opt/homebrew/bin/tmux if present)
#   --prompt-regex ERE, --prompt-regex=ERE
#                   extended regex for the prompt glyph/token that starts the
#                   target TUI input line (default: >|\$|›|❯)
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
TMUX_BIN="__AUTO__"
PROMPT_REGEX='>|\$|›|❯'
VERIFY=1

# require_arg checks that flag $1 has a non-empty, non-flag value at $2;
# exits 2 if the value is missing, empty, OR starts with `-` (which usually
# means the user forgot a value and the parser is about to silently swallow
# the next flag — e.g. `tmux-send.sh --host --no-verify dummy text` would
# set HOST=--no-verify under a naive `[[ $# -lt 2 ]]` check). Avoids both
# the `set -u` unbound-variable crash and the silent flag mis-parse.
require_arg() {
    if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == -* ]]; then
        echo "tmux-send: $1 requires a value (got: ${2:-<nothing>})" >&2
        exit 2
    fi
}

require_prompt_regex_arg() {
    if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == --* ]]; then
        echo "tmux-send: $1 requires a value (got: ${2:-<nothing>})" >&2
        exit 2
    fi
}

set_prompt_regex() {
    if [[ -z "$1" ]]; then
        echo "tmux-send: --prompt-regex requires a non-empty value" >&2
        exit 2
    fi
    PROMPT_REGEX="$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)          require_arg "$@"; HOST="$2"; shift 2 ;;
        --tmux)          require_arg "$@"; TMUX_BIN="$2"; shift 2 ;;
        --prompt-regex=*) set_prompt_regex "${1#--prompt-regex=}"; shift ;;
        --prompt-regex)  require_prompt_regex_arg "$@"; set_prompt_regex "$2"; shift 2 ;;
        --no-verify)     VERIFY=0; shift ;;
        -h|--help)       help_text; exit 0 ;;
        --)              shift; break ;;
        -*)              echo "tmux-send: unknown flag: $1" >&2; usage_error ;;
        *)               break ;;
    esac
done

[[ $# -eq 2 ]] || usage_error
TARGET="$1"
TEXT="$2"

if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    echo "tmux-send: TEXT cannot be empty or whitespace-only" >&2
    exit 2
fi

case "$TEXT" in
    *$'\n'*|*$'\r'*)
        # Reject both LF and CR. CR also acts like Enter in many TUIs,
        # so smuggling `\r` past validation would let TEXT contain a
        # mid-string submit and break the single-line message contract.
        echo "tmux-send: TEXT cannot contain newlines or carriage returns" >&2
        exit 2
        ;;
esac

validate_prompt_regex() {
    local status

    case "$PROMPT_REGEX" in
        *$'\n'*|*$'\r'*)
            echo "tmux-send: --prompt-regex cannot contain newlines or carriage returns" >&2
            exit 2
            ;;
    esac

    set +e
    printf '\n' | grep -E -- "^[[:space:]]*($PROMPT_REGEX)" >/dev/null 2>&1
    status=$?
    set -e

    if [[ "$status" -gt 1 ]]; then
        echo "tmux-send: invalid --prompt-regex: $PROMPT_REGEX" >&2
        exit 2
    fi
}

validate_prompt_regex

REMOTE_BODY=$(cat <<'REMOTE'
set -euo pipefail
# Do NOT name this TMUX — that variable is reserved: tmux client reads
# it to resolve the containing session, and TMUX_CMD is a binary path.
unset TMUX

if [[ "$TMUX_CMD" == "__AUTO__" ]]; then
    if command -v tmux >/dev/null 2>&1; then
        TMUX_CMD="$(command -v tmux)"
    elif [[ -x /opt/homebrew/bin/tmux ]]; then
        TMUX_CMD="/opt/homebrew/bin/tmux"
    else
        TMUX_CMD="tmux"
    fi
fi

# True if TEXT is the trailing content of the CURRENT input line.
#
# "Current input line" = the LAST non-blank pane line whose first
# non-whitespace chars match PROMPT_REGEX. Anchoring to the last prompt
# line — instead of "anywhere in the bottom N rows" — is load-bearing for
# two distinct failure modes:
#
#   1. Partial-then-full corruption: attempt 1 of `send-keys -l` lands
#      "re", attempt 2 retypes "review 221" → input buffer becomes
#      "rereview 221". Substring `grep -qF "review 221"` would pass on
#      this corrupted line; the separator-sensitive end-of-line checks
#      below reject it because the char before "review 221" is "e" (from
#      "rereview"), not a supported prompt/input separator.
#
#   2. Stale echo from a prior dispatch: the prior `> review 221` is
#      still visible in the bottom rows, the new `send-keys -l` drops
#      every char, but a "match anywhere in last 5 rows" check would
#      false-positive on the stale echo. Anchoring to the LAST prompt
#      line makes the new (empty) prompt line the comparison target,
#      because the stale echo lives ABOVE the freshly drawn prompt.
#
# Separator scope: ASCII space, tab, and common Unicode spaces between
# prompt and TEXT. Different TUIs pad the input area differently: some use
# ASCII space, some use NBSP, and some box-framed TUIs use tab. Each
# accepted form has its own bash glob branch in `text_at_input_line`
# below. If a future TUI uses a different prompt token, pass
# --prompt-regex instead of editing this script.
#
# Used for both pre-Enter verification (has the typed text landed at the
# end of the input line?) and post-Enter verification (has it left the
# input line?).
text_at_input_line() {
    # Find the LAST non-blank line in the pane whose first non-whitespace
    # chars match PROMPT_REGEX, then check if it ends with TEXT.
    #
    # `grep -E` with the alternation handles the multi-byte UTF-8 chars
    # (›, ❯) by byte sequence; awk strips blank pad lines first because
    # `capture-pane -p` pads up to the pane's row count with trailing
    # blanks. `|| true` swallows grep's exit-1 on no-match so it doesn't
    # trip `set -e`.
    #
    # End match accepts TEXT preceded by ASCII space / tab / common Unicode
    # spaces. Different TUIs pad the input differently: some use ASCII
    # space, some use NBSP between the prompt glyph and the input buffer,
    # and some box-framed TUIs use tab.
    # The C-u clear at the top of each retry attempt guarantees the input
    # is `[prompt][sep]TEXT` exactly when our send lands, so a permissive
    # whitespace predicate is safe — there's no leftover to concatenate.
    local grep_status last_prompt pane prompt_lines
    pane=$("$TMUX_CMD" capture-pane -p -t "$TARGET")

    set +e
    prompt_lines=$(printf '%s\n' "$pane" \
        | awk 'NF' \
        | grep -E -- "^[[:space:]]*($PROMPT_REGEX)")
    grep_status=$?
    set -e

    if [[ "$grep_status" -eq 1 ]]; then
        return 1
    elif [[ "$grep_status" -gt 1 ]]; then
        echo "tmux-send: invalid --prompt-regex: $PROMPT_REGEX" >&2
        exit 2
    fi

    last_prompt=$(printf '%s\n' "$prompt_lines" | tail -n 1)
    [[ -z "$last_prompt" ]] && return 1
    [[ "$last_prompt" == *" $TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\t'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xc2\xa0'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe2\x80\x82'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe2\x80\x83'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe2\x80\x87'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe2\x80\x89'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe2\x80\xaf'"$TEXT" ]] && return 0
    [[ "$last_prompt" == *$'\xe3\x80\x80'"$TEXT" ]] && return 0
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
    printf -v prefix 'TMUX_CMD=%q\nTARGET=%q\nTEXT=%q\nVERIFY=%q\nPROMPT_REGEX=%q\n' \
        "$TMUX_BIN" "$TARGET" "$TEXT" "$VERIFY" "$PROMPT_REGEX"
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
echo "tmux-send: sent len=${#TEXT} to $TARGET${HOST:+ on $HOST}"
