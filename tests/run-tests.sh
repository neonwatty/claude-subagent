#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT_DIR/bin/claude-subagent"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/fake-bin"
export CLAUDE_SUBAGENT_HOME="$TMP_DIR/home"
export PATH="$FAKE_BIN:$PATH"

pass_count=0

cleanup() {
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t claude-subagent-start-task >/dev/null 2>&1 || true
    tmux kill-session -t claude-subagent-start-complete-task >/dev/null 2>&1 || true
    tmux kill-session -t claude-subagent-start-worktree-task >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$*"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F "$expected" "$file" >/dev/null || fail "expected $file to contain: $expected"
}

assert_output_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

make_fake_claude() {
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="$*"

printf '{"type":"assistant","message":{"content":[{"type":"text","text":"fake claude assistant text"}]}}\n'
printf '{"type":"result","result":"fake claude final result"}\n'
printf 'fake claude stderr\n' >&2

if [[ "$prompt" == *"SLEEP_TASK"* ]]; then
  sleep 30
fi

if [[ "$prompt" == *"APPEND_README"* ]]; then
  printf 'Edited by fake Claude.\n' >>README.md
fi

if [[ "$prompt" == *"REPORT:"* ]]; then
  report_path="${prompt##*REPORT:}"
  report_path="${report_path%%$'\n'*}"
  report_path="${report_path%% --*}"
  mkdir -p "$(dirname "$report_path")"
  printf 'Fake Claude report.\n' >"$report_path"
fi

if [[ "$prompt" == *"FAIL_TASK"* ]]; then
  exit 7
fi
EOF
  chmod +x "$FAKE_BIN/claude"
}

make_fixture_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init >/dev/null
  printf '# Fixture\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -m "Initial fixture" >/dev/null
}

test_init_and_list() {
  "$BIN" init >/dev/null
  [[ -d "$CLAUDE_SUBAGENT_HOME/tasks" ]] || fail "tasks directory was not created"

  local output
  output="$("$BIN" list)"
  assert_output_contains "$output" $'TASK\tSTATUS\tMODE\tCREATED\tWORKDIR'
  pass "init creates storage and list handles empty task set"
}

test_run_success_logs_metadata_and_diff() {
  local repo prompt report output
  repo="$TMP_DIR/fixture-success"
  prompt="$TMP_DIR/success.md"
  report="$CLAUDE_SUBAGENT_HOME/tasks/success-task/report.md"
  make_fixture_repo "$repo"
  printf 'APPEND_README\nREPORT:%s\n' "$report" >"$prompt"

  output="$("$BIN" run success-task --prompt "$prompt" --workdir "$repo")"
  assert_output_contains "$output" "fake claude final result"

  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/metadata.json"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stdout.log"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stderr.log"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/exit-code"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/result.txt"
  assert_file "$report"
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/metadata.json" '"taskName": "success-task"'
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stdout.log" "fake claude final result"
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stderr.log" "fake claude stderr"
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/result.txt" "fake claude final result"
  assert_contains "$repo/README.md" "Edited by fake Claude."

  [[ "$("$BIN" status success-task)" == "succeeded" ]] || fail "success-task did not succeed"
  [[ "$("$BIN" result success-task)" == "fake claude final result" ]] || fail "result command did not return extracted final result"

  local diff_output
  diff_output="$("$BIN" diff success-task)"
  assert_output_contains "$diff_output" "Edited by fake Claude."
  pass "run captures logs, metadata, extracted result, report, status, and diff"
}

test_inspect_summarizes_task() {
  local output
  output="$("$BIN" inspect success-task)"
  assert_output_contains "$output" "Task: success-task"
  assert_output_contains "$output" "Status: succeeded"
  assert_output_contains "$output" "Result:"
  assert_output_contains "$output" "fake claude final result"
  assert_output_contains "$output" "Diff stat:"
  pass "inspect prints task summary, result, and diff stat"
}

test_cleanup_removes_task_only() {
  local repo prompt task_dir output
  repo="$TMP_DIR/fixture-cleanup"
  prompt="$TMP_DIR/cleanup.md"
  make_fixture_repo "$repo"
  printf 'APPEND_README\n' >"$prompt"

  "$BIN" run cleanup-task --prompt "$prompt" --workdir "$repo" >/dev/null
  task_dir="$CLAUDE_SUBAGENT_HOME/tasks/cleanup-task"
  [[ -d "$task_dir" ]] || fail "cleanup-task should exist before cleanup"

  output="$("$BIN" cleanup cleanup-task)"
  assert_output_contains "$output" "removed task cleanup-task"
  [[ ! -d "$task_dir" ]] || fail "cleanup-task directory should be removed"
  [[ "$("$BIN" status cleanup-task)" == "unknown" ]] || fail "cleanup-task should be unknown after cleanup"
  assert_contains "$repo/README.md" "Edited by fake Claude."
  pass "cleanup removes task state without touching workdir"
}

