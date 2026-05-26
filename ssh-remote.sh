#!/usr/bin/env bash
# ssh-remote.sh — Configurable SSH wrapper with audit logging
# Usage: ssh-remote.sh <host-alias> "<command>"
#   or:  ssh-remote.sh web01 "uptime"
#
# Hosts are loaded from ssh-hosts.conf (same directory as this script).
# Add new hosts there — no need to edit this script.

set -euo pipefail

# --- Resolve script directory and load host config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SSH_HOSTS_CONF:-$SCRIPT_DIR/ssh-hosts.conf}"

if [[ ! -f "$CONF_FILE" ]]; then
  echo "Error: Host config not found at $CONF_FILE" >&2
  exit 1
fi

declare -A HOST_IP USER_MAP
while read -r alias ip user || [[ -n "$alias" ]]; do
  [[ -z "$alias" ]] && continue
  [[ "$alias" =~ ^[[:space:]]*# ]] && continue
  HOST_IP["$alias"]="$ip"
  USER_MAP["$alias"]="$user"
done < "$CONF_FILE"

if [[ ${#HOST_IP[@]} -eq 0 ]]; then
  echo "Error: No hosts defined in $CONF_FILE" >&2
  exit 1
fi

# --- Log config ---
LOCAL_LOG_DIR="${SSH_AUDIT_LOG_DIR:-$HOME/.ssh-audit-logs}"
REMOTE_LOG_DIR=".ssh-audit"
AUDIT_USER="${SSH_AUDIT_USER:-$(whoami)}"

# --- Validate args ---
if [[ $# -lt 2 ]]; then
  echo "Usage: ssh-remote.sh <host-alias> \"<command>\"" >&2
  echo "Available hosts: ${!HOST_IP[*]}" >&2
  exit 1
fi

ALIAS="$1"; shift
CMD="$*"

if [[ -z "${HOST_IP[$ALIAS]+x}" ]]; then
  echo "Error: Unknown host '$ALIAS'. Available: ${!HOST_IP[*]}" >&2
  exit 1
fi

HOST="$ALIAS"
IP="${HOST_IP[$ALIAS]}"
USER="${USER_MAP[$ALIAS]}"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Ensure local log directory exists
mkdir -p "$LOCAL_LOG_DIR/${HOST}-${IP}"

# Log locally before execution
echo "[$TIMESTAMP] $USER@$IP: $CMD" >> "$LOCAL_LOG_DIR/${HOST}-${IP}/${DATE}.log"

# Single SSH connection: log remotely, then execute the command
# Encode the command in base64 to avoid shell injection in the remote echo
CMD_B64=$(printf '%s' "$CMD" | base64 | tr -d '\n')

EXIT_CODE=0
ssh "$USER@$IP" bash -s -- "$REMOTE_LOG_DIR" "$DATE" "$CMD_B64" "$AUDIT_USER" <<'REMOTE_EOF' || EXIT_CODE=$?
REMOTE_LOG_DIR="$1"; DATE="$2"; CMD_B64="$3"; AUDIT_USER="$4"
mkdir -p ~/"$REMOTE_LOG_DIR"
DECODED_CMD=$(echo "$CMD_B64" | base64 -d)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $AUDIT_USER: $DECODED_CMD" >> ~/"$REMOTE_LOG_DIR"/"$DATE".log
eval "$DECODED_CMD"
REMOTE_EOF

# Log failure locally if command failed
if [[ $EXIT_CODE -ne 0 ]]; then
  echo "[$TIMESTAMP] FAILED (exit $EXIT_CODE): $USER@$IP: $CMD" >> "$LOCAL_LOG_DIR/${HOST}-${IP}/${DATE}.log"
fi

exit $EXIT_CODE