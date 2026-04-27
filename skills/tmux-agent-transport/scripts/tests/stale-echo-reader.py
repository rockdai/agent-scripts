"""TUI that starts with a stale `> review 221` echo from a "prior dispatch"
already visible in the pane, then drops every char typed by this attempt's
`send-keys -l`. On Enter it submits an empty buffer and prints enough status
lines to push the stale echo out of the post-Enter check's small window.

This reproduces the failure qa-agent raised on PR #221 head 6273c3e:

  1. tmux-send.sh polls `text_in_bottom 5` after `send-keys -l "review 221"`.
  2. The stale `> review 221` from a prior dispatch is still in those 5
     rows, so the bottom-window predicate falsely returns TRUE even though
     no new char actually landed in the input buffer.
  3. The script presses Enter on the empty buffer, the stub printed
     status lines scroll the stale echo out of the 3-row post-Enter
     window, post-check thinks the text "left" the input → exit 0.
  4. The caller never learns its spell was eaten.

Fix this fixture guards: the pre-Enter (and post-Enter) verify must anchor
to the CURRENT input line specifically — i.e. the LAST line in the pane
whose first non-whitespace char is a prompt character (`> $ › ❯`). With
that anchor, the stale echo is "above" the new empty prompt line, so it
no longer matches; the script must exit 3 instead of submitting silently."""

import sys
import termios
import tty


def main() -> None:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        # Pretend a previous dispatch already echoed `> review 221` and
        # the TUI then drew a fresh prompt below it.
        sys.stdout.write("> review 221\n> ")
        sys.stdout.flush()
        while True:
            c = sys.stdin.read(1)
            if not c:
                break
            if c in ("\r", "\n"):
                # "Submit" with whatever's in the buffer (empty, since we
                # dropped everything). Then push status lines so the stale
                # `> review 221` scrolls out of the post-Enter check's
                # small bottom window — emulating a real TUI that draws
                # output between submit and the next prompt.
                sys.stdout.write("\r\033[K")
                for i in range(5):
                    sys.stdout.write(f"[status {i}]\n")
                sys.stdout.write("[SUBMIT len=0]\n> ")
                sys.stdout.flush()
            # Drop everything else — modeling a TUI that fully eats
            # typed chars (Codex CLI under heavy render-tick pressure).
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
