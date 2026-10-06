#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const prototypePath = path.resolve(
  __dirname, "../designs/panel-and-settings/Panel and Settings Prototype.html"
);
const html = fs.readFileSync(prototypePath, "utf8");
const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
assert.equal(scripts.length, 1, "the prototype must expose its executable inline script");

function loadPrototype(search = "") {
  const timers = new Map();
  const deadlines = new Map();
  let clockTime = 0;
  const messages = [];
  let nextTimer = 0;
  const elements = new Map();
  let controls = [];
  const document = {
    getElementById(id) { return elements.get(id) || null; },
    querySelectorAll(selector) {
      if (selector === "[data-pane]") return [soundsPane];
      const attribute = selector.match(/^\[([\w-]+)\]$/);
      return attribute ? controls.filter(control => control.getAttribute(attribute[1]) !== null) : [];
    },
    querySelector(selector) { return selector === '[data-pane="sounds"]' ? soundsPane : null; },
    addEventListener() {}
  };
  function element(attributes = {}) {
    return {
      style: {},
      getAttribute(name) { return attributes[name] || null; },
      querySelector() { return null; },
      focus() { document.activeElement = this; },
      click() {
        assert.equal(typeof this.onclick, "function", "click must reach the prototype's binding");
        this.onclick();
      }
    };
  }
  for (const match of html.slice(0, scripts[0].index).matchAll(/\bid="([^"]+)"/g)) {
    elements.set(match[1], element());
  }
  const soundsPane = element({ "data-pane": "sounds" });
  const context = vm.createContext({
    document, location: { search }, URLSearchParams,
    setTimeout(callback, delay = 0) { const id = ++nextTimer; timers.set(id, callback); deadlines.set(id, clockTime + delay); return id; },
    clearTimeout(id) { timers.delete(id); deadlines.delete(id); },
    performance: { now() { return clockTime; } },
    requestAnimationFrame() { return 0; }, cancelAnimationFrame() {},
    queueMicrotask(callback) { callback(); },
    recordToast(message) { messages.push(message); }
  });
  // Execute the actual script, URL initializer and click bindings. Only visual rendering and
  // toast display are replaced; AI compilation, generation state and timers run unchanged.
  const source = scripts[0][1] + "\nfunction render() { bind(); }\n" +
    "function toast(message) { recordToast(message); }\n";
  new vm.Script(source, { filename: prototypePath }).runInContext(context, { timeout: 1000 });
  return {
    context, document, messages,
    mountControls(markup) {
      for (const control of controls) {
        const id = control.getAttribute("id");
        if (id) elements.delete(id);
      }
      controls = [...markup.matchAll(/<(?:button|select|input)\b([^>]*)>/g)].map(match => {
        const attributes = Object.fromEntries(
          [...match[1].matchAll(/([\w-]+)="([^"]*)"/g)].map(attribute => [attribute[1], attribute[2]])
        );
        const control = element(attributes);
        if (attributes.id) elements.set(attributes.id, control);
        return control;
      });
      context.bind();
    },
    advanceTime(milliseconds) {
      const end = clockTime + milliseconds;
      let remaining = 100;
      while (true) {
        const next = [...timers.keys()].filter(id => deadlines.get(id) <= end)
          .sort((a, b) => deadlines.get(a) - deadlines.get(b))[0];
        if (next === undefined) break;
        assert.ok(remaining-- > 0, "scheduled callbacks must terminate");
        clockTime = deadlines.get(next);
        const callback = timers.get(next);
        timers.delete(next); deadlines.delete(next); callback();
      }
      clockTime = end;
    },
    flushTimers() {
      let remaining = 100;
      while (timers.size) {
        assert.ok(remaining-- > 0, "prototype timers must terminate");
        const [id, callback] = timers.entries().next().value;
        timers.delete(id);
        callback();
      }
    }
  };
}

for (const lang of ["zh", "en"]) {
  test(`${lang}: notice ages floor minutes, hours and days`, () => {
    const { context } = loadPrototype();
    context.S.lang = lang;
    const examples = [
      [0.9, "<1分", "<1m"], [1.9, "1分", "1m"], [59.9, "59分", "59m"],
      [60, "1时", "1h"], [119.9, "1时", "1h"], [1439.9, "23时", "23h"],
      [1440, "1天", "1d"], [2879.9, "1天", "1d"], [2880, "2天", "2d"]
    ];
    for (const [minutes, zh, en] of examples) {
      assert.equal(context.t().age(minutes), lang === "zh" ? zh : en, `${minutes} minutes`);
    }
  });
}

