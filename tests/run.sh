#!/bin/sh

# Run the tests of supervise.sh: all the test_*() functions of the files passed
# as arguments, or of all the tests/test_*.sh files. Each test runs in its own
# process, in a temporary directory with private XDG directories. Set
# TEST_SHELL to run the tests, and supervise.sh, with another shell, e.g. dash,
# TEST_ONLY to a pattern to only run the matching tests, and SUPERVISE to the
# path of another copy of supervise.sh to test.

set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
: "${SUPERVISE:="$(cd "$TESTS_DIR/.." && pwd)/supervise.sh"}"
: "${TEST_SHELL:=sh}"
: "${TEST_ONLY:=""}"
: "${TEST_TIMEOUT:=120}"
export TESTS_DIR SUPERVISE TEST_SHELL

# Run a single test: the function $3 of the file $2.
if [ "${1:-}" = "--one" ]; then
  # shellcheck source=tests/lib.sh
  . "$TESTS_DIR/lib.sh"
  # shellcheck disable=SC1090 # Test files are only known at runtime.
  . "$2"
  setup
  "$3"
  exit 0
fi

# Settings from the environment would change the behaviour of supervise.sh.
for _v in $(env | sed -n -E 's/^(_?SUPERVISE_[A-Za-z0-9_]*)=.*/\1/p'); do
  unset "$_v"
done

[ "$#" -gt 0 ] || set -- "$TESTS_DIR"/test_*.sh

_timeout=
command -v timeout >/dev/null 2>&1 && _timeout="timeout $TEST_TIMEOUT"

_n=0
_failed=0
_out=$(mktemp)
trap 'rm -f "$_out"' EXIT
for _file in "$@"; do
  _file=$(cd "$(dirname "$_file")" && pwd)/$(basename "$_file")
  # shellcheck disable=SC2013 # Function names have no spaces.
  for _test in $(sed -n -E 's/^(test_[A-Za-z0-9_]+)\(\).*/\1/p' "$_file"); do
    [ -z "$TEST_ONLY" ] || case "$_test" in *$TEST_ONLY*) ;; *) continue;; esac
    _n=$((_n + 1))
    # shellcheck disable=SC2086 # Empty when there is no timeout command.
    if $_timeout "$TEST_SHELL" "$TESTS_DIR/run.sh" --one "$_file" "$_test" > "$_out" 2>&1 < /dev/null; then
      printf 'ok %d - %s: %s\n' "$_n" "$(basename "$_file")" "$_test"
    else
      _failed=$((_failed + 1))
      printf 'not ok %d - %s: %s\n' "$_n" "$(basename "$_file")" "$_test"
      sed 's/^/#   /' "$_out"
    fi
  done
done

printf '1..%d\n' "$_n"
if [ "$_failed" -gt 0 ]; then
  printf '# %d of %d tests failed\n' "$_failed" "$_n"
  exit 1
fi
printf '# All %d tests passed\n' "$_n"
