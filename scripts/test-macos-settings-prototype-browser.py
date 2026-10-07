#!/usr/bin/env python3
"""Offline browser regression for the standalone macOS Settings prototype.

Run from the repository root. Requires Python Playwright and installed Chrome.
Only fixed in-memory demo facts are used. Screenshots and report go to --artifacts
(or a new temporary directory). Every result is bound to the exact HTML SHA-256.
"""
import argparse
import hashlib
import itertools
import json
import tempfile
import traceback
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
HTML = ROOT / "designs/macos-settings-native/claudi0 macOS Settings Prototype.html"
PAGES = ["events", "sounds", "integrations", "notifications", "general", "shortcuts", "usage", "about"]

# Fixed local UI routes and states; no real files, credentials, or services.
DETAIL_ROUTES = [('workspaces', 'events', 'normal', ['workspaces']),
 ('workspace-details', 'events', 'normal', ['workspaces', 'select-workspace:claudio', 'scope-details']),
 ('add-workspace', 'events', 'normal', ['workspaces', 'add-workspace']),
 ('pack-options', 'sounds', 'normal', ['pack-options']),
 ('pack-attribution', 'sounds', 'normal', ['pack-options', 'pack-license']),
 ('restore-pack', 'sounds', 'normal', ['pack-options', 'restore-pack']),
 ('restore-library', 'sounds', 'normal', ['restore-library']),
 ('draft-editor', 'sounds', 'normal', ['new-pack']),
 ('draft-name', 'sounds', 'draft', ['rename-draft']),
 ('draft-system-sound', 'sounds', 'draft', ['system-sound']),
 ('audio-inventory', 'sounds', 'referenceIncomplete', ['audio-files']),
 ('audio-assign', 'sounds', 'referenceIncomplete', ['audio-files', 'assign-file:5']),
 ('audio-delete', 'sounds', 'referenceIncomplete', ['audio-files', 'delete-file:5']),
 ('event-editor', 'sounds', 'referenceIncomplete', ['edit-pack:3']),
 ('binding-files', 'sounds', 'referenceIncomplete', ['edit-pack:3', 'choose-file']),
 ('binding-system', 'sounds', 'referenceIncomplete', ['edit-pack:3', 'system-sound']),
 ('import-one', 'sounds', 'referenceIncomplete', ['edit-pack:3', 'import-audio']),
 ('import-many', 'sounds', 'referenceIncomplete', ['add-audio']),
 ('clear-binding', 'sounds', 'referenceIncomplete', ['edit-pack:3', 'clear-binding']),
 ('profile-service', 'sounds', 'referenceIncomplete', ['service']),
 ('profile-credential', 'sounds', 'credentialPending', ['credential']),
 ('credential-delete', 'sounds', 'credentialPending', ['credential', 'delete-credential']),
 ('host-detail', 'integrations', 'normal', ['host-detail']),
 ('receipt-history', 'integrations', 'hostReady', ['receipt-history']),
 ('host-repair', 'integrations', 'hostFailure', ['repair-host']),
 ('clear-receipts', 'integrations', 'hostReady', ['clear-receipts']),
 ('shortcut-recording', 'shortcuts', 'normal', ['record-key:0']),
 ('log-detail', 'usage', 'normal', ['view-log']),
 ('log-clear', 'usage', 'normal', ['clear-log']),
 ('counts-clear', 'usage', 'normal', ['clear-counts']),
 ('reminder-detail', 'usage', 'reminderNoSession', ['notice:demo-1']),
 ('focus-permission', 'notifications', 'normal', ['control:focusQuiet']),
 ('calendar-permission', 'notifications', 'normal', ['control:calendarQuiet']),
 ('workspace-delete',
  'events',
  'normal',
  ['workspaces', 'select-workspace:claudio', 'scope-details', 'delete-workspace']),
 ('reminder-expired', 'usage', 'reminderExpired', ['notice:demo-1']),
 ('reminder-stale', 'usage', 'reminderStale', ['notice:demo-1', 'open-source']),
 ('source-failure', 'usage', 'sourceFailure', ['notice:demo-1', 'open-source', 'wait:650']),
 ('source-timeout', 'usage', 'sourceTimeout', ['notice:demo-1', 'open-source', 'wait:650']),
 ('directory-failure',
  'events',
  'normal',
  ['workspaces', 'add-workspace', 'select:workspace-directory:failure', 'resolve-directory', 'wait:600']),
 ('credential-checking', 'sounds', 'credentialPending', ['credential', 'check-credential']),
 ('shortcut-validation', 'shortcuts', 'normal', ['record-key:0', 'key:A']),
 ('resource-license', 'about', 'normal', ['open-resource:license']),
 ('resource-attribution', 'about', 'normal', ['open-resource:attribution']),
 ('resource-privacy', 'about', 'normal', ['open-resource:privacy']),
 ('panel-display-set', 'sounds', 'normal', ['panel-packs'])]
