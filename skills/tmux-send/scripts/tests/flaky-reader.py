"""TUI that silently drops every 3rd char, reproducing the partial-text
failure mode observed when an agent TUI eats chars under load. Used by
test-tmux-send.sh to lock tmux-send.sh's pre-Enter verification: the
script must detect that the full text never landed and exit 3, not
silently return 0 with a truncated dispatch."""

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
        i = 0
        buf = []
        while True:
            c = sys.stdin.read(1)
            if not c:
                break
            # C-u always processed (real TUIs treat it as a control-line edit
            # not a typed char). Don't count it toward the every-3rd-drop logic.
            if c == "\x15":
                buf = []
                sys.stdout.write("\r\033[K> ")
                sys.stdout.flush()
                continue
            i += 1
            if i % 3 == 0:
                continue
            if c in ("\r", "\n"):
                sys.stdout.write("\r\033[K")
                sys.stdout.write(f"[SUBMIT len={len(buf)}]\n> ")
                sys.stdout.flush()
                buf = []
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
