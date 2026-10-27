#!/bin/sh

# Shell sanity. Stop on errors, undefined variables and pipeline errors.
set -eu
# shellcheck disable=SC3040 # now part of POSIX, but not everywhere yet!
if set -o | grep -q 'pipefail'; then set -o pipefail; fi

# Default XDG directories.
: "${XDG_CONFIG_HOME:="$HOME/.config"}"
: "${XDG_DATA_HOME:="$HOME/.local/share"}"
: "${XDG_STATE_HOME:="$HOME/.local/state"}"
: "${XDG_RUNTIME_DIR:="${TMPDIR:-/tmp}/runtime-$(id -u)"}"

# All following vars have defaults here, but will be set and inherited from
# the calling tunnel.sh script.
: "${SUPERVISE_VERBOSE:=0}"

# Its name, for logging purposes. Defaults to the basename of the executable.
: "${SUPERVISE_NAME:=""}"

# Maximum delay between restarts, in seconds. Defaults to 120.
: "${SUPERVISE_MAXDELAY:="120"}"

usage() {
  # This uses the comments behind the options to show the help. Not extremely
  # correct, but effective and simple.
  echo "$0 Supervise a command and restart on errors." && \
    grep "[[:space:]].)[[:space:]][[:space:]]*#" "$0" |
    sed 's/#//' |
    sed -E 's/([a-zA-Z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^SUPERVISE_' | sed 's/^SUPERVISE_/    SUPERVISE_/g'
  exit "${1:-0}"
}

# shellcheck disable=SC2034 # Used for logging/usage
while getopts "n:vh-" opt; do
  case "$opt" in
    n) # Specify the name for logging purposes
      SUPERVISE_NAME=$OPTARG;;
    v) # Increase verbosity, repeat to increase
      SUPERVISE_VERBOSE=$((SUPERVISE_VERBOSE + 1));;
    h) # Show help
      usage 0 SUPERVISE
      ;;
    -) # End of options, binary and arguments to follow
      break;;
    *)  # Unknown option
      usage 1
      ;;
  esac
done
shift $((OPTIND - 1))

