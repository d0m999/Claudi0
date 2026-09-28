# Station Chimes — Sources

## Origin

The five event files in this pack are **synthesized from scratch** by
`scripts/generate-station-chimes.mjs` (additive/FM-style oscillators plus shaped
noise, written out as 16-bit 44.1 kHz mono PCM WAV). The generator also writes
64 full-length audition variants to `pack-drafts/station-chimes/`; those files
are not part of this curated pack. There are no recordings or extracted samples.

## What is imitated, and what is not

Real Japanese station cues — the *hasshin hōseki* chime played at the door, and
each railway's *hassha melody* (発車メロディ) — are authored works. JR East, the
Tokyo metro operators, and the private railways hold rights in their own melodies,
and individual composers are credited for theirs.

This pack therefore does **not** reproduce any real melody. What it copies is the
*format*:

- how many notes a cue uses, and whether it ascends or descends
- the bell-like timbre and the decay of a struck chime
- the four functional roles a station has: departure melody, door chime,
  platform ambience, PA announcement

Every note in every file here is an original invention. Nothing is a transcription.

## License

CC0 1.0 Universal (public domain dedication). No attribution required, no
restrictions on use, modification, or redistribution.

## Format

| Property | Value |
|---|---|
| Container | RIFF WAVE, PCM |
| Bit depth | 16-bit |
| Sample rate | 44 100 Hz |
| Channels | 1 (mono) |
| Normalization | `task_start` peak −7.0 dBFS; other four event cues peak −1.2 dBFS |

## Regenerating

```bash
node scripts/generate-station-chimes.mjs
```

The generator is deterministic: a fixed seed per style, so the same bytes come
out on every run. It writes 64 audition WAVs outside `packs/` and five short
event WAVs here. To add a style, append an entry to `STYLES` in the generator
and add a matching row to `catalogue` in `manifest.json`.
