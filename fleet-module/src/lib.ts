/**
 * M2O Fleet Bus — SpacetimeDB Module v2
 * Inter-agent coordination: agents, heartbeats, tasks, events, messages
 */

import { schema, table, t } from 'spacetimedb/server';

// ── Table definitions ─────────────────────────────────────────────────────────

const agents = table(
  { name: 'agents', public: true },
  {
    id: t.string().primaryKey(),
    displayName: t.string(),
    status: t.string(),       // alive | degraded | dead | unknown
    preset: t.string(),       // orchestrator | researcher | builder | generalist | ephemeral
    host: t.string(),
    lastSeen: t.u64(),
    currentTask: t.option(t.string()),
    sessionKey: t.option(t.string()),
  }
);

const heartbeats = table(
  { name: 'heartbeats', public: true },
  {
    id: t.u64().primaryKey().autoInc(),
    agentId: t.string().index(),
    ts: t.u64(),
    healthJson: t.string(),
    sessionKey: t.option(t.string()),
  }
);

const tasks = table(
  { name: 'tasks', public: true },
  {
    id: t.string().primaryKey(),
    taskType: t.string(),
    payload: t.string(),
    state: t.string().index(),
    assignedTo: t.option(t.string()),
    createdBy: t.string(),
    createdAt: t.u64(),
    claimedAt: t.option(t.u64()),
    completedAt: t.option(t.u64()),
    result: t.option(t.string()),
    timeoutAt: t.option(t.u64()),
  }
);

const events = table(
  { name: 'events', public: true },
  {
    id: t.u64().primaryKey().autoInc(),
    ts: t.u64(),
    agentId: t.option(t.string()),
    eventType: t.string().index(),
    data: t.string(),
  }
);

const messages = table(
  { name: 'messages', public: true },
  {
    id: t.u64().primaryKey().autoInc(),
    fromAgent: t.string(),
    toAgent: t.option(t.string()),
    content: t.string(),
    ts: t.u64(),
    readAt: t.option(t.u64()),
  }
);

// ── Schema ────────────────────────────────────────────────────────────────────

const db = schema({ agents, heartbeats, tasks, events, messages });

export default db;

// ── Helpers ───────────────────────────────────────────────────────────────────

function nowMs(): bigint {
  return BigInt(Date.now());
}

function emitEvent(ctx: any, agentId: string | null, eventType: string, data: object) {
  ctx.db.events.insert({
    id: 0n,          // autoInc placeholder
    ts: nowMs(),
    agentId: agentId ?? undefined,
    eventType,
    data: JSON.stringify(data),
  });
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

export const init = db.init((ctx) => {
  console.info('Fleet Bus v2 initialized');
});

export const onConnect = db.clientConnected((_ctx) => {});
export const onDisconnect = db.clientDisconnected((_ctx) => {});

// ── Reducers ──────────────────────────────────────────────────────────────────

export const agentHeartbeat = db.reducer(
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
      ctx.db.agents.id.update(agentRow);
    } else {
      ctx.db.agents.insert(agentRow);
    }

    ctx.db.heartbeats.insert({ id: 0n, agentId, ts: now, healthJson, sessionKey });

    if (wasDeadOrUnknown) {
      emitEvent(ctx, agentId, 'agent_recovered', { previous_status: existing!.status });
    }
  }
);

export const markAgentDegraded = db.reducer(
  { agentId: t.string(), missedCount: t.u32(), newStatus: t.string() },
  (ctx, { agentId, missedCount, newStatus }) => {
    const existing = ctx.db.agents.id.find(agentId);
    if (!existing || existing.status === newStatus) return;

    ctx.db.agents.id.update({ ...existing, status: newStatus });
    emitEvent(ctx, agentId, 'agent_health_change', {
      from: existing.status,
      to: newStatus,
      missed_heartbeats: missedCount,
    });
  }
);

export const createTask = db.reducer(
  {
    id: t.string(),
    taskType: t.string(),
    payload: t.string(),
    createdBy: t.string(),
  },
  (ctx, { id, taskType, payload, createdBy }) => {
    const now = nowMs();
    ctx.db.tasks.insert({
      id, taskType, payload, state: 'pending',
      assignedTo: undefined, createdBy, createdAt: now,
      claimedAt: undefined, completedAt: undefined,
      result: undefined, timeoutAt: undefined,
    });
    emitEvent(ctx, createdBy, 'task_created', { task_id: id, task_type: taskType });
  }
);

export const claimTask = db.reducer(
  { agentId: t.string(), taskId: t.string() },
  (ctx, { agentId, taskId }) => {
    const task = ctx.db.tasks.id.find(taskId);
    if (!task || task.state !== 'pending') return;

    const now = nowMs();
    const timeoutAt = now + BigInt(30 * 60 * 1000);

    ctx.db.tasks.id.update({ ...task, state: 'claimed', assignedTo: agentId, claimedAt: now, timeoutAt });
    emitEvent(ctx, agentId, 'task_claimed', { task_id: taskId, task_type: task.taskType });
  }
);

export const completeTask = db.reducer(
  { agentId: t.string(), taskId: t.string(), success: t.bool(), result: t.string() },
  (ctx, { agentId, taskId, success, result }) => {
    const task = ctx.db.tasks.id.find(taskId);
    if (!task) return;

    const now = nowMs();
    ctx.db.tasks.id.update({ ...task, state: success ? 'done' : 'failed', completedAt: now, result });
    emitEvent(ctx, agentId, success ? 'task_done' : 'task_failed', {
      task_id: taskId,
      task_type: task.taskType,
      duration_ms: task.claimedAt ? Number(now - task.claimedAt) : null,
    });
  }
);

export const sendMessage = db.reducer(
  { fromAgent: t.string(), toAgent: t.option(t.string()), content: t.string() },
  (ctx, { fromAgent, toAgent, content }) => {
    ctx.db.messages.insert({ id: 0n, fromAgent, toAgent, content, ts: nowMs(), readAt: undefined });
  }
);
