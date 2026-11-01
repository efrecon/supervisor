# shellcheck shell=sh disable=SC2034 # status and output are used by the tests.
# Helpers for the tests, sourced by run.sh before each test file. Tests run
# with set -eu, so any failing command fails the test.

# Create a temporary directory for the test, with private XDG directories, and
# make it the current directory. It is removed, and the commands started from
# it stopped, when the test ends.
setup() {
  TEST_DIR=$(mktemp -d)
  XDG_STATE_HOME=$TEST_DIR/state
  XDG_RUNTIME_DIR=$TEST_DIR/runtime
  export TEST_DIR XDG_STATE_HOME XDG_RUNTIME_DIR
  cd "$TEST_DIR" || exit
  trap teardown EXIT
}

# Stop the commands started by up from any configuration file, by any copy of
# supervise.sh, whatever its name, then remove the test directory. Keeps the
# exit code of the test.
teardown() {
  _rc=$?
  for _p in "$XDG_STATE_HOME"/*/*/config.path; do
    [ -f "$_p" ] || continue
    SUPERVISE_STATE_HOME=${_p%/*/config.path} \
      "$SUPERVISE" -s "$(cat "$_p")" down > /dev/null 2>&1 || true
  done
  # Kill what down missed, e.g. when it is broken: all the processes started
  # from this test inherit its state directory.
  for _e in $(grep -lzxF "XDG_STATE_HOME=$XDG_STATE_HOME" /proc/[0-9]*/environ 2>/dev/null || true); do
    _p=${_e#/proc/}
    _p=${_p%/environ}
    [ "$_p" = "$$" ] && continue
    printf 'Killing leftover process %s: %s\n' "$_p" "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null || true)" >&2
    kill -KILL "$_p" 2>/dev/null || true
  done
  cd /
  rm -rf "${TEST_DIR:?}"
  exit "$_rc"
}

# Run supervise.sh with the arguments passed, using the shell under test. To
# run it in the background, call "$TEST_SHELL" "$SUPERVISE" instead, so $! is
# its PID and not the one of a subshell running this function.
supervise() {
  "$TEST_SHELL" "$SUPERVISE" "$@"
}

# Source the functions of supervise.sh, without running any command: all the
# script up to the validation of the settings, at its bottom.
load_supervise() {
  grep -q '^# Validate settings' "$SUPERVISE" || fail "No settings validation marker in $SUPERVISE"
  sed '/^# Validate settings/,$d' "$SUPERVISE" > "$TEST_DIR/supervise.lib.sh"
  set --
  # shellcheck disable=SC1091 # Generated above.
  . "$TEST_DIR/supervise.lib.sh"
}

# Run the command passed as arguments, keeping its exit code in status and its
# stdout and stderr in output.
run() {
  status=0
  output=$("$@" 2>&1) || status=$?
}

# Fail the test with the message passed as arguments.
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Fail unless $1 and $2 are equal. $3 describes what is compared.
assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-Values differ}: expected [$1], got [$2]"
}

# Fail unless $1 contains the text $2.
assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "Text [$2] not found in: $1";;
  esac
}

# Fail when $1 contains the text $2.
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "Text [$2] unexpectedly found in: $1";;
  esac
}

# Fail unless a line of $1 matches the extended regular expression $2.
assert_match() {
  printf '%s\n' "$1" | grep -qE -- "$2" || fail "No line matching [$2] in: $1"
}

# Succeed when the process which PID is $1 is gone.
gone() {
  ! kill -0 "$1" 2>/dev/null
}

# Succeed when the file $1 has at least $2 lines.
lines_at_least() {
  [ "$(wc -l < "$1")" -ge "$2" ]
}

# Retry the command passed as arguments every 0.1 second until it succeeds,
# failing the test after 10 seconds. The arguments are expanded once, before
# the call: use a function to compute values at each try.
wait_until() {
  _wu=0
  until "$@"; do
    _wu=$((_wu + 1))
    [ "$_wu" -lt 100 ] || fail "Timeout waiting for: $*"
    sleep 0.1
  done
}

# Print the column $2 of the ps line of the command $1, columns being NAME
# STATE RUN PID UPTIME EXIT.
ps_field() {
  supervise ps "$1" 2>/dev/null | awk -v n="$1" -v c="$2" '$1 == n { print $c }'
}

# Succeed when the STATE of the command $1 is $2.
state_is() {
  [ "$(ps_field "$1" 2)" = "$2" ]
}
