# ssh-remote

SSH wrapper for remote host management with private local and remote audit logs,
host groups, diagnostics, and bounded parallel commands.

## Requirements

- Bash 4.4+ locally and on remote hosts, with a POSIX-compatible remote login shell.
- OpenSSH `ssh` and `scp` locally.
- Unix utilities including `base64` with `-d` support, `date`, `mktemp`, and GNU `mv`
  with `-T` support locally and remotely. `-T` prevents destination directory races
  during fallback replacement. Install GNU coreutils where these are unavailable.
- SSH key authentication and trusted host keys configured beforehand. Connections
  use `BatchMode=yes`; authentication does not prompt.

## Setup

```bash
git clone https://github.com/ricanwarfare/ssh-remote.git
cd ssh-remote
cp ssh-hosts.conf.example ssh-hosts.conf
```

Edit `ssh-hosts.conf` with exactly three whitespace-separated fields per entry:

```text
# alias  host  username
web01    10.0.1.10       admin
db01     db.example.org postgres
ipv6     2001:db8::10    deploy
```

Blank lines and full-line comments are ignored. Aliases may contain lowercase
letters, digits, underscores, and hyphens. `all`, `hosts`, `groups`, `doctor`, and
`scp` are reserved. Duplicate aliases, missing fields, and extra fields are
rejected with a line number. Use unbracketed IPv6 addresses; the wrapper adds
brackets for SCP. The private config file is ignored by Git.

Override its location with `SSH_HOSTS_CONF`:

```bash
SSH_HOSTS_CONF=/etc/ssh-hosts.conf ./ssh-remote.sh hosts
```

## Commands

```bash
./ssh-remote.sh --help
./ssh-remote.sh hosts
./ssh-remote.sh web01 "uptime"
./ssh-remote.sh db01 "psql -c 'SELECT 1'"
./ssh-remote.sh all "hostname && uptime"
./ssh-remote.sh web01 "bash -s" < local-script.sh
./ssh-remote.sh --jobs 3 all "hostname && uptime"
```

