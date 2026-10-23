#!/usr/bin/env python3
"""Focused review regressions for the discussion prototype, in offline Chrome.

Run: python3 scripts/test-ux-optimization-prototype-browser.py
Each test uses a fresh browser context; no personal profile or real service is used.
"""

import unittest
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

expect.set_options(timeout=2000)


PROTOTYPE = (
    Path(__file__).resolve().parent.parent
    / "designs/ux-optimization/First Run and Settings IA Prototype.html"
)


class UXOptimizationPrototypeBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.addClassCleanup(cls.playwright.stop)
        cls.browser = cls.playwright.chromium.launch(channel="chrome", headless=True)
        cls.addClassCleanup(cls.browser.close)

    def setUp(self):
        self.context = self.browser.new_context(
            viewport={"width": 1440, "height": 1200},
            reduced_motion="reduce",
            offline=True,
        )
        self.addCleanup(self.context.close)
        self.page = self.context.new_page()
        self.page.set_default_timeout(2000)
        self.page.clock.install(time=datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc))
        self.page.clock.pause_at(datetime(2026, 10, 23, 12, 0, 1, tzinfo=timezone.utc))
        self.page_errors = []
        self.page.on("pageerror", lambda error: self.page_errors.append(str(error)))

    def tearDown(self):
        self.assertEqual(self.page_errors, [], "the real inline script must run without errors")

    def open_pack(self, pack="my-cues"):
        self.page.goto("about:blank")
        self.page.goto(PROTOTYPE.as_uri() + "#settings-6")
        self.page.locator('.sidebar-item[data-page="sounds"]').click()
        self.page.locator(f'[data-sound-open="{pack}"]').click()

    def event_row(self, key):
        return self.page.locator(f'#sound-event-rows [data-event-key="{key}"]')

    def generate_saved_results(self):
        self.event_row("task-start").locator("[data-sound-source]").select_option("ai")
        self.page.locator('[data-ai-action="generate"]').click()
        self.page.clock.run_for(1200)
        expect(self.page.locator('#ai-cue-form [data-ai-state="saved"]')).to_be_visible()

    def test_saved_history_can_be_reused_after_regeneration_is_cancelled(self):
        self.open_pack()
        untouched = self.event_row("stop").locator(".sound-copy").text_content()
        self.generate_saved_results()
        self.page.locator('[data-ai-action="regenerate"]').click()
        self.page.locator('#ai-cue-form [data-ai-action="cancel"]').click()
        self.page.locator("[data-close-ai]").click()
        self.event_row("task-start").locator("[data-sound-source]").select_option("生成历史")
        picker = self.page.locator("dialog[open]")
        expect(picker).to_be_visible()
        picker.get_by_role("button", name="用于此事件", exact=True).first.click()
        expect(self.event_row("task-start").locator(".sound-copy")).to_contain_text("wooden-tap-12.aiff")
        expect(self.event_row("stop").locator(".sound-copy")).to_have_text(untouched)
        self.choose_history("task-start")
        expect(picker).to_be_visible()
        picker.get_by_role("button", name="用于此事件", exact=True).nth(1).click()
        expect(self.event_row("task-start").locator(".sound-copy")).to_contain_text("wooden-tap-14.aiff")

    def choose_history(self, key):
        control = self.event_row(key).locator("[data-sound-source]")
        # Native select commits only changed values. Playwright's select_option always
        # dispatches change, even for the current value, which would hide this regression.
        if control.input_value() != "生成历史":
            control.select_option("生成历史")

    def test_history_action_opens_again_when_history_is_the_current_source(self):
        self.open_pack()
        for _ in range(2):
            self.choose_history("notification")
            picker = self.page.locator("dialog[open]")
            expect(picker).to_be_visible()
            expect(picker).to_contain_text("暂无已保存")
            self.page.keyboard.press("Escape")
            expect(picker).to_have_count(0)
            expect(self.event_row("notification").locator("[data-sound-source]")).to_be_focused()
            expect(self.event_row("notification").locator(".sound-copy")).to_contain_text("bell_soft.aiff")

    def test_history_selection_preserves_the_current_generating_or_failed_task(self):
        for state in ["generating", "failed"]:
            with self.subTest(state=state):
                self.open_pack()
                self.generate_saved_results()
                self.page.locator("[data-close-ai]").click()
                self.page.locator("#scenario-select").select_option("failure")
                self.page.locator('[data-sound-open="my-cues"]').click()
                self.event_row("stop").locator("[data-sound-source]").select_option("ai")
                self.page.locator("#ai-description").fill("另一批任务的原始描述")
                self.page.locator('[data-ai-action="regenerate"]').click()
                if state == "failed":
                    self.page.clock.run_for(1200)
                self.page.locator("[data-close-ai]").click()
                self.choose_history("notification")
                picker = self.page.locator("dialog[open]")
                expect(picker).to_contain_text("柔和的木质敲击，短促，无背景音乐")
                expect(picker.get_by_role("button", name="用于此事件", exact=True)).to_have_count(3)
                picker.get_by_role("button", name="用于此事件", exact=True).last.click()
                expect(self.event_row("notification").locator(".sound-copy")).to_contain_text("wooden-tap-17.aiff")
                self.event_row("stop").locator("[data-sound-source]").select_option("ai")
                expect(self.page.locator(f'#ai-cue-form [data-ai-state="{state}"]')).to_be_visible()
                expect(self.page.locator("#ai-description")).to_have_value("另一批任务的原始描述")
                if state == "failed":
                    expect(self.page.locator('#ai-cue-form [data-ai-state="failed"] [data-ai-use]').first).to_be_disabled()
                self.page.keyboard.press("Escape")

    def test_regeneration_uses_the_event_and_pack_shown_before_starting(self):
        for pack in ["my-cues", "focus-set"]:
            with self.subTest(pack=pack):
                self.open_pack()
                self.generate_saved_results()
                self.page.locator("[data-close-ai]").click()
                if pack != "my-cues":
                    self.page.locator('[data-sounds-view="detail"] [data-sound-back]').click()
                    self.page.locator(f'[data-sound-open="{pack}"]').click()
                original = self.event_row("task-start").locator(".sound-copy").text_content()
                self.event_row("stop").locator("[data-sound-source]").select_option("ai")
                expect(self.page.locator("#ai-target")).to_have_text(f"{pack} › 本轮结束")
                expect(self.page.locator("#ai-task-origin")).to_contain_text("my-cues › 任务开始")
                self.page.locator('[data-ai-action="regenerate"]').click()
                expect(self.page.locator("#ai-target")).to_have_text(f"{pack} › 本轮结束")
                self.page.clock.run_for(1200)
                self.page.locator('#ai-cue-form [data-ai-state="saved"] [data-ai-use]').first.click()
                expect(self.event_row("stop").locator(".sound-copy")).to_contain_text("wooden-tap-12.aiff")
                expect(self.event_row("task-start").locator(".sound-copy")).to_have_text(original)

    def test_background_completion_keeps_the_focused_history_candidate(self):
        self.open_pack()
        self.generate_saved_results()
        self.page.locator("#ai-description").fill("第二批结果，不应替换当前选择")
        self.page.locator('[data-ai-action="regenerate"]').click()
        self.page.locator("[data-close-ai]").click()
        self.choose_history("stop")
        picker = self.page.locator("#ai-history-picker")
        old_group = picker.locator(".settings-card").filter(has_text="柔和的木质敲击，短促，无背景音乐")
        use = old_group.get_by_role("button", name="用于此事件", exact=True).nth(1)
        use.focus()
        focused = use.element_handle()
        self.page.clock.run_for(1200)
        expect(picker).to_contain_text("第二批结果，不应替换当前选择")
        self.assertTrue(focused.evaluate("node => node.isConnected && document.activeElement === node"))
        expect(use).to_be_focused()
        self.page.keyboard.press("Enter")
        expect(self.page.locator("dialog[open]")).to_have_count(0)
        expect(self.event_row("stop").locator(".sound-copy")).to_contain_text("wooden-tap-14.aiff")

    def test_background_completion_keeps_the_focused_saved_record_preview(self):
        self.open_pack()
        original = self.event_row("task-start").locator(".sound-copy").text_content()
        self.generate_saved_results()
        self.page.locator("#ai-description").fill("第二批结果，不应打断旧记录试听")
        self.page.locator('[data-ai-action="regenerate"]').click()
        self.page.locator("[data-close-ai]").click()
        self.page.locator('[data-sounds-view="detail"] [data-sound-back]').click()
        self.page.locator("[data-sound-history]").click()
        saved = self.page.locator("#ai-history-saved")
        old_group = saved.locator(".settings-card").filter(has_text="柔和的木质敲击，短促，无背景音乐")
        preview = old_group.locator(".history-row").filter(has_text="wooden-tap-14").get_by_role("button")
        preview.focus()
        expect(preview).to_be_focused()
        self.page.clock.run_for(1200)
        expect(saved.locator(".settings-card")).to_have_count(2)
        new_group = saved.locator(".settings-card").first
        expect(new_group).to_contain_text("第二批结果，不应打断旧记录试听")
        expect(preview).to_be_focused()
        self.page.keyboard.press("Enter")
        expect(preview).to_have_text("播放中…")
        expect(preview).to_be_disabled()
        expect(new_group.get_by_role("button", name="试听", exact=True)).to_have_count(3)
        expect(saved.get_by_role("button", name="用于此事件", exact=True)).to_have_count(0)
        expect(self.page.locator("dialog[open]")).to_have_count(0)
        self.page.clock.run_for(700)
        expect(preview).to_have_text("试听")
        expect(preview).to_be_enabled()
        self.page.locator('[data-sounds-view="history"] [data-sound-back]').click()
        self.page.locator('[data-sound-open="my-cues"]').click()
        expect(self.event_row("task-start").locator(".sound-copy")).to_have_text(original)

    def open_first_run(self):
        self.page.goto(PROTOTYPE.as_uri() + "#first-run-empty")
        self.first_run = self.page.locator("#view-first-run-empty")
        self.first_run.locator("[data-reset-empty]").click()

    def open_guided_flow(self, kind):
        self.page.goto("about:blank")
        self.page.goto(PROTOTYPE.as_uri() + f"#first-run-{kind}")
        return self.page.locator(f'.first-run-flow[data-flow="{kind}"]')

    def test_skipping_guided_flows_keeps_the_panel_unconnected(self):
        for kind in ["panel", "window"]:
            with self.subTest(flow=kind):
                flow = self.open_guided_flow(kind)
                flow.get_by_role("button", name="下一步：连接宿主", exact=True).click()
                flow.get_by_role("button", name="稍后再说", exact=True).click()
                skip = flow.get_by_role("button", name="跳过，先进入面板", exact=True)
                if skip.is_visible():
                    skip.click()
                active = flow.locator(".flow-step.active")
                expect(active.locator("h2")).to_have_text("未接入宿主")
                expect(active.locator(".completion-card")).to_have_count(0)
                flow.get_by_role("button", name="继续连接", exact=True).click()
                expect(flow.locator('.flow-step[data-step="2"]')).to_be_visible()

    def test_guided_flows_use_the_selected_host_for_waiting_receipts_and_completion(self):
        for kind in ["panel", "window"]:
            with self.subTest(flow=kind):
                flow = self.open_guided_flow(kind)
                flow.get_by_role("button", name="下一步：连接宿主", exact=True).click()
                flow.locator("[data-host-row]").filter(has_text="Codex").get_by_role(
                    "button", name="连接", exact=True
                ).click()
                self.page.clock.run_for(900)
                flow.get_by_role("button", name="继续", exact=True).click()
                expect(flow.locator(".receipt-head strong")).to_have_text("Codex")
                expect(flow.locator(".receipt-steps li").first).to_have_text("回到 Codex")
                flow.get_by_role("button", name="重新检测", exact=True).click()
                self.page.clock.run_for(1000)
                expect(flow.locator(".receipt-steps li").first).to_have_text("已收到 Codex 的真实回执")
                flow.get_by_role("button", name="查看结果", exact=True).click()
                expect(flow.locator(".flow-step.active h2")).to_have_text("已接入 Codex")
                flow.get_by_role("button", name="完成", exact=True).click()
                expect(flow.locator("[data-finish-toast]")).to_have_text("首次设置完成 · 已接入 Codex")

    def test_guided_flows_keep_their_host_selection_separate(self):
        panel = self.open_guided_flow("panel")
        panel.get_by_role("button", name="下一步：连接宿主", exact=True).click()
        panel.locator("[data-host-row]").filter(has_text="Codex").locator("[data-connect-host]").click()
        self.page.clock.run_for(900)
        self.page.locator('.review-tab[data-target="first-run-window"]').click()
        window = self.page.locator('.first-run-flow[data-flow="window"]')
        window.get_by_role("button", name="下一步：连接宿主", exact=True).click()
        window.locator("[data-host-row]").filter(has_text="Claude Code").locator("[data-connect-host]").click()
        self.page.clock.run_for(900)
        window.get_by_role("button", name="继续", exact=True).click()
        expect(window.locator(".receipt-head strong")).to_have_text("Claude Code")
        self.page.locator('.review-tab[data-target="first-run-panel"]').click()
        panel.get_by_role("button", name="继续", exact=True).click()
        expect(panel.locator(".receipt-head strong")).to_have_text("Codex")

    def test_skipping_after_configuration_does_not_activate_guided_flows(self):
        for kind in ["panel", "window"]:
            with self.subTest(flow=kind):
                flow = self.open_guided_flow(kind)
                flow.get_by_role("button", name="下一步：连接宿主", exact=True).click()
                flow.locator("[data-host-row]").filter(has_text="Codex").locator("[data-connect-host]").click()
                self.page.clock.run_for(900)
                flow.get_by_role("button", name="继续", exact=True).click()
                flow.get_by_role("button", name="跳过，先进入面板", exact=True).click()
                expect(flow.locator(".flow-step.active h2")).to_have_text("未接入宿主")
                flow.get_by_role("button", name="继续连接", exact=True).click()
                flow.get_by_role("button", name="继续", exact=True).click()
                expect(flow.locator(".receipt-head strong")).to_have_text("Codex")
                expect(flow.locator(".receipt-head .badge")).to_have_text("配置已写入")
                flow.get_by_role("button", name="重新检测", exact=True).click()
                flow.get_by_role("button", name="跳过，先进入面板", exact=True).click()
                expect(flow.locator(".flow-step.active h2")).to_have_text("未接入宿主")
                self.page.clock.run_for(1000)
                expect(flow.locator(".flow-step.active h2")).to_have_text("已接入 Codex")
                expect(flow.locator(".flow-step.active .completion-card")).to_have_count(0)

    def connect_host(self, host):
        self.first_run.locator("[data-expand-hosts]").click()
        self.first_run.locator("[data-empty-host-row]").filter(has_text=host).locator(
            "[data-empty-connect]"
        ).click()

    def test_completion_separates_supported_events_from_observed_receipts(self):
        for host, coverage in [("Codex", "4/5"), ("Claude Code", "5/5")]:
            self.open_first_run()
            self.connect_host(host)
            self.page.clock.run_for(900)
            expect(self.first_run.locator("[data-footer-connection]")).to_be_hidden()
            self.first_run.locator("[data-simulate-receipt]").click()
            self.page.clock.run_for(800)
            with self.subTest(host=host, fact="observed"):
                expect(self.first_run.locator(".success-line .badge")).to_have_text("已收到 1 类事件")
            self.first_run.locator("[data-accept-onboarding]").click()
            with self.subTest(host=host, fact="supported"):
                expect(self.first_run.locator("[data-footer-connection]")).to_have_text(
                    f"{host} 已接上 · 支持 {coverage}"
                )
            self.first_run.locator("[data-simulate-restart]").click()
            with self.subTest(host=host, fact="restored"):
                expect(self.first_run.locator("[data-footer-connection]")).to_have_text(
                    f"{host} 已接上 · 支持 {coverage}"
                )

    def test_receipt_after_dismissing_the_checklist_updates_the_visible_connection(self):
        for host, coverage in [("Codex", "4/5"), ("Claude Code", "5/5")]:
            with self.subTest(host=host):
                self.open_first_run()
                self.connect_host(host)
                self.page.clock.run_for(900)
                self.first_run.locator("[data-simulate-receipt]").click()
                self.page.clock.run_for(100)
                self.first_run.locator("[data-dismiss-onboarding]").first.click()
                self.page.clock.run_for(800)
                expect(self.first_run.locator("[data-onboarding-card]")).to_be_hidden()
                connection = self.first_run.locator("[data-footer-connection]")
                expect(connection).to_be_visible()
                expect(connection).to_have_text(f"{host} 已接上 · 支持 {coverage}")
                expect(self.first_run.locator("[data-empty-activity-copy]")).to_have_text("最近一次事件会出现在这里")
                expect(self.first_run.locator("[data-resume-strip]")).to_be_hidden()
                self.first_run.locator("[data-simulate-restart]").click()
                expect(connection).to_have_text(f"{host} 已接上 · 支持 {coverage}")

    def test_reset_cancels_an_old_connection_before_a_new_host_is_connected(self):
        self.open_first_run()
        self.connect_host("Codex")
        self.page.clock.run_for(200)
        self.first_run.locator("[data-reset-empty]").click()
        self.connect_host("Claude Code")
        self.page.clock.run_for(700)
        expect(self.first_run.locator("[data-sim-wrap]")).to_be_hidden()
        self.page.clock.run_for(200)
        expect(self.first_run.locator("[data-connect-sub]")).to_have_text("Claude Code · 等待真实回执")
        expect(self.first_run.locator("[data-demo-state]")).to_have_attribute("data-state", "unseen")

    def test_reset_cancels_a_receipt_and_does_not_complete_the_replacement_host(self):
        self.open_first_run()
        self.connect_host("Codex")
        self.page.clock.run_for(900)
        self.first_run.locator("[data-simulate-receipt]").click()
        self.page.clock.run_for(100)
        self.first_run.locator("[data-reset-empty]").click()
        self.connect_host("Claude Code")
        self.page.clock.run_for(700)
        expect(self.first_run.locator("[data-demo-state]")).to_have_attribute("data-state", "unseen")
        expect(self.first_run.locator("[data-onboarding-success]")).to_be_hidden()
        expect(self.first_run.locator("[data-footer-connection]")).to_be_hidden()
        self.page.reload()
        expect(self.first_run.locator("[data-demo-state]")).to_have_attribute("data-state", "unseen")
        expect(self.first_run.locator("[data-onboarding-card]")).to_be_visible()


if __name__ == "__main__":
    unittest.main()
