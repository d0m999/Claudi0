#!/usr/bin/env python3
"""Browser regressions for the Custom Themes prototype.

Run from the repository root: python3 scripts/test-custom-themes-prototype-browser.py
The browser uses a temporary, offline context and never opens a personal profile.
The prototype stores its own drafts in browser IndexedDB; every test drives a
fresh browser context so no draft leaks between cases.
"""

import base64
import unittest
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import expect, sync_playwright


PROTOTYPE = (
    Path(__file__).resolve().parent.parent
    / "designs/panel-and-settings/Custom Themes Prototype.html"
)

# Two 2x2 frames (red, blue), 100 ms each; generated locally, no external asset.
GIF_BYTES = base64.b64decode(
    "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAA"
    "AgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
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

    def observe_gif_frames(self):
        # Observe the browser resource boundary without replacing the decoder.
        self.page.add_init_script("""(() => {
            const create = window.createImageBitmap.bind(window);
            window.gifFrames = [];
            window.createImageBitmap = async (...args) => {
                const image = await create(...args);
                window.gifFrames.push(image);
                if (window.gifFrameGate) await window.gifFrameGate;
                return image;
            };
        })();""")

    def import_gif(self, name="personal.gif"):
        self.page.locator("#gif-file").set_input_files(
            {"name": name, "mimeType": "image/gif", "buffer": GIF_BYTES}
        )
        expect(self.page.locator(".file-meta")).to_contain_text(name)
        expect(self.page.locator('[data-action="commit-gif"]')).to_be_enabled()

    def wait_for_assets(self, ids):
        self.page.wait_for_function(
            "ids => JSON.stringify(Object.keys(window.themePrototype.snapshot().assets).sort())"
            " === JSON.stringify(ids.sort())", arg=ids
        )

    def test_cancelled_gif_imports_release_sources_and_decoded_frames(self):
        self.observe_gif_frames()
        self.open()
        for index in range(2):
            self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
            self.import_gif(f"cancel-{index}.gif")
            self.assertEqual(len(self.snapshot()["assets"]), 1)
            if index:
                self.page.keyboard.press("Escape")
            else:
                self.page.locator('[data-action="cancel-sheet"]').click()
            self.wait_for_assets([])
            self.assertIsNone(self.draft("ghost"))
            self.assertTrue(self.page.evaluate(
                "() => gifFrames.length > 0 && gifFrames.every(image => image.width === 0)"
            ), "cancel must close all decoded ImageBitmaps")

        self.page.reload()
        expect(self.page.locator("#main-banner")).to_be_visible()
        self.wait_for_assets([])
        self.assertIsNone(self.draft("ghost"))

    def test_gif_replacement_keeps_saved_and_draft_sources_until_discarded(self):
        self.observe_gif_frames()
        self.open()
        editor = self.page.locator('[data-action="edit-gif"][data-index="0"]')
        editor.click()
        self.import_gif("saved.gif")
        saved_asset = next(iter(self.snapshot()["assets"]))
        self.page.locator('[data-action="commit-gif"]').click()
        self.page.locator('[data-action="save-theme"]').click()

        editor.click()
        self.import_gif("replacement.gif")
        self.import_gif("draft.gif")
        assets = self.snapshot()["assets"]
        self.assertEqual(sorted(a["name"] for a in assets.values()), ["draft.gif", "saved.gif"])
        draft_asset = next(key for key, asset in assets.items() if asset["name"] == "draft.gif")
        self.page.locator('[data-action="commit-gif"]').click()
        self.wait_for_assets([saved_asset, draft_asset])
        expect(self.page.locator("#save-state")).to_have_text("草稿已保留")
        self.page.reload()
        self.page.wait_for_function("() => !!window.themePrototype")
        self.wait_for_assets([saved_asset, draft_asset])
        editor.click()
        expect(self.page.locator(".file-meta")).to_contain_text("draft.gif")
        expect(self.page.locator('[data-action="commit-gif"]')).to_be_enabled()
        self.import_gif("cancelled.gif")
        self.page.locator('[data-action="cancel-sheet"]').click()
        self.wait_for_assets([saved_asset, draft_asset])
        self.assertEqual(self.draft("ghost")["gifs"][0]["asset"], draft_asset)

        self.open_menu()
        self.page.locator('#context-menu [data-action="discard-theme"]').click()
        self.page.locator('[data-action="commit-discard"]').click()
        self.wait_for_assets([saved_asset])
        self.assertEqual(self.saved_theme("ghost")["gifs"][0]["asset"], saved_asset)

    def test_deleting_a_theme_keeps_shared_gif_until_last_copy_is_deleted(self):
        self.observe_gif_frames()
        self.open()
        self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
        self.import_gif()
        asset = next(iter(self.snapshot()["assets"]))
        self.page.locator('[data-action="commit-gif"]').click()
        self.page.locator('[data-action="save-theme"]').click()
        self.open_menu()
        self.page.locator('#context-menu [data-action="copy-theme"]').click()
        self.commit_name("共享素材副本")
        copy_id = self.route()["id"]

        self.open_theme("ghost")
        self.open_menu()
        self.page.locator('#context-menu [data-action="delete-theme"]').click()
        self.page.locator("#replacement").select_option("original")
        self.page.locator('[data-action="commit-delete"]').click()
        self.wait_for_assets([asset])

        self.open_theme(copy_id)
        self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
        expect(self.page.locator('[data-action="commit-gif"]')).to_be_enabled()
        self.page.locator('[data-action="cancel-sheet"]').click()
        self.open_menu()
        self.page.locator('#context-menu [data-action="delete-theme"]').click()
        self.page.locator('[data-action="commit-delete"]').click()
        self.wait_for_assets([])
        self.assertTrue(self.page.evaluate("() => gifFrames.every(image => image.width === 0)"))

    def test_cancel_during_decode_releases_late_frames(self):
        self.observe_gif_frames()
        self.open()
        self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
        self.page.evaluate("() => { window.gifFrameGate = new Promise(resolve => window.resumeGifFrames = resolve); }")
        self.page.locator("#gif-file").set_input_files(
            {"name": "pending.gif", "mimeType": "image/gif", "buffer": GIF_BYTES}
        )
        self.page.wait_for_function("() => gifFrames.length === 1")
        self.page.locator('[data-action="cancel-sheet"]').click()
        self.page.evaluate("() => resumeGifFrames()")
        self.page.wait_for_function(
            "() => gifFrames.length === 2 && gifFrames.every(image => image.width === 0)"
        )
        self.wait_for_assets([])
        self.assertIsNone(self.draft("ghost"))

    def test_reload_cleans_an_import_that_was_never_committed_to_a_draft(self):
        self.open()
        self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
        self.import_gif()
        self.assertEqual(len(self.snapshot()["assets"]), 1)
        self.page.reload()
        expect(self.page.locator("#main-banner")).to_be_visible()
        self.wait_for_assets([])
        self.assertIsNone(self.draft("ghost"))

    def test_clearing_a_gif_reclaims_the_source_only_after_saving(self):
        self.observe_gif_frames()
        self.open()
        editor = self.page.locator('[data-action="edit-gif"][data-index="0"]')
        editor.click()
        self.import_gif()
        asset = next(iter(self.snapshot()["assets"]))
        self.page.locator('[data-action="commit-gif"]').click()
        self.page.locator('[data-action="save-theme"]').click()
        editor.click()
        self.page.locator('[data-action="clear-gif"]').click()
        self.wait_for_assets([asset])
        self.page.locator('[data-action="save-theme"]').click()
        self.wait_for_assets([])
        self.assertTrue(self.page.evaluate("() => gifFrames.every(image => image.width === 0)"))

    def test_live_and_queued_notices_keep_deleted_theme_gifs_until_dismissed(self):
        self.observe_gif_frames()
        self.page.clock.install(time=0)
        self.page.clock.pause_at(1)
        self.open()
        self.page.locator('[data-action="edit-gif"][data-index="1"]').click()
        self.import_gif()
        asset = next(iter(self.snapshot()["assets"]))
        self.page.locator('[data-action="commit-gif"]').click()
        self.page.locator('[data-action="save-theme"]').click()
        self.go_workspace()
        for _ in range(4):
            self.page.locator('[data-action="simulate-scope"]').click()
        banners = self.page.locator("[data-live-banner]")
        expect(banners).to_have_count(3)

        self.open_theme("ghost")
        # The stack overlaps the toolbar; use the supported keyboard path.
        self.page.locator('[data-action="theme-menu"]').focus()
        self.page.keyboard.press("Enter")
        self.page.locator('#context-menu [data-action="delete-theme"]').focus()
        self.page.keyboard.press("Enter")
        self.page.locator("#replacement").select_option("original")
        self.page.locator('[data-action="commit-delete"]').click()
        self.wait_for_assets([asset])
        for count in [3, 2, 1, 0]:
            self.page.locator('[data-action="close-live"]').first.click()
            expect(banners).to_have_count(count)
            self.wait_for_assets([asset] if count else [])
        self.assertTrue(self.page.evaluate("() => gifFrames.every(image => image.width === 0)"))

    def test_cancelling_another_event_editor_preserves_preview_selection_and_frame(self):
        self.open()
        canvas = self.page.locator("#main-banner canvas")
        before = canvas.screenshot()
        selected = self.page.locator('[data-action="preview-event"][aria-checked="true"]')
        for cancel in ["button", "escape"]:
            with self.subTest(cancel=cancel):
                self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
                expect(self.page.locator("#sheet-title")).to_have_text("用户发起动画")
                if cancel == "button":
                    self.page.locator('[data-action="cancel-sheet"]').click()
                else:
                    self.page.keyboard.press("Escape")
                self.page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
                expect(selected).to_have_text("响应结束")
                expect(self.page.locator("#main-banner strong")).to_have_text("Codex 本轮响应结束")
                self.assertTrue(canvas.screenshot() == before, "the preview frame must still match 响应结束")

        self.page.locator('[data-action="edit-gif"][data-index="0"]').click()
        self.page.locator('[data-action="clear-gif"]').click()
        expect(selected).to_have_text("用户发起")
        expect(self.page.locator("#main-banner strong")).to_have_text("Codex 开始响应")
        expect(self.page.locator("#main-banner canvas")).to_have_count(0)

    def assert_live_stack_pauses(self, interaction):
        self.page.emulate_media(reduced_motion="no-preference")
        # Freeze before navigation so initialization and RAF share the same clock.
        self.page.clock.install(time=0)
        self.page.clock.pause_at(1)
        self.open()
        self.go_workspace()
        self.page.locator('[data-action="simulate-both"]').click()
        banners = self.page.locator("[data-live-banner]")
        expect(banners).to_have_count(2)
        self.page.mouse.move(0, 0)
        self.page.clock.run_for(160)
        if interaction == "hover":
            banners.first.hover()
        elif interaction == "gap":
            first, second = banners.first.bounding_box(), banners.last.bounding_box()
            self.page.mouse.move(first["x"] + 10, (first["y"] + first["height"] + second["y"]) / 2)
        else:
            banners.last.focus()
        tracks = banners.locator(".track i")
        before = tracks.evaluate_all("els => els.map(el => el.style.transform)")
        self.assertTrue(all(value.startswith("scaleX(") for value in before))
        frames = [canvas.screenshot() for canvas in banners.locator("canvas").all()]
        self.page.clock.run_for(800)
        self.assertEqual(tracks.evaluate_all("els => els.map(el => el.style.transform)"), before)
        self.assertEqual([canvas.screenshot() for canvas in banners.locator("canvas").all()], frames)
        self.page.clock.run_for(4000)
        expect(banners).to_have_count(2)

        self.page.mouse.move(0, 0)
        self.page.locator('[data-action="simulate-both"]').focus()
        self.page.clock.run_for(160)
        self.assertNotEqual(tracks.evaluate_all("els => els.map(el => el.style.transform)"), before)
        self.page.clock.run_for(4000)
        expect(banners).to_have_count(0)

    def test_hovering_one_banner_pauses_the_entire_stack_and_its_gifs(self):
        self.assert_live_stack_pauses("hover")

    def test_hovering_the_gap_between_banners_pauses_the_entire_stack(self):
        self.assert_live_stack_pauses("gap")

    def test_focusing_one_banner_pauses_the_entire_stack_and_its_gifs(self):
        self.assert_live_stack_pauses("focus")

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
