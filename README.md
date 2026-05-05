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
claude-subagent logs hyperframes-video
claude-subagent stop hyperframes-video
```

For a bounded one-shot task:

```bash
claude-subagent run smoke-test --prompt task.md --workdir /path/to/project
```

## Tests

Run the deterministic fake-agent test suite:

```bash
tests/run-tests.sh
```

The tests put a fake `claude` binary first on `PATH` and use `CLAUDE_SUBAGENT_HOME` to isolate all task state in a temporary directory.

## Design Principles

- Offload only on explicit user request.
- Always provide Claude with a written handoff.
- Prefer isolated worktrees for repo edits.
- Capture enough transcript data to audit results.
- Never merge external agent work blindly.
