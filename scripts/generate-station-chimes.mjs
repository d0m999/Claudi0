#!/usr/bin/env node
// Generates original CC0 station-notification sounds in the style of
// Audition variants use <style>-<segment>.wav with Melody / Door Chime /
// Ambience / Announcement segments.
//
// All melodies here are original inventions. They imitate the *format* of
// Japanese station chimes (note count, contour, bell timbre, segment roles)
// without reproducing any railway's copyrighted melody.

import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const SR = 44100;
const PREVIEW_OUT = fileURLToPath(new URL("../pack-drafts/station-chimes/", import.meta.url));
const PACK_OUT = fileURLToPath(new URL("../packs/station-chimes/", import.meta.url));

// ---------- utilities ----------

const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// note name -> frequency, supports e.g. "C#5"
const SEMI = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
function freq(note) {
  const m = /^([A-G])([#b]?)(-?\d)$/.exec(note);
  if (!m) throw new Error("bad note " + note);
  let s = SEMI[m[1]];
  if (m[2] === "#") s += 1;
  if (m[2] === "b") s -= 1;
  const midi = s + (Number(m[3]) + 1) * 12;
  return 440 * Math.pow(2, (midi - 69) / 12);
}

// One-pole low pass
function lowpass(input, cutoff) {
  const out = new Float64Array(input.length);
  const a = Math.exp((-2 * Math.PI * cutoff) / SR);
  let z = 0;
  for (let i = 0; i < input.length; i++) {
    z = input[i] * (1 - a) + z * a;
    out[i] = z;
  }
  return out;
}

// One-pole high pass (applied twice for 12 dB/oct)
function highpass(input, cutoff) {
  let x = lowpass(input, cutoff);
  const out = new Float64Array(input.length);
  for (let i = 0; i < input.length; i++) out[i] = input[i] - x[i];
  return out;
}

function normalize(buf, peak = 0.89) {
  let m = 0;
  for (let i = 0; i < buf.length; i++) m = Math.max(m, Math.abs(buf[i]));
  if (m < 1e-9) return buf;
  const g = peak / m;
  for (let i = 0; i < buf.length; i++) buf[i] *= g;
  return buf;
}

function fadeEdges(buf, ms = 6) {
  const n = Math.min(buf.length, Math.round((SR * ms) / 1000));
  for (let i = 0; i < n; i++) {
    const g = i / n;
    buf[i] *= g;
    buf[buf.length - 1 - i] *= g;
  }
  return buf;
}

function eventExcerpt(samples, seconds, peakDb) {
  const count = Math.round(SR * seconds);
  if (samples.length < count) throw new Error("event excerpt exceeds source length");
  const out = samples.slice(0, count);
  const fadeIn = Math.round(SR * 0.008);
  const fadeOut = Math.round(SR * 0.030);
  for (let i = 0; i < fadeIn; i++) out[i] *= i / (fadeIn - 1);
  for (let i = 0; i < fadeOut; i++) {
    out[count - fadeOut + i] *= (fadeOut - 1 - i) / (fadeOut - 1);
  }
  return normalize(out, Math.pow(10, peakDb / 20));
}

function writeWav(path, samples) {
  const n = samples.length;
  const bytes = Buffer.alloc(44 + n * 2);
  bytes.write("RIFF", 0);
  bytes.writeUInt32LE(36 + n * 2, 4);
  bytes.write("WAVE", 8);
  bytes.write("fmt ", 12);
  bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20); // PCM
  bytes.writeUInt16LE(1, 22); // mono
  bytes.writeUInt32LE(SR, 24);
  bytes.writeUInt32LE(SR * 2, 28);
  bytes.writeUInt16LE(2, 32);
  bytes.writeUInt16LE(16, 34);
  bytes.write("data", 36);
  bytes.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = clamp(samples[i], -1, 1);
    bytes.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  writeFileSync(path, bytes);
}

// ---------- synthesis primitives ----------

// Struck-bell / chimes FM-ish tone with inharmonic partials.
function addBell(out, startSec, f, dur, gain, partials, decay) {
  const start = Math.round(startSec * SR);
  const len = Math.round(dur * SR);
  for (let i = 0; i < len; i++) {
    const idx = start + i;
    if (idx < 0 || idx >= out.length) continue;
    const t = i / SR;
    let s = 0;
    for (let p = 0; p < partials.length; p++) {
      const [ratio, amp] = partials[p];
      // higher partials die faster
      s += amp * Math.sin(2 * Math.PI * f * ratio * t) * Math.exp(-t * decay * (1 + p * 0.55));
    }
    // soft 2.5 ms attack
    const atk = clamp(t / 0.0025, 0, 1);
    out[idx] += s * atk * gain * Math.exp(-t * 0.35);
  }
}

// Simple decaying sine (organ-ish / flute-ish, for melodic lines)
function addTone(out, startSec, f, dur, gain, opts = {}) {
  const { attack = 0.012, decay = 1.6, vib = 0, vibHz = 5, harm = 0.18 } = opts;
  const start = Math.round(startSec * SR);
  const len = Math.round(dur * SR);
  for (let i = 0; i < len; i++) {
    const idx = start + i;
    if (idx < 0 || idx >= out.length) continue;
    const t = i / SR;
    const vibMul = 1 + vib * Math.sin(2 * Math.PI * vibHz * t);
    const fv = f * vibMul;
    const s =
      Math.sin(2 * Math.PI * fv * t) +
      harm * Math.sin(2 * Math.PI * fv * 2 * t) +
      harm * 0.4 * Math.sin(2 * Math.PI * fv * 3 * t);
    const env = Math.min(1, t / attack) * Math.exp(-t * decay);
    out[idx] += s * env * gain;
  }
}

// ---- 16 CC0 station-chime styles ----
// `chime` is the characteristic station door/arrival chime.
// `melody` is the departure melody. All melodies are original inventions.

export const STYLES = [
  {
    id: "rapid-5note-ascending",
    label: "Rapid 5-Note Ascending",
    note: "JR-style rapid line, bright and forward-leaning",
    chime: [["C#6", 0.0], ["E6", 0.16], ["C#6", 0.32]],
    melody: [["G4", 0.0, 0.3], ["C5", 0.3, 0.3], ["E5", 0.6, 0.3], ["G5", 0.9, 0.45], ["C6", 1.35, 1.5]],
  },
  {
    id: "suburb-3note-descending",
    label: "Suburban 3-Note Descending",
    note: "Private-railway suburban feel, short and calm",
    chime: [["A5", 0.0], ["G5", 0.18], ["E5", 0.36]],
    melody: [["E5", 0.0, 0.28], ["C5", 0.28, 0.28], ["G4", 0.56, 1.3]],
  },
  {
    id: "subway-4note-ascending",
    label: "Subway 4-Note Ascending",
    note: "Metro line, clean and orderly",
    chime: [["D6", 0.0], ["F#6", 0.15], ["D6", 0.3]],
    melody: [["D5", 0.0, 0.26], ["F#5", 0.26, 0.26], ["A5", 0.52, 0.26], ["D6", 0.78, 1.2]],
  },
  {
    id: "subway-7note-flowing",
    label: "Subway 7-Note Flowing",
    note: "Long multi-stop line, a longer melodic phrase",
    chime: [["A5", 0.0], ["C#6", 0.14], ["A5", 0.28]],
    melody: [
      ["D5", 0.0, 0.24], ["F#5", 0.24, 0.24], ["A5", 0.48, 0.24], ["B5", 0.72, 0.24],
      ["A5", 0.96, 0.24], ["F#5", 1.2, 0.24], ["D5", 1.44, 1.2],
    ],
  },
  {
    id: "loop-5note-descending",
    label: "Loop 5-Note Descending",
    note: "Loop-line flavour, descending and resolved",
    chime: [["G5", 0.0], ["E5", 0.16], ["C5", 0.32]],
    melody: [["C6", 0.0, 0.3], ["B5", 0.3, 0.3], ["A5", 0.6, 0.3], ["F5", 0.9, 0.3], ["C5", 1.2, 1.5]],
  },
  {
    id: "tram-3note-bright",
    label: "Tram 3-Note Bright",
    note: "Light-rail / tram, small and nimble",
    chime: [["E6", 0.0], ["D6", 0.14], ["B5", 0.28]],
    melody: [["B5", 0.0, 0.22], ["D6", 0.22, 0.22], ["G5", 0.44, 1.1]],
  },
  {
    id: "commuter-4note-descending",
    label: "Commuter 4-Note Descending",
    note: "Through-service commuter line, unhurried",
    chime: [["C6", 0.0], ["B5", 0.2], ["A5", 0.4]],
    melody: [["G5", 0.0, 0.3], ["E5", 0.3, 0.3], ["C5", 0.6, 0.3], ["G4", 0.9, 1.6]],
  },
  {
    id: "airport-4note-open",
    label: "Airport 4-Note Open",
    note: "Airport express, wide and soaring",
    chime: [["F#6", 0.0], ["A6", 0.18], ["F#6", 0.36]],
    melody: [["A4", 0.0, 0.34], ["D5", 0.34, 0.34], ["F#5", 0.68, 0.34], ["A5", 1.02, 1.7]],
  },
  {
    id: "night-3note-low",
    label: "Night 3-Note Low",
    note: "Late-night local, darker and lower",
    chime: [["D5", 0.0], ["C5", 0.2], ["A4", 0.4]],
    melody: [["A4", 0.0, 0.34], ["F4", 0.34, 0.34], ["D4", 0.68, 1.7]],
  },
  {
    id: "sleeper-2note-minimal",
    label: "Sleeper 2-Note Minimal",
    note: "Very sparse cue, almost nothing",
    chime: [["E5", 0.0], ["B4", 0.26]],
    melody: [["B4", 0.0, 0.4], ["E4", 0.4, 2.0]],
  },
  {
    id: "shinkansen-4note-sharp",
    label: "Shinkansen 4-Note Sharp",
    note: "High-speed rail, crisp attack",
    chime: [["A6", 0.0], ["E6", 0.13], ["A6", 0.26]],
    melody: [["E5", 0.0, 0.24], ["A5", 0.24, 0.24], ["C#6", 0.48, 0.24], ["E6", 0.72, 1.4]],
  },
  {
    id: "freight-3note-heavy",
    label: "Freight 3-Note Heavy",
    note: "Low, weighty, slightly gritty",
    chime: [["D5", 0.0], ["Bb4", 0.22], ["F4", 0.44]],
    melody: [["F4", 0.0, 0.4], ["D4", 0.4, 0.4], ["Bb3", 0.8, 1.9]],
  },
  {
    id: "coastal-5note-lydian",
    label: "Coastal 5-Note Modal",
    note: "Touristy coastal line, relaxed and open",
    chime: [["F#5", 0.0], ["A5", 0.15], ["C#6", 0.3]],
    melody: [["E5", 0.0, 0.3], ["F#5", 0.3, 0.3], ["A5", 0.6, 0.3], ["B5", 0.9, 0.3], ["E5", 1.2, 1.5]],
  },
  {
    id: "university-6note-playful",
    label: "University 6-Note Playful",
    note: "Campus tram / short shuttle, bouncy",
    chime: [["C6", 0.0], ["G5", 0.12], ["C6", 0.24]],
    melody: [
      ["G4", 0.0, 0.2], ["B4", 0.2, 0.2], ["D5", 0.4, 0.2], ["G5", 0.6, 0.2],
      ["D5", 0.8, 0.2], ["G4", 1.0, 1.1],
    ],
  },
  {
    id: "depot-4note-mechanical",
    label: "Depot 4-Note Mechanical",
    note: "Depot / shunting cue, square and utilitarian",
    chime: [["D6", 0.0], ["D6", 0.18], ["A5", 0.36], ["A5", 0.54]],
    melody: [["D5", 0.0, 0.22], ["D5", 0.22, 0.22], ["A4", 0.44, 0.22], ["A4", 0.66, 1.3]],
  },
  {
    id: "tourist-8note-narrative",
    label: "Tourist 8-Note Narrative",
    note: "Long scenic line, a full little phrase",
    chime: [["C6", 0.0], ["E6", 0.14], ["G6", 0.28]],
    melody: [
      ["G4", 0.0, 0.22], ["B4", 0.22, 0.22], ["D5", 0.44, 0.22], ["G5", 0.66, 0.22],
      ["F#5", 0.88, 0.22], ["E5", 1.1, 0.22], ["D5", 1.32, 0.22], ["G4", 1.54, 1.6],
    ],
  },
];

// ---------- segment builders ----------

function buildMelody(style, seed) {
  const dur = 3.4;
  const out = new Float64Array(Math.round(SR * dur));
  const rnd = mulberry32(seed);
  for (const [note, at, d] of style.melody) {
    addTone(out, at, freq(note), d, 0.34, {
      attack: 0.014,
      decay: 1.1,
      vib: 0.0015,
      vibHz: 4.6 + rnd() * 0.8,
      harm: 0.2,
    });
  }
  // add a soft sustained pad underneath for body
  const pad = new Float64Array(out.length);
  for (const [note] of style.melody.slice(0, 1)) {
    addTone(pad, 0, freq(note) / 2, dur * 0.8, 0.05, { attack: 0.3, decay: 0.5, harm: 0.05 });
  }
  for (let i = 0; i < out.length; i++) out[i] += pad[i];
  return fadeEdges(normalize(out, 0.85));
}

function buildDoorChime(style, seed) {
  const dur = 1.5;
  const out = new Float64Array(Math.round(SR * dur));
  const rnd = mulberry32(seed);
  const partials = [
    [1, 1.0], [2.0, 0.5], [2.76, 0.22], [5.4, 0.12], [8.9, 0.06],
  ];
  for (const [note, at] of style.chime) {
    addBell(out, at, freq(note), 1.2, 0.3 + rnd() * 0.04, partials, 3.4);
  }
  return fadeEdges(normalize(out, 0.85));
}

function buildAmbience(seed) {
  const dur = 4.0;
  const out = new Float64Array(Math.round(SR * dur));
  const rnd = mulberry32(seed);
  const white = new Float64Array(out.length);
  for (let i = 0; i < white.length; i++) white[i] = rnd() * 2 - 1;
  // platform rumble: low-passed noise
  const rumble = lowpass(white, 220);
  for (let i = 0; i < out.length; i++) out[i] += rumble[i] * 2.4;
  // air / hiss layer
  const air = highpass(white, 1400);
  for (let i = 0; i < out.length; i++) out[i] += air[i] * 0.05;
  // slow swell so it does not feel static
  for (let i = 0; i < out.length; i++) {
    const t = i / SR;
    out[i] *= 0.75 + 0.25 * Math.sin(2 * Math.PI * 0.12 * t + seed);
  }
  // distant rail clatter
  let t = 0.15;
  while (t < dur - 0.1) {
    const n = Math.round((t + rnd() * 0.02) * SR);
    const len = Math.round(0.03 * SR);
    const amp = 0.1 + rnd() * 0.08;
    for (let i = 0; i < len; i++) {
      const idx = n + i;
      if (idx < out.length) out[idx] += (rnd() * 2 - 1) * amp * Math.exp((-i / len) * 5);
    }
    t += 0.32 + rnd() * 0.22;
  }
  return fadeEdges(normalize(out, 0.7), 40);
}

function buildAnnouncement(style, seed) {
  const dur = 2.8;
  const out = new Float64Array(Math.round(SR * dur));
  const rnd = mulberry32(seed);
  // PA attention chime: 5 rising eighth-notes
  const notes = ["A5", "C#6", "E6", "A6"];
  notes.forEach((n, i) => {
    addBell(out, i * 0.17, freq(n), 0.5, 0.26, [[1, 1], [2, 0.4], [3.1, 0.15]], 6.5);
  });
  // speech-shaped formant blips (abstract, not real speech)
  const starts = [0.9, 1.35, 1.8, 2.25];
  for (const st of starts) {
    const n = Math.round(st * SR);
    const len = Math.round(0.3 * SR);
    const base = 120 + rnd() * 40;
    for (let i = 0; i < len; i++) {
      const idx = n + i;
      if (idx >= out.length) break;
      const t = i / SR;
      const env = Math.sin(Math.PI * clamp(t / 0.3, 0, 1)) ** 1.4;
      const f = base * (1 + 0.5 * Math.exp(-t * 12) * Math.sin(2 * Math.PI * 7 * t));
      const s =
        0.6 * Math.sin(2 * Math.PI * f * t) +
        0.25 * Math.sin(2 * Math.PI * f * 2 * t) +
        0.12 * Math.sin(2 * Math.PI * f * 3 * t);
      out[idx] += s * env * 0.16;
    }
  }
  return fadeEdges(normalize(out, 0.85));
}

// ---------- generate ----------

// Full-length styles are listening drafts. Only these five short, level-matched event cues
// belong in the curated pack; the bundle copier copies every file in that directory.
const SELECTED = new Map([
  ["subway-4note-ascending-Door_Chime", ["stop", 0.75]],
  ["loop-5note-descending-Melody", ["stop_failure", 0.88]],
  ["subway-4note-ascending-Announcement", ["notification", 1.20]],
  ["tourist-8note-narrative-Melody", ["subagent_stop", 0.42]],
]);

mkdirSync(PREVIEW_OUT, { recursive: true });
mkdirSync(PACK_OUT, { recursive: true });
let previewCount = 0;
let selectedCount = 0;
for (const [i, style] of STYLES.entries()) {
  const seed = 1000 + i * 137;
  const jobs = [
    ["Melody", buildMelody(style, seed)],
    ["Door_Chime", buildDoorChime(style, seed + 1)],
    ["Ambience", buildAmbience(seed + 2)],
    ["Announcement", buildAnnouncement(style, seed + 3)],
  ];
  for (const [seg, samples] of jobs) {
    const variant = `${style.id}-${seg}`;
    writeWav(join(PREVIEW_OUT, `${variant}.wav`), samples);
    previewCount++;
    const selected = SELECTED.get(variant);
    if (selected) {
      const [event, seconds] = selected;
      writeWav(join(PACK_OUT, `${event}.wav`), eventExcerpt(samples, seconds, -1.2));
      selectedCount++;
    }
  }
}
if (selectedCount !== SELECTED.size) throw new Error("missing selected station chime source");

const taskStart = new Float64Array(Math.round(SR * 0.30));
addTone(taskStart, 0, freq("G4"), 0.18, 0.34, { attack: 0.008, decay: 8, harm: 0.08 });
addTone(taskStart, 0.12, freq("C5"), 0.18, 0.30, { attack: 0.008, decay: 8, harm: 0.08 });
writeWav(join(PACK_OUT, "task_start.wav"), eventExcerpt(taskStart, 0.30, -7.0));

console.log(`wrote ${previewCount} audition WAVs and ${selectedCount + 1} curated event WAVs`);