# PML: Poor Man's Logging on stderr
_log() {
  printf '[%s] [%s] [%s] ' \
    "$(basename "$0")" \
    "${1:-LOG}" \
    "$(date +'%Y%m%d-%H%M%S')" \
    >&2
  shift
  _fmt="$1"
  shift
  # shellcheck disable=SC2059 # ok, we want to use printf format
  printf "${_fmt}\n" "$@" >&2
}
trace() { [ "$SUPERVISE_VERBOSE" -ge "3" ] && _log TRC "$@" || true ; }
debug() { [ "$SUPERVISE_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$SUPERVISE_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@" && exit 1; }

# Print the item at the index at $1 of the remaining arguments. $1 is 0-indexed.
_index() {
  _idx=$1; shift
  shift "$_idx"
  printf %s\\n "$1"
}


# Non-entirely portable way to print all the descendants of the process which
# identifier is passed as a parameter. This uses the content of the /proc file
# system.
ps_children() (
  # This uses a () to force an extra process and have truly local vars.
  for _f in /proc/[0-9]*/stat; do
    # The name of the executable appears at the beginning between parenthesis.
    # Remove it.
    _stat=$(sed -E 's/\([^)]+\)\s//g' < "$_f")
    # If the parent process (3rd item) is the process passed as a parameter,
    # then we should count it.
    # shellcheck disable=SC2086 # We want to expand the arguments
    if [ "$(_index 2 $_stat)" = "$1" ]; then
      # The pid is also part of the stat file list, but also the name of the
      # directory. The following uses shell built-ins and is quicker.
      _pid=$(basename "$(dirname "$_f")")
      # Recurse first so we print the leaves first.
      ps_children "$_pid"
      printf %d\\n "$_pid"
    fi
  done
)


kill_tree() {
  [ -z "${1:-}" ] && error "kill_tree: must pass pid as first arg"
  for _pid in $(ps_children "$1"); do
    kill -"${2:-TERM}" "$_pid"
    printf %d\\n "$_pid"
  done
  kill -"${2:-TERM}" "$1"
  printf %d\\n "$1"
}


# Catch up the list of PIDs in _SUPERVISE_PIDS, removing any that have exited, add
# the ones passed as arguments if they are alive.
_spawn_update() {
  # Reconstruct the list of alive PIDs, by checking each PID in _SUPERVISE_PIDS. Any
  # PID passed as argument is to be added to the list, if it is alive.
  _alive_pids=
  for _pid in $_SUPERVISE_PIDS "$@"; do
    [ -z "${_pid:-}" ] && continue
    if kill -0 "$_pid" 2>/dev/null; then
      if [ -z "$_alive_pids" ]; then
        _alive_pids="$_pid"
      else
        _alive_pids="$_alive_pids $_pid"
      fi
    fi
  done
  _SUPERVISE_PIDS=$_alive_pids
  unset _alive_pids _pid || true
}


# Wait for the process with PID passed as $1 to exit. Returns the exit code of
# the process, or 0 if the process was already dead.
_spawn_wait() {
  [ -z "${1:-}" ] && return 0

  # Re-enter wait if interrupted by a signal before the process actually exits
  while kill -0 "$1" 2>/dev/null; do
    wait "$1" 2>/dev/null
    _wrc=$?
    if [ "$_wrc" -le 127 ]; then
      return "$_wrc"
    fi
  done

  return 0
}


# Wait for the processes with PIDs passed as arguments to exit. If no arguments
# are passed, wait for all PIDs in _SUPERVISE_PIDS. Returns the exit of the last
# process returning an error.
# shellcheck disable=SC2120 # API is to wait for all, or wait for some.
spawn_wait() {
  _ret=0

  # Decide upon the list of PIDs to wait for.
  _wait_pids=
  if [ "$#" -gt 0 ]; then
    _wait_pids="$*"
  else
    _wait_pids=$_SUPERVISE_PIDS
  fi

  # Wait in turns, remember last non-zero exit code.
  for _pid in $_wait_pids; do
    _spawn_wait "$_pid"
    _wrc=$?
    [ "$_wrc" -ne 0 ] && _ret=$_wrc
  done

  # Keep only processes that are still running.
  _spawn_update

  # Log and return the exit code of the last process that returned an error, if
  # any.
  [ -n "$_wait_pids" ] && debug "Spawned processes %s exited, returning %d" "$_wait_pids" "$_ret"
  unset _pid _wait_pids _wrc || true
  return "$_ret"
}


# Return the PID of the latest spawned process, or nothing if none are running.
spawn_latest() {
  printf '%s' "${_SUPERVISE_PIDS:-}" | tr ' ' '\n' | tail -n 1
}


# Send a signal to the process tree of each PID passed as argument, or to all
# PIDs in _SUPERVISE_PIDS if no arguments are passed. The signal to send is from the
# -s option, defaults to TERM.
spawn_kill() {
  _sigspec=TERM
  _tree=0
  _reason=unknown
  while getopts "r:s:t-" opt; do
    case "$opt" in
      r) # Specify the reason for logging purposes
        _reason=$OPTARG;;
      s) # Specify the sigspec
        _sigspec=$OPTARG;;
      t) # Specify whether to kill the process tree
        _tree=1;;
      -) # End of options, file name to follow
        break;;
      *)  # Unknown option
        error "spawn_kill: Unknown option $opt";;
    esac
  done
  shift $((OPTIND - 1))

  # Decide upon the list of PIDs to kill.
  _kill_pids=
  if [ "$#" -gt 0 ]; then
    _kill_pids="$*"
  else
    _kill_pids=$_SUPERVISE_PIDS
  fi

  # Kill the processes, or their trees.
  for _pid in $_kill_pids; do
    if [ "$_tree" -eq 1 ]; then
      debug "Killing tree of PID %d with signal %s. Reason: %s" "$_pid" "$_sigspec" "$_reason"
      kill_tree "$_pid" "$_sigspec" >/dev/null
    else
      debug "Killing PID %d with signal %s. Reason: %s" "$_pid" "$_sigspec" "$_reason"
      kill "-$_sigspec" "$_pid" 2>/dev/null || true
    fi
  done

  # Recapture the list of alive PIDs, since some may have exited.
  _spawn_update
  unset _pid _kill_pids _sigspec _tree || true
}