for (const lang of ["zh", "en"]) {
  test(`${lang}: compact workspace panel keeps its settings route and preview help`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    const scope = context.GROUPS.find(g => g.kind === "ws");
    context.S.scope = scope.id;
    const before = JSON.stringify(context.GROUPS);
    const markup = context.panelHTML();
    assert.ok(!markup.includes(lang === "zh" ? "适用来源：" : "Applies to: "));
    assert.ok(markup.includes(lang === "zh" ? "工作区设置…" : "Workspace settings…"));
    assert.ok(markup.includes('title="' + (lang === "zh" ? "试听只验证" : "Preview checks")));
    runtime.mountControls(markup);
    document.getElementById("editWorkspaceBtn").click();
    assert.equal(context.S.pane, "groups");
    assert.equal(context.S.ws, scope.id);
    assert.equal(JSON.stringify(context.GROUPS), before);
    assert.ok(context.paneGroups().includes(lang === "zh" ? "适用来源" : "Applies to"));
  });
  test(`${lang}: panel activity is a static summary of shared event counts`, () => {
    const { context } = loadPrototype();
    context.S.lang = lang;
    context.S.usage.today.stopFailure = 100;
    let markup = context.panelHTML();
    const summary = markup.match(/<div class="activity-summary" id="activitySummary">([^<]*)<\/div>/)[1];
    assert.equal(summary, lang === "zh" ? "今日 112 次 · 近 7 日 84 次" : "112 today · 84 last 7 days");
    assert.ok(!/actBtn|activityContent|act-toggle|act-bar|act-legend/.test(markup));
    assert.ok(context.paneActivity().includes("100 / 4"), "event details stay available in Settings");
    context.S.usage.today = { taskStart: 0, stop: 0, stopFailure: 0, notification: 0, subagentStop: 0 };
    context.S.usage.week = { taskStart: 0, stop: 0, stopFailure: 0, notification: 0, subagentStop: 0 };
    markup = context.panelHTML();
    assert.ok(markup.includes(lang === "zh" ? "今日 0 次 · 近 7 日 0 次" : "0 today · 0 last 7 days"));
    assert.ok(!/NaN|undefined/.test(markup));
  });
  test(`${lang}: normal panel events omit technical metadata and retain actual preview sources`, () => {
    const runtime = loadPrototype();
    const { context, document, messages } = runtime;
    context.S.lang = lang;
    const group = context.curGroup(), pack = context.packById(group.pack), before = JSON.stringify(group);
    const markup = context.panelHTML();
    assert.ok(!/event-source-|preview-reason-|\.aiff|data-edit-sound/.test(markup));
    for (const event of context.EVENTS) {
      assert.ok(markup.includes(context.evName(event)));
      assert.ok(!markup.replace(/<[^>]*>/g, "").includes(event.token));
    }
    runtime.mountControls(markup);
    document.querySelectorAll("[data-listen]").find(button => button.getAttribute("data-listen") === "stop").click();
    assert.ok(messages.at(-1).includes(pack.files.stop), "preview still resolves the actual selected sound");
    assert.equal(JSON.stringify(group), before);
    context.S.soundPack = pack.id;
    assert.ok(context.paneSounds().includes(pack.files.stop), "file metadata remains in Sounds settings");
  });
  test(`${lang}: unavailable panel previews keep readable and accessible failure reasons`, () => {
    const { context } = loadPrototype();
    context.S.lang = lang;
    const group = context.curGroup(), pack = context.packById(group.pack);
    pack.files.stop = null;
    let markup = context.panelHTML();
    assert.ok(markup.includes('<span class="ev-reason" id="preview-reason-stop">' + (lang === "zh" ? "未映射" : "Not mapped") + '</span>'));
    assert.ok(/data-listen="stop" disabled aria-describedby="preview-reason-stop"/.test(markup));
    assert.ok(!/Configure sound|Choose a sound|设置声音/.test(markup));
    pack.files.stop = "stop.aiff"; group.volume = 0;
    markup = context.panelHTML();
    assert.ok(markup.includes(lang === "zh" ? "音量为零" : "volume is zero"));
    pack.broken = true;
    assert.ok(context.panelHTML().includes(lang === "zh" ? "声音包损坏" : "Pack damaged"));
  });
}

for (const lang of ["zh", "en"]) {
  test(`${lang}: reminder detail and empty list render complete localized text`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    runtime.mountControls(context.panelHTML());
    document.getElementById("needsBtn").click();
    runtime.mountControls(context.rowsHTML());
    document.querySelectorAll("[data-reminder]")[0].click();
    const detail = context.reminderDetailHTML();
    assert.ok(!detail.includes("undefined"));
    for (const value of ["claudi0", "a1b2c3d4-9f2e", "14:32",
      lang === "zh" ? "会话 ID" : "Session ID", lang === "zh" ? "发生时间" : "Occurred"]) {
      assert.ok(detail.includes(value), `missing reminder metadata: ${value}`);
    }
    context.REMINDERS.length = 0;
    const empty = context.rowsHTML();
    assert.ok(!empty.includes("undefined"));
    assert.ok(empty.includes(lang === "zh" ? "当前没有保留的待接手提醒" : "No attention reminders are currently retained."));
  });
}

for (const profile of ["elevenlabs-global", "minimax-global"]) {
  test(`${profile}: Chinese speech compiles from the Chinese interface`, () => {
    const { context } = loadPrototype();
    context.S.ai.profile = profile;
    const result = context.aiInterpret('说“你好”');
    assert.equal(result.error, undefined);
    assert.equal(result.modality, "speech");
    assert.equal(result.quoted, "你好");
  });
}

function openCredentialSheet(profile, status, lang = "zh") {
  const runtime = loadPrototype();
  const { context, document } = runtime;
  context.S.lang = lang;
  context.S.window = true;
  context.S.pane = "sounds";
  context.S.ai.profile = profile;
  context.S.ai.cred[profile] = status;
  context.S.ai.description = '说“你好”';
  runtime.mountControls(context.aiServiceCard());
  document.getElementById("aiManageKey").click();
  assert.equal(context.S.ai.sheet, "configure");
  runtime.mountControls(context.aiCredentialSheetHTML());
  return runtime;
}

