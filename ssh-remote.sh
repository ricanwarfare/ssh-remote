#!/usr/bin/env bash
# ssh-remote.sh — Configurable SSH wrapper with audit logging
# Usage:
#   ssh-remote.sh <host-alias> "<command>"       — run remote command
#   ssh-remote.sh all "<command>"               — run command on all hosts
#   ssh-remote.sh hosts                          — list configured hosts
#   ssh-remote.sh scp <local> <host>:<remote>    — upload file (auto-falls back to base64 for SFTP-less hosts)
#   ssh-remote.sh scp <host>:<remote> <local>   — download file (auto-falls back to base64 for SFTP-less hosts)
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

# --- Resolve host alias from scp path (host:path) ---
resolve_scp_host() {
  local scp_path="$1"
  local host_part="${scp_path%%:*}"
  [[ "$scp_path" != *:* ]] && echo "" && return
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
  if [[ -n "${HOST_IP["$host_part"]+x}" ]]; then
    echo "${USER_MAP["$host_part"]}@${HOST_IP["$host_part"]}:${path_part}"
  else
    echo "$scp_path"
  fi
}

# --- Log helper ---
log_local() {
  local host_label="$1" action="$2"
  local DATE=$(date +%Y-%m-%d)
  local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  local ALIAS="$host_label"
  local IP="${HOST_IP["$ALIAS"]:-$host_label}"
  mkdir -p "$LOCAL_LOG_DIR/${ALIAS}-${IP}"
  echo "[$TIMESTAMP] $AUDIT_USER: $action" >> "$LOCAL_LOG_DIR/${ALIAS}-${IP}/${DATE}.log"
}

log_remote() {
  local host_alias="$1" action="$2"
  local IP="${HOST_IP[$host_alias]}"
  local USER="${USER_MAP[$host_alias]}"
  local DATE=$(date +%Y-%m-%d)
  local ACTION_B64=$(printf '%s' "$action" | base64 | tr -d '\n')

  ssh "$USER@$IP" bash -s -- "$REMOTE_LOG_DIR" "$DATE" "$ACTION_B64" "$AUDIT_USER" <<'REMOTE_EOF' || true
REMOTE_LOG_DIR="$1"; DATE="$2"; ACTION_B64="$3"; AUDIT_USER="$4"
mkdir -p ~/"$REMOTE_LOG_DIR"
DECODED_ACTION=$(echo "$ACTION_B64" | base64 -d)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $AUDIT_USER: $DECODED_ACTION" >> ~/"$REMOTE_LOG_DIR"/"$DATE".log
REMOTE_EOF
}

# --- Base64 transfer fallback (for hosts without SFTP support like Synology) ---
# Safely single-quote a value for use inside a remote shell command string.
# Replaces ' with '\'' so embedded single quotes can't break out of the quote.
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

base64_upload() {
  local local_file="$1" host_alias="$2" remote_path="$3"
  local IP="${HOST_IP[$host_alias]}"
  local USER="${USER_MAP[$host_alias]}"
  local B64
  B64=$(base64 -w 0 "$local_file")
  ssh "$USER@$IP" "echo '$(sq "$B64")' | base64 -d > $(sq "$remote_path")"
}

base64_download() {
  local host_alias="$1" remote_path="$2" local_file="$3"
  local IP="${HOST_IP[$host_alias]}"
  local USER="${USER_MAP[$host_alias]}"
  ssh "$USER@$IP" "base64 -w 0 $(sq "$remote_path")" | base64 -d > "$local_file"
}

# --- 'hosts' subcommand: list all configured hosts ---
if [[ "${1:-}" == "hosts" ]]; then
  printf "%-20s %-18s %-15s\n" "ALIAS" "IP" "USER"
  printf "%-20s %-18s %-15s\n" "-----" "--" "----"
  for alias in "${!HOST_IP[@]}"; do
    printf "%-20s %-18s %-15s\n" "$alias" "${HOST_IP[$alias]}" "${USER_MAP[$alias]}"
  done | sort
  exit 0
