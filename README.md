# Claude Subagent

Claude Subagent is a local bridge for launching Claude Code as an external sub-agent from a Codex session.

The goal is to make offloading explicit, inspectable, and easy to integrate:

- Codex writes a structured handoff packet.
- `claude-subagent` starts Claude Code in an isolated task workspace.
- Logs, prompts, and completion reports are stored in predictable locations.
- Codex can check status, review output, and integrate changes only after inspection.

## Status

This repository is the starting point for the bridge. The initial implementation will focus on:

- CLI process management around Claude Code.
- `tmux` backed background jobs.
- task directories under `~/.claude-subagents`.
- optional git worktree isolation.
- a Codex skill that defines the operating procedure.

See [docs/implementation-plan.md](docs/implementation-plan.md) for the detailed build and test plan.

## Intended Usage

```bash
bin/claude-subagent init

claude-subagent start hyperframes-video --prompt task.md --workdir /path/to/project
claude-subagent status hyperframes-video
claude-subagent result hyperframes-video
claude-subagent logs hyperframes-video
claude-subagent inspect hyperframes-video
claude-subagent stop hyperframes-video
```

For a bounded one-shot task:

```bash
claude-subagent run smoke-test --prompt task.md --workdir /path/to/project
```

For non-interactive edit tasks, opt in to Claude Code's edit-accepting permission mode:

```bash
claude-subagent run smoke-test --prompt task.md --workdir /path/to/project --permission-mode acceptEdits
```

For repo-editing tasks, prefer an isolated git worktree:

```bash
claude-subagent run smoke-test --prompt task.md --workdir /path/to/project --worktree --permission-mode acceptEdits
```

This creates a worktree at `~/.claude-subagents/worktrees/<task-name>` on branch `claude-subagent/<task-name>`, records the source repo and dirty state, and runs Claude in the isolated checkout.

Use `result` for the clean final response extracted from Claude's stream-json transcript:

```bash
claude-subagent result smoke-test
```

Raw stdout and stderr remain available through `logs`.

Use `inspect` for the high-signal task summary:

```bash
claude-subagent inspect smoke-test
```

Use `diff` for review before integrating any generated work. It reports tracked, staged, and untracked files, and prints small text-file contents for new untracked files:

```bash
claude-subagent diff smoke-test
```

Use `cleanup` to remove task state after review:

```bash
claude-subagent cleanup smoke-test
```

For isolated worktree tasks, explicitly opt in to deleting the worktree and branch. Add `--force` when discarding dirty generated work:

```bash
claude-subagent cleanup smoke-test --worktree --branch --force
```

## Tests

Run the deterministic fake-agent test suite:

```bash
tests/run-tests.sh
```

The tests put a fake `claude` binary first on `PATH` and use `CLAUDE_SUBAGENT_HOME` to isolate all task state in a temporary directory.

## Codex Skill

The Codex skill source lives at [skills/claude-subagent/SKILL.md](skills/claude-subagent/SKILL.md). For this machine, it is also installed at:

```text
~/.codex/skills/claude-subagent/SKILL.md
```

## Design Principles

- Offload only on explicit user request.
- Always provide Claude with a written handoff.
- Prefer isolated worktrees for repo edits.
- Capture enough transcript data to audit results.
- Never merge external agent work blindly.