for (const profile of ["qwen-singapore", "qwen-beijing"]) {
  for (const status of ["verified", "deferred", "rejected"]) {
    test(`${profile}/${status}: save replaces active through cancellable pending`, () => {
      const runtime = openCredentialSheet(profile, status);
      const { context, document } = runtime;
      const { S } = context;
      const credentialsBefore = JSON.stringify(S.ai.cred);
      const generationBefore = S.ai.generationID;
      document.getElementById("sheetSave").click();
      assert.equal(S.ai.activity, "pendingReplacement");
      runtime.flushTimers();
      assert.equal(S.ai.cred[profile], status, "saving a replacement preserves the active validation");
      assert.equal(S.ai.pendingReplacement[profile], true);
      assert.ok(context.aiCredentialStatusHTML(context.aiProfile()).includes(context.t().ai.pendingReplacement));
      assert.equal(S.ai.generationID, generationBefore, "saving does not start generation");
      assert.equal(S.ai.description, '说“你好”');
      assert.equal(JSON.stringify(S.ai.cred), credentialsBefore, "other profiles remain independent");
      runtime.mountControls(context.aiServiceCard());
      document.getElementById("aiCancelReplacement").click();
      assert.equal(S.ai.pendingReplacement[profile], undefined);
      assert.equal(S.ai.cred[profile], status, "cancel restores the same active validation");
    });
  }
  test(`${profile}: first save creates deferred active without pending`, () => {
    const runtime = openCredentialSheet(profile, "missing");
    const { context, document } = runtime;
    document.getElementById("sheetSave").click();
    assert.equal(context.S.ai.activity, "saving");
    runtime.flushTimers();
    assert.equal(context.S.ai.cred[profile], "deferred");
    assert.equal(context.S.ai.pendingReplacement[profile], undefined);
    assert.equal(context.S.ai.stage, "editing");
    assert.equal(context.S.ai.cands.length, 0);
  });
  for (const lang of ["zh", "en"]) {
    for (const status of ["verified", "deferred", "rejected"]) {
      test(`${lang}/${profile}/${status}: rejected pending generation keeps active and returns to editing`, () => {
        const runtime = openCredentialSheet(profile, status, lang);
        const { context, document } = runtime;
        const { S } = context;
        document.getElementById("sheetSave").click();
        runtime.flushTimers();
        assert.equal(S.ai.pendingReplacement[profile], true);
        S.soundPack = "my-pack";
        S.aiEvent = "notification";
        S.ai.injectFail = "credentialInvalid";
        const credentialsBefore = JSON.stringify(S.ai.cred);
        const packsBefore = JSON.stringify(context.PACKS);
        const event = context.EVENTS.find(candidate => candidate.id === S.aiEvent);
        runtime.mountControls(context.aiComposerHTML(context.packById(S.soundPack), event));
        document.getElementById("aiGenBtn").click();
        assert.equal(S.ai.stage, "generating");
        runtime.flushTimers();
        assert.equal(S.ai.stage, "editing");
        assert.equal(S.ai.failure, "credentialInvalid");
        assert.equal(S.ai.pendingReplacement[profile], undefined);
        assert.equal(JSON.stringify(S.ai.cred), credentialsBefore);
        assert.equal(JSON.stringify(context.PACKS), packsBefore);
        assert.equal(S.ai.description, '说“你好”');
        assert.equal(S.ai.cands.length, 0);
        assert.equal(S.ai.injectFail, null);
        assert.equal(runtime.messages.at(-1), context.t().ai.errors.credentialInvalid);
        assert.match(context.aiComposerHTML(context.packById(S.soundPack), event), /class="err-line" role="alert"/);
      });
    }
  }
  test(`${profile}: generation failures other than authentication keep pending`, () => {
    for (const failure of ["generation", "rateLimited", "credits", "audioInvalid", "noValidCandidates"]) {
      const runtime = openCredentialSheet(profile, "verified");
      const { context, document } = runtime;
      document.getElementById("sheetSave").click();
      runtime.flushTimers();
      context.S.soundPack = "my-pack";
      context.S.aiEvent = "notification";
      context.S.ai.injectFail = failure;
      context.aiGenerate();
      runtime.flushTimers();
      assert.equal(context.S.ai.stage, "editing");
      assert.equal(context.S.ai.failure, failure);
      assert.equal(context.S.ai.cred[profile], "verified");
      assert.equal(context.S.ai.pendingReplacement[profile], true, failure);
    }
  });
  test(`${profile}: authentication failure without pending rejects the attempted active`, () => {
    const runtime = loadPrototype();
    const { context } = runtime;
    context.S.window = true;
    context.S.pane = "sounds";
    context.S.soundPack = "my-pack";
    context.S.aiEvent = "notification";
    context.S.ai.profile = profile;
    context.S.ai.cred[profile] = "deferred";
    context.S.ai.description = '说“你好”';
    context.S.ai.injectFail = "credentialInvalid";
    context.aiGenerate();
    runtime.flushTimers();
    assert.equal(context.S.ai.stage, "editing");
    assert.equal(context.S.ai.failure, "credentialInvalid");
    assert.equal(context.S.ai.cred[profile], "rejected");
    assert.equal(context.S.ai.cands.length, 0);
  });
}