STATE_ROUTES = [('directory-resolution',
  'events',
  'normal',
  ['workspaces',
   'add-workspace',
   'select:workspace-directory:failure',
   'resolve-directory',
   'snapshot:resolving-disabled',
   'wait:600',
   'snapshot:failure-disabled']),
 ('workspace-volume-unconfirmed',
  'events',
  'normal',
  ['workspaces',
   'add-workspace',
   'select:workspace-pack:minimal',
   'resolve-directory',
   'wait:600',
   'snapshot:volume-unconfirmed-disabled']),
 ('draft-name-invalid',
  'sounds',
  'draft',
  ['rename-draft', 'fill:draft-name:', 'save-draft-name', 'snapshot:name-failure']),
 ('draft-before-publication',
  'sounds',
  'draft',
  ['snapshot:unpublished-disabled', 'system-sound', 'snapshot:long-sheet-normal']),
 ('pack-delete-retained',
  'sounds',
  'deleteRetained',
  ['pack-options',
   'delete-pack',
   'snapshot:delete-confirm',
   'sheet-confirm',
   'snapshot:deleting-disabled',
   'wait:650',
   'snapshot:isolated-copy-retained']),
 ('restore-library-failure',
  'sounds',
  'restoreFailure',
  ['restore-library',
   'snapshot:restore-confirm',
   'sheet-confirm',
   'snapshot:restoring-disabled',
   'wait:650',
   'snapshot:partial-restore-failure']),
 ('import-one-bind-failure',
  'sounds',
  'importBindFailure',
  ['import-audio',
   'snapshot:import-confirm',
   'sheet-import',
   'snapshot:importing-disabled',
   'wait:650',
   'snapshot:import-kept-binding-failed']),
 ('import-many-partial',
  'sounds',
  'importPartial',
  ['add-audio',
   'snapshot:import-multiple-normal',
   'sheet-add-audio',
   'snapshot:importing-cancellable',
   'wait:650',
   'snapshot:first-import-complete',
   'wait:1050',
   'snapshot:partial-import-result']),
 ('import-many-cancel',
  'sounds',
  'referenceIncomplete',
  ['add-audio',
   'sheet-add-audio',
   'wait:650',
   'cancel-operation',
   'snapshot:cancel-retains-completed-import']),
 ('audio-delete-failure',
  'sounds',
  'fileDeleteFailure',
  ['delete-file:5',
   'snapshot:delete-audio-confirm',
   'sheet-confirm',
   'snapshot:deleting-disabled',
   'wait:650',
   'snapshot:audio-delete-failure']),
 ('binding-write-failure',
  'sounds',
  'bindingFailure',
  ['choose-file', 'snapshot:choice-disabled-in-use', 'choice:wood.wav', 'snapshot:binding-write-failure']),
 ('inventory-failure',
  'sounds',
  'inventoryFailure',
  ['snapshot:inventory-failure-disabled',
   'retry-inventory',
   'snapshot:inventory-reading-disabled',
   'wait:650',
   'snapshot:inventory-recovered']),
 ('manifest-failure', 'sounds', 'manifestFailure', ['snapshot:manifest-failure-disabled']),
 ('reference-incomplete',
  'sounds',
  'referenceIncomplete',
  ['pack-options', 'snapshot:delete-disabled-incomplete-references']),
 ('panel-four-limit', 'sounds', 'fifthStar', ['snapshot:panel-limit-disabled']),
 ('panel-damaged-pack', 'sounds', 'brokenStar', ['snapshot:damaged-pack-existing-star-can-cancel']),
 ('generation-failure',
  'sounds',
  'generationFailure',
  ['generate', 'snapshot:generating-description-locked', 'wait:1250', 'snapshot:generation-failure']),
 ('generation-cancel',
  'sounds',
  'generationFailure',
  ['generate', 'snapshot:generating', 'cancel-generation', 'snapshot:cancel-description-retained']),
 ('generation-partial',
  'sounds',
  'partial',
  ['generate',
   'snapshot:generating',
   'wait:1250',
   'snapshot:two-numbered-candidates',
   'fill:adoption-name:',
   'snapshot:empty-common-name-adoption-disabled']),
 ('adoption-failure',
  'sounds',
  'adoptionFailure',
  ['generate',
   'wait:1250',
   'snapshot:candidates-normal',
   'adopt:0',
   'snapshot:adopting-disabled',
   'wait:650',
   'snapshot:retained-import-adoption-failure']),
 ('credential-pending-check',
  'sounds',
  'credentialPending',
  ['credential',
   'snapshot:pending-five-buttons-normal',
   'check-credential',
   'snapshot:checking-conflicting-actions-disabled',
   'wait:600',
   'snapshot:checking-complete']),
 ('credential-save-rejected',
  'sounds',
  'credentialPending',
  ['credential',
   'select:credential-demo:rejected',
   'save-credential',
   'snapshot:credential-validating',
   'wait:650',
   'snapshot:rejected-old-value-retained']),
 ('credential-save-unavailable',
  'sounds',
  'credentialPending',
  ['credential',
   'select:credential-demo:unavailable',
   'save-credential',
   'snapshot:credential-validating',
   'wait:650',
   'snapshot:storage-unavailable-old-value-retained']),
 ('credential-save-write-failure',
  'sounds',
  'credentialPending',
  ['credential',
   'select:credential-demo:writeFailure',
   'save-credential',
   'snapshot:credential-validating',
   'wait:650',
   'snapshot:save-failure-old-value-retained']),
 ('credential-delete-failure',
  'sounds',
  'credentialDeleteFailure',
  ['credential',
   'delete-credential',
   'snapshot:credential-delete-confirm',
   'sheet-confirm',
   'snapshot:credential-deleting',
   'wait:650',
   'snapshot:credential-delete-failure']),
 ('credential-missing-disabled',
  'sounds',
  'credentialMissing',
  ['credential', 'snapshot:credential-delete-disabled']),
 ('host-repair-failure',
  'integrations',
  'hostFailure',
  ['repair-host',
   'snapshot:repair-confirm',
   'sheet-confirm',
   'snapshot:integration-working-disabled',
   'wait:650',
   'snapshot:repair-failure']),
 ('host-repair-awaiting-receipt',
  'integrations',
  'normal',
  ['repair-host',
   'sheet-confirm',
   'snapshot:integration-working-disabled',
   'wait:650',
   'snapshot:configuration-repaired-awaiting-receipt']),
 ('receipt-clear-failure',
  'integrations',
  'receiptClearFailure',
  ['clear-receipts',
   'snapshot:receipt-clear-confirm',
   'sheet-confirm',
   'snapshot:clearing-receipts-disabled',
   'wait:650',
   'snapshot:receipt-clear-failure']),
 ('focus-permission-denied',
  'notifications',
  'normal',
  ['control:focusQuiet',
   'snapshot:permission-sheet',
   'permission-deny',
   'snapshot:policy-enabled-permission-denied']),
 ('calendar-permission-denied',
  'notifications',
  'normal',
  ['control:calendarQuiet', 'permission-deny', 'snapshot:policy-enabled-permission-denied']),
 ('receiver-failure', 'notifications', 'receiverFailure', ['snapshot:receiver-failure']),
 ('login-failure',
  'general',
  'loginFailure',
  ['control:login',
   'snapshot:login-changing-disabled',
   'wait:650',
   'snapshot:login-failure-previous-value-retained']),
 ('shortcut-invalid-key',
  'shortcuts',
  'normal',
  ['record-key:0', 'snapshot:recording', 'key:A', 'snapshot:validation-failure-recording']),
 ('shortcut-registration-failure',
  'shortcuts',
  'shortcut-registrationFailed',
  ['record-key:0', 'key:Control+Alt+J', 'snapshot:registration-failure']),
 ('shortcut-rollback-failure',
  'shortcuts',
  'shortcut-rollbackFailed',
  ['record-key:0', 'key:Control+Alt+J', 'snapshot:rollback-failure-unregistered']),
 ('activity-refresh-failure',
  'usage',
  'activityRefreshFailure',
  ['refresh-activity',
   'snapshot:activity-refreshing-disabled',
   'wait:650',
   'snapshot:activity-stale-retains-data']),
 ('log-clear-failure',
  'usage',
  'logClearFailure',
  ['clear-log', 'sheet-confirm', 'snapshot:clearing-log-disabled', 'wait:650', 'snapshot:clear-log-failure']),
 ('count-clear-failure',
  'usage',
  'countClearFailure',
  ['clear-counts',
   'sheet-confirm',
   'snapshot:clearing-counts-disabled',
   'wait:650',
   'snapshot:clear-counts-failure']),
 ('reminder-no-session',
  'usage',
  'reminderNoSession',
  ['notice:demo-1', 'snapshot:session-actions-disabled']),
 ('reminder-expired', 'usage', 'reminderExpired', ['notice:demo-1', 'snapshot:expired-data-erased']),
 ('reminder-stale',
  'usage',
  'reminderStale',
  ['notice:demo-1', 'open-source', 'snapshot:old-reading-rejected']),
 ('source-opening-failure',
  'usage',
  'sourceFailure',
  ['notice:demo-1',
   'open-source',
   'snapshot:opening-source-disabled',
   'wait:650',
   'snapshot:source-opening-failure']),
 ('source-opening-timeout',
  'usage',
  'sourceTimeout',
  ['notice:demo-1',
   'open-source',
   'snapshot:opening-source-disabled',
   'wait:650',
   'snapshot:source-opening-timeout']),
 ('resource-missing', 'about', 'resourceMissing', ['snapshot:three-resources-disabled']),
 ('resource-open-failure',
  'about',
  'resourceFailure',
  ['open-resource:privacy', 'snapshot:resource-open-failure']),
 ('clipboard-version-failure',
  'about',
  'clipboardFailure',
  ['copy-version', 'snapshot:clipboard-failure-content-retained']),
 ('clipboard-diagnostic-failure',
  'about',
  'clipboardFailure',
  ['copy-diagnostics', 'snapshot:clipboard-failure-content-retained']),
 ('about-unknown', 'about', 'aboutUnknown', ['snapshot:unknown-facts'])]


