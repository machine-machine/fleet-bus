#!/usr/bin/env bash
# fleet-bus.sh — M2O Fleet Coordination CLI (Redis backend)
# Usage:
#   fleet-bus.sh heartbeat                        # announce this agent
#   fleet-bus.sh status                           # fleet snapshot
#   fleet-bus.sh claim <task_type>               # pull next pending task
#   fleet-bus.sh complete <task_id> [--fail]     # mark task done/failed
#   fleet-bus.sh task-add <type> [payload_json]  # add task to queue
#   fleet-bus.sh broadcast "<msg>"               # message all agents
#   fleet-bus.sh events [--limit 20]             # recent events
#   fleet-bus.sh watch                           # stream events live

set -uo pipefail

REDIS_HOST="${FLEET_REDIS_HOST:-fleet-redis}"
REDIS_PORT="${FLEET_REDIS_PORT:-6379}"
AGENT_ID="${AGENT_ID:-m2}"
AGENT_NAME="${AGENT_NAME:-m2}"
AGENT_PRESET="${AGENT_PRESET:-orchestrator}"
AGENT_HOST="${AGENT_HOST:-$(hostname -f 2>/dev/null || hostname)}"
HEARTBEAT_TTL=180   # seconds — miss 3 = dead

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $*${RESET}" >&2; }
err()  { echo -e "${RED}❌ $*${RESET}" >&2; }
info() { echo -e "${CYAN}ℹ️  $*${RESET}"; }

