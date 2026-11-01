# shellcheck shell=sh disable=SC2016,SC2034,SC2154 # Quoted on purpose, Settings used by supervise.sh, status and output set by run.
# Unit tests of the internal functions of supervise.sh, sourced from it.

# Marker of the shell running the tests, as computed by _printf_time_test.
_shell_marker() {
  printf %s "${BASH_VERSION:-}${KSH_VERSION:-}${ZSH_VERSION:-}"
}

# Succeed when the process $1 has $2 descendants.
_has_children() {
  [ "$(ps_children "$1" | wc -l)" -eq "$2" ]
}

test_bytes_converts_suffixes() {
  load_supervise
  assert_eq 0 "$(_bytes 0)"
  assert_eq 100 "$(_bytes 100)"
  assert_eq 2048 "$(_bytes 2k)"
  assert_eq 2048 "$(_bytes 2K)"
  assert_eq 3145728 "$(_bytes 3M)"
  assert_eq 3145728 "$(_bytes 3m)"
  assert_eq 1073741824 "$(_bytes 1G)"
}

test_bytes_rejects_invalid_sizes() {
  load_supervise
  for _size in "" k 12x 1.5M -3 "1 M"; do
    run _bytes "$_size"
    assert_eq 1 "$status" "exit code for [$_size]"
    assert_contains "$output" "Invalid size: $_size"
  done
}

test_validate_number() {
  load_supervise
  for _n in 0 7 120 00042; do
    run validate_number "$_n" thing
    assert_eq 0 "$status" "exit code for [$_n]"
  done
  for _n in "" -1 1.5 abc "1 2"; do
    run validate_number "$_n" thing
    assert_eq 1 "$status" "exit code for [$_n]"
    assert_contains "$output" "Invalid thing: $_n"
  done
}

test_printf_time_test_sets_result_and_marker() {
  load_supervise
  _SUPERVISE_PRINTF_TIME=
  _printf_time_test
  case "$_SUPERVISE_PRINTF_TIME" in
    [01]:"$(_shell_marker)") ;;
    *) fail "Unexpected result: $_SUPERVISE_PRINTF_TIME";;
  esac
  if [ -n "${BASH_VERSION:-}" ]; then
    assert_eq "1:$(_shell_marker)" "$_SUPERVISE_PRINTF_TIME" "bash supports %()T"
  fi
}

test_printf_time_test_reuses_result_of_same_shell() {
  load_supervise
  # A bogus result is kept, which proves that the test is not run again.
  _SUPERVISE_PRINTF_TIME="7:$(_shell_marker)"
  _printf_time_test
  assert_eq "7:$(_shell_marker)" "$_SUPERVISE_PRINTF_TIME"
}

test_printf_time_test_retests_for_other_shell() {
  load_supervise
  _SUPERVISE_PRINTF_TIME="7:another shell"
  _printf_time_test
  case "$_SUPERVISE_PRINTF_TIME" in
    [01]:"$(_shell_marker)") ;;
    *) fail "Not tested again: $_SUPERVISE_PRINTF_TIME";;
  esac
}

test_log_format() {
  load_supervise
  _SUPERVISE_LOGNAME=tester
  _SUPERVISE_LOGFILE=$TEST_DIR/out.log
  _log WRN 'hello %s, %d%%' world 42
  assert_match "$(cat out.log)" '^\[tester\] \[WRN\] \[[0-9]{8}-[0-9]{6}\] hello world, 42%$'
}

test_log_format_without_printf_time() {
  load_supervise
  _SUPERVISE_LOGNAME=tester
  _SUPERVISE_LOGFILE=$TEST_DIR/out.log
  _SUPERVISE_PRINTF_TIME="0:$(_shell_marker)"
  _log NFO '%s' "from date"
  assert_match "$(cat out.log)" '^\[tester\] \[NFO\] \[[0-9]{8}-[0-9]{6}\] from date$'
}

test_log_falls_back_to_stderr() {
  load_supervise
  _SUPERVISE_LOGNAME=tester
  _SUPERVISE_LOGFILE=$TEST_DIR/missing/dir/out.log
  run _log ERR '%s' "still logged"
  assert_eq 0 "$status"
  assert_match "$output" '^\[tester\] \[ERR\] \[.*\] still logged$'
}

test_log_levels_follow_verbosity() {
  load_supervise
  SUPERVISE_VERBOSE=0
  output=$( { warn w; info i; debug d; trace t; } 2>&1 )
  assert_contains "$output" "[WRN]"
  assert_not_contains "$output" "[NFO]"
  SUPERVISE_VERBOSE=1
  output=$( { info i; debug d; } 2>&1 )
  assert_contains "$output" "[NFO]"
  assert_not_contains "$output" "[DBG]"
  SUPERVISE_VERBOSE=3
  output=$( { debug d; trace t; } 2>&1 )
  assert_contains "$output" "[DBG]"
  assert_contains "$output" "[TRC]"
}

test_error_exits() {
  load_supervise
  run error 'bad %s' thing
  assert_eq 1 "$status"
  assert_contains "$output" "[ERR]"
  assert_contains "$output" "bad thing"
}

