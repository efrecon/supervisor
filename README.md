# supervise.sh

`supervise.sh` is a small process supervisor written in POSIX shell.
It runs commands in the background, restarts them when they fail, and keeps their logs.
It can supervise a single command, or a set of commands described in a configuration file,
in the spirit of a minimal `docker compose` for plain processes.

## Features

- Restart failed commands, with an exponential backoff between restarts.
- Supervise several commands from a configuration file, all of them or only some, by name.
- Run in the foreground while following the logs, or detach and return at once.
- Restart only the commands which command line changed in the configuration file.
- Inspect the commands with `ps` and `ls`, and stop them with `down`, from any terminal.
- Log each line of the commands with their name, stream and a timestamp.
- Rotate log files by size, keeping a number of older copies.
- Stop whole process trees.

## Requirements

The script runs with `/bin/sh` and standard utilities.
It relies on a few non-POSIX features, available on most Linux systems, including Alpine:

- `/proc`, to find the descendants of processes.
- `md5sum` and `readlink -f`, to name the state directories.
- `tail -F`, `sort -s` and `mktemp`.

## Quick Start

Write a configuration file called `supervise.cfg`, with one command per line:

```text
web: python3 -m http.server 8080
worker: sh -c 'while true; do date; sleep 5; done'
```

Then start all commands, following their logs until you press `Ctrl-C`:

```sh
./supervise.sh up
```

Or start them in the background, and manage them later:

```sh
./supervise.sh up -d      # Start all commands in the background
./supervise.sh ps         # Show their status
./supervise.sh log -f web # Follow the logs of web
./supervise.sh down       # Stop them all
```

## Configuration File

The configuration file is `supervise.cfg` in the current directory, unless specified otherwise with `-s`.
Empty lines, and lines starting with `#`, are ignored.
Every other line is a command to supervise, optionally preceded by a name and a colon.
Spaces are allowed around the colon.

```text
# A named command.
clock: sh -c 'while true; do date; sleep 5; done'

# Without a name, the command is named after its program, here: sh.
sh -c 'echo "done once"'
```

Names can only contain letters, digits, `.`, `_` and `-`,
so that colons in commands, as in `sh -c 'echo a:b'`, are not mistaken for names.
Without a name, a command is named after the basename of its program.
Names are made unique: a name already taken gets the first free index, e.g. `sh`, `sh-2`, `sh-3`.
Names given in the file are kept when possible, and names derived from programs never take them.
The renamed commands appear under their new names in `ps`, `ls`, `log` and `down`.

Commands are split into words like the shell does, so quotes work as expected.
Commands are not run through a shell though: use `sh -c '...'` for pipes, redirections or `&&`.
The lines are evaluated by the shell, so `$VAR` and `$(...)` are expanded when the file is read.
Use single quotes to pass them to the command instead.
The configuration file is code: only use files that you trust.

### Examples

The following configuration only depends on `sh` and standard utilities, so it runs anywhere.
Save it as `supervise.cfg` and run `./supervise.sh up` to see the commands at work.

```text
# Long-running process logging the time on stdout every 5 seconds.
clock: sh -c 'while true; do date; sleep 5; done'

# Writes to both stdout and stderr, shown as [OUT] and [ERR] lines.
streams: sh -c 'while true; do echo "to stdout"; echo "to stderr" >&2; sleep 7; done'

# Fails after 3 seconds, and is restarted with an increasing delay.
flaky: sh -c 'echo "starting as $$"; sleep 3; echo "failing" >&2; exit 1'

# One-shot command without a name: it succeeds, so it is not restarted.
sh -c 'echo "done once"'
```

## Commands

The general syntax is:

```sh
./supervise.sh [options] <command> [options] [args...]
```

Every command accepts `-h`, to show its options.

### run

`run` runs a single command and restarts it each time it exits with an error.
It stops when the command succeeds, i.e. exits with `0`, or when `run` itself is terminated.

