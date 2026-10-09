#!/usr/bin/env python3
"""Export the prototype's current Canvas frames without importing image assets.

Requires Pillow and Playwright with Chromium. All output is rebuilt from the
HTML API; legacy preview URLs are refreshed, and a recoverable archive is
written outside the repository before samples are changed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import shutil
import struct
import tempfile
import zlib
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright


HERE = Path(__file__).resolve().parent
HTML = HERE / "source/Pixel Motion Prototype.html"
SAMPLES = HERE / "samples"
VARIANTS = ("E", "G", "H")
COMMON_STATES = ("idle", "task_start", "notification", "stop", "subagent_stop", "stop_failure", "preview")
EVENT_STATES = ("task_start", "notification", "stop", "subagent_stop", "stop_failure")
MICRODUCK_REFERENCE = "https://pollen-robotics.com/microduck/"
MICRODUCK_MOTION_REFERENCES = tuple(
    f"https://pollen-robotics.com/assets/microduck/moves-portrait-alpha/{name}.webm"
    for name in ("walk", "grab", "sitstand", "standup")
)
RETIRED_VARIANTS = ("A", "B", "C", "D", "F")
RETIRED_PREVIEWS = (
    "arcade-mobile-preview.png", "arcade-preview.png", "arcade-preview.gif", "arcade-prototype-preview.png",
    "game-characters-preview.png", "game-characters-preview.gif", "original-sounds-preview.png", "original-sounds-preview.gif",
    "dot-preview.png", "dot-preview.gif", "dot-prototype-preview.png", "dot-mobile-preview.png",
)
FONT_PATHS = (
    Path("/System/Library/Fonts/STHeiti Medium.ttc"),
    Path("/Library/Fonts/Arial Unicode.ttf"),
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)
BG = (247, 243, 235)
INK = (56, 49, 43)


@lru_cache(maxsize=12)
def font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    raise RuntimeError("A font with Chinese glyphs is required for preview labels")


def save_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def png_parts(frame: Image.Image) -> tuple[bytes, bytes]:
    out = io.BytesIO()
    frame.save(out, format="PNG")
    data = out.getvalue()
    offset, ihdr, idat = 8, b"", b""
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        if kind == b"IHDR":
            ihdr = payload
        elif kind == b"IDAT":
            idat += payload
        offset += length + 12
    return ihdr, idat


def save_apng(path: Path, frames: list[Image.Image], durations: list[int], num_plays: int = 1) -> None:
    # Pillow coalesces identical neighboring frames. Emit APNG chunks explicitly
    # so the atlas frame count and every duration remain an exact contract.
    assert len(frames) == len(durations)
    assert num_plays in (0, 1)
    ihdr, _ = png_parts(frames[0])
    data = bytearray(b"\x89PNG\r\n\x1a\n")
    data += png_chunk(b"IHDR", ihdr)
    data += png_chunk(b"acTL", struct.pack(">II", len(frames), num_plays))
    sequence = 0
    for index, (frame, duration) in enumerate(zip(frames, durations)):
        frame_header, pixels = png_parts(frame)
        assert frame_header == ihdr
        width, height = frame.size
        control = struct.pack(">IIIIIHHBB", sequence, width, height, 0, 0, duration, 1000, 0, 0)
        data += png_chunk(b"fcTL", control)
        sequence += 1
        if index == 0:
            data += png_chunk(b"IDAT", pixels)
        else:
            data += png_chunk(b"fdAT", struct.pack(">I", sequence) + pixels)
            sequence += 1
    data += png_chunk(b"IEND", b"")
    path.write_bytes(data)


def backup_current() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    archive = Path("/tmp") / f"claudi0-pixel-before-export-{stamp}.zip"
    with ZipFile(archive, "w", ZIP_DEFLATED) as z:
        z.write(HTML, HTML.name)
        z.write(Path(__file__), Path(__file__).name)
        for path in sorted(SAMPLES.rglob("*")):
            if path.is_file():
                z.write(path, str(Path("samples") / path.relative_to(SAMPLES)))
    with ZipFile(archive) as z:
        assert z.testzip() is None
    return archive


def retired_assets() -> list[Path]:
    paths = []
    for key in RETIRED_VARIANTS:
        paths.extend(path for path in sorted((SAMPLES / key).rglob("*")) if path.is_file() and path.suffix.lower() in (".png", ".gif", ".json"))
    paths.extend(SAMPLES / name for name in RETIRED_PREVIEWS if (SAMPLES / name).is_file())
    for key in VARIANTS:
        old_manifest = SAMPLES / key / "timing.json"
        if old_manifest.is_file():
            old_actions = json.loads(old_manifest.read_text())["animations"]
            paths.extend(SAMPLES / key / f"{action}.png" for action in old_actions if action not in COMMON_STATES and (SAMPLES / key / f"{action}.png").is_file())
    paths = sorted(set(paths))
    for path in paths:
        assert path.resolve().is_relative_to(SAMPLES.resolve()), f"Cleanup path is outside samples: {path}"
    return paths


def apng_assets(action: str, item: dict) -> dict:
    frame_count = item["frames"]
    playback = item.get("playback", "once")
    assert playback in ("once", "loop")
    plan = {
        "primary": {"file": f"{action}.png", "numPlays": 1, "sourceFrames": [0, frame_count - 1]},
        "sequence": ["primary"],
    }
    if playback == "loop":
        start, end = item["loopStartFrame"], item["loopEndFrame"]
        assert isinstance(start, int) and isinstance(end, int) and 0 <= start <= end < frame_count
        if start == 0 and end == frame_count - 1:
            plan["primary"]["numPlays"] = 0
        else:
            # APNG cannot express an intro followed by a subrange loop. The
            # primary file plays all atlas frames once; consumers then switch
            # to the separate looping file according to this explicit bridge.
            plan["loop"] = {"file": f"{action}-loop.png", "numPlays": 0, "sourceFrames": [start, end]}
            plan["sequence"].append("loop")
    if "apngAssets" in item:
        assert item["apngAssets"] == plan, f"APNG asset bridge differs from playback fields: {action}"
    else:
        item["apngAssets"] = plan
    return plan


def extract_variant(page, key: str) -> dict:
    payload = page.evaluate(
        """key => ({
          name: window.pixelMotion.variants[key].name,
          states: window.pixelMotion.statesFor(key),
          manifest: window.pixelMotion.manifest(key),
          atlas: window.pixelMotion.atlas(key).toDataURL('image/png')
        })""",
        key,
    )
    atlas = Image.open(io.BytesIO(base64.b64decode(payload["atlas"].split(",", 1)[1]))).convert("RGBA")
    manifest = payload["manifest"]
    width, height = manifest["frameWidth"], manifest["frameHeight"]
    assert isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0
    assert set(manifest["animations"]) == set(COMMON_STATES), "Only idle, the five public events, and preview may be distributed"
    assert {state["id"] for state in payload["states"]} == set(COMMON_STATES)
    assert manifest["rows"] == len(payload["states"])
    assert manifest["columns"] == 16
    assert atlas.size == (width * manifest["columns"], height * manifest["rows"])
    animations = {}
    for state in payload["states"]:
        item = manifest["animations"][state["id"]]
        assert item["frames"] == len(item["durationsMs"]) == manifest["columns"]
        assert 0 <= item["reducedMotionFrame"] < item["frames"]
        assert all(isinstance(t, int) and 0 < t < 65536 for t in item["durationsMs"])
        apng_assets(state["id"], item)
        row = item["row"]
        frames = [atlas.crop((i * width, row * height, (i + 1) * width, (row + 1) * height)) for i in range(item["frames"])]
        for frame in frames:
            assert frame.getchannel("A").getextrema() == (0, 255), f"{key}/{state['id']} lost transparent background"
        animations[state["id"]] = frames
    return {"name": payload["name"], "states": payload["states"], "manifest": manifest, "atlas": atlas, "animations": animations}


def preview_frame(data: dict, state: dict, elapsed_ms: int | None) -> Image.Image:
    frames = data["animations"][state["id"]]
    animation = data["manifest"]["animations"][state["id"]]
    durations = animation["durationsMs"]
    index = len(frames) - 1
    if elapsed_ms is not None:
        start, end = 0, len(frames) - 1
        elapsed = elapsed_ms
        if animation.get("playback", "once") == "loop":
            if elapsed >= sum(durations):
                start, end = animation["loopStartFrame"], animation["loopEndFrame"]
                elapsed = (elapsed - sum(durations)) % sum(durations[start : end + 1])
        else:
            elapsed %= sum(durations) + 650
        for frame_index in range(start, end + 1):
            duration = durations[frame_index]
            if elapsed < duration:
                index = frame_index
                break
            elapsed -= duration
    frame = frames[index]
    scale = max(1, 192 // max(frame.size))
    return frame.resize((frame.width * scale, frame.height * scale), Image.Resampling.NEAREST)


def group_preview(key: str, data: dict, elapsed_ms: int | None = None) -> Image.Image:
    states = data["states"]
    columns, cell_w, cell_h = 4, 240, 256
    rows = (len(states) + columns - 1) // columns
    preview = Image.new("RGB", (columns * cell_w + 48, rows * cell_h + 100), BG)
    draw = ImageDraw.Draw(preview)
    title = f"claudi0 · {data['name']} · 七个表情动作"
    draw.text((24, 20), title, fill=INK, font=font(25))
    for i, state in enumerate(states):
        x, y = 24 + (i % columns) * cell_w, 75 + (i // columns) * cell_h
        frame = preview_frame(data, state, elapsed_ms)
        preview.paste(frame, (x + (cell_w - frame.width) // 2, y + (192 - frame.height) // 2), frame)
        draw.text((x + 18, y + 199), state["name"], fill=INK, font=font(17))
        draw.text((x + 18, y + 222), state["action"], fill=(116, 108, 97), font=font(13))
    return preview


def event_meaning_preview(groups: dict, elapsed_ms: int | None = None) -> Image.Image:
    cell_w, row_h = 240, 292
    preview = Image.new("RGB", (len(EVENT_STATES) * cell_w + 48, len(VARIANTS) * row_h + 105), BG)
    draw = ImageDraw.Draw(preview)
    draw.text((24, 18), "claudi0 · 事件表情反馈", fill=INK, font=font(26))
    draw.text((24, 53), "三种角色 · 五个公共事件 · 按各动作的播放方式预览", fill=(116, 108, 97), font=font(16))
    for row, key in enumerate(VARIANTS):
        data = groups[key]
        row_top = 94 + row * row_h
        draw.text((24, row_top), data["name"], fill=INK, font=font(19))
        for column, action in enumerate(EVENT_STATES):
            state = next(s for s in data["states"] if s["id"] == action)
            x, y = 24 + column * cell_w, row_top + 30
            frame = preview_frame(data, state, elapsed_ms)
            preview.paste(frame, (x + (cell_w - frame.width) // 2, y + (192 - frame.height) // 2), frame)
            draw.text((x + 18, y + 199), state["name"], fill=INK, font=font(17))
            draw.text((x + 18, y + 222), state["action"], fill=(116, 108, 97), font=font(13))
    return preview


def save_preview_gif(path: Path, render) -> None:
    # These are opaque contact sheets; use one shared palette to avoid flicker.
    frames = [render(i * 100) for i in range(60)]
    palette_source = Image.new("RGB", (frames[0].width // 4, len(frames) * (frames[0].height // 4)), BG)
    for index, frame in enumerate(frames):
        reduced = frame.resize((frame.width // 4, frame.height // 4), Image.Resampling.NEAREST)
        palette_source.paste(reduced, (0, index * reduced.height))
    palette = palette_source.quantize(colors=256)
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(path, save_all=True, append_images=indexed[1:], duration=100, loop=0, optimize=False, disposal=2)


def screenshot(page, url: str, out: Path, *, key: str, mobile: bool = False, dark: bool = False) -> None:
    separator = "&" if "?" in url else "?"
    page.set_viewport_size({"width": 390 if mobile else 1440, "height": 844 if mobile else 1100})
    page.goto(f"{url}{separator}variant={key}&state=notification", wait_until="load")
    page.wait_for_function("Boolean(window.pixelMotion)")
    page.locator("#static-mode").check()
    if dark:
        page.locator("#theme").click()
    page.screenshot(path=str(out), full_page=True, animations="disabled")


def verify_apng(path: Path, frames: list[Image.Image], durations: list[int], num_plays: int = 1) -> None:
    with Image.open(path) as animation:
        assert animation.n_frames == len(frames), str(path)
        assert animation.info["loop"] == num_plays, str(path)
        for i, (frame, duration) in enumerate(zip(frames, durations)):
            animation.seek(i)
            assert animation.convert("RGBA").tobytes() == frame.tobytes(), f"{path}: frame {i} differs from atlas"
            assert abs(animation.info["duration"] - duration) < 0.001, f"{path}: frame {i} timing differs"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", action="store_true", help="Export verified native runtime assets without retired-asset cleanup")
    parser.add_argument("--check-runtime", action="store_true", help="Compare current native assets with the source HTML without writing")
    parser.add_argument("--url", help="Optional served prototype URL; default reads the local HTML")
    parser.add_argument("--browser-executable", help="Optional Chromium/Chrome executable path")
    parser.add_argument("--microduck-motion-reference", action="append", help="Override official Microduck motion video URLs; may be repeated")
    args = parser.parse_args()
    if args.runtime or args.check_runtime:
        from export_runtime import export_runtime
        export_runtime(args.browser_executable, check_only=args.check_runtime)
        return
    motion_references = args.microduck_motion_reference or list(MICRODUCK_MOTION_REFERENCES)
    url = args.url or HTML.as_uri()
    html_digest = hashlib.sha256(HTML.read_bytes()).hexdigest()
    cleanup_paths = retired_assets()
    cleanup_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in cleanup_paths}
    archive = backup_current()
    cleanup_inventory = archive.with_suffix(".cleanup.json")
    save_json(cleanup_inventory, {"backup": str(archive), "retiredGeneratedFiles": [str(path.relative_to(HERE)) for path in cleanup_paths]})
    print(f"Backup: {archive}", flush=True)
    print(f"Cleanup inventory: {cleanup_inventory}; {len(cleanup_paths)} precise file paths", flush=True)
    with tempfile.TemporaryDirectory(prefix="claudi0-event-pixel-export-") as temporary:
        stage = Path(temporary)
        groups = {}
        apng_jobs = []
        with sync_playwright() as playwright:
            browser_executable = args.browser_executable
            system_chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
            if not browser_executable and system_chrome.is_file():
                browser_executable = str(system_chrome)
            launch_options = {"executable_path": browser_executable} if browser_executable else {}
            browser = playwright.chromium.launch(headless=True, **launch_options)
            page = browser.new_page(viewport={"width": 1440, "height": 1100}, device_scale_factor=1)
            page.goto(url, wait_until="load")
            page.wait_for_function("Boolean(window.pixelMotion)")
            assert page.evaluate("Object.keys(window.pixelMotion.variants).sort()") == sorted(VARIANTS), "The HTML must expose exactly the selected current characters"
            for key in VARIANTS:
                data = groups[key] = extract_variant(page, key)
                folder = stage / key
                folder.mkdir()
                data["atlas"].save(folder / "sprites.png")
                save_json(folder / "timing.json", data["manifest"])
                for action, frames in data["animations"].items():
                    animation = data["manifest"]["animations"][action]
                    plan = apng_assets(action, animation)
                    for role in plan["sequence"]:
                        asset = plan[role]
                        start, end = asset["sourceFrames"]
                        selected_frames = frames[start : end + 1]
                        durations = animation["durationsMs"][start : end + 1]
                        path = folder / asset["file"]
                        save_apng(path, selected_frames, durations, asset["numPlays"])
                        verify_apng(path, selected_frames, durations, asset["numPlays"])
                        apng_jobs.append((path, selected_frames, durations, asset["numPlays"]))
                group_preview(key, data).save(folder / "contact-sheet.png")
                print(f"Exported {key}: {data['name']}, {len(data['states'])} actions", flush=True)

            # Refresh every published screenshot from the current HTML.
            for filename, key, mobile, dark in (
                ("prototype-preview.png", "H", False, False),
                ("dark-preview.png", "H", False, True),
                ("mobile-preview.png", "H", True, False),
                ("microduck-prototype-preview.png", "E", False, False),
                ("microduck-mobile-preview.png", "E", True, False),
                ("ghost-prototype-preview.png", "G", False, False),
                ("ghost-mobile-preview.png", "G", True, False),
                ("bitcoin-prototype-preview.png", "H", False, False),
                ("bitcoin-mobile-preview.png", "H", True, False),
            ):
                screenshot(page, url, stage / filename, key=key, mobile=mobile, dark=dark)
            browser.close()

        event_meaning_preview(groups).save(stage / "event-meaning-preview.png")
        save_preview_gif(stage / "event-meaning-preview.gif", lambda elapsed: event_meaning_preview(groups, elapsed))
        for key, name in (("E", "microduck"), ("G", "ghost"), ("H", "bitcoin")):
            group_preview(key, groups[key]).save(stage / f"{name}-preview.png")
            save_preview_gif(stage / f"{name}-preview.gif", lambda elapsed, key=key: group_preview(key, groups[key], elapsed))
        provenance = {
            "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
            "source": "Pixel Motion Prototype.html",
            "sourceSHA256": html_digest,
            "productionMethod": "Programmatic pixel drawing in the prototype Canvas API. No third-party photographs or logo image files are included in the exported assets.",
            "designIntent": "Graphical interaction drafts for a mechanical duck, a pixel ghost, and a generic Bitcoin coin symbol.",
            "variants": {
                "E": {
                    "name": groups["E"]["name"],
                    "designSource": "Exploratory pixel draft with explicit third-party Microduck design reference.",
                    "references": [
                        {"title": "Pollen Robotics — Microduck", "url": MICRODUCK_REFERENCE, "kind": "official design reference"},
                        *[{"url": url, "kind": "official motion video reference"} for url in motion_references],
                    ],
                    "thirdPartyDesignReference": True,
                    "legal_clearance": "not_completed",
                    "commercialUsePermission": "not_established",
                },
                "G": {
                    "name": groups["G"]["name"],
                    "designSource": "Programmatic pixel ghost drawing informed by Ghostty's rounded arch, short shallow scalloped hem, and icy white/light-blue volume. The small eye and expression design is independently drawn; the terminal face and screen frame are not reproduced.",
                    "references": [
                        {"title": "Ghostty official character asset", "url": "https://github.com/ghostty-org/ghostty/blob/main/images/Ghostty.icon/Assets/Ghostty.png", "kind": "official visual style reference"},
                        {"title": "Ghostty official website", "url": "https://ghostty.org/", "kind": "official visual style reference"},
                    ],
                    "thirdPartyDesignReference": True,
                    "legal_clearance": "not_completed",
                    "commercialUsePermission": "not_established",
                },
                "H": {
                    "name": groups["H"]["name"],
                    "designSource": "Programmatic pixel drawing of a generic Bitcoin coin symbol for interaction animations.",
                    "contentScope": "Visual interaction draft; no price, return, or trading data is used.",
                    "references": [],
                    "legal_clearance": "not_completed",
                },
            },
            "legal_clearance": "not_completed",
            "reviewScope": "Prototype assets; no legal clearance or commercial-use guarantee is established by this export.",
            "animationFormat": "Transparent APNG with exact atlas frames and timings. Once assets use num_plays=1; continuous loops use num_plays=0. A partial loop has separate intro and loop assets linked by the animation's apngAssets sequence.",
            "frameContent": "Character graphics without text bubbles. The mechanical duck and ghost notification states include a pixel question mark. Event names in contact previews are outside sprite frames.",
            "eventContract": {"states": list(COMMON_STATES), "publicEvents": list(EVENT_STATES), "terminalFrame": "Once-played events retain their end pose; looped events follow their declared loop range.", "notificationMarker": "Mechanical duck E and ghost G: pixel question mark appears from frame 3."},
            "canvasDimensions": {key: {"width": groups[key]["manifest"]["frameWidth"], "height": groups[key]["manifest"]["frameHeight"]} for key in VARIANTS},
        }
        save_json(stage / "provenance.json", provenance)
        assert html_digest == hashlib.sha256(HTML.read_bytes()).hexdigest(), "HTML changed during export; rerun with stable source"
        for path, frames, durations, num_plays in apng_jobs:
            verify_apng(path, frames, durations, num_plays)

        # The current distribution contains only the selected E/G/H groups, the
        # current HTML, event previews, and the source/reference record.
        distribution = stage / "claudi0-pixel-motion-samples.zip"
        zip_paths = [p for key in VARIANTS for p in sorted((stage / key).rglob("*")) if p.is_file()]
        zip_paths += [
            stage / "event-meaning-preview.png", stage / "event-meaning-preview.gif",
            stage / "microduck-preview.png", stage / "microduck-preview.gif",
            stage / "ghost-preview.png", stage / "ghost-preview.gif",
            stage / "bitcoin-preview.png", stage / "bitcoin-preview.gif",
            stage / "provenance.json",
        ]
        with ZipFile(distribution, "w", ZIP_DEFLATED) as z:
            for path in zip_paths:
                z.write(path, str(Path("samples") / path.relative_to(stage)))
            z.write(HTML, HTML.name)
        with ZipFile(distribution) as z:
            assert z.testzip() is None
            assert z.read(HTML.name) == HTML.read_bytes()
            expected = {str(Path("samples") / p.relative_to(stage)) for p in zip_paths} | {HTML.name}
            assert set(z.namelist()) == expected
            assert not any(name.startswith(f"samples/{key}/") for key in RETIRED_VARIANTS for name in expected)

        staged_paths = {path.relative_to(stage) for path in stage.rglob("*") if path.is_file()}
        current_generated = {path.relative_to(SAMPLES) for path in SAMPLES.rglob("*") if path.is_file() and path.suffix.lower() in (".png", ".gif", ".json", ".zip")}
        retired_relative = {path.relative_to(SAMPLES) for path in cleanup_paths}
        assert not current_generated - staged_paths - retired_relative, f"Unclassified generated assets require inspection: {current_generated - staged_paths - retired_relative}"
        for path, digest in cleanup_hashes.items():
            assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"Cleanup target changed during export: {path}"

        for path in stage.rglob("*"):
            if path.is_file():
                target = SAMPLES / path.relative_to(stage)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        for path in cleanup_paths:
            path.unlink()
        for key in RETIRED_VARIANTS:
            directory = SAMPLES / key
            if directory.is_dir() and not any(directory.iterdir()):
                directory.rmdir()
        final_generated = {path.relative_to(SAMPLES) for path in SAMPLES.rglob("*") if path.is_file() and path.suffix.lower() in (".png", ".gif", ".json", ".zip")}
        assert final_generated == staged_paths, "The current samples directory must match the staged current-character assets"
        summary = {
            "backup": str(archive),
            "cleanupInventory": str(cleanup_inventory),
            "removedGeneratedFiles": len(cleanup_paths),
            "sourceSHA256": html_digest,
            "variants": {key: {"name": groups[key]["name"], "actions": len(groups[key]["states"]), "framesPerAction": groups[key]["manifest"]["columns"], "frameWidth": groups[key]["manifest"]["frameWidth"], "frameHeight": groups[key]["manifest"]["frameHeight"]} for key in VARIANTS},
            "canonicalAnimations": sum(len(groups[key]["states"]) for key in VARIANTS),
            "totalAPNGs": len(apng_jobs),
            "encodedAPNGFrames": sum(len(frames) for _, frames, _, _ in apng_jobs),
            "continuousLoopAPNGs": sum(num_plays == 0 for _, _, _, num_plays in apng_jobs),
            "verified": ["transparent RGBA source frames", "APNG exact frames and timings", "APNG per-asset once/loop play counts", "partial-loop intro/loop bridge", "ZIP CRC and exact allowlist", "ZIP current HTML"],
            "distribution": str(SAMPLES / distribution.name),
        }
        print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
