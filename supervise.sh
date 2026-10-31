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

# All following vars have defaults here, and can be set from the environment or
# through the global options.

# Verbosity of the logs, from 0 (warnings and errors only) to 3 (traces).
: "${SUPERVISE_VERBOSE:=0}"

# Its name, for logging purposes. Defaults to the basename of the executable.
: "${SUPERVISE_NAME:=""}"

# Maximum delay between restarts, in seconds. Defaults to 120.
: "${SUPERVISE_MAXDELAY:="120"}"

# Path to the configuration file with the commands to supervise.
: "${SUPERVISE_PATH:="supervise.cfg"}"

# Size above which log files of the commands are rotated, in bytes, or with a k,
# M or G suffix. 0 disables rotation. Defaults to 10M.
: "${SUPERVISE_LOGSIZE:="10M"}"

# Number of rotated log files to keep. Defaults to 5.
: "${SUPERVISE_LOGKEEP:="5"}"

# Print the options documented in the getopts loop read from stdin.
_usage_options() {
  grep "[[:space:]][a-zA-Z-])[[:space:]][[:space:]]*#" |
    sed -E 's/^[[:space:]]*([a-zA-Z-])\)[[:space:]]*#[[:space:]]*/    -\1  /'
}

usage() {
  # This uses the comments behind the options to show the help. Not extremely
  # correct, but effective and simple. $1 is a one line summary, $2 the exit
  # code and $3 the function of a command, to show its options only.
  printf "%s Supervise a command and restart on errors.\n" "$0 "
  [ -z "${1:-}" ] || printf "%s\n" "$1"
  if [ -n "${3:-}" ]; then
    printf "Usage: %s [options] %s [options] [args...]\n" "$0" "${3#supervise_}"
  else
    printf "Usage: %s [options] <command> [options] [args...]\n" "$0"
  fi
  # Global options are parsed by the only getopts loop that is not indented.
  printf \\nOptions:\\n
  awk '/^while getopts/,/^done/' "$0" | _usage_options
  if [ -n "${3:-}" ]; then
    printf '\nOptions of %s:\n' "${3#supervise_}"
    awk "/^${3}\\(\\)/,/^}/" "$0" | _usage_options
  else
    # Commands and their summaries, from the -h option of each command. They are
    # shown in the order below, main commands first, utilities last. Commands
    # not in the list come after, in the order of the source.
    printf \\nCommands:\\n
    _tab=$(printf '\t')
    _cmds=$(sed -n -E 's/^[[:space:]]*usage "([a-z]+): ([^"]*)".*/    \1\t\2/p' "$0")
    _order="up down ps ls log run logger"
    {
      # Listed commands first, in the order given.
      for _c in $_order; do
        printf '%s\n' "$_cmds" | grep "^    ${_c}${_tab}" || true
      done
      # Then any other command, in the order of the source.
      printf '%s\n' "$_cmds" | grep -v -E "^    ($(printf %s "$_order" | tr ' ' '|'))${_tab}" || true
    } | expand -t 12
  fi
  printf \\nEnvironment:\\n
  set | grep '^SUPERVISE_' | sed 's/^SUPERVISE_/    SUPERVISE_/g'
  exit "${2:-0}"
}

# shellcheck disable=SC2034 # Used for logging/usage
while getopts "s:r:m:k:vh-" opt; do
  case "$opt" in
    s) # Path to the configuration file with the commands to supervise, defaults to supervise.cfg
      SUPERVISE_PATH=$OPTARG;;
    r) # Maximum delay between restarts, in seconds
      SUPERVISE_MAXDELAY=$OPTARG;;
    m) # Size above which logs are rotated, with k, M or G suffix, 0 to disable
      SUPERVISE_LOGSIZE=$OPTARG;;
    k) # Number of rotated log files to keep
      SUPERVISE_LOGKEEP=$OPTARG;;
    v) # Increase verbosity, repeat to increase
      SUPERVISE_VERBOSE=$((SUPERVISE_VERBOSE + 1));;
    h) # Show help
      usage "" 0
      ;;
    *)  # Unknown option
      usage "" 1 >&2
      ;;
  esac
done
shift $((OPTIND - 1))

# Test if printf can format the time, e.g. in bash, to avoid forking date at
# every log line. The result is kept in _SUPERVISE_PRINTF_TIME, 1 when
# supported, 0 otherwise, followed by a colon and a marker of the shell that
# ran the test. The variable is exported, so our sub-processes reuse the result
# when run by the same shell, and test again otherwise. Only tests once.
_printf_time_test() {
  _shell=${BASH_VERSION:-}${KSH_VERSION:-}${ZSH_VERSION:-}
  if [ -z "${_SUPERVISE_PRINTF_TIME:-}" ] || [ "${_SUPERVISE_PRINTF_TIME#*:}" != "$_shell" ]; then
    # shellcheck disable=SC3059 # Not POSIX, this is why it is tested.
    case "$(printf '%(%Y%m%d-%H%M%S)T' -1 2>/dev/null || true)" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
        _SUPERVISE_PRINTF_TIME=1:$_shell;;
      *)
        _SUPERVISE_PRINTF_TIME=0:$_shell;;
    esac
  fi
}

