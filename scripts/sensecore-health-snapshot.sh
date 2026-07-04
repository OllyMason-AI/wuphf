#!/usr/bin/env bash
# Sensecore WUPHF Orchestration Health Snapshot
# Read-only diagnostic snapshot. Does not restart services, mutate broker state,
# answer requests, send messages, call models, or edit config.

set -u

WUPHF_DIR="${WUPHF_DIR:-/opt/wuphf}"
WUPHF_SERVICE="${WUPHF_SERVICE:-sensecore-wuphf.service}"
BROKER_URL="${BROKER_URL:-http://127.0.0.1:7890}"
WEB_URL="${WEB_URL:-http://127.0.0.1:7891}"
HERMES_DEFAULT_PORT="${HERMES_DEFAULT_PORT:-8742}"
PUBLIC_OFFICE_URL="${PUBLIC_OFFICE_URL:-https://office.sensecoretech.co.uk}"
WARN_BACKUP_HOURS="${WARN_BACKUP_HOURS:-24}"
LOG_LINES="${LOG_LINES:-300}"
NOW_EPOCH="$(date +%s)"

PASS_REASONS=()
WARN_REASONS=()
FAIL_REASONS=()

add_pass() { PASS_REASONS+=("$*"); }
add_warn() { WARN_REASONS+=("$*"); }
add_fail() { FAIL_REASONS+=("$*"); }

redact() {
  sed -E \
    -e 's/(api[_-]?key|token|secret|password|authorization|bearer)[=: ][^[:space:]]+/\1=[REDACTED]/Ig' \
    -e 's/(nvapi-)[A-Za-z0-9._-]+/\1[REDACTED]/g' \
    -e 's/(sk-[A-Za-z0-9._-]{8})[A-Za-z0-9._-]+/\1[REDACTED]/g'
}

age_human() {
  local epoch="$1"
  if [[ -z "$epoch" || "$epoch" == "0" ]]; then printf 'unknown'; return; fi
  local delta=$((NOW_EPOCH - epoch))
  if (( delta < 60 )); then printf '%ss' "$delta"
  elif (( delta < 3600 )); then printf '%sm' $((delta/60))
  elif (( delta < 86400 )); then printf '%sh' $((delta/3600))
  else printf '%sd' $((delta/86400))
  fi
}

file_stat_line() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    local epoch
    epoch="$(stat -c %Y "$path" 2>/dev/null || printf 0)"
    printf '%-28s %s | mtime=%s | age=%s\n' "$label" "$path" "$(date -d "@$epoch" '+%F %T %Z' 2>/dev/null || printf unknown)" "$(age_human "$epoch")"
  else
    printf '%-28s missing | %s\n' "$label" "$path"
  fi
}

service_summary() {
  local unit="$1"
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 && ! systemctl status "$unit" >/dev/null 2>&1; then
    printf 'unit=%s present=no\n' "$unit"
    return 1
  fi
  local active enabled mainpid restarts mem active_ts restart restart_sec
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  mainpid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
  restarts="$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || true)"
  mem="$(systemctl show "$unit" -p MemoryCurrent --value 2>/dev/null || true)"
  active_ts="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  restart="$(systemctl show "$unit" -p Restart --value 2>/dev/null || true)"
  restart_sec="$(systemctl show "$unit" -p RestartUSec --value 2>/dev/null || true)"
  printf 'unit=%s active=%s enabled=%s main_pid=%s restarts=%s memory_bytes=%s active_since="%s" restart=%s restart_sec=%s\n' \
    "$unit" "$active" "$enabled" "$mainpid" "${restarts:-unknown}" "${mem:-unknown}" "$active_ts" "${restart:-unknown}" "${restart_sec:-unknown}"
  [[ "$active" == "active" ]]
}

port_check() {
  local port="$1" label="$2"
  local line
  line="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print}' | redact | head -1)"
  if [[ -n "$line" ]]; then
    printf 'PASS port %-5s %-24s LISTEN %s\n' "$port" "$label" "$line"
    return 0
  fi
  printf 'FAIL port %-5s %-24s not listening\n' "$port" "$label"
  return 1
}