test_run_failure() {
  local repo prompt status
  repo="$TMP_DIR/fixture-fail"
  prompt="$TMP_DIR/fail.md"
  make_fixture_repo "$repo"
  printf 'FAIL_TASK\n' >"$prompt"

  set +e
  "$BIN" run fail-task --prompt "$prompt" --workdir "$repo" >/tmp/claude-subagent-test-fail.out 2>/tmp/claude-subagent-test-fail.err
  local code=$?
  set -e

  [[ "$code" -eq 7 ]] || fail "expected run to exit 7, got $code"
  status="$("$BIN" status fail-task)"
  [[ "$status" == "failed" ]] || fail "expected failed status, got $status"
  [[ "$(cat "$CLAUDE_SUBAGENT_HOME/tasks/fail-task/exit-code")" == "7" ]] || fail "exit code was not recorded"
  pass "run records failed Claude exit codes"
}

test_run_with_worktree_isolates_source_repo() {
  local repo prompt report output task_dir worktree_path source_head
  repo="$TMP_DIR/fixture-worktree"
  prompt="$TMP_DIR/worktree.md"
  make_fixture_repo "$repo"
  source_head="$(git -C "$repo" rev-parse HEAD)"
  report="$CLAUDE_SUBAGENT_HOME/tasks/worktree-task/report.md"
  printf 'APPEND_README\nREPORT:%s\n' "$report" >"$prompt"

  output="$("$BIN" run worktree-task --prompt "$prompt" --workdir "$repo" --worktree)"
  assert_output_contains "$output" "fake claude final result"

  task_dir="$CLAUDE_SUBAGENT_HOME/tasks/worktree-task"
  worktree_path="$CLAUDE_SUBAGENT_HOME/worktrees/worktree-task"

  assert_file "$task_dir/metadata.json"
  assert_file "$task_dir/worktree-path"
  assert_file "$task_dir/worktree-branch"
  assert_file "$task_dir/source-workdir"
  assert_file "$task_dir/source-dirty"
  assert_contains "$task_dir/metadata.json" '"worktreeEnabled": "true"'
  assert_contains "$task_dir/metadata.json" '"worktreeBranch": "claude-subagent/worktree-task"'
  [[ "$(cat "$task_dir/workdir")" == "$worktree_path" ]] || fail "task workdir should be the worktree path"
  [[ "$(cat "$task_dir/source-workdir")" == "$repo" ]] || fail "source workdir should be recorded"
  [[ "$(cat "$task_dir/source-dirty")" == "false" ]] || fail "source dirty state should be false"
  [[ "$(git -C "$worktree_path" branch --show-current)" == "claude-subagent/worktree-task" ]] || fail "worktree branch was not created"
  assert_contains "$worktree_path/README.md" "Edited by fake Claude."
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$source_head" ]] || fail "source HEAD changed"
  ! grep -F "Edited by fake Claude." "$repo/README.md" >/dev/null || fail "source README was modified"

  local diff_output
  diff_output="$("$BIN" diff worktree-task)"
  assert_output_contains "$diff_output" "Edited by fake Claude."
  pass "run --worktree isolates edits from the source repo"
}

test_cleanup_with_worktree_and_branch() {
  local repo prompt task_dir worktree_path branch output
  repo="$TMP_DIR/fixture-cleanup-worktree"
  prompt="$TMP_DIR/cleanup-worktree.md"
  make_fixture_repo "$repo"
  printf 'APPEND_README\n' >"$prompt"

  "$BIN" run cleanup-worktree-task --prompt "$prompt" --workdir "$repo" --worktree >/dev/null
  task_dir="$CLAUDE_SUBAGENT_HOME/tasks/cleanup-worktree-task"
  worktree_path="$CLAUDE_SUBAGENT_HOME/worktrees/cleanup-worktree-task"
  branch="claude-subagent/cleanup-worktree-task"

  [[ -d "$task_dir" ]] || fail "cleanup-worktree-task should exist before cleanup"
  [[ -d "$worktree_path" ]] || fail "worktree should exist before cleanup"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || fail "worktree branch should exist before cleanup"

  output="$("$BIN" cleanup cleanup-worktree-task --worktree --branch --force)"
  assert_output_contains "$output" "removed worktree $worktree_path"
  assert_output_contains "$output" "deleted branch $branch"
  assert_output_contains "$output" "removed task cleanup-worktree-task"
  [[ ! -d "$task_dir" ]] || fail "task directory should be removed"
  [[ ! -e "$worktree_path" ]] || fail "worktree should be removed"
  ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || fail "worktree branch should be deleted"
  pass "cleanup --worktree --branch removes task, worktree, and branch"
}

