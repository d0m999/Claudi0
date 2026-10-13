import ClaudioCore
import ClaudioSettingsPresentation
import Foundation

@testable import ClaudioGUICore

@MainActor
func runSettingsSoundsPublicationSuites() {
    suite("Sounds publication：复制只接受晚于上次最大状态版本的结果") {
        withTempDirectory { root in
            let seed = soundsPublicationSeed(root: root)
            for (revision, expected) in [(850, "pack-a"), (901, "pack-b")] {
                var arbitration = SettingsSoundsDetailArbitration()
                let oldStatuses = [
                    soundsPublicationStatus(revision: 900),
                    soundsPublicationStatus(revision: 100),
                ]
                arbitration.consume(soundsPublication(seed, statuses: oldStatuses))
                arbitration.consume(
                    soundsPublication(seed, statuses: oldStatuses, phase: .busy))
                arbitration.consume(
                    soundsPublication(
                        seed, statuses: [soundsPublicationStatus(revision: revision)],
                        phase: .succeeded))
                expect(
                    arbitration.detail == .pack(packID: expected),
                    "复制结果应比较之前所有状态的最大版本，不能比较最后一项或发布版本")
            }
        }
    }

    suite("Sounds publication：非 Sounds 发布清除先前草稿观察") {
        withTempDirectory { root in
            let seed = soundsPublicationSeed(root: root)
            let draft = AICuePackDraftPresentation(packID: "draft-a", name: "Draft A")
            var arbitration = SettingsSoundsDetailArbitration()
            arbitration.consume(soundsPublication(seed, draft: draft))
            expect(arbitration.detail == .draft(packID: "draft-a"), "首次草稿应进入其详情")
            arbitration.consume(
                SoundPacksEditorPresentation(
                    revision: 2, library: .ready, installedPackIDs: ["pack-a"], mode: .inactive,
                    activities: [], pendingConfirmation: nil, pendingAnnouncement: nil))
            arbitration.consume(soundsPublication(seed, requestRevision: 2, draft: draft))
            expect(
                arbitration.detail == .draft(packID: "draft-a"),
                "重新进入 Sounds 后，同 ID 草稿应作为本次发布的草稿重新观察")
        }
    }

    suite("Sounds publication：重置后的迟到复制结果不替换新详情") {
        withTempDirectory { root in
            let seed = soundsPublicationSeed(root: root)
            var arbitration = SettingsSoundsDetailArbitration()
            arbitration.consume(soundsPublication(seed))
            arbitration.consume(soundsPublication(seed, phase: .busy))
            arbitration.reset()
            arbitration.consume(soundsPublication(seed, requestRevision: 2))
            arbitration.consume(
                soundsPublication(
                    seed, requestRevision: 2,
                    statuses: [soundsPublicationStatus(revision: 901)], phase: .succeeded))
            expect(
                arbitration.detail == .pack(packID: "pack-a"),
                "新窗口期不继承旧复制的身份过渡资格")
        }
    }

    suite("Sound editor context：值相等继续包含完整目录目标及请求版本") {
        withTempDirectory { root in
            let profile = WorkspaceSoundProfile(selectedPack: "pack-a", volume: 0.5)
            let first = WorkspaceSoundRule(
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("a").path),
                surfaces: [.codex],
                profile: profile)
            let rebound = WorkspaceSoundRule(
                id: first.id,
                directory: WorkspaceDirectory(
                    kind: .directory, path: root.appendingPathComponent("b").path),
                surfaces: [.codex], profile: profile)
            let route = SoundPacksWindowRoute.copyAndApply(
                scope: .workspace(first.id), packID: "pack-a", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: first))
            let context = SoundPacksEditorContext.sounds(route: route, requestRevision: 7)
            expect(context == .sounds(route: route, requestRevision: 7), "独立构造的相同值应继续相等")
            expect(context != .sounds(route: route, requestRevision: 8), "请求版本仍属于完整身份")
            let reboundRoute = SoundPacksWindowRoute.copyAndApply(
                scope: .workspace(first.id), packID: "pack-a", event: .stop,
                workspaceTarget: WorkspaceSoundWriteTarget(rule: rebound))
            expect(context != .sounds(route: reboundRoute, requestRevision: 7), "同 UUID 换目录仍必须不相等")
        }
    }

    suite("Sound editor snapshot：保留的值与后续集合写入相互独立") {
        withTempDirectory { root in
            let seed = soundsPublicationSeed(root: root)
            let original = soundsPublication(seed)
            var changed = original
            changed.draftPackIDs.insert("later-draft")
            expect(original.draftPackIDs.isEmpty, "写新快照不得修改保留的旧快照")
            expect(changed != original, "值相等必须继续观察公开字段的不同")
            if case .sounds(let sounds) = original.mode {
                expect(sounds.selectedPack?.id == "pack-a", "旧快照继续保留原包事实")
            } else {
                expect(false, "原快照应保留 Sounds 模式")
            }
        }
    }
}