# PML: Poor Man's Logging on stderr, or appended to the log file when there is
# one, re-opened at each line so logging continues in a new file once rotated.
# Each line is a single write, so concurrent loggers do not mix lines.
_log() {
  _lvl=${1:-LOG}
  shift
  _fmt="$1"
  shift

  # The timestamp is formatted by printf itself, from the current time (-1), or
  # passed as a string from date.
  _printf_time_test
  if [ "${_SUPERVISE_PRINTF_TIME%%:*}" = "1" ]; then
    _tfmt='%(%Y%m%d-%H%M%S)T'
    _targ=-1
  else
    _tfmt='%s'
    _targ=$(date +'%Y%m%d-%H%M%S')
  fi

  # Logging never fails: when the log file cannot be written, e.g. its directory
  # is gone, log on stderr instead, and ignore errors there too. Otherwise, a
  # logger would exit, and the command it logs would die on its next write.
  if [ -n "${_SUPERVISE_LOGFILE:-}" ]; then
    # shellcheck disable=SC2059 # ok, we want to use printf format
    printf "[%s] [%s] [${_tfmt}] ${_fmt}\n" \
      "${_SUPERVISE_LOGNAME:-${0##*/}}" "$_lvl" "$_targ" "$@" \
      2>/dev/null >> "$_SUPERVISE_LOGFILE" && return 0
  fi
  # shellcheck disable=SC2059 # ok, we want to use printf format
  printf "[%s] [%s] [${_tfmt}] ${_fmt}\n" \
    "${_SUPERVISE_LOGNAME:-${0##*/}}" "$_lvl" "$_targ" "$@" \
    >&2 2>/dev/null || true
}
trace() { [ "$SUPERVISE_VERBOSE" -ge "3" ] && _log TRC "$@" || true ; }
debug() { [ "$SUPERVISE_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$SUPERVISE_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@"; exit 1; }

# Print the descendants of the process passed as $1, leaves first, from the
# pid:ppid pairs passed as the remaining arguments.
_ps_descendants() {
  _ppid=$1
  shift
  for _pair in "$@"; do
    case "$_pair" in
      *":$_ppid")
        # Recurse in a subshell, so it does not modify our variables.
        ( _ps_descendants "${_pair%%:*}" "$@" )
        printf %d\\n "${_pair%%:*}";;
    esac
  done
}


# Non-entirely portable way to print all the descendants of the process which
# identifier is passed as a parameter, leaves first. This uses the content of
# the /proc file system, read once and with shell built-ins only, for speed.
ps_children() (
  # This uses a () to force an extra process and have truly local vars.
  _parent=$1
  # Collect all processes as pid:ppid pairs.
  _pairs=
  for _f in /proc/[0-9]*/stat; do
    # Processes can exit at any time, skip the ones that are gone.
    { IFS= read -r _stat < "$_f"; } 2>/dev/null || continue
    # The name of the executable appears at the beginning between parenthesis,
    # and can contain spaces and parenthesis. Remove up to the last one, the
    # parent process is then the 2nd item, after the state.
    # shellcheck disable=SC2086 # We want to split the fields
    set -- ${_stat##*) }
    _pid=${_f%/stat}
    _pairs="$_pairs ${_pid#/proc/}:$2"
  done
  # shellcheck disable=SC2086 # We want to split the pairs
  _ps_descendants "$_parent" $_pairs
)

# Send the signal $2 (default: TERM) to the process which PID is $1 and all its
# descendants, and print their PIDs, leaves first. The tree is frozen first,
# so no process can create new ones between listing and signalling them.
kill_tree() {
  [ -z "${1:-}" ] && error "kill_tree: must pass pid as first arg"
  # Stop the root, then its descendants, listing them again until no new one
  # appears. Bounded, in case processes keep appearing faster than stopped.
  kill -STOP "$1" 2>/dev/null || true
  _kt_tree=
  _kt_round=0
  while [ "$_kt_round" -lt 10 ]; do
    _kt_found=$(ps_children "$1")
    for _kt_pid in $_kt_found; do
      kill -STOP "$_kt_pid" 2>/dev/null || true
    done
    [ "$_kt_found" = "$_kt_tree" ] && break
    _kt_tree=$_kt_found
    _kt_round=$((_kt_round + 1))
  done

  # Signal the frozen tree, then resume it so the processes can handle the
  # signal. Processes may have exited in the meantime, ignore those.
  for _kt_pid in $_kt_tree "$1"; do
    kill -"${2:-TERM}" "$_kt_pid" 2>/dev/null || true
    printf %d\\n "$_kt_pid"
  done
  for _kt_pid in $_kt_tree "$1"; do
    kill -CONT "$_kt_pid" 2>/dev/null || true
  done
  unset _kt_tree _kt_round _kt_found _kt_pid || true
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
# the process, even if it had already exited.
_spawn_wait() {
  [ -z "${1:-}" ] && return 0

  # Always wait at least once: a process that has already exited is gone from
  # kill -0, but wait still returns its exit code. Re-enter wait if interrupted
  # by a signal before the process actually exits.
  while true; do
    _wrc=0
    wait "$1" 2>/dev/null || _wrc=$?
    if [ "$_wrc" -le 127 ] || ! kill -0 "$1" 2>/dev/null; then
      return "$_wrc"
    fi
  done
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
  _SPAWN_KILL_SIGSPEC=TERM
  _SPAWN_KILL_TREE=0
  _SPAWN_KILL_REASON=unknown
  OPTIND=1
  while getopts "r:s:t-" opt; do
    case "$opt" in
      r) # Specify the reason for logging purposes
        _SPAWN_KILL_REASON=$OPTARG;;
      s) # Specify the sigspec
        _SPAWN_KILL_SIGSPEC=$OPTARG;;
      t) # Specify whether to kill the process tree
        _SPAWN_KILL_TREE=1;;
      -) # End of options, file name to follow
        break;;
      *)  # Unknown option
        error "spawn_kill: Unknown option %s" "$opt";;
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
    if [ "$_SPAWN_KILL_TREE" -eq 1 ]; then
      debug "Killing tree of PID %d with signal %s. Reason: %s" "$_pid" "$_SPAWN_KILL_SIGSPEC" "$_SPAWN_KILL_REASON"
      kill_tree "$_pid" "$_SPAWN_KILL_SIGSPEC" >/dev/null
    else
      debug "Killing PID %d with signal %s. Reason: %s" "$_pid" "$_SPAWN_KILL_SIGSPEC" "$_SPAWN_KILL_REASON"
      kill "-$_SPAWN_KILL_SIGSPEC" "$_pid" 2>/dev/null || true
    fi
  done

  # Recapture the list of alive PIDs, since some may have exited.
  _spawn_update
  unset _pid _kill_pids _SPAWN_KILL_SIGSPEC _SPAWN_KILL_TREE _SPAWN_KILL_REASON || true
}


