# shellcheck shell=sh disable=SC2016,SC2154 # Quoted on purpose, status and output set by run.
# Tests of the commands working on a configuration file: up, down, ps, ls and
# log. Commands are started from supervise.cfg in the test directory.

test_up_detached_ps_ls_log_down() {
  cat > supervise.cfg <<'EOF'
sleeper: sleep 300
once: sh -c 'echo done'
EOF
  run supervise up -d
  assert_eq 0 "$status"
  wait_until state_is once exited
  wait_until state_is sleeper running

  assert_eq 0 "$(ps_field once 6)" "exit code of once"
  _run=$(ps_field sleeper 3)
  _pid=$(ps_field sleeper 4)
  assert_eq sleep "$(cat "/proc/$_pid/comm")"
  # The run process itself, not a subshell of up around it.
  assert_contains "$(tr '\0' ' ' < "/proc/$_run/cmdline")" "run -n sleeper"
  assert_contains "$(supervise ps)" "sleep 300"

  assert_eq "sleeper: sleep 300
once: sh -c 'echo done'" "$(supervise ls)"
  assert_eq "sleeper
once" "$(supervise ls -q)"
  assert_match "$(supervise log once)" '^\[once\] \[OUT\] \[[0-9]{8}-[0-9]{6}\] done$'

  run supervise down
  assert_eq 0 "$status"
  gone "$_run" || fail "run process still alive"
  wait_until gone "$_pid"
  assert_eq stopped "$(ps_field sleeper 2)"
  assert_eq stopped "$(ps_field once 2)"
}

test_up_only_named_commands() {
  printf 'a: sleep 300\nb: sleep 301\n' > supervise.cfg
  run supervise up -d b nosuch
  assert_eq 0 "$status"
  assert_contains "$output" "No command named nosuch"
  wait_until state_is b running
  assert_eq stopped "$(ps_field a 2)"
}

test_up_does_not_start_twice() {
  printf 'a: sleep 300\n' > supervise.cfg
  supervise up -d
  wait_until state_is a running
  _run=$(ps_field a 3)
  supervise up -d
  assert_eq "$_run" "$(ps_field a 3)"
}

test_up_restarts_changed_commands() {
  printf 'a: sleep 300\n' > supervise.cfg
  supervise up -d
  wait_until state_is a running
  _run=$(ps_field a 3)
  _pid=$(ps_field a 4)

  printf 'a: sleep 301\n' > supervise.cfg
  assert_eq "running,changed" "$(ps_field a 2)"
  supervise up -d
  wait_until state_is a running
  [ "$(ps_field a 3)" != "$_run" ] || fail "Not restarted"
  gone "$_run" || fail "Old run process still alive"
  wait_until gone "$_pid"
  assert_contains "$(supervise ps a)" "sleep 301"
}

test_removed_commands_are_still_known() {
  printf 'a: sleep 300\nb: sleep 301\n' > supervise.cfg
  supervise up -d
  wait_until state_is a running
  printf 'b: sleep 301\n' > supervise.cfg

  assert_eq "running,removed" "$(ps_field a 2)"
  assert_eq "b: sleep 301
!a: sleep 300" "$(supervise ls)"
  assert_eq "b
!a" "$(supervise ls -q)"

  supervise down a
  assert_eq "b" "$(supervise ls -q)"
  assert_eq running "$(ps_field b 2)"
}

test_duplicate_names_are_renamed() {
  cat > supervise.cfg <<'EOF'
sh -c 'sleep 300'
sh -c 'sleep 301'
EOF
  assert_eq "sh
sh-2" "$(supervise ls -q)"
  supervise up -d
  wait_until state_is sh running
  wait_until state_is sh-2 running
  assert_contains "$(supervise ps sh-2)" "sleep 301"
  supervise down sh-2
  assert_eq stopped "$(ps_field sh-2 2)"
  assert_eq running "$(ps_field sh 2)"
}

test_up_attached_follows_logs() {
  printf 'once: sh -c "echo hello"\n' > supervise.cfg
  run supervise up
  assert_eq 0 "$status"
  assert_match "$output" '^\[once\] \[OUT\] .* hello$'
  assert_eq exited "$(ps_field once 2)"
}

test_up_attached_stops_only_its_commands() {
  printf 'a: sleep 300\nb: sleep 301\n' > supervise.cfg
  supervise up -d a
  wait_until state_is a running

  exec "$TEST_SHELL" "$SUPERVISE" up > up.out 2>&1 &
  _up=$!
  wait_until state_is b running
  # Leave time for up to install its traps, once all commands are started.
  sleep 0.5
  kill -TERM "$_up"
  _rc=0
  wait "$_up" || _rc=$?
  assert_eq 143 "$_rc" "exit code of up"
  assert_eq stopped "$(ps_field b 2)"
  assert_eq running "$(ps_field a 2)"
}