```sh
./supervise.sh run -n api -- python3 -m http.server 8080
```

- `-n` sets the name used in the logs, the basename of the program by default.
- `--` ends the options, which is only needed when the command starts with a dash.

The delay between restarts starts at 0, then 1 second, then doubles at each restart, up to `-r` seconds.
The output of the command is logged on stderr, prefixed with its name, stream (`OUT` or `ERR`) and a timestamp:

```text
[api] [OUT] [20261031-014715] Serving HTTP on 0.0.0.0 port 8080 (http://0.0.0.0:8080/) ...
[api] [ERR] [20261031-014716] 127.0.0.1 - - [31/Oct/2026 01:47:16] "GET / HTTP/1.1" 200 -
```

When `run` receives `HUP`, `INT` or `TERM`, it stops the whole process tree of its command, then exits.

### up

`up` starts the commands of the configuration file, each through its own `run` process, in the background.
Pass names to only start some of the commands, e.g. `./supervise.sh up web worker`.

- Without `-d`, `up` follows the logs of the selected commands until they have all ended.
  On `Ctrl-C`, `TERM` or `HUP`, it stops the commands it started, but not the ones that were already running.
  It exits with the first non-zero exit code of the commands it started.
- With `-d`, `up` returns at once, leaving the commands running in the background.
  They survive the terminal being closed.

`up` never starts a command twice.
Commands that are already running are left alone,
unless their command line has changed in the configuration file: they are then restarted.
This makes `up -d` safe to run again after editing the configuration file.

### down

`down` stops the commands started from the configuration file, or only the ones which names are given.
It terminates their `run` processes, which stop their whole process trees, and waits up to 10 seconds for them to exit.
`down` only needs the path to the configuration file, so it works even if the file has changed or is gone.

### ps

`ps` shows the status of the commands, or only of the ones which names are given:

```text
NAME            STATE                   RUN      PID     UPTIME EXIT  COMMAND
clock           running               99344    99381      00:04    -  sh -c 'while true; do date; sleep 5; done'
flaky           running               99365    99681      00:01    1  sh -c 'echo "starting"; sleep 3; exit 1'
sh              exited                    -        -          -    0  sh -c 'echo "done once"'
bad             restarting            99416        -          -    7  sh -c "exit 7"
old             running,removed       99512    99530      12:31    -  sh -c 'sleep infinity'
```

- `RUN` is the PID of the `run` process, `PID` the one of the command itself.
- `UPTIME` is the time since the command was last (re)started.
- `EXIT` is the exit code of the last run of the command.

The `STATE` column takes the following values:

- `running`: the command is running.
- `restarting`: the command failed, and `run` is waiting before restarting it.
- `exited`: the command succeeded, and is not restarted.
- `stopped`: the command was never started, or was stopped with `down`.

`,changed` is added when the command line in the file differs from the running one: the next `up` restarts it.
`,removed` is added when the command is still running, but not in the file anymore.

### ls

`ls` lists the known commands, as their name, a colon and their command line.
Commands still running, but not in the file anymore, have their name prefixed with `!`.
With `-q`, only the names are listed, which is handy in scripts:

```sh
for cmd in $(./supervise.sh ls -q); do echo "$cmd"; done
```

### log

`log` shows the logs of the commands, or only of the ones which names are given.
The logs of several commands are merged in chronological order, rotated files included.

- `-n` shows only the last lines, e.g. `./supervise.sh log -n 20 web`.
- `-f` follows the logs, waiting for more lines to appear.

## Options and Environment

Global options go before the command, e.g. `./supervise.sh -v -s procs.cfg up -d`.
Each option has an environment variable counterpart, which the option overrides.

