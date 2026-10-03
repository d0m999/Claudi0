"""The native export path shares the original HTML extractor and APNG encoder."""
from __future__ import annotations

import base64
import hashlib
import io
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image
from playwright.sync_api import sync_playwright
_spec = importlib.util.spec_from_file_location("pixel_motion_original", Path(__file__).with_name("export-original-samples.py"))
_original = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_original)
HTML, SAMPLES, VARIANTS, EVENT_STATES = _original.HTML, _original.SAMPLES, _original.VARIANTS, _original.EVENT_STATES
backup_current, extract_variant = _original.backup_current, _original.extract_variant
save_json, save_apng, verify_apng, group_preview = _original.save_json, _original.save_apng, _original.verify_apng, _original.group_preview
save_preview_gif, event_meaning_preview, screenshot = _original.save_preview_gif, _original.event_meaning_preview, _original.screenshot

RUNTIME = HTML.parents[2] / "gui/Sources/ClaudioGUI/Resources/EventAnimations"
STYLE = {"E": "mechanicalDuck", "G": "pixelGhost", "H": "bitcoin"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export_runtime(browser_executable: str | None, *, check_only: bool = False) -> None:
    source_digest = digest(HTML)
    with tempfile.TemporaryDirectory(prefix="claudio-motion-runtime-") as temporary:
        stage = Path(temporary)
        samples = stage / "samples"
        runtime = stage / "runtime"
        references = []
        pixel_references = []
        styles = {}
        checked_frames = 0
        groups = {}
        prior = json.loads((SAMPLES / "provenance.json").read_text()) if (SAMPLES / "provenance.json").is_file() else {}
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True, **({"executable_path": browser_executable} if browser_executable else {}))
            page = browser.new_page()
            page.goto(HTML.as_uri())
            page.wait_for_function("Boolean(window.pixelMotion)")
            for key in VARIANTS:
                appearances = {}
                for appearance in ("light", "dark"):
                    page.evaluate("dark => document.body.classList.toggle('dark', dark)", appearance == "dark")
                    data = extract_variant(page, key)
                    appearances[appearance] = data
                    direct = page.evaluate("""key => {
                      const canvas=document.createElement('canvas');canvas.width=canvas.height=64;
                      return window.pixelMotion.statesFor(key).filter(s=>s.id!=='idle'&&s.id!=='preview').flatMap(s=>
                        s.times.map((_,frame)=>{window.pixelMotion.drawSprite(canvas,key,s,frame);
                          return {action:s.id,frame,png:canvas.toDataURL('image/png')};}));
                    }""", key)
                    for item in direct:
                        image = Image.open(io.BytesIO(base64.b64decode(item["png"].split(",", 1)[1]))).convert("RGBA")
                        assert image.tobytes() == data["animations"][item["action"]][item["frame"]].tobytes()
                        pixel_references.append({"style": STYLE[key], "appearance": appearance,
                            "action": item["action"], "frame": item["frame"],
                            "rgbaSHA256": hashlib.sha256(image.tobytes()).hexdigest()})
                        checked_frames += 1
                light, dark = appearances["light"], appearances["dark"]
                groups[key] = light
                assert light["manifest"] == dark["manifest"]
                shared = light["atlas"].tobytes() == dark["atlas"].tobytes()
                assert shared == (key != "E"), f"Unexpected appearance mapping for {key}"
                styles[STYLE[key]] = {
                    "variant": key, "timing": f"{key}/timing.json",
                    "atlases": {"light": f"{key}/sprites.png", "dark": f"{key}/{'sprites.png' if shared else 'sprites-dark.png'}"},
                }
                for parent in (samples, runtime):
                    directory = parent / key
                    directory.mkdir(parents=True)
                    light["atlas"].save(directory / "sprites.png")
                    if not shared:
                        dark["atlas"].save(directory / "sprites-dark.png")
                    save_json(directory / "timing.json", light["manifest"])
                for state in light["states"]:
                    action = state["id"]
                    animation = light["manifest"]["animations"][action]
                    for asset_id in animation["apngAssets"]["sequence"]:
                        asset = animation["apngAssets"][asset_id]
                        start, end = asset["sourceFrames"]
                        frames = light["animations"][action][start:end + 1]
                        durations = animation["durationsMs"][start:end + 1]
                        file = samples / key / asset["file"]
                        save_apng(file, frames, durations, asset["numPlays"])
                        verify_apng(file, frames, durations, asset["numPlays"])
                    if action in EVENT_STATES:
                        times = state["times"]
                        total = sum(times)
                        boundaries = [0]
                        for duration in times:
                            boundaries.append(boundaries[-1] + duration)
                        if state.get("playback") == "loop":
                            start = state.get("loopStartFrame", 0)
                            period = sum(times[start:])
                            for cycle in range(3):
                                cursor = total + period * cycle
                                boundaries.append(cursor)
                                for duration in times[start:]:
                                    cursor += duration
                                    boundaries.append(cursor)
                        points = sorted({max(0, b + delta) for b in boundaries for delta in (-1, 0, 1)} | {4000, 6000, 10000})
                        expected = page.evaluate("""({key,action,points}) => {
                          const s=window.pixelMotion.statesFor(key).find(s=>s.id===action);
                          return points.map(elapsedMs=>({elapsedMs,...window.pixelMotion.frameAtElapsed(s,elapsedMs,false)}));
                        }""", {"key": key, "action": action, "points": points})
                        references.extend({"style": STYLE[key], "action": action, **item} for item in expected)
                group_preview(key, light).save(samples / key / "contact-sheet.png")
            if not check_only:
                for filename, key, mobile, dark in (
                    ("prototype-preview.png", "H", False, False), ("dark-preview.png", "H", False, True),
                    ("mobile-preview.png", "H", True, False), ("microduck-prototype-preview.png", "E", False, False),
                    ("microduck-mobile-preview.png", "E", True, False), ("ghost-prototype-preview.png", "G", False, False),
                    ("ghost-mobile-preview.png", "G", True, False), ("bitcoin-prototype-preview.png", "H", False, False),
                    ("bitcoin-mobile-preview.png", "H", True, False),
                ):
                    screenshot(page, HTML.as_uri(), samples / filename, key=key, mobile=mobile, dark=dark)
            browser.close()
        if not check_only:
            event_meaning_preview(groups).save(samples / "event-meaning-preview.png")
            save_preview_gif(samples / "event-meaning-preview.gif", lambda elapsed: event_meaning_preview(groups, elapsed))
            for key, name in (("E", "microduck"), ("G", "ghost"), ("H", "bitcoin")):
                group_preview(key, groups[key]).save(samples / f"{name}-preview.png")
                save_preview_gif(samples / f"{name}-preview.gif", lambda elapsed, key=key: group_preview(key, groups[key], elapsed))
        assert checked_frames == 480
        provenance = {
            "schema": 1, "sourceSHA256": source_digest, "styles": styles,
            "files": {str(p.relative_to(runtime)): digest(p) for p in sorted(runtime.rglob("*")) if p.is_file()},
        }
        save_json(runtime / "provenance.json", provenance)
        # Preserve the source/design references and their existing clearance status.
        metadata = {key: prior[key] for key in ("productionMethod", "designIntent", "variants", "source") if key in prior}
        previews = prior.get("previewFiles", {}) if check_only else {
            p.name: digest(p) for p in samples.iterdir() if p.is_file() and p.suffix in (".png", ".gif")}
        save_json(samples / "provenance.json", {**metadata, **provenance, "verifiedReferenceFrames": checked_frames, "previewFiles": previews})
        save_json(samples / "playback-reference.json", {"sourceSHA256": source_digest, "samples": references})
        save_json(samples / "pixel-reference.json", {"sourceSHA256": source_digest, "samples": pixel_references})
        assert digest(HTML) == source_digest, "Source HTML changed during export"
        if check_only:
            for filename, expected in previews.items():
                assert digest(SAMPLES / filename) == expected, f"Preview checksum differs: {filename}"
            for p in sorted(runtime.rglob("*")):
                if p.is_file():
                    current = RUNTIME / p.relative_to(runtime)
                    assert current.is_file() and digest(current) == digest(p), f"Stale runtime asset: {current}"
            for p in sorted(samples.rglob("*")):
                if p.is_file():
                    current = SAMPLES / p.relative_to(samples)
                    assert current.is_file() and digest(current) == digest(p), f"Stale sample asset: {current}"
        else:
            archive = backup_current()
            for parent, target in ((runtime, RUNTIME), (samples, SAMPLES)):
                for p in sorted(parent.rglob("*")):
                    if p.is_file():
                        destination = target / p.relative_to(parent)
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(p, destination)
            # Refresh the existing downloadable distribution using only the verified canonical
            # assets. No unrelated previews or retired files are removed.
            with ZipFile(SAMPLES / "claudi0-pixel-motion-samples.zip", "w", ZIP_DEFLATED) as zip_file:
                zip_file.write(HTML, HTML.name)
                for p in sorted(samples.rglob("*")):
                    if p.is_file():
                        zip_file.write(p, str(Path("samples") / p.relative_to(samples)))
            print(f"Backup: {archive}")
        print(json.dumps({"status": "PASS", "sourceSHA256": source_digest,
                          "referenceFrames": checked_frames, "boundarySamples": len(references),
                          "runtimeFiles": len(provenance["files"]), "mode": "check" if check_only else "export"}))
