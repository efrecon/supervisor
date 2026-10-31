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

# Path to the configuration file with the commands to supervise.
: "${SUPERVISE_PATH:="supervise.cfg"}"

# Size above which log files of the commands are rotated, in bytes, or with a k,
# M or G suffix. 0 disables rotation. Defaults to 10M.
: "${SUPERVISE_LOGSIZE:="10M"}"

# Number of rotated log files to keep. Defaults to 5.
: "${SUPERVISE_LOGKEEP:="5"}"

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
    # Commands and their summaries, from the -h option of each command.
    printf \\nCommands:\\n
    sed -n -E 's/^[[:space:]]*usage "([a-z]+): ([^"]*)".*/    \1\t\2/p' "$0" |
      expand -t 12
  fi
  printf \\nEnvironment:\\n
  set | grep '^SUPERVISE_' | sed 's/^SUPERVISE_/    SUPERVISE_/g'
  exit "${2:-0}"
}

# Print the options documented in the getopts loop read from stdin.
_usage_options() {
  grep "[[:space:]][a-zA-Z-])[[:space:]][[:space:]]*#" |
    sed -E 's/^[[:space:]]*([a-zA-Z-])\)[[:space:]]*#[[:space:]]*/    -\1  /'
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

# PML: Poor Man's Logging on stderr, or appended to the log file when there is
# one, re-opened at each line so logging continues in a new file once rotated.
# Each line is a single write, so concurrent loggers do not mix lines.
_log() {
  _lvl=${1:-LOG}
  shift
  _fmt="$1"
  shift
  if [ -n "${_SUPERVISE_LOGFILE:-}" ]; then
    # shellcheck disable=SC2059 # ok, we want to use printf format
    printf "[%s] [%s] [%s] ${_fmt}\n" \
      "${_SUPERVISE_LOGNAME:-$(basename "$0")}" "$_lvl" "$(date +'%Y%m%d-%H%M%S')" "$@" \
      >> "$_SUPERVISE_LOGFILE"
  else
    # shellcheck disable=SC2059 # ok, we want to use printf format
    printf "[%s] [%s] [%s] ${_fmt}\n" \
      "${_SUPERVISE_LOGNAME:-$(basename "$0")}" "$_lvl" "$(date +'%Y%m%d-%H%M%S')" "$@" \
      >&2
  fi
}
trace() { [ "$SUPERVISE_VERBOSE" -ge "3" ] && _log TRC "$@" || true ; }
debug() { [ "$SUPERVISE_VERBOSE" -ge "2" ] && _log DBG "$@" || true ; }
info() { [ "$SUPERVISE_VERBOSE" -ge "1" ] && _log NFO "$@" || true ; }
warn() { _log WRN "$@"; }
error() { _log ERR "$@" && exit 1; }

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


kill_tree() {
  [ -z "${1:-}" ] && error "kill_tree: must pass pid as first arg"
  # Processes may exit while the tree is being killed, ignore those.
  for _pid in $(ps_children "$1"); do
    kill -"${2:-TERM}" "$_pid" 2>/dev/null || true
    printf %d\\n "$_pid"
  done
  kill -"${2:-TERM}" "$1" 2>/dev/null || true
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
# the process, even if it had already exited.
_spawn_wait() {
  [ -z "${1:-}" ] && return 0

  # Always wait at least once: a process that has already exited is gone from
  # kill -0, but wait still returns its exit code. Re-enter wait if interrupted
  # by a signal before the process actually exits.
  while :; do
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
  _sigspec=TERM
  _tree=0
  _reason=unknown
  OPTIND=1
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


# Spawn a process in the background, and return its PID. Unless -o is given,
# its stdout and stderr are logged.
spawn() {
  _name=
  _out=
  OPTIND=1
  while getopts "n:o:-" opt; do
    case "$opt" in
      n) # Specify the name for logging purposes
        _name=$OPTARG;;
      o) # Append stdout and stderr to this file, instead of logging them
        _out=$OPTARG;;
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
  if [ -n "$_out" ]; then
    _SUPERVISE_LOGFILE=$_out "$_bin" "$@" >> "$_out" 2>&1 &
  else
    # Route stdout and stderr to separate loggers through FIFOs, so $! remains
    # the PID of the executable. Each logger removes its FIFO once opened, the
    # last one to do so also removes the directory.
    _fifo_dir=$(mktemp -d)
    mkfifo "$_fifo_dir/out" "$_fifo_dir/err"
    # shellcheck disable=SC2094 # FIFOs are only removed, not written to.
    { rm -f "$_fifo_dir/out"; rmdir "$_fifo_dir" 2>/dev/null || true; "$0" logger -n "$_name" OUT; } < "$_fifo_dir/out" > /dev/null &
    # shellcheck disable=SC2094 # FIFOs are only removed, not written to.
    { rm -f "$_fifo_dir/err"; rmdir "$_fifo_dir" 2>/dev/null || true; "$0" logger -n "$_name" ERR; } < "$_fifo_dir/err" > /dev/null &
    "$_bin" "$@" > "$_fifo_dir/out" 2> "$_fifo_dir/err" &
  fi
  _spawned=$!

  # Prune dead PIDs before appending, so the list only holds live processes. Add
  # the new PID to the list of live processes.
  _spawn_update "$_spawned"
  debug "Spawned %s with PID %d" "$_name" "$_spawned"

  # Install process-wide signal handlers if not already done.
  if [ "$_SUPERVISE_TRAPPED" = "0" ]; then
    trap 'spawn_kill -t -s HUP -r "HUP trap";  trap - HUP;  kill -HUP  $$' HUP
    trap 'spawn_kill -t -s INT -r "INT trap";  trap - INT;  kill -INT  $$' INT
    trap 'spawn_kill -t -s TERM -r "TERM trap"; spawn_wait || true; trap - TERM; kill -TERM $$' TERM
    # shellcheck disable=SC2154 # _spawn_exit set inside trap
    trap '_spawn_exit=$?; spawn_kill -t -s TERM -r "EXIT trap" || true; spawn_wait || true; trap - EXIT; exit "$_spawn_exit"' EXIT
    _SUPERVISE_TRAPPED=1
  fi

  # Return the PID of the spawned process, for convenience.
  printf %s\\n "$_spawned"
  unset _bin _name _out _spawned _fifo_dir || true
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
  _log_rotate "$_SUPERVISE_LOGFILE"
  _logged=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _log "$_stream" '%s' "$_line"
    _logged=$((_logged + ${#_line} + 50))
    if [ "$_logged" -ge 4096 ]; then
      _log_rotate "$_SUPERVISE_LOGFILE"
      _logged=0
    fi
  done
  unset _stream _line _logged || true
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
# directory prevents concurrent rotations, e.g. by the OUT and ERR loggers.
_log_rotate() {
  [ -n "${1:-}" ] || return 0
  _max=$(_bytes "$SUPERVISE_LOGSIZE")
  [ "$_max" -gt 0 ] || return 0
  _size=$(wc -c < "$1" 2>/dev/null) || return 0
  [ "$((_size))" -ge "$_max" ] || return 0
  mkdir "${1}.lock" 2>/dev/null || return 0

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


  [ "$#" -gt 0 ] || error "Nothing to run"
  SUPERVISE_BINPATH=$(command -v "$1") || error "Executable $1 not found"
  shift

  [ -x "$SUPERVISE_BINPATH" ] || error "Executable $SUPERVISE_BINPATH not found or not executable"
  [ -n "$SUPERVISE_NAME" ] || SUPERVISE_NAME=$(basename "$SUPERVISE_BINPATH")

  _sup_running=1
  _delay=0

  while [ "$_sup_running" = "1" ]; do
    info "Starting %s at %s in the background" "$SUPERVISE_NAME" "$SUPERVISE_BINPATH"
    spawn -n "$SUPERVISE_NAME" "$SUPERVISE_BINPATH" "$@" > /dev/null
    if [ -n "$_SUPERVISE_STATEDIR" ]; then
      spawn_latest > "${_SUPERVISE_STATEDIR}/${SUPERVISE_NAME}.pid"
    fi
    _rc=0
    spawn_wait || _rc=$?
    if [ -n "$_SUPERVISE_STATEDIR" ]; then
      printf %d\\n "$_rc" > "${_SUPERVISE_STATEDIR}/${SUPERVISE_NAME}.exit"
    fi
    [ "$_sup_running" = "0" ] && break
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
# They are not children of this process, so poll for them to be gone.
_wait_gone() {
  _wtimeout=10
  for _wpid in "$@"; do
    while kill -0 "$_wpid" 2>/dev/null && [ "$_wtimeout" -gt 0 ]; do
      sleep 1
      _wtimeout=$((_wtimeout - 1))
    done
    kill -0 "$_wpid" 2>/dev/null && warn "PID %d still running" "$_wpid"
  done
  unset _wpid _wtimeout || true
}

# Print the PID stored in the file passed as $1, if that process is alive.
_alive_pid() {
  [ -f "$1" ] || return 1
  _pid=$(cat "$1")
  kill -0 "$_pid" 2>/dev/null || return 1
  printf %s\\n "$_pid"
}

# Print the commands from the file at SUPERVISE_PATH, one per line, as their
# name and command line separated by a tab. Empty lines and lines starting with
# # are ignored. Other lines contain a command, optionally preceded by a name and
# a colon. Without a name, the basename of the program is used, as run does.
# shellcheck disable=SC2094,SC2120 # File only read, $1 is set from commands.
_config_entries() (
  # This uses a () to force an extra process and have truly local vars.
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
    if [ -z "$_name" ]; then
      eval "set -- $_cmd"
      _name=$(basename "$1")
    fi
    printf '%s\t%s\n' "$_name" "$_cmd"
  done < "$SUPERVISE_PATH"
)

# Supervise all commands from the file at SUPERVISE_PATH (see _config_entries),
# each in the background through the run command, logging to files. When names
# are passed as arguments, only the commands with these names are supervised.
# Commands always run detached. With -d, up returns at once. Otherwise, up
# follows their logs until they have all ended, and stops the ones it started
# when interrupted.
supervise_up() {
  _detach=0
  OPTIND=1
  while getopts "dh" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "up: Start the commands from the configuration file" 0 supervise_up;;
      d) # Detach: return at once, leaving commands running in the background
        _detach=1;;
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
  if [ "$_detach" = "0" ]; then
    for _cname in $_names; do
      _f=${_logdir}/${_cname}.log
      : >> "$_f"
      _lines=$(wc -l < "$_f")
      tail -F -n +$((_lines + 1)) "$_f" 2>/dev/null &
      _tails="$_tails $!"
    done
  fi

  # Commands run detached: spawn installs no traps, and they ignore HUP so they
  # survive this process and the terminal. Let them inherit the global settings
  # and the state directory.
  _SUPERVISE_TRAPPED=1
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
      _wait_gone "$_pid"
    fi

    # Forget the exit code of a previous run before starting a new one.
    rm -f "${_SUPERVISE_STATEDIR}/${_cname}.exit"
    info "up: Supervising %s" "$_cmd"
    spawn -o "${_logdir}/${_cname}.log" -n "$_cname" "$0" run -n "$_cname" -- "$@" < /dev/null > /dev/null
    # Remember the PID of the run process, so down can stop it.
    spawn_latest > "${_SUPERVISE_STATEDIR}/${_cname}.run"
    printf %s\\n "$_cmd" > "${_SUPERVISE_STATEDIR}/${_cname}.cmd"
    _started="$_started $_cname"
  done <<EOS
$_entries
EOS
  unset _tab _entries _cmd _pid _f _lines || true

  if [ "$_detach" = "1" ]; then
    info "up: Detached, logs in %s" "$_logdir"
    unset _detach _logdir _names _started _tails _cname || true
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
  unset _detach _logdir _names _started _tails _cname _exit || true
  return "$_rc"
}

# Return success if any of the commands which names are in _names is alive.
_up_alive() {
  for _aname in $_names; do
    _alive_pid "${_SUPERVISE_STATEDIR}/${_aname}.run" >/dev/null && return 0
  done
  return 1
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
  [ -n "$_alive" ] && supervise_down $_alive
  # shellcheck disable=SC2086 # We want to split the PIDs
  kill $_tails 2>/dev/null || true
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

  # Terminate the run processes, then wait for them to exit.
  _stopping=
  for _name in "$@"; do
    _f=${_statedir}/${_name}.run
    if [ ! -f "$_f" ]; then
      warn "down: No command named %s started from %s" "$_name" "$SUPERVISE_PATH"
      continue
    fi
    if _pid=$(_alive_pid "$_f"); then
      info "down: Stopping %s, PID %d" "$_name" "$_pid"
      kill -TERM "$_pid"
      _stopping="$_stopping $_pid"
    else
      debug "down: %s was not running" "$_name"
    fi
    rm -f "$_f" "${_statedir}/${_name}.pid" "${_statedir}/${_name}.cmd" "${_statedir}/${_name}.exit"
  done

  # shellcheck disable=SC2086 # We want to split the PIDs
  _wait_gone $_stopping
  unset _statedir _f _name _pid _stopping || true
}

# Print the content of the log files passed as arguments, each preceded by its
# rotated copies, oldest first.
_log_cat() {
  for _lf in "$@"; do
    _i=$SUPERVISE_LOGKEEP
    while [ "$_i" -gt 0 ]; do
      [ -f "${_lf}.${_i}" ] && cat "${_lf}.${_i}"
      _i=$((_i - 1))
    done
    cat "$_lf"
  done
  unset _lf _i || true
}

# Show the logs of the commands started by up -d from the file at
# SUPERVISE_PATH, or only of the ones which names are passed as arguments. Logs
# of several commands are merged in chronological order.
supervise_log() {
  _lines=
  _follow=0
  OPTIND=1
  while getopts "n:fh" opt; do
    case "$opt" in
      h) # Show help for this command
        usage "log: Show the logs of the commands started from the configuration file" 0 supervise_log;;
      n) # Number of lines to show at the end of the logs, default: all
        _lines=$OPTARG;;
      f) # Follow the logs, waiting for more lines to appear
        _follow=1;;
      *)  # Unknown option
        usage "" 1 supervise_log >&2;;
    esac
  done
  shift $((OPTIND - 1))
  [ -z "$_lines" ] || validate_number "$_lines" "number of lines"

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
  if [ -n "$_lines" ]; then
    _log_cat "$@" | sort -s -k3,3 | tail -n "$_lines"
  else
    _log_cat "$@" | sort -s -k3,3
  fi
  if [ "$_follow" = "1" ]; then
    exec tail -q -n 0 -F "$@" 2>/dev/null
  fi
  unset _lines _follow _logdir _f _name || true
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

# List the known commands, one per line, as their name, a colon and their
# command line: the ones from the file at SUPERVISE_PATH, followed by the ones
# still running but not in the file anymore, which names are prefixed with !.
# With -q, only the names are listed.
supervise_ls() {
  _quiet=0
  OPTIND=1
  while getopts "qh" opt; do
    case "$opt" in
      q) # Quiet: only list the names of the commands
        _quiet=1;;
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
  unset _quiet _found _statedir _tab _name _cmd _f || true
}

# Print the ls line for the command which name is $1 and command line is $2.
_ls_line() {
  if [ "$_quiet" = "1" ]; then
    printf %s\\n "$1"
  else
    printf '%s: %s\n' "$1" "$2"
  fi
}


# Directory where run stores the PID of its command, inherited from up. Empty
# when run is called directly.
: "${_SUPERVISE_STATEDIR:=""}"

# Log file the output is appended to, inherited from spawn -o, so the loggers
# can rotate it. Empty when not logging to a file.
: "${_SUPERVISE_LOGFILE:=""}"

# Internal state: list of live spawned PIDs, whether signal traps are set, and
# name to log under (defaults to the basename of this script when empty).
_SUPERVISE_PIDS=
_SUPERVISE_TRAPPED=0
_SUPERVISE_LOGNAME=

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