for (const profile of ["elevenlabs-global", "minimax-global", "senseaudio-cn"]) {
  test(`${profile}: successful probe replaces active without a deferred pending slot`, () => {
    const runtime = openCredentialSheet(profile, "verified");
    const { context, document } = runtime;
    document.getElementById("sheetSave").click();
    assert.equal(context.S.ai.activity, "probing");
    runtime.flushTimers();
    assert.equal(context.S.ai.cred[profile], "verified");
    assert.equal(context.S.ai.pendingReplacement[profile], undefined);
  });
  for (const lang of ["zh", "en"]) {
    test(`${lang}/${profile}: rejected replacement keeps old active and reports the attempt`, () => {
      const runtime = openCredentialSheet(profile, "verified", lang);
      const { context, document } = runtime;
      const { S } = context;
      const credentialsBefore = JSON.stringify(S.ai.cred);
      S.ai.injectFail = "credentialInvalid";
      document.getElementById("sheetSave").click();
      runtime.flushTimers();
      assert.equal(S.ai.cred[profile], "verified");
      assert.equal(JSON.stringify(S.ai.cred), credentialsBefore);
      assert.equal(S.ai.injectFail, null);
      assert.equal(S.ai.activity, null);
      assert.equal(S.ai.pendingReplacement[profile], undefined);
      assert.equal(runtime.messages.at(-1), context.t().ai.errors.credentialInvalid);
      assert.equal(S.ai.credentialFailure?.[profile], "credentialInvalid");
      const serviceCard = context.aiServiceCard();
      assert.match(serviceCard, /class="err-line" role="alert"/);
      assert.ok(serviceCard.includes(context.t().ai.errors.credentialInvalid));
      assert.ok(context.aiCredentialStatusHTML(context.aiProfile()).includes(context.t().ai.storedVerified));
      assert.equal(S.ai.description, '说“你好”');
      const otherProfile = profile === "elevenlabs-global" ? "minimax-global" : "elevenlabs-global";
      S.ai.profile = otherProfile;
      assert.equal(S.ai.credentialFailure[otherProfile], undefined);
      assert.ok(!context.aiServiceCard().includes(context.t().ai.errors.credentialInvalid));
      S.ai.profile = profile;
      assert.ok(context.aiServiceCard().includes(context.t().ai.errors.credentialInvalid));
      S.lang = lang === "zh" ? "en" : "zh";
      assert.ok(context.aiServiceCard().includes(context.t().ai.errors.credentialInvalid), "stored error reprojects with UI language");
      runtime.mountControls(context.aiServiceCard());
      document.getElementById("aiManageKey").click();
      runtime.mountControls(context.aiCredentialSheetHTML());
      document.getElementById("sheetSave").click();
      assert.equal(S.ai.credentialFailure[profile], undefined, "retry clears the previous attempt error");
      runtime.flushTimers();
      assert.equal(S.ai.cred[profile], "verified");
      assert.equal(S.ai.credentialFailure[profile], undefined);
      assert.ok(!context.aiServiceCard().includes(context.t().ai.errors.credentialInvalid));
    });
  }
  test(`${profile}: failed first probe leaves credential missing`, () => {
    const runtime = openCredentialSheet(profile, "missing");
    const { context, document } = runtime;
    context.S.ai.injectFail = "credentialInvalid";
    document.getElementById("sheetSave").click();
    runtime.flushTimers();
    assert.equal(context.S.ai.cred[profile], "missing");
    assert.equal(runtime.messages.at(-1), context.t().ai.errors.credentialInvalid);
    assert.equal(context.S.ai.credentialFailure?.[profile], "credentialInvalid");
    assert.match(context.aiServiceCard(), /class="err-line" role="alert"/);
  });
}

test("switching English back to the simulated system language reprojects Chinese", () => {
  const runtime = loadPrototype();
  const { context, document } = runtime;
  const { S } = context;
  S.window = true;
  S.pane = "general";
  const credentialsBefore = JSON.stringify(S.ai.cred);
  const packsBefore = JSON.stringify(context.PACKS);
  const clickOption = (attribute, value) => {
    runtime.mountControls(context.paneGeneral());
    const control = document.querySelectorAll(`[${attribute}]`)
      .find(candidate => candidate.getAttribute(attribute) === value);
    assert.ok(control, "the language option must exist in the actual General pane markup");
    control.click();
  };
  clickOption("data-langmode", "manual");
  clickOption("data-lang-set", "en");
  assert.equal(S.lang, "en");
  assert.ok(context.paneGeneral().includes("UI language"));
  clickOption("data-langmode", "system");
  assert.equal(S.prefs.langMode, "system");
  assert.equal(S.lang, "zh");
  assert.equal(document.getElementById("langBtn").textContent, "中文");
  assert.ok(context.paneGeneral().includes('当前语言</span><span class="tagline">简体中文'));
  assert.ok(context.sideHTML().includes("通用"));
  assert.equal(JSON.stringify(S.ai.cred), credentialsBefore);
  assert.equal(JSON.stringify(context.PACKS), packsBefore);
});

