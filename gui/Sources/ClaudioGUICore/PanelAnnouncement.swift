import Combine
import Foundation

/// The operational dual-host panel no longer changes shape with Claude Code onboarding state.
/// Its opening/status announcement is therefore the already-composed panel header, normalized to
/// one spoken sentence here rather than reintroducing announcement policy in SwiftUI.
public func dualHostPanelAnnouncement(header: String) -> String? {
    joinSpokenClauses([header])
}

/// 一句话的合法终止符 —— 「正在接管…」以省略号结尾，不该再被补一个句号。
private let spokenTerminators: Set<Character> = ["。", "！", "？", "…"]

/// Join nonempty spoken clauses with one terminator; nil means there is nothing to post.
public func joinSpokenClauses(_ clauses: [String]) -> String? {
    let cleaned =
        clauses
        .map { clause -> String in
            var trimmed = clause
            while trimmed.hasSuffix("。") { trimmed.removeLast() }
            return trimmed
        }
        .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    let joined = cleaned.joined(separator: "。")
    guard let last = joined.last, spokenTerminators.contains(last) else { return joined + "。" }
    return joined
}

/// `next` 是不是「刚说完那句话的尾巴」—— 同一次打开里再 post 一遍，只会**打断**用户正在听的那一句。
public func panelAnnouncementIsRedundant(_ next: String, after previous: String) -> Bool {
    !previous.isEmpty && previous.hasSuffix(next)
}

/// Current operational-panel facts. The library state, rather than the failure text, identifies
/// one refresh-failure period; the visible notice still uses the shared presentation decision.
public struct PanelLibraryAnnouncementFacts: Sendable {
    public let header: String
    public let refreshFailedNotice: String
    public let topContent: PanelTopContent
    public let libraryState: SoundPackLibraryPresentationState
    public let panelIsVisible: Bool
    public let openCount: Int

    public init(
        header: String,
        refreshFailedNotice: String,
        topContent: PanelTopContent,
        libraryState: SoundPackLibraryPresentationState,
        panelIsVisible: Bool,
        openCount: Int
    ) {
        self.header = header
        self.refreshFailedNotice = refreshFailedNotice
        self.topContent = topContent
        self.libraryState = libraryState
        self.panelIsVisible = panelIsVisible
        self.openCount = openCount
    }
}

/// De-duplicates spoken suffixes within one opening and tracks each library-failure period.
/// Reopening may repeat the header; an already-announced failure stays silent until recovery.
@MainActor
public final class PanelAnnouncer: ObservableObject {
    private var lastOpenCount = -1
    private var lastAnnouncedOpeningOpenCount = -1
    private var lastSentence = ""
    private var refreshFailureIsActive = false
    private var refreshFailureWasAnnounced = false
    private var hasScheduledLibraryUpdate = false
    private var pendingOpeningAnnouncement = false
    private var libraryObservation: AnyCancellable?

    public init() {}

    /// Observe each publication, including a quick retry that leaves and re-enters the failure
    /// state before SwiftUI can deliver an `onChange` update.
    public func observeLibraryTransitions(
        from states: Published<SoundPackLibraryPresentationState>.Publisher,
        facts: @escaping @MainActor () -> PanelLibraryAnnouncementFacts,
        onAnnounce: @escaping @MainActor (String) -> Void
    ) {
        guard libraryObservation == nil else { return }
        libraryObservation = states.sink { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.observeRefreshFailure(state) else { return }
                self.scheduleLibraryUpdate(
                    opening: false, facts: facts, onAnnounce: onAnnounce)
            }
        }
    }

    /// 这一刻真正该 post 出去的那句话（`nil` = 不 post）。
    public func consume(_ candidate: String?, openCount: Int) -> String? {
        consume(candidate, openCount: openCount, allowRepeatedSentence: false)
    }

    /// Record the library transition even when the panel is hidden. A later failure can then be
    /// announced once after a successful read or retry has ended the previous failure period.
    /// Returns true only when a new failure period begins.
    @discardableResult
    public func observeRefreshFailure(_ libraryState: SoundPackLibraryPresentationState) -> Bool {
        let isFailed: Bool
        if case .refreshFailed = libraryState { isFailed = true } else { isFailed = false }
        guard isFailed != refreshFailureIsActive else { return false }
        refreshFailureIsActive = isFailed
        refreshFailureWasAnnounced = false
        return isFailed
    }

    /// The opening header and a newly visible refresh failure share one announcement. A second
    /// opening during the same failure still speaks the ordinary header, without repeating notice.
    public func consumeLibraryUpdate(
        _ facts: PanelLibraryAnnouncementFacts,
        opening: Bool
    ) -> String? {
        observeRefreshFailure(facts.libraryState)
        guard facts.panelIsVisible else { return nil }

        let includesNotice =
            panelShowsRefreshFailedNotice(
                topContent: facts.topContent,
                libraryState: facts.libraryState)
            && !refreshFailureWasAnnounced
        let candidate: String?
        if opening {
            candidate = joinSpokenClauses(
                [facts.header, includesNotice ? facts.refreshFailedNotice : nil].compactMap { $0 })
        } else {
            candidate = includesNotice ? joinSpokenClauses([facts.refreshFailedNotice]) : nil
        }
        // A new failure may have identical copy in the same opening. Its episode identity, not
        // text equality, decides whether it needs a new announcement.
        let sentence = consume(
            candidate,
            openCount: facts.openCount,
            allowRepeatedSentence: includesNotice && !opening)
        if sentence != nil && opening { lastAnnouncedOpeningOpenCount = facts.openCount }
        if sentence != nil && includesNotice { refreshFailureWasAnnounced = true }
        return sentence
    }

    /// SwiftUI can deliver the opening and library-state onChange handlers in either order. Queue
    /// one turn so both use the latest facts and produce one combined accessibility announcement.
    public func scheduleLibraryUpdate(
        opening: Bool,
        facts: @escaping @MainActor () -> PanelLibraryAnnouncementFacts,
        onAnnounce: @escaping @MainActor (String) -> Void
    ) {
        pendingOpeningAnnouncement = pendingOpeningAnnouncement || opening
        guard !hasScheduledLibraryUpdate else { return }
        hasScheduledLibraryUpdate = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let requestedOpening = self.pendingOpeningAnnouncement
                self.pendingOpeningAnnouncement = false
                self.hasScheduledLibraryUpdate = false
                let currentFacts = facts()
                // The library publisher can run after popoverDidShow but before SwiftUI delivers
                // showCount.onChange. Treat that unannounced show count as the opening; a later
                // onChange for the same count must not post a second, interrupting sentence.
                let opening =
                    currentFacts.openCount > self.lastAnnouncedOpeningOpenCount
                    && (requestedOpening || currentFacts.panelIsVisible)
                if let sentence = self.consumeLibraryUpdate(currentFacts, opening: opening) {
                    onAnnounce(sentence)
                }
            }
        }
    }

    private func consume(
        _ candidate: String?,
        openCount: Int,
        allowRepeatedSentence: Bool
    ) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        if !allowRepeatedSentence, openCount == lastOpenCount,
            panelAnnouncementIsRedundant(candidate, after: lastSentence)
        {
            return nil
        }
        lastOpenCount = openCount
        lastSentence = candidate
        return candidate
    }
}