| Option | Variable | Default | Description |
| --- | --- | --- | --- |
| `-s` | `SUPERVISE_PATH` | `supervise.cfg` | Path to the configuration file. |
| `-r` | `SUPERVISE_MAXDELAY` | `120` | Maximum delay between restarts, in seconds. |
| `-m` | `SUPERVISE_LOGSIZE` | `10M` | Size above which logs are rotated, `k`, `M` or `G` suffix, `0` to disable. |
| `-k` | `SUPERVISE_LOGKEEP` | `5` | Number of rotated log files to keep. |
| `-v` | `SUPERVISE_VERBOSE` | `0` | Verbosity, repeat `-v` to increase. |
| | `SUPERVISE_NAME` | | Name of the command for `run`, same as its `-n` option. |
| | `SUPERVISE_STATE_HOME` | `$XDG_STATE_HOME/supervise` | Directory for the state of the commands. |
| | `SUPERVISE_RUNTIME_DIR` | `$XDG_RUNTIME_DIR/supervise` | Directory for the logs of the commands. |

Invalid values are rejected before any command runs.
`up` passes these settings to the commands it starts.

## Files and Directories

Each configuration file gets its own directories,
named after the basename of the file and a short hash of its resolved path, e.g. `supervise.cfg-4c57b75eed5b`.
Only the path is used, so the directories stay the same when the file is edited.

These directories are created under directories named after the script, without its extension:
a copy called `procs.sh` uses `procs/` instead of `supervise/`.

Under `$SUPERVISE_STATE_HOME`, i.e. `~/.local/state/supervise/` by default:

- `config.path`: the resolved path of the configuration file.
- `<name>.run`: the PID of the `run` process of the command, and its start time.
- `<name>.pid`: the PID of the command itself, and its start time.
- `<name>.cmd`: the command line the command was started with.
- `<name>.exit`: the exit code of the last run of the command.

A process is only considered alive when both its PID and start time match,
so PIDs reused by other processes, e.g. after a reboot, are never mistaken for the commands.

Under `$SUPERVISE_RUNTIME_DIR`, i.e. `$XDG_RUNTIME_DIR/supervise/` by default, created with `0700` permissions:

- `<name>.log`: the logs of the command, and of its `run` process.
- `<name>.log.1` to `<name>.log.N`: rotated logs, `.1` being the newest.

## Tests

The tests are in the [tests](tests) directory, and only need the same tools as the script.
Run them all, or only the tests of some files:

```sh
tests/run.sh
tests/run.sh tests/test_units.sh
```

- `test_units.sh` tests the internal functions of the script, sourced without running any command.
- `test_cli.sh` tests the help, the options, and the `run` and `logger` commands.
- `test_up.sh` tests `up`, `down`, `ps`, `ls` and `log`, from configuration files.

Each test runs in its own process and temporary directory, with private XDG directories,
so it does not interfere with running commands.
The output follows the TAP format, and the exit code is `1` when a test fails.
Set `TEST_SHELL` to run the tests, and the script, with another shell, e.g. `TEST_SHELL=dash tests/run.sh`.
The tests run on every pull request with bash, dash, mksh, yash, and the ash of busybox.
To test with the ash shell and utilities of busybox, run the tests in Alpine:

```sh
docker run --rm -v "$PWD:/src:ro" -w /src alpine:3.22 tests/run.sh
```

Set `TEST_ONLY` to a pattern to only run the matching tests, e.g. `TEST_ONLY=rotate tests/run.sh`.

## Limitations

- Moving or renaming the configuration file loses track of its running commands.
  Stop them with `down` first.
- Removing a command from the configuration file does not stop it.
  `ps` shows it as `removed`, use `down <name>` to stop it.
- Commands without a name are evaluated twice per `up`, so `$(...)` in them run twice.
- When followed by `up`, lines of different commands within the same second may appear out of order.
  `log` sorts them by timestamp.
- Log files can grow a few kilobytes above the rotation size before they are rotated.
- Commands started by `up` ignore `INT`, as background processes of a non-interactive shell do.
  Stop them with `down`, or with `TERM`.
