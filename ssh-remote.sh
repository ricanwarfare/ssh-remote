#!/usr/bin/env bash
# Audit-logged SSH commands and single-file transfers. Requires Bash 4.4+.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SSH_HOSTS_CONF:-$SCRIPT_DIR/ssh-hosts.conf}"
if [[ ! -f "$CONF_FILE" ]]; then
  printf 'Error: Host config not found at %s\n' "$CONF_FILE" >&2
  exit 1
fi

declare -A HOST_IP=() USER_MAP=()
line=0
while read -r alias ip user extra || [[ -n "$alias" ]]; do
  line=$((line + 1))
  [[ -z "$alias" || "$alias" == \#* ]] && continue
  if [[ ! "$alias" =~ ^[a-z0-9_-]+$ || "$alias" == all || "$alias" == hosts || "$alias" == scp ||
        ! "$ip" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ||
        ! "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ || -n "$extra" ]]; then
    printf 'Error: Invalid host entry at %s:%s (expected alias host user)\n' "$CONF_FILE" "$line" >&2
    exit 1
  fi
  if [[ -n "${HOST_IP[$alias]+x}" ]]; then
    printf 'Error: Duplicate host alias at %s:%s\n' "$CONF_FILE" "$line" >&2
    exit 1
  fi
  HOST_IP["$alias"]="$ip"
  USER_MAP["$alias"]="$user"
done < "$CONF_FILE"
if [[ ${#HOST_IP[@]} -eq 0 ]]; then
  printf 'Error: No hosts defined in %s\n' "$CONF_FILE" >&2
  exit 1
fi

LOCAL_LOG_DIR="${SSH_AUDIT_LOG_DIR:-$HOME/.ssh-audit-logs}"
AUDIT_USER="${SSH_AUDIT_USER:-$(whoami)}"
# Quote each argument for the login shell used by ssh (which joins arguments).
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
# Keep ordinary commands readable; escape control characters into one log line.
log_text() {
  if [[ "$1" == *[[:cntrl:]]* ]]; then printf '%q' "$1"; else printf '%s' "$1"; fi
}
log_local() {
  local host="$1" action="$2" directory
  directory="$LOCAL_LOG_DIR/$host-${HOST_IP[$host]}"
  mkdir -p -- "$directory" || return
  printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$(log_text "$AUDIT_USER")" "$(log_text "$action")" >> "$directory/$(date +%Y-%m-%d).log"
}

# Send the wrapper as a quoted command, leaving SSH stdin for the user's command.
REMOTE_WRAPPER=$(cat <<'REMOTE'
set -euo pipefail
log_text() {
  if [[ "$1" == *[[:cntrl:]]* ]]; then printf '%q' "$1"; else printf '%s' "$1"; fi
}
# A sentinel preserves trailing newlines removed by command substitution.
decoded=$(printf '%s' "$1" | base64 -d || exit; printf '.')
decoded=${decoded%.}
mkdir -p -- "$HOME/.ssh-audit"
printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
  "$(log_text "$2")" "$(log_text "$decoded")" >> "$HOME/.ssh-audit/$(date +%Y-%m-%d).log"
if [[ "$3" == execute ]]; then exec bash -c "$decoded"; fi
REMOTE
)
remote_audit() {
  local host="$1" action="$2" mode="$3" encoded
  encoded=$(printf '%s' "$action" | base64 | tr -d '\n') || return
  ssh -o BatchMode=yes "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "bash -c $(sq "$REMOTE_WRAPPER") -- $(sq "$encoded") $(sq "$AUDIT_USER") $(sq "$mode")"
}

# Only host:path is remote. ./name:part and /path/name:part are local paths.
resolve_scp_host() {
  local path="$1" host="${1%%:*}"
  if [[ "$path" == *:* && "$host" != */* ]]; then
    if [[ -z "$host" || -z "${HOST_IP[$host]+x}" || -z "${path#*:}" ]]; then
      printf 'Error: Invalid or unknown transfer endpoint: %s\n' "$path" >&2
      return 1
    fi
    printf '%s' "$host"
  fi
}
build_scp_path() {
  local path="$1" host="$2" ip
  if [[ -n "$host" ]]; then
    ip="${HOST_IP[$host]}"
    [[ "$ip" != *:* ]] || ip="[$ip]"
    printf '%s@%s:%s' "${USER_MAP[$host]}" "$ip" "${path#*:}"
  elif [[ "$path" == /* || "$path" == ./* ]]; then
    printf '%s' "$path"
  else
    printf './%s' "$path"
  fi
}
base64_upload() {
  local source="$1" host="$2" destination="$3" wrapper size
  if [[ ! -f "$source" || ! -r "$source" ]]; then
    printf 'Error: Upload source must be a readable regular file: %s\n' "$source" >&2
    return 1
  fi
  size=$(wc -c < "$source") || return
  wrapper=$(cat <<'REMOTE'
set -euo pipefail
destination=$1
if [[ -d "$destination" ]]; then destination=${destination%/}/$2; fi
# Stage in the same directory, so interrupted transfers leave the target intact.
temporary=$(mktemp -- "${destination}.ssh-remote.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
base64 -d > "$temporary"
[[ $(wc -c < "$temporary") -eq "$3" ]] || { echo "Error: Incomplete upload" >&2; exit 1; }
mv -f -- "$temporary" "$destination"
REMOTE
)
  base64 < "$source" | ssh -o BatchMode=yes "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "bash -c $(sq "$wrapper") -- $(sq "$destination") $(sq "${source##*/}") $(sq "$size")"
}
base64_download() {
  local host="$1" source="$2" destination="$3" temporary status=0
  if [[ -d "$destination" ]]; then destination="${destination%/}/${source##*/}"; fi
  temporary=$(mktemp -- "${destination}.ssh-remote.XXXXXX") || return
  ssh -o BatchMode=yes "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "base64 < $(sq "$source")" | base64 -d > "$temporary" || status=$?
  if [[ "$status" -eq 0 ]]; then mv -f -- "$temporary" "$destination" || status=$?; fi
  rm -f -- "$temporary"
  return "$status"
}

if [[ "${1:-}" == hosts && $# -eq 1 ]]; then
  printf '%-20s %-18s %-15s\n' ALIAS HOST USER
  for alias in "${!HOST_IP[@]}"; do
    printf '%-20s %-18s %-15s\n' "$alias" "${HOST_IP[$alias]}" "${USER_MAP[$alias]}"
  done | sort
  exit 0
fi

if [[ "${1:-}" == scp ]]; then
  if [[ $# -ne 3 ]]; then
    printf 'Usage: ssh-remote.sh scp <local> <alias>:<remote> (or reverse)\n' >&2
    exit 1
  fi
  SRC="$2" DST="$3"
  UPLOAD_HOST=$(resolve_scp_host "$DST")
  DOWNLOAD_HOST=$(resolve_scp_host "$SRC")
  if [[ -n "$UPLOAD_HOST" && -n "$DOWNLOAD_HOST" || -z "$UPLOAD_HOST" && -z "$DOWNLOAD_HOST" ]]; then
    printf 'Error: Transfers require exactly one configured remote endpoint and one local path\n' >&2
    exit 1
  fi
  HOST_ALIAS="${UPLOAD_HOST:-$DOWNLOAD_HOST}"
  RESOLVED_SRC=$(build_scp_path "$SRC" "$DOWNLOAD_HOST")
  RESOLVED_DST=$(build_scp_path "$DST" "$UPLOAD_HOST")
  ACTION_DESC="scp $SRC -> $DST"
  log_local "$HOST_ALIAS" "$ACTION_DESC"
  EXIT_CODE=0
  SCP_ERR_FILE=$(mktemp)
  trap 'rm -f -- "$SCP_ERR_FILE"' EXIT
  scp -o BatchMode=yes "$RESOLVED_SRC" "$RESOLVED_DST" 2>"$SCP_ERR_FILE" || EXIT_CODE=$?
  # Retry only a definite missing SFTP subsystem, not generic connection errors.
  if [[ $EXIT_CODE -ne 0 ]] && grep -qi 'subsystem request failed' "$SCP_ERR_FILE"; then
    printf 'scp: SFTP unavailable on %s; trying base64 transfer\n' "$HOST_ALIAS" >&2
    EXIT_CODE=0
    ACTION_DESC="$ACTION_DESC (base64 fallback)"
    if [[ -n "$UPLOAD_HOST" ]]; then
      base64_upload "$RESOLVED_SRC" "$HOST_ALIAS" "${DST#*:}" || EXIT_CODE=$?
    else
      base64_download "$HOST_ALIAS" "${SRC#*:}" "$RESOLVED_DST" || EXIT_CODE=$?
    fi
  elif [[ -s "$SCP_ERR_FILE" ]]; then
    cat "$SCP_ERR_FILE" >&2
  fi
  if [[ $EXIT_CODE -ne 0 ]]; then ACTION_DESC="FAILED (exit $EXIT_CODE): $ACTION_DESC"; fi
  log_local "$HOST_ALIAS" "$ACTION_DESC" || printf 'Warning: Could not log transfer result locally\n' >&2
  remote_audit "$HOST_ALIAS" "$ACTION_DESC" log </dev/null || \
    printf 'Warning: Could not write remote transfer audit on %s\n' "$HOST_ALIAS" >&2
  exit "$EXIT_CODE"
fi

if [[ $# -lt 2 ]]; then
  printf 'Usage: ssh-remote.sh <alias|all> "<command>"\n       ssh-remote.sh hosts\n       ssh-remote.sh scp <src> <dst>\n' >&2
  exit 1
fi
ALIAS="$1"; shift
CMD="$*"
if [[ -z "$CMD" ]]; then
  printf 'Error: No command specified\n' >&2
  exit 1
fi
if [[ "$ALIAS" == all ]]; then
  ALL_EXIT=0
  for h in "${!HOST_IP[@]}"; do
    printf '=== %s (%s) ===\n' "$h" "${HOST_IP[$h]}"
    bash "$SCRIPT_DIR/ssh-remote.sh" "$h" "$CMD" || ALL_EXIT=1
  done
  exit "$ALL_EXIT"
fi
if [[ -z "${HOST_IP[$ALIAS]+x}" ]]; then
  printf 'Error: Unknown host: %s\n' "$ALIAS" >&2
  exit 1
fi
ACTION_DESC="${USER_MAP[$ALIAS]}@${HOST_IP[$ALIAS]}: $CMD"
log_local "$ALIAS" "$ACTION_DESC"
EXIT_CODE=0
remote_audit "$ALIAS" "$CMD" execute || EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  log_local "$ALIAS" "FAILED (exit $EXIT_CODE): $ACTION_DESC" || \
    printf 'Warning: Could not log command failure locally\n' >&2
fi
exit "$EXIT_CODE"