# Spawn a process in the background, and return its PID.
spawn() {
  _name=
  while getopts "n:-" opt; do
    case "$opt" in
      n) # Specify the name for logging purposes
        _name=$OPTARG;;
      -) # End of options, file name to follow
        break;;
      *)  # Unknown option
        error "spawn: Unknown option $opt";;
    esac
  done
  shift $((OPTIND - 1))

  # Sanity check on the executable.
  [ -z "${1:-}" ] && error "spawn: No executable given"
  [ -x "$1" ] || error "spawn: $1 is not executable"

  # Capture the executable and default name for logging purposes, if not already
  # set.
  _bin=$1
  shift
  [ -z "${_name:-}" ] && _name=$(basename "$_bin")

  # Spawn the process in the background, and remember its PID.
  trace "Spawning %s with arguments: %s" "$_bin" "$*"
  "$_bin" "$@" &
  _spawned=$!

  # Prune dead PIDs before appending, so the list only holds live processes. Add
  # the new PID to the list of live processes.
  _spawn_update "$_spawned"
  debug "Spawned %s with PID %d" "$_name" "$_spawned"

  # Install process-wide signal handlers if not already done.
  if [ "$_SUPERVISE_TRAPPED" = "0" ]; then
    trap 'spawn_kill -s HUP -r "HUP trap";  trap - HUP;  kill -HUP  $$' HUP
    trap 'spawn_kill -s INT -r "INT trap";  trap - INT;  kill -INT  $$' INT
    trap 'spawn_kill -s TERM -r "TERM trap"; spawn_wait || true; trap - TERM; kill -TERM $$' TERM
    # shellcheck disable=SC2154 # _spawn_exit set inside trap
    trap '_spawn_exit=$?; spawn_kill -s TERM -r "EXIT trap" || true; spawn_wait || true; trap - EXIT; exit "$_spawn_exit"' EXIT
    _SUPERVISE_TRAPPED=1
  fi

  # Return the PID of the spawned process, for convenience.
  printf %s\\n "$_spawned"
  unset _bin _name _spawned || true
}


[ "$#" -gt 0 ] || error "No arguments provided"
SUPERVISE_BINPATH=$(command -v "$1") || error "Executable $1 not found"
shift

[ -x "$SUPERVISE_BINPATH" ] || error "Executable $SUPERVISE_BINPATH not found or not executable"
[ -n "$SUPERVISE_NAME" ] || SUPERVISE_NAME=$(basename "$SUPERVISE_BINPATH")

_sup_running=1
_delay=0

while [ "$_sup_running" = "1" ]; do
  info "Starting %s at %s in the background" "$SUPERVISE_NAME" "$SUPERVISE_BINPATH"
  spawn "$SUPERVISE_BINPATH" "$@" > /dev/null
  _rc=0
  spawn_wait || _rc=$?
  [ "$_sup_running" = "0" ] && break
  [ "$_rc" -eq 0 ] && break
  debug "%s exited with %d, restarting in %d seconds" "$SUPERVISE_NAME" "$_rc" "$_delay"
  [ "$_delay" -gt 0 ] && sleep "$_delay" || true
  if [ "$_delay" -eq 0 ]; then
    _delay=1
  elif [ "$((_delay * 2))" -gt "$SUPERVISE_MAXDELAY" ]; then
    _delay="$SUPERVISE_MAXDELAY"
  else
    _delay=$((_delay * 2))
  fi
done