test("language matching normalizes both sides without broadening exact tags", () => {
  const { context } = loadPrototype();
  for (const tag of ["zh-Hans", "zh-hans", "ZH-HANS"]) {
    assert.equal(context.aiLocaleSupported(["zh-Hans"], tag), true, tag);
    assert.equal(context.aiLocaleSupported(["ZH-HANS"], tag), true, tag);
  }
  for (const tag of ["zh-Hans-CN", "zh_Hans", "en"]) {
    assert.equal(context.aiLocaleSupported(["zh-Hans"], tag), false, tag);
  }
  for (const tag of ["zh", "ZH-HANS", "zh_Hans"]) {
    assert.equal(context.aiLocaleSupported(["ZH*"], tag), true, tag);
  }
  assert.equal(context.aiLocaleSupported(["zh*"], "zhuang"), false);
});

const profiles = ["elevenlabs-global", "minimax-global", "qwen-singapore", "qwen-beijing", "senseaudio-cn"];
for (const lang of ["zh", "en"]) {
  for (const profile of profiles) {
    for (const scene of ["candidates", "generating", "applied"]) {
      test(`${lang}/${profile}: ${scene} URL initializes safely`, () => {
        const query = new URLSearchParams({ win: "1", pane: "sounds", ai: scene, aiProfile: profile, lang });
        const { context } = loadPrototype(`?${query}`);
        const { S } = context;
        assert.equal(S.window, true);
        assert.equal(S.pane, "sounds");
        assert.equal(S.ai.profile, profile);
        assert.equal(S.aiEvent, "notification");
        const interpreted = context.aiInterpret(S.ai.description);
        if (lang === "en" && profile === "minimax-global") {
          assert.equal(interpreted.error, "unsupportedLocale");
          assert.equal(S.ai.failure, "unsupportedLocale");
          assert.equal(S.ai.stage, "editing");
          assert.equal(S.ai.cands.length, 0);
          assert.equal(S.ai.lastFile, null);
          assert.equal(S.ai.cred[profile], "missing", "compile failure must precede credential handling");
          assert.ok(S.ai.description.length > 0, "compile failure keeps the description");
          return;
        }
        assert.equal(interpreted.error, undefined);
        assert.equal(S.ai.modality, interpreted.modality);
        const policy = context.aiRoutePolicy(context.aiProfile(), S.ai.modality);
        assert.ok(policy, "the selected modality must have a real profile route");
        assert.equal(S.ai.stage, scene);
        assert.equal(S.ai.failure, null);
        assert.equal(S.ai.cands.length, 3);
        assert.equal(S.ai.cands[0].label, context.aiCandidateLabel(policy.kind, 1));
        assert.equal(S.ai.lastFile !== null, scene === "applied");
      });
    }
  }
}

test("partial URL candidates follow the SenseAudio SFX route policy", () => {
  const { context } = loadPrototype("?win=1&pane=sounds&ai=candidates&aiProfile=senseaudio-cn&aiPartial=1");
  assert.equal(context.S.ai.modality, "soundEffect");
  assert.equal(context.S.ai.cands.length, 2);
});

for (const lang of ["zh", "en"]) {
  test(`${lang}: failure control reaches generation failure and explicit retry`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    const { S } = context;
    S.lang = lang;
    S.window = true;
    S.pane = "sounds";
    S.soundPack = "my-pack";
    S.aiEvent = "notification";
    S.ai.description = lang === "zh" ? "一声清脆的木琴提示音" : "A crisp short click";
    const description = S.ai.description;
    const packsBefore = JSON.stringify(context.PACKS);
    for (let i = 0; i < 3; i++) document.getElementById("aiFailBtn").click();
    assert.equal(S.ai.injectFail, "generation");
    context.aiGenerate();
    assert.equal(S.ai.stage, "generating");
    runtime.flushTimers();
    assert.equal(S.ai.stage, "editing");
    assert.equal(S.ai.failure, "generation");
    assert.equal(S.ai.description, description);
    assert.equal(S.ai.cands.length, 0);
    assert.equal(S.ai.injectFail, null);
    assert.equal(runtime.messages.at(-1), context.t().ai.errors.generation);
    assert.equal(JSON.stringify(context.PACKS), packsBefore, "failure must preserve the pack's sounds");
    context.aiGenerate();
    runtime.flushTimers();
    assert.equal(S.ai.stage, "candidates");
    assert.equal(S.ai.failure, null);
    assert.equal(S.ai.description, description);
    assert.equal(S.ai.cands.length, 3);
  });
}


for (const lang of ["zh", "en"]) {
  test(`${lang}: integrated pack controls hide generation for factory packs`, () => {
    const { context } = loadPrototype();
    context.S.lang = lang;
    context.S.soundPack = "minimal-chime";
    assert.ok(!context.paneSounds().includes("data-aiev="));
    context.S.soundPack = "my-pack";
    assert.equal([...context.paneSounds().matchAll(/<button\b[^>]*data-aiev=/g)].length, 5);
    assert.ok(!context.paneSounds().includes("提示音组"));
    assert.ok(!context.paneSounds().includes("cue pack"));
  });
  test(`${lang}: workspace sound editing returns without changing group settings`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    context.S.window = true;
    context.S.pane = "groups";
    const scope = context.GROUPS.find(g => g.kind === "ws");
    context.S.ws = scope.id;
    scope.pack = "my-pack";
    scope.volume = 37;
    scope.events.notification = false;
    const before = JSON.stringify(context.GROUPS);
    runtime.mountControls(context.paneGroups());
    document.querySelectorAll("[data-group-edit-sound]").find(b => b.getAttribute("data-group-edit-sound") === "notification").click();
    assert.equal(context.S.pane, "sounds");
    assert.equal(context.S.soundPack, "my-pack");
    assert.equal(context.S.aiEvent, null, "editing a sound must not start AI generation");
    runtime.mountControls(context.paneSounds());
    document.getElementById("backToWorkspace").click();
    assert.equal(context.S.pane, "groups");
    assert.equal(context.S.ws, scope.id);
    assert.equal(JSON.stringify(context.GROUPS), before);
    assert.equal(context.workspaceSoundReturn, null);
  });
}