http_code() {
  local url="$1"
  curl -sS --max-time 5 -o /tmp/wuphf-health-snapshot-body.$$ -w '%{http_code}' "$url" 2>/dev/null || printf '000'
}

json_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json, sys
p, key = sys.argv[1], sys.argv[2]
try:
    data=json.load(open(p))
    cur=data
    for part in key.split('.'):
        cur=cur.get(part) if isinstance(cur, dict) else None
    if isinstance(cur, bool): print(str(cur).lower())
    elif cur is None: print('')
    else: print(cur)
except Exception:
    pass
PY
}

section() { printf '\n## %s\n' "$*"; }

printf '# Sensecore WUPHF Orchestration Health Snapshot\n'
printf 'timestamp_utc=%s\n' "$(date -u '+%F %T UTC')"
printf 'host=%s user=%s\n' "$(hostname)" "$(id -un)"
printf 'read_only=true\n'

section '1. System services'
if service_summary "$WUPHF_SERVICE"; then add_pass "$WUPHF_SERVICE active"; else add_fail "$WUPHF_SERVICE not active"; fi

printf '\n# Hermes/router units discovered\n'
mapfile -t HERMES_UNITS < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'hermes|wuphf.*router|router.*hermes' | sort -u || true)
if (( ${#HERMES_UNITS[@]} == 0 )); then
  printf 'none discovered via systemd\n'
  add_warn 'No Hermes/router systemd unit discovered; gateway may be process-managed rather than service-managed'
else
  for unit in "${HERMES_UNITS[@]}"; do service_summary "$unit" || true; done
fi

printf '\n# Hermes/router processes\n'
HERMES_PROCS="$(pgrep -af 'hermes|wuphf.*router|router.*hermes' 2>/dev/null | grep -v 'sensecore-health-snapshot' | grep -v 'avahi-daemon' | redact || true)"
if [[ -n "$HERMES_PROCS" ]]; then printf '%s\n' "$HERMES_PROCS" | head -20; add_pass 'Hermes/router process discovered'; else printf 'none\n'; add_warn 'No Hermes/router process discovered'; fi

section '2. Ports'
port_check 7890 'WUPHF broker' || add_fail 'WUPHF broker port 7890 not listening'
port_check 7891 'WUPHF web' || add_fail 'WUPHF web port 7891 not listening'
port_check "$HERMES_DEFAULT_PORT" 'Hermes research gateway' || add_warn "Hermes research gateway port $HERMES_DEFAULT_PORT not listening"
printf '\n# Other Hermes/router-like listening ports\n'
ss -ltnp 2>/dev/null | grep -Ei 'hermes|router|wuphf' | redact || true

section '3. WUPHF health'
HEALTH_BODY="/tmp/wuphf-health-snapshot-health.$$.json"
HEALTH_CODE="$(curl -sS --max-time 5 -o "$HEALTH_BODY" -w '%{http_code}' "$BROKER_URL/health" 2>/dev/null || printf '000')"
printf 'broker_health_http=%s\n' "$HEALTH_CODE"
if [[ "$HEALTH_CODE" == "200" ]]; then
  python3 -m json.tool "$HEALTH_BODY" 2>/dev/null || cat "$HEALTH_BODY" | redact
  status="$(json_value "$HEALTH_BODY" status)"
  provider="$(json_value "$HEALTH_BODY" provider)"
  provider_model="$(json_value "$HEALTH_BODY" provider_model)"
  focus_mode="$(json_value "$HEALTH_BODY" focus_mode)"
  memory_backend="$(json_value "$HEALTH_BODY" memory_backend_active)"
  nex_connected="$(json_value "$HEALTH_BODY" nex_connected)"
  printf 'summary status=%s provider=%s model=%s focus_mode=%s memory_backend=%s nex_connected=%s\n' "$status" "$provider" "$provider_model" "$focus_mode" "$memory_backend" "$nex_connected"
  [[ "$status" == "ok" ]] && add_pass 'WUPHF /health status ok' || add_fail "WUPHF /health status not ok: $status"
else
  add_fail "WUPHF /health returned HTTP $HEALTH_CODE"
  cat "$HEALTH_BODY" 2>/dev/null | redact || true
fi
rm -f "$HEALTH_BODY"

WEB_CODE="$(curl -sS --max-time 5 -o /tmp/wuphf-health-snapshot-web.$$ -w '%{http_code}' "$WEB_URL/" 2>/dev/null || printf '000')"
printf 'local_web_http=%s url=%s/\n' "$WEB_CODE" "$WEB_URL"
[[ "$WEB_CODE" =~ ^(200|301|302)$ ]] && add_pass 'Local WUPHF web route responds' || add_warn "Local WUPHF web route returned HTTP $WEB_CODE"
rm -f /tmp/wuphf-health-snapshot-web.$$

PUBLIC_CODE="$(curl -k -sS --max-time 8 -o /tmp/wuphf-health-snapshot-public.$$ -w '%{http_code}' "$PUBLIC_OFFICE_URL/" 2>/dev/null || printf '000')"
printf 'public_office_http=%s url=%s/\n' "$PUBLIC_CODE" "$PUBLIC_OFFICE_URL"
[[ "$PUBLIC_CODE" =~ ^(200|301|302)$ ]] && add_pass 'Public office route responds' || add_warn "Public office route returned HTTP $PUBLIC_CODE"
rm -f /tmp/wuphf-health-snapshot-public.$$

section '4. Git/runtime'
if [[ -d "$WUPHF_DIR/.git" ]]; then
  (
    cd "$WUPHF_DIR" || exit 0
    printf 'repo=%s\n' "$WUPHF_DIR"
    printf 'branch=%s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    printf 'commit=%s\n' "$(git rev-parse HEAD 2>/dev/null || true)"
    printf 'commit_subject=%s\n' "$(git log -1 --pretty=%s 2>/dev/null || true)"
    tracked_dirty="$(git status --porcelain 2>/dev/null | grep -Ev '^\?\?' | wc -l | tr -d ' ')"
    untracked="$(git status --porcelain 2>/dev/null | grep -E '^\?\?' | wc -l | tr -d ' ')"
    printf 'tracked_dirty_count=%s untracked_count=%s\n' "$tracked_dirty" "$untracked"
    git status --short 2>/dev/null | sed -n '1,40p'
    if [[ "$tracked_dirty" != "0" ]]; then exit 2; elif [[ "$untracked" != "0" ]]; then exit 3; fi
  )
  case $? in
    0) add_pass 'WUPHF git tree clean' ;;
    2) add_warn 'WUPHF has tracked dirty changes' ;;
    3) add_warn 'WUPHF has untracked files' ;;
  esac
