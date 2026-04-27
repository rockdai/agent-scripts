"""TUI that uses U+00A0 NBSP (UTF-8 bytes c2 a0) as the separator between
the prompt glyph and the input buffer. Some agent TUIs render this shape
during agent-to-agent dispatch.

`capture-pane -p` shows the input line as `❯\xa0pr 221`, NOT
`❯ pr 221` (ASCII space). The earlier `*" $TEXT"` predicate missed
this, so tmux-send.sh exited 3 even though the text visibly landed.

This fixture locks the fix: `text_at_input_line` must accept NBSP between
the prompt glyph and TEXT, in addition to ASCII space and tab."""

import sys
import termios
import tty


# Build the prompt prefix at module level using explicit codepoints, so
# there is zero chance the source file's "space" character is a regular
# ASCII space instead of the NBSP we want to test against.
PROMPT = "❯ "  # ❯ (U+276F) + NBSP (U+00A0)


def main() -> None:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write(PROMPT)
        sys.stdout.flush()
        buf: list[str] = []
        while True:
            c = sys.stdin.read(1)
            if not c:
                break
            if c in ("\r", "\n"):
                sys.stdout.write("\r\033[K")
                sys.stdout.write(f"[SUBMIT len={len(buf)}]\n{PROMPT}")
                sys.stdout.flush()
                buf = []
            elif c == "\x15":  # Ctrl+U: kill-line, clear buf and redraw prompt
                buf = []
                sys.stdout.write(f"\r\033[K{PROMPT}")
                sys.stdout.flush()
            elif c in ("\x7f", "\b"):
                if buf:
                    buf.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
            else:
                buf.append(c)
                sys.stdout.write(c)
                sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