test("native workspace selector rejects missing targets and selects an existing scope", () => {
  const runtime = loadPrototype();
  const { context, document } = runtime;
  context.S.pane = "groups";
  runtime.mountControls(context.paneGroups());
  const selector = document.getElementById("redesignWorkspace");
  const previous = context.S.ws;
  selector.value = "missing-workspace";
  selector.onchange();
  assert.equal(context.S.ws, previous);
  const target = context.GROUPS.find(g => g.id !== previous).id;
  selector.value = target;
  selector.onchange();
  assert.equal(context.S.ws, target);
});

test("native pack selector preserves current composer on no-op and cancels stale generation when switching", () => {
  const runtime = loadPrototype();
  const { context, document } = runtime;
  context.S.pane = "sounds";
  context.S.soundPack = "my-pack";
  context.S.aiEvent = "notification";
  context.S.ai.description = "A crisp short click";
  context.aiGenerate();
  assert.equal(context.S.ai.stage, "generating");
  runtime.mountControls(context.paneSounds());
  const selector = document.getElementById("redesignPack");
  selector.value = "my-pack";
  selector.onchange();
  assert.equal(context.S.ai.stage, "generating");
  selector.value = "missing-pack";
  selector.onchange();
  assert.equal(context.S.soundPack, "my-pack");
  selector.value = "minimal-chime";
  selector.onchange();
  runtime.flushTimers();
  assert.equal(context.S.soundPack, "minimal-chime");
  assert.equal(context.S.aiEvent, null);
  assert.equal(context.S.ai.cands.length, 0);
});

test("return to a deleted workspace keeps a valid current scope", () => {
  const { context } = loadPrototype();
  context.S.pane = "groups";
  const target = context.GROUPS.find(g => g.kind === "ws").id;
  context.openWorkspaceSound(target, "stop");
  context.GROUPS = context.GROUPS.filter(g => g.id !== target);
  context.S.ws = context.GROUPS[0].id;
  context.returnToWorkspace();
  assert.equal(context.S.pane, "groups");
  assert.ok(context.groupById(context.S.ws));
  assert.equal(context.workspaceSoundReturn, null);
});


for (const lang of ["zh", "en"]) {
  test(`${lang}: regrouped notifications preserve all preferences and current quiet facts`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    context.S.pane = "notifications";
    context.S.system.focusActive = true;
    context.S.system.calendarBusy = true;
    const profiles = JSON.stringify(context.GROUPS);
    runtime.mountControls(context.paneNotifications());
    const toggles = document.querySelectorAll("[data-pref]");
    assert.deepEqual(toggles.map(b => b.getAttribute("data-pref")).sort(), ["bannerOn", "calendar", "focusEnabled", "quietOnLock"]);
    const focus = toggles.find(b => b.getAttribute("data-pref") === "focusEnabled");
    const calendar = toggles.find(b => b.getAttribute("data-pref") === "calendar");
    focus.click();
    assert.equal(context.S.prefs.quiet.reasonKey, "focusActive");
    calendar.click();
    assert.equal(context.S.prefs.quiet.reasonKey, "focusAndCalendarBusy");
    context.S.prefs.focusAuth = "denied";
    context.paneNotifications();
    assert.equal(context.S.prefs.quiet.reasonKey, "calendarBusy");
    calendar.click();
    assert.equal(context.S.prefs.quiet.on, false);
    assert.equal(JSON.stringify(context.GROUPS), profiles);
    assert.equal(typeof document.getElementById("focusBtn").onclick, "function");
  });
}