else
  add_fail "$WUPHF_DIR is not a git repo"
fi
file_stat_line 'binary' "$WUPHF_DIR/wuphf"
file_stat_line 'env_file' '/etc/wuphf/wuphf.env'
for c in \
  '/home/olly/.wuphf-spaces/main/.wuphf/company.json' \
  '/home/olly/.wuphf-spaces/main/.wuphf/team/company.json' \
  "$WUPHF_DIR/.wuphf/company.json" \
  "$WUPHF_DIR/.wuphf/team/company.json"; do
  [[ -e "$c" ]] && file_stat_line 'company_json' "$c"
done

section '5. Broker state'
STATE_PATH=''
for p in \
  '/home/olly/.wuphf-spaces/main/.wuphf/team/broker-state.json' \
  '/home/olly/.wuphf-spaces/main/.wuphf/broker-state.json' \
  '/home/olly/.wuphf/team/broker-state.json' \
  "$WUPHF_DIR/.wuphf/team/broker-state.json"; do
  if [[ -f "$p" ]]; then STATE_PATH="$p"; break; fi
done
if [[ -z "$STATE_PATH" ]]; then
  printf 'broker_state_path=missing\n'
  add_fail 'Broker state file not found'
else
  file_stat_line 'broker_state' "$STATE_PATH"
  STATE_SUMMARY="$(python3 - "$STATE_PATH" "$NOW_EPOCH" <<'PY'