test_ps_descendants_leaves_first() {
  load_supervise
  # 1 has children 2 and 4, 2 has child 3, 5 is unrelated.
  assert_eq "3
2
4" "$(_ps_descendants 1 2:1 3:2 4:1 5:9)"
  assert_eq "" "$(_ps_descendants 7 2:1 3:2)"
}

test_ps_children_and_kill_tree() {
  load_supervise
  sh -c 'sleep 300 & sleep 300 & wait' &
  _root=$!
  wait_until _has_children "$_root" 2
  _kids=$(ps_children "$_root")
  for _pid in $_kids; do
    assert_eq sleep "$(cat "/proc/$_pid/comm")"
  done

  # The whole tree is signalled, the root last.
  _killed=$(kill_tree "$_root" TERM)
  assert_eq "$_root" "$(printf '%s\n' "$_killed" | tail -n 1)"
  for _pid in $_kids; do
    assert_contains "$_killed" "$_pid"
    wait_until gone "$_pid"
  done
  wait "$_root" || true
}

test_config_entries_parses_lines() {
  load_supervise
  cat > supervise.cfg <<'EOF'
# A comment
   # An indented comment

clock: sh -c 'date'
spaced   :   sleep 10
nospace:sleep 20
sh -c 'echo a:b'
/bin/echo hello
EOF
  SUPERVISE_PATH=supervise.cfg
  _tab=$(printf '\t')
  assert_eq "clock${_tab}sh -c 'date'
spaced${_tab}sleep 10
nospace${_tab}sleep 20
sh${_tab}sh -c 'echo a:b'
echo${_tab}/bin/echo hello" "$(_config_entries)"
}

test_config_entries_skips_names_without_command() {
  load_supervise
  printf 'empty:\nok: sleep 1\n' > supervise.cfg
  SUPERVISE_PATH=supervise.cfg
  run _config_entries
  assert_contains "$output" "No command for empty"
  assert_eq "ok	sleep 1" "$(_config_entries 2>/dev/null)"
}

test_config_entries_makes_names_unique() {
  load_supervise
  cat > supervise.cfg <<'EOF'
sh -c 'echo 1'
sh -c 'echo 2'
sh-2: sleep 1
a: sleep 2
a: sleep 3
EOF
  SUPERVISE_PATH=supervise.cfg
  # Derived names avoid the given sh-2, given duplicates are renamed.
  assert_eq "sh sh-3 sh-2 a a-2" \
    "$(_config_entries 2>/dev/null | cut -f 1 | tr '\n' ' ' | sed 's/ $//')"
  run _config_entries
  assert_contains "$output" "Duplicate name a"
  assert_not_contains "$output" "Duplicate name sh"
}

test_config_entries_keeps_given_names() {
  load_supervise
  # The derived name comes first, but the given name wins.
  printf 'sleep 1\nsleep: sleep 2\n' > supervise.cfg
  SUPERVISE_PATH=supervise.cfg
  _tab=$(printf '\t')
  assert_eq "sleep-2${_tab}sleep 1
sleep${_tab}sleep 2" "$(_config_entries)"
}

test_config_id() {
  load_supervise
  mkdir sub
  printf 'a: sleep 1\n' > "my file.cfg"
  printf 'a: sleep 1\n' > sub/my-file.cfg

  SUPERVISE_PATH="my file.cfg"
  _id=$(_config_id)
  assert_match "$_id" '^my_file\.cfg-[0-9a-f]{12}$'
  # The id only depends on the path, not the content.
  printf 'b: sleep 2\n' >> "my file.cfg"
  assert_eq "$_id" "$(_config_id)"
  SUPERVISE_PATH="./sub/../my file.cfg"
  assert_eq "$_id" "$(_config_id)"

  SUPERVISE_PATH=sub/my-file.cfg
  assert_match "$(_config_id)" '^my-file\.cfg-[0-9a-f]{12}$'
}

test_pid_start_and_record() {
  load_supervise
  _start=$(_pid_start $$)
  assert_match "$_start" '^[0-9]+$'
  assert_eq "$$ $_start" "$(_pid_record $$)"

  sleep 300 &
  _pid=$!
  kill "$_pid"
  wait "$_pid" || true
  run _pid_start "$_pid"
  assert_eq 1 "$status"
  assert_eq "" "$(_pid_record "$_pid")"
  assert_eq "" "$(_pid_record "")"
}

test_alive_pid() {
  load_supervise
  sleep 300 &
  _pid=$!
  _pid_record "$_pid" > ok.pid
  assert_eq "$_pid" "$(_alive_pid ok.pid)"

  # A reused PID has another start time.
  printf '%s 1\n' "$_pid" > reused.pid
  run _alive_pid reused.pid
  assert_eq 1 "$status"
  # PID files without start time are not trusted.
  printf '%s\n' "$_pid" > nostart.pid
  run _alive_pid nostart.pid
  assert_eq 1 "$status"
  run _alive_pid missing.pid
  assert_eq 1 "$status"

  kill "$_pid"
  wait "$_pid" || true
  run _alive_pid ok.pid
  assert_eq 1 "$status"
}