redis_py() {
  python3 -c "
import redis, sys, json, time, os

r = redis.Redis(host='$REDIS_HOST', port=$REDIS_PORT, decode_responses=True)
cmd = sys.argv[1]
args = sys.argv[2:]

if cmd == 'heartbeat':
    agent_id, preset, host, health = args[0], args[1], args[2], args[3]
    now = int(time.time())
    pipe = r.pipeline()
    pipe.hset(f'agent:{agent_id}', mapping={
        'id': agent_id, 'preset': preset, 'host': host,
        'lastSeen': now, 'health': health, 'status': 'alive'
    })
    pipe.expire(f'agent:{agent_id}', $HEARTBEAT_TTL)
    pipe.sadd('agents', agent_id)
    pipe.xadd('events', {'agent': agent_id, 'type': 'heartbeat', 'ts': now}, maxlen=1000)
    pipe.execute()
    print('ok')

elif cmd == 'status':
    agents = r.smembers('agents')
    result = []
    now = int(time.time())
    for aid in sorted(agents):
        data = r.hgetall(f'agent:{aid}')
        if not data:
            status = 'dead'
            last = '?'
        else:
            last_seen = int(data.get('lastSeen', 0))
            age = now - last_seen
            status = 'alive' if age < $HEARTBEAT_TTL else 'dead'
            last = f'{age}s ago'
        result.append({'id': aid, 'status': status, 'last': last, **data})
    print(json.dumps(result))

elif cmd == 'task_add':
    task_type, payload, created_by = args[0], args[1], args[2]
    task_id = f'{task_type}-{int(time.time())}'
    task = json.dumps({'id': task_id, 'type': task_type, 'payload': payload,
                       'state': 'pending', 'created_by': created_by, 'created_at': int(time.time())})
    r.lpush(f'tasks:{task_type}', task)
    r.xadd('events', {'type': 'task_created', 'task_id': task_id, 'agent': created_by}, maxlen=1000)
    print(task_id)

elif cmd == 'claim':
    task_type, agent_id = args[0], args[1]
    raw = r.rpop(f'tasks:{task_type}')
    if not raw:
        print('none')
    else:
        task = json.loads(raw)
        task['state'] = 'claimed'
        task['assigned_to'] = agent_id
        task['claimed_at'] = int(time.time())
        r.setex(f'task:{task[\"id\"]}', 1800, json.dumps(task))
        r.xadd('events', {'type': 'task_claimed', 'task_id': task['id'], 'agent': agent_id}, maxlen=1000)
        print(json.dumps(task))

elif cmd == 'complete':
    task_id, agent_id, success, result_data = args[0], args[1], args[2], args[3]
    raw = r.get(f'task:{task_id}')
    if raw:
        task = json.loads(raw)
        task['state'] = 'done' if success == 'true' else 'failed'
        task['completed_at'] = int(time.time())
        task['result'] = result_data
        r.setex(f'task:{task_id}', 3600, json.dumps(task))
    r.xadd('events', {'type': 'task_done' if success=='true' else 'task_failed',
                       'task_id': task_id, 'agent': agent_id}, maxlen=1000)
    print('ok')

elif cmd == 'broadcast':
    msg, from_agent = args[0], args[1]
    r.xadd('messages', {'from': from_agent, 'to': 'all', 'content': msg}, maxlen=500)
    print('ok')

elif cmd == 'events':
    limit = int(args[0]) if args else 20
    entries = r.xrevrange('events', count=limit)
    for eid, data in reversed(entries):
        ts = int(eid.split('-')[0]) // 1000
        import datetime
        t = datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M:%S')
        print(f\"{t}  {data.get('agent','fleet'):<12}  {data.get('type','?'):<20}  {str(data)[:60]}\")

elif cmd == 'watch':
    last_id = '\$'
    import datetime
    print('Watching events (Ctrl+C to stop)...')
    while True:
        entries = r.xread({'events': last_id}, block=5000, count=10)
        if entries:
            for stream, msgs in entries:
                for eid, data in msgs:
                    last_id = eid
                    ts = int(eid.split('-')[0]) // 1000
                    t = datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M:%S')
                    print(f\"{t}  {data.get('agent','?'):<12}  {data.get('type','?')}\")
" "$@"
}

cmd_heartbeat() {
  local h
  h=$(python3 -c "
import json, subprocess, time
h = {'ts': int(time.time())}
try:
    import psutil
    h['cpu'] = psutil.cpu_percent(interval=0.3)
    h['mem'] = psutil.virtual_memory().percent
except: pass
try:
    r = subprocess.run(['curl','-sf','http://localhost:18789/health'],
                       capture_output=True, timeout=2)
    h['gateway'] = r.returncode == 0
except: h['gateway'] = False
print(json.dumps(h))
" 2>/dev/null || echo '{}')

  redis_py heartbeat "$AGENT_ID" "$AGENT_PRESET" "$AGENT_HOST" "$h"
}

cmd_status() {
  echo ""
  echo "🛸 Fleet Status"
  echo "──────────────────────────────────────────────────────"
  redis_py status | python3 -c "
import json, sys
agents = json.load(sys.stdin)
if not agents:
    print('  (no agents registered)')
else:
    for a in agents:
        status = a.get('status','?')
        icon = {'alive':'🟢','dead':'🔴'}.get(status,'⚪')
        print(f\"  {icon} {a.get('id','?'):<14} {status:<8} {a.get('preset','?'):<14} seen: {a.get('last','?')}\")
" 2>/dev/null
  echo ""
}

CMD="${1:-status}"
shift || true

case "$CMD" in
  heartbeat|hb)     cmd_heartbeat ;;
  status|st)        cmd_status ;;
  claim)            redis_py claim "${1:-}" "$AGENT_ID" ;;
  complete|done)    redis_py complete "${1:-}" "$AGENT_ID" "${2:-true}" "${3:-{}}" ;;
  task-add|add)     redis_py task_add "${1:-}" "${2:-'{}'}" "$AGENT_ID" ;;
  broadcast|bc)     redis_py broadcast "${1:-}" "$AGENT_ID" ;;
  events)           redis_py events "${1:-20}" ;;
  watch)            redis_py watch ;;
  cron-heartbeat)   cmd_heartbeat > /dev/null 2>&1 || true ;;
  *)
    echo "Usage: fleet-bus.sh <heartbeat|status|claim|complete|task-add|broadcast|events|watch>"
    ;;
esac
