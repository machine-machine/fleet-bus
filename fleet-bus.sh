#!/usr/bin/env bash
# fleet-bus.sh — M2O Fleet Coordination CLI
# High-level wrapper over SpacetimeDB HTTP API
#
# Usage:
#   fleet-bus.sh heartbeat                        # announce this agent
#   fleet-bus.sh status                           # fleet snapshot
#   fleet-bus.sh claim <task_type>                # pull next pending task
#   fleet-bus.sh complete <task_id> [--fail] [--result <json>]
#   fleet-bus.sh task-add <type> <payload_json>   # add task to queue
#   fleet-bus.sh broadcast "<msg>"               # message all agents
#   fleet-bus.sh dm <agent_id> "<msg>"           # direct message
#   fleet-bus.sh watch                           # stream events (SSE)
#   fleet-bus.sh events [--limit 20]             # recent events

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
FLEET_BUS_URL="${FLEET_BUS_URL:-http://spacetimedb.machinemachine.ai}"
FLEET_MODULE="${FLEET_MODULE:-fleet-bus}"
AGENT_ID="${AGENT_ID:-m2}"
AGENT_NAME="${AGENT_NAME:-m2}"
AGENT_PRESET="${AGENT_PRESET:-orchestrator}"
AGENT_HOST="${AGENT_HOST:-$(hostname -f 2>/dev/null || hostname)}"

# SpacetimeDB HTTP API base
STDB_API="$FLEET_BUS_URL/v1"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $*${RESET}" >&2; }
err()  { echo -e "${RED}❌ $*${RESET}" >&2; }
info() { echo -e "${CYAN}ℹ️  $*${RESET}"; }

# ── API helpers ───────────────────────────────────────────────────────────────
stdb_call() {
  # POST reducer call
  local reducer="$1"
  local args_json="$2"
  curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    "$STDB_API/database/$FLEET_MODULE/call/$reducer" \
    -d "$args_json" 2>/dev/null
}

stdb_query() {
  # SQL query
  local sql="$1"
  curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    "$STDB_API/database/$FLEET_MODULE/sql" \
    -d "{\"query\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$sql")}" 2>/dev/null
}

now_ms() {
  python3 -c "import time; print(int(time.time() * 1000))"
}

uuid4() {
  python3 -c "import uuid; print(str(uuid.uuid4()))"
}

