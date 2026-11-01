# shellcheck shell=sh disable=SC2016,SC2154 # Quoted on purpose, status and output set by run.
# Tests of the command line of supervise.sh: help, options, run and logger.

test_help_lists_commands_in_order() {
  run supervise -h
  assert_eq 0 "$status"
  assert_contains "$output" "Options:"
  assert_contains "$output" "-s  Path to the configuration file"
  assert_eq "up down ps ls log run logger" \
    "$(printf '%s\n' "$output" | sed -n '/^Commands:/,/^$/p' | awk 'NR > 1 && NF { print $1 }' | tr '\n' ' ' | sed 's/ $//')"
}

test_command_help_shows_its_options_only() {
  run supervise up -h
  assert_eq 0 "$status"
  assert_contains "$output" "up: Start the commands from the configuration file"
  assert_contains "$output" "Options of up:"
  assert_contains "$output" "-d  Detach"
  assert_not_contains "$output" "-q  Quiet"
  assert_not_contains "$output" "Commands:"
  for _cmd in down ps ls log run logger; do
    run supervise "$_cmd" -h
    assert_eq 0 "$status" "exit code of $_cmd -h"
    assert_contains "$output" "Options of $_cmd:"
  done
}

test_unknown_option_fails() {
  run supervise -x ls
  assert_eq 1 "$status"
  assert_contains "$output" "Usage:"
  run supervise ls -x
  assert_eq 1 "$status"
  assert_contains "$output" "Options of ls:"
}

test_commands_are_validated() {
  run supervise
  assert_eq 1 "$status"
  assert_contains "$output" "No command given"
  run supervise nosuch
  assert_eq 1 "$status"
  assert_contains "$output" "Unknown command: nosuch"
  run supervise 'ls;id'
  assert_eq 1 "$status"
  assert_contains "$output" "Invalid command"
  # Internal functions are not commands.
  run supervise _bytes 1
  assert_eq 1 "$status"
}

test_commands_are_case_insensitive() {
  printf 'a: sleep 1\n' > supervise.cfg
  run supervise LS -q
  assert_eq 0 "$status"
  assert_eq a "$output"
}

test_settings_are_validated() {
  run supervise -m 10x ls
  assert_eq 1 "$status"
  assert_contains "$output" "Invalid size: 10x"
  run supervise -k many ls
  assert_eq 1 "$status"
  assert_contains "$output" "Invalid number of log files to keep: many"
  run supervise -r -1 ls
  assert_eq 1 "$status"
  assert_contains "$output" "Invalid maximum delay between restarts: -1"
  # Settings from the environment are validated too.
  run env SUPERVISE_LOGSIZE=big "$TEST_SHELL" "$SUPERVISE" ls
  assert_eq 1 "$status"
  assert_contains "$output" "Invalid size: big"
}

test_run_logs_streams() {
  run supervise run -- sh -c 'echo hello; echo oops >&2'
  assert_eq 0 "$status"
  assert_match "$output" '^\[sh\] \[OUT\] \[[0-9]{8}-[0-9]{6}\] hello$'
  assert_match "$output" '^\[sh\] \[ERR\] \[[0-9]{8}-[0-9]{6}\] oops$'
}

test_run_uses_name() {
  run supervise run -n api -- sh -c 'echo hello'
  assert_eq 0 "$status"
  assert_match "$output" '^\[api\] \[OUT\] .* hello$'
  run env SUPERVISE_NAME=other "$TEST_SHELL" "$SUPERVISE" run sh -c 'echo hello'
  assert_match "$output" '^\[other\] \[OUT\] .* hello$'
}

test_run_restarts_until_success() {
  # Fails twice, then succeeds.
  run supervise run -- sh -c 'n=$(cat count 2>/dev/null || echo 0); n=$((n + 1)); echo $n > count; [ $n -ge 3 ]'
  assert_eq 0 "$status"
  assert_eq 3 "$(cat count)"
}

test_run_fails_without_command() {
  run supervise run
  assert_eq 1 "$status"
  assert_contains "$output" "Nothing to run"
  run supervise run -- no-such-command-here
  assert_eq 1 "$status"
  assert_contains "$output" "not found"
}

test_run_stops_process_tree_on_term() {
  "$TEST_SHELL" "$SUPERVISE" run -- sh -c 'sleep 300 & echo $! > child; wait' 2>/dev/null &
  _run=$!
  wait_until [ -s child ]
  _child=$(cat child)
  kill -TERM "$_run"
  _rc=0
  wait "$_run" || _rc=$?
  assert_eq 143 "$_rc" "exit code of run"
  wait_until gone "$_child"
}

test_run_through_shell_when_not_executable() {
  # run calls the script again for its loggers, through the shell when the
  # script is not executable.
  cp "$SUPERVISE" copy.sh
  chmod -x copy.sh
  run "$TEST_SHELL" copy.sh run -- sh -c 'echo hello'
  assert_eq 0 "$status"
  assert_match "$output" '^\[sh\] \[OUT\] .* hello$'
}

test_logger_logs_stdin() {
  output=$(printf 'first\nlast without newline' | supervise logger -n app out 2>&1)
  assert_match "$output" '^\[app\] \[OUT\] \[[0-9]{8}-[0-9]{6}\] first$'
  assert_match "$output" '^\[app\] \[OUT\] .* last without newline$'
  assert_eq 2 "$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  run supervise logger
  assert_eq 1 "$status"
  assert_contains "$output" "No stream name given"
}

test_logger_rotates_without_losing_lines() {
  _i=0
  while [ "$_i" -lt 200 ]; do
    printf 'line %03d of a log with some padding to make it longer\n' "$_i"
    _i=$((_i + 1))
  done > input
  _SUPERVISE_LOGFILE=$TEST_DIR/app.log "$TEST_SHELL" "$SUPERVISE" -m 1k -k 50 logger -n app out < input
  [ -f app.log.1 ] || fail "Log not rotated"
  # All lines are kept, in order, from the oldest rotated file to the current.
  _files=$(printf '%s\n' app.log.[0-9]* | sort -t . -k 3 -rn)
  # shellcheck disable=SC2086 # We want to split the file names
  assert_eq "$(sed 's/^/[app] [OUT] [] /' input)" \
    "$(cat $_files app.log | sed -E 's/\[[0-9]{8}-[0-9]{6}\]/[]/')"
}