# Install process-wide signal handlers that terminate the process trees of all
# spawned processes when this process is signalled or exits. Processes that
# should outlive this one must be spawned without calling this.
spawn_init() {
  trap 'spawn_kill -t -s HUP -r "HUP trap";  trap - HUP;  kill -HUP  $$' HUP
  trap 'spawn_kill -t -s INT -r "INT trap";  trap - INT;  kill -INT  $$' INT
  trap 'spawn_kill -t -s TERM -r "TERM trap"; spawn_wait || true; trap - TERM; kill -TERM $$' TERM
  # shellcheck disable=SC2154 # _spawn_exit set inside trap
  trap '_spawn_exit=$?; spawn_kill -t -s TERM -r "EXIT trap" || true; spawn_wait || true; trap - EXIT; exit "$_spawn_exit"' EXIT
}

# Spawn a process in the background, and return its PID. Unless -o is given,
# its stdout and stderr are logged.
spawn() {
  _SPAWN_NAME=
  _SPAWN_OUT=
  OPTIND=1
  while getopts "n:o:-" opt; do
    case "$opt" in
      n) # Specify the name for logging purposes
        _SPAWN_NAME=$OPTARG;;
      o) # Append stdout and stderr to this file, instead of logging them
        _SPAWN_OUT=$OPTARG;;
      -) # End of options, file name to follow
        break;;
      *)  # Unknown option
        error "spawn: Unknown option %s" "$opt";;
    esac
  done
  shift $((OPTIND - 1))

  # Sanity check on the executable.
  [ -z "${1:-}" ] && error "spawn: No executable given"
  [ -x "$1" ] || error "spawn: %s is not executable" "$1"

  # Capture the executable and default name for logging purposes, if not already
  # set.
  _bin=$1
  shift
  [ -z "${_SPAWN_NAME:-}" ] && _SPAWN_NAME=$(basename "$_bin")

  # Spawn the process in the background, and remember its PID. Test printf
  # first, so the process, and our loggers, inherit the result.
  _printf_time_test
  trace "Spawning %s with arguments: %s" "$_bin" "$*"
  if [ -n "$_SPAWN_OUT" ]; then
    _SUPERVISE_LOGFILE=$_SPAWN_OUT "$_bin" "$@" >> "$_SPAWN_OUT" 2>&1 &
  else
    # Route stdout and stderr to separate loggers through FIFOs, so $! remains
    # the PID of the executable. Each logger removes its FIFO once opened, the
    # last one to do so also removes the directory.
    _fifo_dir=$(mktemp -d)
    mkfifo "$_fifo_dir/out" "$_fifo_dir/err"
    # shellcheck disable=SC2094,SC2086 # FIFOs only removed, shell may be empty.
    { rm -f "$_fifo_dir/out"; rmdir "$_fifo_dir" 2>/dev/null || true; $_SUPERVISE_SHELL "$0" logger -n "$_SPAWN_NAME" OUT; } < "$_fifo_dir/out" > /dev/null &
    # shellcheck disable=SC2094,SC2086 # FIFOs only removed, shell may be empty.
    { rm -f "$_fifo_dir/err"; rmdir "$_fifo_dir" 2>/dev/null || true; $_SUPERVISE_SHELL "$0" logger -n "$_SPAWN_NAME" ERR; } < "$_fifo_dir/err" > /dev/null &
    "$_bin" "$@" > "$_fifo_dir/out" 2> "$_fifo_dir/err" &
  fi
  _spawned=$!

  # Prune dead PIDs before appending, so the list only holds live processes. Add
  # the new PID to the list of live processes.
  _spawn_update "$_spawned"
  debug "Spawned %s with PID %d" "$_SPAWN_NAME" "$_spawned"

  # Return the PID of the spawned process, for convenience.
  printf %s\\n "$_spawned"
  unset _bin _SPAWN_NAME _SPAWN_OUT _spawned _fifo_dir || true
}

# Fail unless $1 is a non-negative integer. $2 describes what it is, for the
# error message, and $3 is the value to show in that message, defaults to $1.
validate_number() {
  case "$1" in
    '' | *[!0-9]*) error "Invalid %s: %s" "$2" "${3:-$1}";;
  esac
}

# Convert the size passed as $1, in bytes or with a k, M or G suffix, to bytes.
_bytes() {
  case "$1" in
    *[kK]) _n=${1%?}; _m=1024;;
    *[mM]) _n=${1%?}; _m=1048576;;
    *[gG]) _n=${1%?}; _m=1073741824;;
    *) _n=$1; _m=1;;
  esac
  validate_number "$_n" size "$1"
  printf %d\\n "$((_n * _m))"
  unset _n _m || true
}

# Rotate the log file passed as $1 when it is larger than SUPERVISE_LOGSIZE,
# keeping SUPERVISE_LOGKEEP older copies, named .1 (newest) to .N (oldest). The
# file is renamed: _log re-opens it at each line, so no line is lost. A lock
# directory prevents concurrent rotations, e.g. by the OUT and ERR loggers. A
# lock older than a minute is stale, left by a logger killed while rotating,
# and is removed.
_log_rotate() {
  [ -n "${1:-}" ] || return 0
  _max=$(_bytes "$SUPERVISE_LOGSIZE")
  [ "$_max" -gt 0 ] || return 0
  _size=$(wc -c < "$1" 2>/dev/null) || return 0
  [ "$((_size))" -ge "$_max" ] || return 0
  if ! mkdir "${1}.lock" 2>/dev/null; then
    [ -n "$(find "${1}.lock" -prune -mmin +1 2>/dev/null)" ] || return 0
    # Rename before removing, so only one logger removes the stale lock.
    mv "${1}.lock" "${1}.lock.$$" 2>/dev/null || return 0
    rmdir "${1}.lock.$$" 2>/dev/null || true
    debug "Removed stale lock on %s" "$1"
    mkdir "${1}.lock" 2>/dev/null || return 0
  fi

  _i=$SUPERVISE_LOGKEEP
  rm -f "${1}.${_i}"
  while [ "$_i" -gt 1 ]; do
    [ -f "${1}.$((_i - 1))" ] && mv -f "${1}.$((_i - 1))" "${1}.${_i}"
    _i=$((_i - 1))
  done
  if [ "$SUPERVISE_LOGKEEP" -gt 0 ]; then
    # Recreate the file at once, so followers switch to it without delay.
    mv -f "$1" "${1}.1"
    : >> "$1"
  else
    : > "$1"
  fi

  rmdir "${1}.lock"
  unset _max _size _i || true
}