import json, sys, time, re
from datetime import datetime, timezone
path=sys.argv[1]; now=int(sys.argv[2])
try:
    data=json.load(open(path))
except Exception as e:
    print(f'parse_error={e}')
    sys.exit(2)

def get_list(*names):
    for n in names:
        v=data.get(n)
        if isinstance(v, list): return v
    return []

def ts(v):
    if not v: return 0
    if isinstance(v, (int,float)): return int(v/1000 if v>100000000000 else v)
    if isinstance(v, str):
        s=v.replace('Z','+00:00')
        try: return int(datetime.fromisoformat(s).timestamp())
        except Exception: return 0
    return 0

def tid(x): return x.get('id') or x.get('task_id') or x.get('uid') or '?'
def title(x): return (x.get('title') or x.get('name') or x.get('summary') or '')[:120]
def owner(x): return x.get('owner') or x.get('assignee') or x.get('agent') or ''
def status(x): return x.get('status') or x.get('pipeline_stage') or x.get('lifecycle_state') or 'unknown'

members=get_list('members','office_members')
channels=get_list('channels')
messages=get_list('messages')
tasks=get_list('tasks')
requests=get_list('requests')
print(f'member_count={len(members)}')
print(f'channel_count={len(channels)}')
print(f'message_count={len(messages)}')
print(f'task_count={len(tasks)}')
print(f'request_count={len(requests)}')
counts={}
for t in tasks: counts[status(t)]=counts.get(status(t),0)+1
print('task_counts_by_status=' + ','.join(f'{k}:{v}' for k,v in sorted(counts.items())) )
active=[t for t in tasks if status(t).lower() not in ('done','complete','completed','cancelled','canceled','rejected')]
review=[t for t in tasks if 'review' in status(t).lower()]
print(f'active_task_count={len(active)}')
for t in active[:20]: print(f'active_task id={tid(t)} owner={owner(t)} status={status(t)} title={title(t)}')
print(f'pending_review_task_count={len(review)}')
for t in review[:20]: print(f'pending_review id={tid(t)} owner={owner(t)} status={status(t)} title={title(t)}')
open_block=[]; stale=[]
for r in requests:
    answered=bool(r.get('answered_at') or r.get('answeredAt') or r.get('answer'))
    blocking=bool(r.get('blocking'))
    if blocking and not answered:
        open_block.append(r)
        created=ts(r.get('created_at') or r.get('createdAt') or r.get('timestamp'))
        if created and now-created > 6*3600: stale.append(r)
        elif not created: stale.append(r)
print(f'open_blocking_request_count={len(open_block)}')
for r in open_block[:20]: print(f'open_blocking_request id={r.get("id") or r.get("request_id") or "?"} created={r.get("created_at") or r.get("createdAt") or "unknown"} summary={(r.get("summary") or r.get("title") or r.get("body") or "")[:120]}')
print(f'stale_blocking_request_count={len(stale)}')
if open_block: print(f'HEALTH_WARN open_blocking_requests={len(open_block)}')
if stale: print(f'HEALTH_WARN stale_blocking_requests={len(stale)}')
recent_words=re.compile(r'(self-heal|retry|skill[-_ ]?nudge)', re.I)
recent=[]
for t in tasks:
    blob=' '.join(str(t.get(k,'')) for k in ('id','title','name','summary','details','body'))
    if recent_words.search(blob): recent.append(t)
print(f'recent_self_heal_retry_skill_nudge_count={len(recent)}')
for t in recent[-20:]: print(f'recent_retry_task id={tid(t)} owner={owner(t)} status={status(t)} title={title(t)}')
# Canceled tasks with repeated mentions in recent messages.
canceled=[t for t in tasks if status(t).lower() in ('cancelled','canceled')]
recent_msgs=messages[-100:]
for t in canceled:
    ident=tid(t)
    hits=sum(1 for m in recent_msgs if ident and ident in str(m))
    holding=sum(1 for m in recent_msgs if ident in str(m) and 'Holding' in str(m))
    if hits or holding:
        print(f'canceled_recently_woken id={ident} hits_recent_messages={hits} holding_hits={holding} title={title(t)}')
        print(f'HEALTH_WARN canceled_task_recently_woken={ident}')
