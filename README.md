# ssh-remote

SSH wrapper for remote host management with local and remote audit logging.

## Requirements

- Bash 4.4+ locally and on the remote hosts, with a POSIX-compatible remote login shell.
- OpenSSH `ssh` and `scp` locally.
- Unix utilities including `base64` with `-d` support, `date`, and `mktemp`.
- SSH key authentication and trusted host keys configured beforehand. Connections use `BatchMode=yes`, so authentication does not prompt.

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

Blank lines and full-line comments are ignored. Aliases may contain lowercase letters, digits, underscores, and hyphens. `all`, `hosts`, and `scp` are reserved. Duplicate aliases, missing fields, and extra fields are rejected with a line number. Use unbracketed IPv6 addresses; the wrapper adds brackets for SCP. The private config file is ignored by Git.

Override the config location with `SSH_HOSTS_CONF`:

```bash
SSH_HOSTS_CONF=/etc/ssh-hosts.conf ./ssh-remote.sh hosts
```

## Commands

```bash
./ssh-remote.sh hosts
./ssh-remote.sh web01 "uptime"
./ssh-remote.sh db01 "psql -c 'SELECT 1'"
./ssh-remote.sh all "hostname && uptime"
./ssh-remote.sh web01 "bash -s" < local-script.sh
```

Pass the remote shell command as one quoted argument. Commands run with `bash -c`, and stdin is forwarded to the command. A single-host invocation returns the remote exit status (or SSH's error status). `all` runs sequentially, continues after failures, and returns 1 if any host failed. Stdin is shared across these sequential invocations; it is not replayed for every host.

## File transfers

```bash
./ssh-remote.sh scp ./report.txt web01:/tmp/report.txt
./ssh-remote.sh scp web01:/tmp/report.txt ./download.txt
```

Exactly one endpoint must be a configured `alias:path`; the other must be local. Remote-to-remote transfers are unsupported. Prefix local filenames containing a colon with `./` to distinguish them from remote endpoints.

Transfers try SCP first. If SCP reports `subsystem request failed`, the wrapper retries using streamed base64 over SSH. Generic connection and permission failures are reported without retrying. IPv6 SCP destinations are bracketed automatically.

The fallback supports individual regular files and existing destination directories. It stages output beside the destination before replacing it; failed downloads leave an existing local destination intact. Uploads verify the decoded byte count before replacement. Fallback files use `mktemp` permissions (normally 0600); ownership, permissions, timestamps, and symlink behavior are not preserved as with SCP. Remote fallback paths are literal: use absolute paths or paths relative to the login directory, without `~` expansion or wildcards. Recursive transfers are unsupported.

## Audit logs

Local logs: `~/.ssh-audit-logs/<alias>-<host>/YYYY-MM-DD.log`

Remote logs: `~/.ssh-audit/YYYY-MM-DD.log`

```text
[2026-05-26 08:30:01] operator: admin@10.0.1.10: uptime
[2026-05-26 08:31:15] operator: FAILED (exit 1): admin@10.0.1.10: cat /nonexistent
```

Set `SSH_AUDIT_LOG_DIR` to override the local log root and `SSH_AUDIT_USER` to override the operator label (default: `whoami`). Each machine uses its own date and timezone. Control characters in commands, paths, and operator labels are rendered using Bash escaping so each entry occupies one line.

Commands are logged locally before connecting, then remotely before execution within one SSH connection. Failure to write either initial log prevents command execution. The command is base64-encoded for transport, and all wrapper arguments are quoted for the remote shell. Base64 is an encoding, not encryption; SSH provides the transport security.

Transfers log an attempt locally and then record the result locally and through a separate remote audit connection. A failed remote transfer audit emits a warning while preserving the transfer exit status. Command failures are recorded locally; the remote command entry records the attempt, not its result. Input supplied through stdin is not recorded.

These files are operational records, not tamper-proof audit trails: the account running commands can edit them, and operator labels can be overridden. Commands may contain secrets, so restrict log access. Daily files are created automatically; old files are not automatically deleted.

## Development

Run the offline integration tests and syntax check:

```bash
python3 -m unittest discover -s tests -v
bash -n ssh-remote.sh
```

The tests simulate SSH's remote command parsing and execute commands in temporary directories. They never connect to configured hosts. Real SSH/SFTP server compatibility still requires deployment testing.

## License

MIT
