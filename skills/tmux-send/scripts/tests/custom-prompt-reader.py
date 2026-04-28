"""TUI that uses a project-specific prompt token and Unicode separator.

The default prompt matcher intentionally stays conservative to avoid
matching ordinary log lines as input prompts. This fixture verifies that
callers can opt into a custom prompt regex, including one that starts
with a dash, without editing tmux-send.sh.
"""

import sys
import termios
import tty


PROMPT = "->\u2007"  # Dash prompt + figure space.


def main() -> None:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write(PROMPT)
        sys.stdout.flush()
        buf = []
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
