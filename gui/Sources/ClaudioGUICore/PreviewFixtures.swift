import ClaudioCore
import ClaudioLocalization
import Foundation

// This entire catalog is DEBUG-only: its only consumers are the DEBUG-gated state gallery
// (`ClaudioGUI/StateGalleryView.swift`) and the test harness, so it never belongs in a
// Release build — matching the `#if DEBUG` gating on the `previewState` view-model inits it
// renders through. Keeps this preview/test-only sample data off the shipped `ClaudioGUICore`
// public surface entirely rather than relying on the linker to dead-strip it (T14
// swift-review nit).
//
// The harness is NOT "always debug", despite what this comment used to claim: `claudio-gui-tests`
// is an `executableTarget` (this repo has no Xcode, hence no XCTest — see Package.swift), so a
// bare `swift build -c release` builds it too, and it does not compile without these symbols.
// That is why `Package.swift` declares an explicit `ClaudioGUI` product and release.yml builds
// `--product ClaudioGUI`. Verify with BOTH, never just the first:
//     swift run claudio-gui-tests                        # debug: the green signal
//     swift build -c release --product ClaudioGUI        # release: what CI actually ships
#if DEBUG

/// Shared DEBUG-only values for production galleries and regression suites.
/// assertExhaustive visits each maintained state family; exhaustive switches guard new cases.
public enum PreviewFixtures {

    // MARK: - Imported audio sample for the production editor gallery

    /// A representative imported file. The editor gallery reads its filename;
    /// the destination is a plausible sample path and is never accessed.
    public static let sampleImportedAudioFile = ImportedAudioFile(
        packID: "minimal-chime",
        destinationURL: URL(fileURLWithPath: "/Users/demo/.claudio/packs/minimal-chime/stop.mp3"),
        fileName: "stop.mp3",
        format: .mp3,
        fileSizeBytes: 214_016,
        duration: 1.2
    )

    // MARK: - EventRow / CoverageState (ENGINEERING.md T16 D2, DESIGN.md "事件行三态")

    /// Every ``CoverageState`` case × `enabled` (true/false) — six rows — AND every ``Event``,
    /// on both axes at once: the five events are ROTATED across the six coverage×enabled
    /// combinations (in ``Event/allCases`` declaration order), so the combination grid stays
    /// exhaustive while no event is left un-rendered.
    ///
    /// The event axis is load-bearing, not decoration (T14 review 修复①): this catalog is the
    /// repo's ONLY exhaustive visual truth source, and an event that never appears in it has
    /// its display name, its glyph, and its ``ClaudioColor/event(_:_:)`` tile color rendered
    /// exactly zero times — nobody has ever LOOKED at it. That is precisely how `night_dim`
    /// drifted before. `SubagentStop`'s indigo was missing here until this fix.
    ///
    /// Each row's event is visible in FULL color regardless of `enabled`/coverage
    /// (the event glyph never dims — DESIGN.md 硬约束 "不整行降 opacity"), so one
    /// appearance per event is genuinely enough to see its true color; the rotation doesn't
    /// need to also pair every event with every coverage state.
    ///
    /// ``PreviewFixturesSuite`` pins BOTH axes at runtime: the six coverage×enabled
    /// combinations, and `Set(eventRows.map(\.event)) == Set(Event.allCases)` — the latter
    /// driven straight off ``Event``'s compiler-synthesized `allCases`, so adding a fifth
    /// event turns that check red without anyone having to remember to update a hand-written
    /// list.
    public static let eventRows: [EventRow] = [
        EventRow(
            event: .taskStart, coverage: .present(fileName: "task-start.mp3"), enabled: true),
        EventRow(
            event: .stop, coverage: .present(fileName: "stop.mp3"), enabled: false),
        EventRow(event: .stopFailure, coverage: .unmapped, enabled: true),
        EventRow(event: .notification, coverage: .unmapped, enabled: false),
        EventRow(
            event: .subagentStop, coverage: .broken(fileName: "subagent-stop.mp3"), enabled: true),
        EventRow(event: .notification, coverage: .broken(fileName: "ping.mp3"), enabled: false),
    ]

    // MARK: - PackCard / PackCardState (ENGINEERING.md T15 D3)