health_json() {
  python3 -c "
import json, psutil, os, subprocess
health = {
  'cpu_pct': psutil.cpu_percent(interval=0.5),
  'mem_pct': psutil.virtual_memory().percent,
  'gateway_ok': False,
  'session_count': 0,
}
# Check openclaw gateway
try:
  r = subprocess.run(['curl','-sf','http://localhost:18789/health'], capture_output=True, timeout=3)
  health['gateway_ok'] = r.returncode == 0
except: pass
print(json.dumps(health))
" 2>/dev/null || echo '{"error":"psutil_missing"}'
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_heartbeat() {
  local h; h=$(health_json)
  local session_key; session_key=""

  local args; args=$(python3 -c "
import json, os
print(json.dumps({
  'agentId': '$AGENT_ID',
  'displayName': '$AGENT_NAME',
  'preset': '$AGENT_PRESET',
  'host': '$AGENT_HOST',
  'healthJson': $h,
  'sessionKey': None
}))
")

  local result; result=$(stdb_call "agentHeartbeat" "$args" 2>&1)
  if [[ $? -eq 0 ]]; then
    ok "Heartbeat sent: $AGENT_ID @ $(date -u +%H:%M:%SZ)"
  else
    err "Heartbeat failed: $result"
    return 1
  fi
}

cmd_status() {
  echo ""
  echo "🛸 Fleet Status"
  echo "──────────────────────────────────────────────────────"

  local agents; agents=$(stdb_query "SELECT * FROM agents ORDER BY lastSeen DESC" 2>/dev/null)
  if [[ -z "$agents" ]]; then
    warn "Cannot reach SpacetimeDB at $STDB_API"
    echo "  URL: $FLEET_BUS_URL"
    echo "  Try: curl $STDB_API/health"
    return 1
  fi

  echo "$agents" | python3 -c "
import json, sys, datetime
try:
  rows = json.load(sys.stdin)
  if not rows:
    print('  (no agents registered)')
  else:
    for r in rows:
      status = r.get('status','?')
      icon = {'alive':'🟢','degraded':'🟡','dead':'🔴'}.get(status,'⚪')
      last_ms = r.get('lastSeen', 0)
      last = datetime.datetime.utcfromtimestamp(last_ms/1000).strftime('%H:%M:%S') if last_ms else '?'
      task = r.get('currentTask','') or ''
      print(f\"  {icon} {r.get('id','?'):<12} {status:<10} last:{last}  {r.get('preset','?')}\")
      if task: print(f\"       task: {task}\")
except Exception as e:
  print(f'  Parse error: {e}')
  print(sys.stdin.read()[:500])
" 2>/dev/null || echo "  (parse error)"

  echo ""
  echo "📋 Pending Tasks"
  local tasks; tasks=$(stdb_query "SELECT * FROM tasks WHERE state='pending' OR state='claimed' ORDER BY createdAt DESC LIMIT 10" 2>/dev/null)
  echo "$tasks" | python3 -c "
import json, sys
try:
  rows = json.load(sys.stdin)
  if not rows:
    print('  (no active tasks)')
  else:
    for r in rows:
      state=r.get('state','?')
      icon={'pending':'⏳','claimed':'🔄','running':'⚡'}.get(state,'❓')
      assigned=r.get('assignedTo','') or 'unassigned'
      print(f\"  {icon} [{r.get('taskType','?')}] {r.get('id','?')[:16]}  {state} → {assigned}\")
except: print('  (none)')
" 2>/dev/null

  echo ""
}

cmd_claim() {
  local task_type="${1:-}"
  if [[ -z "$task_type" ]]; then
    err "Usage: fleet-bus.sh claim <task_type>"
    return 1
  fi

  # Find next pending task of this type
  local task_row; task_row=$(stdb_query "SELECT id FROM tasks WHERE state='pending' AND taskType='$task_type' ORDER BY createdAt ASC LIMIT 1" 2>/dev/null)
  local task_id; task_id=$(echo "$task_row" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
print(rows[0]['id'] if rows else '')
" 2>/dev/null)

  if [[ -z "$task_id" ]]; then
    info "No pending tasks of type: $task_type"
    return 0
  fi

  local args; args=$(python3 -c "
import json
print(json.dumps({'agentId': '$AGENT_ID', 'taskId': '$task_id'}))
")
  stdb_call "claimTask" "$args" > /dev/null
  ok "Claimed task: $task_id (type: $task_type)"
  echo "$task_id"
}

cmd_complete() {
  local task_id="${1:-}"
  local success=true
  local result="{}"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fail)         success=false; shift ;;
      --result)       result="$2"; shift 2 ;;
      *)              shift ;;
    esac
  done

  if [[ -z "$task_id" ]]; then
    err "Usage: fleet-bus.sh complete <task_id> [--fail] [--result <json>]"
    return 1
  fi

  local args; args=$(python3 -c "
import json
print(json.dumps({
  'agentId': '$AGENT_ID',
  'taskId': '$task_id',
  'success': $success,
  'result': '$result'
}))
")
  stdb_call "completeTask" "$args" > /dev/null
  ok "Task ${success:+done}${success:-failed}: $task_id"
}

cmd_task_add() {
  local task_type="${1:-}"
  local payload="${2:-'{}'}"
  if [[ -z "$task_type" ]]; then
    err "Usage: fleet-bus.sh task-add <type> [payload_json]"
    return 1
  fi

  local task_id; task_id=$(uuid4)
  local args; args=$(python3 -c "
import json
print(json.dumps({
  'id': '$task_id',
  'taskType': '$task_type',
  'payload': '''$payload''',
  'createdBy': '$AGENT_ID'
}))
")
  stdb_call "createTask" "$args" > /dev/null
  ok "Task created: $task_id (type: $task_type)"
  echo "$task_id"
}

cmd_broadcast() {
  local msg="${1:-}"
  if [[ -z "$msg" ]]; then err "Usage: fleet-bus.sh broadcast \"<msg>\""; return 1; fi
  local args; args=$(python3 -c "import json; print(json.dumps({'fromAgent':'$AGENT_ID','toAgent':None,'content':sys.argv[1]}))" "$msg")
  stdb_call "sendMessage" "$args" > /dev/null
  ok "Broadcast sent"
}

cmd_dm() {
  local to="${1:-}" msg="${2:-}"
  if [[ -z "$to" || -z "$msg" ]]; then err "Usage: fleet-bus.sh dm <agent_id> \"<msg>\""; return 1; fi
  local args; args=$(python3 -c "import json,sys; print(json.dumps({'fromAgent':'$AGENT_ID','toAgent':sys.argv[1],'content':sys.argv[2]}))" "$to" "$msg")
  stdb_call "sendMessage" "$args" > /dev/null
  ok "Message sent to $to"
}

cmd_events() {
  local limit=20
  [[ "${1:-}" == "--limit" ]] && { limit="$2"; shift 2; }
  local events; events=$(stdb_query "SELECT * FROM events ORDER BY ts DESC LIMIT $limit" 2>/dev/null)
  echo "$events" | python3 -c "
import json, sys, datetime
try:
  rows=json.load(sys.stdin)
  for r in reversed(rows):
    ts=datetime.datetime.utcfromtimestamp(r.get('ts',0)/1000).strftime('%H:%M:%S')
    agent=r.get('agentId','fleet') or 'fleet'
    print(f\"{ts}  {agent:<12}  {r.get('eventType','?'):<20}  {str(r.get('data',''))[:60]}\")
except: print('(no events or parse error)')
"
}

cmd_watch() {
  info "Watching events (Ctrl+C to stop)..."
  # SSE stream from SpacetimeDB
  curl -sN "$STDB_API/database/$FLEET_MODULE/subscribe" \
    -H "Accept: text/event-stream" 2>/dev/null || {
    warn "SSE not available — polling every 5s"
    local last_id=0
    while true; do
      local ev; ev=$(stdb_query "SELECT * FROM events WHERE id > $last_id ORDER BY id ASC LIMIT 10" 2>/dev/null)
      local new_id; new_id=$(echo "$ev" | python3 -c "
import json,sys
try:
  rows=json.load(sys.stdin)
  for r in rows:
    print(r.get('id',0), r.get('agentId','?'), r.get('eventType','?'), str(r.get('data',''))[:60])
  if rows: print('__last__', rows[-1].get('id',0))
except: pass
" 2>/dev/null)
      if echo "$new_id" | grep -q "__last__"; then
        last_id=$(echo "$new_id" | grep "__last__" | awk '{print $2}')
        echo "$new_id" | grep -v "__last__"
      fi
      sleep 5
    done
  }
}

# ── Cron heartbeat helper (call from cron every 60s) ────────────────────────
cmd_cron_heartbeat() {
  # Silent except on failure
  cmd_heartbeat 2>/dev/null || warn "Heartbeat failed at $(date -u)"
}

# ── Main ─────────────────────────────────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  heartbeat|hb)     cmd_heartbeat "$@" ;;
  status|st)        cmd_status "$@" ;;
  claim)            cmd_claim "$@" ;;
  complete|done)    cmd_complete "$@" ;;
  task-add|add)     cmd_task_add "$@" ;;
  broadcast|bc)     cmd_broadcast "$@" ;;
  dm)               cmd_dm "$@" ;;
  events)           cmd_events "$@" ;;
  watch)            cmd_watch "$@" ;;
  cron-heartbeat)   cmd_cron_heartbeat "$@" ;;
  *)
    echo "Usage: fleet-bus.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  heartbeat            Announce this agent to the fleet"
    echo "  status               Fleet snapshot (agents + tasks)"
    echo "  claim <type>         Claim next pending task of type"
    echo "  complete <id>        Mark task done (--fail, --result)"
    echo "  task-add <type>      Add task to queue"
    echo "  broadcast \"<msg>\"   Message all agents"
    echo "  dm <agent> \"<msg>\"  Direct message"
    echo "  events [--limit N]   Recent events"
    echo "  watch                Stream events live"
    echo ""
    echo "Config (env vars):"
    echo "  FLEET_BUS_URL        SpacetimeDB base URL (default: http://spacetimedb.machinemachine.ai)"
    echo "  AGENT_ID             This agent's ID (default: m2)"
    echo "  AGENT_PRESET         Role: orchestrator|researcher|builder|generalist"
    ;;
esac
