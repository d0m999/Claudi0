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
        self.page.set_default_timeout(5000)
        self.page_errors = []
        self.page.on("pageerror", lambda error: self.page_errors.append(str(error)))

    def tearDown(self):
        self.assertEqual(self.page_errors, [], "the real inline script must run without errors")

    def open(self, **query):
        self.page.goto(PROTOTYPE.as_uri() + "?" + urlencode({"clean": "1", **query}))

    def banner_track_sample(self):
        return self.page.locator("[data-notice] .track > i").evaluate("""el => ({
            fraction: el.getBoundingClientRect().width / el.parentElement.getBoundingClientRect().width,
            opacity: Number(getComputedStyle(el).opacity),
            time: performance.now()
        })""")

    def open_banner(self, reduced_motion="no-preference"):
        self.page.emulate_media(reduced_motion=reduced_motion)
        self.page.mouse.move(0, 0)
        self.open()
        self.page.evaluate("showNoticeScene('permission')")
        self.page.wait_for_function("NoticeClock.clocks.size && [...NoticeClock.clocks.values()].every(clock => !clock.pauses.has('entrance'))")

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
                    colors = self.page.locator("[data-notice]").evaluate("""el => ({
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
            const fill = document.querySelector('[data-notice] .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .75;
        }""")
        second = self.banner_track_sample()
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('[data-notice] .track > i');
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
        self.page.wait_for_function("!S.banners.length")
        elapsed = self.page.evaluate("performance.now()") - first["time"]
        self.assertGreater(elapsed, 3800)
        self.assertLess(elapsed, 4500)
        self.page.locator("[data-notice]").wait_for(state="detached")
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_banner_reading_track_pauses_for_overlapping_hover_and_focus(self):
        self.open_banner()
        self.page.wait_for_function("""() => {
            const fill = document.querySelector('[data-notice] .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .85;
        }""")
        self.page.locator("[data-notice]").hover()
        hovered = self.banner_track_sample()
        self.page.wait_for_timeout(650)
        self.assertAlmostEqual(self.banner_track_sample()["fraction"], hovered["fraction"], delta=.006)
        self.page.locator("[data-banner-action]").focus()
        self.page.mouse.move(0, 0)
        focused = self.banner_track_sample()
        self.page.wait_for_timeout(650)
        self.assertAlmostEqual(self.banner_track_sample()["fraction"], focused["fraction"], delta=.006)
        self.assertAlmostEqual(focused["fraction"], hovered["fraction"], delta=.006)
        self.page.locator("#mbIcon").focus()
        self.page.wait_for_function("""fraction => {
            const fill = document.querySelector('[data-notice] .track > i');
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
            const fill = document.querySelector('[data-notice] .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < .7;
        }""")
        before_failure = self.banner_track_sample()
        self.page.locator("[data-banner-action]").click()
        self.assertTrue(self.page.locator("[data-notice] .banner-error").is_visible())
        self.page.wait_for_function("S.banners[0].failure === 'unavailable'")
        self.assertEqual(self.page.locator("[data-banner-action]").inner_text(), "重试")
        after_failure = self.banner_track_sample()
        self.assertLessEqual(after_failure["fraction"], before_failure["fraction"] + .006)
        self.page.mouse.move(0, 0)
        self.page.locator("#mbIcon").focus()
        self.page.wait_for_function("""fraction => {
            const fill = document.querySelector('[data-notice] .track > i');
            return fill && fill.getBoundingClientRect().width / fill.parentElement.getBoundingClientRect().width < fraction - .08;
        }""", arg=after_failure["fraction"])
        self.page.locator("#bannerFailureBtn").click()
        before_retry = self.banner_track_sample()
        self.page.locator("[data-banner-action]").click()
        self.assertTrue(self.page.locator("[data-notice] .banner-error").is_visible())
        self.assertLessEqual(self.banner_track_sample()["fraction"], before_retry["fraction"] + .006)
        self.page.wait_for_function("S.banners[0].failure === 'unavailable'")
        self.page.locator("[data-banner-action]").click()
        self.page.wait_for_function("S.banners[0].failure === 'fallback'")
        self.assertIn("未定位到会话", self.page.locator("[data-notice] .banner-error").inner_text())
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
        self.page.wait_for_function("!S.banners.length")
        elapsed = self.page.evaluate("performance.now()") - first["time"]
        self.assertGreater(elapsed, 3800)
        self.assertLess(elapsed, 4500)
        self.page.locator("[data-notice]").wait_for(state="detached")
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_banner_stack_preserves_abc_and_promotes_a_waiting_event_with_a_full_budget(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        self.page.evaluate("showNoticeBurst(true)")
        self.page.locator("#bannerStack").hover()
        self.assertEqual(self.page.locator("[data-notice]").count(), 3)
        self.assertEqual(self.page.evaluate("S.banners.map(x => x.event)"), ["stop", "subagent", "permission"])
        self.assertEqual(self.page.locator("[data-banner-body]").count(), 3)
        self.assertEqual(self.page.locator("[data-banner-action]").count(), 1)
        self.page.evaluate("showNoticeBurst(false)")
        self.assertEqual(self.page.evaluate("S.bannerQueue.map(x => x.id)"), [4, 5, 6])
        self.assertFalse(self.page.evaluate("NoticeClock.clocks.has(4)"))
        self.page.locator("#bannerOverflow").click()
        self.assertEqual(self.page.locator(".banner-queue-row").count(), 3)
        self.page.evaluate("window.retainedBanner = document.getElementById('banner-3')")
        self.page.locator('[data-banner-close="1"]').click()
        self.assertEqual(self.page.evaluate("S.banners.map(x => x.id)"), [2, 3, 4])
        self.assertTrue(self.page.evaluate("window.retainedBanner === document.getElementById('banner-3')"))
        self.assertAlmostEqual(self.page.evaluate("NoticeClock.clocks.get(4).left()"), 4000, delta=50)
        self.assertEqual(self.page.evaluate("S.bannerQueue.map(x => x.id)"), [5, 6])

    def test_panel_application_fallback_preserves_its_banner_and_waiting_events(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
        self.page.locator("#bannerStack").hover()
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        self.page.evaluate("window.retainedBanner = document.getElementById('banner-1')")
        self.assertEqual(self.page.evaluate("S.banners.map(x => x.id)"), [1, 2, 3])
        self.assertEqual(self.page.evaluate("S.bannerQueue.map(x => x.id)"), [4, 5, 6])
        reminder = self.page.evaluate("S.banners.find(x => x.id === 3).reminderID")

        self.page.locator("#mbIcon").click()
        self.page.locator("#needsBtn").click()
        self.page.locator(f'[data-reminder="{reminder}"]').click()
        self.page.locator(f'[data-opensource="{reminder}"]').click()

        self.page.wait_for_function("S.banners.find(x => x.id === 3).failure === 'fallback'")
        self.assertEqual(self.page.evaluate("S.banners.map(x => x.id)"), [1, 2, 3])
        self.assertEqual(self.page.evaluate("S.bannerQueue.map(x => x.id)"), [4, 5, 6])
        self.assertEqual(self.page.locator("[data-notice]").count(), 3)
        self.assertTrue(self.page.evaluate("window.retainedBanner === document.getElementById('banner-1')"))
        self.assertFalse(self.page.evaluate("NoticeClock.clocks.has(4)"))
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_stack_escape_clears_visible_and_waiting_but_keeps_reminders(self):
        self.open()
        self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        self.page.locator('[data-banner-close="2"]').focus()
        self.page.keyboard.press("Escape")
        self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 0)
        self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)
        self.assertEqual(self.page.locator("[data-notice]").count(), 0)

    def test_queue_expansion_pauses_all_reading_after_focus_and_hover_leave(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
        self.page.locator("#bannerOverflow").click()
        self.page.mouse.move(0, 0)
        self.page.locator("#mbIcon").focus()
        first = self.page.evaluate("[...NoticeClock.clocks.values()].map(c => c.left())")
        self.page.wait_for_timeout(650)
        later = self.page.evaluate("[...NoticeClock.clocks.values()].map(c => c.left())")
        for a, b in zip(first, later):
            self.assertAlmostEqual(a, b, delta=8)
        self.assertTrue(self.page.evaluate("[...NoticeClock.clocks.values()].every(c => c.pauses.has('queueExpansion'))"))

    def test_queued_attention_uses_its_reminder_source_before_and_after_promotion(self):
        for language in ["zh", "en"]:
            for scene in ["needsInput", "interrupted"]:
                with self.subTest(language=language, scene=scene):
                    self.open(lang=language)
                    self.page.evaluate("showNoticeBurst(true); NoticeClock.pause('test', true)")
                    self.page.evaluate("scene => showNoticeScene(scene)", scene)
                    queued = self.page.evaluate("S.bannerQueue[0]")
                    reminder = self.page.evaluate("id => REMINDERS.find(r => r.id === id)", queued["reminderID"])
                    self.assertEqual(queued["host"], reminder["host"])
                    self.assertEqual(queued["project"], reminder["proj"])
                    self.page.locator("#bannerOverflow").click()
                    row = self.page.locator(".banner-queue-row")
                    self.assertIn(reminder["host"], row.inner_text())
                    self.assertIn(reminder["proj"], row.inner_text())
                    self.page.locator('[data-banner-close="1"]').click()
                    banner = self.page.locator(f'#banner-{queued["id"]}')
                    self.assertIn(reminder["host"], banner.inner_text())
                    self.assertIn(reminder["proj"], banner.inner_text())

    def test_resize_preserves_fifo_budget_and_zero_card_entry_opens_panel(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
        self.page.wait_for_function("[...NoticeClock.clocks.values()].every(c => !c.pauses.has('entrance'))")
        self.page.wait_for_timeout(500)
        self.page.evaluate("NoticeClock.pause('test',true)")
        saved = self.page.evaluate("NoticeClock.clocks.get(2).left()")
        self.page.set_viewport_size({"width":1300, "height":300})
        self.page.wait_for_function("S.banners.length === 1")
        self.assertEqual(self.page.evaluate("S.banners.map(n => n.id)"), [1])
        self.assertEqual(self.page.evaluate("S.bannerQueue.map(n => n.id)"), [2, 3, 4, 5, 6])
        self.page.wait_for_timeout(500)
        self.assertAlmostEqual(self.page.evaluate("NoticeClock.clocks.get(2).left()"), saved, delta=8)
        self.page.set_viewport_size({"width":1300, "height":1000})
        self.page.wait_for_function("S.banners.length === 3")
        self.assertAlmostEqual(self.page.evaluate("NoticeClock.clocks.get(2).left()"), saved, delta=8)
        self.assertEqual(self.page.locator("#banner-2").evaluate("n => n.getAnimations().length"), 0)
        self.page.set_viewport_size({"width":1300, "height":160})
        self.page.wait_for_function("S.banners.length === 0")
        self.assertTrue(self.page.locator("#bannerOverflow").is_visible())
        self.page.locator("#bannerOverflow").click()
        self.assertTrue(self.page.evaluate("S.popover && S.needs === 'list'"))

    def test_veil_only_changes_background_and_decoration_and_exit_keeps_its_layer(self):
        for theme in ["light", "dark"]:
            self.open(th=theme)
            self.page.evaluate("showNoticeScene('permission'); showNoticeScene('permission'); showNoticeScene('permission')")
            styles = self.page.locator("[data-notice]").evaluate_all("""nodes => nodes.map(n => ({
                veil:getComputedStyle(n,'::before').opacity,
                text:getComputedStyle(n.querySelector('.cap-text .p')).color,
                textOpacity:getComputedStyle(n.querySelector('.cap-text .p')).opacity,
                actionOpacity:getComputedStyle(n.querySelector('[data-banner-action]')).opacity,
                trackOpacity:getComputedStyle(n.querySelector('.track > i')).opacity
            }))""")
            self.assertEqual([s["veil"] for s in styles], ["0", "0.2", "0.32"])
            self.assertEqual(len({s["text"] for s in styles}), 1)
            self.assertTrue(all(s["textOpacity"] == s["actionOpacity"] == "1" for s in styles))
            self.assertTrue(all(s["trackOpacity"] == "0.3" for s in styles))
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        self.page.evaluate("showNoticeBurst(true)")
        self.page.wait_for_function("[...document.querySelectorAll('[data-notice]')].every(n=>!n.getAnimations().length)")
        self.page.evaluate("closeBanner(2)")
        self.assertEqual(self.page.locator(".motion-exit.banner").evaluate("n=>getComputedStyle(n,'::before').opacity"), "0.2")

    def test_navigation_is_single_flight_and_feedback_belongs_to_each_card(self):
        self.open()
        self.page.evaluate("showNoticeScene('permission'); showNoticeScene('permission'); NoticeClock.pause('test',true); S.bannerNavigationDelay=650; S.bannerInjectFailure=true; openBannerSource(1)")
        self.page.evaluate("openBannerSource(2); closeBanner(2)")
        self.assertEqual(self.page.evaluate("S.bannerNavigationID"), 1)
        self.page.wait_for_function("S.banners.find(n=>n.id===1).failure==='unavailable'")
        self.page.evaluate("showNoticeScene('permission'); S.bannerNavigationOutcome='fallback'; openBannerSource(3)")
        self.assertEqual(self.page.evaluate("S.banners.find(n=>n.id===1).failure"), "unavailable")
        self.page.wait_for_function("S.banners.find(n=>n.id===3).failure==='fallback'")
        self.assertEqual(self.page.locator(".banner-error").count(), 2)
        self.page.evaluate("S.bannerNavigationDelay=3500; openBannerSource(1)")
        self.page.wait_for_function("S.banners.find(n=>n.id===1).failure==='timedOut'")
        self.page.wait_for_timeout(600)
        self.assertEqual(self.page.evaluate("S.banners.find(n=>n.id===1).failure"), "timedOut")

    def test_turning_reduce_motion_on_during_cascade_removes_delay_and_starts_reading(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        initial = self.page.evaluate("""() => {
            showNoticeBurst(true);
            return [...document.querySelectorAll('[data-notice]')].map(n => ({
                delay:n.getAnimations()[0].effect.getTiming().delay,
                fill:n.getAnimations()[0].effect.getTiming().fill
            }));
        }""")
        self.assertEqual([s["delay"] for s in initial], [0, 90, 180])
        self.assertTrue(all(s["fill"] == "backwards" for s in initial))
        self.page.emulate_media(reduced_motion="reduce")
        self.page.wait_for_function("Motion.reduced && [...NoticeClock.clocks.values()].every(c=>!c.pauses.has('entrance'))")
        self.assertEqual(self.page.evaluate("document.getAnimations().length"), 0)
        self.assertTrue(self.page.locator("[data-notice] .track > i").evaluate_all("nodes=>nodes.every(n=>getComputedStyle(n).opacity==='0.3')"))

    def test_panel_source_action_without_a_visible_match_keeps_all_banners_and_queue(self):
        for queued in [False, True]:
            with self.subTest(queued=queued):
                self.open()
                self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
                self.page.locator("#bannerStack").hover()
                reminder = self.page.evaluate("S.bannerQueue.find(x => x.id === 6).reminderID") if queued else "r1"
                retained = self.page.evaluate("REMINDERS.map(r => r.id)")
                self.page.locator("#mbIcon").click()
                self.page.locator("#needsBtn").click()
                self.page.locator(f'[data-reminder="{reminder}"]').click()
                self.page.locator(f'[data-opensource="{reminder}"]').click()
                self.assertEqual(self.page.evaluate("S.banners.map(x => x.id)"), [1, 2, 3])
                self.assertEqual(self.page.evaluate("S.bannerQueue.map(x => x.id)"), [4, 5, 6])
                self.assertEqual(self.page.locator("[data-notice]").count(), 3)
                self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_banner_stack_entrance_exit_and_reflow_use_the_existing_motion_durations(self):
        self.page.emulate_media(reduced_motion="no-preference")
        self.open()
        entrance = self.page.evaluate("""() => {
            showNoticeBurst(true);
            return [...document.querySelectorAll('[data-notice]')].map(node =>
                node.getAnimations().map(a => ({ duration:a.effect.getTiming().duration, frames:a.effect.getKeyframes() })));
        }""")
        self.assertEqual(len(entrance), 3)
        for animations in entrance:
            self.assertEqual(animations[0]["duration"], 180)
            self.assertEqual(animations[0]["frames"][0]["opacity"], "0")
            self.assertEqual(animations[0]["frames"][-1]["opacity"], "1")
        self.page.wait_for_function("[...document.querySelectorAll('[data-notice]')].every(node => !node.getAnimations().length)")
        previous_top = self.page.locator("#banner-2").bounding_box()["y"]
        motion = self.page.evaluate("""() => {
            closeBanner(1);
            const ghost = document.querySelector('.motion-exit.banner');
            return {
                move:document.getElementById('banner-2').getAnimations().map(a => a.effect.getTiming().duration),
                exit:ghost.getAnimations().map(a => a.effect.getTiming().duration),
                inert:ghost.inert, hidden:ghost.getAttribute('aria-hidden'),
                identities:ghost.querySelectorAll('[id], [data-notice], [data-banner-close]').length
            };
        }""")
        self.assertEqual(motion["move"], [260])
        self.assertEqual(motion["exit"], [180])
        self.assertTrue(motion["inert"])
        self.assertEqual(motion["hidden"], "true")
        self.assertEqual(motion["identities"], 0)
        self.page.wait_for_function("!document.querySelector('.motion-exit') && !document.getElementById('banner-2').getAnimations().length")
        self.assertLess(self.page.locator("#banner-2").bounding_box()["y"], previous_top - 30)

    def test_full_banner_queue_retains_distinct_attention_reminders_in_the_panel(self):
        self.open()
        self.page.evaluate("setView('desktop'); for (let i = 0; i < 50; i++) showNoticeScene('stop')")
        self.page.locator("#bannerStack").hover()
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        self.page.evaluate("""() => {
            showNoticeScene('permission', { host:'Codex', project:'api-gateway' });
            showNoticeScene('permission', { host:'Claude Code', project:'web-dashboard' });
        }""")
        self.assertEqual(self.page.evaluate("REMINDERS.length"), len(retained) + 2)
        added = self.page.evaluate("REMINDERS.slice(0, 2).map(r => ({ id:r.id, host:r.host, project:r.proj }))")
        self.assertEqual(len({r["id"] for r in added}), 2)
        self.assertEqual([(r["host"], r["project"]) for r in added],
                         [("Claude Code", "web-dashboard"), ("Codex", "api-gateway")])
        self.assertEqual(self.page.evaluate("REMINDERS.slice(2).map(r => r.id)"), retained)
        self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 50)
        self.page.locator("#mbIcon").click()
        self.page.locator("#needsBtn").click()
        for reminder in added:
            row = self.page.locator(f'[data-reminder="{reminder["id"]}"]')
            self.assertTrue(row.is_visible())
            self.assertIn(reminder["host"], row.inner_text())
            self.assertIn(reminder["project"], row.inner_text())

    def test_banner_stack_reduced_motion_has_no_animation_and_waiting_events_still_display(self):
        self.open()
        self.page.mouse.move(0, 0)
        self.page.evaluate("showNoticeBurst(true); showNoticeBurst(false)")
        self.assertEqual(self.page.evaluate("document.getAnimations().length"), 0)
        samples = self.page.locator("[data-notice] .track > i").evaluate_all("""nodes => nodes.map(el => ({
            fraction:el.getBoundingClientRect().width / el.parentElement.getBoundingClientRect().width,
            opacity:Number(getComputedStyle(el).opacity)
        }))""")
        for sample in samples:
            self.assertAlmostEqual(sample["fraction"], 1, delta=.001)
            self.assertEqual(sample["opacity"], .3)
        self.page.wait_for_function("S.banners.length === 3 && S.banners[0].id === 4")
        self.assertEqual(self.page.evaluate("S.banners.map(x => x.id)"), [4, 5, 6])
        self.assertGreater(self.page.evaluate("NoticeClock.clocks.get(4).left()"), 3800)
        self.assertEqual(self.page.evaluate("document.getAnimations().length"), 0)

    def test_banner_stack_is_readable_at_a_narrow_width_in_both_languages_and_themes(self):
        self.page.set_viewport_size({"width": 390, "height": 800})
        for language in ["zh", "en"]:
            for theme in ["light", "dark"]:
                with self.subTest(language=language, theme=theme):
                    self.open(lang=language, th=theme)
                    self.page.evaluate("showNoticeBurst(true)")
                    self.assertEqual(self.page.locator("[data-notice]").count(), 3)
                    boxes = self.page.locator("[data-notice]").evaluate_all("nodes => nodes.map(el => ({ left:el.getBoundingClientRect().left, right:el.getBoundingClientRect().right, top:el.getBoundingClientRect().top, bottom:el.getBoundingClientRect().bottom }))")
                    for box in boxes:
                        self.assertGreaterEqual(box["left"], 0)
                        self.assertLessEqual(box["right"], 390)
                    self.assertLessEqual(boxes[0]["bottom"], boxes[1]["top"])
                    self.assertLessEqual(boxes[1]["bottom"], boxes[2]["top"])

    def test_panel_wordmark_has_no_retired_decoration(self):
        self.open(panel="1")
        self.assertEqual(self.page.locator(".p-head .word").inner_text(), "claudi0")
        self.assertEqual(self.page.locator(".p-head .dot").count(), 0)
        self.assertEqual(self.page.locator("#gearBtn").count(), 1)

    def settings_state(self):
        return self.page.evaluate("MacSettings.getState()")

    def open_panel_with_write_conflict(self, language):
        self.open(panel="1", lang=language)
        self.page.locator("#gearBtn").click()
        self.page.locator("#macSettingsScene").select_option("configConflict", force=True)
        self.page.locator("#window-close").click()
        if not self.page.locator("#popover").is_visible():
            self.page.locator("#mbIcon").click()
        self.assertTrue(self.page.locator("#popover").is_visible())

    def test_panel_library_retry_refreshes_the_shared_owner_before_writing(self):
        self.open(panel="1")
        self.page.locator("#gearBtn").click()
        self.page.locator("#macSettingsScene").select_option("libraryStale", force=True)
        self.page.locator("#window-close").click()
        if not self.page.locator("#popover").is_visible():
            self.page.locator("#mbIcon").click()
        self.assertEqual(self.settings_state()["library"], "stale")
        original = self.settings_state()["scopes"]
        self.page.locator('#popover [data-library-retry]').click()
        self.page.wait_for_function("MacSettings.getState().library === 'ready'")
        self.assertEqual(self.page.evaluate("S.library.status"), "ready")
        self.assertEqual(self.settings_state()["scopes"], original)
        self.assertEqual(self.page.locator('#popover [data-library-retry]').count(), 0)
        self.page.locator("#panelPack").select_option("soft")
        self.assertEqual(self.settings_state()["scopes"][0]["pack"], "soft")
        self.assertEqual(self.page.locator("#panelPack").input_value(), "soft")

    def test_first_settings_show_preserves_the_selected_scene_detail(self):
        for previously_opened in [False, True]:
            for scene, detail in [("draft", "edit:task_start"), ("partial", "edit:notification")]:
                with self.subTest(previously_opened=previously_opened, scene=scene):
                    self.open()
                    if previously_opened:
                        self.page.locator("#viewWindow").click()
                        self.page.locator("#window-close").click()
                    self.page.locator("#macSettingsScene").select_option(scene, force=True)
                    state = self.settings_state()
                    self.assertEqual(state["page"], "sounds")
                    self.assertEqual(state["detail"], detail)
                    self.assertTrue(self.page.locator("#settings-window").is_visible())
                    if scene == "draft":
                        self.assertIsNotNone(state["draft"])
                        self.assertEqual(state["pack"], state["draft"]["id"])
                        self.assertNotIn(state["pack"], [p["id"] for p in state["packs"]])
                        self.assertTrue(self.page.locator('[data-action="rename-draft"]').is_visible())
                    else:
                        self.assertEqual(state["expandedEvent"], 3)
                        self.assertTrue(self.page.locator("#cue-description").is_visible())
                        self.page.locator('[data-action="generate"]').click()
                        self.page.wait_for_function("MacSettings.getState().candidates.length === 2")
                        self.assertEqual(self.settings_state()["detail"], detail)

    def test_disabling_banners_stops_the_stack_queue_and_navigation_but_keeps_reminders(self):
        for reduced_motion in ["reduce", "no-preference"]:
            with self.subTest(reduced_motion=reduced_motion):
                self.page.emulate_media(reduced_motion=reduced_motion)
                self.open(win="1", pane="notifications")
                self.page.evaluate("NoticeClock.pause('test', true); showNoticeBurst(false); showNoticeBurst(false); openBannerSource(3)")
                retained = self.page.evaluate("REMINDERS.map(r => r.id)")
                self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 6)
                self.assertEqual(self.page.evaluate("S.bannerNavigationID"), 3)
                self.page.locator('[data-control="notifications"]').uncheck()
                self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 0)
                self.assertEqual(self.page.evaluate("NoticeClock.clocks.size"), 0)
                self.assertIsNone(self.page.evaluate("S.bannerNavigationID"))
                self.assertEqual(self.page.locator('[data-notice], .motion-exit.banner').count(), 0)
                self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)
                self.assertEqual([r["id"] for r in self.settings_state()["pending"]], retained)
                self.page.evaluate("closeBanner(1)")
                self.page.wait_for_timeout(550)
                self.page.locator('[data-control="notifications"]').check()
                self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 0)
                self.page.evaluate("showNoticeScene('stop')")
                self.assertEqual(self.page.evaluate("S.banners.length"), 1)
                self.assertEqual(self.page.evaluate("REMINDERS.map(r => r.id)"), retained)

    def test_attention_capacity_matches_the_panel_and_settings_reading_projection(self):
        self.open(win="1", pane="activity")
        self.page.locator("#mbIcon").click()
        self.page.evaluate("NoticeClock.pause('test', true); for (let i = 0; i < 55; i++) showNoticeScene('permission')")
        retained = self.page.evaluate("REMINDERS.map(r => r.id)")
        self.assertEqual(len(retained), 50)
        self.assertTrue(self.page.locator('#banner-1 [data-banner-action="1"]').is_visible())
        self.assertEqual(self.page.locator('#banner-1 .banner-error').count(), 0)
        self.assertEqual([r["id"] for r in self.settings_state()["pending"]], retained)
        self.assertEqual(self.page.locator("#needsBtn .n").inner_text(), "50")
        self.assertEqual(self.page.locator('[data-action="toggle-pending"] .controls').inner_text(), "50")
        self.page.locator('[data-action="toggle-pending"]').click()
        self.assertEqual([r["id"] for r in self.settings_state()["reading"]], retained)
        self.assertEqual(self.page.locator('[data-action^="notice:"]').count(), 50)
        if not self.page.locator("#popover").is_visible():
            self.page.locator("#mbIcon").click()
        self.page.locator("#needsBtn").click()
        self.assertEqual(self.page.locator('#popover [data-reminder]').count(), 50)

    def test_panel_rejected_mute_write_shows_reason_and_can_retry_through_settings(self):
        for language in ["zh", "en"]:
            with self.subTest(language=language):
                self.open_panel_with_write_conflict(language)
                original = self.settings_state()["scopes"]
                mute = self.page.locator('[data-mute="notification"]')
                mute.click()
                self.assertEqual(self.settings_state()["scopes"], original)
                self.assertEqual(mute.get_attribute("aria-pressed"), "false")
                feedback = self.page.locator('#popover [role="alert"]')
                self.assertTrue(feedback.is_visible())
                self.assertIn("写入冲突" if language == "zh" else "Write conflict", feedback.inner_text())
                self.page.locator("#gearBtn").click()
                self.page.locator('[data-action="nav:events"]').click()
                self.page.locator('[data-action="retry-config"]').click()
                self.page.locator("#window-close").click()
                self.assertEqual(mute.get_attribute("aria-pressed"), "true")
                self.assertEqual(self.page.locator('#popover [role="alert"]').count(), 0)

    def test_panel_rejected_pack_write_restores_selection_and_shows_reason(self):
        for language in ["zh", "en"]:
            with self.subTest(language=language):
                self.open_panel_with_write_conflict(language)
                original = self.settings_state()["scopes"]
                for attempted_pack in ["soft", "night"]:
                    self.page.locator("#panelPack").select_option(attempted_pack)
                    self.assertEqual(self.settings_state()["scopes"], original)
                    self.assertEqual(self.page.locator("#panelPack").input_value(), "minimal")
                    feedback = self.page.locator('#popover [role="alert"]')
                    self.assertTrue(feedback.is_visible())
                    self.assertIn("写入冲突" if language == "zh" else "Write conflict", feedback.inner_text())

    def test_panel_rejected_volume_write_restores_slider_and_shows_reason(self):
        for language in ["zh", "en"]:
            with self.subTest(language=language):
                self.open_panel_with_write_conflict(language)
                original = self.settings_state()["scopes"]
                for attempted_volume in ["30", "41"]:
                    self.page.locator("#volRange").fill(attempted_volume)
                    self.assertEqual(self.settings_state()["scopes"], original)
                    self.assertEqual(self.page.locator("#volRange").input_value(), "65")
                    self.assertEqual(self.page.locator("#volPct").inner_text(), "65%")
                    feedback = self.page.locator('#popover [role="alert"]')
                    self.assertTrue(feedback.is_visible())
                    self.assertIn("写入冲突" if language == "zh" else "Write conflict", feedback.inner_text())

    def test_settings_retry_clears_the_matching_panel_write_failure(self):
        for language in ["zh", "en"]:
            for scope in ["default", "claudio"]:
                with self.subTest(language=language, scope=scope):
                    self.open_panel_with_write_conflict(language)
                    if scope != "default":
                        self.page.locator("#scopeBtn").click()
                        self.page.locator(f'[data-scope="{scope}"]').click()
                    original = self.settings_state()["scopes"]
                    self.page.locator("#volRange").fill("30")
                    self.assertEqual(self.settings_state()["scopes"], original)
                    self.assertEqual(self.settings_state()["panelWriteFailure"]["scope"], scope)
                    self.assertTrue(self.page.locator('#popover [role="alert"]').is_visible())
                    self.page.locator("#gearBtn").click()
                    self.page.locator('[data-action="nav:events"]').click()
                    self.page.locator('[data-action="retry-config"]').click()
                    updated = self.settings_state()["scopes"]
                    self.assertEqual(next(g for g in updated if g["id"] == scope)["volume"], 30)
                    self.assertEqual([g for g in updated if g["id"] != scope],
                                     [g for g in original if g["id"] != scope])
                    self.page.locator("#window-close").click()
                    self.assertEqual(self.page.locator("#volRange").input_value(), "30")
                    self.assertEqual(self.page.locator("#volPct").inner_text(), "30%")
                    self.assertIsNone(self.settings_state()["panelWriteFailure"])
                    self.assertEqual(self.page.locator('#popover [role="alert"]').count(), 0)

    def test_collapsed_settings_reminders_update_without_navigation(self):
        self.open(win="1", pane="activity")
        pending = self.page.locator('[data-action="toggle-pending"]')
        self.assertEqual(pending.get_attribute("aria-expanded"), "false")
        original = len(self.settings_state()["pending"])
        self.assertEqual(pending.locator(".controls").inner_text(), str(original))
        self.page.evaluate("showNoticeScene('permission'); NoticeClock.pause('test', true)")
        self.assertEqual(len(self.settings_state()["pending"]), original + 1)
        self.assertEqual(pending.locator(".controls").inner_text(), str(original + 1))
        self.assertFalse(self.settings_state()["pendingExpanded"])
        self.assertIsNone(self.settings_state()["reading"])

    def test_expanded_settings_reminders_keep_reading_until_explicit_refresh(self):
        self.open(win="1", pane="activity")
        self.page.locator('[data-action="toggle-pending"]').click()
        original = self.settings_state()["reading"]
        self.page.locator('[data-action="refresh-reminders"]').focus()
        self.page.locator('[data-action="refresh-reminders"]').evaluate("el => { window.readingButton = el; }")
        self.page.evaluate("showNoticeScene('permission'); NoticeClock.pause('test', true)")
        self.assertEqual(len(self.settings_state()["pending"]), len(original) + 1)
        self.assertEqual(self.settings_state()["reading"], original)
        self.assertEqual(self.page.locator('[data-action="toggle-pending"] .controls').inner_text(), str(len(original)))
        self.assertEqual(self.page.locator('[data-action^="notice:"]').count(), len(original))
        self.assertTrue(self.page.evaluate("window.readingButton.isConnected && window.readingButton === window.readingButton.getRootNode().activeElement"))
        self.page.locator('[data-action="refresh-reminders"]').click()
        self.assertEqual(len(self.settings_state()["reading"]), len(original) + 1)
        self.assertEqual(self.page.locator('[data-action^="notice:"]').count(), len(original) + 1)

    def test_closing_empty_draft_publishes_restored_pack_before_reopening(self):
        for close_control in ["#window-close", "#viewPanel"]:
            with self.subTest(close_control=close_control):
                self.open(win="1", pane="sounds")
                original = self.settings_state()
                self.page.locator('[data-action="new-pack"]').click()
                draft = self.settings_state()["draft"]["id"]
                self.assertEqual(self.page.evaluate("S.soundPack"), draft)
                self.page.locator(close_control).click()
                self.assertIsNone(self.settings_state()["draft"])
                self.assertEqual(self.settings_state()["pack"], original["pack"])
                self.assertEqual(self.page.evaluate("S.soundPack"), original["pack"])
                self.assertEqual(self.settings_state()["scopes"], original["scopes"])
                self.page.locator("#viewWindow").click()
                self.assertEqual(self.settings_state()["pack"], original["pack"])
                self.assertEqual(self.page.locator('[data-control="pack"]').input_value(), original["pack"])
                self.assertNotIn("原声音包已移除", self.page.locator("#page-content").inner_text())
                self.assertNotIn(draft, [p["id"] for p in self.settings_state()["packs"]])

    def test_full_queue_publishes_reminders_to_already_open_consumers(self):
        self.open(win="1", pane="activity")
        self.page.locator("#mbIcon").click()
        self.page.evaluate("NoticeClock.pause('test', true); for (let i = 0; i < 50; i++) showNoticeScene('stop')")
        original = self.page.evaluate("REMINDERS.map(r => r.id)")
        banners = self.page.evaluate("[...S.banners, ...S.bannerQueue].map(n => n.id)")
        self.assertEqual(len(banners), 50)
        self.page.evaluate("showNoticeScene('permission')")
        self.assertEqual(self.page.evaluate("REMINDERS.slice(1).map(r => r.id)"), original)
        self.assertEqual(self.page.evaluate("[...S.banners, ...S.bannerQueue].map(n => n.id)"), banners)
        self.assertEqual(len(self.settings_state()["pending"]), len(original) + 1)
        self.assertEqual(self.page.locator("#needsBtn .n").inner_text(), str(len(original) + 1))
        self.assertEqual(self.page.locator('[data-action="toggle-pending"] .controls').inner_text(), str(len(original) + 1))

    def test_disabled_banners_still_publish_reminders_to_open_consumers(self):
        self.open(win="1", pane="notifications")
        self.page.locator('[data-control="notifications"]').uncheck()
        self.page.locator('[data-action="nav:usage"]').click()
        self.page.locator("#mbIcon").click()
        original = len(self.settings_state()["pending"])
        self.page.evaluate("showNoticeScene('permission')")
        self.assertEqual(self.page.evaluate("S.banners.length + S.bannerQueue.length"), 0)
        self.assertEqual(len(self.settings_state()["pending"]), original + 1)
        self.assertEqual(self.page.locator("#needsBtn .n").inner_text(), str(original + 1))
        self.assertEqual(self.page.locator('[data-action="toggle-pending"] .controls').inner_text(), str(original + 1))

    def test_same_page_workspace_entry_consumes_the_new_target(self):
        self.open(panel="1")
        for workspace in ["claudio", "notes"]:
            self.page.locator("#scopeBtn").click()
            self.page.locator(f'[data-scope="{workspace}"]').click()
            self.page.locator("#editWorkspaceBtn").click()
            self.assertEqual(self.settings_state()["scope"], workspace)
            self.assertEqual(self.page.locator('[data-control="volume"]').input_value(),
                             "55" if workspace == "claudio" else "40")
            self.assertIsNone(self.settings_state()["detail"])
            if workspace == "claudio":
                self.page.locator('[data-action="scope-details"]').click()
            self.page.locator("#mbIcon").click()
        self.page.locator('[data-control="volume"]').fill("31")
        scopes = {g["id"]: g for g in self.settings_state()["scopes"]}
        self.assertEqual(scopes["notes"]["volume"], 31)
        self.assertEqual(scopes["claudio"]["volume"], 55)

    def test_unavailable_workspace_stays_unavailable_in_the_panel(self):
        for scene in ["stale", "ruleBroken"]:
            with self.subTest(scene=scene):
                self.open(panel="1")
                self.page.locator("#scopeBtn").click()
                self.page.locator('[data-scope="claudio"]').click()
                self.page.locator("#editWorkspaceBtn").click()
                self.page.locator("#macSettingsScene").select_option(scene, force=True)
                self.assertEqual(self.settings_state()["scope"], "claudio")
                self.page.locator("#window-close").click()
                if not self.page.locator("#popover").is_visible():
                    self.page.locator("#mbIcon").click()
                self.assertEqual(self.page.evaluate("S.scope"), "claudio")
                self.assertIn("不可用", self.page.locator("#popover").inner_text())
                self.assertEqual(self.page.locator("#volRange, #panelPack, [data-mute]").count(), 0)
                self.page.locator("#scopeBtn").click()
                self.page.locator('[data-scope="default"]').click()
                self.assertEqual(self.settings_state()["scope"], "default")
                self.assertEqual(self.page.locator("#volRange").input_value(), "65")

    def test_settings_removal_cleans_only_the_matching_banner_and_queue(self):
        for position in ["visible", "queued"]:
            with self.subTest(position=position):
                self.open()
                self.page.evaluate("closeBanner(); for(let i=0;i<6;i++)showNoticeScene('permission'); NoticeClock.pause('test',true)")
                before = self.page.evaluate("({visible:S.banners.map(n=>n.reminderID),queued:S.bannerQueue.map(n=>n.reminderID)})")
                removed = before["visible" if position == "visible" else "queued"][0]
                self.page.locator("#viewWindow").click()
                self.page.locator('[data-action="nav:usage"]').click()
                self.page.locator('[data-action="toggle-pending"]').click()
                self.page.locator(f'[data-action="notice:{removed}"]').click()
                self.page.locator('[data-action="remove-reminder"]').click()
                self.assertNotIn(removed, self.page.evaluate("REMINDERS.map(r=>r.id)"))
                retained = self.page.evaluate("[...S.banners,...S.bannerQueue].map(n=>n.reminderID)")
                self.assertEqual(retained, [x for x in before["visible"] + before["queued"] if x != removed])
                self.page.evaluate("S.banners.slice().forEach(n=>closeBanner(n.id))")
                self.assertNotIn(removed, self.page.evaluate("[...S.banners,...S.bannerQueue].map(n=>n.reminderID)"))

    def test_ai_deep_links_initialize_the_rendered_settings_owner(self):
        for profile in ["elevenlabs-global", "minimax-global", "qwen-singapore", "qwen-beijing", "senseaudio-cn"]:
            for lang in ["zh", "en"]:
                for scene in ["credential", "candidates", "generating", "applied"]:
                    with self.subTest(profile=profile, lang=lang, scene=scene):
                        self.open(win="1", pane="sounds", ai=scene, aiProfile=profile, lang=lang)
                        state = self.settings_state()
                        self.assertEqual(state["profile"], profile)
                        self.assertEqual(state["page"], "sounds")
                        if scene == "credential":
                            self.assertEqual(state["credentials"][profile]["status"], "missing")
                            self.assertTrue(self.page.locator("#sheet").evaluate("el=>el.open"))
                        else:
                            self.assertEqual(state["pack"], "studio")
                            self.assertEqual(state["detail"], "edit:notification")
                            if profile == "minimax-global" and lang == "en":
                                self.assertIsNone(state["generation"])
                                self.assertEqual(state["candidates"], [])
                                self.assertEqual(state["credentials"][profile]["status"], "missing")
                                self.assertTrue(self.page.locator("#cue-route-reason").inner_text())
                                continue
                            if scene == "generating":
                                self.assertEqual(state["generation"], "busy")
                                self.page.wait_for_function("MacSettings.getState().generation==='ready'")
                            elif scene == "candidates":
                                self.assertEqual(state["generation"], "ready")
                                self.assertEqual(len(state["candidates"]), 3)
                            else:
                                self.page.wait_for_function("MacSettings.getState().packs.find(p=>p.id==='studio').sounds[3]!=='knock.wav'")
                                state = self.settings_state()
                                pack = next(p for p in state["packs"] if p["id"] == "studio")
                                self.assertNotEqual(pack["sounds"][3], "knock.wav")
                                self.assertIn(pack["sounds"][3], pack["audio"])
                                self.assertNotIn("license", pack)

    def test_ai_deep_links_keep_partial_policy_and_failure_preserves_binding(self):
        for profile, count in [("senseaudio-cn", 2), ("elevenlabs-global", 3), ("qwen-singapore", 3)]:
            with self.subTest(profile=profile):
                self.open(win="1", pane="sounds", ai="candidates", aiProfile=profile, aiPartial="1")
                state = self.settings_state()
                self.assertEqual(len(state["candidates"]), count)
                self.assertTrue(all(c["profile"] == profile and c["pack"] == "studio" and c["event"] == 3
                                    for c in state["candidates"]))
        self.open(win="1", pane="sounds", ai="generating", aiFail="generation")
        self.page.wait_for_function("MacSettings.getState().generation==='failed'")
        state = self.settings_state()
        self.assertEqual(state["candidates"], [])
        self.assertEqual(next(p for p in state["packs"] if p["id"] == "studio")["sounds"][3], "knock.wav")

    def test_ai_generating_deep_link_discards_late_results_after_navigation(self):
        self.open(win="1", pane="sounds", ai="generating", aiProfile="qwen-beijing")
        self.assertEqual(self.settings_state()["generation"], "busy")
        self.page.locator('[data-action="nav:general"]').click()
        self.page.wait_for_timeout(1200)
        self.assertIsNone(self.settings_state()["generation"])
        self.assertEqual(self.settings_state()["candidates"], [])

    def test_panel_controls_receive_clicks_above_retained_settings(self):
        self.open(win="1", pane="general")
        self.page.locator('[data-control="login"]').uncheck()
        self.page.wait_for_timeout(600)
        state = self.settings_state()["login"]
        self.page.locator("#mbIcon").click()
        control = self.page.locator('[data-mute="stop"]')
        original = control.get_attribute("aria-pressed")
        control.click()
        self.assertNotEqual(control.get_attribute("aria-pressed"), original)
        self.assertTrue(self.page.locator("#window").is_visible())
        self.assertEqual(self.settings_state()["login"], state)
        self.assertEqual(self.settings_state()["scopes"][0]["enabled"][1], original == "true")

    def test_escape_from_panel_preserves_settings_and_cancels_panel_layers(self):
        for entry in ["direct", "gear"]:
            with self.subTest(entry=entry):
                self.open(panel="1") if entry == "gear" else self.open(win="1", pane="general")
                if entry == "gear":
                    self.page.locator("#gearBtn").click()
                state = self.settings_state()["page"]
                self.page.locator("#mbIcon").click()
                self.page.locator("#scopeBtn").click()
                self.page.keyboard.press("Escape")
                self.assertTrue(self.page.locator("#window").is_visible())
                self.assertEqual(self.page.locator("#scopeBtn").get_attribute("aria-expanded"), "false")
                self.page.keyboard.press("Escape")
                self.assertFalse(self.page.locator("#popover").is_visible())
                self.assertTrue(self.page.locator("#window").is_visible())
                self.assertEqual(self.settings_state()["page"], state)

    def test_escape_from_settings_uses_settings_handback(self):
        self.open(panel="1")
        self.page.locator("#gearBtn").click()
        self.page.keyboard.press("Escape")
        self.assertFalse(self.page.locator("#window").is_visible())
        self.assertTrue(self.page.locator("#popover").is_visible())
        self.assertTrue(self.page.locator("#gearBtn").evaluate("el => el === document.activeElement"))

    def test_native_shortcut_sheet_captures_then_releases_keyboard(self):
        self.open(win="1", pane="shortcuts")
        self.page.locator('[data-action="record-key:0"]').click()
        self.assertTrue(self.page.locator("#sheet").evaluate("el => el.open"))
        self.page.keyboard.press("Meta+k")
        self.page.wait_for_timeout(650)
        self.assertEqual(self.settings_state()["keys"][0], "⌘ K")
        self.assertEqual(self.page.evaluate("S.prefs.scPanel"), "⌘K")
        self.assertFalse(self.page.locator("#sheet").evaluate("el => el.open"))
        self.page.locator('[data-action="nav:general"]').click()
        self.page.keyboard.press("Meta+v")
        self.assertEqual(self.settings_state()["keys"][0], "⌘ K")

    def test_native_sheet_escape_cancels_before_settings_window_closes(self):
        self.open(win="1", pane="shortcuts")
        self.page.locator('[data-action="record-key:0"]').click()
        self.page.keyboard.press("Escape")
        self.assertFalse(self.page.locator("#sheet").evaluate("el => el.open"))
        self.assertTrue(self.page.locator("#window").is_visible())
        self.assertEqual(self.settings_state()["keys"][0], "⌃ ⌥ C")
        self.page.keyboard.press("Escape")
        self.assertFalse(self.page.locator("#window").is_visible())

    def test_native_close_button_preserves_preferences_and_reopens(self):
        self.open(win="1", pane="notifications")
        self.page.locator('[data-control="notifications"]').uncheck()
        self.page.locator("#window-close").click()
        self.assertFalse(self.page.locator("#window").is_visible())
        self.page.locator("#viewWindow").click()
        self.assertFalse(self.page.locator('[data-control="notifications"]').is_checked())
        self.assertFalse(self.page.evaluate("S.prefs.bannerOn"))

    def test_panel_activity_is_static_and_zero_counts_remain_readable(self):
        for lang in ["zh", "en"]:
            with self.subTest(lang=lang):
                self.open(panel="1", lang=lang)
                self.page.evaluate("S.usage.today = {taskStart:0,stop:0,stopFailure:0,notification:0,subagentStop:0}; S.usage.week={...S.usage.today}; render();")
                summary=self.page.locator("#activitySummary")
                self.assertEqual(summary.inner_text(), "今日 0 次 · 近 7 日 0 次" if lang == "zh" else "0 today · 0 last 7 days")
                self.assertEqual(summary.evaluate("el => el.tagName"), "DIV")
                self.assertIsNone(summary.get_attribute("tabindex"))
                self.assertEqual(self.page.locator("#actBtn, #activityContent, .act-bar").count(), 0)

    def test_sidebar_width_follows_the_actual_window_boundary(self):
        self.open(win="1", pane="general")
        for viewport, window, sidebar in [(1300,1240,252),(1161,1101,252),(1160,1100,210),(1100,1040,210),(1020,960,210),(900,876,210)]:
            with self.subTest(viewport=viewport):
                self.page.set_viewport_size({"width":viewport,"height":1000})
                self.assertAlmostEqual(self.page.locator("#settings-window").bounding_box()["width"],window)
                self.assertAlmostEqual(self.page.locator("#sidebar").bounding_box()["width"],sidebar)
                self.assertLessEqual(self.page.evaluate("document.documentElement.scrollWidth"),viewport)

    def test_native_window_size_control_switches_default_and_minimum_geometry(self):
        self.open(win="1",pane="general")
        self.page.locator('#window-maximize').click()
        box=self.page.locator('#settings-window').bounding_box()
        self.assertAlmostEqual(box['width'],960)
        self.assertAlmostEqual(box['height'],640)
        self.assertAlmostEqual(self.page.locator('#sidebar').bounding_box()['width'],210)
        self.page.locator('#window-maximize').click()
        box=self.page.locator('#settings-window').bounding_box()
        self.assertAlmostEqual(box['width'],1240)
        self.assertAlmostEqual(box['height'],820)

    def test_eight_native_pages_share_shell_and_expected_system_palette(self):
        for theme in ["light","dark"]:
            for pane,page in [("groups","events"),("sounds","sounds"),("integrations","integrations"),("notifications","notifications"),("general","general"),("shortcuts","shortcuts"),("activity","usage"),("about","about")]:
                with self.subTest(theme=theme,pane=pane):
                    self.open(win="1",pane=pane,th=theme)
                    self.assertEqual(self.settings_state()["page"],page)
                    self.assertEqual(self.page.locator("#settings-nav button").count(),8)
                    self.assertEqual(self.page.locator("#wMain, #wSide").count(),0)
                    self.assertEqual(self.page.locator("#sidebar").evaluate("el => getComputedStyle(el).backgroundColor"),
                                     "rgb(233, 233, 236)" if theme == "light" else "rgb(43, 43, 46)")
                    self.assertTrue(self.page.locator("#page-title").inner_text())

    def test_native_settings_navigation_keeps_workspace_and_real_focus(self):
        self.open(panel="1")
        self.page.locator("#scopeBtn").click()
        self.page.locator('[data-scope="claudio"]').click()
        self.page.locator("#editWorkspaceBtn").click()
        self.assertEqual(self.settings_state()["scope"],"claudio")
        self.assertTrue(self.page.locator("#page-title").evaluate("el => el === el.getRootNode().activeElement"))
        for page in ["integrations","events","notifications","sounds","usage","shortcuts","about","general"]:
            self.page.locator(f'[data-action="nav:{page}"]').click()
            self.assertEqual(self.settings_state()["scope"],"claudio")
            self.assertTrue(self.page.locator(f'[data-action="nav:{page}"]').evaluate("el => el === el.getRootNode().activeElement"))

    def test_settings_close_paths_clear_the_window_history_before_reopening(self):
        for close_path in ["outer_escape", "window_button"]:
            with self.subTest(close_path=close_path):
                self.open(win="1", pane="general")
                original_scopes = self.settings_state()["scopes"]
                self.page.locator('[data-action="nav:notifications"]').click()
                self.page.locator('[data-action="nav:sounds"]').click()
                self.page.locator("#detail-back").click()
                before = self.page.evaluate("MacSettings.review.navigation.getState()")
                self.assertGreater(before["cursor"], 0)
                self.assertFalse(self.page.locator("#detail-forward").is_disabled())
                if close_path == "outer_escape":
                    self.page.locator("#mbIcon").focus()
                    self.page.keyboard.press("Escape")
                else:
                    self.page.locator("#window-close").click()
                self.assertFalse(self.page.locator("#window").is_visible())
                closed = self.page.evaluate("MacSettings.review.navigation.getState()")
                self.assertEqual(closed["entries"], [])
                self.assertEqual(closed["cursor"], -1)
                self.assertGreater(closed["version"], before["version"])
                self.assertEqual(self.settings_state()["scopes"], original_scopes)
                self.page.locator("#viewWindow").click()
                reopened = self.page.evaluate("MacSettings.review.navigation.getState()")
                self.assertEqual(len(reopened["entries"]), 1)
                self.assertEqual(reopened["cursor"], 0)
                self.assertTrue(self.page.locator("#detail-back").is_disabled())
                self.assertTrue(self.page.locator("#detail-forward").is_disabled())

    def test_background_host_completion_keeps_sidebar_focus_and_arrow_navigation(self):
        for language in ["zh", "en"]:
            with self.subTest(language=language):
                self.open(win="1", pane="integrations", lang=language)
                self.page.locator("#demo-host-update").click()
                self.assertEqual(next(h for h in self.settings_state()["hosts"] if h["id"] == "codex")["maintenance"], "recovering")
                sidebar = self.page.locator('[data-action="nav:usage"]')
                sidebar.click()
                self.assertTrue(sidebar.evaluate("el => el === el.getRootNode().activeElement"))
                self.page.wait_for_function("!MacSettings.getState().hosts.find(h => h.id === 'codex').maintenance")
                self.assertTrue(sidebar.evaluate("el => el === el.getRootNode().activeElement"))
                self.page.keyboard.press("ArrowDown")
                self.assertEqual(self.settings_state()["page"], "about")
                self.assertTrue(self.page.locator('[data-action="nav:about"]').evaluate("el => el === el.getRootNode().activeElement"))

    def test_settings_minimization_keeps_the_window_history(self):
        self.open(win="1", pane="general")
        self.page.locator('[data-action="nav:notifications"]').click()
        self.page.locator('[data-action="nav:sounds"]').click()
        self.page.locator("#detail-back").click()
        before = self.page.evaluate("MacSettings.review.navigation.getState()")
        self.page.locator("#window-minimize").click()
        self.assertFalse(self.page.locator("#window").is_visible())
        self.assertEqual(self.page.evaluate("MacSettings.review.navigation.getState()"), before)
        self.page.locator("#viewWindow").click()
        reopened = self.page.evaluate("MacSettings.review.navigation.getState()")
        self.assertEqual(reopened["cursor"], before["cursor"])
        self.assertEqual(len(reopened["entries"]), len(before["entries"]))
        self.assertFalse(self.page.locator("#detail-forward").is_disabled())

    def test_latest_integrations_details_diagnostics_and_history_are_in_main_file(self):
        self.open(win="1",pane="integrations")
        self.assertEqual(self.page.locator('[data-control^="host-enabled:"]').count(),3)
        self.page.locator('[data-action="open-host:codex"]').first.click()
        self.assertEqual(self.settings_state()["detail"],"host")
        self.assertEqual(self.page.locator('[id^="reminder-"]').count(),5)
        self.page.locator('[data-action="host-diagnostics"]').click()
        self.assertEqual(self.settings_state()["detail"],"host-diagnostics")
        self.page.locator("#detail-back").click()
        self.assertEqual(self.settings_state()["detail"],"host")
        self.page.locator("#detail-forward").click()
        self.assertEqual(self.settings_state()["detail"],"host-diagnostics")
        self.assertTrue(self.page.locator("#page-title").evaluate("el => el === el.getRootNode().activeElement"))
        self.page.keyboard.press("Escape")
        self.assertTrue(self.page.locator("#window").is_visible())
        self.assertNotEqual(self.settings_state()["detail"],"host-diagnostics")

    def test_panel_and_settings_round_trip_workspace_pack_volume_and_event_state(self):
        self.open(panel="1")
        self.page.locator("#scopeBtn").click()
        self.page.locator('[data-scope="claudio"]').click()
        self.page.locator("#volRange").fill("37")
        self.page.locator("#panelPack").select_option("soft")
        self.page.locator('[data-mute="stop"]').click()
        self.page.locator("#editWorkspaceBtn").click()
        self.assertEqual(self.page.locator('[data-control="volume"]').input_value(),"37")
        self.assertEqual(self.page.locator('[data-control="scope-pack"]').input_value(),"soft")
        self.assertFalse(self.page.locator('[data-control="event:1"]').is_checked())
        self.page.locator('[data-control="volume"]').fill("73")
        self.page.locator('[data-control="event:1"]').check()
        self.page.locator('[data-control="scope-pack"]').select_option("night")
        self.page.locator("#window-close").click()
        self.assertEqual(self.page.locator("#volRange").input_value(),"73")
        self.assertEqual(self.page.locator("#panelPack").input_value(),"night")
        self.assertEqual(self.page.locator('[data-mute="stop"]').get_attribute("aria-pressed"),"false")
        self.assertEqual(self.settings_state()["scopes"][0]["volume"],65)

    def test_native_language_preference_updates_panel_and_global_theme_updates_settings(self):
        self.open(win="1",pane="general")
        self.page.locator('[data-control="language"]').select_option("en")
        self.assertEqual(self.page.locator("#page-title").inner_text(),"General")
        self.page.locator("#window-close").click()
        self.page.locator("#mbIcon").click()
        self.assertEqual(self.page.evaluate("S.lang"),"en")
        self.page.locator("#gearBtn").click()
        self.page.evaluate("document.getElementById('themeBtn').click()")
        self.assertEqual(self.page.locator("#window").get_attribute("data-theme"),"dark")

    def test_native_activity_reminders_share_panel_retention_and_removal(self):
        self.open(win="1",pane="activity")
        original=self.page.evaluate("REMINDERS.map(r=>r.id)")
        self.page.locator('[data-action="toggle-pending"]').click()
        self.assertEqual(self.settings_state()["pending"] and [r["id"] for r in self.settings_state()["pending"]],original)
        self.page.locator(f'[data-action="notice:{original[0]}"]').click()
        self.page.locator('[data-action="remove-reminder"]').click()
        self.assertEqual(self.page.evaluate("REMINDERS.map(r=>r.id)"),original[1:])
        self.assertEqual([r["id"] for r in self.settings_state()["pending"]],original[1:])

    def test_global_and_native_language_modes_do_not_double_toggle_or_reset_system(self):
        self.open(win="1",pane="general",lang="en")
        self.assertEqual(self.page.evaluate("S.lang"),"en")
        self.page.locator('[data-control="language"]').select_option("system")
        self.assertEqual(self.settings_state()["language"],"system")
        self.page.locator('[data-action="nav:notifications"]').click()
        self.assertEqual(self.settings_state()["language"],"system")

    def test_native_sounds_editor_and_ai_service_are_available(self):
        self.open(win="1",pane="sounds")
        self.page.locator('[data-control="pack"]').select_option("studio")
        self.page.locator('[data-action="edit-pack:0"]').click()
        self.assertEqual(self.settings_state()["detail"],"edit:task_start")
        self.page.locator('[data-action="open-generation"]').click()
        self.assertTrue(self.page.locator("#cue-description").is_visible())
        self.page.locator("#cue-description").fill("清脆的短铃声")
        self.page.locator('[data-action="generate"]').click()
        self.page.locator('[data-action="nav:general"]').click()
        self.assertIsNone(self.settings_state()["generation"])
        self.assertEqual(self.settings_state()["candidates"],[])


if __name__ == "__main__":
    unittest.main()
