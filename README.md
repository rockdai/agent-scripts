# Agent scripts

Scripts for agents, shared between my repositories.

## Skills

- `skills/pr-feedback`: process pull request review feedback as the PR author.
- `skills/pr-review`: perform a full independent pull request review.
- `skills/pr-recheck`: re-evaluate a pull request after author changes or replies.
- `skills/merge-sync`: synchronize local agent workspaces after a pull request merge.
- `skills/issue-check`: verify and handle work from an issue.
- `skills/review-notify`: notify a reviewer agent that a pull request needs review or recheck.
- `skills/tmux-send`: reliable one-line signaling between independent agent sessions through tmux.
- `skills/spells`: conventions for short trigger phrases (such as `pr N`, `review N`, `merged`) that route an agent into a standard workflow.

Each skill follows the `SKILL.md` folder format so projects can vendor, symlink, or install the skills into the agent runtime they use.
