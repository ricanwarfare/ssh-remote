#!/usr/bin/env bash
# ssh-remote.sh — Configurable SSH wrapper with audit logging
# Usage:
#   ssh-remote.sh <host-alias> "<command>"     — run remote command
#   ssh-remote.sh scp <local> <host>:<remote>  — upload file
#   ssh-remote.sh scp <host>:<remote> <local>  — download file
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

# --- Resolve host alias from scp path (host:path or host:path) ---
resolve_scp_host() {
  local scp_path="$1"
  # Extract the part before the colon
  local host_part="${scp_path%%:*}"
  # If no colon, it's a local path
  [[ "$scp_path" != *:* ]] && echo "" && return
  # Check if it's a known alias
  if [[ -n "${HOST_IP["$host_part"]+x}" ]]; then
    echo "$host_part"
  else
    echo ""
  fi
}

# Build the actual scp destination with user@ip
build_scp_path() {
  local scp_path="$1"
  local host_part="${scp_path%%:*}"
  local path_part="${scp_path#*:}"
  # If host_part is a known alias, resolve it
  if [[ -n "${HOST_IP["$host_part"]+x}" ]]; then
    echo "${USER_MAP["$host_part"]}@${HOST_IP["$host_part"]}:${path_part}"
  else
    # Not a known host — pass through as-is (could be a raw IP or hostname)
    echo "$scp_path"
  fi
}

# --- Log helper ---
log_local() {
  local host_label="$1" action="$2"
  local DATE=$(date +%Y-%m-%d)
  local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  # Extract host alias for log directory
  local ALIAS="$host_label"
  local IP="${HOST_IP["$ALIAS"]:-$host_label}"
  mkdir -p "$LOCAL_LOG_DIR/${ALIAS}-${IP}"
  echo "[$TIMESTAMP] $AUDIT_USER: $action" >> "$LOCAL_LOG_DIR/${ALIAS}-${IP}/${DATE}.log"
}

log_remote() {
  local host_alias="$1" action="$2"
  local IP="${HOST_IP["$host_alias"]}"
  local USER="${USER_MAP["$host_alias"]}"
  local DATE=$(date +%Y-%m-%d)
  local ACTION_B64=$(printf '%s' "$action" | base64 | tr -d '\n')

  ssh "$USER@$IP" bash -s -- "$REMOTE_LOG_DIR" "$DATE" "$ACTION_B64" "$AUDIT_USER" <<'REMOTE_EOF' || true
REMOTE_LOG_DIR="$1"; DATE="$2"; ACTION_B64="$3"; AUDIT_USER="$4"
mkdir -p ~/"$REMOTE_LOG_DIR"
DECODED_ACTION=$(echo "$ACTION_B64" | base64 -d)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $AUDIT_USER: $DECODED_ACTION" >> ~/"$REMOTE_LOG_DIR"/"$DATE".log
REMOTE_EOF
}

# --- SCP mode ---
if [[ "${1:-}" == "scp" ]]; then
  shift
  if [[ $# -lt 2 ]]; then
    echo "Usage: ssh-remote.sh scp <local_PATH> <host_alias>:<remote_PATH>" >&2
    echo "   or: ssh-remote.sh scp <host_alias>:<remote_PATH> <local_PATH>" >&2
    echo "Available hosts: ${!HOST_IP[*]}" >&2
    exit 1
  fi

  SRC="$1"
  DST="$2"

  # Determine which arg has the host alias
  UPLOAD_HOST=$(resolve_scp_host "$DST")
  DOWNLOAD_HOST=$(resolve_scp_host "$SRC")

  RESOLVED_SRC=$(build_scp_path "$SRC")
  RESOLVED_DST=$(build_scp_path "$DST")

  HOST_ALIAS=""
  ACTION_DESC=""

  if [[ -n "$UPLOAD_HOST" ]]; then
    HOST_ALIAS="$UPLOAD_HOST"
    ACTION_DESC="scp UPLOAD $SRC -> $DST"
  elif [[ -n "$DOWNLOAD_HOST" ]]; then
    HOST_ALIAS="$DOWNLOAD_HOST"
    ACTION_DESC="scp DOWNLOAD $SRC -> $DST"
  else
    # Neither side is a known host — log locally with generic label
    HOST_ALIAS="unknown"
    ACTION_DESC="scp $SRC -> $DST"
  fi

  # Log locally
  log_local "$HOST_ALIAS" "$ACTION_DESC"

  # Execute SCP
  EXIT_CODE=0
  scp "$RESOLVED_SRC" "$RESOLVED_DST" || EXIT_CODE=$?

  # Log remotely if host is known
  if [[ -n "$HOST_ALIAS" && "$HOST_ALIAS" != "unknown" ]]; then
    log_remote "$HOST_ALIAS" "$ACTION_DESC"
  fi

  # Log failure
  if [[ $EXIT_CODE -ne 0 ]]; then
    local_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local_date=$(date +%Y-%m-%d)
    local IP="${HOST_IP["$HOST_ALIAS"]:-unknown}"
    echo "[$local_ts] FAILED (exit $EXIT_CODE): $ACTION_DESC" >> "$LOCAL_LOG_DIR/${HOST_ALIAS}-${IP}/${local_date}.log"
  fi

  exit $EXIT_CODE
fi

# --- SSH command mode ---
if [[ $# -lt 2 ]]; then
  echo "Usage: ssh-remote.sh <host-alias> \"<command>\"" >&2
  echo "       ssh-remote.sh scp <src> <dst>" >&2
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
echo "[$TIMESTAMP] $AUDIT_USER: $USER@$IP: $CMD" >> "$LOCAL_LOG_DIR/${HOST}-${IP}/${DATE}.log"

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