for (const lang of ["zh", "en"]) {
  test(`${lang}: banners have one direct action and no detail or technical metadata`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    context.S.bannerReminderID = context.REMINDERS[0].id;
    context.showBanner(true);
    const markup = context.bannerHTML();
    assert.ok(markup.includes('data-banner-body="1"'));
    assert.ok(!markup.includes('<div class="cap-text">'));
    assert.ok(!markup.includes("aria-expanded"));
    assert.ok(!markup.includes("bannerDetails"));
    assert.ok(!markup.includes("data-copysession"));
    assert.ok(!markup.includes(context.REMINDERS[0].session));
    runtime.mountControls(markup);
    assert.equal(document.querySelectorAll("[id]").length, 3);
    const before = JSON.stringify(context.REMINDERS);
    document.getElementById("bannerAct-1").click();
    assert.equal(context.S.banners[0].failure, "started");
    runtime.advanceTime(450);
    assert.equal(context.S.banners.length, 1);
    assert.equal(context.S.banners[0].failure, "fallback");
    assert.equal(JSON.stringify(context.REMINDERS), before);
    assert.ok(context.paneActivity().includes(context.REMINDERS[0].session));
  });
  test(`${lang}: banner failure stays inline and a retry retains the reminder`, () => {
    const runtime = loadPrototype();
    const { context, document } = runtime;
    context.S.lang = lang;
    context.S.bannerReminderID = context.REMINDERS[0].id;
    context.showBanner(true);
    context.S.bannerInjectFailure = true;
    const serial = context.S.bannerSerial;
    const before = JSON.stringify(context.REMINDERS);
    runtime.mountControls(context.bannerHTML());
    document.getElementById("bannerAct-1").click();
    assert.equal(context.S.banners.length, 1);
    assert.equal(context.S.banners[0].failure, "started");
    runtime.advanceTime(450);
    assert.equal(context.S.banners[0].failure, "unavailable");
    assert.equal(context.S.bannerSerial, serial);
    assert.ok(context.bannerHTML().includes('role="alert"'));
    assert.ok(context.bannerHTML().includes(lang === "zh" ? "重试" : "Retry"));
    runtime.mountControls(context.bannerHTML());
    document.getElementById("bannerAct-1").click();
    runtime.advanceTime(450);
    assert.equal(context.S.banners.length, 1);
    assert.equal(context.S.banners[0].failure, "fallback");
    assert.equal(JSON.stringify(context.REMINDERS), before);
  });
  test(`${lang}: missing or changed banner targets cannot open a different reminder`, () => {
    const runtime = loadPrototype();
    const { context } = runtime;
    context.S.lang = lang;
    context.S.bannerReminderID = context.REMINDERS[0].id;
    context.showBanner(true);
    context.S.banners[0].reminderID = "missing-reminder";
    const before = JSON.stringify(context.REMINDERS);
    context.openBannerSource();
    assert.equal(context.S.banners[0].failure, "stale");
    assert.equal(runtime.messages.length, 0);
    assert.ok(!context.bannerHTML().includes('data-banner-action='));
    context.S.banners[0].reminderID = context.REMINDERS[0].id;
    context.REMINDERS[0].updated = true;
    context.openBannerSource();
    assert.equal(runtime.messages.length, 0);
    assert.match(context.bannerHTML(), /data-banner-action="1" disabled/);
    delete context.REMINDERS[0].updated;
    assert.equal(JSON.stringify(context.REMINDERS), before);
  });
}

test("banner reading budget survives redraw and combined hover/focus pauses; expiry retains reminders", () => {
  const runtime = loadPrototype();
  const { context } = runtime;
  context.S.bannerReminderID = context.REMINDERS[0].id;
  context.showBanner(true);
  const before = JSON.stringify(context.REMINDERS);
  const node = { matches() { return false; }, contains() { return false; }, addEventListener() {}, querySelector() { return null; } };
  const clock = context.createNoticeClock(1);
  clock.sync(node, "atn:1");
  runtime.advanceTime(1000);
  assert.equal(clock.left(), 3000);
  clock.sync(node, "atn:1");
  assert.equal(clock.left(), 3000, "redraw cannot grant another four seconds");
  clock.pause("hover", true);
  clock.pause("focus", true);
  runtime.advanceTime(10000);
  clock.pause("hover", false);
  runtime.advanceTime(10000);
  assert.equal(clock.left(), 3000);
  clock.pause("focus", false);
  runtime.advanceTime(2999);
  assert.equal(context.S.banners.length, 1);
  runtime.advanceTime(1);
  assert.equal(context.S.banners.length, 0);
  assert.equal(JSON.stringify(context.REMINDERS), before);
});

test("informational banners have a close action and reading track without an extra primary button", () => {
  const runtime = loadPrototype();
  const { context, document } = runtime;
  context.S.bannerEvent = "stop";
  context.showBanner(false);
  const markup = context.bannerHTML();
  assert.ok(markup.includes('class="track"'));
  assert.ok(!markup.includes('data-banner-action='));
  assert.ok(!markup.includes("aria-expanded"));
  runtime.mountControls(markup);
  document.getElementById("bannerClose-1").click();
  assert.equal(context.S.banners.length, 0);
});

// Whole-pack import was removed from the confirmed integrated prototype. Audio import in the
// native event editor is a different capability and remains available.
test("whole-pack import has no control, confirmation, demo creation or event binding", () => {
  assert.doesNotMatch(html, /importPack|data-import-pack|导入声音包|Import sound pack/);
});

for (const outcome of ["exact", "requested", "fallback", "failed"]) {
  test(`banner body shares navigation action: ${outcome}`, () => {
    const runtime = loadPrototype(); const { context, document } = runtime;
    context.S.bannerReminderID = context.REMINDERS[0].id; context.showBanner(true);
    context.S.bannerNavigationOutcome = outcome;
    const count = context.REMINDERS.length;
    runtime.mountControls(context.bannerHTML());
    document.getElementById("bannerBody-1").click();
    document.getElementById("bannerAct-1").click();
    assert.equal(context.S.banners[0].failure, "started"); runtime.advanceTime(450);
    assert.equal(context.REMINDERS.length, count - (outcome === "exact" ? 1 : 0));
    assert.equal(context.S.banners.length, outcome === "exact" ? 0 : 1);
  });
}
test("ordinary body is clickable and close invalidates an in-flight jump", () => {
  const runtime = loadPrototype(); const { context, document } = runtime;
  context.showBanner(false); context.S.bannerNavigationOutcome = "exact";
  runtime.mountControls(context.bannerHTML()); document.getElementById("bannerBody-1").click();
  document.getElementById("bannerClose-1").click(); runtime.advanceTime(450);
  assert.equal(context.S.banners.length, 0); assert.equal(runtime.messages.length, 0);
});

