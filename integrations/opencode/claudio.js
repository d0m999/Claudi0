// Claudio OpenCode server plugin. Source contract: OpenCode 1.18.34.
// Installation values are prepended by the adapter. No message/tool body is retained or sent.
import { spawn } from "node:child_process";

export const id = "claudio.opencode.v1";
const MAX_SESSIONS = 128;
const MAX_IDENTITIES = 256;
const RETENTION = 30 * 60 * 1000;
const identifier = (v) => typeof v === "string" && v.length > 0 &&
  Buffer.byteLength(v) <= 256 && !/[\s\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u.test(v);
const finiteTime = (v) => typeof v === "number" && Number.isFinite(v) && v > 0;
const terminalErrors = new Set([
  "APIError", "ProviderAuthError", "UnknownError", "MessageOutputLengthError", "StructuredOutputError",
]);

// Public plugin interface is also the regression-test seam. JSON plugin options cannot supply
// functions; the test harness supplies a local dispatcher and clock instead of spawning audio.
export async function server(context, options = {}) {
  const registryKey = Symbol.for("claudio.opencode.instances.v1");
  const registry = globalThis[registryKey] ??= new Set();
  const instanceKey = JSON.stringify([context.directory, installation.installation_id]);
  if (registry.has(instanceKey) || registry.size >= MAX_SESSIONS) return {};
  registry.add(instanceKey);
  const now = typeof options.clock === "function" ? options.clock : Date.now;
  const bootTime = now();
  const sessions = new Map();
  const requests = new Map();
  const completed = new Map();
  const pending = [];
  const children = new Set();
  let draining = false;
  let disposed = false;

  function prune() {
    const cutoff = now() - RETENTION;
    for (const [key, value] of sessions) if (value.touched < cutoff) sessions.delete(key);
    for (const ledger of [requests, completed]) {
      for (const [key, time] of ledger) if (time < cutoff) ledger.delete(key);
    }
  }

  function consume(ledger, key) {
    prune();
    if (ledger.has(key) || ledger.size >= MAX_IDENTITIES) return false;
    ledger.set(key, now());
    return true;
  }

  function emit(event, state, fields = {}) {
    if (disposed || !installation.enabled_events.includes(event)) return;
    const payload = {
      bridge_schema: 1,
      hook_event_name: event,
      session_id: state.id,
      session_kind: state.parentID ? "child" : "main",
      ...fields,
    };
    if (state.parentID) payload.parent_session_id = state.parentID;
    // Directory is an ephemeral source label only. The helper uses the Default Group.
    if (typeof context.directory === "string" && context.directory.startsWith("/") &&
        Buffer.byteLength(context.directory) <= 4096 &&
        !/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u.test(context.directory)) {
      payload.cwd = context.directory;
    }
    if (typeof options.dispatch === "function") {
      try { options.dispatch(event, payload); } catch { /* best effort */ }
      return;
    }
    if (children.size >= 8) return;
    const bytes = JSON.stringify(payload);
    if (Buffer.byteLength(bytes) > 8192) return;
    try {
      const child = spawn(installation.helper_path,
        ["hook", "opencode", event, "--installation-id", installation.installation_id],
        { stdio: ["pipe", "ignore", "ignore"] });
      children.add(child);
      const timer = setTimeout(() => { child.kill("SIGKILL"); }, 1500);
      timer.unref?.();
      const finish = () => { clearTimeout(timer); children.delete(child); };
      child.once("error", finish);
      child.once("close", finish);
      child.stdin.on("error", () => {});
      child.stdin.end(bytes);
      child.unref();
    } catch { /* no host output, approval or retry */ }
  }

  function remember(info) {
    if (!info || !identifier(info.id) ||
        (info.parentID !== undefined && !identifier(info.parentID))) return;
    prune();
    const previous = sessions.get(info.id);
    if (previous) {
      // Contradictory parent evidence cannot change a main turn into a child or vice versa.
      if (previous.parentID !== info.parentID) sessions.delete(info.id);
      return;
    }
    if (sessions.size >= MAX_SESSIONS) return;
    sessions.set(info.id, {
      id: info.id, parentID: info.parentID, touched: now(), candidates: new Map(), active: undefined,
    });
  }

  async function session(sessionID) {
    if (!identifier(sessionID)) return;
    prune();
    if (sessions.has(sessionID)) return sessions.get(sessionID);
    if (sessions.size >= MAX_SESSIONS || !context.client?.session?.get) return;
    const controller = new AbortController();
    let timer;
    try {
      // Only fetch session identity, never message/history content. Timeout is independent of
      // SDK cancellation support and prevents a hung lookup from growing the serialized queue.
      const result = await Promise.race([
        context.client.session.get({ path: { id: sessionID }, signal: controller.signal }),
        new Promise((resolve) => {
          timer = setTimeout(() => { controller.abort(); resolve(undefined); }, 300);
        }),
      ]);
      const info = result?.data;
      if (!disposed && info?.id === sessionID) remember(info);
    } catch { /* unknown identity fails closed */ }
    finally { clearTimeout(timer); }
    return disposed ? undefined : sessions.get(sessionID);
  }

  function finish(state) {
    const active = state.active;
    if (!active || !active.idle || !active.terminal || active.cancelled) return;
    const terminal = active.terminal;
    if (terminal.result === "failure" && !active.errors.has(terminal.errorKind)) return;
    if (!state.parentID && !active.started) return;
    if (state.parentID && terminal.result !== "success") return;
    const key = JSON.stringify([state.id, active.userID]);
    if (!consume(completed, key)) return;
    emit(state.parentID ? "SubagentCompleted" :
      terminal.result === "success" ? "ResponseCompleted" : "ResponseFailed", state, {
      turn_id: active.userID, message_id: terminal.messageID,
      terminal: terminal.result, ...(terminal.errorKind ? { error_kind: terminal.errorKind } : {}),
    });
    state.active = undefined;
    state.candidates.delete(active.userID);
  }

  async function message(info) {
    if (!info || info.role !== "assistant" || !identifier(info.id) ||
        !identifier(info.parentID) || !finiteTime(info.time?.created) ||
        info.time.created < bootTime) return;
    const state = await session(info.sessionID);
    if (!state) return;
    state.touched = now();
    const key = JSON.stringify([state.id, info.parentID]);
    if (completed.has(key)) return;
    if (state.active && state.active.userID !== info.parentID) {
      // Compaction and automatic continuation create new parents without chat.message.
      // Their idle cannot finish the old response, even when the new turn is ineligible.
      state.candidates.delete(state.active.userID);
      state.active = undefined;
    }
    if (info.summary === true) return;
    const candidate = state.candidates.get(info.parentID);
    if (!state.parentID && !candidate) return;
    if (state.active?.userID !== info.parentID) {
      // A new main response must belong to a confirmed non-synthetic live user message.
      state.active = {
        userID: info.parentID, started: false, idle: false, cancelled: false,
        errors: new Set(), terminal: undefined,
      };
    }
    const active = state.active;
    if (!state.parentID && !active.started) {
      active.started = true;
      emit("UserTurnStarted", state, { turn_id: info.parentID, message_id: info.id,
        origin_kind: "user", executing: true });
    }
    // A later assistant step invalidates an earlier terminal candidate (e.g. tool continuation).
    if (active.messageID !== info.id) {
      active.terminal = undefined;
      active.idle = false;
      active.errors.clear();
    }
    active.messageID = info.id;
    if (!finiteTime(info.time?.completed) || info.time.completed < info.time.created) return;
    if (info.error) {
      const name = info.error.name;
      if (name === "MessageAbortedError" || name === "AbortError") active.cancelled = true;
      if (terminalErrors.has(name)) active.terminal = {
        result: "failure", errorKind: name, messageID: info.id,
      };
    } else if (info.finish === "stop" || info.finish === "length") {
      active.terminal = { result: "success", messageID: info.id };
    }
    finish(state);
  }

  async function event(input) {
    const event = input?.event;
    const p = event?.properties;
    if (!p || typeof p !== "object") return;
    if (event.type === "session.created" || event.type === "session.updated") {
      remember(p.info);
      return;
    }
    if (event.type === "session.deleted") {
      if (identifier(p.info?.id)) sessions.delete(p.info.id);
      return;
    }
    if (event.type === "message.updated") return message(p.info);
    if (["question.replied", "question.rejected", "permission.replied"].includes(event.type)) {
      if (identifier(p.sessionID) && identifier(p.requestID)) {
        consume(requests, JSON.stringify([event.type.split(".")[0], p.sessionID, p.requestID]));
      }
      return;
    }
    if (event.type === "question.asked" || event.type === "permission.asked") {
      if (!identifier(p.id)) return;
      const state = await session(p.sessionID);
      if (!state) return;
      const kind = event.type.split(".")[0];
      if (!consume(requests, JSON.stringify([kind, state.id, p.id]))) return;
      emit(kind === "question" ? "QuestionAsked" : "PermissionRequested", state,
        { request_id: p.id });
      return;
    }
    const state = sessions.get(p.sessionID);
    if (!state?.active) return;
    state.touched = now();
    if (event.type === "session.error" && typeof p.error?.name === "string") {
      if (p.error.name === "MessageAbortedError" || p.error.name === "AbortError") {
        state.active.cancelled = true;
      }
      if (terminalErrors.has(p.error.name)) state.active.errors.add(p.error.name);
      finish(state);
    } else if (event.type === "session.idle") {
      state.active.idle = true;
      finish(state);
    } else if (event.type === "session.status" && p.status?.type === "busy") {
      state.active.idle = false;
    }
  }

  function schedule(job) {
    if (disposed || pending.length >= 64) return Promise.resolve();
    return new Promise((resolve) => {
      pending.push({ job, resolve });
      if (draining) return;
      draining = true;
      void (async () => {
        try {
          while (pending.length && !disposed) {
            const next = pending.shift();
            try { await next.job(); } catch { /* malformed upstream data fails closed */ }
            next.resolve();
          }
        } finally { draining = false; }
      })();
    });
  }

  function projectEvent(input) {
    const event = input?.event;
    const p = event?.properties;
    if (!p || typeof p !== "object" || ![
      "session.created", "session.updated", "session.deleted", "session.idle", "session.status",
      "session.error", "message.updated", "permission.asked", "permission.replied", "question.asked",
      "question.replied", "question.rejected",
    ].includes(event.type)) return undefined;
    const info = p.info;
    if (info?.parentID !== undefined && !identifier(info.parentID)) return undefined;
    const isMessage = event.type === "message.updated";
    // Session.summary is a diff-stat object; Message.summary is a compaction flag.
    if (isMessage && info?.summary !== undefined && typeof info.summary !== "boolean") return undefined;
    const safeID = (value) => identifier(value) ? value : undefined;
    // Select fields synchronously, before queuing. Queued jobs never retain raw event objects,
    // prompts, message parts, tool output, questions, answers or error messages/stacks.
    const properties = {
      sessionID: safeID(p.sessionID), id: safeID(p.id), requestID: safeID(p.requestID),
      status: p.status ? { type: safeID(p.status.type) } : undefined,
      error: p.error ? { name: safeID(p.error.name) } : undefined,
      info: info ? {
        id: safeID(info.id), sessionID: safeID(info.sessionID), parentID: safeID(info.parentID),
        role: safeID(info.role), summary: isMessage ? info.summary : undefined, finish: safeID(info.finish),
        time: info.time ? { created: finiteTime(info.time.created) ? info.time.created : undefined,
          completed: finiteTime(info.time.completed) ? info.time.completed : undefined } : undefined,
        error: info.error ? { name: safeID(info.error.name) } : undefined,
      } : undefined,
    };
    return { event: { type: event.type, properties } };
  }

  return {
    event: (input) => {
      const projected = projectEvent(input);
      return projected ? schedule(() => event(projected)) : Promise.resolve();
    },
    "chat.message": (input, output) => {
      const sessionID = identifier(input?.sessionID) ? input.sessionID : undefined;
      const messageID = identifier(output?.message?.id) ? output.message.id : undefined;
      const human = output?.message?.role === "user" && messageID && sessionID &&
        output.message.sessionID === sessionID && input.noReply !== true &&
        Array.isArray(output.parts) && output.parts.length <= 256 && output.parts.some((part) =>
          (part?.type === "text" || part?.type === "file") &&
          (part.synthetic === undefined || part.synthetic === false));
      return schedule(async () => {
        if (!human) return;
        const state = await session(sessionID);
        if (!state || state.candidates.size >= 64) return;
        state.touched = now();
        state.candidates.set(messageID, true);
      });
    },
    dispose: async () => {
      disposed = true;
      sessions.clear(); requests.clear(); completed.clear();
      for (const { resolve } of pending.splice(0)) resolve();
      // Already admitted callbacks may still be starting when a short-lived host exits.
      // Let them finish; each child retains its existing bounded timeout while the host lives.
      registry.delete(instanceKey);
    },
  };
}

// OpenCode's module loader selects the default PluginModule before legacy named exports.
export default { id, server };
