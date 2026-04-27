"""Minimal TUI that echoes each typed char and clears its input line on
Enter. This models the happy path for agent TUIs that echo typed input.

Used by test-tmux-send.sh to verify the happy path of tmux-send.sh."""

import sys
import termios
import tty


def main() -> None:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write("> ")
        sys.stdout.flush()
        buf = []
        while True:
            c = sys.stdin.read(1)
            if not c:
                break
            if c in ("\r", "\n"):
                sys.stdout.write("\r\033[K")
                sys.stdout.write(f"[SUBMIT len={len(buf)}]\n> ")
                sys.stdout.flush()
                buf = []
            elif c == "\x15":  # Ctrl+U: kill-line, clear buf and redraw prompt
                buf = []
                sys.stdout.write("\r\033[K> ")
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