for (const lang of ["zh", "en"]) {
  test(`${lang}: ABC retain distinct content and actions; overflow waits in arrival order`, () => {
    const runtime = loadPrototype(); const { context, document } = runtime;
    context.S.lang = lang;
    document.getElementById("btnBannerBurst").click();
    assert.deepEqual(Array.from(context.S.banners, x => x.event), ["stop", "subagent", "permission"]);
    assert.deepEqual(Array.from(context.S.banners, x => x.project), ["claudi0", "api-gateway", "web-dashboard"]);
    const markup = context.bannerStackHTML(); runtime.mountControls(markup);
    assert.equal(document.querySelectorAll("[data-banner-body]").length, 3);
    assert.equal(document.querySelectorAll("[data-banner-close]").length, 3);
    assert.equal(document.querySelectorAll("[data-banner-action]").length, 1);
    document.getElementById("btnBannerMore").click();
    assert.deepEqual(Array.from(context.S.bannerQueue, x => x.id), [4, 5, 6]);
    context.closeBanner(2);
    assert.deepEqual(Array.from(context.S.banners, x => x.id), [1, 3, 4]);
    assert.deepEqual(Array.from(context.S.bannerQueue, x => x.id), [5, 6]);
    assert.ok(context.bannerStackHTML().includes(lang === "zh" ? "还有 2 条" : "2 more"));
  });
}

test("queued events receive four seconds only after becoming visible; stack pauses overlap", () => {
  const runtime = loadPrototype(); const { context } = runtime;
  context.showNoticeBurst(false); context.showNoticeBurst(false);
  const root = { matches() { return false; }, contains() { return false; }, addEventListener() {} };
  context.NoticeClock.sync(root, false);
  runtime.advanceTime(1000);
  assert.equal(context.NoticeClock.clocks.get(1).left(), 3000);
  assert.equal(context.NoticeClock.clocks.has(4), false);
  context.NoticeClock.pause("hover", true); context.NoticeClock.pause("focus", true);
  runtime.advanceTime(10000); context.NoticeClock.pause("hover", false); runtime.advanceTime(10000);
  assert.equal(context.NoticeClock.clocks.get(2).left(), 3000);
  context.closeBanner(1); context.NoticeClock.sync(root, false);
  assert.equal(context.NoticeClock.clocks.get(4).left(), 4000);
  assert.equal(context.NoticeClock.clocks.get(4).pauses.has("focus"), false, "sync samples actual focus ownership");
  context.NoticeClock.pause("hover", true);
  context.NoticeClock.sync(root, false);
  assert.equal(context.NoticeClock.clocks.get(2).left(), 3000, "redraw keeps the surviving budget");
});

test("closing one banner cancels only its navigation; a later request cancels an earlier request", () => {
  const runtime = loadPrototype(); const { context } = runtime;
  context.showNoticeBurst(false); const retained = JSON.stringify(context.REMINDERS);
  const reminderID = context.S.banners.find(x => x.id === 3).reminderID;
  context.S.bannerNavigationOutcome = "fallback";
  context.openBannerSource(3); context.closeBanner(1); runtime.advanceTime(450);
  assert.equal(context.S.banners.find(x => x.id === 3).failure, "fallback");
  assert.equal(JSON.stringify(context.REMINDERS), retained);
  context.S.bannerNavigationOutcome = "exact"; context.openBannerSource(2); context.openBannerSource(3);
  runtime.advanceTime(450);
  assert.deepEqual(Array.from(context.S.banners, x => x.id), [2]);
  assert.equal(context.REMINDERS.some(x => x.id === reminderID), false);
});

test("closing all clears the queue and a full bounded queue reports overflow", () => {
  const { context, messages } = loadPrototype();
  for (let i = 0; i < 51; i++) context.showNoticeScene("stop");
  assert.equal(context.S.banners.length, 3); assert.equal(context.S.bannerQueue.length, 47);
  assert.equal(messages.length, 1);
  context.closeBanner();
  assert.equal(context.S.banners.length + context.S.bannerQueue.length, 0);
});

for (const admission of ["full", "disabled"]) {
  test(`${admission}: distinct attention reminders survive rejected banner admission`, () => {
    const { context } = loadPrototype();
    if (admission === "full") {
      for (let i = 0; i < 50; i++) context.showNoticeScene("stop");
    } else context.S.prefs.bannerOn = false;
    const retained = JSON.stringify(context.REMINDERS);
    const banners = JSON.stringify([context.S.banners, context.S.bannerQueue]);
    const sources = [
      { host: "Codex", project: "api-gateway" },
      { host: "Claude Code", project: "web-dashboard" }
    ];
    for (const source of sources) context.showNoticeScene("permission", source);
    const added = context.REMINDERS.slice(0, 2);
    assert.equal(JSON.stringify(context.REMINDERS.slice(2)), retained, "both reminders retained without replacing older ones");
    assert.equal(new Set(added.map(r => r.id)).size, 2, "each arriving attention signal has its own identity");
    assert.deepEqual(Array.from(added, r => ({ host: r.host, project: r.proj })), sources.slice().reverse());
    assert.equal(JSON.stringify([context.S.banners, context.S.bannerQueue]), banners, "rejected banners leave the display queue unchanged");
  });
}