# Loop indicators independent of task id.
holding_recent=sum(1 for m in recent_msgs if re.search(r'\bHolding\.?\b', str(m)))
ack_loop_recent=sum(1 for m in recent_msgs if re.search(r'(staying silent|wake-cycle|stale loop|no live lane)', str(m), re.I))
print(f'recent_holding_message_count={holding_recent}')
print(f'recent_ack_loop_indicator_count={ack_loop_recent}')
if holding_recent >= 10: print(f'HEALTH_WARN recent_holding_messages={holding_recent}')
if ack_loop_recent >= 10: print(f'HEALTH_WARN recent_ack_loop_indicators={ack_loop_recent}')
PY
  )"
  py_status=$?
  printf '%s\n' "$STATE_SUMMARY" | grep -v '^HEALTH_WARN ' || true
  while IFS= read -r warn_line; do
    [[ -z "$warn_line" ]] && continue
    add_warn "Broker state warning: ${warn_line#HEALTH_WARN }"
  done < <(printf '%s\n' "$STATE_SUMMARY" | grep '^HEALTH_WARN ' || true)
  if [[ $py_status -ne 0 ]]; then add_fail 'Broker state could not be parsed'; fi
fi

section '6. Agent/runtime processes'
printf '# WUPHF process tree\n'
MAIN_PID="$(systemctl show "$WUPHF_SERVICE" -p MainPID --value 2>/dev/null || true)"
if [[ -n "$MAIN_PID" && "$MAIN_PID" != "0" ]]; then
  ps -o pid,ppid,etimes,stat,rss,comm,args --forest --ppid "$MAIN_PID" -p "$MAIN_PID" 2>/dev/null | redact | sed -E 's/(.{220}).*/\1.../' || true
else
  printf 'main_pid_missing\n'
fi
printf '\n# opencode children\n'
pgrep -af 'opencode run' 2>/dev/null | grep -v 'sensecore-health-snapshot' | redact | sed -E 's/(.{260}).*/\1.../' || true
printf '\n# Hermes child/process list\n'
pgrep -af 'hermes|sensecore-research|sensecore-sales|sensecore-content|sensecore-ops' 2>/dev/null | grep -v 'sensecore-health-snapshot' | grep -v 'avahi-daemon' | redact | sed -E 's/(.{260}).*/\1.../' || true
# Warn on very old task children. Long-running daemons are expected; opencode run children are not.
OLD_CHILDREN="$(ps -eo pid,ppid,etimes,comm,args 2>/dev/null | awk '$0 ~ /opencode run/ && $3 > 1800 {print}' | grep -v 'sensecore-health-snapshot' | redact || true)"
if [[ -n "$OLD_CHILDREN" ]]; then
  printf '\n# opencode task children older than 30m\n%s\n' "$OLD_CHILDREN" | sed -E 's/(.{260}).*/\1.../'
  add_warn 'One or more opencode task children older than 30 minutes found; review for long-running/zombie work'
fi