class Regression:
    def __init__(self, browser, artifacts, launch_browser=None):
        self.browser = browser
        self.launch_browser = launch_browser
        self.artifacts = artifacts
        self.context = None
        self.page = None
        self.errors = []
        self.runner_errors = []
        self.requests = []
        self.checks = []
        self.layouts = []
        self.state_layouts = []
        self.detail_layouts = []
        self.operation_layouts = []
        self.cases = []
        self.case = "layout"

    def recycle_browser(self):
        # Each variant is independent. Bound Chrome resources during long matrices.
        if self.launch_browser and self.context:
            self.context.close()
            self.context = None
            self.page = None
            self.browser.close()
            self.browser = self.launch_browser()

    def failure_screenshot(self, name):
        try:
            if self.page and not self.page.is_closed():
                self.page.screenshot(path=str(self.artifacts/name))
        except Exception as e:
            self.runner_errors.append({"case":self.case,"stage":"failure-screenshot","error":str(e)})

    def fresh(self, **query):
        if self.context:
            self.context.close()
        size = query.get("size", "default")
        width, height = (960, 640) if size == "minimum" else (1240, 820)
        self.context = self.browser.new_context(
            viewport={"width": width, "height": height}, offline=True,
            reduced_motion="reduce", permissions=["clipboard-read", "clipboard-write"],
        )
        self.page = self.context.new_page()
        self.page.set_default_timeout(4000)
        self.page.on("pageerror", lambda e: self.errors.append({"case": self.case, "error": str(e)}))
        self.page.on("request", lambda r: self.requests.append(r.url) if r.url.startswith(("http:", "https:")) else None)
        self.page.goto(HTML.as_uri() + "?" + urlencode({"clean": "1", **query}))
        self.page.wait_for_selector("#settings-nav .nav-item")

    def act(self, name):
        locator = self.page.locator(f'[data-action="{name}"]')
        if not locator.count() and name in ["detail-back", "window-close"]:
            locator = self.page.locator("#"+name)
        if self.page.locator("#sheet").evaluate("e => e.open"):
            in_sheet = self.page.locator(f'#sheet [data-action="{name}"]')
            if in_sheet.count():
                locator = in_sheet
        self.check(f"control {name} reachable", locator.count() == 1)
        locator.click()

    def select(self, name, value):
        self.page.locator(f'[data-control="{name}"]').select_option(value)

    def state(self, expression="S"):
        return self.page.evaluate(f"() => structuredClone({expression})")

    def settled(self):
        self.page.wait_for_function("!S.operation")

    def check(self, label, condition):
        self.checks.append({"case": self.case, "label": label, "passed": bool(condition)})
        if not condition:
            raise AssertionError(label)

    def contains(self, text, selector="#page-content"):
        self.check(f"visible result {text}", text in self.page.locator(selector).inner_text())

    def scene(self, name, **query):
        self.fresh(scene=name, **query)

    def confirm(self):
        self.act("sheet-confirm")
        self.settled()

    def generate(self):
        self.act("generate")
        self.page.wait_for_function("S.generation !== 'busy'")

    def layout(self):
        return self.page.evaluate("""() => {
            const win=document.querySelector('#settings-window'), side=document.querySelector('#sidebar'),
            scroll=document.querySelector('#page-scroll'), content=document.querySelector('#page-content');
            const wr=win.getBoundingClientRect(), cr=content.getBoundingClientRect(), sr=scroll.getBoundingClientRect();
            const cs=getComputedStyle(content);
            const overflow=[...content.querySelectorAll('.row,.group,.controls,input,select,textarea,button')]
                .filter(e => e.getBoundingClientRect().width &&
                    (e.getBoundingClientRect().right>sr.right+1 || e.getBoundingClientRect().left<sr.left-1))
                .map(e=>({tag:e.tagName,action:e.dataset.action,control:e.dataset.control,text:e.innerText?.slice(0,70)}));
            const nameless=[...document.querySelectorAll('#settings-window button,#settings-window input,#settings-window select,#settings-window textarea')]
                .filter(e=>e.getBoundingClientRect().width && !e.getAttribute('aria-label') && !e.innerText?.trim() &&
                    !document.querySelector('label[for="'+e.id+'"]'))
                .map(e=>e.outerHTML.slice(0,160));
            return {width:wr.width,height:wr.height,side:side.getBoundingClientRect().width,content:cr.width,
                padding:parseFloat(cs.paddingLeft),background:getComputedStyle(scroll).backgroundColor,
                detailBackground:getComputedStyle(document.querySelector('.detail')).backgroundColor,
                horizontal:scroll.scrollWidth>scroll.clientWidth+1 || document.documentElement.scrollWidth>innerWidth,
                overflow,nameless,scrollHeight:scroll.scrollHeight,clientHeight:scroll.clientHeight,
                nav:document.querySelectorAll('.nav-item').length};
        }""")

    def layout_checks(self, sample, size):
        self.check("window geometry", sample["width"] == (960 if size == "minimum" else 1240) and sample["height"] == (640 if size == "minimum" else 820))
        self.check("sidebar geometry", sample["side"] == (210 if size == "minimum" else 252))
        self.check("780 includes padding", sample["content"] <= 780 and sample["padding"] == (26 if size == "minimum" else 32))
        self.check("eight pages reachable", sample["nav"] == 8)
        self.check("no horizontal overflow", not sample["horizontal"] and not sample["overflow"])
        self.check("controls named", not sample["nameless"])
        self.page.locator("#page-scroll").evaluate("e=>e.scrollTop=e.scrollHeight")
        self.check("scroll end reachable", self.page.locator("#page-scroll").evaluate("e=>e.scrollTop+e.clientHeight>=e.scrollHeight-1"))

    def all_layouts(self):
        for lang, theme, size, page in itertools.product(["zh", "en"], ["light", "dark"], ["default", "minimum"], PAGES):
            self.case = f"layout:{lang}:{theme}:{size}:{page}"
            self.fresh(lang=lang, theme=theme, size=size, page=page)
            sample = self.layout()
            self.layout_checks(sample, size)
            self.page.locator("#page-scroll").evaluate("e=>e.scrollTop=0")
            name = f"{lang}-{theme}-{size}-{page}.png"
            self.page.screenshot(path=str(self.artifacts / name))
            self.layouts.append({"lang":lang,"theme":theme,"size":size,"page":page,"screenshot":name,**sample})
        for name in self.state("prototypeReview.scenes"):
            self.case = f"state-layout:{name}"
            self.scene(name, lang="en", theme="dark", size="minimum")
            sample = self.layout()
            self.layout_checks(sample, "minimum")
            self.state_layouts.append({"scene": name, **sample})
        self.case = "page-backgrounds"
        for theme in ["light", "dark"]:
            bg = {s["detailBackground"] for s in self.layouts if s["theme"] == theme}
            self.check("all eight page backgrounds match", len(bg) == 1)

    def detail_sample(self, label, lang, theme, size, target):
        # Wait one frame for the sheet's initial focus; operation timers are >=450ms.
        self.page.evaluate("() => new Promise(requestAnimationFrame)")
        sample = self.layout()
        self.layout_checks(sample, size)
        dialog = self.page.locator("#sheet").evaluate("""e => {
            if (!e.open) return null;
            const r=e.getBoundingClientRect(), h=e.querySelector('h2').getBoundingClientRect();
            const visible=e=>e.getBoundingClientRect().width && getComputedStyle(e).visibility!=='hidden';
            return {title:e.querySelector('h2').innerText,
                withinWindow:r.left>=0 && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight,
                horizontal:e.scrollWidth>e.clientWidth+1,
                overflow:[...e.querySelectorAll('button,input,select,textarea,.row,.controls')].filter(visible)
                    .filter(n=>n.getBoundingClientRect().left<r.left || n.getBoundingClientRect().right>r.right)
                    .map(n=>n.dataset.action||n.id||n.tagName),
                clippedButtons:[...e.querySelectorAll('button')].filter(visible)
                    .filter(n=>n.scrollWidth>n.clientWidth+1).map(n=>n.dataset.action),
                titleVisible:h.top>=r.top && h.bottom<=r.bottom};
        }""")
        if dialog:
            self.check("sheet fits viewport",dialog["withinWindow"] and not dialog["horizontal"] and not dialog["overflow"])
            self.check("sheet actions fit text",not dialog["clippedButtons"])
            self.check("sheet title/result present",bool(dialog["title"]))
            # Validation may intentionally focus a result lower in a long sheet.
            if label in ["draft-system-sound","binding-system","long-sheet-normal"]:
                self.check("long sheet starts at title",dialog["titleVisible"])
            self.page.locator("#sheet").evaluate("e=>e.scrollTop=e.scrollHeight")
            self.check("sheet scroll end reachable",self.page.locator("#sheet").evaluate("e=>e.scrollTop+e.clientHeight>=e.scrollHeight-1"))
        projected=self.page.evaluate("prototypeReview.getState()")
        target.append({"route":label,"lang":lang,"theme":theme,"size":size,
            "page":projected["page"],"detail":projected["detail"],"operation":projected["operation"],
            "generation":projected["generation"],"dialog":dialog,**sample})

    def route_steps(self, actions, lang, theme, size, target):
        for action in actions:
            if action.startswith("snapshot:"):
                self.detail_sample(action[9:],lang,theme,size,target)
            elif action.startswith("wait:"):
                self.page.wait_for_timeout(int(action[5:]))
            elif action.startswith("key:"):
                self.page.keyboard.press(action[4:])
            elif action.startswith("select:"):
                _,name,value=action.split(":",2)
                self.page.locator("#"+name).select_option(value)
            elif action.startswith("fill:"):
                _,name,value=action.split(":",2)
                self.page.locator("#"+name).fill(value)
            elif action.startswith("choice:"):
                self.page.locator('[data-choice="'+action[7:]+'"]').click()
            elif action.startswith("control:"):
                self.page.locator('[data-control="'+action[8:]+'"]').click()
            elif action.startswith("selector:"):
                self.page.locator(action[9:]).click()
            else:
                self.act(action)

    def all_detail_layouts(self):
        page_details={"workspaces":"workspaces","workspace-details":"scope-details",
            "draft-editor":"edit:task_start","audio-inventory":"audio","event-editor":"edit:notification",
            "profile-service":"service","host-detail":"host","panel-display-set":"panel"}
        for lang,theme,size in itertools.product(["zh","en"],["light","dark"],["default","minimum"]):
            self.recycle_browser()
            for name,page,scene,actions in DETAIL_ROUTES:
                self.case=f"detail:{lang}:{theme}:{size}:{name}"
                self.fresh(lang=lang,theme=theme,size=size,scene=scene,page=page)
                self.route_steps(actions,lang,theme,size,self.detail_layouts)
                if name in page_details:
                    self.check("expected detail result",self.state("S.detail")==page_details[name])
                else:
                    self.check("expected sheet result",self.page.locator("#sheet").evaluate("e=>e.open"))
                self.detail_sample(name,lang,theme,size,self.detail_layouts)
            for name,page,scene,actions in STATE_ROUTES:
                self.case=f"operation-layout:{lang}:{theme}:{size}:{name}"
                self.fresh(lang=lang,theme=theme,size=size,scene=scene,page=page)
                self.route_steps(actions,lang,theme,size,self.operation_layouts)
            print(f"PASS details/states {lang} {theme} {size}",flush=True)

    def C01(self):
        self.fresh()
        initial = self.state("S.scopes")
        self.select("scope", "claudio")
        self.select("scope-pack", "soft")
        self.page.locator('[data-control="volume"]').fill("38")
        self.page.locator('[data-control="volume"]').dispatch_event("change")
        self.page.locator('[data-control="event:1"]').uncheck()
        scopes = self.state("S.scopes")
        self.check("workspace independent pack volume switches", scopes[1]["pack"]=="soft" and scopes[1]["volume"]==38 and not scopes[1]["enabled"][1])
        self.check("default unchanged", scopes[0] == initial[0])

    def C02(self):
        self.scene("zero")
        self.check("zero disables preview", self.page.locator('[data-action="preview:0"]').is_disabled())
        self.contains("音量为 0")
        self.scene("previewFailure")
        self.act("preview:3")
        self.contains("无法试听")
        self.act("refresh-library")
        self.settled()
        self.check("preview repair removes failure", not self.state("S.faults.preview"))
        self.fresh(page="sounds")
        self.check("no pack sequence", self.page.locator('[data-action="preview-all"]').count()==0)

    def C03(self):
        self.fresh()
        self.select("scope", "claudio")
        self.act("edit-from-scope:3")
        self.act("system-sound")
        self.page.locator('[data-choice="Glass"]').click()
        self.act("return-scope")
        self.check("saved binding survives return", self.state("S.packs.find(p=>p.id==='studio').sounds[3]")=="Glass")
        self.check("return scope identity", self.state("S.scope")=="claudio")
        self.page.wait_for_function("document.activeElement.dataset.action==='edit-from-scope:3'")
        self.check("return focus", self.page.evaluate("document.activeElement.dataset.action")=="edit-from-scope:3")
        self.act("edit-from-scope:3")
        self.page.evaluate("S.scopes.find(g=>g.id==='claudio').path='~/Different';")
        self.act("return-scope")
        self.contains("请显式重新选择")
        self.check("invalid target does not write default", self.state("S.scopes[0].pack")=="minimal")
        self.check("invalid target focus", self.page.evaluate("document.activeElement.id")=="target-unavailable")

    def C04(self):
        self.fresh()
        self.act("workspaces")
        self.act("add-workspace")
        self.check("no custom workspace name", self.page.locator("#workspace-name").count()==0)
        self.check("volume confirmation required", self.page.locator('[data-action="sheet-add-workspace"]').is_disabled())
        self.act("resolve-directory")
        self.page.wait_for_function("document.querySelector('#directory-result').textContent.includes('NewProject')")
        self.page.locator("#workspace-pack").select_option("soft")
        self.page.locator("#workspace-claude").uncheck()
        self.page.locator("#workspace-codex").uncheck()
        self.page.locator("#workspace-volume-confirm").check()
        self.page.locator("#workspace-volume").fill("42")
        self.check("volume changes invalidate confirmation", not self.page.locator("#workspace-volume-confirm").is_checked())
        self.page.locator("#workspace-volume-confirm").check()
        self.act("sheet-add-workspace")
        g=self.state("S.scopes.at(-1)")
        self.check("directory-derived name zero surfaces", g["name"]=="NewProject" and g["surfaces"]==[] and g["volume"]==42 and all(g["enabled"]))
        self.act("scope-details")
        self.contains("没有适用来源")
        self.act("detail-back")
        self.check("details return preserves explicit workspace selection",self.state("S.scope")==g["id"])
        self.select("scope", "default")
        self.act("workspaces")
        self.act("add-workspace")
        self.page.locator("#workspace-directory").select_option("failure")
        self.act("resolve-directory")
        self.page.wait_for_function("document.querySelector('#sheet-error').textContent.includes('Git')")
        self.check("Git failure no plain fallback", self.page.locator('[data-action="sheet-add-workspace"]').is_disabled())
        self.fresh()
        self.act("workspaces")
        self.act("add-workspace")
        self.act("resolve-directory")
        self.page.locator("#workspace-directory").select_option("plain")
        self.page.wait_for_timeout(550)
        self.check("late old-directory resolution rejected", "NewProject" not in self.page.locator("#directory-result").inner_text())
        self.check("changed directory needs new resolution",self.page.locator('[data-action="sheet-add-workspace"]').is_disabled())
        self.act("resolve-directory")
        self.page.wait_for_function("document.querySelector('#directory-result').textContent.includes('NewNotes')")
        self.page.locator("#workspace-pack").select_option("minimal")
        self.page.locator("#workspace-volume-confirm").check()
        self.act("sheet-add-workspace")
        self.check("new explicit directory is actual write target",self.state("S.scopes.at(-1).path")=="~/Documents/NewNotes")

    def C05(self):
        self.fresh()
        self.select("scope","notes")
        self.act("scope-details")
        self.page.locator('[data-control="scope-surface:claude-code"]').uncheck()
        self.contains("没有适用来源")
        self.check("WorkBuddy eligibility blocked", self.page.locator('[data-control="scope-surface:workbuddy"]').is_disabled())
        self.act("delete-workspace")
        self.act("sheet-cancel")
        self.check("cancel preserves rule", len(self.state("S.scopes"))==3)
        self.act("delete-workspace")
        self.confirm()
        self.check("delete only rule", len(self.state("S.packs"))==7 and len(self.state("S.scopes"))==2)
        self.check("deleted target remains unavailable", self.state("S.scope")=="notes" and bool(self.state("S.invalidScope")))

    def C06(self):
        self.scene("migration")
        self.contains("旧来源覆盖已停用")
        self.scene("ruleBroken")
        self.check("broken rule no volume", self.page.locator('[data-control="volume"]').count()==0)
        self.select("scope","default")
        self.select("scope","claudio")
        self.check("reselect broken rule cannot enable writes", self.page.locator('[data-control="volume"]').count()==0)
        self.scene("configConflict")
        self.select("scope-pack","soft")
        self.check("write failure retains value", self.state("S.scopes[0].pack")=="minimal")
        self.act("retry-config")
        self.check("retry writes exact original intent", self.state("S.scopes[0].pack")=="soft")
        self.scene("configConflict")
        self.page.locator('[data-control="event:3"]').click()
        self.select("scope","notes")
        self.act("retry-config")
        self.check("cross-scope retry preserves captured target",not self.state("S.scopes[0].enabled[3]") and self.state("S.scopes[2].enabled[3]"))

    def C07(self):
        for name,state in [("libraryLoading","loading"),("libraryRefreshing","refreshing"),("libraryFailure","failed"),("libraryStale","stale")]:
            self.scene(name)
            self.check("library status exact "+state,self.state("S.library")==state)
            self.contains("声音包")
        self.act("retry-library")
        self.settled()
        self.check("retry reloaded",self.state("S.library")=="ready")

    def C08(self):
        self.fresh(page="sounds")
        initial=self.state("S.scopes")
        self.select("pack","soft")
        self.check("view does not apply",self.state("S.scopes")==initial)
        self.select("management-scope","notes")
        self.act("use-pack")
        self.check("use applies captured current scope",self.state("S.scopes[2].pack")=="soft" and self.state("S.scopes[0].pack")=="minimal")

    def C09(self):
        # Keep the historical case ID as a guard for the retired prototype controls.
        self.fresh(page="sounds")
        initial_scopes=self.state("S.scopes")
        initial_packs=self.state("S.packs")
        for pack_id in ["minimal","studio"]:
            self.select("pack",pack_id)
            for detail in [False,True]:
                if detail:
                    self.act("edit-pack:3")
                self.check("retired pack copy controls absent",self.page.locator('[data-action="copy-pack"], [data-action="copy-and-use"]').count()==0)
            self.act("back-sounds")
        self.check("browsing preserves packs and scope selections",self.state("S.packs")==initial_packs and self.state("S.scopes")==initial_scopes)
        self.check("retired copy scenes absent",not {"copyFailure","copyApplyFailure"}.intersection(self.state("prototypeReview.scenes")))

    def C10(self):
        self.scene("referenceIncomplete")
        self.act("pack-options")
        self.check("incomplete refs prevent deletion", self.page.locator('[data-action="delete-pack"]').is_disabled())
        self.act("sheet-cancel")
        self.fresh(page="sounds")
        self.select("pack","studio")
        self.act("pack-options")
        self.check("active pack protected",self.page.locator('[data-action="delete-pack"]').is_disabled())
        self.scene("deleteRetained")
        self.act("pack-options")
        self.act("delete-pack")
        self.confirm()
        self.contains("隔离副本保留")
        self.check("isolated original unavailable",not self.state("S.packs.some(p=>p.id==='studio'&&p.healthy)"))

    def C11(self):
        self.fresh(page="sounds")
        self.act("pack-options")
        self.act("pack-license")
        self.contains("CC0","#sheet")
        self.act("sheet-cancel")
        self.act("pack-options")
        self.act("restore-pack")
        self.confirm()
        self.contains("已恢复 1 个")
        self.act("pack-options")
        self.act("reveal-pack")
        self.contains("Demo/packs/minimal")

    def C12(self):
        self.scene("restoreFailure")
        before=self.state("S.packs.find(p=>p.id==='studio')")
        scopes=self.state("S.scopes")
        self.act("restore-library")
        self.confirm()
        self.contains("2 个工厂包已恢复")
        self.check("factory restore retains user and groups",self.state("S.packs.find(p=>p.id==='studio')")==before and self.state("S.scopes")==scopes)
        self.act("retry-last")
        self.confirm()
        self.contains("已恢复 6 个")

    def C13(self):
        self.scene("fifthStar")
        self.check("new fifth blocked",self.page.locator('[data-action="star:pizzicato"]').is_disabled())
        self.act("star:bowl")
        self.check("existing fifth removable",len(self.state("S.stars"))==4)
        self.scene("brokenStar")
        self.check("broken existing star enabled",self.page.locator('[data-action="star:studio"]').is_enabled())
        self.act("star:studio")
        self.check("broken unstarred cannot add",self.page.locator('[data-action="star:studio"]').is_disabled())

    def C14(self):
        self.fresh(page="sounds")
        self.select("pack","studio")
        self.act("edit-pack:3")
        self.act("choose-file")
        self.check("occupied file disabled",self.page.locator('[data-choice="intro.wav"]').is_disabled())
        self.page.locator('[data-choice="warm.wav"]').click()
        self.check("file assignment",self.state("S.packs.find(p=>p.id==='studio').sounds[3]")=="warm.wav")
        self.scene("bindingFailure")
        self.act("system-sound")
        self.check("occupied system sound disabled",self.page.locator('[data-choice="Basso"]').is_disabled())
        self.page.locator('[data-choice="Glass"]').click()
        self.contains("绑定写入失败")
        self.check("CAS failure retains prior mapping",self.state("S.packs.find(p=>p.id==='studio').sounds[3]")=="knock.wav")

    def C15(self):
        self.scene("importBindFailure")
        self.act("import-audio")
        self.act("sheet-import")
        self.settled()
        self.contains("已导入，绑定失败")
        self.check("imported file retained old mapping",self.state("S.packs.find(p=>p.id==='studio').audio.includes('imported-chime.wav')") and self.state("S.packs.find(p=>p.id==='studio').sounds[3]")=="knock.wav")
        self.act("clear-binding")
        self.confirm()
        self.check("clear retains audio file",self.state("S.packs.find(p=>p.id==='studio').sounds[3]") is None and self.state("S.packs.find(p=>p.id==='studio').audio.includes('knock.wav')"))

    def C16(self):
        self.fresh(page="sounds")
        self.select("pack","studio")
        self.act("audio-files")
        self.check("no unbound standalone preview",self.page.locator('[data-action^="unbound-preview"]').count()==0)
        self.check("bound audio cannot delete",self.page.locator('[data-action="delete-file:0"]').is_disabled())
        self.act("assign-file:4")
        self.act("sheet-assign:3")
        self.check("direct assignment",self.state("S.packs.find(p=>p.id==='studio').sounds[3]")=="warm.wav")
        self.act("delete-file:5")
        self.confirm()
        self.check("unbound deletion",not self.state("S.packs.find(p=>p.id==='studio').audio.includes('wood.wav')"))

    def C17(self):
        self.scene("importPartial")
        self.act("add-audio")
        self.act("sheet-add-audio")
        self.settled()
        self.contains("1 个已导入，1 个失败")
        self.check("partial files accurate",self.state("S.packs.find(p=>p.id==='studio').audio.includes('added-bell.wav')") and not self.state("S.packs.find(p=>p.id==='studio').audio.includes('added-wood.wav')"))
        self.fresh(page="sounds")
        self.select("pack","studio")
        self.act("add-audio")
        self.act("sheet-add-audio")
        self.page.wait_for_function("S.operation?.imported.length===1")
        self.act("cancel-operation")
        self.contains("成功导入的文件保留")
        self.check("cancel retains completed file",self.state("S.packs.find(p=>p.id==='studio').audio.includes('added-bell.wav')"))

    def C18(self):
        self.scene("inventoryFailure")
        self.check("inventory failed disables mutation",self.page.locator('[data-action="assign-file:4"]').is_disabled())
        self.act("retry-inventory")
        self.settled()
        self.check("inventory retry enables",self.page.locator('[data-action="assign-file:4"]').is_enabled())
        self.scene("manifestFailure")
        self.act("reveal-manifest")
        self.contains("manifest.json")
        self.act("retry-manifest")
        self.settled()
        self.check("retry does not magically fix manifest",not self.state("S.packs.find(p=>p.id==='studio').healthy"))

    def C19(self):
        self.fresh(page="sounds")
        initial=self.state("S.scopes")
        self.act("new-pack")
        self.check("draft has no file import",self.page.locator('[data-action="import-audio"]').count()==0 and self.page.locator('[data-action="choose-file"]').count()==0)
        self.check("empty draft is unpublished",len(self.state("S.packs"))==7)
        self.act("system-sound")
        self.page.locator('[data-choice="Glass"]').click()
        self.check("first system binding publishes ordinary user pack",len(self.state("S.packs"))==8 and self.state("S.draft") is None and self.state("S.scopes")==initial)
        self.check("published file import enabled",self.page.locator('[data-action="import-audio"]').is_enabled())

    def C20(self):
        self.scene("draft")
        original=self.state("S.draft.name")
        self.act("rename-draft")
        self.page.locator("#draft-name").fill("Renamed demo")
        self.act("sheet-cancel")
        self.check("cancel draft name unchanged",self.state("S.draft.name")==original)
        self.act("rename-draft")
        self.check("native 64-character draft contract",self.page.locator("#draft-name").get_attribute("data-maximum-characters")=="64")
        self.page.locator("#draft-name").fill("x"*64)
        self.act("save-draft-name")
        self.check("64-character draft is accepted",len(self.state("S.draft.name"))==64)
        self.act("rename-draft")
        self.page.locator("#draft-name").fill("Renamed demo")
        self.act("save-draft-name")
        self.check("saved draft name unpublished",self.state("S.draft.name")=="Renamed demo" and len(self.state("S.packs"))==7)
        self.act("cancel-draft")
        self.check("empty draft discarded",self.state("S.draft") is None)

    def C21(self):
        self.fresh(page="sounds")
        self.act("service")
        ids=self.state("profiles.map(p=>p.id)")
        self.check("five exact fixed profiles",ids==["elevenlabs-global","minimax-global","qwen-singapore","qwen-beijing","senseaudio-cn"])
        for pr in ids:
            self.check("profile reachable "+pr,self.page.locator(f'[data-action="profile:{pr}"]').count()==1)
        self.act("profile:senseaudio-cn")
        self.contains("未加密")
        self.contains("1/3 或 2/3")

    def C22(self):
        for scene,status in [("credentialChecking","checking"),("credentialMissing","missing"),("credentialRejected","rejected"),("credentialUnavailable","unavailable"),("credentialPending","pending")]:
            self.scene(scene)
            self.check("credential state "+status,self.state("credential().status")==status)
        self.act("credential")
        self.check("no real key input",self.page.locator('#sheet input[type="password"],#sheet input[type="text"]').count()==0)
        self.act("check-credential")
        self.page.wait_for_function("credential().status==='pending'")

    def C23(self):
        self.scene("credentialPending")
        self.act("credential")
        self.act("cancel-replacement")
        self.check("cancel replacement restores active",self.state("credential().status")=="verified")
        self.act("credential")
        self.page.locator("#credential-demo").select_option("writeFailure")
        self.act("save-credential")
        self.settled()
        self.check("failed save retains active",self.state("credential().status")=="verified")
        self.act("credential")
        self.act("save-credential")
        self.settled()
        self.check("Qwen save deferred pending no generation",self.state("credential().status")=="pending" and self.state("S.generation") is None)
        self.act("credential")
        self.act("delete-credential")
        self.act("sheet-cancel")
        self.check("cancel delete no effect",self.state("credential().status")=="pending")
        self.scene("credentialDeleteFailure")
        self.act("credential")
        self.act("delete-credential")
        self.confirm()
        self.contains("凭据删除失败")
        self.check("delete failure retains credential",self.state("credential().status")=="verified")

    def C24(self):
        self.scene("partial")
        description=self.state("S.description")
        self.act("generate")
        self.check("generation locks retained description",self.page.locator("#cue-description").is_disabled() and self.state("S.description")==description)
        self.act("cancel-generation")
        self.check("cancel unlocks description",self.page.locator("#cue-description").is_enabled())
        self.generate()
        self.check("route allows partial",len(self.state("S.candidates"))==2 and self.state("S.candidates.every(c=>!c.style)"))
        self.act("modify-description")
        self.check("modify clears candidates",self.state("S.candidates")==[])
        self.generate()
        self.page.locator("#cue-description").fill("short bright bell")
        self.check("input invalidates candidates",self.state("S.candidates")==[])
        self.scene("generationFailure")
        self.generate()
        self.contains("生成失败")

    def C25(self):
        self.scene("adoptionFailure")
        self.generate()
        self.check("one common adoption field",self.page.locator("#adoption-name").count()==1 and self.page.locator('[data-control^="candidate-name:"]').count()==0)
        self.check("native description length contract",self.page.locator("#cue-description").get_attribute("data-maximum-characters")=="1000")
        self.check("native adoption name contract",self.page.locator("#adoption-name").get_attribute("data-maximum-characters")=="40")
        identities=self.state("S.candidates.map(c=>c.id)")
        self.page.locator("#adoption-name").fill("Shared adoption name")
        self.check("name preserves candidate identity",self.state("S.candidates.map(c=>c.id)")==identities)
        self.act("candidate-preview:0")
        self.check("candidate preview plays",self.page.locator('[data-action="candidate-preview:0"]').get_attribute("aria-pressed")=="true")
        self.act("adopt:0")
        self.settled()
        self.contains("原绑定和包声明保留")
        self.check("adoption failure preserves candidate and mapping",len(self.state("S.candidates"))==3 and self.state("pack().sounds[3]")=="knock.wav")
        self.page.evaluate("S.credentials[S.profile]={status:'missing'};render();")
        self.act("retry-last")
        self.settled()
        self.check("valid candidate adoption independent of credential",self.state("pack().sounds[3]")=="Shared adoption name.wav" and self.state("S.candidates")==[])

    def C26(self):
        self.fresh(page="sounds")
        self.select("pack","studio")
        other_packs=self.state("S.packs.filter(p=>p.id!=='studio')")
        self.check("user pack starts with whole-pack claims",bool(self.state("pack().license")) and bool(self.state("pack().author")))
        self.act("edit-pack:3")
        self.act("open-generation")
        self.generate()
        self.contains("license / author")
        self.act("adopt:0")
        self.settled()
        self.check("adopt drops claims",not self.state("'license' in pack()") and not self.state("'author' in pack()"))
        self.check("adoption preserves other packs",self.state("S.packs.filter(p=>p.id!=='studio')")==other_packs)

    def C27(self):
        self.fresh(page="integrations")
        before=self.state("S.hosts")
        self.act("select-host:claude-code")
        self.check("selection does not connect",self.state("S.hosts")==before)
        self.page.locator('[data-control="host-enabled:claude-code"]').click()
        self.act("sheet-cancel")
        self.check("cancel disconnect retains enabled",self.state("S.hosts[0].enabled"))
        self.page.locator('[data-control="host-enabled:claude-code"]').click()
        self.confirm()
        self.check("surface independent disconnect",not self.state("S.hosts[0].enabled") and self.state("S.hosts[1]")==before[1])
        self.page.locator('[data-control="host-enabled:claude-code"]').click()
        self.confirm()
        self.check("connect waits for receipt",self.state("S.hosts[0].state")=="awaitingActivation")

    def C28(self):
        for scene,status in [("hostNotConnected","notConnected"),("hostLegacy","legacy"),("hostAwaiting","awaitingActivation"),("hostReady","ready")]:
            self.scene(scene)
            self.check("source state "+status,self.state("host().state")==status)
        self.scene("hostFailure")
        old=self.state("S.hosts")
        self.act("repair-host")
        self.confirm()
        self.check("failure preserves all surfaces",self.state("S.hosts")==old)
        self.act("retry-last")
        self.settled()
        self.check("repair cannot fake activated",self.state("host().state")=="awaitingActivation" and not self.state("host().receipts.some(r=>r.current)"))
        self.act("detect-host")
        self.settled()
        self.check("detect no fabricated receipt",not self.state("host().receipts.some(r=>r.current)"))

    def C29(self):
        self.scene("hostReady")
        self.check("Codex interruption unsupported",not self.state("capability(host(),2).supported"))
        self.check("Codex binding identity matches source",self.state("hostBindings(host(),2)[0].id")=="codex:none:stop_failure:codex.stop_failure_unavailable:v1")
        self.check("Codex binding retains catalog implementation fact",self.state("hostBindings(host(),2)[0].implemented"))
        self.page.evaluate("S.selectedHost='workbuddy';render();")
        self.check("WorkBuddy supported not implemented",self.state("capability(host(),2).supported") and not self.state("capability(host(),2).implemented"))
        self.fresh(page="integrations")
        self.act("host-detail")
        self.act("receipt-history")
        self.contains("旧代次","#sheet")
        self.act("sheet-cancel")
        before=self.state("S.hosts[0].receipts")
        self.act("clear-receipts")
        self.confirm()
        self.check("clear only selected surface receipts",self.state("host().receipts")==[] and self.state("S.hosts[0].receipts")==before)
        self.page.evaluate("S.selectedHost='claude-code';render();")
        self.check("Claude notification bindings separately reachable",self.page.locator("#binding-claude-notification").count()==1 and self.page.locator("#binding-claude-question").count()==1)
        self.page.evaluate("host().receipts=[{event:3,current:true,time:'18:30',result:'played',nativeEvent:'Notification',bindingID:'claude-code:Notification:notification:none:v1',installationID:host().installationID}];render();")
        self.check("one receipt cannot confirm both native bindings",self.state("bindingCurrent(host(),hostBindings(host(),3)[0])") and not self.state("bindingCurrent(host(),hostBindings(host(),3)[1])"))
        self.page.evaluate("host().receipts[0].installationID='old-installation';render();")
        self.check("old installation does not activate binding",not self.state("bindingCurrent(host(),hostBindings(host(),3)[0])"))

    def C30(self):
        self.scene("receiverFailure")
        self.contains("RECEIVER_BIND_FAILED")
        pending=self.state("S.pending")
        self.page.locator('[data-control="notifications"]').uncheck()
        self.check("banner preference does not remove reminders",self.state("S.pending")==pending)
        self.scene("receiverDisabled")
        self.contains("当前停用")

    def C31(self):
        self.fresh(page="notifications")
        scopes=self.state("S.scopes")
        self.page.locator('[data-control="focusQuiet"]').check()
        self.act("permission-allow")
        self.check("Focus independent authorization",self.state("S.focusAuth")=="authorized" and self.state("S.calendarAuth")=="notRequested")
        self.page.locator('[data-control="calendarQuiet"]').check()
        self.act("permission-deny")
        self.check("Calendar independent denial",self.state("S.calendarAuth")=="denied" and self.state("S.scopes")==scopes)
        self.act("open-calendar-settings")
        self.contains("Calendar privacy")
        self.scene("quiet-focusAndCalendarBusy")
        self.page.locator('[data-control="calendarQuiet"]').uncheck()
        self.check("Focus observation survives Calendar policy off",self.state("S.quietReason")=="focusActive")
        self.scene("quiet-focusAndCalendarBusy")
        self.page.locator('[data-control="focusQuiet"]').uncheck()
        self.check("Calendar observation survives Focus policy off",self.state("S.quietReason")=="calendarBusy")

    def C32(self):
        reasons=self.state("Object.keys(quietNames)")
        health=self.state("Object.keys(healthNames)")
        for reason in reasons:
            self.scene("quiet-"+reason)
            self.check("quiet reason "+reason,self.state("S.quietReason")==reason)
            self.check("reason visible",bool(self.page.locator("#quiet-status").inner_text()))
        for state in health:
            self.scene("health-"+state)
            self.check("snapshot health "+state,self.state("S.quietHealth")==state)
        self.contains("不能继续静音")

    def C33(self):
        self.fresh(page="general")
        self.select("language","en")
        self.check("English whole shell",self.page.locator('[data-action="nav:shortcuts"]').inner_text()=="Keyboard shortcuts")
        self.act("nav:sounds")
        self.contains("Current management scope")
        self.act("pack-options")
        self.contains("Sound pack options","#sheet")
        self.contains("Cancel","#sheet")
        self.act("sheet-cancel")
        self.act("nav:general")
        self.select("language","zh")
        self.contains("登录时打开")
        self.scene("systemEnglish")
        self.contains("resolved to English")
        self.check("resolved system language",self.page.locator("html").get_attribute("lang")=="en")

    def C34(self):
        for state in ["enabled","disabled","requiresApproval","unavailable"]:
            self.scene("login-"+state)
            self.check("login four states "+state,self.state("S.login")==state)
        self.check("unavailable toggle disabled",self.page.locator('[data-control="login"]').is_disabled())
        self.scene("loginFailure")
        self.page.locator('[data-control="login"]').click()
        self.settled()
        self.check("failure retains observed system state",self.state("S.login")=="enabled")
        self.act("retry-login")
        self.settled()
        self.check("retry repeats intended state",self.state("S.login")=="disabled")
        self.scene("platformFailure")
        self.act("open-login-settings")
        self.contains("打开失败")

    def C35(self):
        self.scene("preferenceCorrupt")
        self.contains("已采用安全默认")
        self.check("recovery visible",self.page.locator("#preference-recovery").count()==1)
        self.select("language","en")
        self.act("nav:integrations")
        self.act("select-host:claude-code")
        self.check("explicit preferences repair corrupt saved values",self.state("S.preferenceIssues")==[])

    def C36(self):
        self.fresh(page="shortcuts")
        for i in range(3):
            old=self.state(f"S.keys[{i}]")
            self.act(f"record-key:{i}")
            self.page.keyboard.press("Escape")
            self.check("cancel recorded shortcut unchanged",self.state(f"S.keys[{i}]")==old)
        self.act("record-key:2")
        self.page.keyboard.press("Control+Alt+K")
        self.check("record succeeded",self.state("S.keys[2]")=="⌃ ⌥ K")
        self.act("clear-key:2")
        self.check("clear succeeded",self.state("S.keys[2]") is None)

    def C37(self):
        self.fresh(page="shortcuts")
        self.act("record-key:2")
        self.page.keyboard.press("K")
        self.contains("Command 或 Control","#sheet")
        self.page.locator("#sheet").dispatch_event("keydown",{"key":" ","code":"Space","metaKey":True})
        self.contains("系统保留组合","#sheet")
        self.page.keyboard.press("Control+Alt+C")
        self.contains("重复","#sheet")
        self.act("sheet-cancel")
        for error in ["invalidStoredValue","registrationFailed","unregisterFailed","persistenceFailed","persistenceCleanupFailed","rollbackFailed","conflict","validation"]:
            self.scene("shortcut-"+error)
            self.check("shortcut failure explicit "+error,self.state("S.keyErrors[0]")==error)
            self.check("failure message visible",bool(self.page.locator("#shortcut-error-0 small").inner_text()))
        self.scene("shortcut-rollbackFailed")
        self.check("rollback failure not registered",not self.state("S.keyRegistered[0]"))
        self.scene("shortcut-invalidStoredValue")
        self.act("clear-key:0")
        self.check("damaged saved shortcut can recover",self.state("S.keyErrors[0]") is None)
        self.act("record-key:0")
        self.page.keyboard.press("Control+Alt+K")
        self.check("damaged shortcut rerecord succeeds",self.state("S.keys[0]")=="⌃ ⌥ K" and self.state("S.keyRegistered[0]"))
        for code,glyph in [("Numpad1","⌨1"),("NumpadEnter","⌨↩"),("NumpadComma","⌨,"),("IntlBackslash","§"),("IntlYen","¥"),("IntlRo","_"),("Lang1","かな"),("Lang2","英数")]:
            self.fresh(page="shortcuts")
            self.act("record-key:2")
            self.page.locator("#sheet").dispatch_event("keydown",{"key":glyph,"code":code,"ctrlKey":True})
            self.check("supported native physical key "+code,self.state("S.keys[2]")=="⌃ "+glyph)

    def C38(self):
        self.fresh(page="usage")
        text=self.page.locator("#activity-summary").inner_text()
        self.check("three projected summaries",all(n in text for n in ["114","629","186"]))
        self.check("five event counts",self.page.locator("#event-counts .row").count()==5)
        self.check("source details stable anchor exists",self.page.locator("#source-counts .row").count()==3)
        self.check("no daily chart or log count",self.page.locator(".chart,.chart-bars").count()==0 and "条诊断记录" not in self.page.locator("#page-content").inner_text())

    def C39(self):
        for state in ["ready","empty","unobserved","unavailable","stale","partial"]:
            self.scene("activity-"+state)
            self.check("six activity states "+state,self.state("S.activity")==state)
        self.scene("activityRefreshFailure")
        before=self.state("S.counts")
        self.act("refresh-activity")
        self.settled()
        self.check("failed refresh retains successful data",self.state("S.counts")==before and self.state("S.activity")=="stale")
        self.act("retry-last")
        self.settled()
        self.check("refresh recovery",self.state("S.activity")=="ready")

    def C40(self):
        for state in ["missing","damaged","unreadable"]:
            self.scene("log-"+state)
            self.check("log state visible "+state,bool(self.page.locator("#log-status").inner_text()))
        self.fresh(page="usage")
        self.page.evaluate("S.log.failures=Array.from({length:7},(_,i)=>({event:2,code:'PLAYBACK_FAILED',time:'18:21:00'}));")
        self.act("view-log")
        self.check("five summaries maximum",self.page.locator("#sheet .group .row").count()==5)
        self.act("sheet-cancel")
        self.act("copy-log-path")
        self.check("copied displayed log path",self.page.evaluate("navigator.clipboard.readText()")==self.state("S.log.path"))
        self.act("reveal-log")
        self.contains("~/.claudio/claudio.log")

    def C41(self):
        self.fresh(page="usage")
        self.act("toggle-pending")
        self.page.evaluate("S.pending.push({...structuredClone(S.pending[0]),id:'new-reminder'});render();")
        self.check("new reminder does not mutate reading set",len(self.state("S.reading"))==2)
        self.act("refresh-reminders")
        self.check("explicit refresh updates reading set",len(self.state("S.reading"))==3)
        self.scene("reminderStale")
        self.act("notice:demo-1")
        self.act("copy-session")
        self.contains("旧版提醒拒绝操作","#sheet")
        self.scene("reminderExpired")
        self.act("notice:demo-1")
        self.contains("已清空","#sheet")
        self.check("expired source erased",self.page.locator("#session-id").count()==0 and "Codex" not in self.page.locator("#sheet").inner_text())

    def C42(self):
        self.fresh(page="usage")
        self.act("toggle-pending")
        self.act("notice:demo-1")
        self.act("copy-session")
        self.check("valid session copied",self.page.evaluate("navigator.clipboard.readText()")=="demo-codex-session-01")
        self.act("sheet-cancel")
        for scene,fragment in [("sourceFailure","来源应用不可用"),("sourceTimeout","打开来源超时")]:
            self.scene(scene)
            self.act("notice:demo-1")
            self.act("open-source")
            self.page.wait_for_function("document.querySelector('#sheet-error').textContent.includes('提醒保留')")
            self.contains(fragment,"#sheet")
            self.check("failed source open retains reminder",len(self.state("S.pending"))==2)
        self.scene("reminderNoSession")
        self.act("notice:demo-1")
        self.check("invalid session cannot copy",self.page.locator('[data-action="copy-session"]').is_disabled())

    def C43(self):
        self.fresh(page="usage")
        receipts=self.state("S.hosts")
        reminders=self.state("S.pending")
        counts=self.state("S.counts")
        self.act("clear-log")
        self.confirm()
        self.check("successful log clear reports missing file",self.state("S.log.state")=="missing")
        self.check("log clear independent",self.state("S.counts")==counts and self.state("S.pending")==reminders and self.state("S.hosts")==receipts and self.state("S.log.bytes")==0)
        self.act("clear-counts")
        self.confirm()
        self.check("count clear independent partial",self.state("S.activity")=="partial" and self.state("S.pending")==reminders and self.state("S.hosts")==receipts and self.state("S.log.bytes")==0)
        self.act("toggle-pending")
        self.act("notice:demo-1")
        self.act("remove-reminder")
        self.check("removal changes only reminder",len(self.state("S.pending"))==1 and self.state("S.hosts")==receipts and self.state("S.log.bytes")==0)
        for scene,act,key in [("logClearFailure","clear-log","S.log.bytes"),("countClearFailure","clear-counts","S.counts")]:
            self.scene(scene)
            old=self.state(key)
            self.act(act)
            self.confirm()
            self.check("failed clear retains exact records",self.state(key)==old)

    def C44(self):
        self.scene("aboutUnknown")
        self.check("five unknown facts visible",self.page.locator("#version-facts").inner_text().count("未知")==5)
        self.act("copy-version")
        self.check("version copy reflects displayed unknowns","未知" in self.page.evaluate("navigator.clipboard.readText()"))

    def C45(self):
        self.fresh(page="about")
        for resource in ["license","attribution","privacy"]:
            self.act("open-resource:"+resource)
            self.check("three independent resource actions",self.page.locator("#sheet").evaluate("e=>e.open"))
            self.act("sheet-cancel")
        self.scene("resourceMissing")
        self.check("missing resources disabled",all(self.page.locator('[data-action="open-resource:'+r+'"]').is_disabled() for r in ["license","attribution","privacy"]))
        self.scene("resourceFailure")
        self.act("open-resource:privacy")
        self.contains("打开失败")

    def C46(self):
        self.fresh(page="about")
        shown=self.page.locator("#diagnostic-preview").input_value()
        self.check("diagnostics displayed selectable before copy",self.page.locator("#diagnostic-preview").is_visible() and self.page.locator("#diagnostic-preview").get_attribute("readonly") is not None)
        self.act("copy-diagnostics")
        self.check("copies identical displayed snapshot",self.page.evaluate("navigator.clipboard.readText()")==shown)
        self.check("summary has no path secret or hardcoded receiver claim","~/" not in shown and "Receiver: healthy" not in shown)
        self.scene("clipboardFailure")
        self.act("copy-version")
        self.contains("复制失败")
        self.act("copy-diagnostics")
        self.contains("复制失败")

    def C47(self):
        self.fresh(page="sounds")
        self.page.locator('[data-action="nav:about"]').focus()
        self.page.keyboard.press("Tab")
        self.check("Tab enters current page at management scope",self.page.evaluate("document.activeElement.dataset.control")=="management-scope")
        self.page.keyboard.press("Tab")
        self.check("Tab skips disabled apply and reaches viewed pack",self.page.evaluate("document.activeElement.dataset.control")=="pack")
        self.page.keyboard.press("Tab")
        self.check("Tab reaches pack options after viewed pack",self.page.evaluate("document.activeElement.dataset.action")=="pack-options")
        self.act("pack-options")
        self.page.keyboard.press("Escape")
        self.check("cancel focus returns to trigger",self.page.evaluate("document.activeElement.dataset.action")=="pack-options")
        self.page.locator('[data-action="nav:events"]').focus()
        self.page.keyboard.press("ArrowDown")
        self.check("sidebar keyboard selection focus",self.state("S.page")=="sounds" and self.page.evaluate("document.activeElement.dataset.action")=="nav:sounds")
        self.act("pack-options")
        self.page.evaluate("S.packs=[];S.pack=null;render();")
        self.act("sheet-cancel")
        self.check("disappeared trigger falls back visible reason/title",self.page.evaluate("document.activeElement.id") in ["target-unavailable","operation-feedback","page-title"])
        self.page.keyboard.press("Tab")
        self.check("Tab moves to enabled focusable control",self.page.evaluate("document.activeElement.tagName!=='BODY' && !document.activeElement.disabled"))
        self.scene("credentialPending",lang="en",theme="dark",size="minimum")
        self.act("credential")
        self.check("credential actions fit buttons",self.page.locator("#sheet .actions button").evaluate_all("es=>es.every(e=>e.scrollWidth<=e.clientWidth+1)"))
        self.scene("draft",lang="en",theme="dark",size="minimum")
        self.act("system-sound")
        self.check("new long sheet begins with visible title",self.page.locator("#sheet").evaluate("e=>e.querySelector('h2').getBoundingClientRect().top>=e.getBoundingClientRect().top"))

    def C48(self):
        self.scene("partial")
        self.act("generate")
        self.act("nav:general")
        self.page.wait_for_timeout(1200)
        self.check("late generation cannot mutate new page",self.state("S.candidates")==[] and self.state("S.generation") is None and self.state("S.page")=="general")
        self.scene("draft")
        self.act("window-close") if self.page.locator('[data-action="window-close"]').count() else self.page.locator("#window-close").click()
        self.check("closing clears empty draft candidates audio",self.state("S.draft") is None and self.state("S.candidates")==[] and self.state("prototypeReview.getPlaying()")==0)
        self.act("reopen-window")
        self.check("reopen no empty installed pack",len(self.state("S.packs"))==7)
        self.scene("credentialRejected")
        self.act("credential")
        self.act("check-credential")
        self.check("credential checking disables conflicting actions", all(self.page.locator('[data-action="'+a+'"]').is_disabled() for a in ["save-credential","delete-credential"]))
        self.page.evaluate("closeWindow()")
        self.act("reopen-window")
        self.page.wait_for_timeout(550)
        self.check("closing credential check restores stable status",self.state("S.credentials['elevenlabs-global'].status")=="rejected")
        self.scene("credentialRejected")
        self.act("credential")
        self.act("check-credential")
        self.act("sheet-cancel")
        self.page.evaluate("setScene('normal')")
        self.page.wait_for_timeout(550)
        self.check("late credential check cannot overwrite reset",self.state("S.credentials['elevenlabs-global'].status")=="verified")
        self.scene("sourceFailure")
        self.act("notice:demo-1")
        self.act("open-source")
        self.act("sheet-cancel")
        self.act("view-log")
        self.page.wait_for_timeout(650)
        self.check("late source result cannot pollute new sheet",self.page.locator("#sheet-error").inner_text()=="")

    def run_cases(self,names=None):
        for i in range(1,49):
            if names and f"C{i:02}" not in names:
                continue
            name=f"C{i:02}"
            self.case=name
            start=len(self.checks)
            try:
                self.fresh()
                getattr(self,name)()
                self.cases.append({"id":name,"passed":True,"assertions":len(self.checks)-start})
            except Exception as e:
                self.cases.append({"id":name,"passed":False,"assertions":len(self.checks)-start,"error":str(e),"trace":traceback.format_exc()})
                self.failure_screenshot(name+"-failure.png")
                print(f"FAIL {name}: {e}",flush=True)
            else:
                print(f"PASS {name}",flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts",type=Path)
    parser.add_argument("--expected-sha")
    parser.add_argument("--cases-only",action="store_true")
    parser.add_argument("--details-only",action="store_true")
    parser.add_argument("--skip-details",action="store_true",help="Run page layouts and C01–C48; pair with --details-only for complete evidence")
    parser.add_argument("--case",action="append",choices=[f"C{i:02}" for i in range(1,49)])
    args=parser.parse_args()
    if args.details_only and (args.skip_details or args.cases_only):
        parser.error("--details-only cannot be combined with --skip-details or --cases-only")
    sha=hashlib.sha256(HTML.read_bytes()).hexdigest()
    if args.expected_sha and args.expected_sha!=sha:
        raise SystemExit(f"HTML SHA mismatch: {sha}")
    artifacts=args.artifacts or Path(tempfile.mkdtemp(prefix="claudio-macos-settings-"))
    artifacts.mkdir(parents=True,exist_ok=True)
    with sync_playwright() as pw:
        launch_browser=lambda:pw.chromium.launch(channel="chrome",headless=True)
        browser=launch_browser()
        regression=Regression(browser,artifacts,launch_browser)
        layout_error=None
        if not args.cases_only:
            try:
                if not args.details_only:
                    regression.all_layouts()
                if not args.skip_details:
                    regression.all_detail_layouts()
            except Exception as e:
                layout_error=traceback.format_exc()
                print(f"FAIL {regression.case}: {e}",flush=True)
                regression.failure_screenshot("layout-failure.png")
        if not args.details_only:
            regression.run_cases(args.case)
        changed=hashlib.sha256(HTML.read_bytes()).hexdigest()!=sha
        failed=layout_error or any(not c["passed"] for c in regression.cases) or regression.errors or regression.runner_errors or regression.requests or changed
        report={"html_sha256":sha,"source_baseline":"7ca63a4af0497b74b53e89225ccf4de30d900c12","passed":not bool(failed),
            "requested_scope":{"page_layouts":not args.cases_only and not args.details_only,"detail_layouts":not args.cases_only and not args.skip_details,"capability_cases":not args.details_only},
            "layout_combinations":len(regression.layouts),"state_layouts":len(regression.state_layouts),"cases":regression.cases,"detail_layouts":regression.detail_layouts,"operation_layouts":regression.operation_layouts,
            "assertions":regression.checks,"layouts":regression.layouts,"state_layout_samples":regression.state_layouts,
            "page_errors":regression.errors,"runner_errors":regression.runner_errors,"network_requests":regression.requests,"html_changed_during_run":changed,"layout_error":layout_error,
            "evidence_boundary":"Offline browser only; no native layout, VoiceOver, actual audio, permissions, host callbacks, Provider, release, or formal acceptance."}
        (artifacts/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
        print(json.dumps({"passed":report["passed"],"html_sha256":sha,"layouts":len(regression.layouts),"state_layouts":len(regression.state_layouts),
            "detail_layouts":len(regression.detail_layouts),"operation_layouts":len(regression.operation_layouts),"cases_passed":sum(c["passed"] for c in regression.cases),"assertions":len(regression.checks),"page_errors":len(regression.errors),"artifacts":str(artifacts)},ensure_ascii=False),flush=True)
        if regression.browser.is_connected():
            regression.browser.close()
    return 1 if failed else 0


if __name__=="__main__":
    raise SystemExit(main())
