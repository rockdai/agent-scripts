"""TUI that accepts the first 2 text chars, then drops chars 3-10 of the
first send. From char 11 onward (the retry attempt) it accepts everything.
Used to verify tmux-send.sh's C-u + retry self-heal:

  1. First `send-keys -l "review 221"` (10 chars) — chars 1-2 land ("re"),
     chars 3-10 dropped. buf = "re".
  2. tmux-send.sh's pre-Enter verify sees `> re` — predicate fails.
  3. tmux-send.sh sends C-u (kill-line), this fixture clears buf and
     redraws `> ` (counter is unchanged, real TUIs treat C-u as a line
     edit not a typed char).
  4. tmux-send.sh re-sends "review 221" (10 more chars, counter now 11-20,
     all accepted). buf = "review 221", display `> review 221`.
  5. Pre-Enter verify matches → exit 0.

The fix this fixture guards: C-u between retry attempts prevents partial-
prefix concatenation (`rereview 221` corruption) AND lets the script
self-heal when the first send only partially landed."""

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
        char_count = 0
        buf: list[str] = []
        while True:
            c = sys.stdin.read(1)
            if not c:
                break
            if c in ("\r", "\n"):
                sys.stdout.write("\r\033[K")
                sys.stdout.write(f"[SUBMIT len={len(buf)}]\n> ")
                sys.stdout.flush()
                buf = []
                continue
            if c == "\x15":  # Ctrl+U: kill-line, doesn't count as a typed char
                buf = []
                sys.stdout.write("\r\033[K> ")
                sys.stdout.flush()
                continue
            char_count += 1
            # First send of 10-char text: accept chars 1-2, drop chars 3-10.
            # Anything from char 11 onward (the retry) is accepted fully.
            if 3 <= char_count <= 10:
                continue
            buf.append(c)
            sys.stdout.write(c)
            sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