test_unknown_and_invalid_tasks() {
  [[ "$("$BIN" status missing-task)" == "unknown" ]] || fail "missing task should be unknown"

  set +e
  "$BIN" status ../bad >/tmp/claude-subagent-test-invalid.out 2>/tmp/claude-subagent-test-invalid.err
  local code=$?
  set -e

  [[ "$code" -ne 0 ]] || fail "invalid task name should fail"
  pass "status handles unknown and invalid task names"
}

test_start_status_logs_and_stop() {
  command -v tmux >/dev/null 2>&1 || fail "tmux is required for start test"

  local repo prompt
  repo="$TMP_DIR/fixture-start"
  prompt="$TMP_DIR/start.md"
  make_fixture_repo "$repo"
  printf 'SLEEP_TASK\n' >"$prompt"

  "$BIN" start start-task --prompt "$prompt" --workdir "$repo" >/dev/null
  [[ "$("$BIN" status start-task)" == "running" ]] || fail "start-task should be running"

  "$BIN" stop start-task >/dev/null
  local stopped_status
  stopped_status="$("$BIN" status start-task)"
  [[ "$stopped_status" == "created" || "$stopped_status" == "failed" ]] || fail "unexpected stopped status: $stopped_status"
  pass "start creates a tmux task and stop terminates it"
}

test_start_writes_result_when_completed() {
  command -v tmux >/dev/null 2>&1 || fail "tmux is required for completed start test"

  local repo prompt i status result_output
  repo="$TMP_DIR/fixture-start-complete"
  prompt="$TMP_DIR/start-complete.md"
  make_fixture_repo "$repo"
  printf 'APPEND_README\n' >"$prompt"

  "$BIN" start start-complete-task --prompt "$prompt" --workdir "$repo" >/dev/null
  status="created"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    status="$("$BIN" status start-complete-task)"
    [[ "$status" != "running" && "$status" != "created" ]] && break
    sleep 0.25
  done

  [[ "$status" == "succeeded" ]] || fail "start-complete-task should succeed, got $status"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/start-complete-task/result.txt"
  result_output="$("$BIN" result start-complete-task)"
  [[ "$result_output" == "fake claude final result" ]] || fail "background result command did not return extracted final result"
  assert_contains "$repo/README.md" "Edited by fake Claude."
  pass "start writes extracted result after completion"
}

test_start_with_worktree_creates_isolated_session() {
  command -v tmux >/dev/null 2>&1 || fail "tmux is required for start worktree test"

  local repo prompt task_dir worktree_path
  repo="$TMP_DIR/fixture-start-worktree"
  prompt="$TMP_DIR/start-worktree.md"
  make_fixture_repo "$repo"
  printf 'SLEEP_TASK\n' >"$prompt"

  "$BIN" start start-worktree-task --prompt "$prompt" --workdir "$repo" --worktree >/dev/null
  [[ "$("$BIN" status start-worktree-task)" == "running" ]] || fail "start-worktree-task should be running"

  task_dir="$CLAUDE_SUBAGENT_HOME/tasks/start-worktree-task"
  worktree_path="$CLAUDE_SUBAGENT_HOME/worktrees/start-worktree-task"
  [[ "$(cat "$task_dir/workdir")" == "$worktree_path" ]] || fail "start task workdir should be the worktree path"
  [[ "$(cat "$task_dir/source-workdir")" == "$repo" ]] || fail "start task source workdir should be recorded"
  [[ "$(git -C "$worktree_path" branch --show-current)" == "claude-subagent/start-worktree-task" ]] || fail "start worktree branch was not created"

  "$BIN" stop start-worktree-task >/dev/null
  pass "start --worktree creates an isolated tmux task"
}

make_fake_claude
test_init_and_list
test_run_success_logs_metadata_and_diff
test_inspect_summarizes_task
test_cleanup_removes_task_only
test_run_failure
test_run_with_worktree_isolates_source_repo
test_cleanup_with_worktree_and_branch
test_unknown_and_invalid_tasks
test_start_status_logs_and_stop
test_start_writes_result_when_completed
test_start_with_worktree_creates_isolated_session

printf '%d tests passed\n' "$pass_count"
