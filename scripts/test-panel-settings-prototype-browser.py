#!/usr/bin/env python3
"""Browser regressions for the local prototype; requires Python Playwright and Chrome.

Run from the repository root: python3 scripts/test-panel-settings-prototype-browser.py
The browser uses a temporary, offline context and never opens a personal profile.
"""

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
        activity = self.page.locator("#actBtn")
        activity.scroll_into_view_if_needed()
        box = activity.bounding_box()
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        self.assertTrue(activity.evaluate(
            "(el, p) => el.contains(document.elementFromPoint(p.x, p.y))", {"x": x, "y": y}
        ), "the visible panel control must own its hit target")
        self.page.mouse.click(x, y)
        self.assertEqual(activity.get_attribute("aria-expanded"), "true")
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
                self.page.locator('[data-mapmenu="taskStart"]').click()
                self.assertEqual(name.input_value(), typed)
                self.assertEqual(self.page.locator("#packDetail").get_by_role("heading", name=original, exact=True).count(), 1)
                self.page.locator("#langBtn").click()
                self.assertEqual(name.input_value(), typed)
                self.page.locator("#draftNameSave").click()
                self.assertEqual(name.input_value(), "Evening cue")
                self.assertEqual(self.page.locator("#packDetail").get_by_role("heading", name="Evening cue", exact=True).count(), 1)
                self.page.locator("#discardDraftBtn").click()
                self.page.locator("#newPackBtn").click()
                self.assertNotEqual(name.input_value(), "Evening cue")

    def test_zero_activity_keeps_four_visible_hollow_segments(self):
        self.open(panel="1")
        self.page.evaluate("""S.activity = true;
            S.usage.today = {taskStart: 0, stop: 0, stopFailure: 0, notification: 0, subagentStop: 0};
            render();""")
        segments = self.page.locator(".act-bar > span")
        self.assertEqual(segments.count(), 4)
        for segment in segments.all():
            self.assertGreater(segment.bounding_box()["width"], 0)
            self.assertEqual(segment.evaluate("el => getComputedStyle(el).backgroundColor"), "rgba(0, 0, 0, 0)")
            self.assertEqual(segment.evaluate("el => getComputedStyle(el).borderTopStyle"), "solid")

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


if __name__ == "__main__":
    unittest.main()
