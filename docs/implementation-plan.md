# Implementation Plan

This project turns Claude Code into an external sub-agent that Codex can launch at the user's explicit request.

## Goals

- Provide a stable `claude-subagent` command for Codex to call.
- Use Claude Code's existing CLI features instead of reimplementing agent runtime behavior.
- Store every task's prompt, logs, metadata, and report in predictable locations.
- Support both synchronous and background offloads.
- Prefer isolated workspaces for tasks that may edit files.
- Make integration reviewable by Codex before any changes are accepted into the user's active work.

## Non-Goals

- Do not make Claude an invisible always-on worker.
- Do not auto-merge, auto-commit, or auto-push Claude's changes without an explicit command.
- Do not bypass Claude Code permissions by default.
- Do not replace Codex's built-in sub-agents; this is a bridge to an external tool.

## Runtime Model

Codex remains the orchestrator. Claude Code is launched as a subordinate process with a written task packet.

```text
user request
  -> Codex creates handoff packet
    -> claude-subagent starts Claude Code
      -> Claude works in task workspace
        -> claude-subagent captures logs and metadata
          -> Codex reviews report and diff
```

## Storage Layout

Default base directory:

```text
~/.claude-subagents/
  tasks/
    <task-name>/
      prompt.md
      metadata.json
      stdout.log
      stderr.log
      report.md
      pid
      exit-code
      workdir
  worktrees/
    <task-name>/
```

If a task uses an isolated worktree, the worktree path should be recorded in `workdir`.

## CLI Surface

### `init`

Creates the base directory structure and validates prerequisites.

```bash
claude-subagent init
```

Checks:

- `claude` exists.
- `tmux` exists for background mode.
- `git` exists for worktree mode.
- base storage directory is writable.

### `run`

Runs a short task synchronously and exits with Claude's result code.

```bash
claude-subagent run <task-name> --prompt <file> --workdir <path>
```

Use `--worktree` for isolated repo edits:

```bash
claude-subagent run <task-name> --prompt <file> --workdir <path> --worktree --permission-mode acceptEdits
```

Initial Claude invocation:

```bash
claude "<prompt contents>" --print --verbose --output-format stream-json --add-dir "<task dir>"
```

The wrapper should execute from `--workdir`, tee stdout and stderr to task logs, and write the final exit code.

### `start`

Starts a longer task in the background.

```bash
claude-subagent start <task-name> --prompt <file> --workdir <path>
```

Implementation options:

- Preferred first implementation: our wrapper starts a named `tmux` session and runs Claude inside it.
- Later option: delegate to Claude Code's native `--worktree --tmux` support when it gives us the control and logs we need.

The command should return quickly after recording the session name and initial metadata.

### `status`

Reports whether a task is running, completed, failed, or unknown.

```bash
claude-subagent status <task-name>
```

Sources:

- `tmux has-session` for background tasks.
- `exit-code` file for completed tasks.
- `metadata.json` for creation time, workdir, and mode.

### `logs`

Prints or tails the captured transcript.

```bash
claude-subagent logs <task-name>
claude-subagent logs <task-name> --tail
```

For `tmux` tasks, this can combine captured pane output with log files.

### `diff`

Shows the git diff for a task workdir.

```bash
claude-subagent diff <task-name>
```

This should refuse to run when the recorded workdir is not a git repository.

### `stop`

Stops a running background task.

```bash
claude-subagent stop <task-name>
```

The first implementation can kill the `tmux` session. A later implementation can send a graceful interrupt first.

### `list`

Lists known tasks with mode, status, created time, and workdir.

```bash
claude-subagent list
```

## Handoff Contract

Codex should create a task prompt with:

- task name
- objective
- current repo and branch
- allowed edit paths
- forbidden paths
- expected deliverables
- commands Claude may run
- tests or checks Claude should run
- completion report path
- instruction to stop after the scoped task and not start unrelated work

The prompt should tell Claude to write its completion report to:

```text
~/.claude-subagents/tasks/<task-name>/report.md
```

## Codex Skill

Create a local skill at:

```text
~/.codex/skills/claude-subagent/SKILL.md
```

Skill rules:

- Use only when the user explicitly asks to offload work to Claude.
- Create a handoff prompt before launching Claude.
- Prefer worktree isolation for repo-editing tasks.
- Use `run` only for bounded checks or small generation tasks.
- Use `start` for exploratory, iterative, or long-running work.
- Review logs, report, and diff before integrating changes.
- Never treat Claude output as trusted just because the command succeeded.

