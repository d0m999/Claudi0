#!/usr/bin/env python3
"""Browser regressions for the Custom Themes prototype.

Run from the repository root: python3 scripts/test-custom-themes-prototype-browser.py
The browser uses a temporary, offline context and never opens a personal profile.
The prototype stores its own drafts in browser IndexedDB; every test drives a
fresh browser context so no draft leaks between cases.
"""

import unittest
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import expect, sync_playwright


PROTOTYPE = (
    Path(__file__).resolve().parent.parent
    / "designs/panel-and-settings/Custom Themes Prototype.html"
)


class CustomThemesPrototypeBrowserTests(unittest.TestCase):
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

    # -- helpers ---------------------------------------------------------
    def open(self, **query):
        self.page.goto(PROTOTYPE.as_uri() + "?" + urlencode(query))
        self.page.wait_for_function("() => !!window.themePrototype")
        self.page.wait_for_timeout(150)

    def snapshot(self):
        return self.page.evaluate("() => window.themePrototype.snapshot()")

    def route(self):
        return self.page.evaluate("() => window.themePrototype.route()")

    def saved_theme(self, theme_id):
        for theme in self.snapshot()["themes"]:
            if theme["id"] == theme_id:
                return theme
        return None

    def draft(self, theme_id):
        return self.snapshot()["drafts"].get(theme_id)

    def groups(self, account="pro"):
        return self.snapshot()["scopes"][account]

    def go_library(self):
        self.page.locator('[data-action="nav"][data-page="themes"]').click()
        self.page.wait_for_timeout(120)

    def go_workspace(self, scope="default"):
        self.page.locator('[data-action="nav"][data-page="workspace"]').click()
        self.page.wait_for_timeout(120)
        self.page.locator(f'[data-action="scope"][data-id="{scope}"]').click()
        self.page.wait_for_timeout(120)

    def open_theme(self, theme_id):
        self.go_library()
        self.page.locator(f'[data-action="open-theme"][data-id="{theme_id}"]').click()
        self.page.wait_for_timeout(120)

    def open_menu(self):
        self.page.locator('[data-action="theme-menu"]').click()
        expect(self.page.locator("#context-menu")).to_be_visible()

    def set_palette(self, palette):
        self.page.locator(f'[data-action="palette"][data-id="{palette}"]').click()
        self.page.wait_for_timeout(120)

    def commit_name(self, name):
        self.page.locator("#theme-name").fill(name)
        self.page.locator('[data-action="commit-name"]').click()
        self.page.wait_for_timeout(200)

    def wait_for_draft(self, theme_id):
        self.page.wait_for_function(
            "id => !!window.themePrototype.snapshot().drafts[id]", arg=theme_id
        )

    def library_row(self, theme_id):
        return self.page.locator(f'[data-action="open-theme"][data-id="{theme_id}"]')

    def test_copy_uses_the_last_saved_theme_instead_of_the_unsaved_draft(self):
        self.open()
        self.assertEqual(self.route(), {"page": "themes", "id": "ghost"})
        self.set_palette("dusk")
        self.wait_for_draft("ghost")
        self.assertEqual(self.draft("ghost")["palette"], "dusk")
        self.assertEqual(self.saved_theme("ghost")["palette"], "mist")

        self.open_menu()
        self.page.locator('#context-menu [data-action="copy-theme"]').click()
        expect(self.page.locator("#theme-name")).to_have_value("我的幽灵 副本")
        self.commit_name("幽灵副本")

        state = self.snapshot()
        copies = [t for t in state["themes"] if t["name"] == "幽灵副本"]
        self.assertEqual(len(copies), 1)
        copy = copies[0]
        self.assertEqual(copy["palette"], "mist", "the copy must use the last saved content")
        self.assertFalse(copy["builtin"])
        self.assertEqual(self.route()["id"], copy["id"])
        self.assertEqual(
            state["drafts"].get("ghost", {}).get("palette"),
            "dusk",
            "the source draft must survive the copy untouched",
        )
        self.assertNotIn(copy["id"], state["drafts"])

    def test_rename_reads_the_live_theme_while_copy_reads_the_saved_theme(self):
        self.open()
        self.open_menu()
        self.page.locator('#context-menu [data-action="rename-theme"]').click()
        self.commit_name("幽灵改名")

        self.assertEqual(self.draft("ghost")["name"], "幽灵改名")
        self.assertEqual(self.saved_theme("ghost")["name"], "我的幽灵")

        self.open_menu()
        self.page.locator('#context-menu [data-action="rename-theme"]').click()
        expect(self.page.locator("#theme-name")).to_have_value("幽灵改名")
        self.page.locator('[data-action="cancel-sheet"]').click()

        self.open_menu()
        self.page.locator('#context-menu [data-action="copy-theme"]').click()
        expect(self.page.locator("#theme-name")).to_have_value("我的幽灵 副本")

    def test_copy_for_a_workspace_uses_the_saved_theme_and_rebinds_only_that_group(self):
        self.open()
        self.set_palette("dusk")
        self.wait_for_draft("ghost")

        self.go_workspace("default")
        self.page.locator('[data-action="copy-for-scope"]').click()
        expect(self.page.locator("#theme-name")).to_have_value("我的幽灵 副本")
        self.commit_name("默认组专用")

        state = self.snapshot()
        copy = [t for t in state["themes"] if t["name"] == "默认组专用"][0]
        self.assertEqual(copy["palette"], "mist", "the scope copy must use the saved content")
        groups = self.groups()
        self.assertEqual([g for g in groups if g["id"] == "default"][0]["theme"], copy["id"])
        self.assertEqual(
            [g for g in groups if g["id"] == "claudio"][0]["theme"],
            "duck",
            "other groups keep their own theme",
        )
        self.assertEqual(state["drafts"]["ghost"]["palette"], "dusk")
        self.assertNotIn(copy["id"], state["drafts"])

    def test_applying_a_theme_with_an_unsaved_draft_is_refused(self):
        self.open()
        self.set_palette("dusk")
        self.wait_for_draft("ghost")
        self.open_menu()
        self.page.locator('#context-menu [data-action="apply-theme"]').click()
        expect(self.page.locator("#toast")).to_have_text("请先保存主题，再应用到工作区")
        expect(self.page.locator("#sheet")).not_to_be_visible()

    def test_saving_moves_the_draft_into_the_saved_theme(self):
        self.open()
        self.set_palette("dusk")
        self.wait_for_draft("ghost")
        self.go_library()
        expect(self.library_row("ghost")).to_contain_text("有未保存的草稿")

        self.open_theme("ghost")
        self.page.locator('[data-action="save-theme"]').click()
        expect(self.page.locator("#toast")).to_have_text("主题已保存，后续提醒使用新版本")
        self.assertEqual(self.saved_theme("ghost")["palette"], "dusk")
        self.assertIsNone(self.draft("ghost"))
        expect(self.page.locator("#save-state")).to_have_text("已保存")

        self.go_library()
        expect(self.library_row("ghost")).not_to_contain_text("有未保存的草稿")

    def test_discarding_a_draft_keeps_the_saved_theme(self):
        self.open()
        self.set_palette("dusk")
        self.wait_for_draft("ghost")
        self.open_menu()
        self.page.locator('#context-menu [data-action="discard-theme"]').click()
        self.page.locator('[data-action="commit-discard"]').click()
        expect(self.page.locator("#toast")).to_have_text("已放弃修改")
        self.assertIsNone(self.draft("ghost"))
        self.assertEqual(self.saved_theme("ghost")["palette"], "mist")

    def test_deleting_a_used_theme_asks_for_a_replacement_and_keeps_group_settings(self):
        self.open()
        self.go_workspace("default")
        before = [g for g in self.groups() if g["id"] == "default"][0]
        self.open_theme("ghost")
        self.open_menu()
        self.page.locator('#context-menu [data-action="delete-theme"]').click()
        expect(self.page.locator("#replacement")).to_be_visible()
        self.page.locator("#replacement").select_option("original")
        self.page.locator('[data-action="commit-delete"]').click()
        expect(self.page.locator("#toast")).to_have_text("主题已删除")

        state = self.snapshot()
        self.assertIsNone(self.saved_theme("ghost"))
        after = [g for g in self.groups() if g["id"] == "default"][0]
        self.assertEqual(after["theme"], "original")
        self.assertEqual(after["volume"], before["volume"])
        self.assertEqual(after["enabled"], before["enabled"])

    def test_new_theme_starts_unapplied_and_a_pack_theme_uses_its_own_sounds(self):
        self.open()
        self.go_library()
        self.page.locator('[data-action="new-theme"]').click()
        expect(self.page.locator("#theme-name")).to_have_value("我的主题")
        self.commit_name("新建主题")

        state = self.snapshot()
        created = [t for t in state["themes"] if t["name"] == "新建主题"][0]
        self.assertFalse(created["builtin"])
        self.assertTrue(all(g["theme"] != created["id"] for g in self.groups()))

        self.page.locator('[data-action="nav"][data-page="sounds"]').click()
        self.page.locator('[data-action="theme-from-pack"][data-pack="soft"]').click()
        self.commit_name("柔和双音主题")
        packed = [t for t in self.snapshot()["themes"] if t["name"] == "柔和双音主题"][0]
        self.assertEqual([sound["type"] for sound in packed["sounds"]], ["tone"] * 5)
        self.assertTrue(all(g["theme"] != packed["id"] for g in self.groups()))

    def test_workspace_theme_selection_updates_only_the_selected_group(self):
        self.open()
        self.go_workspace("notes")
        before = {group["id"]: group["theme"] for group in self.groups()}
        self.assertIsNone(before["notes"])

        self.page.locator('#scope-theme').select_option("duck")
        self.page.wait_for_timeout(150)
        after = {group["id"]: group["theme"] for group in self.groups()}
        self.assertEqual(after["notes"], "duck")
        self.assertEqual(after["default"], before["default"])
        self.assertEqual(after["claudio"], before["claudio"])

    def test_free_account_cannot_apply_a_paid_theme(self):
        self.open(account="free")
        self.open_theme("ghost")
        self.page.locator('[data-action="apply-theme"]').click()
        expect(self.page.locator("#apply-target")).to_be_visible()
        self.page.locator('[data-action="commit-apply"]').click()
        expect(self.page.locator("#sheet-title")).to_have_text("应用此主题需要 Pro")

    def test_draft_survives_a_reload_in_the_same_browser_context(self):
        self.open()
        self.set_palette("sage")
        self.wait_for_draft("ghost")
        self.page.reload()
        self.page.wait_for_function("() => !!window.themePrototype")
        self.page.wait_for_function("() => !!window.themePrototype.snapshot().drafts.ghost")
        self.assertEqual(self.draft("ghost")["palette"], "sage")
        self.assertEqual(self.saved_theme("ghost")["palette"], "mist")


if __name__ == "__main__":
    unittest.main()
