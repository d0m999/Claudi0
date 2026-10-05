import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../integrations/opencode/claudio.js", import.meta.url), "utf8");
const installation = { helper_path: "/fixture/.claudio/bin/claudio",
  installation_id: "11111111-2222-4333-8444-555555555555",
  enabled_events: ["UserTurnStarted", "ResponseCompleted", "ResponseFailed", "PermissionRequested",
    "QuestionAsked", "SubagentCompleted"] };
const module = await import("data:text/javascript;base64," +
  Buffer.from("const installation = " + JSON.stringify(installation) + ";\n" + source).toString("base64"));
assert.equal(module.id, "claudio.opencode.v1");
assert.equal(typeof module.server, "function");
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
  const hooks = await module.server(context, { dispatch: (name, payload) => events.push({ name, payload }),
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

console.log(`OpenCode plugin: ${count} scenarios passed`);
