/**
 * M2O Fleet Bus — SpacetimeDB Module
 * Inter-agent coordination: agents, heartbeats, tasks, events, messages
 */

import { schema, table, t } from 'spacetimedb/server';

export const spacetimedb = schema(
  // ── Agent registry ──────────────────────────────────────────────────────────
  table(
    {
      name: 'agents',
      primaryKey: 'id',
      public: true,
    },
    {
      id: t.string(),           // e.g. "m2", "peter", "pittbull"
      displayName: t.string(),
      status: t.string(),       // alive | degraded | dead | unknown
      preset: t.string(),       // orchestrator | researcher | builder | generalist | ephemeral
      host: t.string(),
      lastSeen: t.u64(),        // unix timestamp ms
      currentTask: t.option(t.string()),
      sessionKey: t.option(t.string()),
    }
  ),

  // ── Heartbeat log ────────────────────────────────────────────────────────────
  table(
    {
      name: 'heartbeats',
      primaryKey: 'id',
      public: true,
    },
    {
      id: t.u64(),              // auto-increment via counter
      agentId: t.string(),
      ts: t.u64(),              // unix timestamp ms
      healthJson: t.string(),   // JSON: cpu, mem, gateway_ok, active_task, etc.
      sessionKey: t.option(t.string()),
    }
  ),

  // ── Task queue ───────────────────────────────────────────────────────────────
  table(
    {
      name: 'tasks',
      primaryKey: 'id',
      public: true,
    },
    {
      id: t.string(),
      taskType: t.string(),     // research | build | spawn | monitor | etc.
      payload: t.string(),      // JSON
      state: t.string(),        // pending | claimed | running | done | failed
      assignedTo: t.option(t.string()),
      createdBy: t.string(),
      createdAt: t.u64(),
      claimedAt: t.option(t.u64()),
      completedAt: t.option(t.u64()),
      result: t.option(t.string()),
      timeoutAt: t.option(t.u64()),  // claim expires at (ms)
    }
  ),

  // ── Event log (immutable audit trail) ────────────────────────────────────────
  table(
    {
      name: 'events',
      primaryKey: 'id',
      public: true,
    },
    {
      id: t.u64(),
      ts: t.u64(),
      agentId: t.option(t.string()),
      eventType: t.string(),    // heartbeat | task_claimed | task_done | alert | spawn | etc.
      data: t.string(),         // JSON payload
    }
  ),

  // ── Messages (inter-agent) ────────────────────────────────────────────────────
  table(
    {
      name: 'messages',
      primaryKey: 'id',
      public: true,
    },
    {
      id: t.u64(),
      fromAgent: t.string(),
      toAgent: t.option(t.string()),   // NULL = broadcast
      content: t.string(),
      ts: t.u64(),
      readAt: t.option(t.u64()),
    }
  ),

  // ── Counters (monotonic IDs) ──────────────────────────────────────────────────
  table(
    {
      name: 'counters',
      primaryKey: 'name',
      public: false,
    },
    {
      name: t.string(),
      value: t.u64(),
    }
  )
);

// ── Helpers ──────────────────────────────────────────────────────────────────
function nextId(ctx: any, counterName: string): bigint {
  let counter = ctx.db.counters.name.find(counterName);
  const next = counter ? counter.value + 1n : 1n;
  if (counter) {
    ctx.db.counters.name.updateByName(counterName, { name: counterName, value: next });
  } else {
    ctx.db.counters.insert({ name: counterName, value: next });
  }
  return next;
}

function nowMs(): bigint {
  return BigInt(Date.now());
}

function emitEvent(ctx: any, agentId: string | null, eventType: string, data: object) {
  const id = nextId(ctx, 'events');
  ctx.db.events.insert({
    id,
    ts: nowMs(),
    agentId: agentId || undefined,
    eventType,
    data: JSON.stringify(data),
  });
}

// ── Init ─────────────────────────────────────────────────────────────────────
spacetimedb.init((ctx) => {
  // Initialize counter rows
  ctx.db.counters.insert({ name: 'heartbeats', value: 0n });
  ctx.db.counters.insert({ name: 'events', value: 0n });
  ctx.db.counters.insert({ name: 'messages', value: 0n });
  console.info('Fleet Bus initialized');
});

spacetimedb.clientConnected((_ctx) => {});
spacetimedb.clientDisconnected((_ctx) => {});

// ── Reducers ──────────────────────────────────────────────────────────────────

/**
 * agentHeartbeat — called by each agent every 60s
 * Upserts agent record, logs heartbeat, detects recovery
 */