# Log each line read from stdin, using the stream name passed as $1 (e.g. OUT
# or ERR) as the log level. The -n option sets the name to log under.
supervise_logger() {
  OPTIND=1
  while getopts "n:h" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "logger: Log lines from stdin under a stream name, used internally" 0 supervise_logger;;
      n) # Specify the name for logging purposes
        _SUPERVISE_LOGNAME=$OPTARG;;
      *)  # Unknown option
        usage "" 1 supervise_logger >&2;;
    esac
  done
  shift $((OPTIND - 1))

  [ "$#" -gt 0 ] || error "logger: No stream name given"
  _stream=$(printf %s "$1" | tr '[:lower:]' '[:upper:]')
  # Rotate the log file when needed. Its size is only checked every 4k logged,
  # estimated from the lengths of the lines and their prefix, to save forks.
  # Failing to rotate, e.g. when the directory is gone, must not stop logging.
  _log_rotate "$_SUPERVISE_LOGFILE" || true
  _logged=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _log "$_stream" '%s' "$_line"
    _logged=$((_logged + ${#_line} + 50))
    if [ "$_logged" -ge 4096 ]; then
      _log_rotate "$_SUPERVISE_LOGFILE" || true
      _logged=0
    fi
  done
  unset _stream _line _logged || true
}

# Print the name of the directories for the file at SUPERVISE_PATH: its
# basename, made safe, followed by a short md5 of its resolved path. Only the
# path is used, so the directories stay the same when the file is edited.
_config_id() {
  _path=$(readlink -f "$SUPERVISE_PATH")
  printf '%s-%s\n' \
    "$(basename "$_path" | tr -c 'A-Za-z0-9._\n-' '_')" \
    "$(printf %s "$_path" | md5sum | cut -c 1-12)"
  unset _path || true
}

# Wait up to 10 seconds in total for the processes passed as arguments to exit.
# They are not children of this process, so poll for them to be gone. Fails
# when some are still running.
_wait_gone() {
  _wtimeout=10
  _wrc=0
  for _wpid in "$@"; do
    while kill -0 "$_wpid" 2>/dev/null && [ "$_wtimeout" -gt 0 ]; do
      sleep 1
      _wtimeout=$((_wtimeout - 1))
    done
    if kill -0 "$_wpid" 2>/dev/null; then
      warn "PID %d still running" "$_wpid"
      _wrc=1
    fi
  done
  unset _wpid _wtimeout || true
  return "$_wrc"
}

# Print the start time of the process which PID is $1, in clock ticks since
# boot, the 22nd field of its stat file. Fails when the process is gone.
_pid_start() {
  { IFS= read -r _stat < "/proc/$1/stat"; } 2>/dev/null || return 1
  # Remove the name of the executable, the state is then the 1st field.
  # shellcheck disable=SC2086 # We want to split the fields
  set -- ${_stat##*) }
  printf %s\\n "${20}"
}

# Print the PID passed as $1, followed by the start time of the process, for
# storage in a PID file. Prints nothing when there is no such process.
_pid_record() {
  [ -n "${1:-}" ] || return 0
  _rstart=$(_pid_start "$1") || return 0
  printf '%s %s\n' "$1" "$_rstart"
}

supervise_run() {
  OPTIND=1
  while getopts "n:h-" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "run: Run a single command, restarting it when it fails" 0 supervise_run;;
      n) # Specify the name for logging purposes
        SUPERVISE_NAME=$OPTARG;;
      -) # End of options, binary and arguments to follow
        break;;
      *)  # Unknown option
        usage "" 1 supervise_run >&2
        ;;
    esac
  done
  shift $((OPTIND - 1))

  # Terminate the command, and its process tree, when terminated.
  spawn_init

  [ "$#" -gt 0 ] || error "Nothing to run"
  SUPERVISE_BINPATH=$(command -v "$1") || error "Executable %s not found" "$1"
  shift

  [ -x "$SUPERVISE_BINPATH" ] || error "Executable %s not found or not executable" "$SUPERVISE_BINPATH"
  [ -n "$SUPERVISE_NAME" ] || SUPERVISE_NAME=$(basename "$SUPERVISE_BINPATH")

  _delay=0

  while true; do
    info "Starting %s at %s in the background" "$SUPERVISE_NAME" "$SUPERVISE_BINPATH"
    spawn -n "$SUPERVISE_NAME" "$SUPERVISE_BINPATH" "$@" > /dev/null
    if [ -n "$_SUPERVISE_STATEDIR" ]; then
      _pid_record "$(spawn_latest)" > "${_SUPERVISE_STATEDIR}/${SUPERVISE_NAME}.pid"
    fi
    _rc=0
    spawn_wait || _rc=$?
    if [ -n "$_SUPERVISE_STATEDIR" ]; then
      printf %d\\n "$_rc" > "${_SUPERVISE_STATEDIR}/${SUPERVISE_NAME}.exit"
    fi
    [ "$_rc" -eq 0 ] && break
    debug "%s exited with %d, restarting in %d seconds" "$SUPERVISE_NAME" "$_rc" "$_delay"
    # Sleep in the background, so signal traps fire at once, e.g. on down.
    if [ "$_delay" -gt 0 ]; then
      sleep "$_delay" &
      wait $! || true
    fi
    if [ "$_delay" -eq 0 ]; then
      _delay=1
    elif [ "$((_delay * 2))" -gt "$SUPERVISE_MAXDELAY" ]; then
      _delay="$SUPERVISE_MAXDELAY"
    else
      _delay=$((_delay * 2))
    fi
  done
}

