import ClaudioCore
import ClaudioGUICore
import ClaudioSettingsPresentation
import Foundation

@MainActor
func runSettingsNavigationHistorySuites() async {
    suite("Settings history: cross-page traversal, repeat, branch and close") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.notifications))
        let session = fixture.session
        session.send(.route(.notifications(.eventAnimation)))
        session.send(.selectSidebar(.general))
        expect(session.navigationHistory.entries.count == 3, "A → detail → B has three positions")
        session.send(.goBack)
        expect(
            session.state.routeResolution.route == .notifications(.eventAnimation),
            "Back restores actual detail")
        session.send(.goBack)
        expect(
            session.state.routeResolution.route == .destination(.notifications),
            "Second Back restores A")
        session.send(.route(.destination(.notifications)))
        expect(
            session.navigationHistory.entries.count == 3 && session.state.chrome.canGoForward,
            "Repeating the current position preserves Forward")
        session.send(.goForward)
        expect(
            session.state.routeResolution.route == .notifications(.eventAnimation),
            "Forward restores detail")
        session.send(.selectSidebar(.about))
        expect(
            !session.state.chrome.canGoForward && session.navigationHistory.entries.count == 3,
            "A new position truncates the forward branch")
        expect(fixture.actionRecorder.actions.isEmpty, "Traversal performs no platform effects")
        session.send(.windowWillClose)
        expect(
            session.navigationHistory.entries.isEmpty && session.state.navigationRestoration == nil,
            "Close erases all window-lifetime positions and reading requests")
        session.send(.present(.route(nil)))
        expect(
            session.navigationHistory.entries.count == 1 && !session.state.chrome.canGoBack,
            "Reopen starts at the last top-level preference without old history")
    }

    suite("Settings history: bounded capacity, bookmarks and operation stamps") {
        var history = SettingsNavigationHistory()
        for index in 0..<70 {
            history.visit(
                .init(
                    route: .events(
                        scope: .workspace(UUID()),
                        event: index.isMultiple(of: 2) ? .stop : .taskStart)))
        }
        expect(
            history.entries.count == 64 && history.cursor == 63,
            "The newest 64 browsing positions survive")
        let oldStamp = history.stamp!
        let bookmark = SettingsReadingBookmark(
            focusIdentifier: "workspace.event.stop.edit",
            scrollAnchorIdentifier: "workspace-event-stop", anchorOffset: 17,
            relativeScrollPosition: 0.7)
        history.updateBookmark(bookmark, stamp: oldStamp)
        let expected = history.current!
        _ = history.move(by: -1)
        history.updateBookmark(.init(focusIdentifier: "late-result"), stamp: oldStamp)
        expect(
            history.current?.bookmark.focusIdentifier != "late-result",
            "Old reading debt cannot overwrite a newer visit")
        _ = history.move(by: 1)
        expect(
            history.current?.bookmark == bookmark,
            "Forward retains semantic anchor and relative position")
        expect(
            !history.replaceCurrent(.init(route: .destination(.general)), matching: oldStamp),
            "Leaving and returning to the same entry invalidates an old operation result")
        expect(
            history.current?.id == expected.id,
            "Traversal retains entry identity while advancing navigation version")
        let count = history.entries.count
        history.replaceCurrent(.init(route: .destination(.about)), matching: history.stamp)
        expect(
            history.entries.count == count,
            "A current operation replaces a position without an extra visit")
    }

    suite("Settings history: stale target identities fail closed") {
        let rule = WorkspaceSoundRule(
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/original"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "pack", volume: 0.7))
        let target = WorkspaceSoundWriteTarget(rule: rule)
        let route = EventSettingsWindowRoute(
            scope: .workspace(rule.id), workspaceTarget: target, detail: .scope(target))
        let availability = SettingsRouteAvailability(
            integrationSurfaces: [], eventScopes: [.global, .workspace(rule.id)],
            soundScopes: [.global, .workspace(rule.id)], soundPackIDs: ["pack"],
            events: Set(Event.allCases))
        let location = SettingsLocation(
            route: .events(scope: route.scope, event: nil), workspaceRoute: route)
        var config = ClaudioConfig(selectedPack: "pack")
        config.workspaceRules = [rule]
        expect(
            location.resolve(availability: availability, config: config).failure == nil,
            "Captured directory is current")
        let rebound = WorkspaceSoundRule(
            id: rule.id,
            directory: WorkspaceDirectory(kind: .directory, path: "/fixture/rebound"),
            surfaces: [.codex],
            profile: WorkspaceSoundProfile(selectedPack: "pack", volume: 0.7))
        var reboundConfig = config
        reboundConfig.workspaceRules = [rebound]
        expect(
            location.resolve(
                availability: availability,
                config: reboundConfig
            ).failure == .staleSoundScope(route.scope),
            "Rebinding a UUID cannot restore a writable replacement directory")
        expect(
            location.resolve(
                availability: availability, config: ClaudioConfig(selectedPack: "pack")
            ).failure != nil,
            "Deletion retains the unavailable identity")
        let pack = SettingsLocation(route: .destination(.sounds), viewedPackID: "deleted")
        expect(
            pack.resolve(availability: availability, config: config).failure
                == .staleSoundPack("deleted"),
            "An overview's captured viewed pack cannot silently fall back to another pack")
    }

    suite("Settings history: malformed input and modal navigation") {
        let fixture = SettingsPresentationFixtures.generalLogin()
        let session = fixture.session
        let before = session.navigationHistory
        let bad = session.send(.route(.sounds(.editEvent(packID: "", event: .stop))))
        expect(
            bad == .rejected(.invalidSoundPackID) && session.navigationHistory == before,
            "Unparseable navigation is rejected without becoming a position")
        session.send(.selectSidebar(.about))
        let cursor = session.navigationHistory.cursor
        session.send(.setNavigationBlocked(id: "sheet", blocked: true))
        expect(
            !session.state.chrome.navigationEnabled && !session.state.chrome.canGoBack,
            "Modal state disables all chrome navigation")
        expect(
            session.send(.goBack) == .unchanged
                && session.send(.selectSidebar(.general)) == .unchanged,
            "Modal state rejects toolbar and sidebar intents")
        session.send(.setNavigationBlocked(id: "sheet", blocked: false))
        expect(
            session.navigationHistory.cursor == cursor && session.state.chrome.canGoBack,
            "Cancel does not move the history cursor")
        let old = session.state.navigationRestoration!.stamp
        session.send(.selectSidebar(.shortcuts))
        expect(
            session.send(.acknowledgeRestoration(old)) == .unchanged,
            "Shell and destination cannot consume a newer navigation's restoration with an old version"
        )
    }

    await suite("Settings history: pending resolution and viewed pack use current configuration") {
        await withTempDirectory { root in
            let editor = makeSoundEditorFixture(
                root: root, packIDs: ["pack-a", "pack-b"],
                config: ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.3))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.editEvent(packID: "pack-b", event: .stop)),
                soundPacksEditor: editor.owner)
            let session = fixture.session
            let initialEntry = session.navigationHistory.current!.id
            await waitForSoundEditorReady(editor.owner, library: editor.library)
            for _ in 0..<512
            where session.state.soundsDetail != .event(packID: "pack-b", event: .stop) {
                await Task.yield()
            }
            expect(
                session.state.soundsDetail == .event(packID: "pack-b", event: .stop)
                    && session.navigationHistory.entries.count == 1
                    && session.navigationHistory.current?.id == initialEntry,
                "Initial pending completion resolves in place with one history identity")
            session.send(.goBack)
            expect(!session.state.chrome.canGoBack, "Pending hydration creates no extra Back step")
            session.send(.selectSidebar(.general))
            var newest = ClaudioConfig(selectedPack: "pack-a")
            newest.masterVolume = 0.85
            let bytes = try! JSONEncoder().encode(newest)
            writeFixture(bytes, to: editor.configFile)
            session.send(.goBack)
            await waitForSoundEditorReady(editor.owner, library: editor.library)
            expect(
                session.state.soundsDetail == .event(packID: "pack-b", event: .stop)
                    && session.navigationHistory.current?.location.viewedPackID == "pack-b"
                    && (try? Data(contentsOf: editor.configFile)) == bytes,
                "Back restores viewing B without replaying old configuration: route=\(session.state.routeResolution), detail=\(session.state.soundsDetail), location=\(session.navigationHistory.current!.location), bytesUnchanged=\((try? Data(contentsOf: editor.configFile)) == bytes)"
            )
            session.send(.route(.sounds(.editEvent(packID: "pack-b", event: .stop))))
            expect(
                session.navigationHistory.entries.count == 2 && session.state.chrome.canGoForward,
                "A repeated deep link preserves Forward: count=\(session.navigationHistory.entries.count), chrome=\(session.state.chrome)"
            )
            session.send(.windowWillClose)
        }
    }

    await suite("Settings history: restoring a refreshed overview retains its viewed pack") {
        await withTempDirectory { root in
            let editor = makeSoundEditorFixture(
                root: root, packIDs: ["pack-a", "pack-b"],
                config: ClaudioConfig(selectedPack: "pack-a"))
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview), soundPacksEditor: editor.owner)
            let session = fixture.session
            await waitForSoundEditorReady(editor.owner, library: editor.library)
            expect(
                session.send(.inspectSoundPack("pack-b")) == .routed,
                "The overview explicitly inspects B while the Default Group continues using A")
            guard case .sounds(let inspected) = editor.owner.presentation.mode else {
                expect(false, "Inspection must retain the Sounds presentation")
                return
            }
            expect(
                inspected.selectedPack?.id == "pack-b"
                    && session.navigationHistory.current?.location.viewedPackID == "pack-b",
                "The visible overview and history capture B before any refresh")
            let entryID = session.navigationHistory.current!.id
            let entryCount = session.navigationHistory.entries.count
            let configBefore = try! Data(contentsOf: editor.configFile)
            let packDirectory = root.appendingPathComponent("packs/pack-b")
            let removedDirectory = root.appendingPathComponent("removed-pack-b")
            try! FileManager.default.moveItem(at: packDirectory, to: removedDirectory)
            _ = await editor.library.refreshSnapshot(trigger: .retry)
            for _ in 0..<512 where session.state.routeResolution.failure == nil {
                await Task.yield()
            }
            expect(
                session.state.routeResolution.failure == .staleSoundPack("pack-b")
                    && session.navigationHistory.current?.id == entryID
                    && session.navigationHistory.current?.location.viewedPackID == "pack-b"
                    && editor.owner.presentation.mode == .inactive,
                "A missing viewed pack becomes unavailable without adopting the owner's fallback")
            expect(
                (try? Data(contentsOf: editor.configFile)) == configBefore,
                "Refresh removal must preserve the Default Group's configuration bytes")

            try! FileManager.default.moveItem(at: removedDirectory, to: packDirectory)
            _ = await editor.library.refreshSnapshot(trigger: .retry)
            for _ in 0..<512 {
                if session.state.routeResolution.failure == nil,
                    editor.owner.presentation.library.isFresh,
                    case .sounds(let sounds) = editor.owner.presentation.mode,
                    sounds.packs.contains(where: { $0.id == "pack-b" })
                {
                    break
                }
                await Task.yield()
            }
            guard case .sounds(let restored) = editor.owner.presentation.mode else {
                expect(false, "Restoring the captured pack must reactivate the overview")
                return
            }
            expect(
                session.state.routeResolution.failure == nil
                    && editor.owner.presentation.library.isFresh
                    && session.state.soundsDetail == .overview
                    && restored.selectedPack?.id == "pack-b"
                    && session.navigationHistory.current?.location.viewedPackID == "pack-b"
                    && session.navigationHistory.current?.id == entryID
                    && session.navigationHistory.entries.count == entryCount,
                "Refresh recovery restores captured B in place; it cannot turn fallback A into a browsing choice: selected=\(restored.selectedPack?.id ?? "nil"), location=\(session.navigationHistory.current!.location)"
            )
            expect(
                (try? Data(contentsOf: editor.configFile)) == configBefore,
                "Restoring viewing B must not apply it to the Default Group or replay a write")
            session.send(.windowWillClose)
        }
    }

    await suite("Settings history: a newer inspection cancels a pending viewed pack recovery") {
        await withTempDirectory { root in
            let gate = SettingsViewedPackRecoveryPublicationGate()
            defer { gate.release() }
            let editor = makeSoundEditorFixture(
                root: root, packIDs: ["pack-a", "pack-b", "pack-c"],
                config: ClaudioConfig(selectedPack: "pack-a"),
                beforeReadyPublication: { gate.pauseNextPublication() })
            let fixture = SettingsPresentationFixtures.generalLogin(
                route: .sounds(.overview), soundPacksEditor: editor.owner)
            let session = fixture.session
            await waitForSoundEditorReady(editor.owner, library: editor.library)
            session.send(.inspectSoundPack("pack-b"))
            let configBefore = try! Data(contentsOf: editor.configFile)
            let packDirectory = root.appendingPathComponent("packs/pack-b")
            let removedDirectory = root.appendingPathComponent("removed-pack-b")
            try! FileManager.default.moveItem(at: packDirectory, to: removedDirectory)
            _ = await editor.library.refreshSnapshot(trigger: .retry)
            for _ in 0..<512 where session.state.routeResolution.failure == nil {
                await Task.yield()
            }
            expect(
                session.state.routeResolution.failure == .staleSoundPack("pack-b"),
                "B must become unavailable before its recovery can be pending")

            try! FileManager.default.moveItem(at: removedDirectory, to: packDirectory)
            gate.arm()
            let library = editor.library
            let refresh = Task.detached { await library.refreshSnapshot(trigger: .retry) }
            expect(
                gate.waitUntilPaused(), "The recovered B snapshot pauses before ready publication")
            for _ in 0..<512
            where session.state.routeResolution.failure != nil
                || editor.owner.presentation.mode == .inactive
            {
                await Task.yield()
            }
            expect(
                !editor.owner.presentation.library.isFresh
                    && session.navigationHistory.current?.location.viewedPackID == "pack-b",
                "Loading retains B while the fresh recovery capability is not yet published")
            expect(
                session.send(.inspectSoundPack("pack-c")) == .routed,
                "An explicit inspection of C supersedes the pending recovery of B")
            let newerStamp = session.navigationHistory.stamp
            gate.release()
            _ = await refresh.value
            for _ in 0..<512 where !editor.owner.presentation.library.isFresh {
                await Task.yield()
            }
            guard case .sounds(let restored) = editor.owner.presentation.mode else {
                expect(false, "The newer inspection must remain active after recovery")
                return
            }
            expect(
                editor.owner.presentation.library.isFresh
                    && restored.packs.contains(where: { $0.id == "pack-b" })
                    && restored.selectedPack?.id == "pack-c"
                    && session.navigationHistory.current?.location.viewedPackID == "pack-c"
                    && session.navigationHistory.stamp == newerStamp,
                "A late fresh B snapshot cannot override the newer C browsing identity")
            expect(
                (try? Data(contentsOf: editor.configFile)) == configBefore,
                "Neither deferred recovery nor the newer inspection writes Default Group settings")
            session.send(.windowWillClose)
        }
    }

    suite("Settings history: compatibility roots refer to the same visible position") {
        let fixture = SettingsPresentationFixtures.generalLogin(route: .destination(.sounds))
        let session = fixture.session
        session.send(.selectSidebar(.general))
        session.send(.goBack)
        let entryID = session.navigationHistory.current!.id
        session.send(.route(.sounds(.overview)))
        expect(
            session.navigationHistory.entries.count == 2 && session.state.chrome.canGoForward
                && session.navigationHistory.current?.id == entryID,
            "Generic Sounds and explicit global overview repeat the same visible position")
        let staleReady = session.state.navigationRestoration!.stamp
        session.send(.goForward)
        expect(
            session.send(.destinationReady(staleReady)) == .unchanged,
            "A late destination mount cannot authorize focus for a newer navigation")
    }
}

/// Holds the real library's terminal publication so a newer navigation can supersede recovery.
private final class SettingsViewedPackRecoveryPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private var armed = false

    func arm() { lock.lock(); armed = true; lock.unlock() }

    func pauseNextPublication() {
        lock.lock()
        let pauses = armed
        armed = false
        lock.unlock()
        guard pauses else { return }
        entered.signal()
        _ = resumed.wait(timeout: .now() + 5)
    }

    func waitUntilPaused() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func release() { resumed.signal() }
}
