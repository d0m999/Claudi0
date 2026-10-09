#!/usr/bin/env python3
"""Exercise only the event-animation HTML, served with the app's runtime resources.

Requires Python Playwright, Pillow, and its installed Chromium. No desktop UI is controlled.
Results bind the prototype, source HTML, runtime provenance, timing, and atlas bytes.
"""

import argparse
import functools
import hashlib
import http.server
import json
import tempfile
import threading
from contextlib import contextmanager
from importlib.metadata import version
from pathlib import Path
from urllib.parse import quote, urlparse

from PIL import Image
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
PROTOTYPE = ROOT / "designs/macos-settings-native/Animation Settings Prototype.html"
JAVASCRIPT = PROTOTYPE.parent / "animation-settings-prototype.js"
SOURCE = ROOT / "designs/pixel-motion/reference/approved-source.html"
RESOURCES = ROOT / "gui/Sources/ClaudioGUI/Resources/EventAnimations"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
EVENTS = ["task_start", "notification", "stop", "subagent_stop", "stop_failure"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


@contextmanager
def serve_repository():
    handler = functools.partial(QuietHandler, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def rgba_frame(atlas, row, frame):
    return atlas.crop((frame * 64, row * 64, (frame + 1) * 64, (row + 1) * 64)).tobytes()


def canvas_bytes(page):
    return bytes(page.locator("canvas[data-motion-live]").evaluate(
        "canvas => Array.from(canvas.getContext('2d').getImageData(0,0,64,64).data)"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument(
        "--browser-executable", type=Path,
        help="Explicit browser override; the default uses Playwright's matching Chromium.",
    )
    args = parser.parse_args()
    artifacts = args.artifacts or Path(tempfile.mkdtemp(prefix="claudio-animation-prototype-"))
    artifacts.mkdir(parents=True, exist_ok=True)
    provenance = json.loads((RESOURCES / "provenance.json").read_text())
    entries = {entry["variant"]: entry for entry in provenance["styles"].values()}
    manifests = {
        variant: json.loads((RESOURCES / entry["timing"]).read_text())
        for variant, entry in entries.items()
    }
    atlases = {
        (variant, appearance): Image.open(RESOURCES / entry["atlases"][appearance]).convert("RGBA")
        for variant, entry in entries.items() for appearance in ["light", "dark"]
    }
    checks = []
    page_errors, forbidden_requests, requested_resources = [], [], set()

    def check(condition, name, *, fatal=True):
        checks.append({"name": name, "status": "PASS" if condition else "FAIL"})
        if not condition and fatal:
            raise AssertionError(name)

    report = {
        "prototypeSHA256": digest(PROTOTYPE), "prototypeJavaScriptSHA256": digest(JAVASCRIPT),
        "sourceSHA256": digest(SOURCE), "provenanceSHA256": digest(RESOURCES / "provenance.json"),
        "resourceSHA256": {path: digest(RESOURCES / path) for path in provenance["files"]},
        "playwrightVersion": version("playwright"),
        "browserLaunchPolicy": "explicit executable" if args.browser_executable else "bundled Chromium",
        "browserExecutableOverride": str(args.browser_executable) if args.browser_executable else None,
        "checks": checks,
    }
    try:
        check(provenance["sourceSHA256"] == report["sourceSHA256"], "runtime resources bind current source HTML")
        with serve_repository() as origin, sync_playwright() as playwright:
            launch_options = {"headless": True}
            if args.browser_executable:
                launch_options["executable_path"] = str(args.browser_executable)
            browser = playwright.chromium.launch(**launch_options)
            context = browser.new_context(viewport={"width": 1440, "height": 1080}, reduced_motion="no-preference")
            page = context.new_page()
            page.on("pageerror", lambda error: page_errors.append(str(error)))

            def route(request_route):
                request = request_route.request
                if not request.url.startswith(origin + "/"):
                    forbidden_requests.append(request.url)
                    request_route.abort()
                    return
                path = urlparse(request.url).path
                if "/Resources/EventAnimations/" in path:
                    requested_resources.add(path.split("/Resources/EventAnimations/", 1)[1])
                request_route.continue_()

            page.route("**/*", route)
            page.add_init_script("""(() => {
              window.animationAudioStarts = 0;
              for (const key of ['AudioContext', 'webkitAudioContext']) {
                if (window[key]) window[key] = new Proxy(window[key], {
                  construct() { window.animationAudioStarts++; throw new Error('Animation preview must not start audio'); }
                });
              }
              HTMLMediaElement.prototype.play = function() {
                window.animationAudioStarts++;
                return Promise.reject(new Error('Animation preview must not play media'));
              };
            })();""")
            url = origin + "/" + quote(str(PROTOTYPE.relative_to(ROOT)))
            page.goto(url + "?variant=A&lang=zh&theme=light", wait_until="networkidle")
            page.wait_for_function("window.animationSettingsReview !== undefined")
            get_state = lambda: page.evaluate("window.animationSettingsReview.getState()")
            check(get_state()["theme"] == "original", "default is original icons")
            check(page.locator("[data-motion-theme-choice]").count() == 4, "A layout has four styles")
            check(page.locator("[data-motion-event]").count() == 5, "only five public events can be previewed")
            check(page.locator("#motion-enabled").count() == 0, "original hides character options")

            for variant in ["E", "G", "H"]:
                page.locator(f"#motion-theme-{variant}").click()
                if not get_state()["reduced"]:
                    page.locator("#motion-reduced").check()
                for appearance in ["light", "dark"]:
                    page.locator("#preview-theme").select_option(appearance)
                    for event in EVENTS:
                        page.locator(f"#motion-event-{event}").click()
                        animation = manifests[variant]["animations"][event]
                        expected = rgba_frame(atlases[variant, appearance], animation["row"], animation["reducedMotionFrame"])
                        check(canvas_bytes(page) == expected, f"{variant}/{appearance}/{event} renders canonical static pixels")
                        check(page.locator(f"#motion-event-{event}").get_attribute("aria-pressed") == "true", f"{variant}/{appearance}/{event} selection is visible")
                        check(not get_state()["playing"], f"{variant}/{appearance}/{event} static preview stops scheduling")
                page.locator("#motion-enabled").uncheck()
                check(get_state()["theme"] == variant and not get_state()["enabled"], f"{variant} choice is retained while disabled")
                check(page.locator(".motion-banner [data-motion-original]").count() == 1, f"{variant} disabled preview uses original glyph")
                page.locator("#motion-enabled").check()
                check(page.locator("canvas[data-motion-live]").count() == 1, f"{variant} restores selected character")

            page.locator("#motion-theme-original").click()
            for event in EVENTS:
                page.locator(f"#motion-event-{event}").click()
                check(page.locator(f".motion-banner [data-motion-original='{event}']").count() == 1, f"original/{event} keeps existing glyph")
            check(page.locator("#motion-reduced").count() == 0, "switching back to original hides character options")

            page.locator("#motion-theme-H").click()
            page.locator("#motion-reduced").uncheck()
            page.emulate_media(reduced_motion="reduce")
            # Media-query change delivery belongs to the browser's rendering lifecycle. Await
            # real animation frames and capture a paint before inspecting the resulting UI.
            page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
            page.screenshot(path=str(artifacts / "prototype-live-reduce-motion.png"), full_page=True)
            page.wait_for_function("window.animationSettingsReview.getState().systemReducedMotion")
            try:
                page.wait_for_function("document.querySelector('#motion-reduced')?.checked && document.querySelector('#motion-reduced')?.disabled", timeout=2000)
                media_change_updated_controls = True
            except PlaywrightTimeoutError:
                media_change_updated_controls = False
            report["dynamicReducedMotionObservation"] = {
                "state": get_state(),
                "browserMediaMatches": page.evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches"),
                "checkbox": page.locator("#motion-reduced").evaluate("node => ({checked:node.checked, disabled:node.disabled, html:node.outerHTML})"),
            }
            check(media_change_updated_controls, "live system Reduce Motion change updates visible control state", fatal=False)
            check(page.evaluate("window.animationAudioStarts") == 0, "all style and event previews never start audio")
            # A fresh media configuration models opening Settings with the user's system
            # preference already enabled. Live environment changes are exercised separately
            # through the production SwiftUI renderer's environment seam.
            page.emulate_media(reduced_motion="reduce")
            page.goto(url + "?variant=A&character=H&lang=zh&theme=dark", wait_until="networkidle")
            page.wait_for_function("window.animationSettingsReview !== undefined")
            page.wait_for_function("window.animationSettingsReview.getState().systemReducedMotion")
            page.wait_for_function("document.querySelector('#motion-reduced')?.checked && document.querySelector('#motion-reduced')?.disabled")
            check(page.locator("#motion-reduced").is_checked() and page.locator("#motion-reduced").is_disabled(), "system Reduce Motion takes precedence at initial load")
            check(not get_state()["playing"], "system Reduce Motion stops scheduling")
            animation = manifests["H"]["animations"][get_state()["event"]]
            check(canvas_bytes(page) == rgba_frame(atlases["H", "dark"], animation["row"], animation["reducedMotionFrame"]), "system Reduce Motion displays declared frame")
            check(page.evaluate("window.animationAudioStarts") == 0, "system Reduce Motion preview never starts audio")
            page.emulate_media(reduced_motion="no-preference")
            page.goto(url + "?variant=A&character=H&lang=zh&theme=dark", wait_until="networkidle")
            page.wait_for_function("window.animationSettingsReview !== undefined")
            page.locator("#motion-event-notification").click()
            page.locator("#motion-replay").click()
            check(get_state()["playing"], "replay starts independent preview")
            page.wait_for_function("!window.animationSettingsReview.getState().playing", timeout=5500)
            reference = json.loads((ROOT / "designs/pixel-motion/samples/playback-reference.json").read_text())
            final = next(sample for sample in reference["samples"] if sample["style"] == "bitcoin" and sample["action"] == "notification" and sample["elapsedMs"] == 4000)
            animation = manifests["H"]["animations"]["notification"]
            check(canvas_bytes(page) == rgba_frame(atlases["H", "dark"], animation["row"], final["frame"]), "four-second loop preview retains canonical final frame")
            page.locator("#motion-replay").click()
            check(get_state()["playing"], "preview can replay after completion")
            page.locator("#detail-back").click()
            check(not get_state()["playing"], "leaving event-animation page stops scheduling")
            check(page.locator("#motion-open").evaluate("node => node === document.activeElement"), "return restores entry focus")
            page.locator("#motion-open").click()
            page.locator("#window-close").click()
            check(not get_state()["playing"], "closing the settings preview stops scheduling")
            page.locator(".window-closed button").click()
            check(page.evaluate("window.animationAudioStarts") == 0, "all character previews never start audio")

            page.goto(url + "?variant=A&lang=en&theme=light&size=minimum", wait_until="networkidle")
            page.wait_for_function("window.animationSettingsReview !== undefined")
            check(page.locator("#page-title").inner_text() == "Event animation", "English title is localized")
            check(get_state()["theme"] == "original", "new page session returns to original")
            page.screenshot(path=str(artifacts / "prototype-english-minimum.png"), full_page=True)
            check(page.evaluate("window.animationAudioStarts") == 0, "preview never starts audio")
            check(not forbidden_requests, "preview performs no external network requests")
            check(not page_errors, "prototype produces no page errors")
            required = {"provenance.json"} | set(provenance["files"])
            check(required.issubset(requested_resources), "prototype loads the same provenance, timing and atlases as the executable")
            report["requestedRuntimeResources"] = sorted(requested_resources)
            report["browserVersion"] = browser.version
            report["status"] = "PASS" if all(check["status"] == "PASS" for check in checks) else "FAIL"
            if report["status"] == "FAIL":
                report["failure"] = "One or more required assertions failed; see checks and dynamic media observation."
            context.close()
            browser.close()
    except Exception as error:
        missing_browser = "Executable doesn't exist" in str(error)
        report["status"] = "BLOCKED" if missing_browser else "FAIL"
        report["failure"] = str(error)
        if missing_browser:
            report["recovery"] = "Run python3 -m playwright install chromium, or pass --browser-executable explicitly."
    finally:
        report["pageErrors"] = page_errors
        report["externalRequests"] = forbidden_requests
        report_path = artifacts / "report.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"{report['status']}: {len(checks)} checks; report {report_path}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