# Print the PID stored in the file passed as $1, if that process is alive. The
# start time stored with the PID must match, so a PID reused by another
# process, e.g. after a reboot, is not mistaken for the process recorded.
_alive_pid() {
  [ -f "$1" ] || return 1
  read -r _apid _astart < "$1" || return 1
  [ -n "$_apid" ] && [ -n "${_astart:-}" ] || return 1
  [ "$(_pid_start "$_apid" || true)" = "$_astart" ] || return 1
  printf %s\\n "$_apid"
}

# Print the commands from the file at SUPERVISE_PATH, one per line, as their
# name and command line separated by a tab. Empty lines and lines starting with
# # are ignored. Other lines contain a command, optionally preceded by a name and
# a colon. Without a name, the basename of the program is used, as run does.
# Names are made unique: when a name is already taken, it is suffixed with the
# first free index, e.g. sh, sh-2, sh-3. Names given in the file are kept when
# possible, names derived from programs never take them.
# shellcheck disable=SC2094,SC2120 # File only read, $1 is set from commands.
_config_entries() (
  # This uses a () to force an extra process and have truly local vars.
  _tab=$(printf '\t')
  # First pass: collect the commands, marking names given in the file with a +
  # and derived names with a -, and remember the names given.
  _given=" "
  _entries=
  while IFS= read -r _line || [ -n "$_line" ]; do
    # Trim leading and trailing spaces, skip empty lines and comments.
    _line=$(printf %s "$_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$_line" in
      '' | '#'*) continue;;
    esac

    # Split away the name, if any. Names cannot contain spaces, so that commands
    # with colons in their arguments are not mistaken for names.
    _name=
    _cmd=$_line
    if printf %s "$_line" | grep -qE '^[A-Za-z0-9_.-]+[[:space:]]*:'; then
      _name=${_line%%:*}
      _name=${_name%%[[:space:]]*}
      _cmd=$(printf %s "${_line#*:}" | sed -E 's/^[[:space:]]+//')
    fi
    if [ -z "$_cmd" ]; then
      warn "No command for %s in %s, skipping" "$_name" "$SUPERVISE_PATH"
      continue
    fi
    if [ -n "$_name" ]; then
      _given="${_given}${_name} "
      _kind=+
    else
      eval "set -- $_cmd"
      _name=$(basename "$1")
      _kind=-
    fi
    _entries="${_entries}${_kind}${_name}${_tab}${_cmd}
"
  done < "$SUPERVISE_PATH"

  # Second pass: make the names unique.
  _taken=" "
  while IFS=$_tab read -r _name _cmd; do
    [ -z "$_name" ] && continue
    _kind=${_name%"${_name#?}"}
    _name=${_name#?}
    # Derived names also avoid the names given in the file.
    _avoid=$_taken
    [ "$_kind" = "-" ] && _avoid="${_taken}${_given}"
    case "$_avoid" in
      *" $_name "*)
        _i=2
        while case "${_taken}${_given}" in *" ${_name}-${_i} "*) true;; *) false;; esac; do
          _i=$((_i + 1))
        done
        [ "$_kind" = "+" ] && warn "Duplicate name %s in %s, renamed to %s" "$_name" "$SUPERVISE_PATH" "${_name}-${_i}"
        _name=${_name}-${_i};;
    esac
    _taken="${_taken}${_name} "
    printf '%s\t%s\n' "$_name" "$_cmd"
  done <<EOF
$_entries
EOF
)

# Return success if any of the commands which names are in _names is alive.
_up_alive() {
  for _aname in $_names; do
    _alive_pid "${_SUPERVISE_STATEDIR}/${_aname}.run" >/dev/null && return 0
  done
  return 1
}