section '7. Logs'
printf '# Recent WUPHF warning/error patterns\n'
WUPHF_LOG="$(journalctl -u "$WUPHF_SERVICE" -n "$LOG_LINES" --no-pager 2>/dev/null | grep -Ei 'error|fail|panic|warn|unauthor|timeout|401|429|5[0-9][0-9]|holding|wake-cycle|skill_scanner|retry|self-heal|degrad|rate|limit' | tail -80 | redact || true)"
if [[ -n "$WUPHF_LOG" ]]; then printf '%s\n' "$WUPHF_LOG"; else printf 'none\n'; fi
skill_timeouts="$(printf '%s\n' "$WUPHF_LOG" | grep -ci 'skill_scanner.*timed out' || true)"
holding_logs="$(printf '%s\n' "$WUPHF_LOG" | grep -ci 'holding\|wake-cycle' || true)"
if (( skill_timeouts > 0 )); then add_warn "Recent WUPHF logs include $skill_timeouts skill scanner timeout pattern(s)"; fi
if (( holding_logs > 0 )); then add_warn "Recent WUPHF logs include $holding_logs holding/wake-cycle pattern(s)"; fi
printf '\n# Recent Hermes/router warning/error patterns\n'
if (( ${#HERMES_UNITS[@]} > 0 )); then
  for unit in "${HERMES_UNITS[@]}"; do
    printf 'unit=%s\n' "$unit"
    journalctl -u "$unit" -n "$LOG_LINES" --no-pager 2>/dev/null | grep -Ei 'error|fail|panic|warn|unauthor|timeout|401|429|5[0-9][0-9]|rate|limit' | tail -40 | redact || true
  done
else
  printf 'no systemd-backed Hermes/router unit found\n'
fi

section '8. Backups'
latest_file_under() {
  local label="$1"; shift
  local found
  found="$(find "$@" -maxdepth 4 -type f 2>/dev/null | xargs -r stat -c '%Y %n' 2>/dev/null | sort -nr | head -1 || true)"
  if [[ -z "$found" ]]; then
    printf '%s=missing\n' "$label"
    return 1
  fi
  local epoch path
  epoch="${found%% *}"; path="${found#* }"
  printf '%s=%s | mtime=%s | age=%s\n' "$label" "$path" "$(date -d "@$epoch" '+%F %T %Z' 2>/dev/null || printf unknown)" "$(age_human "$epoch")"
  if (( NOW_EPOCH - epoch > WARN_BACKUP_HOURS*3600 )); then return 2; fi
  return 0
}
latest_file_under latest_wuphf_backup /home/olly/wuphf-backups /opt/wuphf-broken-backup-20260702 2>/dev/null
case $? in 0) add_pass 'Recent WUPHF backup found';; 1) add_warn 'No WUPHF backup found';; 2) add_warn "Latest WUPHF backup older than ${WARN_BACKUP_HOURS}h";; esac
latest_file_under latest_env_backup /etc/wuphf /home/olly/wuphf-backups 2>/dev/null
case $? in 0) add_pass 'Recent env backup found';; 1) add_warn 'No env backup found';; 2) add_warn "Latest env backup older than ${WARN_BACKUP_HOURS}h";; esac
latest_file_under latest_broker_state_backup /home/olly/.wuphf-spaces /home/olly/wuphf-backups 2>/dev/null
case $? in 0) add_pass 'Recent broker-state backup found';; 1) add_warn 'No broker-state backup found';; 2) add_warn "Latest broker-state backup older than ${WARN_BACKUP_HOURS}h";; esac

section '9. Verdict'
if (( ${#FAIL_REASONS[@]} > 0 )); then
  VERDICT='FAIL'
elif (( ${#WARN_REASONS[@]} > 0 )); then
  VERDICT='WARN'
else
  VERDICT='PASS'
fi
printf 'VERDICT=%s\n' "$VERDICT"
printf '\nPASS reasons:\n'
if (( ${#PASS_REASONS[@]} )); then printf -- '- %s\n' "${PASS_REASONS[@]}"; else printf -- '- none\n'; fi
printf '\nWARN reasons:\n'
if (( ${#WARN_REASONS[@]} )); then printf -- '- %s\n' "${WARN_REASONS[@]}"; else printf -- '- none\n'; fi
printf '\nFAIL reasons:\n'
if (( ${#FAIL_REASONS[@]} )); then printf -- '- %s\n' "${FAIL_REASONS[@]}"; else printf -- '- none\n'; fi

printf '\nRecommended next action:\n'
if (( ${#FAIL_REASONS[@]} > 0 )); then
  printf 'Stop hardening changes and fix FAIL items first. Do not run agent tasks until the baseline is healthy.\n'
elif (( ${#WARN_REASONS[@]} > 0 )); then
  printf 'Proceed only with read-only review of WARN items; clear blockers/loops/backups before wiring more agents.\n'
else
  printf 'Baseline is healthy. Safe to run the next approved hardening step.\n'
fi

case "$VERDICT" in
  PASS) exit 0 ;;
  WARN) exit 1 ;;
  FAIL) exit 2 ;;
esac
