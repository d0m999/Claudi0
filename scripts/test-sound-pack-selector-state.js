#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const selectorState = require("../sound-pack-selector-state.js");

const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "sound-pack-selector.html"), "utf8");
const catalogSource = html.match(/const packs = \[([\s\S]*?)\n    \];/);
assert.ok(catalogSource, "selector pack catalog must remain readable");
const catalogIds = [...catalogSource[1].matchAll(/\n\s+id: "([a-z0-9-]+)"/g)]
  .map(match => match[1])
  .sort();
// packs/ contains optional, ignored local audio. The versioned license ledger owns the
// curated roster; a clean checkout must validate the same six candidates without that audio.
const licenses = fs.readFileSync(path.join(root, "packs/LICENSES.md"), "utf8");
const currentCandidates = licenses.split("## 重设计试听候选包：2026-09-02");
assert.equal(currentCandidates.length, 2, "current curated license roster must be identifiable");
const builtinIds = [...licenses.matchAll(/^## 内置包：([a-z0-9-]+)（/gm)]
  .map(match => match[1]);
const candidateIds = [...currentCandidates[1].matchAll(/^#{2,3} ([a-z0-9-]+)（/gm)]
  .map(match => match[1]);
const licensedPackIds = [...builtinIds, ...candidateIds].sort();
assert.ok(builtinIds.length > 0 && candidateIds.length > 0, "builtin and curated licenses are required");
assert.equal(new Set(licensedPackIds).size, licensedPackIds.length, "licensed IDs must be unique");
assert.deepEqual(catalogIds, licensedPackIds, "selector must exactly match the versioned curated license roster");
const bundled = JSON.parse(fs.readFileSync(path.join(root, "packs/bundled-pack-selection.json"), "utf8"));
assert.ok(bundled.selected_pack_ids.every(id => catalogIds.includes(id)), "selector must include every approved Factory Pack");
assert.match(html, /src="sound-pack-selector-state\.js"/);
assert.match(html, /selectorState\.changeBlindPack\(/);
assert.match(html, /selectorState\.replaceSelection\(/);
assert.match(html, /selectorState\.resolveStoredSelection\(/);

const known = ["minimal-chime", "night-console"];
const defaults = ["minimal-chime"];
assert.deepEqual(selectorState.resolveStoredSelection(null, known, defaults), defaults);
assert.deepEqual(selectorState.resolveStoredSelection([], known, defaults), []);
assert.deepEqual(
  selectorState.resolveStoredSelection(["night-console", "removed-pack"], known, defaults),
  ["night-console"]
);
assert.deepEqual(
  selectorState.resolveStoredSelection(["removed-pack"], known, defaults),
  defaults
);

const blindEffects = [];
const reset = selectorState.changeBlindPack("night-console", () => blindEffects.push("stop"));
assert.deepEqual(blindEffects, ["stop"]);
assert.deepEqual(
  { packId: reset.packId, round: reset.round, correct: reset.correct, total: reset.total },
  { packId: "night-console", round: null, correct: 0, total: 0 }
);

const replacementEffects = [];
let landedSelection = null;
selectorState.replaceSelection(new Set(["night-console"]), {
  stopAllAudio() { replacementEffects.push("stop"); },
  setSelection(value) {
    replacementEffects.push("set");
    landedSelection = value;
  },
  saveSelection() { replacementEffects.push("save"); },
  render() { replacementEffects.push("render"); }
});
assert.deepEqual(replacementEffects, ["stop", "set", "save", "render"]);
assert.deepEqual([...landedSelection], ["night-console"]);

console.log("✓ sound-pack selector executable state seam passed");