# Stop the commands started by up from the file at SUPERVISE_PATH, or only the
# ones which names are passed as arguments. The run process of each command is
# terminated, which terminates the command itself.
supervise_down() {
  OPTIND=1
  while getopts "h" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "down: Stop the commands started from the configuration file" 0 supervise_down;;
      *)  # Unknown option
        usage "" 1 supervise_down >&2;;
    esac
  done
  shift $((OPTIND - 1))

  # Only the path matters, the file itself may have changed or be gone.
  [ -n "$SUPERVISE_PATH" ] || error "down: No file given, use -s"

  _statedir=${XDG_STATE_HOME}/supervise/$(_config_id)
  if [ ! -d "$_statedir" ]; then
    warn "down: Nothing started from %s" "$SUPERVISE_PATH"
    return 0
  fi

  # Without names, stop all the commands which run process is known.
  if [ "$#" -eq 0 ]; then
    for _f in "$_statedir"/*.run; do
      [ -f "$_f" ] || continue
      set -- "$@" "$(basename "$_f" .run)"
    done
  fi

  # Terminate the run processes, remembering them as name:pid pairs.
  _stopping=
  _pids=
  _gone=
  for _name in "$@"; do
    _f=${_statedir}/${_name}.run
    if [ ! -f "$_f" ]; then
      warn "down: No command named %s started from %s" "$_name" "$SUPERVISE_PATH"
      continue
    fi
    if _pid=$(_alive_pid "$_f"); then
      info "down: Stopping %s, PID %d" "$_name" "$_pid"
      kill -TERM "$_pid"
      _stopping="$_stopping ${_name}:${_pid}"
      _pids="$_pids $_pid"
    else
      debug "down: %s was not running" "$_name"
      _gone="$_gone $_name"
    fi
  done

  # Wait for them to exit. Forget the state of the commands that are gone, but
  # keep it for the ones still running, so they can still be found.
  _rc=0
  # shellcheck disable=SC2086 # We want to split the PIDs
  _wait_gone $_pids || true
  for _pair in $_stopping; do
    if kill -0 "${_pair##*:}" 2>/dev/null; then
      warn "down: %s did not stop, keeping its state" "${_pair%%:*}"
      _rc=1
    else
      _gone="$_gone ${_pair%%:*}"
    fi
  done
  for _name in $_gone; do
    rm -f "${_statedir}/${_name}.run" "${_statedir}/${_name}.pid" \
      "${_statedir}/${_name}.cmd" "${_statedir}/${_name}.exit"
  done
  unset _statedir _f _name _pid _stopping _pids _gone _pair || true
  return "$_rc"
}

# Stop the commands started by up that are still alive, and the followers of
# their logs. Ended commands are left alone, to keep their exit codes.
_up_stop() {
  trap - HUP INT TERM
  _alive=
  for _aname in $_started; do
    _alive_pid "${_SUPERVISE_STATEDIR}/${_aname}.run" >/dev/null && _alive="$_alive $_aname"
  done
  # shellcheck disable=SC2086 # We want to split the names
  [ -z "$_alive" ] || supervise_down $_alive || true
  # shellcheck disable=SC2086 # We want to split the PIDs
  kill $_tails 2>/dev/null || true
}

# Supervise all commands from the file at SUPERVISE_PATH (see _config_entries),
# each in the background through the run command, logging to files. When names
# are passed as arguments, only the commands with these names are supervised.
# Commands always run detached. With -d, up returns at once. Otherwise, up
# follows their logs until they have all ended, and stops the ones it started
# when interrupted.
supervise_up() {
  _SUPERVISE_UP_DETACH=0
  OPTIND=1
  while getopts "dh" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "up: Start the commands from the configuration file" 0 supervise_up;;
      d) # Detach: return at once, leaving commands running in the background
        _SUPERVISE_UP_DETACH=1;;
      *)  # Unknown option
        usage "" 1 supervise_up >&2;;
    esac
  done
  shift $((OPTIND - 1))

  [ -n "$SUPERVISE_PATH" ] || error "up: No file given, use -s"
  [ -r "$SUPERVISE_PATH" ] || error "up: Cannot read %s" "$SUPERVISE_PATH"

  # Create a state directory unique to this configuration file. The run commands
  # store the PIDs of their commands there. Remember where the file is, to
  # identify the directory.
  _id=$(_config_id)
  _SUPERVISE_STATEDIR=${XDG_STATE_HOME}/supervise/${_id}
  mkdir -p "$_SUPERVISE_STATEDIR"
  readlink -f "$SUPERVISE_PATH" > "${_SUPERVISE_STATEDIR}/config.path"
  debug "up: Storing PIDs in %s" "$_SUPERVISE_STATEDIR"

  # Logs go to the same subdirectory under the runtime directory, created
  # private as the XDG spec requires.
  _logdir=${XDG_RUNTIME_DIR}/supervise/${_id}
  (umask 077 && mkdir -p "$_logdir")
  debug "up: Storing logs in %s" "$_logdir"
  unset _id || true

  # Select the commands to supervise: all, or the ones which names are given.
  _tab=$(printf '\t')
  _entries=$(_config_entries)
  _names=
  while IFS=$_tab read -r _cname _cmd; do
    [ -z "$_cname" ] && continue
    if [ "$#" -gt 0 ]; then
      case " $* " in *" $_cname "*) ;; *) continue;; esac
    fi
    _names="$_names $_cname "
  done <<EOS
$_entries
EOS
  for _cname in "$@"; do
    case "$_names" in
      *" $_cname "*) ;;
      *) warn "up: No command named %s in %s" "$_cname" "$SUPERVISE_PATH";;
    esac
  done

  # When attached, follow the logs of the selected commands, starting after
  # their current content, before any command is started so no line is lost.
  # Files are created first: tail misses the first lines of files that appear
  # later. They are followed by name, so rotations are followed.
  _tails=
  if [ "$_SUPERVISE_UP_DETACH" = "0" ]; then
    for _cname in $_names; do
      _f=${_logdir}/${_cname}.log
      : >> "$_f"
      _lines=$(wc -l < "$_f")
      tail -F -n +$((_lines + 1)) "$_f" 2>/dev/null &
      _tails="$_tails $!"
    done
  fi

  # Commands run detached: spawn_init is not called, and they ignore HUP so they
  # survive this process and the terminal. Let them inherit the global settings
  # and the state directory.
  trap '' HUP
  export SUPERVISE_VERBOSE SUPERVISE_MAXDELAY SUPERVISE_LOGSIZE SUPERVISE_LOGKEEP _SUPERVISE_STATEDIR

  _started=
  while IFS=$_tab read -r _cname _cmd; do
    case "$_names" in *" $_cname "*) ;; *) continue;; esac

    # Split the command into words, respecting quotes, and run it. stdin is
    # closed so commands do not consume the rest of the file.
    eval "set -- $_cmd"

    # Do not start commands twice. Their command line is remembered, so that
    # commands changed in the file since they were started are restarted.
    if _pid=$(_alive_pid "${_SUPERVISE_STATEDIR}/${_cname}.run"); then
      if [ "$(cat "${_SUPERVISE_STATEDIR}/${_cname}.cmd" 2>/dev/null || true)" = "$_cmd" ]; then
        info "up: %s already running, PID %d" "$_cname" "$_pid"
        continue
      fi
      info "up: %s changed, restarting it, PID %d" "$_cname" "$_pid"
      kill -TERM "$_pid"
      if ! _wait_gone "$_pid"; then
        warn "up: %s did not stop, not starting its new command" "$_cname"
        continue
      fi
    fi

    # Forget the exit code of a previous run before starting a new one.
    rm -f "${_SUPERVISE_STATEDIR}/${_cname}.exit"
    info "up: Supervising %s" "$_cmd"
    # shellcheck disable=SC2086 # Empty when this script is executable.
    spawn -o "${_logdir}/${_cname}.log" -n "$_cname" $_SUPERVISE_SHELL "$0" run -n "$_cname" -- "$@" < /dev/null > /dev/null
    # Remember the PID of the run process, so down can stop it.
    _pid_record "$(spawn_latest)" > "${_SUPERVISE_STATEDIR}/${_cname}.run"
    printf %s\\n "$_cmd" > "${_SUPERVISE_STATEDIR}/${_cname}.cmd"
    _started="$_started $_cname"
  done <<EOS
$_entries
EOS
  unset _tab _entries _cmd _pid _f _lines || true

  if [ "$_SUPERVISE_UP_DETACH" = "1" ]; then
    info "up: Detached, logs in %s" "$_logdir"
    unset _SUPERVISE_UP_DETACH _logdir _names _started _tails _cname || true
    return 0
  fi

  # When interrupted, stop the commands started here, but not the ones that
  # were already running.
  trap '_up_stop; exit 129' HUP
  trap '_up_stop; exit 130' INT
  trap '_up_stop; exit 143' TERM

  # Wait for all selected commands to end. Sleep in the background, so traps
  # fire at once. Give the followers a moment to print the last lines.
  while _up_alive; do
    sleep 1 &
    wait $! || true
  done
  sleep 1
  trap - HUP INT TERM
  # shellcheck disable=SC2086 # We want to split the PIDs
  kill $_tails 2>/dev/null || true

  # Return the first failure of the commands started here, if any.
  _rc=0
  for _cname in $_started; do
    _exit=$(cat "${_SUPERVISE_STATEDIR}/${_cname}.exit" 2>/dev/null || echo 0)
    if [ "$_rc" = "0" ] && [ "$_exit" != "0" ]; then
      _rc=$_exit
    fi
  done
  unset _SUPERVISE_UP_DETACH _logdir _names _started _tails _cname _exit || true
  return "$_rc"
}

# Print the content of the log files passed as arguments, each preceded by its
# rotated copies, oldest first. Rotated copies are found by name, not counted
# from SUPERVISE_LOGKEEP, which may differ from when they were rotated.
_log_cat() {
  for _lf in "$@"; do
    for _i in $(
      for _rf in "${_lf}".[0-9]*; do
        case "${_rf##*.}" in
          '' | *[!0-9]*) ;;
          *) [ -f "$_rf" ] && printf '%s\n' "${_rf##*.}";;
        esac
      done | sort -rn
    ); do
      cat "${_lf}.${_i}"
    done
    cat "$_lf"
  done
  unset _lf _i || true
}

# Show the logs of the commands started by up -d from the file at
# SUPERVISE_PATH, or only of the ones which names are passed as arguments. Logs
# of several commands are merged in chronological order.
supervise_log() {
  _SUPERVISE_LOG_LINES=
  _SUPERVISE_LOG_FOLLOW=0
  OPTIND=1
  while getopts "n:fh" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "log: Show the logs of the commands started from the configuration file" 0 supervise_log;;
      n) # Number of lines to show at the end of the logs, default: all
        _SUPERVISE_LOG_LINES=$OPTARG;;
      f) # Follow the logs, waiting for more lines to appear
        _SUPERVISE_LOG_FOLLOW=1;;
      *)  # Unknown option
        usage "" 1 supervise_log >&2;;
    esac
  done
  shift $((OPTIND - 1))
  [ -z "$_SUPERVISE_LOG_LINES" ] || validate_number "$_SUPERVISE_LOG_LINES" "number of lines"

  # Only the path matters, the file itself may have changed or be gone.
  [ -n "$SUPERVISE_PATH" ] || error "log: No file given, use -s"

  _logdir=${XDG_RUNTIME_DIR}/supervise/$(_config_id)
  if [ ! -d "$_logdir" ]; then
    warn "log: No logs for %s, commands are only logged with up -d" "$SUPERVISE_PATH"
    return 0
  fi

  # Replace the names with the paths to their log files, or use all log files
  # when no names are given.
  if [ "$#" -eq 0 ]; then
    for _f in "$_logdir"/*.log; do
      [ -f "$_f" ] && set -- "$@" "$_f"
    done
  else
    for _name in "$@"; do
      shift
      if [ -f "${_logdir}/${_name}.log" ]; then
        set -- "$@" "${_logdir}/${_name}.log"
      else
        warn "log: No logs for command %s" "$_name"
      fi
    done
  fi
  if [ "$#" -eq 0 ]; then
    warn "log: No logs found in %s" "$_logdir"
    return 0
  fi

  # Merge on the timestamp, i.e. the 3rd field, keeping the order of lines from
  # the same second, rotated files included. Then follow new lines from all
  # files, if requested, across rotations.
  if [ -n "$_SUPERVISE_LOG_LINES" ]; then
    _log_cat "$@" | sort -s -k3,3 | tail -n "$_SUPERVISE_LOG_LINES"
  else
    _log_cat "$@" | sort -s -k3,3
  fi
  if [ "$_SUPERVISE_LOG_FOLLOW" = "1" ]; then
    exec tail -q -n 0 -F "$@" 2>/dev/null
  fi
  unset _SUPERVISE_LOG_LINES _SUPERVISE_LOG_FOLLOW _logdir _f _name || true
}

# Print the ps line of the command which name is $1, using the state in
# _statedir. $2 is its command line in the file at SUPERVISE_PATH, empty when it
# is not in the file anymore.
_ps_line() {
  _state=stopped
  _rpid=-
  _cpid=-
  _uptime=-
  _scmd=$(cat "${_statedir}/${1}.cmd" 2>/dev/null || true)
  # Exit code of the last run of the command, if any.
  _exit=$(cat "${_statedir}/${1}.exit" 2>/dev/null || true)
  if _rpid=$(_alive_pid "${_statedir}/${1}.run"); then
    # The run process is alive, the command might be waiting to restart.
    if _cpid=$(_alive_pid "${_statedir}/${1}.pid"); then
      _state=running
      _uptime=$(ps -o etime= -p "$_cpid" | tr -d ' ')
    else
      _state=restarting
      _cpid=-
    fi
    if [ -z "$2" ]; then
      _state="${_state},removed"
    elif [ "$_scmd" != "$2" ]; then
      _state="${_state},changed"
    fi
  else
    # Supervision ended: either the command succeeded, or it was never started
    # or stopped by down, which forgets its state.
    [ -n "$_exit" ] && _state=exited
    _rpid=-
    _scmd=${2:-$_scmd}
  fi
  printf '%-15s %-18s %8s %8s %10s %4s  %s\n' \
    "$1" "$_state" "$_rpid" "$_cpid" "$_uptime" "${_exit:--}" "$_scmd"
  unset _state _rpid _cpid _uptime _scmd _exit || true
}

# Show the status of the commands from the file at SUPERVISE_PATH, or only of
# the ones which names are passed as arguments. Commands still running but not
# in the file anymore are also shown. RUN is the PID of the run process, PID the
# one of the command.
supervise_ps() {
  OPTIND=1
  while getopts "h" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "ps: Show the status of the commands from the configuration file" 0 supervise_ps;;
      *)  # Unknown option
        usage "" 1 supervise_ps >&2;;
    esac
  done
  shift $((OPTIND - 1))

  [ -n "$SUPERVISE_PATH" ] || error "ps: No file given, use -s"

  _wanted=
  [ "$#" -gt 0 ] && _wanted=" $* "
  _found=" "
  _statedir=${XDG_STATE_HOME}/supervise/$(_config_id)

  printf '%-15s %-18s %8s %8s %10s %4s  %s\n' NAME STATE RUN PID UPTIME EXIT COMMAND
  # Commands from the file, if it still exists.
  if [ -r "$SUPERVISE_PATH" ]; then
    _tab=$(printf '\t')
    while IFS=$_tab read -r _name _cmd; do
      [ -z "$_name" ] && continue
      [ -n "$_wanted" ] && case "$_wanted" in *" $_name "*) ;; *) continue;; esac
      _found="${_found}${_name} "
      _ps_line "$_name" "$_cmd"
    done <<EOF
$(_config_entries 2>/dev/null)
EOF
  fi
  # Commands started, but not in the file anymore.
  for _f in "$_statedir"/*.run; do
    [ -f "$_f" ] || continue
    _name=$(basename "$_f" .run)
    case "$_found" in *" $_name "*) continue;; esac
    [ -n "$_wanted" ] && case "$_wanted" in *" $_name "*) ;; *) continue;; esac
    _found="${_found}${_name} "
    _ps_line "$_name" ""
  done

  # Warn about requested names that are nowhere to be found.
  for _name in $_wanted; do
    case "$_found" in
      *" $_name "*) ;;
      *) warn "ps: No command named %s" "$_name";;
    esac
  done
  unset _wanted _found _statedir _tab _name _cmd _f || true
}

# Print the ls line for the command which name is $1 and command line is $2.
_ls_line() {
  if [ "$_SUPERVISE_LS_QUIET" = "1" ]; then
    printf %s\\n "$1"
  else
    printf '%s: %s\n' "$1" "$2"
  fi
}


# List the known commands, one per line, as their name, a colon and their
# command line: the ones from the file at SUPERVISE_PATH, followed by the ones
# still running but not in the file anymore, which names are prefixed with !.
# With -q, only the names are listed.
supervise_ls() {
  _SUPERVISE_LS_QUIET=0
  OPTIND=1
  while getopts "qh" opt; do
    case "$opt" in
      q) # Quiet: only list the names of the commands
        _SUPERVISE_LS_QUIET=1;;
      h) # Show help for this command
        usage "ls: List the known commands" 0 supervise_ls;;
      *)  # Unknown option
        usage "" 1 supervise_ls >&2;;
    esac
  done
  shift $((OPTIND - 1))

  [ -n "$SUPERVISE_PATH" ] || error "ls: No file given, use -s"

  _found=" "
  _statedir=${XDG_STATE_HOME}/supervise/$(_config_id)
  # Commands from the file, if it still exists.
  if [ -r "$SUPERVISE_PATH" ]; then
    _tab=$(printf '\t')
    while IFS=$_tab read -r _name _cmd; do
      [ -z "$_name" ] && continue
      _found="${_found}${_name} "
      _ls_line "$_name" "$_cmd"
    done <<EOF
$(_config_entries 2>/dev/null)
EOF
  fi
  # Commands still running, but not in the file anymore.
  for _f in "$_statedir"/*.run; do
    [ -f "$_f" ] || continue
    _name=$(basename "$_f" .run)
    case "$_found" in *" $_name "*) continue;; esac
    _alive_pid "$_f" > /dev/null || continue
    _ls_line "!$_name" "$(cat "${_statedir}/${_name}.cmd" 2>/dev/null || true)"
  done
  unset _SUPERVISE_LS_QUIET _found _statedir _tab _name _cmd _f || true
}

# Directory where run stores the PID of its command, inherited from up. Empty
# when run is called directly.
: "${_SUPERVISE_STATEDIR:=""}"

# Log file the output is appended to, inherited from spawn -o, so the loggers
# can rotate it. Empty when not logging to a file.
: "${_SUPERVISE_LOGFILE:=""}"

# How to run this script again, e.g. for run and logger: directly when it is
# executable, through the shell running it otherwise, e.g. sh supervise.sh.
_SUPERVISE_SHELL=
[ -x "$0" ] || _SUPERVISE_SHELL=$(readlink /proc/$$/exe)

# Whether printf can format time, see _log. Empty until tested at the first log
# line, inherited from the calling process otherwise. Exported, as we call
# ourselves for most commands.
: "${_SUPERVISE_PRINTF_TIME:=""}"
export _SUPERVISE_PRINTF_TIME

# Internal state: list of live spawned PIDs, and name to log under, the basename
# of this script without its extension, computed once without forking, unless
# set by logger -n.
_SUPERVISE_PIDS=
_SUPERVISE_LOGNAME=${0##*/}
_SUPERVISE_LOGNAME=${_SUPERVISE_LOGNAME%.*}

# Validate settings, whether set through options or from the environment.
_bytes "$SUPERVISE_LOGSIZE" > /dev/null
validate_number "$SUPERVISE_LOGKEEP" "number of log files to keep"
validate_number "$SUPERVISE_MAXDELAY" "maximum delay between restarts"

[ "$#" -gt 0 ] || error "No command given"
cmd=$(printf %s "$1" | tr '[:upper:]' '[:lower:]')
shift

case "$cmd" in
  *[!a-z0-9_]*) error "Invalid command: %s" "$cmd";;
esac
if [ "$(command -v "supervise_$cmd" 2>/dev/null || true)" = "supervise_$cmd" ]; then
  "supervise_$cmd" "$@"
else
  error "Unknown command: %s" "$cmd"
fi
