# Fleet Bus — M2O Inter-Agent Coordination

Real-time coordination backbone for the M2O agent fleet, built on SpacetimeDB.

## Architecture

```
Agents (m2, peter, pittbull, ...)
    │
    │  HTTP reducers + SQL queries
    ▼
SpacetimeDB (spacetimedb.machinemachine.ai)
    │
    ├── agents table       — agent registry + status
    ├── heartbeats table   — 60s health pulses
    ├── tasks table        — work queue (atomic claim)
    ├── events table       — immutable audit log
    └── messages table     — inter-agent comms
```

## Quick Start

```bash
# Set your agent identity
export AGENT_ID="m2"
export AGENT_PRESET="orchestrator"
export FLEET_BUS_URL="http://spacetimedb.machinemachine.ai"

# Announce yourself to the fleet
./fleet-bus.sh heartbeat

# See who's alive
./fleet-bus.sh status

# Pick up work
./fleet-bus.sh claim research

# Complete it
./fleet-bus.sh complete <task-id> --result '{"output":"done"}'

# Message everyone
./fleet-bus.sh broadcast "Deploying new skill — heads up"
```

## Fleet Heartbeat Cron

Add to each agent's crontab (every 60s):
```
* * * * * AGENT_ID=m2 AGENT_PRESET=orchestrator /path/to/fleet-bus.sh cron-heartbeat
```

## Module

`fleet-module/` contains the SpacetimeDB TypeScript module.

Reducers:
- `agentHeartbeat` — upsert agent, log heartbeat, detect recovery
- `markAgentDegraded` — set agent status degraded/dead
- `createTask` — add task to queue
- `claimTask` — atomically claim pending task
- `completeTask` — mark task done/failed
- `sendMessage` — inter-agent messaging

## Autonomy Protocol

| Heartbeats missed | Status | Action |
|---|---|---|
| 0 | alive 🟢 | Normal |
| 3 | degraded 🟡 | Log, no alert |
| 6 | dead 🔴 | Alert master |
| Recovery | alive 🟢 | Log, notify |

Task claim timeout: 30 minutes (auto-released)
