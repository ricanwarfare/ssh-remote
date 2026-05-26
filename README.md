# ssh-remote

Audit-logged SSH wrapper for remote host management. Runs commands on remote hosts with automatic dual-sided audit logging — local and remote — so you always have a record of what was executed, when, and by whom.

## Features

- **Dual audit logging** — commands logged locally and on the remote host
- **External host config** — add hosts via a simple conf file, no script edits needed
- **Injection-safe** — commands are base64-encoded to prevent shell injection in audit logs
- **Exit code propagation** — script returns the remote command's exit code
- **Failure logging** — failed commands are flagged in the local audit log
- **Date-based log rotation** — logs are automatically split by date

## Install

```bash
git clone https://github.com/ricanwarfare/ssh-remote.git
cd ssh-remote
chmod +x ssh-remote.sh
```

## Setup

### 1. Create your host config

Copy the example and add your hosts:

```bash
cp ssh-hosts.conf.example ssh-hosts.conf
```

Edit `ssh-hosts.conf` — one host per line, `alias ip user`:

```
web01     10.0.1.10  admin
db01      10.0.1.20  postgres
bastion   10.0.1.1   deploy
```

### 2. Ensure SSH keys are set up

This script relies on key-based SSH auth. No passwords.

### 3. Run commands

```bash
./ssh-remote.sh web01 "uptime"
./ssh-remote.sh db01 "psql -c 'SELECT 1'"
./ssh-remote.sh bastion "df -h"
```

## Audit Logs

### Local

`~/.ssh-audit-logs/<alias>-<ip>/YYYY-MM-DD.log`

```
[2026-05-26 08:30:01] admin@10.0.1.10: uptime
[2026-05-26 08:31:15] admin@10.0.1.10: FAILED (exit 1): cat /nonexistent
```

### Remote

`~/.ssh-audit/YYYY-MM-DD.log`

```
[2026-05-26 08:30:01] clawd: uptime
```

Override the local log directory with `SSH_AUDIT_LOG_DIR`:

```bash
SSH_AUDIT_LOG_DIR=/var/log/ssh-audit ssh-remote.sh web01 "uptime"
```

Override the config file path with `SSH_HOSTS_CONF`:

```bash
SSH_HOSTS_CONF=/etc/ssh-hosts.conf ssh-remote.sh web01 "uptime"
```

## Configuration Reference

### ssh-hosts.conf format

```
# Lines starting with # are comments
# Blank lines are ignored
# Format: alias  ip_address  username

web01  10.0.1.10  admin
db01   10.0.1.20  postgres
```

- **alias** — lowercase alphanumeric, hyphens, underscores. Used as the script argument.
- **ip_address** — IP or hostname of the remote host.
- **username** — SSH user for that host.

## Examples

### Check system info on multiple hosts

```bash
for host in web01 db01 bastion; do
  echo "=== $host ==="
  ./ssh-remote.sh "$host" "hostname && uptime && free -h"
done
```

### Docker management

```bash
./ssh-remote.sh web01 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

### Run a script on a remote host

```bash
./ssh-remote.sh web01 "bash -s" < local-script.sh
```

### Combine with other tools

```bash
# Pipe remote output locally
./ssh-remote.sh db01 "tail -100 /var/log/postgres.log" | grep ERROR
```

## How It Works

1. Loads hosts from `ssh-hosts.conf`
2. Validates the alias and command
3. Logs the command locally (before execution)
4. Opens **one SSH connection** that:
   - Creates the remote audit log directory
   - Decodes the base64 command and logs it remotely
   - Executes the command via `eval`
5. Returns the command's exit code
6. If the command failed, appends a failure line to the local log

The base64 encoding ensures commands containing quotes, special characters, or shell metacharacters are safely passed through the SSH session without injection vulnerabilities in the audit log.

## License

MIT