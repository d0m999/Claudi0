import Foundation

/// Desktop access is an explicit test input, never inferred from CI or the environment.
enum GUIHarnessMode: String, CaseIterable {
    case background, foreground, all

    var includesBackground: Bool { self != .foreground }
    var includesForeground: Bool { self != .background }
}

struct GUIHarnessSelection {
    let mode: GUIHarnessMode
    let selector: String?
    let dryRun: Bool

    var description: String {
        let scope = selector ?? "batch"
        return "GUI checks: \(mode.rawValue) \(scope)"
    }

    init(arguments: [String]) throws {
        let modes = arguments.filter { GUIHarnessMode(rawValue: String($0.dropFirst(2))) != nil }
        guard modes.count <= 1 else {
            throw SelectionError("Choose one of --background, --foreground, --all.")
        }
        mode =
            modes.first.flatMap { GUIHarnessMode(rawValue: String($0.dropFirst(2))) } ?? .background
        let selectors = arguments.filter { Self.selectors.contains($0) }
        guard selectors.count <= 1 else {
            throw SelectionError("Choose only one focused test selector.")
        }
        selector = selectors.first
        dryRun = arguments.contains("--dry-run")
        let known = Self.selectors.union([
            "--background", "--foreground", "--all", "--dry-run", "--minimal",
        ])
        if let unknown = arguments.first(where: { !known.contains($0) }) {
            throw SelectionError("Unknown test argument: \(unknown). Use --help.")
        }
        if mode == .all, selector != nil {
            throw SelectionError("--all runs both complete batches; omit the focused selector.")
        }
        if arguments.contains("--minimal"), selector != "--gui-baseline-regressions" {
            throw SelectionError("--minimal requires --gui-baseline-regressions.")
        }
        if let selector, Self.foregroundSelectors.contains(selector), !mode.includesForeground {
            throw SelectionError(
                "\(selector) uses visible windows or focus. Run with --foreground when the desktop is available."
            )
        }
    }

    struct SelectionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static var selectors: Set<String> { backgroundSelectors.union(foregroundSelectors) }

    // Keep focused routes explicit as well: a broad name may include a mounted native probe.
    static let backgroundSelectors: Set<String> = [
        "--harness-routing",
        "--bailian-regression", "--ai-cue-routing", "--app-motion", "--public-preview",
        "--sounds-redesign", "--sound-event-selection-lifecycle", "--event-row-sound-entry",
        "--integration-automation", "--question-intent", "--additional-hosts",
        "--question-integration-contract", "--view-wiring", "--event-stack",
        "--zed-managed-navigation", "--zed-source-navigation", "--ai-cue-assets",
        "--user-sound-pack-deletion", "--sound-window-accessibility",
        "--sound-editor-import-results", "--sound-editor-interface", "--sound-editor-focus",
        "--settings-sounds-publications", "--sound-editor-detail-identity",
        "--event-settings-retry",
        "--workspace-sounds", "--system-sounds", "--ai-cue-local-credentials",
        "--bailian-local-credentials", "--ai-cue-pack-scoped", "--ai-cue-transports",
        "--ai-cue-provider-contracts", "--senseaudio-provider", "--shared-write-contracts",
        "--menu-bar-composition", "--panel-announcement", "--release-layout",
        "--surface-sound-issue", "--panel-error-copy", "--five-page-settings",
        "--settings-sidebar-backing",
    ]

    static let foregroundSelectors: Set<String> = [
        "--first-run-native-render", "--first-run-native", "--ai-cue-gallery",
        "--review-findings", "--gui-baseline-regressions", "--sounds-review-recovery",
        "--integration-automation-native", "--settings-notification-navigation",
        "--settings-navigation-native-focus", "--workspace-deletion-native-focus",
        "--ai-cue-native-focus", "--sound-editor-ai-lifecycle", "--settings-native-states",
        "--event-notice-reader", "--event-notice-presentation-live", "--event-notice-presentation",
        "--hit-targets", "--event-modal-lifecycle", "--event-reading-live", "--event-animation",
        "--event-animation-layout", "--review-repairs", "--focus-scope-review", "--event-reader",
        "--event-stack-motion-native", "--event-stack-native", "--event-attention",
        "--panel-settings-handback", "--settings-lifecycle", "--ai-cue-generation",
        "--senseaudio-isolation", "--settings-product-images", "--settings-menu-layout",
        "--settings-sounds-layout", "--settings-sounds-sheet-layout", "--mounted-panel-contracts",
        "--mounted-lifecycle-contracts", "--native-regression-composition",
        "--settings-polish-native", "--five-page-settings-native", "--five-page-forms-native",
        "--settings-navigation-core", "--settings-review-repairs", "--settings-scope-pickers",
        "--ci-native-regressions", "--settings-native-alignment", "--settings-native-regressions",
    ]
}

/// Both batches are awaited serially. Background success never implies foreground coverage.
@MainActor
func executeGUIHarnessBatches(
    mode: GUIHarnessMode,
    background: @MainActor () async -> Void,
    foreground: @MainActor () async -> Void
) async {
    if mode.includesBackground { await background() }
    if mode.includesForeground { await foreground() }
}
