#!/usr/bin/env python3
"""Offline contracts for the approved five-page Settings picture SoT."""
import unittest
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

HTML = Path(__file__).resolve().parent.parent / 'designs/panel-and-settings/Panel and Settings Prototype.html'

class FivePageSettingsPrototypeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(channel='chrome', headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.context = self.browser.new_context(viewport={'width':1400,'height':1000}, reduced_motion='reduce', offline=True)
        self.page = self.context.new_page()
        self.errors = []
        self.page.on('pageerror', lambda error: self.errors.append(str(error)))
        self.page.goto(HTML.as_uri() + '?win=1&pane=groups&clean=1')

    def tearDown(self):
        self.assertEqual(self.errors, [])
        self.context.close()

    def test_five_pages_and_hidden_diagnostics_history(self):
        self.assertEqual(self.page.locator('#settings-nav button').all_text_contents(),
                         ['工作区', '声音包', '连接', '提醒与静音', '通用'])
        self.page.locator('[data-action="nav:integrations"]').click()
        self.page.locator('[data-action="nav:usage"]').click()
        expect(self.page.locator('#settings-nav [aria-current]')).to_have_text('连接')
        self.page.locator('[data-action="nav:general"]').click()
        self.page.locator('#detail-back').click()
        expect(self.page.locator('#page-title')).to_have_text('活动与诊断')
        self.page.locator('#detail-forward').click()
        expect(self.page.locator('#page-title')).to_have_text('通用')

    def test_discussion_keeps_first_run_comparisons_and_links_single_settings_source(self):
        discussion = HTML.parent.parent / 'ux-optimization/First Run and Settings IA Prototype.html'
        self.page.goto(discussion.as_uri())
        for target in ['first-run-panel', 'first-run-window', 'first-run-empty', 'settings']:
            self.page.locator(f'[data-target="{target}"]').click()
            expect(self.page.locator('#view-' + target)).to_be_visible()
            expect(self.page.locator('#note-shape')).not_to_be_empty()
        notice = self.page.locator('#settings-history-notice')
        expect(notice).to_be_visible()
        expect(notice).to_contain_text('历史评审与离线回归证据')
        expect(notice.locator('a')).to_have_count(1)
        self.assertIn('Panel%20and%20Settings%20Prototype.html',
                      notice.locator('a').get_attribute('href'))
        notice.locator('a').click()
        expect(self.page.locator('#settings-nav button')).to_have_count(5)

    def test_about_modal_is_general_without_duplicate_update_section(self):
        self.page.locator('[data-action="nav:general"]').click()
        self.page.locator('[data-action="open-about"]').click()
        expect(self.page.locator('#page-title')).to_have_text('通用')
        expect(self.page.locator('#sheet')).to_be_visible()
        expect(self.page.locator('#sheet [data-action="check-update"]')).to_have_count(0)
        for key in ['Tab', 'Shift+Tab'] * 4:
            self.page.keyboard.press(key)
            self.assertTrue(self.page.locator('#sheet').evaluate('el => el.contains(el.getRootNode().activeElement)'))
        self.page.keyboard.press('Escape')
        self.assertEqual(self.page.evaluate("document.getElementById('window').shadowRoot.activeElement.dataset.action"), 'open-about')

    def test_workspace_summary_and_pack_event_return(self):
        expect(self.page.locator('#page-content')).not_to_contain_text('6500%')
        self.page.locator('[data-action="select-workspace:claudio"]').click()
        self.page.locator('[data-action="edit-from-scope:1"]').click()
        expect(self.page.locator('[data-action="return-scope"]')).to_be_visible()
        expect(self.page.locator('.sf-event[data-event="stop"]')).to_be_visible()
        self.page.locator('[data-action="return-scope"]').click()
        expect(self.page.locator('#page-title')).to_have_text('Claudio')

    def test_service_management_is_compact_with_live_status_and_controls(self):
        self.page.locator('[data-action="nav:sounds"]').click()
        disclosure = self.page.locator('.sf-service-details')
        self.assertFalse(disclosure.evaluate('el => el.open'))
        disclosure.locator('summary').click()
        expect(disclosure.locator('[data-service-status]')).to_be_visible()
        disclosure.locator('[data-act="service"]').click()
        expect(self.page.locator('dialog.sf-overlay[open]')).to_be_visible()

    def test_ai_sheet_keeps_task_after_escape_and_blocks_background_focus(self):
        self.page.locator('[data-action="nav:sounds"]').click()
        self.page.locator('.sf-pack-detail[data-id="studio"]').click()
        row = self.page.locator('.sf-event[data-event="task_start"]')
        row.locator('[data-act="sources"]').click()
        row.locator('[data-source="ai"]').click()
        expect(self.page.locator('dialog.sf-overlay[open]')).to_be_visible()
        self.page.locator('#sf-ai-prompt').fill('木质短促提示音')
        self.page.locator('[data-act="generate"]').click()
        self.page.keyboard.press('Escape')
        expect(self.page.locator('dialog.sf-overlay[open]')).to_have_count(0)
        self.assertTrue(row.locator('[data-act="sources"]').evaluate('el => el.getRootNode().activeElement === el'))
        self.page.locator('[data-act="history"]').first.click()
        expect(self.page.locator('[data-task-title]:visible')).to_contain_text('生成')
        self.page.wait_for_timeout(5800)
        expect(self.page.locator('[data-task-title]:visible')).to_have_count(0)
        expect(self.page.locator('[data-description]:visible').first).to_have_text('木质短促提示音')

if __name__ == '__main__':
    unittest.main()
