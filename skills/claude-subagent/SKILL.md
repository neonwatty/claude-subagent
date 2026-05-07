---
name: claude-subagent
description: Use when the user explicitly asks Codex to offload work to Claude, Claude Code, a Claude sub-agent, or an external agent via the local claude-subagent CLI. Provides the handoff, launch, monitoring, and review workflow for delegating work from Codex to Claude Code.
---

# Claude Subagent

Use this skill only when the user explicitly asks to offload, delegate, spin up Claude, or use Claude as a sub-agent. Do not use it just because a task is large.

## Workflow

1. Confirm the task boundary from the conversation.
2. Choose a task name with only letters, numbers, dots, underscores, or hyphens.
3. Create a handoff prompt file that includes:
   - objective
   - working directory
   - allowed edit paths
   - forbidden edit paths
   - expected deliverables
   - commands Claude may run
   - completion report path
   - instruction to stop after the scoped task
4. Run Claude through the wrapper:

```bash
claude-subagent run <task-name> --prompt <prompt-file> --workdir <path>
```

For non-interactive edit tasks, add `--permission-mode acceptEdits` only when the user has explicitly asked Claude to make edits.

For repo-editing tasks, prefer `--worktree`:

```bash
claude-subagent run <task-name> --prompt <prompt-file> --workdir <path> --worktree --permission-mode acceptEdits
```

Use `--timeout <duration>` for bounded work, especially exploratory or creative tasks. Durations accept `s`, `m`, or `h`, for example `--timeout 10m`.

Use `start` instead of `run` for longer work:

```bash
claude-subagent start <task-name> --prompt <prompt-file> --workdir <path>
```

5. Inspect the result:

```bash
claude-subagent status <task-name>
claude-subagent result <task-name>
claude-subagent logs <task-name>
claude-subagent inspect <task-name>
claude-subagent diff <task-name>
```

6. Review Claude's result, report, logs, and diff before integrating any output.
7. If the user approves specific output, integrate only those paths:

```bash
claude-subagent integrate <task-name> --path <relative-path>
```

## Rules

- Never offload without explicit user instruction.
- Prefer isolated git worktrees for repo-editing tasks.
- Keep the handoff prompt precise and bounded.
- Use timeouts for tasks likely to sprawl; a timed-out task exits `124` and should be reviewed before retrying.
- Do not give Claude permission to edit unrelated files.
- Do not auto-merge, auto-commit, or auto-push Claude's changes unless the user explicitly asks.
- Treat Claude output as untrusted until Codex reviews the transcript, report, and diff.
- Use `diff` to review tracked, staged, and untracked generated files; small new text files are printed inline.
- Use `integrate` only for user-approved relative paths. Do not integrate the whole worktree by default.
- Use `cleanup <task-name>` only after review. Add `--worktree --branch --force` only when the user wants to discard the isolated worktree and generated changes.
- If Claude fails or produces ambiguous results, summarize the failure and ask for direction before retrying with broader permissions.

## Storage

By default, task state is stored under:

```text
~/.claude-subagents/tasks/<task-name>/
```

Use `CLAUDE_SUBAGENT_HOME` only for tests or temporary isolated runs.