spacetimedb.reducer(
  'agentHeartbeat',
  {
    agentId: t.string(),
    displayName: t.string(),
    preset: t.string(),
    host: t.string(),
    healthJson: t.string(),
    sessionKey: t.option(t.string()),
  },
  (ctx, { agentId, displayName, preset, host, healthJson, sessionKey }) => {
    const now = nowMs();
    const existing = ctx.db.agents.id.find(agentId);
    const wasDeadOrUnknown = existing && (existing.status === 'dead' || existing.status === 'unknown');

    // Upsert agent
    const agentRow = {
      id: agentId,
      displayName,
      status: 'alive',
      preset,
      host,
      lastSeen: now,
      currentTask: existing?.currentTask,
      sessionKey,
    };

    if (existing) {
      ctx.db.agents.id.updateById(agentId, agentRow);
    } else {
      ctx.db.agents.insert(agentRow);
    }

    // Log heartbeat
    const hbId = nextId(ctx, 'heartbeats');
    ctx.db.heartbeats.insert({ id: hbId, agentId, ts: now, healthJson, sessionKey });

    // Emit recovery event if agent was dead
    if (wasDeadOrUnknown) {
      emitEvent(ctx, agentId, 'agent_recovered', { previous_status: existing!.status });
      console.info(`Agent recovered: ${agentId}`);
    }
  }
);

/**
 * markAgentDegraded — called by monitor when heartbeats are missed
 */
spacetimedb.reducer(
  'markAgentDegraded',
  { agentId: t.string(), missedCount: t.u32(), newStatus: t.string() },
  (ctx, { agentId, missedCount, newStatus }) => {
    const existing = ctx.db.agents.id.find(agentId);
    if (!existing) return;
    if (existing.status === newStatus) return;

    ctx.db.agents.id.updateById(agentId, { ...existing, status: newStatus });
    emitEvent(ctx, agentId, 'agent_health_change', {
      from: existing.status,
      to: newStatus,
      missed_heartbeats: missedCount,
    });

    if (newStatus === 'dead') {
      console.warn(`ALERT: Agent ${agentId} is DEAD (missed ${missedCount} heartbeats)`);
    }
  }
);

/**
 * createTask — add a task to the queue
 */
spacetimedb.reducer(
  'createTask',
  {
    id: t.string(),
    taskType: t.string(),
    payload: t.string(),
    createdBy: t.string(),
  },
  (ctx, { id, taskType, payload, createdBy }) => {
    const now = nowMs();
    ctx.db.tasks.insert({
      id,
      taskType,
      payload,
      state: 'pending',
      assignedTo: undefined,
      createdBy,
      createdAt: now,
      claimedAt: undefined,
      completedAt: undefined,
      result: undefined,
      timeoutAt: undefined,
    });
    emitEvent(ctx, createdBy, 'task_created', { task_id: id, task_type: taskType });
  }
);

/**
 * claimTask — atomically claim a pending task of a given type
 */
spacetimedb.reducer(
  'claimTask',
  { agentId: t.string(), taskId: t.string() },
  (ctx, { agentId, taskId }) => {
    const task = ctx.db.tasks.id.find(taskId);
    if (!task || task.state !== 'pending') {
      console.warn(`Task ${taskId} not claimable (state: ${task?.state})`);
      return;
    }

    const now = nowMs();
    const timeoutAt = now + BigInt(30 * 60 * 1000); // 30-min timeout

    ctx.db.tasks.id.updateById(taskId, {
      ...task,
      state: 'claimed',
      assignedTo: agentId,
      claimedAt: now,
      timeoutAt,
    });

    emitEvent(ctx, agentId, 'task_claimed', { task_id: taskId, task_type: task.taskType });
  }
);

/**
 * completeTask — mark task done or failed
 */
spacetimedb.reducer(
  'completeTask',
  { agentId: t.string(), taskId: t.string(), success: t.bool(), result: t.string() },
  (ctx, { agentId, taskId, success, result }) => {
    const task = ctx.db.tasks.id.find(taskId);
    if (!task) return;

    const now = nowMs();
    ctx.db.tasks.id.updateById(taskId, {
      ...task,
      state: success ? 'done' : 'failed',
      completedAt: now,
      result,
    });

    emitEvent(ctx, agentId, success ? 'task_done' : 'task_failed', {
      task_id: taskId,
      task_type: task.taskType,
      duration_ms: task.claimedAt ? Number(now - task.claimedAt) : null,
    });
  }
);

/**
 * sendMessage — inter-agent messaging
 */
spacetimedb.reducer(
  'sendMessage',
  { fromAgent: t.string(), toAgent: t.option(t.string()), content: t.string() },
  (ctx, { fromAgent, toAgent, content }) => {
    const id = nextId(ctx, 'messages');
    ctx.db.messages.insert({
      id,
      fromAgent,
      toAgent,
      content,
      ts: nowMs(),
      readAt: undefined,
    });
  }
);
