#!/usr/bin/env python3
"""Browser regressions for the local prototype; requires Python Playwright and Chrome.

Run from the repository root: python3 scripts/test-panel-settings-prototype-browser.py
The browser uses a temporary, offline context and never opens a personal profile.
"""

import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import sync_playwright


PROTOTYPE = (
    Path(__file__).resolve().parent.parent
    / "designs/panel-and-settings/Panel and Settings Prototype.html"
)


class PanelSettingsPrototypeBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.chromium.launch(channel="chrome", headless=True)
        cls.addClassCleanup(cls.browser.close)

    def setUp(self):
        self.context = self.browser.new_context(
            viewport={"width": 1300, "height": 1000},
            reduced_motion="reduce",
            offline=True,
        )
        self.addCleanup(self.context.close)
        self.page = self.context.new_page()
        self.page_errors = []
        self.page.on("pageerror", lambda error: self.page_errors.append(str(error)))

    def tearDown(self):
        self.assertEqual(self.page_errors, [], "the real inline script must run without errors")

    def open(self, **query):
        self.page.goto(PROTOTYPE.as_uri() + "?" + urlencode({"clean": "1", **query}))

    def banner_track_sample(self):
        return self.page.locator("#banner .track > i").evaluate("""el => ({
            fraction: el.getBoundingClientRect().width / el.parentElement.getBoundingClientRect().width,
            opacity: Number(getComputedStyle(el).opacity),
            time: performance.now()
        })""")

    def open_banner(self, reduced_motion="no-preference"):
        self.page.emulate_media(reduced_motion=reduced_motion)
        self.page.mouse.move(0, 0)
        self.open()
        self.page.evaluate("showNoticeScene('permission')")

    def test_banner_reading_track_has_the_visible_event_color(self):
        self.page.emulate_media(reduced_motion="no-preference")
        for theme in ["light", "dark"]:
            for scene in [
                "permission", "needsInput", "interrupted", "review",
                "stop", "subagent", "question", "taskStart",
            ]:
                with self.subTest(theme=theme, scene=scene):
                    self.open(th=theme)
                    self.page.evaluate("kind => showNoticeScene(kind)", scene)
                    colors = self.page.locator("#banner").evaluate("""el => ({
                        track: getComputedStyle(el.querySelector('.track > i')).backgroundColor,
                        event: getComputedStyle(el.querySelector('.spine')).backgroundColor,
                        height: el.querySelector('.track').getBoundingClientRect().height
                    })""")
                    self.assertEqual(colors["height"], 2)
                    self.assertNotEqual(colors["event"], "rgba(0, 0, 0, 0)")
                    evidence = None
                    if colors["track"] != colors["event"]:
                        evidence = Path(tempfile.mkdtemp(prefix="claudio-banner-track-red-")) / f"{theme}-{scene}.png"
                        self.page.screenshot(path=str(evidence))
                    self.assertEqual(colors["track"], colors["event"], f"visible event color; screenshot: {evidence}")

    def test_banner_reading_track_shrinks_over_its_four_second_budget(self):
        self.open_banner()
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        first = self.banner_track_sample()
        self.assertGreater(first["fraction"], .95)
        self.assertEqual(first["opacity"], 1)
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .75;
        }""")
        second = self.banner_track_sample()
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .5;
        }""")
        third = self.banner_track_sample()
        for previous, current in [(first, second), (second, third)]:
            self.assertGreater(previous["fraction"], current["fraction"])
            self.assertAlmostEqual(
                previous["fraction"] - current["fraction"],
                (current["time"] - previous["time"]) / 4000,
                delta=.035,
            )
        self.page.wait_for_function("!S.bannerAtn")
        elapsed = self.page.evaluate("performance.now()") - first["time"]
        self.assertGreater(elapsed, 3800)
        self.assertLess(elapsed, 4500)
        self.page.locator("#banner").wait_for(state="detached")
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_banner_reading_track_pauses_for_overlapping_hover_and_focus(self):
        self.open_banner()
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .85;
        }""")
        self.page.locator("#banner").hover()
        hovered = self.banner_track_sample()
        self.page.wait_for_timeout(650)
        self.assertAlmostEqual(self.banner_track_sample()["fraction"], hovered["fraction"], delta=.006)
        self.page.locator("#bannerAct").focus()
        self.page.mouse.move(0, 0)
        focused = self.banner_track_sample()
        self.page.wait_for_timeout(650)
        self.assertAlmostEqual(self.banner_track_sample()["fraction"], focused["fraction"], delta=.006)
        self.assertAlmostEqual(focused["fraction"], hovered["fraction"], delta=.006)
        self.page.locator("#mbIcon").focus()
        self.page.wait_for_function("""fraction => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < fraction - .08;
        }""", arg=focused["fraction"])
        resumed = self.banner_track_sample()
        self.assertLess(resumed["fraction"], focused["fraction"] - .08)

    def test_banner_failure_and_retry_keep_the_remaining_reading_track(self):
        self.open_banner()
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        self.page.locator("#foldBtn").click()
        self.page.locator("#bannerFailureBtn").click()
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .7;
        }""")
        before_failure = self.banner_track_sample()
        self.page.locator("#bannerAct").click()
        self.assertTrue(self.page.locator("#banner .banner-error").is_visible())
        self.assertEqual(self.page.locator("#bannerAct").inner_text(), "重试")
        after_failure = self.banner_track_sample()
        self.assertLessEqual(after_failure["fraction"], before_failure["fraction"] + .006)
        self.page.mouse.move(0, 0)
        self.page.locator("#mbIcon").focus()
        self.page.wait_for_function("""fraction => {
            const fill = document.querySelector('#banner .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < fraction - .08;
        }""", arg=after_failure["fraction"])
        self.page.locator("#bannerFailureBtn").click()
        before_retry = self.banner_track_sample()
        self.page.locator("#bannerAct").click()
        self.assertTrue(self.page.locator("#banner .banner-error").is_visible())
        self.assertLessEqual(self.banner_track_sample()["fraction"], before_retry["fraction"] + .006)
        self.page.locator("#bannerAct").click()
        self.page.locator("#banner").wait_for(state="detached")
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_reduced_motion_keeps_a_static_track_and_expires_the_budget(self):
        self.open_banner(reduced_motion="reduce")
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        first = self.banner_track_sample()
        self.assertAlmostEqual(first["fraction"], 1, delta=.001)
        self.assertEqual(first["opacity"], .3)
        self.page.wait_for_timeout(1100)
        second = self.banner_track_sample()
        self.assertAlmostEqual(second["fraction"], 1, delta=.001)
        self.assertEqual(second["opacity"], .3)
        self.page.wait_for_function("!S.bannerAtn")
        elapsed = self.page.evaluate("performance.now()") - first["time"]
        self.assertGreater(elapsed, 3800)
        self.assertLess(elapsed, 4500)
        self.page.locator("#banner").wait_for(state="detached")
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_panel_wordmark_has_no_retired_decoration(self):
        self.open(panel="1")
        self.assertEqual(self.page.locator(".p-head .word").inner_text(), "claudi0")
        self.assertEqual(self.page.locator(".p-head .dot").count(), 0)
        self.assertEqual(self.page.locator("#gearBtn").count(), 1)

    def test_panel_controls_receive_clicks_above_retained_settings(self):
        self.open(win="1", pane="general")
        self.page.locator('[data-pref="launchLogin"]').click()
        settings_state = self.page.evaluate("[S.pane, S.prefs.launchLogin, S.returnToPanel]")
        self.page.locator("#mbIcon").click()
        control = self.page.locator('[data-mute="stop"]')
        original = control.get_attribute("aria-pressed")
        control.scroll_into_view_if_needed()
        box = control.bounding_box()
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        self.assertTrue(control.evaluate(
            "(el, p) => el.contains(document.elementFromPoint(p.x, p.y))", {"x": x, "y": y}
        ), "the visible panel control must own its hit target")
        self.page.mouse.click(x, y)
        self.assertNotEqual(control.get_attribute("aria-pressed"), original)
        self.assertTrue(self.page.locator("#window").is_visible())
        self.assertEqual(self.page.evaluate("[S.pane, S.prefs.launchLogin, S.returnToPanel]"), settings_state)

    def test_escape_from_panel_preserves_settings_and_cancels_panel_layers(self):
        for entry in ["direct", "gear"]:
            with self.subTest(entry=entry):
                if entry == "gear":
                    self.open(panel="1")
                    self.page.locator("#gearBtn").click()
                else:
                    self.open(win="1", pane="general")
                self.page.locator('[data-pref="launchLogin"]').click()
                settings_state = self.page.evaluate("[S.pane, S.prefs.launchLogin, S.returnToPanel]")
                self.page.locator("#mbIcon").click()
                self.page.locator("#scopeBtn").click()
                self.page.keyboard.press("Escape")
                self.assertTrue(self.page.locator("#window").is_visible())
                self.assertTrue(self.page.locator("#popover").is_visible())
                self.assertEqual(self.page.locator("#scopeBtn").get_attribute("aria-expanded"), "false")
                self.page.keyboard.press("Escape")
                self.assertFalse(self.page.locator("#popover").is_visible())
                self.assertTrue(self.page.locator("#window").is_visible())
                self.assertEqual(self.page.evaluate("[S.pane, S.prefs.launchLogin, S.returnToPanel]"), settings_state)

    def test_escape_from_settings_uses_settings_handback(self):
        self.open(panel="1")
        self.page.locator("#gearBtn").click()
        self.page.locator("#mbIcon").click()
        self.page.locator('[data-pane="general"]').click()
        self.page.keyboard.press("Escape")
        self.assertFalse(self.page.locator("#window").is_visible())
        self.assertTrue(self.page.locator("#popover").is_visible())
        self.assertTrue(self.page.locator("#gearBtn").evaluate("el => el === document.activeElement"))

    def assert_paste_does_not_record_shortcut(self):
        # Observe the real key event after the app listener; no clipboard or personal data is read.
        self.page.evaluate("""window.pasteWasPrevented = null;
            document.addEventListener('keydown', e => {
                if (e.key.toLowerCase() === 'v' && e.metaKey) window.pasteWasPrevented = e.defaultPrevented;
            });""")
        self.page.keyboard.press("Meta+v")
        self.assertEqual(self.page.evaluate("S.prefs.scPanel"), "⌃⌥C")
        self.assertIs(self.page.evaluate("window.pasteWasPrevented"), False)
        self.assertIsNone(self.page.evaluate("S.prefs.recording"))

    def test_leaving_shortcuts_cancels_recording_and_allows_paste(self):
        self.open(win="1", pane="shortcuts")
        self.page.locator('[data-rec="togglePanel"]').click()
        self.page.locator('[data-pane="general"]').click()
        self.assert_paste_does_not_record_shortcut()
        self.page.locator('[data-pane="shortcuts"]').click()
        self.assertEqual(self.page.locator('[data-rec="togglePanel"]').inner_text(), "录制")

    def test_closing_settings_cancels_recording_and_allows_paste(self):
        self.open(win="1", pane="shortcuts")
        self.page.locator('[data-rec="togglePanel"]').click()
        self.page.locator("#winClose").click()
        self.assertFalse(self.page.locator("#window").is_visible())
        self.assert_paste_does_not_record_shortcut()

    def test_recording_only_captures_keys_in_its_focused_control(self):
        self.open(win="1", pane="shortcuts")
        record = self.page.locator('[data-rec="togglePanel"]')
        record.click()
        self.page.locator("#mbIcon").click()
        self.page.locator("#scopeBtn").click()
        self.assert_paste_does_not_record_shortcut()
        self.page.keyboard.press("Escape")
        self.assertTrue(self.page.locator("#window").is_visible())
        self.page.keyboard.press("Escape")
        record.click()
        self.page.keyboard.press("Meta+k")
        self.assertEqual(self.page.evaluate("S.prefs.scPanel"), "⌘K")
        self.assertIsNone(self.page.evaluate("S.prefs.recording"))

    def test_unsaved_draft_name_survives_mapping_and_language_reprojection(self):
        for lang in ["zh", "en"]:
            with self.subTest(lang=lang):
                self.open(win="1", pane="sounds", lang=lang, clean="0")
                self.page.locator("#newPackBtn").click()
                name = self.page.locator("#draftNameInput")
                original = name.input_value()
                typed = "  Evening cue  "
                name.fill(typed)
                self.page.locator('[data-aiev="taskStart"]').click()
                self.assertEqual(name.input_value(), typed)
                self.assertEqual(self.page.locator("#packDetail").get_by_role("heading", name=original, exact=True).count(), 1)
                self.page.locator("#foldBtn").click()
                self.page.locator("#langBtn").click()
                self.assertEqual(name.input_value(), typed)
                self.page.locator("#draftNameSave").click()
                self.assertEqual(name.input_value(), "Evening cue")
                self.assertEqual(self.page.locator("#packDetail").get_by_role("heading", name="Evening cue", exact=True).count(), 1)
                self.page.locator("#discardDraftBtn").click()
                self.page.locator("#newPackBtn").click()
                self.assertNotEqual(name.input_value(), "Evening cue")

    def test_panel_activity_is_static_and_zero_counts_remain_readable(self):
        for lang in ["zh", "en"]:
            with self.subTest(lang=lang):
                self.open(panel="1", lang=lang)
                self.page.evaluate("""S.usage.today = {taskStart: 0, stop: 0, stopFailure: 0, notification: 0, subagentStop: 0};
                    S.usage.week = {...S.usage.today}; render();""")
                summary = self.page.locator("#activitySummary")
                self.assertEqual(summary.inner_text(), "今日 0 次 · 近 7 日 0 次" if lang == "zh" else "0 today · 0 last 7 days")
                self.assertEqual(summary.evaluate("el => el.tagName"), "DIV")
                self.assertIsNone(summary.get_attribute("tabindex"))
                self.assertEqual(self.page.locator("#actBtn, #activityContent, .act-bar").count(), 0)
                self.assertEqual(self.page.locator("#popover [id^='event-source-']").count(), 0)
                self.assertEqual(self.page.locator("#popover .ev-reason").count(), 0)

    def test_sidebar_width_follows_the_actual_window_boundary(self):
        self.open(win="1", pane="general")
        for viewport, window, sidebar in [
            (1300, 1240, 252), (1161, 1101, 252), (1160, 1100, 210),
            (1020, 960, 210), (900, 876, 210),
        ]:
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size({"width": viewport, "height": 1000})
                self.assertAlmostEqual(self.page.locator("#window").bounding_box()["width"], window)
                self.assertAlmostEqual(self.page.locator("#wSide").bounding_box()["width"], sidebar)
                self.assertLessEqual(
                    self.page.evaluate("document.documentElement.scrollWidth"), viewport
                )

    def test_settings_navigation_focuses_the_heading_then_the_first_control(self):
        for lang in ["zh", "en"]:
            with self.subTest(lang=lang):
                self.open(panel="1", lang=lang)
                self.page.locator("#gearBtn").click()
                heading = self.page.locator("#wMain").get_by_role("heading", level=1)
                self.assertTrue(heading.evaluate("el => el === document.activeElement"))
                self.page.evaluate("S.ws = 'ws1'; S.scope = 'ws1'; S.applyScope = 'ws1'; render();")
                for pane in [
                    "integrations", "groups", "notifications", "sounds", "activity",
                    "shortcuts", "about", "general",
                ]:
                    self.page.locator(f'[data-pane="{pane}"]').click()
                    self.assertTrue(heading.evaluate("el => el === document.activeElement"), pane)
                    self.assertEqual(self.page.evaluate("[S.ws, S.scope]"), ["ws1", "ws1"])
                self.page.locator('[data-pane="general"]').click()
                self.assertTrue(heading.evaluate("el => el === document.activeElement"))
                self.page.keyboard.press("Tab")
                self.assertTrue(self.page.locator('[data-pref="launchLogin"]').evaluate(
                    "el => el === document.activeElement"
                ))

    def test_integration_groups_entry_focuses_heading_and_preserves_workspace(self):
        self.open(win="1", pane="integrations")
        self.page.evaluate("S.ws = 'ws1'; S.scope = 'ws1'; S.applyScope = 'ws1'; render();")
        self.page.locator('[data-host="claude"]').click()
        self.page.locator("[data-goto-groups]").click()
        self.assertEqual(self.page.evaluate("S.pane"), "groups")
        self.assertEqual(self.page.evaluate("[S.ws, S.scope]"), ["ws1", "ws1"])
        self.assertTrue(self.page.locator("#wMain").get_by_role("heading", level=1).evaluate(
            "el => el === document.activeElement"
        ))

    def test_eight_pages_share_background_and_three_sidebar_groups(self):
        for theme, background in [("light", "rgb(250, 248, 244)"), ("dark", "rgb(26, 24, 21)")]:
            for pane in ["groups", "sounds", "integrations", "notifications", "general", "shortcuts", "activity", "about"]:
                with self.subTest(theme=theme, pane=pane):
                    self.open(win="1", pane=pane, th=theme)
                    self.assertEqual(self.page.locator("#wMain").evaluate(
                        "el => getComputedStyle(el).backgroundColor"
                    ), background)
                    rows = self.page.locator(".w-item[data-pane]").evaluate_all(
                        "els => els.map(el => ({pane: el.dataset.pane, top: el.getBoundingClientRect().top, bottom: el.getBoundingClientRect().bottom}))"
                    )
                    self.assertEqual([row["pane"] for row in rows], [
                        "groups", "sounds", "integrations", "notifications", "general", "shortcuts", "activity", "about"
                    ])
                    for index in range(1, len(rows)):
                        self.assertAlmostEqual(
                            rows[index]["top"] - rows[index - 1]["bottom"],
                            24 if index in [4, 6] else 3,
                        )

    def test_scope_and_sound_cards_keep_boundaries_and_grow_with_ai_form(self):
        for pane, info in [("groups", ".scope-configuration"), ("sounds", ".pack-information")]:
            for theme, surface in [("light", "rgb(255, 255, 255)"), ("dark", "rgb(28, 26, 23)")]:
                with self.subTest(pane=pane, theme=theme):
                    self.open(win="1", pane=pane, th=theme)
                    if pane == "sounds":
                        self.page.locator("#newPackBtn").click()
                    selector = self.page.locator(".catalog-select")
                    self.assertGreaterEqual(selector.bounding_box()["height"], 70)
                    tiles = self.page.locator(".event-tile")
                    self.assertEqual(tiles.count(), 5)
                    boxes = [tiles.nth(index).bounding_box() for index in range(5)]
                    for index in range(5):
                        style = tiles.nth(index).evaluate(
                            "el => { const s = getComputedStyle(el); return [s.backgroundColor, s.borderTopWidth, s.borderRadius]; }"
                        )
                        self.assertEqual(style, [surface, "1px", "13px"])
                        if index:
                            self.assertAlmostEqual(boxes[index]["y"] - boxes[index - 1]["y"] - boxes[index - 1]["height"], 12)
                    information = self.page.locator(info).bounding_box()
                    self.assertAlmostEqual(boxes[0]["y"] - information["y"] - information["height"], 24)
                    if pane == "sounds":
                        self.page.locator('[data-aiev="taskStart"]').click()
                        expanded = tiles.nth(0).bounding_box()
                        following = tiles.nth(1).bounding_box()
                        self.assertGreater(expanded["height"], boxes[0]["height"])
                        self.assertAlmostEqual(following["y"] - expanded["y"] - expanded["height"], 12)


if __name__ == "__main__":
    unittest.main()
