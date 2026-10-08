#!/usr/bin/env bash
# Audit-logged SSH commands and single-file transfers. Requires Bash 4.4+.
# Remote command strings deliberately expand locally through sq() before SSH.
# shellcheck disable=SC2029
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: ssh-remote.sh [--jobs N] [--audit-format text|json] <alias|all|@group> "<command>"
       ssh-remote.sh hosts
       ssh-remote.sh groups
       ssh-remote.sh doctor [alias|all|@group]
       ssh-remote.sh scp <local> <alias>:<remote> (or reverse)
       ssh-remote.sh --help

Options precede the subcommand. Parallel commands have no stdin; sequential
commands share stdin. JSON selects JSON Lines audit files, not command output.
Connection settings: SSH_CONNECT_TIMEOUT (10), SSH_KEEPALIVE_INTERVAL (15),
SSH_KEEPALIVE_COUNT (3), SSH_REMOTE_SSH_CONFIG (optional OpenSSH config).
HELP
}
JOBS=1
AUDIT_FORMAT=${SSH_AUDIT_FORMAT:-text}
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --jobs|--audit-format)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      if [[ $1 == --jobs ]]; then JOBS=$2; else AUDIT_FORMAT=$2; fi
      shift 2 ;;
    --) shift; break ;;
    *) printf 'Error: Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[[ $JOBS =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'Error: jobs must be 1–9999' >&2; exit 1; }
[[ $AUDIT_FORMAT == text || $AUDIT_FORMAT == json ]] || { echo 'Error: audit format must be text or json' >&2; exit 1; }
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo 'Error: Bash 4.4+ required' >&2; exit 1; }
CONNECT_TIMEOUT=${SSH_CONNECT_TIMEOUT:-10}
KEEPALIVE_INTERVAL=${SSH_KEEPALIVE_INTERVAL:-15}
KEEPALIVE_COUNT=${SSH_KEEPALIVE_COUNT:-3}
for value in "$CONNECT_TIMEOUT" "$KEEPALIVE_INTERVAL" "$KEEPALIVE_COUNT"; do
  [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'Error: connection settings must be positive integers' >&2; exit 1; }
done
SSH_OPTIONS=(-o BatchMode=yes -o "ConnectTimeout=$CONNECT_TIMEOUT"
  -o "ServerAliveInterval=$KEEPALIVE_INTERVAL" -o "ServerAliveCountMax=$KEEPALIVE_COUNT")