@MainActor
private func soundsPublicationSeed(root: URL) -> SoundsEditorPresentation {
    let owner = SoundPacksEditorOwner.stateGalleryFixture(
        previewConfig: ClaudioConfig(selectedPack: "pack-a", masterVolume: 0.4),
        packCards: [
            PackCard(
                id: "pack-a", name: "Pack A", isCC0: true, presentEvents: [],
                state: .partial(present: 0, total: Event.allCases.count), isSelected: true)
        ],
        selectedPackID: "pack-a", selectedEventRows: [],
        environment: makeAudioImportEnvironment(
            userPacksDirectory: root.appendingPathComponent("packs", isDirectory: true)),
        activation: .sounds(
            route: SoundPacksWindowRoute(scope: .global, destination: .pack(packID: "pack-a")),
            requestRevision: 1))
    guard case .sounds(let sounds) = owner.presentation.mode else {
        fatalError("Sounds fixture must produce Sounds presentation")
    }
    return sounds
}

private func soundsPublicationStatus(revision: Int) -> SoundPacksWindowStatus {
    SoundPacksWindowStatus(
        kind: .packFork, severity: .notice, revision: revision,
        action: "Copy", message: "Copied", packID: "pack-b")
}

private func soundsPublication(
    _ seed: SoundsEditorPresentation, requestRevision: UInt64 = 1,
    statuses: [SoundPacksWindowStatus] = [], phase: SoundPackEditorActivityPhase? = nil,
    draft: AICuePackDraftPresentation? = nil
) -> SoundPacksEditorPresentation {
    let sounds = SoundsEditorPresentation(
        route: seed.route, requestRevision: requestRevision, routeState: seed.routeState,
        scope: seed.scope, workspaceName: seed.workspaceName, masterVolume: seed.masterVolume,
        packs: seed.packs, selectedPack: seed.selectedPack, eventRows: seed.eventRows,
        draft: draft, inventory: seed.inventory, requestImportAction: seed.requestImportAction,
        stopPreviewAction: seed.stopPreviewAction, retryLibraryAction: seed.retryLibraryAction,
        restoreAllFactoryPacksAction: seed.restoreAllFactoryPacksAction,
        emptyLibraryRecovery: seed.emptyLibraryRecovery, windowStatuses: statuses,
        recoveryActions: seed.recoveryActions, manifestRecoveryActions: seed.manifestRecoveryActions
    )
    let activities =
        phase.map {
            [
                SoundPackEditorActivityPresentation(
                    operationID: SoundPackEditorOperationID(rawValue: 42), kind: .copy, phase: $0,
                    packID: "pack-a", event: nil, cancelAction: nil)
            ]
        } ?? []
    return SoundPacksEditorPresentation(
        revision: 1, library: .ready, installedPackIDs: ["pack-a", "pack-b"], mode: .sounds(sounds),
        activities: activities, pendingConfirmation: nil, pendingAnnouncement: nil)
}