## Worktree Strategy

For tasks that edit a git repository:

1. Check that the source repo is clean enough to branch from, or record dirty state.
2. Create a task branch or worktree name derived from the task name.
3. Launch Claude in the isolated worktree.
4. Review the resulting diff from Codex.
5. Integrate by cherry-picking, manually copying, or opening a PR, depending on the task.

The first implementation creates worktrees at:

```text
~/.claude-subagents/worktrees/<task-name>
```

with branches named:

```text
claude-subagent/<task-name>
```

For tasks that generate standalone artifacts:

1. Use a task directory under `~/.claude-subagents/tasks/<task-name>/workspace`.
2. Ask Claude to write outputs there.
3. Review artifacts before moving them into a target project.

## Testing Plan

### Phase 1: Unit Tests

Use a shell test runner such as `bats-core`, or a small POSIX shell test harness if we want zero dependencies.

Test cases:

- `init` creates the expected directory structure.
- invalid task names are rejected.
- missing prompt file fails clearly.
- `metadata.json` is written with task name, mode, prompt path, workdir, and timestamps.
- `status` reports unknown tasks.
- `list` handles an empty task directory.

Use a fake Claude binary on `PATH` for deterministic tests.

### Phase 2: Fake-Agent Integration Tests

Create a temporary directory with:

```text
fake-bin/claude
fixture-repo/
```

The fake `claude` should:

- print predictable output,
- optionally write a report file,
- optionally modify a fixture file,
- exit with either success or failure.

Test cases:

- `run` captures stdout, stderr, and exit code.
- failed Claude runs are reported as failed.
- `diff` shows changes made by the fake agent.
- `start` creates a background session and `status` detects it.
- `stop` terminates a running fake-agent session.

### Phase 3: Real Claude Smoke Test

This is the first test that uses the real Claude Code CLI.

Create a disposable fixture repo:

```text
/tmp/claude-subagent-smoke/
  README.md
```

Prompt:

```text
Append one sentence to README.md saying this file was edited by a Claude Subagent smoke test.
Write a report to ~/.claude-subagents/tasks/smoke-real-claude/report.md.
Do not modify any other files.
```

Run:

```bash
claude-subagent run smoke-real-claude --prompt smoke.md --workdir /tmp/claude-subagent-smoke
```

Assertions:

- task metadata exists.
- stdout or transcript exists.
- report exists.
- fixture repo has exactly the expected README diff.
- `claude-subagent diff smoke-real-claude` shows the change.

### Phase 4: Codex-Orchestrated End-to-End Test

This verifies the intended product behavior.

Steps:

1. User asks Codex: "Offload the smoke fixture edit to Claude."
2. Codex writes the handoff prompt.
3. Codex runs `claude-subagent run` or `start`.
4. Codex checks `status`, `logs`, `report`, and `diff`.
5. Codex summarizes Claude's output and either accepts or rejects the diff.

Pass condition:

- Codex can trigger Claude through the wrapper without manual terminal interaction.
- Codex can inspect the result and explain exactly what Claude changed.
- No changes are merged into an unrelated repo.

### Phase 5: Real Background Task Test

Use `start` with a prompt that sleeps or performs a small multi-step edit in a disposable repo.

Assertions:

- `start` returns immediately.
- `status` reports running while Claude is active.
- `logs --tail` shows progress.
- `stop` can terminate the session.
- completed tasks write an exit code and report.

## First Implementation Sequence

1. Replace the placeholder Bash script with a real CLI parser.
2. Implement `init`, task directory creation, task name validation, and metadata writing.
3. Implement synchronous `run` using real `claude --print`.
4. Add fake-Claude tests for `run`, logging, exit codes, and metadata.
5. Implement `status`, `logs`, `list`, and `diff`.
6. Add fake-agent integration tests.
7. Implement background `start` and `stop` with `tmux`.
8. Add the Codex skill.
9. Run the real Claude smoke test in a disposable repo.
10. Run the Codex-orchestrated end-to-end test.

## Open Decisions

- Bash is enough for the first version, but Python or Node may be better if JSON handling and test ergonomics become annoying.
- We need to decide whether real Claude background jobs should use our own `tmux` wrapper or Claude Code's native `--worktree --tmux` behavior.
- We need to decide whether the wrapper should install the Codex skill automatically or keep that as a separate command.
- We need to decide the default permission mode for Claude. The conservative default should be Claude Code's normal permissions, with any bypass mode requiring an explicit flag.