    /// Every ``PackCardState`` case × `isSelected` (true/false) — six cards.
    ///
    /// The `presentEvents` sets carry a SECOND exhaustiveness obligation, for the same reason
    /// ``eventRows`` does (T14 review 修复①): the row's 5-slot coverage track
    /// (``PackGalleryView``, T4) renders ``Event/allCases`` for every card whose
    /// ``packRowTrailingSlot(for:)`` resolves to `.track`, styling each slot present-or-absent.
    /// So the fixtures whose state is `.complete`/`.partial` (the ones that actually reach a
    /// track) must show each of the five events in BOTH styles among THEMSELVES — the two
    /// `.broken` cards' `presentEvents == []` does NOT count toward this anymore (T4: a broken
    /// row renders a status row instead of a track, so its `presentEvents` is never turned into
    /// an actual absent-styled slot anywhere in the gallery — counting it here would be exactly
    /// the "asserted against data nobody renders" bug this file exists to prevent). The
    /// `.complete` cards (`presentEvents == Set(Event.allCases)`) supply all five PRESENT
    /// slots; the two `.partial` cards' present sets are chosen so their absent sets' UNION is
    /// all five events. ``PreviewFixturesSuite`` pins both halves, scoped to the `.track`-
    /// resolving cards, off ``Event/allCases`` directly.
    public static let packCards: [PackCard] = [
        PackCard(
            id: "minimal-chime", name: "极简铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: true),
        PackCard(
            id: "sunny-chime", name: "晴朗铃", isCC0: true, presentEvents: Set(Event.allCases),
            state: .complete, isSelected: false),
        PackCard(
            id: "half-pack", name: "半成品", isCC0: false,
            presentEvents: [.taskStart, .stop, .notification],
            state: .partial(present: 3, total: 5), isSelected: true),
        // `one-event-pack` 刻意只让 `.subagentStop` 在场：其缺失集
        // {taskStart, stop, stopFailure, notification} 与 `half-pack` 的缺失集
        // {stopFailure, subagentStop} 取并集，五个事件的「缺」才恰好全部覆盖到。
        // 两个都缺的正是 `stopFailure`/`subagentStop`，若这里仍选 `.stop` 在场，`.stop` 就永远
        // 不会在任何一张会画轨的卡片上以「缺失格」样式出现过。
        PackCard(
            id: "one-event-pack", name: "缺四个", isCC0: false, presentEvents: [.subagentStop],
            state: .partial(present: 1, total: 5), isSelected: false),
        PackCard(
            id: "ghost-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "声音包目录未找到"), isSelected: true),
        PackCard(
            id: "corrupt-pack", name: nil, isCC0: false, presentEvents: [],
            state: .broken(reason: "manifest.json 解析失败"), isSelected: false),
    ]

    // MARK: - Product UI refactor states

    /// 主面板包区域的五个互斥状态，另加固定包 1 行/4 行两种真实密度。
    public static let panelPackSectionStates: [PanelPackSectionState] = [
        .loading,
        .pinned([packCards[0]]),
        .pinned(Array(packCards.prefix(maxStarredPacks))),
        .noPinnedPacks(availablePackCount: 6),
        .noPacks,
        .readFailed(reason: "声音包目录暂时无法读取，请检查权限。"),
    ]

    // MARK: - About settings

    public static let aboutBundleFacts = projectAboutBundleFacts(
        AboutBundleFactsInput(
            brandName: "Orbit Zero",
            productName: "claudi0",
            version: "0.1.0",
            build: "42",
            architecture: "arm64",
            minimumSystemVersion: "12.0",
            operatingSystemVersion: "15.6.1"))

    public static let aboutBundledResources = AboutBundledResourceKind.allCases.map {
        AboutBundledResource(
            kind: $0,
            url: URL(fileURLWithPath: "/preview/\($0.rawValue)"))
    }

    public static let aboutPathFacts = AboutPathKind.allCases.map {
        AboutPathExistenceFact(kind: $0, exists: true)
    }

    public static let aboutSurfaceFacts =
        [
            AboutSurfaceFact(host: .claudeCode, state: .ready),
            AboutSurfaceFact(host: .codex, state: .awaitingActivation),
            AboutSurfaceFact(host: .workBuddy, state: .legacy),
        ].compactMap { $0 }
        + AdditionalHostReleasePolicy.visibleHosts.compactMap {
            AboutSurfaceFact(host: $0, state: .awaitingActivation)
        }

    // MARK: - Unified Settings routes (#86)

    public struct SettingsRouteScenario: Identifiable, Sendable, Equatable {
        public var id: SettingsDestination { destination }
        public let destination: SettingsDestination
        public let route: SettingsRoute

        public init(destination: SettingsDestination, route: SettingsRoute) {
            self.destination = destination
            self.route = route
        }
    }

    public struct SettingsRouteFailureScenario: Identifiable, Sendable, Equatable {
        public let id: String
        public let route: SettingsRoute
        public let availability: SettingsRouteAvailability
        public let expectedFailure: SettingsRouteFailure

        public init(
            id: String,
            route: SettingsRoute,
            availability: SettingsRouteAvailability,
            expectedFailure: SettingsRouteFailure
        ) {
            self.id = id
            self.route = route
            self.availability = availability
            self.expectedFailure = expectedFailure
        }
    }

    /// Production basic-destination states used by the unified Settings visual/AX matrix. Each
    /// case names a real semantic state owned by the destination model; the gallery only injects
    /// deterministic adapters and continues to render the ``ClaudioSettingsPresentation``
    /// module's `SettingsRootView` seam itself.
    public enum SettingsGeneralGalleryState: Sendable, Equatable {
        case ready
        case permissionRequired
        case writeFailed
    }

    public enum SettingsNotificationsGalleryState: Sendable, Equatable {
        case ready
        case permissionRequired
        case stale
        case writeFailed
    }

    public enum SettingsUsageGalleryState: Sendable, Equatable {
        case loading
        case ready
        case empty
        case stale
        case unreadable
        case writeFailed
    }

    public enum SettingsShortcutsGalleryState: Sendable, Equatable {
        case ready
        case empty
        case writeFailed
    }

    public enum SettingsAboutGalleryState: Sendable, Equatable {
        case ready
        case empty
        case writeFailed
    }

    /// One descriptor is the sole scenario-to-fixture dispatch point. Destination builders read
    /// only their typed field instead of repeatedly switching on the scenario roster.
    public struct SettingsExperienceProfile: Sendable, Equatable {
        public let destination: SettingsDestination
        public let general: SettingsGeneralGalleryState
        public let notifications: SettingsNotificationsGalleryState
        public let usage: SettingsUsageGalleryState
        public let shortcuts: SettingsShortcutsGalleryState
        public let about: SettingsAboutGalleryState

        fileprivate init(
            destination: SettingsDestination,
            general: SettingsGeneralGalleryState = .ready,
            notifications: SettingsNotificationsGalleryState = .ready,
            usage: SettingsUsageGalleryState = .empty,
            shortcuts: SettingsShortcutsGalleryState = .empty,
            about: SettingsAboutGalleryState = .ready
        ) {
            self.destination = destination
            self.general = general
            self.notifications = notifications
            self.usage = usage
            self.shortcuts = shortcuts
            self.about = about
        }
    }

    public enum SettingsExperienceScenario: String, CaseIterable, Identifiable, Sendable {
        case generalReady = "general.ready"
        case generalPermissionRequired = "general.permission-required"
        case generalWriteFailed = "general.write-failed"
        case notificationsReady = "notifications.ready"
        case notificationsPermissionRequired = "notifications.permission-required"
        case notificationsStale = "notifications.stale"
        case notificationsWriteFailed = "notifications.write-failed"
        case usageLoading = "usage.loading"
        case usageReady = "usage.ready"
        case usageEmpty = "usage.empty"
        case usageStale = "usage.stale"
        case usageUnreadable = "usage.unreadable"
        case usageWriteFailed = "usage.write-failed"
        case shortcutsReady = "shortcuts.ready"
        case shortcutsEmpty = "shortcuts.empty"
        case shortcutsWriteFailed = "shortcuts.write-failed"
        case aboutReady = "about.ready"
        case aboutEmpty = "about.empty"
        case aboutWriteFailed = "about.write-failed"

        public var id: String { rawValue }

        public var profile: SettingsExperienceProfile {
            switch self {
            case .generalReady:
                SettingsExperienceProfile(destination: .general)
            case .generalPermissionRequired:
                SettingsExperienceProfile(
                    destination: .general,
                    general: .permissionRequired)
            case .generalWriteFailed:
                SettingsExperienceProfile(destination: .general, general: .writeFailed)
            case .notificationsReady:
                SettingsExperienceProfile(destination: .notifications)
            case .notificationsPermissionRequired:
                SettingsExperienceProfile(
                    destination: .notifications,
                    notifications: .permissionRequired)
            case .notificationsStale:
                SettingsExperienceProfile(
                    destination: .notifications,
                    notifications: .stale)
            case .notificationsWriteFailed:
                SettingsExperienceProfile(
                    destination: .notifications,
                    notifications: .writeFailed)
            case .usageLoading:
                SettingsExperienceProfile(destination: .usage, usage: .loading)
            case .usageReady:
                SettingsExperienceProfile(destination: .usage, usage: .ready)
            case .usageEmpty:
                SettingsExperienceProfile(destination: .usage)
            case .usageStale:
                SettingsExperienceProfile(destination: .usage, usage: .stale)
            case .usageUnreadable:
                SettingsExperienceProfile(destination: .usage, usage: .unreadable)
            case .usageWriteFailed:
                SettingsExperienceProfile(destination: .usage, usage: .writeFailed)
            case .shortcutsReady:
                SettingsExperienceProfile(destination: .shortcuts, shortcuts: .ready)
            case .shortcutsEmpty:
                SettingsExperienceProfile(destination: .shortcuts)
            case .shortcutsWriteFailed:
                SettingsExperienceProfile(destination: .shortcuts, shortcuts: .writeFailed)
            case .aboutReady:
                SettingsExperienceProfile(destination: .about)
            case .aboutEmpty:
                SettingsExperienceProfile(destination: .about, about: .empty)
            case .aboutWriteFailed:
                SettingsExperienceProfile(destination: .about, about: .writeFailed)
            }
        }

        public var destination: SettingsDestination { profile.destination }
    }

    public static let settingsExperienceScenarios = SettingsExperienceScenario.allCases

    /// Exhaustive visual roster for the allowlisted AI Cue profiles, credential states, composer
    /// lifecycle and failure families required by the Settings acceptance matrix. The gallery
    /// routes every scenario through SettingsStateGalleryView into the production
    /// SettingsRootView/session mount.
    public enum AICueGalleryScenario: String, CaseIterable, Identifiable, Sendable {
        case elevenLabsMissing = "elevenlabs.missing"
        case elevenLabsVerified = "elevenlabs.verified"
        case miniMaxRejected = "minimax.rejected"
        case qwenSingaporeDeferred = "qwen-singapore.deferred"
        case qwenBeijingPendingReplacement = "qwen-beijing.pending-replacement"
        case qwenBeijingUnavailable = "qwen-beijing.unavailable"
        case senseAudioMissing = "senseaudio-cn.missing"
        case senseAudioVoiceUnavailable = "senseaudio-cn.voice-unavailable"
        case elevenLabsProbing = "elevenlabs.probing"
        case qwenSingaporeSaving = "qwen-singapore.saving"
        case qwenBeijingUpdatingReplacement = "qwen-beijing.updating-replacement"
        case miniMaxDeleting = "minimax.deleting"
        case elevenLabsProbeFailure = "elevenlabs.probe-failure"
        case qwenSingaporeSaveFailure = "qwen-singapore.save-failure"
        case miniMaxDeleteFailure = "minimax.delete-failure"
        case editing = "composer.editing"
        case generating = "composer.generating"
        case candidates = "composer.candidates"
        case senseAudioPartial = "composer.senseaudio-partial"
        case senseAudioPartialPlaying = "composer.senseaudio-partial-playing"
        case playing = "composer.playing"
        case adopting = "composer.adopting"
        case applied = "composer.applied"
        case unsupportedModality = "composer.unsupported-modality"
        case unsupportedLocale = "composer.unsupported-locale"
        case credentialRequired = "composer.credential-required"
        case providerFailure = "composer.provider-failure"
        case validationFailure = "composer.validation-failure"
        case displayNameFailure = "composer.display-name-failure"
        case targetDrift = "composer.target-drift"
        case adoptionRollback = "composer.adoption-rollback"

        public var id: String { rawValue }

        public var providerProfileID: AICueProviderProfileID { facts.providerProfileID }
        public var rendersCredentialSheet: Bool { facts.rendersCredentialSheet }

        public var playingCandidateID: UUID? {
            switch self {
            case .playing: PreviewFixtures.aiCueCandidateIDs[0]
            case .senseAudioPartialPlaying: PreviewFixtures.aiCueCandidateIDs[2]
            default: nil
            }
        }

        package var previewSession: AICueComposerSession? {
            rendersCredentialSheet ? nil : PreviewFixtures.aiCueSession
        }

        package var candidateIdentities: [AICueCandidateIdentity] {
            guard facts.needsGeneration else { return [] }
            if usesSenseAudioPartialGeneration {
                return [1, 3].map { .numbered(AICueCandidateOrdinal(rawValue: $0)!) }
            }
            return AICueVariant.allCases.map(AICueCandidateIdentity.styled)
        }

        package func previewState(
            candidateAssets: [AICueCandidateIdentity: AICueTemporaryAudioAsset] = [:]
        ) -> AICueGenerationPreviewState {
            precondition(
                Set(candidateAssets.keys) == Set(candidateIdentities),
                "AI Cue gallery candidates require exact, lifecycle-owned audio assets")
            let session = previewSession
            let generation: AICueGeneration?
            if facts.needsGeneration {
                generation =
                    usesSenseAudioPartialGeneration
                    ? PreviewFixtures.senseAudioPartialGeneration(candidateAssets: candidateAssets)
                    : PreviewFixtures.aiCueGeneration(candidateAssets: candidateAssets)
            } else {
                generation = nil
            }
            let outcome = self == .applied ? PreviewFixtures.aiCueAdoptionOutcome : nil
            return AICueGenerationPreviewState(
                providerProfileID: providerProfileID,
                credentialStatus: facts.credentialStatus,
                credentialActivity: facts.credentialActivity,
                credentialFailure: facts.credentialFailure,
                phase: facts.composerPhase,
                adoptingCandidateID: self == .adopting
                    ? PreviewFixtures.aiCueCandidateIDs[1] : nil,
                soundDescription: session == nil ? "" : PreviewFixtures.aiCueDescription,
                displayName: generation == nil ? "" : PreviewFixtures.aiCueDisplayName,
                session: session,
                generation: self == .applied ? nil : generation,
                failure: facts.composerFailure,
                adoptionOutcome: outcome)
        }

        private var usesSenseAudioPartialGeneration: Bool {
            self == .senseAudioPartial || self == .senseAudioPartialPlaying
        }

        private var facts: Facts {
            switch self {
            case .elevenLabsMissing:
                Facts(rendersCredentialSheet: true, credentialStatus: .missing)
            case .elevenLabsVerified:
                Facts(rendersCredentialSheet: true)
            case .miniMaxRejected:
                Facts(
                    providerProfileID: .miniMaxGlobal,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .rejected,
                        hasPendingReplacement: false))
            case .qwenSingaporeDeferred:
                Facts(
                    providerProfileID: .qwenSingapore,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .deferred,
                        hasPendingReplacement: false))
            case .qwenBeijingPendingReplacement:
                Facts(
                    providerProfileID: .qwenBeijing,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .verified,
                        hasPendingReplacement: true))
            case .qwenBeijingUnavailable:
                Facts(
                    providerProfileID: .qwenBeijing,
                    rendersCredentialSheet: true,
                    credentialStatus: .unavailable)
            case .senseAudioMissing:
                Facts(
                    providerProfileID: .senseAudioChina,
                    rendersCredentialSheet: true,
                    credentialStatus: .missing)
            case .senseAudioVoiceUnavailable:
                Facts(
                    providerProfileID: .senseAudioChina,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .verified,
                        hasPendingReplacement: false),
                    credentialFailure: .provider(.requiredModelsUnavailable))
            case .elevenLabsProbing:
                Facts(rendersCredentialSheet: true, credentialActivity: .probing)
            case .qwenSingaporeSaving:
                Facts(
                    providerProfileID: .qwenSingapore,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .deferred,
                        hasPendingReplacement: false),
                    credentialActivity: .saving)
            case .qwenBeijingUpdatingReplacement:
                Facts(
                    providerProfileID: .qwenBeijing,
                    rendersCredentialSheet: true,
                    credentialStatus: .stored(
                        verification: .verified,
                        hasPendingReplacement: true),
                    credentialActivity: .pendingReplacement)
            case .miniMaxDeleting:
                Facts(
                    providerProfileID: .miniMaxGlobal,
                    rendersCredentialSheet: true,
                    credentialActivity: .deleting)
            case .elevenLabsProbeFailure:
                Facts(
                    rendersCredentialSheet: true,
                    credentialStatus: .missing,
                    credentialFailure: .provider(.invalidCredential))
            case .qwenSingaporeSaveFailure:
                Facts(
                    providerProfileID: .qwenSingapore,
                    rendersCredentialSheet: true,
                    credentialStatus: .missing,
                    credentialFailure: .storageUnavailable)
            case .miniMaxDeleteFailure:
                Facts(
                    providerProfileID: .miniMaxGlobal,
                    rendersCredentialSheet: true,
                    credentialFailure: .storageUnavailable)
            case .editing:
                Facts()
            case .generating:
                Facts(composerPhase: .generating)
            case .candidates, .playing:
                Facts(composerPhase: .candidatesReady, needsGeneration: true)
            case .senseAudioPartial, .senseAudioPartialPlaying:
                Facts(
                    providerProfileID: .senseAudioChina,
                    composerPhase: .candidatesReady,
                    needsGeneration: true)
            case .adopting:
                Facts(composerPhase: .adopting, needsGeneration: true)
            case .applied:
                Facts(composerPhase: .applied)
            case .unsupportedModality:
                Facts(
                    providerProfileID: .miniMaxGlobal,
                    composerFailure: .generation(
                        .requestCompilation(.unsupportedModality)))
            case .unsupportedLocale:
                Facts(
                    providerProfileID: .miniMaxGlobal,
                    composerFailure: .generation(
                        .requestCompilation(.unsupportedLocale)))
            case .credentialRequired:
                Facts(
                    credentialStatus: .missing,
                    composerFailure: .generation(.credentialRequired))
            case .providerFailure:
                Facts(composerFailure: .generation(.provider(.serviceUnavailable)))
            case .validationFailure:
                Facts(composerFailure: .generation(.validation(.emptyDescription)))
            case .displayNameFailure:
                Facts(
                    composerPhase: .candidatesReady,
                    needsGeneration: true,
                    composerFailure: .displayName(
                        .displayNameTooLong(maximumCharacters: 40)))
            case .targetDrift:
                Facts(
                    composerPhase: .candidatesReady,
                    needsGeneration: true,
                    composerFailure: .adoption(.targetChanged))
            case .adoptionRollback:
                Facts(
                    composerPhase: .candidatesReady,
                    needsGeneration: true,
                    composerFailure: .adoption(
                        .importedButNotBound(
                            fileName: PreviewFixtures.sampleImportedAudioFile.fileName)))
            }
        }

        private struct Facts: Sendable {
            let providerProfileID: AICueProviderProfileID
            let rendersCredentialSheet: Bool
            let credentialStatus: AICueCredentialStatus?
            let credentialActivity: AICueCredentialActivity
            let credentialFailure: AICueCredentialFailure?
            let composerPhase: AICueComposerPhase
            let needsGeneration: Bool
            let composerFailure: AICueComposerFailure?

            init(
                providerProfileID: AICueProviderProfileID = .elevenLabsGlobal,
                rendersCredentialSheet: Bool = false,
                credentialStatus: AICueCredentialStatus? = .stored(
                    verification: .verified,
                    hasPendingReplacement: false),
                credentialActivity: AICueCredentialActivity = .idle,
                credentialFailure: AICueCredentialFailure? = nil,
                composerPhase: AICueComposerPhase = .editing,
                needsGeneration: Bool = false,
                composerFailure: AICueComposerFailure? = nil
            ) {
                self.providerProfileID = providerProfileID
                self.rendersCredentialSheet = rendersCredentialSheet
                self.credentialStatus = credentialStatus
                self.credentialActivity = credentialActivity
                self.credentialFailure = credentialFailure
                self.composerPhase = composerPhase
                self.needsGeneration = needsGeneration
                self.composerFailure = composerFailure
            }
        }
    }

    public static let aiCueGalleryScenarios = AICueGalleryScenario.allCases

    package static var aiCueEvidenceRegistry: AICueProviderRegistry {
        let policy = try! AICueAssetPolicy(
            allowedOrigins: [try! AICueAssetOrigin("https://assets.fixture.invalid")],
            acceptedMediaTypes: ["audio/mpeg"])
        return AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: policy)
    }

    /// The exact finalized Events reference: Claude Code, ElevenLabs verified, prompt editing.
    public static let finalizedClaudeEventsAICuePreviewState: AICueGenerationPreviewState = {
        return AICueGenerationPreviewState(
            providerProfileID: .elevenLabsGlobal,
            credentialStatus: .stored(
                verification: .verified,
                hasPendingReplacement: false),
            credentialActivity: .idle,
            credentialFailure: nil,
            phase: .editing,
            adoptingCandidateID: nil,
            soundDescription: aiCueDescription,
            displayName: "",
            session: AICueComposerSession(scope: .surface(.claudeCode), event: .stop),
            generation: nil,
            failure: nil,
            adoptionOutcome: nil)
    }()

    /// A deterministic seven-day activity document used by the production Panel gallery.
    /// Claude Code keeps its real 5/5 capability truth; WorkBuddy supplies the real unsupported
    /// slots so both visual states are covered without forging a Claude capability gap.
    public static let finalizedActivityDiagnosticsPresentation: ActivityDiagnosticsPresentation = {
        let now = Date(timeIntervalSince1970: 1_788_739_200)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let dateKeys = LocalActivitySummaryStore.dateKeys(today: now, timeZone: timeZone)
        let todayCounts: [String: UInt64] = [
            LocalActivityCounterKey.make(host: .claudeCode, event: .taskStart): 4,
            LocalActivityCounterKey.make(host: .claudeCode, event: .stop): 0,
            LocalActivityCounterKey.make(host: .claudeCode, event: .stopFailure): 1,
            LocalActivityCounterKey.make(host: .claudeCode, event: .notification): 0,
            LocalActivityCounterKey.make(host: .claudeCode, event: .subagentStop): 2,
            LocalActivityCounterKey.make(host: .workBuddy, event: .taskStart): 2,
            LocalActivityCounterKey.make(host: .workBuddy, event: .stop): 1,
        ]
        let previousCounts: [String: UInt64] = [
            LocalActivityCounterKey.make(host: .claudeCode, event: .taskStart): 18,
            LocalActivityCounterKey.make(host: .claudeCode, event: .stop): 16,
            LocalActivityCounterKey.make(host: .claudeCode, event: .stopFailure): 1,
            LocalActivityCounterKey.make(host: .claudeCode, event: .notification): 5,
            LocalActivityCounterKey.make(host: .claudeCode, event: .subagentStop): 4,
            LocalActivityCounterKey.make(host: .workBuddy, event: .taskStart): 8,
            LocalActivityCounterKey.make(host: .workBuddy, event: .stop): 7,
        ]
        let document = LocalActivitySummaryDocument(
            updatedAt: now,
            buckets: [
                LocalActivityDayBucket(localDate: dateKeys[0], counts: todayCounts),
                LocalActivityDayBucket(localDate: dateKeys[1], counts: previousCounts),
            ])
        let projection = ActivityOverviewProjector.project(
            document: document,
            readState: .ready,
            integrationStatuses: [
                .claudeCode: .connected,
                .codex: .awaitingReceipt,
                .workBuddy: .connected,
            ],
            now: now,
            timeZone: timeZone)
        return ActivityDiagnosticsPresentation(
            projection: projection,
            log: ActivityDiagnosticLogSnapshot(path: "", state: .missing, failures: []))
    }()

    private static let aiCueDescription = "清晰地说“任务完成”，语气温和"
    private static let aiCueDisplayName = "任务完成"
    private static let aiCueGenerationID = UUID(
        uuidString: "A1000000-0000-0000-0000-000000000001")!
    fileprivate static let aiCueCandidateIDs = [
        UUID(uuidString: "A1000000-0000-0000-0000-000000000011")!,
        UUID(uuidString: "A1000000-0000-0000-0000-000000000012")!,
        UUID(uuidString: "A1000000-0000-0000-0000-000000000013")!,
    ]
    private static let aiCueSession = AICueComposerSession(
        scope: .surface(.workBuddy),
        event: .stop)
    private static let aiCuePlan = AICueSoundPlan(
        suggestedDisplayName: aiCueDisplayName,
        modality: .speech,
        soundDescription: aiCueDescription,
        spokenContent: "任务完成",
        languageTag: "zh-Hans",
        styleDescription: "温和、清晰、短促",
        targetDurationMilliseconds: 1_800,
        instructionVersion: AICueSoundPlanner.instructionVersion)
    private static func aiCueGeneration(
        candidateAssets: [AICueCandidateIdentity: AICueTemporaryAudioAsset]
    ) -> AICueGeneration {
        AICueGeneration(
            id: aiCueGenerationID,
            profileID: .elevenLabsGlobal,
            plan: aiCuePlan,
            candidates: zip(AICueVariant.allCases, aiCueCandidateIDs).map { variant, id in
                let identity = AICueCandidateIdentity.styled(variant)
                return AICueCandidate(
                    id: id,
                    identity: identity,
                    asset: candidateAssets[identity]!,
                    durationMilliseconds: 1_600 + variant.ordinal * 100,
                    mediaType: previewMediaType(for: candidateAssets[identity]!.sniffedFormat),
                    provenance: AICueCandidateProvenance(
                        providerID: .elevenLabs,
                        profileID: .elevenLabsGlobal,
                        modelID: "eleven_v3",
                        generationID: aiCueGenerationID,
                        requestOrdinal: variant.ordinal,
                        providerRequestID: "gallery-\(variant.ordinal)"))
            },
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func senseAudioPartialGeneration(
        candidateAssets: [AICueCandidateIdentity: AICueTemporaryAudioAsset]
    ) -> AICueGeneration {
        let generationID = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
        return AICueGeneration(
            id: generationID,
            profileID: .senseAudioChina,
            plan: AICueSoundPlan(
                suggestedDisplayName: "短促木琴",
                modality: .soundEffect,
                soundDescription: "短促木琴音效",
                spokenContent: nil,
                languageTag: nil,
                styleDescription: "短促木琴音效",
                targetDurationMilliseconds: 1_500,
                instructionVersion: AICueSoundPlanner.instructionVersion),
            candidates: [1, 3].map { ordinalValue in
                let ordinal = AICueCandidateOrdinal(rawValue: ordinalValue)!
                let identity = AICueCandidateIdentity.numbered(ordinal)
                return AICueCandidate(
                    id: aiCueCandidateIDs[ordinalValue - 1],
                    identity: identity,
                    asset: candidateAssets[identity]!,
                    durationMilliseconds: 1_400 + ordinalValue * 100,
                    mediaType: previewMediaType(for: candidateAssets[identity]!.sniffedFormat),
                    provenance: AICueCandidateProvenance(
                        providerID: .senseAudio,
                        profileID: .senseAudioChina,
                        modelID: "senseaudio-sfx-1.0-260626",
                        generationID: generationID,
                        requestOrdinal: ordinalValue,
                        providerRequestID: "gallery-senseaudio-\(ordinalValue)"))
            },
            completion: .partial,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func previewMediaType(for format: AudioFormat) -> String {
        switch format {
        case .wav: "audio/wav"
        case .mp3: "audio/mpeg"
        case .aiff: "audio/aiff"
        case .m4a: "audio/mp4"
        }
    }
    private static let aiCueAdoptionOutcome = AICueComposerAdoptionOutcome(
        finalDisplayName: aiCueDisplayName)

    public static let settingsRouteAvailability = SettingsRouteAvailability(
        integrationSurfaces: Set(HostID.productVisibleCases.map(\.surfaceID)),
        eventScopes: Set(
            [PanelSoundScopeID.global]
                + HostID.productVisibleCases.map { .surface($0.surfaceID) }),
        soundScopes: Set(
            [PanelSoundScopeID.global]
                + HostID.productVisibleCases.map { .surface($0.surfaceID) }),
        soundPackIDs: ["gallery-pack"],
        events: Set(Event.allCases))

    /// One ready route slot per fixed destination, in sidebar order.
    public static let settingsRouteScenarios: [SettingsRouteScenario] =
        SettingsDestination.allCases.map { destination in
            let route: SettingsRoute
            switch destination {
            case .integrations:
                route = .integrations(IntegrationsSettingsRoute(surface: .workBuddy))
            case .eventsAndSounds:
                route = .events(scope: .global, event: .notification)
            case .sounds:
                route = .sounds(
                    .editEvent(
                        surface: nil,
                        packID: "gallery-pack",
                        event: .stop))
            default:
                route = .destination(destination)
            }
            return SettingsRouteScenario(destination: destination, route: route)
        }

    /// Every visible failure shape in ``SettingsRouteFailure``. Each frame retains its requested
    /// destination and carries only the availability change needed to make that target stale.
    public static let settingsRouteFailureScenarios: [SettingsRouteFailureScenario] = {
        let surfaceLimited = SettingsRouteAvailability(
            integrationSurfaces: [.workBuddy],
            eventScopes: [.global, .surface(.workBuddy)],
            soundScopes: [.global, .surface(.workBuddy)],
            soundPackIDs: settingsRouteAvailability.soundPackIDs,
            events: settingsRouteAvailability.events)
        let globalEventScopeMissing = SettingsRouteAvailability(
            integrationSurfaces: settingsRouteAvailability.integrationSurfaces,
            eventScopes: [.surface(.workBuddy)],
            soundScopes: settingsRouteAvailability.soundScopes,
            soundPackIDs: settingsRouteAvailability.soundPackIDs,
            events: settingsRouteAvailability.events)
        let eventMissing = SettingsRouteAvailability(
            integrationSurfaces: settingsRouteAvailability.integrationSurfaces,
            eventScopes: settingsRouteAvailability.eventScopes,
            soundScopes: settingsRouteAvailability.soundScopes,
            soundPackIDs: settingsRouteAvailability.soundPackIDs,
            events: Set(Event.allCases.filter { $0 != .stopFailure }))

        return [
            SettingsRouteFailureScenario(
                id: "invalid-surface",
                route: .integrations(IntegrationsSettingsRoute(surface: .chatGPTDesktopAX)),
                availability: settingsRouteAvailability,
                expectedFailure: .invalidSurface(.chatGPTDesktopAX)),
            SettingsRouteFailureScenario(
                id: "stale-surface",
                route: .events(scope: .surface(.codex), event: .stop),
                availability: surfaceLimited,
                expectedFailure: .staleSurface(.codex)),
            SettingsRouteFailureScenario(
                id: "stale-sound-scope",
                route: .events(scope: .global, event: .stop),
                availability: globalEventScopeMissing,
                expectedFailure: .staleSoundScope(.global)),
            SettingsRouteFailureScenario(
                id: "stale-event",
                route: .events(scope: .surface(.workBuddy), event: .stopFailure),
                availability: eventMissing,
                expectedFailure: .staleEvent(.stopFailure)),
            SettingsRouteFailureScenario(
                id: "invalid-sound-pack-id",
                route: .sounds(
                    .editEvent(surface: .workBuddy, packID: "   ", event: .stop)),
                availability: settingsRouteAvailability,
                expectedFailure: .invalidSoundPackID),
            SettingsRouteFailureScenario(
                id: "stale-sound-pack",
                route: .sounds(
                    .editEvent(
                        surface: .workBuddy,
                        packID: "removed-pack",
                        event: .stop)),
                availability: settingsRouteAvailability,
                expectedFailure: .staleSoundPack("removed-pack")),
        ]
    }()

    // MARK: - MasterVolumeState (PLAN-MASTER-VOLUME.md 阶段 D, D33/D38/D39)
    //
    // 主音量控件行在 state gallery 里的展示态。**这不是生产代码里一个真实存在的状态机**——生产端
    // `MasterVolumeRow` 显示什么是两个独立事实的组合（`VolumeDragSession.draft` 当前的值 + 若有，
    // `PanelConfigController.masterVolumeError` 那条写失败），从未被合并成一个真实类型。这个 enum
    // 只是给 gallery 一个可以逐帧枚举的手柄，与其它四族「照抄生产类型」的做法不同，理由见下。
    //
    // D38：范围只到这一族的六帧（含至少一条「行 + 错误行」组合帧，D39）——D23 定稿的三个路由态
    // （`.needsPack`/`.malformed`/`.unwritable`）不进 gallery（那三态根本不渲染 `MasterVolumeRow`，
    // 走真机走查 ⑫⑬ 兜底，见 `TODOS.md` 登记的 `PanelRouteState` 族 P3）。

    /// 六帧要覆盖的两个「形状」：滑块单独显示一个值，或者滑块回滚之后贴着一条错误行（D12 的瞬跳 +
    /// D39 的组合帧）。
    public enum MasterVolumeState: Sendable, Equatable {
        /// 滑块显示 `volume`，没有错误行。
        case value(Double)
        /// 一次写盘失败之后（D12：draft 已经瞬跳回磁盘上的 `volume`），下方贴着一条错误行 `message`
        /// （D39：`.writeFailed` 归 `PanelView` 渲染，`MasterVolumeRow` 自身零错误 UI）。
        case failed(volume: Double, message: String)
    }

    /// D16：音量 0 是合法值（总输出无声），不是"禁用"或"错误"——它必须有自己的一帧，不能被折进
    /// 「随便一个值」里悄悄消失。0.35 是 21 档网格上的一个中间值（D45「干净渲染」那一类的代表）。
    /// 两条 `.failed` 帧的文案直接取自 `SetMasterVolumeError.description`（真实文案，不是在这里
    /// 手抄一遍好看的假句子——遵循共享 fixture 文案合同）：一条是高频常态的锁竞争，
    /// 一条是 D12 走查项 ⑧ 的真实场景（目录只读）。
    public static let masterVolumeStates: [MasterVolumeState] = [
        .value(0.0),
        .value(0.35),
        .value(ClaudioConfig.defaultMasterVolume),
        .value(1.0),
        .failed(volume: 0.8, message: SetMasterVolumeError.lockBusy.description),
        .failed(
            volume: 0.35,
            message: SetMasterVolumeError.configWriteFailure(
                reason: "~/.claudio 目录不可写，请检查权限后重试"
            ).description),
    ]

    // MARK: - Host integrations (all products)

    /// 全部产品宿主状态展柜的一帧。`state` 同时携带宿主快照与 Core 合成的可听矩阵，
    /// 因此宿主卡、矩阵格和检查器不会在预览中分裂成三套事实。
    public struct HostIntegrationScenario: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let state: HostIntegrationPresentationState

        public init(
            id: String,
            title: String,
            state: HostIntegrationPresentationState
        ) {
            self.id = id
            self.title = title
            self.state = state
        }
    }

    /// #65 的 WorkBuddy pre-RC 阶段名册。raw value 同时是稳定 fixture ID；新增阶段必须先扩展
    /// `allCases`，使 focused suite 与 state gallery 一起 fail closed。
    public enum WorkBuddyVisualPhase: String, CaseIterable, Sendable, Equatable, Hashable {
        case disconnected = "workbuddy.disconnected"
        case awaitingActivation = "workbuddy.awaiting"
        case taskStartCurrent = "workbuddy.task-start-current"
        case allImplementedBindingsCurrent = "workbuddy.all-bindings-current"
        case conflict = "workbuddy.conflict"
        case repairedAwaitingActivation = "workbuddy.repaired-awaiting"
        case disconnectedAfterAction = "workbuddy.disconnected-after-action"
    }

    /// WorkBuddy 验收矩阵的一帧。它仍携带全部 Product/Surface 快照；`phase` 只命名本帧要
    /// 突出的 WorkBuddy 事实，不会把产品身份、surface 或 binding 压成一个 UI-only 状态。
    public struct WorkBuddyVisualScenario: Identifiable, Sendable, Equatable {
        public var id: String { phase.rawValue }
        public let phase: WorkBuddyVisualPhase
        public let title: String
        public let state: HostIntegrationPresentationState

        public init(
            phase: WorkBuddyVisualPhase,
            title: String,
            state: HostIntegrationPresentationState
        ) {
            self.phase = phase
            self.title = title
            self.state = state
        }
    }

    /// 全部产品宿主态的最小验收名册。每帧都通过 ``hostIntegrationScenario`` 调用
    /// ``HostCapabilityCatalog`` + ``AudibilityMatrix.make`` 构建；这里不允许手写
    /// ``AudibilityCell``，因此删除 Codex 映射会直接改变展柜里的真实格子。
    public static let hostIntegrationScenarios: [HostIntegrationScenario] = [
        hostIntegrationScenario(
            id: "all-products-disconnected",
            title: "全部产品宿主未连接",
            snapshots: HostID.productVisibleCases.map {
                HostIntegrationSnapshot.disconnected(host: $0)
            }),
        hostIntegrationScenario(
            id: "claude-only",
            title: "仅 Claude Code 已连接",
            snapshots: [
                hostIntegrationSnapshot(host: .claudeCode),
                .disconnected(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "codex-only",
            title: "仅 Codex 已连接",
            snapshots: [
                .disconnected(host: .claudeCode),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "all-products-connected",
            title: "全部产品宿主已连接",
            snapshots: HostID.productVisibleCases.map { hostIntegrationSnapshot(host: $0) }),
        hostIntegrationScenario(
            id: "codex-awaiting",
            title: "claudi0 已写好，等待 Codex 确认",
            snapshots: [
                hostIntegrationSnapshot(host: .claudeCode),
                hostIntegrationSnapshot(
                    host: .codex,
                    activation: .awaitingReceipt(installationID: hostIntegrationInstallationID)),
            ]),
        hostIntegrationScenario(
            id: "claude-legacy",
            title: "Claude Code 旧版连接，可升级",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .legacyConnected,
                    activation: HostActivationEvidence.none),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "codex-normal-4-of-5",
            title: "Codex 正常 4/5",
            snapshots: [
                .disconnected(host: .claudeCode),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "partial-single-degraded",
            title: "Claude Code 缺少一个 hook，Codex 仍可用",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .incomplete(missingNativeEvents: ["StopFailure"]),
                    activation: HostActivationEvidence.none),
                hostIntegrationSnapshot(host: .codex),
            ]),
        hostIntegrationScenario(
            id: "shared-runtime-failure",
            title: "共享 helper 损坏",
            snapshots: HostID.productVisibleCases.map {
                hostIntegrationSnapshot(
                    host: $0,
                    runtime: .damaged(reason: "claudi0 helper 损坏"))
            }),
        hostIntegrationScenario(
            id: "single-side-connection-failure",
            title: "Claude Code 连接失败，Codex 仍可用",
            snapshots: [
                hostIntegrationSnapshot(
                    host: .claudeCode,
                    configuration: .conflict(reason: "连接失败：配置已被外部修改"),
                    activation: HostActivationEvidence.none,
                    operation: .failed(reason: "配置已被外部修改")),
                hostIntegrationSnapshot(host: .codex),
            ]),
    ]

    /// #65 的确定性 WorkBuddy 状态基线。每帧由真实 catalog 与 `AudibilityMatrix` 合成；
    /// Repair/Disconnect 是动作完成后的事实态，不会在 preview 中执行宿主写入。
    public static let workBuddyVisualScenarios: [WorkBuddyVisualScenario] =
        WorkBuddyVisualPhase.allCases.map(workBuddyVisualScenario)

    private static let hostIntegrationInstallationID = UUID(
        uuidString: "00000000-0000-4000-8000-0000000000C1")!

    private static let workBuddyVisualInstallationID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000065")!

    private static func hostIntegrationSnapshot(
        host: HostID,
        runtime: SharedRuntimeHealth = .ready,
        configuration: HostConfigurationState = .configured,
        activation: HostActivationEvidence? = nil,
        operation: HostOperationState = .idle
    ) -> HostIntegrationSnapshot {
        guard
            let binding = HostCapabilityCatalog.bindings(for: host)
                .first(where: \.isAudibleCapability)
        else {
            return HostIntegrationSnapshot(
                host: host,
                runtime: runtime,
                availability: .unavailable(reason: "Beta candidate unavailable"),
                configuration: .notConfigured,
                writability: .unknown,
                activation: .none,
                operation: operation)
        }
        let resolvedActivation =
            activation
            ?? .observed(
                HostReceiptEvidence(
                    bindingID: binding.id,
                    installationID: hostIntegrationInstallationID,
                    nativeEvent: binding.nativeEvent!,
                    event: binding.event,
                    timestamp: Date(timeIntervalSince1970: 1_721_980_800),
                    playbackResult: .played))
        let latestReceipt: HostReceiptEvidence?
        if case .observed(let observed) = resolvedActivation {
            latestReceipt = observed
        } else {
            latestReceipt = nil
        }
        return HostIntegrationSnapshot(
            host: host,
            runtime: runtime,
            availability: .available,
            configuration: configuration,
            writability: .writable,
            activation: resolvedActivation,
            bindingActivations: activation == nil && configuration == .configured
                ? Dictionary(
                    uniqueKeysWithValues: HostCapabilityCatalog.bindings(for: host)
                        .filter(\.isAudibleCapability).map {
                            (
                                $0.id,
                                .observed(
                                    HostReceiptEvidence(
                                        bindingID: $0.id,
                                        installationID: hostIntegrationInstallationID,
                                        nativeEvent: $0.nativeEvent!, event: $0.event,
                                        timestamp: Date(timeIntervalSince1970: 1_721_980_800),
                                        playbackResult: .played))
                            )
                        }) : [:],
            latestReceipt: latestReceipt,
            operation: operation,
            installationID: configuration == .notConfigured
                ? nil : hostIntegrationInstallationID)
    }

    private static func hostIntegrationScenario(
        id: String,
        title: String,
        snapshots: [HostIntegrationSnapshot]
    ) -> HostIntegrationScenario {
        let snapshotByHost = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.host, $0) })
        let normalizedSnapshots = HostID.productVisibleCases.map { host in
            snapshotByHost[host] ?? .disconnected(host: host)
        }
        let capabilities = Dictionary(
            uniqueKeysWithValues: HostID.productVisibleCases.map {
                ($0, HostCapabilityCatalog.bindings(for: $0))
            })
        let matrix = AudibilityMatrix.make(
            snapshots: normalizedSnapshots,
            capabilities: capabilities,
            soundCoverage: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0, true) }),
            enabledEvents: Dictionary(
                uniqueKeysWithValues: Event.allCases.map { ($0, true) }))
        return HostIntegrationScenario(
            id: id,
            title: title,
            state: HostIntegrationPresentationState(
                snapshots: normalizedSnapshots,
                matrix: matrix))
    }

    private static func workBuddyVisualScenario(
        _ phase: WorkBuddyVisualPhase
    ) -> WorkBuddyVisualScenario {
        let title: String
        var snapshot: HostIntegrationSnapshot
        let awaiting = HostActivationEvidence.awaitingReceipt(
            installationID: workBuddyVisualInstallationID)

        switch phase {
        case .disconnected:
            title = "WorkBuddy 未连接"
            snapshot = .disconnected(host: .workBuddy)
        case .awaitingActivation:
            title = "WorkBuddy 已配置，等待回执"
            snapshot = workBuddyVisualSnapshot(
                activation: awaiting,
                bindingActivations: workBuddyImplementedBindingActivations(
                    taskStart: awaiting,
                    stop: awaiting,
                    subagentStop: awaiting, notification: awaiting))
        case .taskStartCurrent:
            title = "WorkBuddy 仅 task_start current"
            let taskStart = workBuddyVisualReceipt(event: .taskStart, timestamp: 1_721_980_801)
            snapshot = workBuddyVisualSnapshot(
                activation: .observed(taskStart),
                bindingActivations: workBuddyImplementedBindingActivations(
                    taskStart: .observed(taskStart),
                    stop: awaiting,
                    subagentStop: awaiting, notification: awaiting),
                latestReceipt: taskStart)
        case .allImplementedBindingsCurrent:
            title = "WorkBuddy 四条 binding current"
            let taskStart = workBuddyVisualReceipt(event: .taskStart, timestamp: 1_721_980_801)
            let stop = workBuddyVisualReceipt(event: .stop, timestamp: 1_721_980_802)
            let notification = workBuddyVisualReceipt(
                event: .notification, timestamp: 1_721_980_804)
            let subagentStop = workBuddyVisualReceipt(
                event: .subagentStop, timestamp: 1_721_980_803)
            snapshot = workBuddyVisualSnapshot(
                activation: .observed(taskStart),
                bindingActivations: workBuddyImplementedBindingActivations(
                    taskStart: .observed(taskStart),
                    stop: .observed(stop),
                    subagentStop: .observed(subagentStop), notification: .observed(notification)),
                latestReceipt: notification)
        case .conflict:
            title = "WorkBuddy 配置冲突，可 Repair"
            snapshot = workBuddyVisualSnapshot(
                configuration: .conflict(reason: "检测到与 Claudio 条目冲突的 WorkBuddy hook"),
                activation: .none)
        case .repairedAwaitingActivation:
            title = "WorkBuddy Repair 后等待回执"
            snapshot = workBuddyVisualSnapshot(
                activation: awaiting,
                bindingActivations: workBuddyImplementedBindingActivations(
                    taskStart: awaiting,
                    stop: awaiting,
                    subagentStop: awaiting, notification: awaiting))
        case .disconnectedAfterAction:
            title = "WorkBuddy Disconnect 后未连接"
            snapshot = .disconnected(host: .workBuddy)
        }

        // Fixture owns its saved intent explicitly; production never infers it from configuration.
        snapshot.intent = HostIntegrationIntent(
            enabled: phase != .disconnected && phase != .disconnectedAfterAction,
            revision: workBuddyVisualInstallationID)
        let state = hostIntegrationScenario(
            id: phase.rawValue,
            title: title,
            snapshots: [snapshot]
        ).state
        return WorkBuddyVisualScenario(phase: phase, title: title, state: state)
    }

    private static func workBuddyVisualSnapshot(
        configuration: HostConfigurationState = .configured,
        activation: HostActivationEvidence,
        bindingActivations: [HostEventBindingID: HostActivationEvidence] = [:],
        latestReceipt: HostReceiptEvidence? = nil
    ) -> HostIntegrationSnapshot {
        HostIntegrationSnapshot(
            host: .workBuddy,
            runtime: .ready,
            availability: .available,
            configuration: configuration,
            writability: .writable,
            activation: activation,
            bindingActivations: bindingActivations,
            latestReceipt: latestReceipt,
            installationID: workBuddyVisualInstallationID)
    }

    private static func workBuddyImplementedBindingActivations(
        taskStart: HostActivationEvidence,
        stop: HostActivationEvidence,
        subagentStop: HostActivationEvidence,
        notification: HostActivationEvidence
    ) -> [HostEventBindingID: HostActivationEvidence] {
        [
            workBuddyVisualBinding(for: .taskStart).id: taskStart,
            workBuddyVisualBinding(for: .stop).id: stop,
            workBuddyVisualBinding(for: .subagentStop).id: subagentStop,
            workBuddyVisualBinding(for: .notification).id: notification,
        ]
    }

    private static func workBuddyVisualReceipt(
        event: Event,
        timestamp: TimeInterval
    ) -> HostReceiptEvidence {
        let binding = workBuddyVisualBinding(for: event)
        guard let nativeEvent = binding.nativeEvent else {
            preconditionFailure("WorkBuddy visual fixture requires a native event for \(event)")
        }
        return HostReceiptEvidence(
            bindingID: binding.id,
            installationID: workBuddyVisualInstallationID,
            nativeEvent: nativeEvent,
            event: event,
            timestamp: Date(timeIntervalSince1970: timestamp),
            playbackResult: .played)
    }

    private static func workBuddyVisualBinding(for event: Event) -> HostCapabilityBinding {
        guard
            let binding = HostCapabilityCatalog.binding(host: .workBuddy, event: event),
            binding.isAudibleCapability
        else {
            preconditionFailure("WorkBuddy visual fixture requires an implemented \(event) binding")
        }
        return binding
    }

    public static func assertExhaustive() -> Set<String> {
        var visited: Set<String> = []
        for row in eventRows { visited.insert("coverage.\(coverageStateCoverage(row.coverage))") }
        for card in packCards { visited.insert("packCard.\(packCardStateCoverage(card.state))") }
        for state in panelPackSectionStates {
            visited.insert("panelPack.\(panelPackSectionStateCoverage(state))")
        }
        for scenario in settingsRouteScenarios {
            visited.insert("settingsRoute.\(scenario.destination.rawValue)")
        }
        for scenario in settingsRouteFailureScenarios {
            visited.insert(
                "settingsRouteFailure.\(settingsRouteFailureCoverage(scenario.expectedFailure))")
        }
        for scenario in settingsExperienceScenarios {
            visited.insert("settingsExperience.\(scenario.rawValue)")
        }
        for scenario in aiCueGalleryScenarios {
            visited.insert("aiCueGallery.\(scenario.rawValue)")
        }
        for state in masterVolumeStates {
            visited.insert("masterVolume.\(masterVolumeStateCoverage(state))")
        }
        for scenario in hostIntegrationScenarios {
            visited.insert("hostIntegration.\(scenario.id)")
        }
        for scenario in workBuddyVisualScenarios {
            visited.insert("workBuddyVisual.\(scenario.id)")
        }
        return visited
    }

    /// Exhaustive over every visible Settings route failure. Adding a new failure case breaks
    /// this switch until the shared fixture catalog and gallery render it.
    static func settingsRouteFailureCoverage(_ failure: SettingsRouteFailure) -> String {
        switch failure {
        case .invalidSurface: "invalid-surface"
        case .staleSurface: "stale-surface"
        case .staleSoundScope: "stale-sound-scope"
        case .staleEvent: "stale-event"
        case .invalidSoundPackID: "invalid-sound-pack-id"
        case .staleSoundPack: "stale-sound-pack"
        }
    }

    /// Exhaustive over every ``CoverageState`` case — no `default:`.
    static func coverageStateCoverage(_ state: CoverageState) -> String {
        switch state {
        case .present: "present"
        case .unmapped: "unmapped"
        case .broken: "broken"
        }
    }

    /// Exhaustive over every ``PackCardState`` case — no `default:`.
    static func packCardStateCoverage(_ state: PackCardState) -> String {
        switch state {
        case .complete: "complete"
        case .partial: "partial"
        case .broken: "broken"
        }
    }

    static func panelPackSectionStateCoverage(_ state: PanelPackSectionState) -> String {
        switch state {
        case .loading: "loading"
        case .pinned(let cards): cards.count == 1 ? "pinned.one" : "pinned.four"
        case .noPinnedPacks: "noPinned"
        case .noPacks: "noPacks"
        case .readFailed: "readFailed"
        }
    }

    /// Exhaustive over every ``MasterVolumeState`` case — no `default:`.
    static func masterVolumeStateCoverage(_ state: MasterVolumeState) -> String {
        switch state {
        case .value: "value"
        case .failed: "failed"
        }
    }
}

#endif
