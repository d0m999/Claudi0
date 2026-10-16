import assert from "node:assert/strict";
import { readFile, mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const source = await readFile(new URL("../integrations/opencode/claudio.js", import.meta.url), "utf8");
const installation = { helper_path: "/fixture/.claudio/bin/claudio",
  installation_id: "11111111-2222-4333-8444-555555555555",
  enabled_events: ["UserTurnStarted", "ResponseCompleted", "ResponseFailed", "PermissionRequested",
    "QuestionAsked", "SubagentCompleted"] };
const module = await import("data:text/javascript;base64," +
  Buffer.from("const installation = " + JSON.stringify(installation) + ";\n" + source).toString("base64"));
assert.equal(module.id, "claudio.opencode.v1");
assert.equal(typeof module.server, "function");
// OpenCode 1.18.34 loads the default PluginModule before considering legacy exports.
// Named id/server exports alone fall through to the legacy function-only loader.
assert.equal(module.default?.id, "claudio.opencode.v1",
  "the real host loader must discover a default PluginModule with a stable id");
assert.equal(module.default?.server, module.server,
  "the real host loader must initialize the same public server entry point");
// OpenCode 2 requires a default definition with an id and a setup function and
// ignores the legacy server export. The dual shape keeps 1.18.29+ working.
assert.equal(typeof module.default?.setup, "function",
  "OpenCode 2 must discover setup() on the same default PluginModule");
let count = 0;
let fixtureNumber = 0;

async function check(name, body) {
  await body();
  count++;
  console.log("PASS " + name);
}

async function fixture({ lookup, clock } = {}) {
  const events = [];
  const context = { directory: "/fixture/project-" + fixtureNumber++,
    client: { session: { get: lookup ?? (async () => ({ data: undefined })) } } };
  const hooks = await module.default.server(context, { dispatch: (name, payload) => events.push({ name, payload }),
    clock: clock ?? (() => 1000) });
  const event = (type, properties) => hooks.event({ event: { type, properties } });
  const session = (id = "s", parentID) => event("session.created", { info: { id, parentID } });
  const user = (id = "u", sessionID = "s", synthetic = false) =>
    hooks["chat.message"]({ sessionID }, { message: { role: "user", id, sessionID },
      parts: [{ type: "text", text: "PRIVATE_PROMPT", synthetic }] });
  const assistant = (overrides = {}) => event("message.updated", { info: {
    id: "a", parentID: "u", sessionID: "s", role: "assistant",
    time: { created: 1000 }, ...overrides } });
  const complete = (overrides = {}) => assistant({ finish: "stop",
    time: { created: 1000, completed: 1001 }, ...overrides });
  const idle = (sessionID = "s") => event("session.idle", { sessionID });
  const names = () => events.map((e) => e.name);
  return { context, hooks, event, session, user, assistant, complete, idle, names, events };
}

await check("ordinary main turn needs executed message, terminal message and idle", async () => {
  const f = await fixture();
  await f.session(); await f.user();
  assert.deepEqual(f.names(), []);
  await f.assistant(); await f.complete();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.idle(); await f.idle(); await f.complete();
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await f.hooks.dispose();
});

await check("session summary objects preserve identity without becoming message summary flags", async () => {
  const f = await fixture();
  const summary = { additions: 1, deletions: 0, files: 1, diffs: [{ patch: "PRIVATE_DIFF" }] };
  await f.event("session.created", { info: { id: "s", summary, title: "PRIVATE_TITLE" } });
  await f.user();
  await f.assistant({ summary: "invalid-message-flag" });
  assert.deepEqual(f.names(), []);
  await f.assistant(); await f.complete(); await f.idle();
  await f.event("session.updated", { info: { id: "c", parentID: "s", summary } });
  await f.complete({ sessionID: "c", parentID: "child-user", id: "child-message" });
  await f.idle("c");
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted", "SubagentCompleted"]);
  assert.equal(JSON.stringify(f.events).includes("PRIVATE_"), false);
  await f.hooks.dispose();
});

await check("idle, shell idle, and noReply storage alone never complete or start", async () => {
  const f = await fixture();
  await f.session(); await f.idle(); await f.user(); await f.idle();
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("synthetic and history messages never create a main turn", async () => {
  const f = await fixture();
  await f.session(); await f.user("u", "s", true); await f.complete(); await f.idle();
  await f.user("history");
  await f.complete({ parentID: "history", time: { created: 999, completed: 999 } });
  await f.idle();
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

for (const order of ["before-idle", "after-idle", "before-terminal"]) {
  await check("terminal failure " + order + " emits once without success", async () => {
    const f = await fixture();
    await f.session(); await f.user(); await f.assistant();
    const error = () => f.event("session.error", { sessionID: "s",
      error: { name: "APIError", data: { message: "PRIVATE_ERROR" } } });
    const complete = () => f.complete({ error: { name: "APIError", data: { message: "PRIVATE_ERROR" } } });
    if (order === "before-terminal") { await error(); await f.idle(); await complete(); }
    else { await complete(); if (order === "before-idle") await error(); await f.idle();
      if (order === "after-idle") await error(); }
    await f.idle();
    assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseFailed"]);
    await f.hooks.dispose();
  });
}

for (const name of ["MessageAbortedError", "AbortError", "ContextOverflowError", "UnknownRecoverableError"]) {
  await check("non-terminal/cancel error " + name + " never becomes failure or success", async () => {
    const f = await fixture();
    await f.session(); await f.user(); await f.assistant();
    await f.event("session.error", { sessionID: "s", error: { name } });
    await f.complete({ error: { name } }); await f.idle();
    assert.deepEqual(f.names(), ["UserTurnStarted"]);
    await f.hooks.dispose();
  });
}

await check("recoverable compaction may continue to a normal response", async () => {
  const f = await fixture();
  await f.session(); await f.user(); await f.assistant();
  await f.event("session.error", { sessionID: "s", error: { name: "ContextOverflowError" } });
  await f.complete({ id: "summary", summary: true });
  await f.event("session.status", { sessionID: "s", status: { type: "busy" } });
  await f.complete({ id: "after-compaction" }); await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await f.hooks.dispose();
});

for (const outcome of ["failure", "success", "incomplete"]) {
  await check("automatic compaction " + outcome + " never reuses the previous response terminal", async () => {
    const f = await fixture();
    await f.session(); await f.user(); await f.complete();
    // OpenCode aec0b9a6: compaction.ts creates these users directly with updateMessage,
    // bypassing chat.message; the synthetic continuation has no confirmed user-turn identity.
    const storedUser = (id, created) => f.event("message.updated", {
      info: { role: "user", id, sessionID: "s", time: { created } },
    });
    await storedUser("compaction-user", 1002);
    await f.complete({ id: "summary", parentID: "compaction-user", summary: true,
      time: { created: 1003, completed: 1004 } });
    await storedUser("auto-user", 1005);
    await f.assistant({ id: "auto-response", parentID: "auto-user", time: { created: 1006 } });
    await f.event("session.status", { sessionID: "s", status: { type: "busy" } });
    if (outcome === "failure") {
      // processor.ts halt publishes error and idle before cleanup publishes completed.
      await f.event("session.error", { sessionID: "s", error: { name: "APIError" } });
      await f.idle();
      assert.deepEqual(f.names(), ["UserTurnStarted"]);
      await f.complete({ id: "auto-response", parentID: "auto-user",
        time: { created: 1006, completed: 1007 }, error: { name: "APIError" } });
    } else if (outcome === "success") {
      await f.complete({ id: "auto-response", parentID: "auto-user",
        time: { created: 1006, completed: 1007 } });
    }
    await f.idle();
    assert.deepEqual(f.names(), ["UserTurnStarted"]);
    // A late update of the retired response cannot restore its old terminal/idle pairing.
    await f.complete(); await f.idle();
    assert.deepEqual(f.names(), ["UserTurnStarted"]);
    await f.user("next-user");
    await f.complete({ id: "next-response", parentID: "next-user",
      time: { created: 1008, completed: 1009 } });
    await f.idle();
    assert.deepEqual(f.names(), ["UserTurnStarted", "UserTurnStarted", "ResponseCompleted"]);
    assert.equal(f.events.at(-1).payload.turn_id, "next-user");
    assert.equal(f.events.at(-1).payload.message_id, "next-response");
    await f.hooks.dispose();
  });
}

await check("compaction failure idle cannot complete the response before compaction", async () => {
  const f = await fixture();
  await f.session(); await f.user(); await f.complete();
  await f.assistant({ id: "summary", parentID: "compaction-user", summary: true,
    time: { created: 1002 } });
  await f.event("session.error", { sessionID: "s", error: { name: "APIError" } });
  await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.complete({ id: "summary", parentID: "compaction-user", summary: true,
    time: { created: 1002, completed: 1003 }, error: { name: "APIError" } });
  await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.hooks.dispose();
});

await check("session.error without a terminal message or session identity is insufficient", async () => {
  const f = await fixture();
  await f.event("session.error", { error: { name: "UnknownError" } });
  await f.session(); await f.user(); await f.assistant();
  await f.event("session.error", { sessionID: "s", error: { name: "APIError" } });
  await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.hooks.dispose();
});

await check("tool-calls and unknown finishes are not terminal completion", async () => {
  const f = await fixture();
  await f.session(); await f.user();
  for (const finish of ["tool-calls", "unknown", "error", "content-filter", undefined]) {
    await f.complete({ finish }); await f.idle();
  }
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.hooks.dispose();
});

await check("a later assistant step invalidates an earlier completion candidate", async () => {
  const f = await fixture();
  await f.session(); await f.user(); await f.complete();
  await f.assistant({ id: "tool-continuation" }); await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.complete({ id: "tool-continuation" });
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await f.hooks.dispose();
});

await check("two simultaneous sessions and successive turns retain independent identities", async () => {
  const f = await fixture();
  await f.session("s1"); await f.session("s2");
  await Promise.all([f.user("u1", "s1"), f.user("u2", "s2")]);
  await Promise.all([f.complete({ sessionID: "s1", parentID: "u1", id: "a1" }),
    f.complete({ sessionID: "s2", parentID: "u2", id: "a2" })]);
  await f.idle("s2"); await f.idle("s1");
  await f.user("u3", "s1"); await f.complete({ sessionID: "s1", parentID: "u3", id: "a3" });
  await f.idle("s1");
  assert.equal(f.events.filter((e) => e.name === "ResponseCompleted").length, 3);
  assert.deepEqual(f.events.filter((e) => e.name === "ResponseCompleted").map((e) =>
    [e.payload.session_id, e.payload.turn_id]), [["s2", "u2"], ["s1", "u1"], ["s1", "u3"]]);
  await f.hooks.dispose();
});

await check("background subagent completion requires child session terminal and idle", async () => {
  const f = await fixture();
  await f.session("parent"); await f.session("child", "parent");
  await f.event("tool.execute.after", { tool: "task", sessionID: "parent" });
  assert.deepEqual(f.names(), []);
  await f.complete({ sessionID: "child", parentID: "child-user" }); await f.idle("parent");
  assert.deepEqual(f.names(), []);
  await f.idle("child");
  assert.deepEqual(f.names(), ["SubagentCompleted"]);
  assert.equal(f.events[0].payload.parent_session_id, "parent");
  await f.hooks.dispose();
});

await check("failed child is never reported as successful subagent or main failure", async () => {
  const f = await fixture(); await f.session("child", "parent");
  await f.assistant({ sessionID: "child", parentID: "child-user" });
  await f.event("session.error", { sessionID: "child", error: { name: "APIError" } });
  await f.complete({ sessionID: "child", parentID: "child-user", error: { name: "APIError" } });
  await f.idle("child");
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("unknown or contradictory session parent identity fails closed", async () => {
  const f = await fixture(); await f.user(); await f.complete(); await f.idle();
  assert.deepEqual(f.names(), []);
  await f.session(); await f.user(); await f.session("s", "different-parent");
  await f.complete(); await f.idle();
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("one identity lookup can establish an existing session without reading history", async () => {
  const calls = [];
  const f = await fixture({ lookup: async (input) => { calls.push(input.path.id); return { data: { id: "s" } }; } });
  await f.user(); await f.complete(); await f.idle();
  assert.deepEqual(calls, ["s"]);
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await f.hooks.dispose();
});

await check("question and permission request identities deduplicate independently", async () => {
  const f = await fixture(); await f.session();
  const request = { sessionID: "s", id: "request", questions: ["PRIVATE_QUESTION"],
    patterns: ["PRIVATE_PATH"] };
  await f.event("question.asked", request); await f.event("question.asked", request);
  await f.event("permission.asked", request); await f.event("permission.asked", request);
  await f.session("s2"); await f.event("question.asked", { ...request, sessionID: "s2" });
  assert.deepEqual(f.names(), ["QuestionAsked", "PermissionRequested", "QuestionAsked"]);
  assert(!JSON.stringify(f.events).includes("PRIVATE_"));
  await f.hooks.dispose();
});

await check("replied/rejected tombstones suppress late duplicate asked events", async () => {
  const f = await fixture(); await f.session();
  for (const type of ["question.replied", "question.rejected", "permission.replied"]) {
    const requestID = type;
    await f.event(type, { sessionID: "s", requestID, answers: ["PRIVATE_ANSWER"] });
    await f.event(type.split(".")[0] + ".asked", { sessionID: "s", id: requestID });
  }
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("malformed event identities and request fields never emit", async () => {
  const f = await fixture(); await f.session();
  for (const id of [undefined, null, 1, "", "space id", "x".repeat(257), "bad\u202eid"]) {
    await f.event("question.asked", { sessionID: "s", id });
    await f.event("question.asked", { sessionID: id, id: "r" });
  }
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("request ledger never evicts live entries to replay duplicates", async () => {
  const f = await fixture(); await f.session();
  for (let i = 0; i < 257; i++) await f.event("question.asked", { sessionID: "s", id: "q" + i });
  await f.event("question.asked", { sessionID: "s", id: "q0" });
  assert.equal(f.events.length, 256);
  await f.hooks.dispose();
});

await check("session capacity and TTL are bounded without history replay", async () => {
  let time = 1000;
  const f = await fixture({ clock: () => time });
  for (let i = 0; i < 129; i++) await f.session("s" + i);
  await f.event("question.asked", { sessionID: "s128", id: "r" });
  assert.deepEqual(f.names(), []);
  time += 30 * 60 * 1000 + 1;
  await f.session("new"); await f.event("question.asked", { sessionID: "new", id: "new-request" });
  assert.deepEqual(f.names(), ["QuestionAsked"]);
  await f.hooks.dispose();
});

await check("duplicate plugin instances share an in-process ownership guard", async () => {
  const f = await fixture();
  const duplicate = await module.server(f.context, { dispatch: () => { throw Error("duplicate"); } });
  assert.deepEqual(duplicate, {});
  await f.hooks.dispose();
});

await check("dispose clears pending events and prevents subsequent sounds", async () => {
  const f = await fixture(); await f.session(); await f.user(); await f.hooks.dispose();
  await f.complete(); await f.idle();
  assert.deepEqual(f.names(), []);
});

await check("hung identity lookups have a bounded timeout", async () => {
  const f = await fixture({ lookup: () => new Promise(() => {}) });
  const started = Date.now();
  await f.user();
  assert(Date.now() - started < 1500);
  assert.deepEqual(f.names(), []);
  await f.hooks.dispose();
});

await check("a recovered assistant step needs its own corresponding idle", async () => {
  const f = await fixture(); await f.session(); await f.user(); await f.assistant();
  await f.complete({ error: { name: "ContextOverflowError" } });
  await f.event("session.error", { sessionID: "s", error: { name: "ContextOverflowError" } });
  await f.idle();
  await f.complete({ id: "new-step" });
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.idle();
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await f.hooks.dispose();
});

await check("noReply, mismatched message identity and malformed synthetic flags never start", async () => {
  for (const mode of ["noReply", "mismatched-session", "bad-synthetic"]) {
    const f = await fixture(); await f.session();
    await f.hooks["chat.message"]({ sessionID: "s", noReply: mode === "noReply" }, {
      message: { role: "user", id: "u", sessionID: mode === "mismatched-session" ? "other" : "s" },
      parts: [{ type: "text", synthetic: mode === "bad-synthetic" ? "false" : false }],
    });
    await f.complete(); await f.idle();
    assert.deepEqual(f.names(), []);
    await f.hooks.dispose();
  }
});

await check("queued projection captures only bounded identity fields before caller mutation", async () => {
  let release;
  const blocked = new Promise((resolve) => { release = resolve; });
  const f = await fixture({ lookup: async ({ path }) => {
    await blocked; return { data: { id: path.id } };
  } });
  const first = f.user();
  const input = { event: { type: "permission.asked", properties: { sessionID: "s", id: "q",
    tool: { output: "PRIVATE_TOOL_BODY" } } } };
  const queued = f.hooks.event(input);
  input.event.properties.id = { oversized: "PRIVATE_BODY".repeat(10000) };
  input.event.properties.sessionID = "other";
  release(); await first; await queued;
  assert.equal(f.events[0].payload.request_id, "q");
  assert.equal(f.events[0].payload.session_id, "s");
  assert(!JSON.stringify(f.events).includes("PRIVATE"));
  await f.hooks.dispose();
});

await check("serialized queue overflow stays bounded and drops unidentified callbacks", async () => {
  let release;
  const blocked = new Promise((resolve) => { release = resolve; });
  const f = await fixture({ lookup: async ({ path }) => {
    await blocked; return { data: { id: path.id } };
  } });
  const first = f.user();
  const work = Array.from({ length: 100 }, (_, index) => f.event("permission.asked", {
    sessionID: "s", id: "q-" + index,
  }));
  release(); await first; await Promise.all(work);
  assert.equal(f.events.length, 64);
  await f.hooks.dispose();
});

await check("dispose lets admitted helper callbacks finish within their existing deadline", async () => {
  const root = await mkdtemp(join(tmpdir(), "claudio-opencode-dispose-"));
  const helper = join(root, ".claudio", "bin", "claudio");
  const record = join(root, "events.jsonl");
  await mkdir(join(root, ".claudio", "bin"), { recursive: true });
  await writeFile(helper, "#!/usr/bin/env node\n" +
    "const fs = require('node:fs');\n" +
    "process.stdin.resume();\n" +
    "process.stdin.on('end', () => setTimeout(() => fs.appendFileSync(" +
    JSON.stringify(record) + ", JSON.stringify(process.argv[4]) + '\\n'), 100));\n",
    { mode: 0o700 });
  const realModule = await import("data:text/javascript;base64," + Buffer.from(
    "const installation = " + JSON.stringify({ ...installation, helper_path: helper }) +
    ";\n" + source).toString("base64"));
  const hooks = await realModule.default.server({ directory: root,
    client: { session: { get: async () => ({ data: undefined }) } } }, { clock: () => 1000 });
  const event = (type, properties) => hooks.event({ event: { type, properties } });
  try {
    await event("session.created", { info: { id: "s" } });
    await hooks["chat.message"]({ sessionID: "s" }, {
      message: { role: "user", id: "u", sessionID: "s" },
      parts: [{ type: "text", synthetic: false }],
    });
    await event("message.updated", { info: { id: "a", parentID: "u", sessionID: "s",
      role: "assistant", finish: "stop", time: { created: 1000, completed: 1001 } } });
    await event("session.idle", { sessionID: "s" });
    await hooks.dispose();
    const deadline = Date.now() + 2000;
    let received = [];
    while (Date.now() < deadline) {
      try { received = (await readFile(record, "utf8")).trim().split("\n").map(JSON.parse); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      if (received.length === 2) break;
      await delay(25);
    }
    assert.deepEqual(received.sort(), ["ResponseCompleted", "UserTurnStarted"]);
    await event("question.asked", { sessionID: "s", id: "after-dispose" });
    await delay(150);
    assert.equal((await readFile(record, "utf8")).trim().split("\n").length, 2);
  } finally {
    await hooks.dispose();
    await rm(root, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// OpenCode 2 contract: default { id, setup }, ctx.event.subscribe({ signal })
// as an async iterator, domain hooks on ctx.session. 2.0.27 delivers
// { type, data }; newer builds use { type, properties } and a "next" family
// segment. Fixtures drive both shapes.
// ---------------------------------------------------------------------------

function v2Fixture({ lookup, clock, events, claims } = {}) {
  const queue = [];
  const waiters = [];
  const stream = {
    [Symbol.asyncIterator]() { return this; },
    next() {
      return queue.length
        ? Promise.resolve({ value: queue.shift(), done: false })
        : new Promise((resolve) => waiters.push(resolve));
    },
    return() { return Promise.resolve({ done: true }); },
  };
  const hooks = {};
  const context = {
    location: { directory: "/fixture/v2-project-" + fixtureNumber++ },
    event: { subscribe: (options) => stream },
    session: {
      // OpenCode 2 reads { sessionID }; the plugin also tolerates { path: { id } }.
      get: lookup ?? (async () => ({ data: undefined })),
      hook: async (name, handler) => { (hooks[name] ??= []).push(handler); },
    },
  };
  const dispatched = events ?? [];
  const f = {};
  f.context = context;
  f.hooks = hooks;
  f.setup = () => module.default.setup(context, {
    dispatch: (name, payload) => dispatched.push({ name, payload }),
    clock: clock ?? (() => 1000),
    claims: claims ?? new Map(),
  });
  f.events = dispatched;
  f.push = (event) => {
    if (waiters.length) waiters.shift()({ value: event, done: false });
    else queue.push(event);
  };
  f.emitEvent = async (type, data) => { f.push({ type, data }); await settle(); };
  f.emitProperties = async (type, properties) => { f.push({ type, properties }); await settle(); };
  f.names = () => dispatched.map((entry) => entry.name);
  f.sessionCreated = async (id = "s", parentID) => f.emitEvent("session.created",
    { sessionID: id, parentID, slug: "slug", projectID: "p", version: "2" });
  f.admit = async (sessionID = "s", messageID = "prompt-1") => {
    // Admission is the pre-admission prompt hook; durable inbox delivery alone
    // never evidences a user turn because OpenCode 2 delivers it for synthetic
    // and automatic executions too.
    for (const handler of f.hooks.prompt ?? []) {
      await handler({ sessionID, messageID, parts: [{ type: "text", synthetic: false }] });
    }
    await settle();
  };
  f.admitSynthetic = async (sessionID = "s", messageID = "synthetic-1") => {
    for (const handler of f.hooks.prompt ?? []) {
      await handler({ sessionID, messageID, parts: [{ type: "text", synthetic: true }] });
    }
    await settle();
  };
  f.deliverInbox = async (sessionID = "s", inboxID = "inb-1") =>
    f.emitEvent("session.inbox.delivered", { sessionID, inboxID });
  f.startExecution = async (sessionID = "s") => f.emitEvent("session.execution.started", { sessionID });
  f.step = async (sessionID = "s", assistantMessageID = "msg-1") =>
    f.emitEvent("session.step.started", { sessionID, assistantMessageID, started: 1000 });
  f.succeeded = async (sessionID = "s") => f.emitEvent("session.execution.succeeded", { sessionID });
  f.failed = async (sessionID = "s", name = "APIError") => f.emitEvent("session.execution.failed",
    { sessionID, error: { name } });
  return f;
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 10));

for (const outcome of ["succeeded", "failed", "interrupted"]) {
  await check("V2 queued user admission survives the active execution " + outcome, async () => {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.sessionCreated();
    await f.admit();
    await f.startExecution();
    await f.step();
    await f.admit("s", "prompt-2");
    await f.emitEvent("session.execution." + outcome, { sessionID: "s", error: { name: "APIError" } });
    await f.startExecution();
    await f.step("s", "msg-2");
    await f.succeeded();
    const first = outcome === "succeeded" ? ["UserTurnStarted", "ResponseCompleted"]
      : outcome === "failed" ? ["UserTurnStarted", "ResponseFailed"] : ["UserTurnStarted"];
    assert.deepEqual(f.names(), [...first, "UserTurnStarted", "ResponseCompleted"]);
    assert.equal(f.events.at(-2).payload.turn_id, "prompt-2");
    assert.equal(f.events.at(-1).payload.turn_id, "prompt-2");
    assert.equal(f.events.at(-1).payload.message_id, "msg-2");
    await cleanup();
  });
}

for (const outcome of ["succeeded", "failed", "interrupted"]) {
  await check("V2 queued user admission survives an unadmitted synthetic execution " + outcome,
    async () => {
      const f = v2Fixture();
      const cleanup = await f.setup();
      await f.sessionCreated();
      // A synthetic or automatic execution never establishes an active turn:
      // its step is unadmitted. Its terminal must retire only the admission it
      // carried, not a real user prompt queued while it was executing.
      await f.admitSynthetic("s", "synthetic-1");
      await f.startExecution();
      await f.step("s", "synthetic-msg");
      await f.admit("s", "prompt-2");
      await f.emitEvent("session.execution." + outcome, { sessionID: "s", error: { name: "APIError" } });
      await f.startExecution();
      await f.step("s", "msg-2");
      await f.succeeded();
      assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
      assert.equal(f.events[0].payload.turn_id, "prompt-2");
      assert.equal(f.events[0].payload.message_id, "msg-2");
      assert.equal(f.events[1].payload.turn_id, "prompt-2");
      await cleanup();
    });
}

for (const outcome of ["failed", "interrupted"]) {
  for (const executionStarted of [false, true]) {
    await check("V2 pre-step " + outcome + " retires admission, execution started: " + executionStarted, async () => {
      const f = v2Fixture();
      const cleanup = await f.setup();
      await f.sessionCreated();
      await f.admit();
      if (executionStarted) await f.startExecution();
      await f.emitEvent("session.execution." + outcome, { sessionID: "s", error: { name: "APIError" } });
      await f.admitSynthetic();
      await f.startExecution();
      await f.step("s", "synthetic-msg");
      await f.succeeded();
      assert.deepEqual(f.names(), [], "a cancelled admission cannot authorize synthetic execution");
      await f.admit("s", "fresh-prompt");
      await f.startExecution();
      await f.step("s", "fresh-msg");
      await f.succeeded();
      assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
      assert.equal(f.events[0].payload.turn_id, "fresh-prompt");
      await cleanup();
    });
  }
}

await check("V2 ordinary turn needs admitted prompt, execution and step", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.startExecution();
  await f.step();
  assert.deepEqual(f.names(), [], "execution without admitted user input never starts");
  await f.admit();
  await f.startExecution();
  await f.step();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.succeeded();
  await f.succeeded();
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  assert.equal(f.events[0].payload.session_kind, "main");
  assert.equal(f.events[0].payload.turn_id, "prompt-1");
  assert.equal(f.events[0].payload.message_id, "msg-1");
  assert.equal(f.events[1].payload.terminal, "success");
  await cleanup();
});

await check("V2 inbox delivery alone never starts a turn", async () => {
  // OpenCode 2 delivers durable prompt delivery for synthetic and automatic
  // executions too; only pre-admission prompt admission evidences user input.
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.deliverInbox();
  await f.startExecution();
  await f.step();
  await f.succeeded();
  assert.deepEqual(f.names(), []);
  await cleanup();
});

await check("V2 synthetic prompt parts and noReply never admit a turn", async () => {
  for (const mode of ["synthetic", "noReply"]) {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.sessionCreated();
    for (const handler of f.hooks.prompt ?? []) {
      await handler(mode === "noReply"
        ? { sessionID: "s", messageID: "p", noReply: true, parts: [{ type: "text" }] }
        : { sessionID: "s", messageID: "p", parts: [{ type: "text", synthetic: true }] });
    }
    await f.startExecution();
    await f.step();
    await f.succeeded();
    assert.deepEqual(f.names(), [], mode + " must not start a turn");
    await cleanup();
  }
});

await check("V2 a later synthetic event never retracts an admitted real turn", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.admit();
  await f.emitEvent("session.synthetic", { sessionID: "s", text: "PRIVATE_SYNTHETIC" });
  await f.startExecution();
  await f.step();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.succeeded();
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  await cleanup();
});

for (const name of ["APIError", "ProviderAuthError", "UnknownError", "MessageOutputLengthError",
  "StructuredOutputError"]) {
  await check("V2 terminal failure " + name + " emits stop_failure once", async () => {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.sessionCreated();
    await f.admit();
    await f.startExecution();
    await f.step();
    await f.failed("s", name);
    await f.failed("s", name);
    assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseFailed"]);
    assert.equal(f.events[1].payload.error_kind, name);
    assert.equal(f.events[1].payload.terminal, "failure");
    await cleanup();
  });
}

for (const name of ["MessageAbortedError", "AbortError", "ContextOverflowError", "ContentFilterError"]) {
  await check("V2 retryable error " + name + " never becomes failure or success", async () => {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.sessionCreated();
    await f.admit();
    await f.startExecution();
    await f.step();
    for (let attempt = 1; attempt <= 2; attempt++) {
      await f.emitEvent("session.retry.scheduled", { sessionID: "s",
        assistantMessageID: "msg-1", attempt, at: 2000, error: { name } });
      await f.step();
    }
    await f.succeeded();
    assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
    await cleanup();
  });

  await check("V2 execution failure with non-terminal kind " + name + " stays silent", async () => {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.sessionCreated();
    await f.admit();
    await f.startExecution();
    await f.step();
    await f.failed("s", name);
    assert.deepEqual(f.names(), ["UserTurnStarted"]);
    await cleanup();
  });
}

await check("V2 interrupted executions never play", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.admit();
  await f.startExecution();
  await f.step();
  await f.emitEvent("session.execution.interrupted", { sessionID: "s", reason: "user" });
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await cleanup();
});

for (const type of ["session.created", "session.updated"]) {
  for (const shape of ["data", "properties"]) {
    await check("V2 nested child identity survives top-level sessionID: " + type + " / " + shape, async () => {
      const f = v2Fixture();
      const cleanup = await f.setup();
      const session = { sessionID: "child", info: { id: "child", parentID: "parent",
        title: "PRIVATE_TITLE", summary: { additions: 1 } } };
      if (shape === "data") await f.emitEvent(type, session);
      else await f.emitProperties(type, session);
      await f.emitEvent("permission.asked", { sessionID: "child", id: "child-permission" });
      assert.equal(f.events[0].payload.session_kind, "child");
      assert.equal(f.events[0].payload.parent_session_id, "parent");
      await f.startExecution("child");
      await f.step("child", "child-msg");
      await f.succeeded("child");
      assert.deepEqual(f.names(), ["PermissionRequested", "SubagentCompleted"]);
      assert.equal(f.events[1].payload.parent_session_id, "parent");
      assert.equal(f.events[1].payload.session_id, "child");
      assert.equal(JSON.stringify(f.events).includes("PRIVATE_"), false);
      await cleanup();
    });
  }
}

await check("V2 child session completion is subagent_stop with parent identity", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated("child", "parent");
  await f.startExecution("child");
  await f.step("child", "child-msg");
  assert.deepEqual(f.names(), [], "a child turn is not a user turn");
  await f.succeeded("child");
  assert.deepEqual(f.names(), ["SubagentCompleted"]);
  assert.equal(f.events[0].payload.session_kind, "child");
  assert.equal(f.events[0].payload.parent_session_id, "parent");
  assert.equal(f.events[0].payload.session_id, "child");
  await cleanup();
});

await check("V2 failed child is never a successful subagent or main failure", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated("child", "parent");
  await f.startExecution("child");
  await f.step("child", "child-msg");
  await f.failed("child", "APIError");
  assert.deepEqual(f.names(), []);
  await cleanup();
});

await check("V2 question and permission requests deduplicate independently", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.emitEvent("permission.asked", { sessionID: "s", id: "perm-1" });
  await f.emitEvent("permission.asked", { sessionID: "s", id: "perm-1" });
  await f.emitEvent("form.created", { form: { id: "form-1", sessionID: "s" } });
  await f.emitEvent("form.created", { form: { id: "form-1", sessionID: "s" } });
  await f.emitEvent("question.asked", { sessionID: "s", id: "q-1" });
  assert.deepEqual(f.names(), ["PermissionRequested", "QuestionAsked", "QuestionAsked"]);
  await settle();
  await cleanup();
});

await check("V2 settlement tombstones suppress late duplicate asked events", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  for (const [settled, asked] of [["form.replied", "form.created"],
    ["form.cancelled", "form.created"], ["permission.replied", "permission.asked"]]) {
    await f.emitEvent(settled, { sessionID: "s", id: "r-" + settled });
    await f.emitEvent(asked, settled.startsWith("form")
      ? { form: { id: "r-" + settled, sessionID: "s" } }
      : { sessionID: "s", id: "r-" + settled });
  }
  await f.emitEvent("question.rejected", { sessionID: "s", requestID: "q-late" });
  await f.emitEvent("question.asked", { sessionID: "s", id: "q-late" });
  assert.deepEqual(f.names(), []);
  await cleanup();
});

await check("V2 unknown session identity fails closed until a look-up proves it", async () => {
  const calls = [];
  const f = v2Fixture({ lookup: async (input) => {
    // OpenCode 2's real session.get shape is { sessionID }.
    const id = input?.sessionID ?? input?.path?.id;
    calls.push(id);
    return { data: { id, parentID: "parent" } };
  } });
  const cleanup = await f.setup();
  await f.emitEvent("permission.asked", { sessionID: "ghost", id: "r" });
  await settle();
  assert.deepEqual(calls, ["ghost"], "one bounded identity look-up, no history");
  await settle();
  assert.deepEqual(f.names(), ["PermissionRequested"]);
  assert.equal(f.events[0].payload.session_kind, "child");
  await cleanup();
});

await check("V2 step for a session created before load still needs its own identity", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  // No session.created: the execution, admission and step stay unconfirmed.
  await f.admit();
  await f.startExecution();
  await f.step();
  await f.succeeded();
  assert.deepEqual(f.names(), []);
  await cleanup();
});

await check("V2 one-shot CLI turn proves identity through the { sessionID } look-up", async () => {
  // OpenCode's `opencode run` submits without session.created in the stream;
  // the only identity evidence is the real { sessionID } look-up shape.
  const calls = [];
  const f = v2Fixture({ lookup: async (input) => {
    const id = input?.sessionID ?? input?.path?.id;
    calls.push(id);
    return { data: { id } };
  } });
  const cleanup = await f.setup();
  await f.admit();
  await f.startExecution();
  await f.step();
  await f.succeeded();
  assert.deepEqual(calls, ["s"]);
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  assert.equal(f.events[0].payload.turn_id, "prompt-1");
  await cleanup();
});

await check("V2 a failed look-up keeps the turn unconfirmed", async () => {
  const f = v2Fixture({ lookup: async () => { throw new Error("unavailable"); } });
  const cleanup = await f.setup();
  await f.admit();
  await f.startExecution();
  await f.step();
  await f.succeeded();
  assert.deepEqual(f.names(), []);
  await cleanup();
});

await check("V2 next-prefixed and properties-shaped events normalize to the same bridge", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.emitProperties("session.created", { sessionID: "s", info: { id: "s" } });
  for (const handler of f.hooks.prompt ?? []) {
    await handler({ sessionID: "s", messageID: "prompt-2",
      parts: [{ type: "text", synthetic: false }] });
  }
  await f.emitProperties("session.next.execution.started", { sessionID: "s" });
  await f.emitProperties("session.next.step.started",
    { sessionID: "s", assistantMessageID: "msg-2" });
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await f.emitProperties("session.next.execution.succeeded", { sessionID: "s" });
  assert.deepEqual(f.names(), ["UserTurnStarted", "ResponseCompleted"]);
  assert.equal(f.events[0].payload.turn_id, "prompt-2");
  await cleanup();
});

await check("V2 unrelated stream events never emit or retain bodies", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.emitEvent("session.reasoning.delta", { sessionID: "s", delta: "PRIVATE_REASONING" });
  await f.emitEvent("session.tool.called", { sessionID: "s",
    input: { command: "PRIVATE_COMMAND" }, executed: true });
  await f.emitEvent("session.text.delta", { sessionID: "s", delta: "PRIVATE_TEXT" });
  await f.emitEvent("model.updated", {});
  assert.deepEqual(f.names(), []);
  assert.equal(JSON.stringify(f.events).includes("PRIVATE"), false);
  await cleanup();
});

await check("V2 global requests use their session directory even when another instance claims first", async () => {
  const claims = new Map();
  const events = [];
  const a = v2Fixture({ claims, events });
  const b = v2Fixture({ claims, events });
  const cleanupA = await a.setup();
  const cleanupB = await b.setup();
  const session = { sessionID: "session-b", info: { id: "session-b", directory: b.context.location.directory } };
  await a.emitProperties("session.created", session);
  await b.emitProperties("session.created", session);
  const request = { sessionID: "session-b", id: "permission-b" };
  await a.emitEvent("permission.asked", request);
  await b.emitEvent("permission.asked", request);
  assert.equal(events.length, 1, "global claim still deduplicates the request");
  assert.equal(events[0].payload.cwd, b.context.location.directory);
  await cleanupA();
  await cleanupB();
});

for (const source of ["created", "updated", "lookup"]) {
  await check("V2 session directory comes from " + source + " evidence", async () => {
    const f = v2Fixture({ lookup: async () => ({ data: { id: "s", directory: "/fixture/session-owner" } }) });
    const cleanup = await f.setup();
    if (source === "created") {
      await f.emitEvent("session.created", { sessionID: "s", directory: "/fixture/session-owner" });
    } else if (source === "updated") {
      await f.sessionCreated();
      await f.emitProperties("session.updated", { sessionID: "s", info: { id: "s", directory: "/fixture/session-owner" } });
    }
    await f.emitEvent("permission.asked", { sessionID: "s", id: "permission" });
    assert.equal(f.events[0].payload.cwd, "/fixture/session-owner");
    await f.admit();
    await f.startExecution();
    await f.step();
    await f.succeeded();
    assert.deepEqual(f.names(), ["PermissionRequested", "UserTurnStarted", "ResponseCompleted"]);
    assert.equal(f.events.every(({ payload }) => payload.cwd === "/fixture/session-owner"), true);
    await cleanup();
  });
}

await check("V2 unknown or unsafe session directories never use the subscriber directory", async () => {
  for (const directory of [undefined, "relative/path", 42, "/unsafe\npath", "/bad\u202epath", "/" + "x".repeat(4096)]) {
    const f = v2Fixture();
    const cleanup = await f.setup();
    await f.emitEvent("session.created", { sessionID: "s", info: { id: "s", directory } });
    await f.emitEvent("permission.asked", { sessionID: "s", id: "permission" });
    assert.deepEqual(f.names(), ["PermissionRequested"]);
    assert.equal(Object.hasOwn(f.events[0].payload, "cwd"), false);
    await cleanup();
  }
});

await check("V2 duplicate instances claim emissions only once per host event", async () => {
  // OpenCode 2 instantiates the plugin per location and delivers the whole
  // stream to each instance; one host event must still sound exactly once.
  const streams = [];
  const broadcast = (event) => {
    for (const stream of streams) stream.push(event);
  };
  const makeStream = () => {
    const queue = [];
    const waiters = [];
    const stream = {
      [Symbol.asyncIterator]() { return this; },
      next() {
        return queue.length
          ? Promise.resolve({ value: queue.shift(), done: false })
          : new Promise((resolve) => waiters.push(resolve));
      },
      return() { return Promise.resolve({ done: true }); },
      push(event) {
        if (waiters.length) waiters.shift()({ value: event, done: false });
        else queue.push(event);
      },
    };
    streams.push(stream);
    return stream;
  };
  const shared = new Map();
  const dispatched = [];
  const instances = [];
  const promptHandlers = [];
  for (const directory of ["/fixture/v2-a", "/fixture/v2-b", "/fixture/v2-c"]) {
    const context = {
      location: { directory },
      event: { subscribe: (options) => makeStream() },
      session: {
        get: async () => ({ data: undefined }),
        hook: async (name, handler) => { if (name === "prompt") promptHandlers.push(handler); },
      },
    };
    instances.push(await module.default.setup(context, {
      dispatch: (name, payload) => dispatched.push({ name, payload }),
      clock: () => 1000,
      claims: shared,
    }));
  }
  broadcast({ type: "session.created", data: { sessionID: "s", slug: "x" } });
  for (const handler of promptHandlers) {
    await handler({ sessionID: "s", messageID: "prompt-1",
      parts: [{ type: "text", synthetic: false }] });
  }
  broadcast({ type: "session.execution.started", data: { sessionID: "s" } });
  broadcast({ type: "session.step.started", data: { sessionID: "s", assistantMessageID: "m" } });
  broadcast({ type: "session.execution.succeeded", data: { sessionID: "s" } });
  await settle();
  assert.deepEqual(dispatched.map((entry) => entry.name),
    ["UserTurnStarted", "ResponseCompleted"]);
  for (const cleanup of instances) await cleanup();
});

await check("V2 setup refuses to double-claim the same location and installation", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  const duplicate = await module.default.setup(f.context, {
    dispatch: () => { throw Error("duplicate"); }, claims: new Map(),
  });
  assert.deepEqual(duplicate, {});
  await f.sessionCreated();
  await f.admit();
  await f.startExecution();
  await f.step();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await cleanup();
});

await check("V2 cleanup stops subsequent emissions and releases the instance", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  await f.admit();
  await f.startExecution();
  await f.step();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
  await cleanup();
  await f.startExecution();
  await f.step();
  await f.succeeded();
  assert.deepEqual(f.names(), ["UserTurnStarted"]);
});

await check("V2 malformed event identities and shapes never emit", async () => {
  const f = v2Fixture();
  const cleanup = await f.setup();
  await f.sessionCreated();
  for (const id of [undefined, null, 1, "", "space id", "x".repeat(257), "bad\u202eid"]) {
    await f.emitEvent("permission.asked", { sessionID: "s", id });
    await f.emitEvent("permission.asked", { sessionID: id, id: "r" });
    await f.emitEvent("form.created", { form: { id, sessionID: "s" } });
  }
  await settle();
  assert.deepEqual(f.names(), []);
  await cleanup();
});

console.log(`OpenCode plugin: ${count} scenarios passed`);
