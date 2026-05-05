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

printf '{"type":"message","content":"fake claude stdout"}\n'
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
  assert_output_contains "$output" "fake claude stdout"

  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/metadata.json"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stdout.log"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stderr.log"
  assert_file "$CLAUDE_SUBAGENT_HOME/tasks/success-task/exit-code"
  assert_file "$report"
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/metadata.json" '"taskName": "success-task"'
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stdout.log" "fake claude stdout"
  assert_contains "$CLAUDE_SUBAGENT_HOME/tasks/success-task/stderr.log" "fake claude stderr"
  assert_contains "$repo/README.md" "Edited by fake Claude."

  [[ "$("$BIN" status success-task)" == "succeeded" ]] || fail "success-task did not succeed"

  local diff_output
  diff_output="$("$BIN" diff success-task)"
  assert_output_contains "$diff_output" "Edited by fake Claude."
  pass "run captures logs, metadata, report, status, and diff"
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

make_fake_claude
test_init_and_list
test_run_success_logs_metadata_and_diff
test_run_failure
test_unknown_and_invalid_tasks
test_start_status_logs_and_stop

printf '%d tests passed\n' "$pass_count"