test_log_options() {
  printf 'talk: sh -c "echo one; echo two; echo three"\nquiet: sleep 300\n' > supervise.cfg
  supervise up -d
  wait_until state_is talk exited

  assert_eq 3 "$(supervise log talk | wc -l | tr -d ' ')"
  _last=$(supervise log -n 1 talk)
  assert_match "$_last" '^\[talk\] \[OUT\] .* three$'
  assert_eq 1 "$(printf '%s\n' "$_last" | wc -l | tr -d ' ')"
  run supervise log -n 0 talk
  assert_eq 0 "$status"
  assert_eq "" "$output"
  run supervise log -n x
  assert_eq 1 "$status"
  run supervise log nosuch
  assert_contains "$output" "No logs for command nosuch"
}

test_log_follows() {
  # Numbered, so that every line is unique.
  cat > supervise.cfg <<'EOF'
tick: sh -c 'i=0; while true; do i=$((i + 1)); echo "tick $i"; sleep 0.2; done'
EOF
  supervise up -d
  wait_until state_is tick running
  wait_until grep -q tick "$XDG_RUNTIME_DIR"/supervise/*/tick.log
  exec "$TEST_SHELL" "$SUPERVISE" log -n 1 -f tick > follow.out 2>&1 &
  _log=$!
  # The last line, then new ones.
  wait_until lines_at_least follow.out 3
  kill "$_log"
  wait "$_log" || true
  assert_eq "$(sort -u follow.out | wc -l)" "$(wc -l < follow.out)" "lines shown twice"
}

test_log_follows_from_end() {
  printf 'tick: sh -c "while true; do echo tick; sleep 0.2; done"\n' > supervise.cfg
  supervise up -d
  wait_until state_is tick running
  exec "$TEST_SHELL" "$SUPERVISE" log -n 0 -f tick > follow.out 2>&1 &
  _log=$!
  wait_until grep -q tick follow.out
  kill "$_log"
  wait "$_log" || true
}

test_logs_are_private() {
  printf 'a: sh -c "echo hi"\n' > supervise.cfg
  supervise up -d
  for _d in "$XDG_RUNTIME_DIR"/supervise/supervise.cfg-*; do
    assert_eq 700 "$(stat -c %a "$_d")" "permissions of $_d"
  done
}

test_directories_follow_script_name() {
  printf 'once: sh -c "echo hi"\n' > supervise.cfg
  cp "$SUPERVISE" other.sh
  "$TEST_SHELL" ./other.sh up -d
  wait_until grep -q hi "$XDG_RUNTIME_DIR"/other/supervise.cfg-*/once.log
  [ -f "$(echo "$XDG_STATE_HOME"/other/supervise.cfg-*/config.path)" ] || fail "No state under other"
  [ ! -e "$XDG_STATE_HOME/supervise" ] || fail "State under supervise"
  [ ! -e "$XDG_RUNTIME_DIR/supervise" ] || fail "Logs under supervise"
  # Each name has its own directories.
  assert_eq stopped "$(ps_field once 2)"
}

test_directories_from_environment() {
  printf 'a: sleep 300\n' > supervise.cfg
  SUPERVISE_STATE_HOME=$TEST_DIR/mystate
  SUPERVISE_RUNTIME_DIR=$TEST_DIR/mylogs
  export SUPERVISE_STATE_HOME SUPERVISE_RUNTIME_DIR
  supervise up -d
  wait_until state_is a running
  [ -f "$(echo "$TEST_DIR"/mystate/supervise.cfg-*/a.run)" ] || fail "No state in SUPERVISE_STATE_HOME"
  [ -f "$(echo "$TEST_DIR"/mylogs/supervise.cfg-*/a.log)" ] || fail "No logs in SUPERVISE_RUNTIME_DIR"
  [ ! -e "$XDG_STATE_HOME/supervise" ] || fail "State under XDG_STATE_HOME"
  [ ! -e "$XDG_RUNTIME_DIR/supervise" ] || fail "Logs under XDG_RUNTIME_DIR"
  supervise down
  assert_eq stopped "$(ps_field a 2)"
}

test_nothing_started() {
  printf 'a: sleep 300\n' > supervise.cfg
  run supervise down
  assert_eq 0 "$status"
  assert_contains "$output" "Nothing started"
  run supervise log
  assert_eq 0 "$status"
  assert_contains "$output" "No logs"
  run supervise ps nosuch
  assert_contains "$output" "No command named nosuch"
  assert_eq stopped "$(ps_field a 2)"
}

test_up_fails_on_missing_file() {
  run supervise -s missing.cfg up -d
  assert_eq 1 "$status"
  assert_contains "$output" "Cannot read missing.cfg"
}

test_down_works_when_file_is_gone() {
  printf 'a: sleep 300\n' > supervise.cfg
  supervise up -d
  wait_until state_is a running
  _pid=$(ps_field a 4)
  rm supervise.cfg
  run supervise down
  assert_eq 0 "$status"
  wait_until gone "$_pid"
}
