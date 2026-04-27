# agent-scripts

Reusable scripts and skills for agent workflows across repositories.

## Skills

- `skills/tmux-agent-transport`: reliable one-line signaling between independent agent sessions through tmux.
- `skills/address-pr-feedback`: fetch, judge, fix, and reply to pull request review feedback.

Each skill follows the `SKILL.md` folder format so projects can vendor, symlink, or install the skills into the agent runtime they use.