Options precede the target or subcommand. Pass the remote shell command as one
quoted argument. Commands run with `bash -c`. A single-host invocation returns
the remote exit status (or SSH's error status).

`all` visits aliases in sorted order, continues after failures, prints each host's
exit status in a final summary, and returns 1 if any host failed. The same run ID
links all records from an invocation. Sequential commands forward stdin; stdin
is shared and is not replayed for every host.

`--jobs N` runs up to N hosts concurrently in batches (default 1; maximum 9999).
Each host's stdout and stderr are buffered in private temporary files, then
printed under its header in sorted order. Parallel commands receive `/dev/null`
as stdin. Output storage grows with command output. Interrupting a parallel run
cleans up its buffers and terminates active local SSH connections; disconnecting
SSH does not guarantee that a remote process has stopped. Completed hosts retain
their audit results; interrupted commands may have only a start record.

## Host groups

Create an optional `ssh-groups.conf`, or set `SSH_HOST_GROUPS_CONF` to its path:

```text
# group-name  alias [alias ...]
production web01 db01
webservers web01 ipv6
```

Every member must be a configured alias. Invalid members, empty groups, and
duplicate group names are rejected. Repeated members run once; groups do not nest.
The private groups file is ignored by Git; an example file is provided.

```bash
./ssh-remote.sh groups
./ssh-remote.sh @production "uptime"
./ssh-remote.sh --jobs 2 @webservers "hostname"
```

## Connection settings and diagnostics

All command, transfer, fallback, audit, and diagnostic SSH connections use:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SSH_CONNECT_TIMEOUT` | `10` | Connection timeout in seconds |
| `SSH_KEEPALIVE_INTERVAL` | `15` | SSH server-alive interval in seconds |
| `SSH_KEEPALIVE_COUNT` | `3` | Missed keepalives before disconnecting |
| `SSH_REMOTE_SSH_CONFIG` | unset | Optional OpenSSH config passed with `-F` |

Timeout and keepalive values must be positive integers. These settings detect
connection problems; they do not impose a wall-clock limit on a responsive remote
command. An OpenSSH config can supply ports, identity files, or jump hosts.

```bash
SSH_CONNECT_TIMEOUT=5 ./ssh-remote.sh web01 "uptime"
SSH_REMOTE_SSH_CONFIG=./my-ssh-config ./ssh-remote.sh web01 "uptime"
./ssh-remote.sh doctor
./ssh-remote.sh doctor web01
./ssh-remote.sh doctor @production
```

`doctor` validates the configuration and local dependencies, then checks each
selected host's authentication, Bash version, required utilities, base64 decoding,
GNU `mv` support, and audit-directory access. It creates or repairs private audit
directories and writes/removes temporary probe files. It returns 1 if a check
fails. With no target, it checks all hosts sequentially.

`--help` works without a host configuration.

## File transfers

```bash
./ssh-remote.sh scp ./report.txt web01:/tmp/report.txt
./ssh-remote.sh scp web01:/tmp/report.txt ./download.txt
```

Exactly one endpoint must be a configured `alias:path`; the other must be local.
Remote-to-remote transfers are unsupported. Prefix local filenames containing a
colon with `./` to distinguish them from remote endpoints.

Transfers try SCP first. If SCP reports `subsystem request failed`, the wrapper
retries using streamed base64 over SSH. Generic connection and permission failures
are reported without retrying. IPv6 SCP destinations are bracketed automatically.

The fallback supports individual regular files and existing destination
directories. It stages output beside the destination before replacing it; failed
downloads leave an existing local destination intact. Uploads verify the decoded
byte count before replacement. If the final filename is already a directory,
the transfer fails instead of placing a temporary filename inside it. Temporary
fallback files are cleaned up on normal exits and catchable interruption signals;
SIGKILL and machine failures cannot run cleanup traps.

Fallback files use `mktemp` permissions (normally 0600); ownership, permissions,
timestamps, and symlink behavior are not preserved as with SCP. Remote fallback
paths are literal: use absolute paths or paths relative to the login directory,
without `~` expansion or wildcards. Recursive transfers are unsupported.

## Audit logs

Local logs: `~/.ssh-audit-logs/<alias>-<host>/YYYY-MM-DD.log`

Remote logs: `~/.ssh-audit/YYYY-MM-DD.log`

```text
[2026-10-07T18:30:01Z] operator: admin@10.0.1.10: uptime [run=20261007T183001Z-1234-5678 event=start exit=null duration=0s]
[2026-10-07T18:30:02Z] operator: admin@10.0.1.10: uptime [run=20261007T183001Z-1234-5678 event=finish exit=0 duration=1s]
```

Set `SSH_AUDIT_LOG_DIR` to override the local root and `SSH_AUDIT_USER` to override
the operator label (default: `whoami`). Audit directories are created with 0700
permissions and files with 0600; directories and the current file also have their
permissions repaired on use. Historical files are not automatically modified.
Symlink audit files are rejected. The command's original umask is preserved.

Timestamps are UTC; daily filenames use each machine's local date. Control
characters in text-log commands, paths, and operator labels are rendered using
Bash escaping so each entry occupies one line. Durations use whole seconds from
each machine's clock.

### JSON Lines

```bash
./ssh-remote.sh --audit-format json web01 "uptime"
SSH_AUDIT_FORMAT=json ./ssh-remote.sh --jobs 2 all "hostname"
```

JSON mode writes `YYYY-MM-DD.jsonl` instead of `.log`, on both machines. It changes
the audit format, not command stdout. Records contain `timestamp`, `run_id`,
`operator`, `host`, `event`, `action`, `started_at`, `finished_at`,
`duration_seconds`, and `exit_status`. Start records have null finish, duration,
and exit fields. Epoch times and exit statuses are JSON numbers. All strings are
escaped without requiring Python or jq on remote hosts.

Commands are logged locally before connecting and remotely before execution.
Failure to write either initial record prevents execution. Completion records are
written locally and remotely, including successful results and failed exit codes.
If completion logging fails, a warning preserves the command exit status. The
command is base64-encoded for transport, and wrapper arguments are quoted for the
remote shell. SSH provides transport security; base64 is only an encoding.

Transfers log an attempt and completion locally, then record completion remotely
through a separate audit connection. A failed remote transfer audit emits a
warning while preserving the transfer exit status. Input supplied through stdin
is not recorded.

These are operational records, not tamper-proof audit trails: the account running
commands can edit them, and operator labels can be overridden. Commands may
contain secrets. Old files are not automatically deleted.

## Development

```bash
python3 -m unittest discover -s tests -v
bash -n ssh-remote.sh
shellcheck ssh-remote.sh
```

Offline tests simulate SSH command parsing and use temporary directories; they
never connect to configured hosts. CI runs them with syntax checks and ShellCheck.

A second CI job runs opt-in tests against a disposable OpenSSH server bound only
to loopback, using temporary keys, pinned host keys, and a temporary remote home.
It covers actual command stdin/exit status, diagnostics, SFTP transfers, and
base64 fallback when SFTP is unavailable. To run it locally, install
`openssh-server` (including the SFTP server) and ensure `/run/sshd` exists on Linux:

```bash
SSH_REMOTE_REAL_TESTS=1 python3 -m unittest discover -s tests -p test_real_ssh.py -v
```

The opt-in tests launch their own server as the current user and never use the
project's private host configuration.

## License

MIT