test_wait_gone() {
  load_supervise
  # Not a child of ours: children are zombies until reaped, and kill -0 still
  # finds them.
  _short=$(sh -c 'sleep 1 > /dev/null & echo $!')
  kill -0 "$_short" || fail "Process gone too early"
  run _wait_gone "$_short"
  assert_eq 0 "$status"
  gone "$_short" || fail "Process still alive"
}

test_log_rotate_rotates_and_keeps() {
  load_supervise
  SUPERVISE_LOGSIZE=10
  SUPERVISE_LOGKEEP=2
  for _gen in 1 2 3; do
    printf 'generation %d\n' "$_gen" > app.log
    _log_rotate "$TEST_DIR/app.log"
    assert_eq "" "$(cat app.log)" "content after rotation $_gen"
  done
  assert_eq "generation 3" "$(cat app.log.1)"
  assert_eq "generation 2" "$(cat app.log.2)"
  [ ! -e app.log.3 ] || fail "app.log.3 should not be kept"
  [ ! -e app.log.lock ] || fail "lock not removed"
}

test_log_rotate_below_size_or_disabled() {
  load_supervise
  printf 'small\n' > app.log
  SUPERVISE_LOGSIZE=1k
  _log_rotate "$TEST_DIR/app.log"
  assert_eq small "$(cat app.log)"
  SUPERVISE_LOGSIZE=0
  _log_rotate "$TEST_DIR/app.log"
  assert_eq small "$(cat app.log)"
  [ ! -e app.log.1 ] || fail "rotated without reason"
  # Missing files are not an error, and silently ignored.
  SUPERVISE_LOGSIZE=1
  run _log_rotate "$TEST_DIR/missing.log"
  assert_eq 0 "$status"
  assert_eq "" "$output"
}

test_log_rotate_keep_zero_truncates() {
  load_supervise
  SUPERVISE_LOGSIZE=1
  SUPERVISE_LOGKEEP=0
  printf 'content\n' > app.log
  _log_rotate "$TEST_DIR/app.log"
  assert_eq "" "$(cat app.log)"
  [ ! -e app.log.1 ] || fail "app.log.1 should not exist"
}

test_log_rotate_respects_lock() {
  load_supervise
  SUPERVISE_LOGSIZE=1
  printf 'content\n' > app.log
  mkdir app.log.lock
  _log_rotate "$TEST_DIR/app.log"
  assert_eq content "$(cat app.log)" "rotated while locked"

  # A lock older than a minute is stale, and removed.
  touch -d '5 minutes ago' app.log.lock
  _log_rotate "$TEST_DIR/app.log"
  assert_eq "" "$(cat app.log)"
  assert_eq content "$(cat app.log.1)"
  [ ! -e app.log.lock ] || fail "stale lock not removed"
}

test_log_cat_orders_rotated_files() {
  load_supervise
  for _i in 1 2 10; do
    printf 'rotated %s\n' "$_i" > "app.log.$_i"
  done
  printf 'current\n' > app.log
  mkdir app.log.lock
  printf 'other\n' > other.log
  assert_eq "rotated 10
rotated 2
rotated 1
current
other" "$(_log_cat "$TEST_DIR/app.log" "$TEST_DIR/other.log")"
}

test_spawn_appends_to_file_and_waits() {
  load_supervise
  printf 'before\n' > out.log
  spawn -o "$TEST_DIR/out.log" /bin/sh -c 'echo "$_SUPERVISE_LOGFILE"; echo err >&2; exit 3' > /dev/null
  _rc=0
  spawn_wait || _rc=$?
  assert_eq 3 "$_rc" "exit code"
  assert_eq "before
$TEST_DIR/out.log
err" "$(cat out.log)"
  assert_eq "" "$_SUPERVISE_PIDS" "PIDs left"
}

test_spawn_latest_and_update() {
  load_supervise
  spawn -o /dev/null /bin/sleep 300 > /dev/null
  _first=$(spawn_latest)
  spawn -o /dev/null /bin/sleep 300 > /dev/null
  _second=$(spawn_latest)
  [ "$_first" != "$_second" ] || fail "Same PID twice"
  assert_eq "$_first $_second" "$_SUPERVISE_PIDS"

  kill "$_second"
  wait "$_second" || true
  _spawn_update
  assert_eq "$_first" "$_SUPERVISE_PIDS"
  assert_eq "$_first" "$(spawn_latest)"
  spawn_kill
  spawn_wait || true
  assert_eq "" "$(spawn_latest)"
}

test_spawn_kill_tree() {
  load_supervise
  spawn -o /dev/null /bin/sh -c 'sleep 300 & echo $! > child; wait' > /dev/null
  wait_until [ -s child ]
  _child=$(cat child)
  spawn_kill -t -s TERM -r test
  spawn_wait || true
  wait_until gone "$_child"
}

test_spawn_rejects_non_executable() {
  load_supervise
  run spawn -o /dev/null "$TEST_DIR/nothing"
  assert_eq 1 "$status"
  assert_contains "$output" "is not executable"
  run spawn
  assert_eq 1 "$status"
  assert_contains "$output" "No executable given"
}