fi

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
    HOST_ALIAS="unknown"
    ACTION_DESC="scp $SRC -> $DST"
  fi

  # Log locally
  log_local "$HOST_ALIAS" "$ACTION_DESC"

  # Try SCP first
  EXIT_CODE=0
  SCP_ERR_FILE=$(mktemp)
  scp "$RESOLVED_SRC" "$RESOLVED_DST" 2>"$SCP_ERR_FILE" || EXIT_CODE=$?
  SCP_ERR=$(cat "$SCP_ERR_FILE")
  rm -f "$SCP_ERR_FILE"

  # Auto-fallback to base64 transfer if SFTP subsystem not supported
  if [[ $EXIT_CODE -ne 0 && "$HOST_ALIAS" != "unknown" ]]; then
    if echo "$SCP_ERR" | grep -qiE "subsystem request failed|Connection closed|protocol error"; then
      echo "scp: SFTP not supported on $HOST_ALIAS, falling back to base64 transfer..." >&2
      EXIT_CODE=0
      if [[ -n "$UPLOAD_HOST" ]]; then
        # Upload via base64
        local_file="$SRC"
        remote_path="${DST#*:}"
        base64_upload "$local_file" "$HOST_ALIAS" "$remote_path" || EXIT_CODE=$?
      elif [[ -n "$DOWNLOAD_HOST" ]]; then
        # Download via base64
        remote_path="${SRC#*:}"
        local_file="$DST"
        base64_download "$HOST_ALIAS" "$remote_path" "$local_file" || EXIT_CODE=$?
      fi
      if [[ $EXIT_CODE -eq 0 ]]; then
        echo "scp: base64 transfer successful" >&2
        # Update action description to note fallback was used
        ACTION_DESC="$ACTION_DESC (base64 fallback)"
      fi
    fi
  fi

  # Log remotely if host is known
  if [[ -n "$HOST_ALIAS" && "$HOST_ALIAS" != "unknown" ]]; then
    log_remote "$HOST_ALIAS" "$ACTION_DESC"
  fi

  # Log failure
  if [[ $EXIT_CODE -ne 0 ]]; then
    fail_ts=$(date '+%Y-%m-%d %H:%M:%S')
    fail_date=$(date +%Y-%m-%d)
    fail_ip="${HOST_IP["$HOST_ALIAS"]:-unknown}"
    echo "[$fail_ts] FAILED (exit $EXIT_CODE): $ACTION_DESC" >> "$LOCAL_LOG_DIR/${HOST_ALIAS}-${fail_ip}/${fail_date}.log"
  fi

  exit $EXIT_CODE
fi

# --- SSH command mode ---

if [[ $# -lt 1 ]]; then
  echo "Usage: ssh-remote.sh <host-alias> \"<command>\"" >&2
  echo "       ssh-remote.sh all \"<command>\"" >&2
  echo "       ssh-remote.sh hosts" >&2
  echo "       ssh-remote.sh scp <src> <dst>" >&2
  echo "Available hosts: ${!HOST_IP[*]}" >&2
  exit 1
fi

ALIAS="$1"; shift
CMD="$*"

if [[ -z "$CMD" ]]; then
  echo "Error: No command specified" >&2
  echo "Usage: ssh-remote.sh <host-alias> \"<command>\"" >&2
  echo "       ssh-remote.sh all \"<command>\"" >&2
  echo "Available hosts: ${!HOST_IP[*]}" >&2
  exit 1
fi

# --- 'all' target: run command on every configured host ---
if [[ "$ALIAS" == "all" ]]; then
  ALL_EXIT=0
  for h in "${!HOST_IP[@]}"; do
    echo "=== $h (${HOST_IP[$h]}) ==="
    "$0" "$h" "$CMD" || {
      echo "(failed on $h)" >&2
      ALL_EXIT=1
    }
    echo ""
  done
  exit $ALL_EXIT
fi

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