if [[ -n ${SSH_REMOTE_SSH_CONFIG:-} ]]; then SSH_OPTIONS+=(-F "$SSH_REMOTE_SSH_CONFIG"); fi

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
  if [[ ! "$alias" =~ ^[a-z0-9_-]+$ || "$alias" == all || "$alias" == hosts || "$alias" == scp || "$alias" == groups || "$alias" == doctor ||
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

# Groups live separately so existing three-field host files remain valid.
declare -A GROUP_MAP=()
GROUP_FILE=${SSH_HOST_GROUPS_CONF:-$SCRIPT_DIR/ssh-groups.conf}
if [[ -e $GROUP_FILE ]]; then
  line=0
  while read -r group members || [[ -n $group ]]; do
    line=$((line + 1))
    [[ -z $group || $group == \#* ]] && continue
    if [[ ! $group =~ ^[a-z0-9_-]+$ || -z $members || -n ${GROUP_MAP[$group]+x} ]]; then
      printf 'Error: Invalid or duplicate group at %s:%s\n' "$GROUP_FILE" "$line" >&2; exit 1
    fi
    read -r -a group_hosts <<< "$members"
    for member in "${group_hosts[@]}"; do
      [[ $member =~ ^[a-z0-9_-]+$ && -n ${HOST_IP[$member]+x} ]] || { printf 'Error: Unknown group member at %s:%s: %s\n' "$GROUP_FILE" "$line" "$member" >&2; exit 1; }
    done
    GROUP_MAP[$group]=$members
  done < "$GROUP_FILE"
elif [[ -n ${SSH_HOST_GROUPS_CONF:-} ]]; then
  printf 'Error: Group config not found at %s\n' "$GROUP_FILE" >&2; exit 1
fi
select_hosts() {
  local target=$1
  case "$target" in
    all) printf '%s\n' "${!HOST_IP[@]}" | sort ;;
    @*)
      [[ -n ${target#@} && -n ${GROUP_MAP[${target#@}]+x} ]] || { printf 'Error: Unknown group: %s\n' "$target" >&2; return 1; }
      local -a members
      read -r -a members <<< "${GROUP_MAP[${target#@}]}"
      printf '%s\n' "${members[@]}" | sort -u ;;
    *)
      [[ -n $target && -n ${HOST_IP[$target]+x} ]] || { printf 'Error: Unknown host: %s\n' "$target" >&2; return 1; }
      printf '%s\n' "$target" ;;
  esac
}

LOCAL_LOG_DIR="${SSH_AUDIT_LOG_DIR:-$HOME/.ssh-audit-logs}"
AUDIT_USER="${SSH_AUDIT_USER:-$(whoami)}"
# Quote each argument for the login shell used by ssh (which joins arguments).
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
# Keep ordinary commands readable; escape control characters into one log line.
log_text() {
  if [[ "$1" == *[[:cntrl:]]* ]]; then printf '%q' "$1"; else printf '%s' "$1"; fi
}
# Pure Bash JSON escaping keeps remote logging independent of Python/jq.
json_string() {
  local text=$1 char code i
  printf '"'
  for ((i=0; i<${#text}; i++)); do
    char=${text:i:1}
    case "$char" in
      '"') printf '\\"' ;;
      \\) printf '\134\134' ;;
      *)
        if [[ $char == [[:cntrl:]] ]]; then
          printf -v code '%d' "'$char"
          printf '\\u%04x' "$code"
        else printf '%s' "$char"; fi ;;
    esac
  done
  printf '"'
}
audit_write() (
  umask 077
  local directory=$1 action=$2 event=$3 status=$4 started=$5 host=$6
  local logfile timestamp finished duration record
  mkdir -p -- "$directory" || return
  chmod 700 -- "$directory" || return
  logfile="$directory/$(date +%Y-%m-%d)"
  if [[ $AUDIT_FORMAT == json ]]; then logfile+=.jsonl; else logfile+=.log; fi
  [[ ! -L $logfile ]] || { echo 'Error: Refusing symlink audit file' >&2; return 1; }
  touch -- "$logfile" && chmod 600 -- "$logfile" || return
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  finished=$(date +%s)
  duration=$((finished - started))
  if [[ $AUDIT_FORMAT == json ]]; then
    record=$(printf '{"timestamp":%s,"run_id":%s,"operator":%s,"host":%s,"event":%s,"action":%s,"started_at":%s,"finished_at":%s,"duration_seconds":%s,"exit_status":%s}' \
      "$(json_string "$timestamp")" "$(json_string "$RUN_ID")" "$(json_string "$AUDIT_USER")" \
      "$(json_string "$host")" "$(json_string "$event")" "$(json_string "$action")" \
      "$started" "$([[ $event == finish ]] && printf '%s' "$finished" || printf null)" \
      "$([[ $event == finish ]] && printf '%s' "$duration" || printf null)" "$status") || return
  else
    record="[$timestamp] $(log_text "$AUDIT_USER"): $(log_text "$action") [run=$RUN_ID event=$event exit=$status duration=${duration}s]"
  fi
  printf '%s\n' "$record" >> "$logfile"
)
RUN_ID=${SSH_REMOTE_RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM}
# This value appears unescaped in text metadata; prevent forged records.
[[ $RUN_ID =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Error: Invalid run ID' >&2; exit 1; }
log_local() (
  umask 077
  local host=$1 action=$2 event=${3:-start} status=${4:-null} started=${5:-$SECONDS_STARTED}
  mkdir -p -- "$LOCAL_LOG_DIR" && chmod 700 -- "$LOCAL_LOG_DIR" || return
  audit_write "$LOCAL_LOG_DIR/$host-${HOST_IP[$host]}" "$action" "$event" "$status" "$started" "$host"
)
SECONDS_STARTED=$(date +%s)

# Send the wrapper as a quoted command, leaving SSH stdin for the user's command.
REMOTE_WRAPPER="$(declare -f log_text json_string audit_write)
$(cat <<'REMOTE'
set -euo pipefail
# A sentinel preserves trailing newlines removed by command substitution.
decoded=$(printf '%s' "$1" | base64 -d || exit; printf '.')
decoded=${decoded%.}
AUDIT_USER=$2
mode=$3
RUN_ID=$4
AUDIT_FORMAT=$5
host=$6
event=$7
status=$8
started=$9
if [[ $mode == execute ]]; then started=$(date +%s); fi
audit_write "$HOME/.ssh-audit" "$decoded" "$event" "$status" "$started" "$host"
if [[ $mode == execute ]]; then
  status=0
  bash -c "$decoded" || status=$?
  action=$decoded
  if [[ $status -ne 0 ]]; then action="FAILED (exit $status): $action"; fi
  audit_write "$HOME/.ssh-audit" "$action" finish "$status" "$started" "$host" || echo 'Warning: Could not write remote command result' >&2
  exit "$status"
fi
REMOTE
)"
remote_audit() {
  local host=$1 action=$2 mode=$3 event=${4:-start} status=${5:-null} started=${6:-$SECONDS_STARTED} encoded connection
  encoded=$(printf '%s' "$action" | base64 | tr -d '\n') || return
  ssh "${SSH_OPTIONS[@]}" "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "bash -c $(sq "$REMOTE_WRAPPER") -- $(sq "$encoded") $(sq "$AUDIT_USER") $(sq "$mode") $(sq "$RUN_ID") $(sq "$AUDIT_FORMAT") $(sq "$host") $(sq "$event") $(sq "$status") $(sq "$started")" <&0 &
  connection=$!
  trap 'kill "$connection" 2>/dev/null || true; wait "$connection" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local status=0
  wait "$connection" || status=$?
  trap - EXIT INT TERM
  return "$status"
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
[[ ! -d $destination ]] || { echo 'Error: Destination is a directory' >&2; exit 1; }
# Stage in the same directory, so interrupted transfers leave the target intact.
temporary=$(mktemp -- "${destination}.ssh-remote.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
base64 -d > "$temporary"
[[ $(wc -c < "$temporary") -eq "$3" ]] || { echo "Error: Incomplete upload" >&2; exit 1; }
mv -fT -- "$temporary" "$destination"
REMOTE
)
  base64 < "$source" | ssh "${SSH_OPTIONS[@]}" "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "bash -c $(sq "$wrapper") -- $(sq "$destination") $(sq "${source##*/}") $(sq "$size")"
}
base64_download() (
  local host="$1" source="$2" destination="$3" temporary status=0
  if [[ -d "$destination" ]]; then destination="${destination%/}/${source##*/}"; fi
  [[ ! -d $destination ]] || { echo 'Error: Destination is a directory' >&2; return 1; }
  temporary=$(mktemp -- "${destination}.ssh-remote.XXXXXX") || return
  trap 'rm -f -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ssh "${SSH_OPTIONS[@]}" "${USER_MAP[$host]}@${HOST_IP[$host]}" \
    "base64 < $(sq "$source")" | base64 -d > "$temporary" || status=$?
  if [[ "$status" -eq 0 ]]; then mv -fT -- "$temporary" "$destination" || status=$?; fi
  rm -f -- "$temporary"
  return "$status"
)

if [[ ${1:-} == groups && $# -eq 1 ]]; then
  for group in "${!GROUP_MAP[@]}"; do printf '%s %s\n' "$group" "${GROUP_MAP[$group]}"; done | sort
  exit 0
fi
if [[ ${1:-} == doctor ]]; then
  [[ $# -le 2 ]] || { usage >&2; exit 1; }
  status=0
  for dependency in bash ssh scp base64 date mktemp chmod touch mv wc sort tr cat grep rm; do
    if ! command -v "$dependency" >/dev/null; then printf 'MISSING %s\n' "$dependency"; status=1; fi
  done
  [[ $status -eq 0 ]] || exit "$status"
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo 'Bash 4.4+ required'; exit 1; }
  [[ $(printf dGVzdA== | base64 -d) == test ]] || { echo 'Error: base64 -d required' >&2; exit 1; }
  [[ $(mv --help) == *--no-target-directory* ]] || { echo 'Error: GNU mv (-T) required' >&2; exit 1; }
  printf 'OK local dependencies and configuration\n'
  mkdir -p -- "$LOCAL_LOG_DIR" && chmod 700 -- "$LOCAL_LOG_DIR" || exit 1
  probe=$(mktemp "$LOCAL_LOG_DIR/.doctor.XXXXXX") || exit 1
  rm -f -- "$probe"
  selected=$(select_hosts "${2:-all}") || exit 1
  while IFS= read -r host; do
    # Remote shell expands these variables, not the local shell.
    # shellcheck disable=SC2016
    diagnostic='set -euo pipefail
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))
for dependency in base64 date mktemp chmod touch mv wc; do command -v "$dependency" >/dev/null; done
[[ $(printf dGVzdA== | base64 -d) == test ]]
[[ $(mv --help) == *--no-target-directory* ]]
umask 077
mkdir -p "$HOME/.ssh-audit"
chmod 700 "$HOME/.ssh-audit"
probe=$(mktemp "$HOME/.ssh-audit/.doctor.XXXXXX")
rm -f -- "$probe"'
    if ssh "${SSH_OPTIONS[@]}" "${USER_MAP[$host]}@${HOST_IP[$host]}" "bash -c $(sq "$diagnostic")" </dev/null; then
      printf 'OK %s: authentication, Bash, utilities, audit directory\n' "$host"
    else printf 'FAILED %s: remote diagnostics\n' "$host"; status=1; fi
  done <<< "$selected"
  exit "$status"
fi

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
  trap 'exit 130' INT
  trap 'exit 143' TERM
  scp "${SSH_OPTIONS[@]}" "$RESOLVED_SRC" "$RESOLVED_DST" 2>"$SCP_ERR_FILE" || EXIT_CODE=$?
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
  log_local "$HOST_ALIAS" "$ACTION_DESC" finish "$EXIT_CODE" || printf 'Warning: Could not log transfer result locally\n' >&2
  (remote_audit "$HOST_ALIAS" "$ACTION_DESC" log finish "$EXIT_CODE") </dev/null || \
    printf 'Warning: Could not write remote transfer audit on %s\n' "$HOST_ALIAS" >&2
  exit "$EXIT_CODE"
fi

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi
ALIAS="$1"; shift
CMD="$*"
if [[ -z "$CMD" ]]; then
  printf 'Error: No command specified\n' >&2
  exit 1
fi
selected=$(select_hosts "$ALIAS") || exit 1
run_command() {
  local host=$1 action="${USER_MAP[$1]}@${HOST_IP[$1]}: $CMD" status=0 started connection
  started=$(date +%s)
  log_local "$host" "$action" start null "$started" || return 1
  remote_audit "$host" "$CMD" execute start null "$started" <&0 &
  connection=$!
  trap 'kill "$connection" 2>/dev/null || true; wait "$connection" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wait "$connection" || status=$?
  trap - EXIT INT TERM
  if [[ $status -ne 0 ]]; then action="FAILED (exit $status): $action"; fi
  log_local "$host" "$action" finish "$status" "$started" || echo 'Warning: Could not log command result locally' >&2
  return "$status"
}
if [[ $ALIAS != all && $ALIAS != @* ]]; then
  run_command "$ALIAS"
  exit $?
fi
mapfile -t targets <<< "$selected"
declare -A results=() pids=()
ALL_EXIT=0
if [[ $JOBS -eq 1 ]]; then
  for host in "${targets[@]}"; do
    printf '=== %s (%s) ===\n' "$host" "${HOST_IP[$host]}"
    status=0
    run_command "$host" || status=$?
    results[$host]=$status
  done
else
  output_dir=$(mktemp -d)
  # Invoked by the EXIT trap.
  # shellcheck disable=SC2329
  cleanup_parallel() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf -- "$output_dir"
  }
  trap cleanup_parallel EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Bound concurrency in batches; output is replayed in sorted host order.
  for ((offset=0; offset<${#targets[@]}; offset+=JOBS)); do
    pids=()
    batch=("${targets[@]:offset:JOBS}")
    for host in "${batch[@]}"; do
      run_command "$host" </dev/null >"$output_dir/$host.out" 2>"$output_dir/$host.err" &
      pids[$host]=$!
    done
    for host in "${batch[@]}"; do
      status=0
      wait "${pids[$host]}" || status=$?
      unset 'pids[$host]'
      results[$host]=$status
      printf '=== %s (%s) ===\n' "$host" "${HOST_IP[$host]}"
      cat "$output_dir/$host.out"
      cat "$output_dir/$host.err" >&2
    done
  done
fi
printf '\nHost summary (run %s):\n' "$RUN_ID"
for host in "${targets[@]}"; do
  printf '%-20s exit %s\n' "$host" "${results[$host]}"
  [[ ${results[$host]} -eq 0 ]] || ALL_EXIT=1
done
exit "$ALL_EXIT"
