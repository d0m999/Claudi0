import ClaudioCore
import Combine
import Dispatch
import Foundation

public enum EventNoticePresentationPhase: String, Codable, Sendable, Equatable {
    case hidden
    case entering
    case visible
    case exiting
}

public struct EventNoticePauseReason: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let hover = Self(rawValue: 1 << 0)
    public static let keyboardFocus = Self(rawValue: 1 << 1)
    public static let windowFocus = Self(rawValue: 1 << 2)
    public static let queueExpansion = Self(rawValue: 1 << 3)
    public static let modal = Self(rawValue: 1 << 4)
}

public enum EventNoticeRecordStatus: String, Codable, Sendable, Equatable {
    case queued
    case displayed
    case collapsed
}

/// One immutable source payload per version, shared by live and frozen projections. This is
/// not another owner or cache: erasing every retained reference releases the source together.
fileprivate final class EventNoticeContent: Sendable, Equatable {
    private enum Payload: Sendable, Equatable {
        case hook(HostEventNotice)
        case developmentObservation(CodexQuestionObservation)
    }

    private let payload: Payload
    let sourceApplication: SourceApplicationTarget?
    let navigationTarget: SessionNavigationTarget?

    init(_ notice: HostEventNotice, sourceApplication: SourceApplicationTarget? = nil) {
        payload = .hook(notice.removingProcessAncestors())
        self.sourceApplication = sourceApplication
        navigationTarget = HostSessionTargetResolver.resolve(notice, application: sourceApplication)
    }
    init(_ observation: CodexQuestionObservation) {
        payload = .developmentObservation(observation)
        sourceApplication = nil
        navigationTarget = nil
    }

    var notice: HostEventNotice? {
        guard case .hook(let notice) = payload else { return nil }
        return notice
    }

    var provenance: EventNoticeProvenance {
        switch payload {
        case .hook: .hostHook
        case .developmentObservation: .developmentCodexRollout
        }
    }

    var host: HostID? {
        switch payload {
        case .hook(let notice): notice.host
        case .developmentObservation: .codex
        }
    }

    var source: HostEventSource? {
        switch payload {
        case .hook(let notice): notice.source
        case .developmentObservation(let observation):
            HostEventSource(projectLabel: nil, sessionID: observation.sessionID)
        }
    }

    var reason: HostEventNoticeReason? {
        switch payload {
        case .hook(let notice): notice.reason
        case .developmentObservation: .questionIntent
        }
    }

    var occurredAt: Date {
        switch payload {
        case .hook(let notice): notice.occurredAt
        case .developmentObservation(let observation): observation.occurredAt
        }
    }

    static func == (lhs: EventNoticeContent, rhs: EventNoticeContent) -> Bool {
        lhs === rhs
            || (lhs.payload == rhs.payload && lhs.sourceApplication == rhs.sourceApplication
                && lhs.navigationTarget == rhs.navigationTarget)
    }
}

/// A notice record is a presentation record, not a receipt or activity fact. `notice` becomes
/// nil when its short privacy TTL expires; the event and safe focus identity may remain so the
/// current control does not jump underneath a user.
public struct EventNoticeRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: Event
    public let occurredAt: Date?
    fileprivate let content: EventNoticeContent?
    public var notice: HostEventNotice? { content?.notice }
    public var provenance: EventNoticeProvenance? { content?.provenance }
    public var host: HostID? { content?.host }
    public var reason: HostEventNoticeReason? { content?.reason }
    public var sourceApplication: SourceApplicationTarget? { content?.sourceApplication }
    public var navigationTarget: SessionNavigationTarget? { content?.navigationTarget }
    public let status: EventNoticeRecordStatus
    public let isExpired: Bool
    public let version: UInt64
    public let isActionable: Bool
    /// A newer attention revision replaced this record, independent of action availability.
    public let isSuperseded: Bool
    public let kind: EventNoticeKind
    public var action: EventNoticeAction? {
        guard let notice else { return nil }
        return EventNoticeAction(
            id: id, version: version, epoch: notice.receiverEpoch,
            installationID: notice.installationID)
    }

    public var source: HostEventSource? { content?.source }
    public var sessionID: String? { source?.sessionID }

    public init(
        id: UUID,
        event: Event,
        occurredAt: Date?,
        notice: HostEventNotice?,
        status: EventNoticeRecordStatus,
        isExpired: Bool,
        version: UInt64 = 1,
        isActionable: Bool = true,
        isSuperseded: Bool = false,
        kind: EventNoticeKind = .transient,
        sourceApplication: SourceApplicationTarget? = nil
    ) {
        self.init(
            id: id, event: event, occurredAt: occurredAt,
            content: notice.map { EventNoticeContent($0, sourceApplication: sourceApplication) },
            status: status,
            isExpired: isExpired, version: version, isActionable: isActionable,
            isSuperseded: isSuperseded, kind: kind)
    }

    fileprivate init(
        id: UUID, event: Event, occurredAt: Date?, content: EventNoticeContent?,
        status: EventNoticeRecordStatus, isExpired: Bool, version: UInt64,
        isActionable: Bool, isSuperseded: Bool, kind: EventNoticeKind
    ) {
        self.id = id
        self.event = event
        self.occurredAt = occurredAt
        self.content = content
        self.status = status
        self.isExpired = isExpired
        self.version = version
        self.isActionable = isActionable
        self.isSuperseded = isSuperseded
        self.kind = kind
    }
}

public struct EventNoticeModelSnapshot: Sendable, Equatable {
    public let phase: EventNoticePresentationPhase
    public let current: EventNoticeRecord?
    public let attentionReminders: [EventNoticeRecord]
    public let pendingCount: Int
    public let pauseReasons: EventNoticePauseReason
    public let remainingTime: TimeInterval?
    public let readingTime: EventNoticeReadingTime?
    public let isExpanded: Bool
    public let isDetail: Bool
    public let totalCount: Int
    public var needsRefresh: Bool {
        pendingCount > 0 || attentionReminders.contains { !$0.isActionable }
    }
    public let droppedCount: Int
    public let receiverEpoch: UUID

    public init(
        phase: EventNoticePresentationPhase,
        current: EventNoticeRecord?,
        attentionReminders: [EventNoticeRecord],
        pendingCount: Int,
        pauseReasons: EventNoticePauseReason,
        remainingTime: TimeInterval?,
        isExpanded: Bool,
        droppedCount: Int,
        receiverEpoch: UUID,
        isDetail: Bool = false,
        totalCount: Int = 0,
        readingTime: EventNoticeReadingTime? = nil
    ) {
        self.phase = phase
        self.current = current
        self.attentionReminders = attentionReminders
        self.pendingCount = pendingCount
        self.pauseReasons = pauseReasons
        self.remainingTime = remainingTime
        self.readingTime = readingTime
        self.isExpanded = isExpanded
        self.isDetail = isDetail
        self.totalCount = totalCount
        self.droppedCount = droppedCount
        self.receiverEpoch = receiverEpoch
    }
}

public enum EventNoticeAcceptance: Sendable, Equatable {
    case accepted
    case ignoredDisabled
    case staleEpoch
    case duplicate
    case invalid
    case droppedCapacity
    case staleObservation
}

/// The scheduler is injected so countdown and stale-callback behavior can be tested without
/// sleeping. Production uses one cancellable DispatchSourceTimer per model timer.
public struct EventNoticeScheduler {
    private let scheduleClosure:
        @MainActor (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> EventNoticeCancellation

    public init(
        schedule:
            @escaping @MainActor (
                TimeInterval,
                @escaping @MainActor () -> Void
            ) -> EventNoticeCancellation
    ) {
        scheduleClosure = schedule
    }

    @MainActor
    public func schedule(
        after delay: TimeInterval,
        _ callback: @escaping @MainActor () -> Void
    ) -> EventNoticeCancellation {
        scheduleClosure(max(0, delay), callback)
    }

    @MainActor public static let live = Self { delay, callback in
        // Cancelling asyncAfter's work item can retain its closure until the old deadline.
        // A source timer releases that pending handler on cancellation, including a 30min TTL.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler {
            timer.setEventHandler(handler: nil)
            timer.cancel()
            MainActor.assumeIsolated { callback() }
        }
        timer.resume()
        return EventNoticeCancellation {
            timer.setEventHandler(handler: nil)
            timer.cancel()
        }
    }
}

public final class EventNoticeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: () -> Void
    private var isCancelled = false

    public init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        cancellation()
    }
}

public enum EventNoticeKind: Sendable, Equatable {
    case transient, permission, needsInput, interrupted, review

    /// Attention kinds are retained as versioned reminders; transient is display-only.
    public var isAttention: Bool { self != .transient }

    public static func classify(_ notice: HostEventNotice) -> Self {
        switch notice.event {
        case .taskStart, .stop, .subagentStop: return .transient
        case .stopFailure: return .interrupted
        case .notification:
            switch notice.reason {
            case .permission: return .permission
            case .needsInput: return .needsInput
            case .informational, .questionIntent: return .transient
            case .review, nil: return .review
            }
        }
    }
}

/// The exact version the user saw. It contains no display/source strings.
public struct EventNoticeAction: Sendable, Equatable, Hashable {
    public let id: UUID
    public let version: UInt64
    public let epoch: UUID
    public let installationID: UUID

    public init(id: UUID, version: UInt64, epoch: UUID, installationID: UUID) {
        self.id = id
        self.version = version
        self.epoch = epoch
        self.installationID = installationID
    }
}

public enum EventNoticeRemovalReason: Sendable, Equatable {
    case userRemoved, exactReturnConfirmed, subsequentSubmission, expired, capacity, privacy
}

public enum EventNoticeActionOutcome: Sendable, Equatable {
    case applied, stale, unavailable
}

public struct EventNoticePrivacyReason: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let screenLocked = Self(rawValue: 1 << 0)
    public static let sleeping = Self(rawValue: 1 << 1)
    public static let inactiveSession = Self(rawValue: 1 << 2)
}

public struct EventNoticeResourceUsage: Sendable, Equatable {
    public let latestVersions: Int
    public let readingVersions: Int
    public let transientVersions: Int
    public let deduplicationEntries: Int
    public let observationEntries: Int
    public let timers: Int
}

/// Sole owner of reminders, reading versions, lifecycle and deadlines. Views only consume
/// immutable snapshots and return versioned actions. No source data is persisted.
@MainActor
public final class EventNoticeModel: ObservableObject {
    public static let displayDuration: TimeInterval = 4
    public static let fadeDuration: TimeInterval = 0.18
    public static let retentionDuration: TimeInterval = 30 * 60
    public static let maximumAttentionReminderCount = 50
    public static let maximumMetadataCount = 256
    public static let maximumBannerCount = 50
    public static let maximumVisibleBannerCount = 3

    @Published public private(set) var snapshot: EventNoticeModelSnapshot
    /// Compatibility projection for old readers; production presentation uses stackSnapshot.
    @Published public private(set) var bannerSnapshot: EventNoticeModelSnapshot
    @Published public private(set) var stackSnapshot: EventNoticeStackSnapshot
    @Published public private(set) var readingSnapshot: EventNoticeReadingSnapshot
    @Published public private(set) var badgeCount = 0
    public private(set) var receiverEpoch: UUID
    public private(set) var isEnabled = true
    public private(set) var privacyReasons: EventNoticePrivacyReason = []
    public private(set) var isAutomaticallySuppressed = false
    public private(set) var lastRemovalReason: EventNoticeRemovalReason?
    public var resourceUsage: EventNoticeResourceUsage {
        var readingVersions = 0
        for entry in frozen where entry.content != nil { readingVersions += 1 }
        return EventNoticeResourceUsage(
            latestVersions: entries.count, readingVersions: readingVersions,
            transientVersions: (presentations + exitingPresentations).filter {
                $0.entry.kind == .transient && $0.entry.content != nil
            }.count,
            deduplicationEntries: seen.count, observationEntries: observations.count,
            timers: (presentationTimer == nil ? 0 : 1) + (expiryTimer == nil ? 0 : 1)
                + (badgeTimer == nil ? 0 : 1) + (presentationCommitTimer == nil ? 0 : 1))
    }
    public var canReceive: Bool { isEnabled && privacyReasons.isEmpty }

    private struct Identity: Equatable {
        let epoch: UUID
        let surface: HostSurfaceID
        let installation: UUID
        let project: Data
        let session: Data

        // Byte-exact Data comparisons otherwise expand at every lookup closure under -Osize.
        // Keep one comparison body; String equality would merge canonically equivalent IDs.
        @inline(never)
        static func == (lhs: Identity, rhs: Identity) -> Bool {
            lhs.epoch == rhs.epoch && lhs.surface == rhs.surface
                && lhs.installation == rhs.installation
                && lhs.project == rhs.project && lhs.session == rhs.session
        }

        init?(_ notice: HostEventNotice) {
            guard let source = notice.source, !source.isParentSession,
                source.mainSessionIsKnown == true,
                source.completeness == .complete, let project = source.projectKey,
                let session = source.sessionID, notice.event != .subagentStop
            else { return nil }
            epoch = notice.receiverEpoch
            surface = notice.surface
            installation = notice.installationID
            self.project = Data(project.utf8)
            self.session = Data(session.utf8)
        }
    }

    /// Live and frozen lists share a version handle. Only this model may erase its source;
    /// a replacement always creates a new handle, so older reading versions keep their TTL.
    private final class Entry {
        let id: UUID
        let version: UInt64
        let event: Event
        let kind: EventNoticeKind
        let expiresAt: TimeInterval
        var content: EventNoticeContent?
        var identity: Identity?
        var isSuperseded = false
        init(
            id: UUID, version: UInt64, event: Event, kind: EventNoticeKind,
            expiresAt: TimeInterval, content: EventNoticeContent?, identity: Identity?
        ) {
            self.id = id
            self.version = version
            self.event = event
            self.kind = kind
            self.expiresAt = expiresAt
            self.content = content
            self.identity = identity
        }
        var notice: HostEventNotice? { content?.notice }
        var action: EventNoticeAction? {
            guard let notice else { return nil }
            return EventNoticeAction(
                id: id, version: version, epoch: notice.receiverEpoch,
                installationID: notice.installationID)
        }
        func matches(_ action: EventNoticeAction) -> Bool {
            guard id == action.id, version == action.version, let notice else { return false }
            return notice.receiverEpoch == action.epoch
                && notice.installationID == action.installationID
        }
        func erase() {
            content = nil
            identity = nil
        }
    }

    @MainActor
    private final class Presentation {
        let id = UUID()
        var entry: Entry
        var phase: EventNoticePresentationPhase = .hidden
        var remaining: TimeInterval = EventNoticeModel.displayDuration
        var deadline: TimeInterval?
        var entrance: EventNoticeMotionPlan?
        var relocation: EventNoticeMotionPlan?
        var exit: EventNoticeMotionPlan?
        var retiredRecord: EventNoticeRecord?
        var hasPresented = false
        var hasMeasuredPosition = false
        var positionY: Double = 0
        var layerIndex = 0

        init(_ entry: Entry) { self.entry = entry }
    }

    private struct Observation {
        let identity: Identity
        let uptime: TimeInterval
        let expiresAt: TimeInterval
    }

    private enum SeenIdentity: Equatable {
        case hook(UUID)
        case development(runID: UUID, session: Data, request: Data)

        var isDevelopment: Bool {
            if case .development = self { return true }
            return false
        }
    }

    private let now: @MainActor () -> TimeInterval
    private let scheduler: EventNoticeScheduler
    private let resolveSourceApplication:
        @MainActor ([HostProcessIdentity], EventNoticeAction) -> SourceApplicationTarget?
    /// Empty in production. Only adapters with real submission-order evidence may opt in.
    private let noticeAuthorized: @MainActor (HostEventNotice) -> Bool
    private let verifiedSubmissionSurfaces: Set<HostSurfaceID>
    private var epochStartedAt: TimeInterval
    private var entries: [Entry] = []  // oldest update first
    private var frozen: [Entry] = []  // complete reading versions, newest first
    private var presentations: [Presentation] = []  // FIFO, visible prefix then waiting
    private var exitingPresentations: [Presentation] = []
    private var visibleCapacity = EventNoticeModel.maximumVisibleBannerCount
    private var measuredPresentations: Set<UUID>?
    private var visibleCount: Int {
        guard let measuredPresentations else { return min(visibleCapacity, presentations.count) }
        return presentations.prefix(visibleCapacity).prefix {
            measuredPresentations.contains($0.id)
        }.count
    }
    private var isQueueExpanded = false
    private var queueOpenedAt: TimeInterval?
    private var displayOverflowCount = 0
    private var capacityHintCount = 0
    private var presentationCommitTimer: EventNoticeCancellation?
    private var presentationCommitID: UUID?
    private var presentationDeadline: TimeInterval?
    private var readingConsumers: Set<EventNoticeReadingConsumer> = []
    private var readingSelection: EventNoticeAction?
    private var protectedAction: EventNoticeAction?
    private var seen: [(id: SeenIdentity, expiresAt: TimeInterval)] = []
    private var observations: [Observation] = []
    private var developmentObservationRun: UUID?
    private var developmentObservationStartedAt: TimeInterval?
    private var pauseReasons: EventNoticePauseReason = []
    private var isExpanded = false
    private var isDetail = false
    private var usesReducedMotion = false
    private var presentationTimer: EventNoticeCancellation?
    private var expiryTimer: EventNoticeCancellation?
    private var badgeTimer: EventNoticeCancellation?
    private var presentationRevision: UInt64 = 0
    private var expiryRevision: UInt64 = 0
    private var badgeRevision: UInt64 = 0
    private var expiryDeadline: TimeInterval?
    private var droppedCount = 0
    private var isReducingBatch = false
    private var owesImmediateBadge = false

    public init(
        receiverEpoch: UUID,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: EventNoticeScheduler = .live,
        verifiedSubmissionSurfaces: Set<HostSurfaceID> = [],
        noticeAuthorized: @escaping @MainActor (HostEventNotice) -> Bool = { _ in true },
        resolveSourceApplication:
            @escaping @MainActor ([HostProcessIdentity], EventNoticeAction) ->
            SourceApplicationTarget? = { _, _ in nil }
    ) {
        self.receiverEpoch = receiverEpoch
        self.now = now
        self.scheduler = scheduler
        self.resolveSourceApplication = resolveSourceApplication
        self.verifiedSubmissionSurfaces = verifiedSubmissionSurfaces
        self.noticeAuthorized = noticeAuthorized
        epochStartedAt = now()
        let initialSnapshot = EventNoticeModelSnapshot(
            phase: .hidden, current: nil, attentionReminders: [], pendingCount: 0,
            pauseReasons: [],
            remainingTime: nil, isExpanded: false, droppedCount: 0, receiverEpoch: receiverEpoch)
        snapshot = initialSnapshot
        bannerSnapshot = initialSnapshot
        stackSnapshot = EventNoticeStackSnapshot(receiverEpoch: receiverEpoch)
        readingSnapshot = EventNoticeReadingSnapshot(
            records: [], pendingCount: 0, droppedCount: 0,
            receiverEpoch: receiverEpoch, isOpen: false)
    }

    public func isNoticeAuthorized(_ notice: HostEventNotice) -> Bool { noticeAuthorized(notice) }

    /// OFF removes all display frames from this source. Accepted Attention and frozen reading
    /// versions retain their own TTL and explicit navigation capability (ADR 0025).
    public func hideBanner(for surface: HostSurfaceID) {
        presentations.removeAll { $0.entry.notice?.surface == surface }
        exitingPresentations.removeAll { $0.entry.notice?.surface == surface }
        reconcilePresentation()
        publish()
    }

    private func isVerifiedSubmissionStart(_ notice: HostEventNotice) -> Bool {
        notice.event == .taskStart && verifiedSubmissionSurfaces.contains(notice.surface)
    }

    @discardableResult
    public func accept(_ notice: HostEventNotice) -> EventNoticeAcceptance {
        guard noticeAuthorized(notice) else { return .ignoredDisabled }
        expireEntries()
        defer { publish() }
        guard canReceive else { return .ignoredDisabled }
        guard notice.receiverEpoch == receiverEpoch else { return .staleEpoch }
        guard notice.isSemanticallyValid, let host = notice.host,
            HostCapabilityCatalog.binding(host: host, nativeEvent: notice.nativeEvent)?
                .isAudibleCapability == true
        else { return .invalid }
        guard !seen.contains(where: { $0.id == .hook(notice.id) }),
            !entries.contains(where: { $0.content?.notice?.id == notice.id }),
            !frozen.contains(where: { $0.content?.notice?.id == notice.id }),
            !presentations.contains(where: { $0.entry.notice?.id == notice.id }),
            !exitingPresentations.contains(where: { $0.entry.notice?.id == notice.id })
        else { return .duplicate }
        seen.append((.hook(notice.id), now() + Self.retentionDuration))
        if seen.count > Self.maximumMetadataCount { seen.removeFirst() }

        let kind = EventNoticeKind.classify(notice)
        let identity = Identity(notice)
        let existingIndex = identity.flatMap { index(for: $0) }
        let existing =
            existingIndex.map { entries[$0] }
            ?? (kind.isAttention
                ? identity.flatMap { identity in
                    presentations.first {
                        $0.entry.kind.isAttention && $0.entry.identity == identity
                    }?.entry
                } : nil)
        let observation = validObservation(notice)
        let requiresOrderedObservation =
            kind.isAttention
            || isVerifiedSubmissionStart(notice)
        if let identity, requiresOrderedObservation {
            let metadataTime = observations.first(where: { $0.identity == identity })?.uptime
            let latestTime = existing?.notice.flatMap(validObservation)
            let previousObservation = [metadataTime, latestTime].compactMap { $0 }.max()
            if let observation, let previousObservation, observation <= previousObservation {
                return .staleObservation
            }
            if let observation {
                observations.removeAll { $0.identity == identity }
                observations.append(
                    Observation(
                        identity: identity, uptime: observation,
                        expiresAt: now() + Self.retentionDuration))
                if observations.count > Self.maximumMetadataCount { observations.removeFirst() }
            } else if previousObservation != nil {
                return .staleObservation
            }
        }

        if isVerifiedSubmissionStart(notice),
            identity != nil, let observation,
            let previous = existing,
            let previousNotice = previous.notice,
            let previousTime = validObservation(previousNotice),
            observation > previousTime, let action = previous.action
        {
            _ = remove(action, reason: .subsequentSubmission)
        }

        if kind == .transient {
            return enqueue(makeEntry(notice, kind: kind, identity: identity))
                ? .accepted : .droppedCapacity
        }

        if let previous = existing, previous.version == UInt64.max {
            droppedCount = saturatedIncrement(droppedCount)
            return .droppedCapacity
        }
        if existingIndex == nil, entries.count >= Self.maximumAttentionReminderCount {
            guard
                let index = entries.firstIndex(where: { candidate in
                    !presentations.prefix(visibleCount).contains {
                        $0.entry.id == candidate.id
                    } && candidate.id != protectedAction?.id
                        && candidate.id != readingSelection?.id
                })
            else {
                droppedCount = saturatedIncrement(droppedCount)
                return .droppedCapacity
            }
            eraseReadingVersion(id: entries[index].id)
            entries.remove(at: index)
            droppedCount = saturatedIncrement(droppedCount)
            lastRemovalReason = .capacity
        }
        let entry: Entry
        if let previous = existing {
            if let index = existingIndex { entries.remove(at: index) }
            previous.isSuperseded = true
            entry = makeEntry(
                notice, kind: kind, identity: identity, id: previous.id,
                version: previous.version + 1)
        } else {
            entry = makeEntry(notice, kind: kind, identity: identity)
        }
        entries.append(entry)
        // Reminder admission is independent of display overflow.
        _ = enqueue(entry)
        return .accepted
    }

    /// The explicit development observer registers one run in the current privacy epoch.
    /// Changing that run clears only development metadata and its transient display.
    public func setDevelopmentObservationRun(_ runID: UUID?) {
        guard developmentObservationRun != runID else { return }
        developmentObservationRun = canReceive ? runID : nil
        developmentObservationStartedAt = developmentObservationRun == nil ? nil : now()
        seen.removeAll { $0.id.isDevelopment }
        presentations.removeAll { $0.entry.content?.provenance == .developmentCodexRollout }
        exitingPresentations.removeAll { $0.entry.content?.provenance == .developmentCodexRollout }
        reconcilePresentation()
        publish()
    }

    /// In-process development evidence never enters the hook validator, receipts or Attention.
    @discardableResult
    public func acceptDevelopmentObservation(_ observation: CodexQuestionObservation)
        -> EventNoticeAcceptance
    {
        expireEntries()
        defer { publish() }
        guard canReceive else { return .ignoredDisabled }
        guard observation.runID == developmentObservationRun,
            let startedAt = developmentObservationStartedAt
        else { return .staleEpoch }
        guard observation.observedUptime.isFinite,
            observation.observedUptime >= max(startedAt, epochStartedAt),
            observation.observedUptime <= now(), observation.observedUptime > 0,
            observation.occurredAt.timeIntervalSince1970.isFinite
        else { return .staleObservation }
        let request = Data(observation.requestID.utf8)
        guard observation.sessionID.utf8.count == 36,
            UUID(uuidString: observation.sessionID)?.uuidString.lowercased()
                == observation.sessionID,
            (1...256).contains(request.count),
            request.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 58, 95].contains($0)
            })
        else { return .invalid }
        let identity = SeenIdentity.development(
            runID: observation.runID, session: Data(observation.sessionID.utf8), request: request)
        guard !seen.contains(where: { $0.id == identity }) else { return .duplicate }
        seen.append((identity, now() + Self.retentionDuration))
        if seen.count > Self.maximumMetadataCount { seen.removeFirst() }
        if !isAutomaticallySuppressed {
            let entry = Entry(
                id: UUID(), version: 1, event: .notification, kind: .transient,
                expiresAt: now() + Self.retentionDuration,
                content: EventNoticeContent(observation), identity: nil)
            return enqueue(entry) ? .accepted : .droppedCapacity
        }
        return .accepted
    }

    /// One bounded reduction for runtime ingress; unconsumed messages stay in the mailbox.
    @discardableResult
    public func acceptBatch(_ notices: [HostEventNotice]) -> [EventNoticeAcceptance] {
        var results: [EventNoticeAcceptance] = []
        let started = ProcessInfo.processInfo.systemUptime
        isReducingBatch = true
        for notice in notices.prefix(32) {
            results.append(accept(notice))
            if ProcessInfo.processInfo.systemUptime - started >= 0.004 { break }
        }
        isReducingBatch = false
        if !results.isEmpty { publish() }
        return results
    }

    @discardableResult
    public func accept<S: Sequence>(contentsOf notices: S) -> [EventNoticeAcceptance]
    where S.Element == HostEventNotice {
        var results: [EventNoticeAcceptance] = []
        var buffer: [HostEventNotice] = []
        func reduceBuffer() {
            while !buffer.isEmpty {
                let reduced = acceptBatch(buffer)
                results.append(contentsOf: reduced)
                buffer.removeFirst(reduced.count)
            }
        }
        for notice in notices {
            buffer.append(notice)
            if buffer.count == 32 { reduceBuffer() }
        }
        reduceBuffer()
        return results
    }

    public func setHovering(_ value: Bool) { setPauseReason(.hover, active: value) }
    public func setKeyboardFocused(_ value: Bool) { setPauseReason(.keyboardFocus, active: value) }
    public func setExpanded(_ value: Bool) {
        value ? openAttentionReminders() : closeAttentionReminders()
    }

    public func openReading(_ consumer: EventNoticeReadingConsumer) {
        guard canReceive else { return }
        expireEntries()
        if readingConsumers.isEmpty { frozen = entries.reversed() }
        readingConsumers.insert(consumer)
        publish(immediateBadge: true)
    }

    public func closeReading(_ consumer: EventNoticeReadingConsumer) {
        readingConsumers.remove(consumer)
        if readingConsumers.isEmpty { frozen.removeAll(); readingSelection = nil }
        publish()
    }

    public func refreshReading() {
        guard !readingConsumers.isEmpty else { return }
        expireEntries()
        frozen = entries.reversed()
        readingSelection = nil
        publish()
    }

    /// Detail resolves a frozen reminder or a live display-only entry, without retaining
    /// ordinary progress in the attention list or creating a second content owner.
    public func readingRecord(for action: EventNoticeAction) -> EventNoticeRecord? {
        guard action.epoch == receiverEpoch else { return nil }
        if let record = readingSnapshot.records.first(where: {
            $0.id == action.id && $0.version == action.version
        }) {
            return record
        }
        guard let presentation = presentations.first(where: { $0.entry.matches(action) }),
            isCurrent(action)
        else { return nil }
        return record(presentation.entry)
    }

    public func openAttentionReminders() {
        isExpanded = true
        isDetail = false
        openReading(.legacy)
    }

    public func closeAttentionReminders() {
        isExpanded = false
        isDetail = false
        readingSelection = nil
        closeReading(.legacy)
    }

    public func refreshAttentionReminders() {
        isDetail = false
        refreshReading()
    }

    @discardableResult
    public func viewSource(_ action: EventNoticeAction) -> EventNoticeActionOutcome {
        expireEntries()
        guard actionableEntry(action) != nil else { publish(); return .stale }
        openAttentionReminders()
        readingSelection = action
        isDetail = true
        publish()
        return .applied
    }

    public func closeDetail() {
        isDetail = false
        readingSelection = nil
        publish()
    }

    public func selectAttentionReminder(id: UUID) {
        guard let record = readingSnapshot.records.first(where: { $0.id == id }),
            let action = record.action
        else { return }
        _ = viewSource(action)
    }

    public func isCurrent(_ action: EventNoticeAction) -> Bool {
        actionableEntry(action) != nil
    }

    /// True when the action still resolves to a live attention reminder (not the transient slot).
    func isAttentionReminder(_ action: EventNoticeAction) -> Bool {
        entries.contains { $0.matches(action) && $0.kind.isAttention }
    }

    public func sourceNotice(for action: EventNoticeAction) -> HostEventNotice? {
        actionableEntry(action)?.notice
    }

    public func navigationTarget(for action: EventNoticeAction) -> SessionNavigationTarget? {
        actionableEntry(action)?.content?.navigationTarget
    }

    public func sourceApplication(for action: EventNoticeAction) -> SourceApplicationTarget? {
        actionableEntry(action)?.content?.sourceApplication
    }

    public func protect(_ action: EventNoticeAction?) {
        protectedAction = action.flatMap { isCurrent($0) ? $0 : nil }
    }

    @discardableResult
    public func remove(_ action: EventNoticeAction, reason: EventNoticeRemovalReason = .userRemoved)
        -> EventNoticeActionOutcome
    {
        expireEntries()
        guard
            reason == .userRemoved || reason == .exactReturnConfirmed
                || reason == .subsequentSubmission,
            isCurrent(action), let index = entries.firstIndex(where: { $0.matches(action) })
        else { publish(); return .stale }
        dismissBanner(action: action)
        entries.remove(at: index)
        eraseReadingVersion(id: action.id)
        if protectedAction == action { protectedAction = nil }
        lastRemovalReason = reason
        publish(immediateBadge: true)
        return .applied
    }

    @discardableResult
    public func copySessionID(_ action: EventNoticeAction, write exportSessionID: (String) -> Bool)
        -> Bool
    {
        expireEntries()
        defer { publish() }
        guard let session = actionableEntry(action)?.notice?.source?.sessionID else { return false }
        return exportSessionID(session)
    }

    /// The compatibility close entry point now means Escape: clear display and waiting only.
    public func dismiss(animated: Bool = true) { dismissStack(animated: animated) }

    public func containsPresentation(_ id: UUID) -> Bool {
        presentations.contains { $0.id == id && $0.phase != .hidden }
    }

    public func presentationID(for action: EventNoticeAction) -> UUID? {
        presentations.first { $0.entry.matches(action) }?.id
    }

    public func dismissBanner(action: EventNoticeAction, animated: Bool = true) {
        guard let id = presentationID(for: action) else { return }
        dismissBanner(id: id, animated: animated)
    }

    public func dismissBanner(id: UUID, animated: Bool = true) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        let captured = record(presentations[index].entry)
        let item = presentations.remove(at: index)
        beginExit(item, animated: animated, captured: captured)
        reconcilePresentation()
        publish()
    }

    public func dismissStack(animated: Bool = true) {
        let previous = presentations.map { ($0, record($0.entry)) }
        presentations.removeAll()
        for (item, captured) in previous { beginExit(item, animated: animated, captured: captured) }
        isQueueExpanded = false
        queueOpenedAt = nil
        pauseReasons = []
        capacityHintCount = 0
        reconcilePresentation()
        publish()
    }

    public func hideImmediately() {
        presentations.removeAll()
        exitingPresentations.removeAll()
        if measuredPresentations != nil { measuredPresentations = [] }
        invalidatePresentationCommit()
        isQueueExpanded = false
        queueOpenedAt = nil
        pauseReasons = []
        capacityHintCount = 0
        invalidatePresentationTimer()
        publish()
    }

    public func setQueueExpanded(_ value: Bool) {
        let expanded = value && presentations.count > visibleCount
        guard isQueueExpanded != expanded else { return }
        isQueueExpanded = expanded
        queueOpenedAt = expanded ? now() : nil
        setPauseReason(.queueExpansion, active: expanded)
    }

    public func setVisibleCapacity(_ value: Int, measuredIDs: Set<UUID>? = nil) {
        let capacity = min(Self.maximumVisibleBannerCount, max(0, value))
        let measurementsChanged = measuredIDs.map { $0 != measuredPresentations } ?? false
        guard visibleCapacity != capacity || measurementsChanged else { return }
        visibleCapacity = capacity
        if let measuredIDs { measuredPresentations = measuredIDs }
        reconcilePresentation()
        publish()
    }

    /// Positions come from complete native measurements; the model owns only the shared motion
    /// schedule, never a second layout/height cache.
    public func updateDisplayPositions(_ positions: [UUID: Double]) {
        var changed = false
        for (index, item) in presentations.prefix(visibleCount).enumerated() {
            guard let position = positions[item.id], position.isFinite else { continue }
            let hadPosition = item.hasMeasuredPosition
            item.hasMeasuredPosition = true
            guard abs(item.positionY - position) > 0.5 else { continue }
            if hadPosition && !usesReducedMotion {
                let offset = item.relocation?.offsetY(at: now(), reducedMotion: false) ?? 0
                item.relocation = EventNoticeMotionPlan(
                    kind: .relocation, startedAt: now(), index: index,
                    fromY: item.positionY + offset - position)
            }
            item.positionY = position
            changed = true
        }
        if changed { publish() }
    }

    public func setAutomaticallySuppressed(_ value: Bool) {
        guard isAutomaticallySuppressed != value else { return }
        isAutomaticallySuppressed = value
        if value { hideImmediately() }
        publish()
    }

    public func setReducedMotion(_ value: Bool) {
        guard usesReducedMotion != value else { return }
        usesReducedMotion = value
        if value {
            invalidatePresentationCommit()
            exitingPresentations.removeAll()
            for item in presentations.prefix(visibleCount) {
                item.entrance = nil
                item.relocation = nil
                if item.phase == .entering {
                    item.phase = .visible
                    item.hasPresented = true
                    resumeReading(item)
                }
            }
        }
        publish()
    }

    public func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        clearForPrivacy()
    }

    public func setSystemPrivacy(_ reason: EventNoticePrivacyReason, active: Bool) {
        let previous = privacyReasons
        if active { privacyReasons.formUnion(reason) } else { privacyReasons.subtract(reason) }
        guard previous != privacyReasons else { return }
        if active { clearForPrivacy() }
    }

    public func clearForPrivacy(newReceiverEpoch: UUID = UUID()) {
        invalidatePresentationTimer()
        expiryTimer?.cancel()
        expiryTimer = nil
        expiryDeadline = nil
        expiryRevision &+= 1
        receiverEpoch = newReceiverEpoch
        epochStartedAt = now()
        entries.removeAll()
        frozen.removeAll()
        presentations.removeAll()
        exitingPresentations.removeAll()
        if measuredPresentations != nil { measuredPresentations = [] }
        invalidatePresentationCommit()
        isQueueExpanded = false
        queueOpenedAt = nil
        displayOverflowCount = 0
        capacityHintCount = 0
        readingConsumers.removeAll()
        readingSelection = nil
        protectedAction = nil
        seen.removeAll()
        observations.removeAll()
        developmentObservationRun = nil
        developmentObservationStartedAt = nil
        pauseReasons = []
        isExpanded = false
        isDetail = false
        droppedCount = 0
        lastRemovalReason = .privacy
        publish(immediateBadge: true)
    }

    public func replaceReceiverEpoch(_ epoch: UUID) {
        if epoch != receiverEpoch { clearForPrivacy(newReceiverEpoch: epoch) }
    }

    public func setPauseReason(_ reason: EventNoticePauseReason, active: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if active { pauseReasons.formUnion(reason) } else { pauseReasons.subtract(reason) }
        expireEntries()
        if !wasPaused && !pauseReasons.isEmpty {
            for item in presentations { pauseReading(item) }
        } else if wasPaused && pauseReasons.isEmpty {
            for item in presentations.prefix(visibleCount) { resumeReading(item) }
        }
        publish()
    }

    package var presentationUptime: TimeInterval { now() }

    public func expireNow() {
        expireEntries(); reconcilePresentation(); publish(immediateBadge: true)
    }

    private var currentEntry: Entry? {
        presentations.prefix(visibleCount).first?.entry ?? exitingPresentations.first?.entry
    }
    private var phase: EventNoticePresentationPhase {
        presentations.prefix(visibleCount).first?.phase
            ?? (exitingPresentations.isEmpty ? .hidden : .exiting)
    }

    /// Resolve the complete identity once per arrival, before any transition mutates entries.
    private func index(for identity: Identity) -> Int? {
        for index in entries.indices {
            if entries[index].identity == identity {
                return index
            }
        }
        return nil
    }

    private func actionableEntry(_ action: EventNoticeAction) -> Entry? {
        guard canReceive, action.epoch == receiverEpoch else { return nil }
        let entry =
            entries.first(where: { $0.matches(action) })
            ?? presentations.first(where: { $0.entry.matches(action) })?.entry
        guard let entry, entry.content != nil, entry.expiresAt > now() else { return nil }
        return entry
    }

    private func validObservation(_ notice: HostEventNotice) -> TimeInterval? {
        guard let observation = notice.observedUptime, observation.isFinite,
            observation >= epochStartedAt, observation <= now(), observation > 0
        else { return nil }
        return observation
    }

    private func makeEntry(
        _ notice: HostEventNotice, kind: EventNoticeKind, identity: Identity?,
        id: UUID? = nil, version: UInt64 = 1
    ) -> Entry {
        let action = EventNoticeAction(
            id: id ?? notice.id, version: version, epoch: notice.receiverEpoch,
            installationID: notice.installationID)
        let target = notice.processAncestors.flatMap { resolveSourceApplication($0, action) }
        return Entry(
            id: action.id, version: version, event: notice.event, kind: kind,
            expiresAt: now() + Self.retentionDuration,
            content: EventNoticeContent(
                notice, sourceApplication: target?.action == action ? target : nil),
            identity: identity)
    }

    @discardableResult
    private func enqueue(_ entry: Entry) -> Bool {
        guard !isAutomaticallySuppressed else { return true }
        if entry.kind.isAttention,
            let item = presentations.first(where: { $0.entry.id == entry.id })
        {
            item.entry = entry
            item.remaining = Self.displayDuration
            item.deadline = nil
            if item.phase == .visible { resumeReading(item) }
            return true
        }
        guard presentations.count < Self.maximumBannerCount else {
            displayOverflowCount = saturatedIncrement(displayOverflowCount)
            capacityHintCount = saturatedIncrement(capacityHintCount)
            return false
        }
        presentations.append(Presentation(entry))
        reconcilePresentation()
        return true
    }

    private func reconcilePresentation() {
        for (index, item) in presentations.enumerated() {
            item.layerIndex = index
            if index >= visibleCount {
                pauseReading(item)
                item.phase = .hidden
                item.entrance = nil
                item.relocation = nil
                item.hasMeasuredPosition = false
            } else if item.phase == .hidden {
                if item.hasPresented || usesReducedMotion {
                    item.phase = .visible
                    item.hasPresented = true
                    resumeReading(item)
                } else {
                    item.phase = .entering
                    item.entrance = EventNoticeMotionPlan(kind: .entrance, startedAt: nil)
                }
            }
        }
        if presentations.count <= visibleCount {
            isQueueExpanded = false
            queueOpenedAt = nil
            let wasPaused = !pauseReasons.isEmpty
            pauseReasons.subtract(.queueExpansion)
            if wasPaused && pauseReasons.isEmpty {
                for item in presentations.prefix(visibleCount) { resumeReading(item) }
            }
        }
        if presentations.isEmpty {
            capacityHintCount = 0
            pauseReasons.formIntersection(.modal)
        }
        if presentations.contains(where: { $0.phase == .entering && $0.entrance?.startedAt == nil }
        ),
            presentationCommitTimer == nil
        {
            // Arrivals in this MainActor transaction form one zero-based presentation batch.
            let epoch = receiverEpoch
            let id = UUID()
            presentationCommitID = id
            presentationCommitTimer = scheduler.schedule(after: 0) { [weak self] in
                guard let self, self.receiverEpoch == epoch, self.presentationCommitID == id else {
                    return
                }
                self.presentationCommitID = nil
                self.presentationCommitTimer = nil
                self.commitPresentation()
            }
        } else if !presentations.contains(where: {
            $0.phase == .entering && $0.entrance?.startedAt == nil
        }) {
            invalidatePresentationCommit()
        }
        schedulePresentation()
    }

    private func commitPresentation() {
        var index = 0
        for item in presentations.prefix(visibleCount)
        where item.phase == .entering && item.entrance?.startedAt == nil {
            item.entrance = EventNoticeMotionPlan(kind: .entrance, startedAt: now(), index: index)
            index += 1
        }
        publish()
    }

    private func resumeReading(_ item: Presentation) {
        guard item.phase == .visible, pauseReasons.isEmpty, item.deadline == nil else { return }
        item.deadline = now() + item.remaining
    }

    private func pauseReading(_ item: Presentation) {
        if let deadline = item.deadline { item.remaining = max(0, deadline - now()) }
        item.deadline = nil
    }

    private func beginExit(_ item: Presentation, animated: Bool, captured: EventNoticeRecord) {
        pauseReading(item)
        guard animated, !usesReducedMotion, item.phase != .hidden else { return }
        let time = now()
        let opacity = item.entrance?.opacity(at: time, reducedMotion: false) ?? 1
        let offset =
            (item.entrance?.offsetY(at: time, reducedMotion: false) ?? 0)
            + (item.relocation?.offsetY(at: time, reducedMotion: false) ?? 0)
        item.phase = .exiting
        item.retiredRecord = captured
        item.exit = EventNoticeMotionPlan(
            kind: .exit, startedAt: time, fromY: offset, fromOpacity: opacity)
        item.relocation = nil
        // At most 50 display frames can retire in one 180ms interval.
        if exitingPresentations.count == Self.maximumBannerCount {
            exitingPresentations.removeFirst()
        }
        exitingPresentations.append(item)
    }

    private func schedulePresentation() {
        var earliest = TimeInterval.infinity
        for item in presentations.prefix(visibleCount) {
            if item.phase == .entering, let end = item.entrance?.completesAt {
                earliest = min(earliest, end)
            }
            if let deadline = item.deadline { earliest = min(earliest, deadline) }
        }
        for item in exitingPresentations {
            if let end = item.exit?.completesAt { earliest = min(earliest, end) }
        }
        let deadline = earliest.isFinite ? earliest : nil
        guard presentationDeadline != deadline else { return }
        invalidatePresentationTimer()
        presentationDeadline = deadline
        guard let deadline else { return }
        let revision = presentationRevision
        presentationTimer = scheduler.schedule(after: max(0, deadline - now())) { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            self.presentationTimer = nil
            self.presentationDeadline = nil
            self.advancePresentation()
        }
    }

    private func advancePresentation() {
        let time = now()
        for item in presentations.prefix(visibleCount)
        where item.phase == .entering && (item.entrance?.completesAt ?? .infinity) <= time {
            item.phase = .visible
            item.hasPresented = true
            resumeReading(item)
        }
        let expired = presentations.filter { ($0.deadline ?? .infinity) <= time }
            .map { ($0, record($0.entry)) }
        for (item, captured) in expired {
            presentations.removeAll { $0.id == item.id }
            beginExit(item, animated: true, captured: captured)
        }
        exitingPresentations.removeAll { ($0.exit?.completesAt ?? .infinity) <= time }
        expireEntries()
        reconcilePresentation()
        publish()
    }

    private func eraseReadingVersion(id: UUID) {
        for index in frozen.indices where frozen[index].id == id {
            // A frozen placeholder cannot erase the shared handle retained by a retiring
            // card. That noninteractive frame releases its own content after 180ms.
            let previous = frozen[index]
            frozen[index] = Entry(
                id: previous.id, version: previous.version, event: previous.event,
                kind: previous.kind, expiresAt: previous.expiresAt, content: nil, identity: nil)
        }
    }

    private func expireEntries() {
        let time = now()
        let previousCount = entries.count
        entries.removeAll { $0.expiresAt <= time }
        if entries.count < previousCount { lastRemovalReason = .expired }
        // Each reading version has its own deadline, even if a newer version extended the row.
        for index in frozen.indices where frozen[index].expiresAt <= time { frozen[index].erase() }
        for item in presentations + exitingPresentations where item.entry.expiresAt <= time {
            item.entry.erase()
        }
        let displayCount = presentations.count
        presentations.removeAll { $0.entry.content == nil }
        exitingPresentations.removeAll { $0.entry.content == nil }
        if displayCount != presentations.count { reconcilePresentation() }
        seen.removeAll { $0.expiresAt <= time }
        observations.removeAll { $0.expiresAt <= time }
        if let action = protectedAction, !isCurrent(action) { protectedAction = nil }
    }

    private func scheduleExpiry() {
        // Find the earliest deadline without copying source-bearing entries or building
        // temporary arrays on every event batch.
        var earliest = TimeInterval.infinity
        for entry in entries { earliest = min(earliest, entry.expiresAt) }
        for entry in frozen where entry.content != nil { earliest = min(earliest, entry.expiresAt) }
        for item in presentations + exitingPresentations where item.entry.content != nil {
            earliest = min(earliest, item.entry.expiresAt)
        }
        for item in seen { earliest = min(earliest, item.expiresAt) }
        for item in observations { earliest = min(earliest, item.expiresAt) }
        let deadline = earliest.isFinite ? earliest : nil
        guard deadline != expiryDeadline else { return }
        expiryTimer?.cancel()
        expiryTimer = nil
        expiryDeadline = deadline
        expiryRevision &+= 1
        guard let deadline else { return }
        let revision = expiryRevision
        expiryTimer = scheduler.schedule(after: max(0, deadline - now())) { [weak self] in
            guard let self, self.expiryRevision == revision else { return }
            self.expiryDeadline = nil
            self.expiryTimer = nil
            self.expireEntries()
            self.publish(immediateBadge: true)
        }
    }

    private func invalidatePresentationTimer() {
        presentationRevision &+= 1
        presentationTimer?.cancel()
        presentationTimer = nil
        presentationDeadline = nil
    }

    private func invalidatePresentationCommit() {
        presentationCommitID = nil
        presentationCommitTimer?.cancel()
        presentationCommitTimer = nil
    }

    private func record(_ entry: Entry) -> EventNoticeRecord {
        EventNoticeRecord(
            id: entry.id, event: entry.event, occurredAt: entry.content?.occurredAt,
            content: entry.content,
            status: presentations.prefix(visibleCount).contains(where: { $0.entry === entry })
                ? .displayed
                : presentations.contains(where: { $0.entry === entry }) ? .queued : .collapsed,
            isExpired: entry.content == nil, version: entry.version,
            isActionable: entry.action.map(isCurrent) ?? false,
            isSuperseded: entry.isSuperseded, kind: entry.kind)
    }

    private func publish(immediateBadge: Bool = false) {
        owesImmediateBadge = owesImmediateBadge || immediateBadge
        guard !isReducingBatch else { return }
        scheduleExpiry()
        schedulePresentation()
        var pendingRefreshCount = 0
        if !readingConsumers.isEmpty {
            for entry in entries where !frozen.contains(where: { $0.action == entry.action }) {
                pendingRefreshCount += 1
            }
        }
        let sampledUptime = now()
        func bannerItem(_ item: Presentation) -> EventNoticeBannerItem {
            let remaining = item.deadline.map { max(0, $0 - sampledUptime) } ?? item.remaining
            return EventNoticeBannerItem(
                id: item.id, record: item.retiredRecord ?? record(item.entry), phase: item.phase,
                readingTime: EventNoticeReadingTime(
                    sampledUptime: sampledUptime, remaining: remaining,
                    isPaused: item.deadline == nil, budget: Self.displayDuration),
                entrance: item.entrance, relocation: item.relocation, exit: item.exit,
                positionY: item.positionY, layerIndex: item.layerIndex)
        }
        let stack = EventNoticeStackSnapshot(
            visible: presentations.prefix(visibleCount).map(bannerItem),
            queued: presentations.dropFirst(visibleCount).map(bannerItem),
            exiting: exitingPresentations.map(bannerItem), isQueueExpanded: isQueueExpanded,
            queueOpenedAt: queueOpenedAt, pauseReasons: pauseReasons,
            overflowCount: displayOverflowCount, capacityHintCount: capacityHintCount,
            receiverEpoch: receiverEpoch)
        if stackSnapshot != stack { stackSnapshot = stack }
        let readingTime = stack.visible.first?.readingTime ?? stack.exiting.first?.readingTime
        let remaining = readingTime?.remaining
        let banner = EventNoticeModelSnapshot(
            phase: phase, current: currentEntry.map(record), attentionReminders: [],
            pendingCount: 0, pauseReasons: pauseReasons, remainingTime: remaining,
            isExpanded: false, droppedCount: droppedCount, receiverEpoch: receiverEpoch,
            totalCount: entries.count, readingTime: readingTime)
        let reading = EventNoticeReadingSnapshot(
            records: (!readingConsumers.isEmpty ? frozen : Array(entries.reversed())).map(record),
            pendingCount: pendingRefreshCount, droppedCount: droppedCount,
            receiverEpoch: receiverEpoch, isOpen: !readingConsumers.isEmpty,
            latest: entries.last.map(record))
        if readingSnapshot != reading { readingSnapshot = reading }
        if bannerSnapshot != banner { bannerSnapshot = banner }
        let selected = readingSelection.flatMap { action in
            (frozen.first(where: { $0.id == action.id && $0.version == action.version })
                ?? presentations.first(where: { $0.entry.matches(action) })?.entry).map(record)
        }
        let updated = EventNoticeModelSnapshot(
            phase: isExpanded ? .visible : phase, current: isDetail ? selected : banner.current,
            attentionReminders: reading.records, pendingCount: reading.pendingCount,
            pauseReasons: pauseReasons, remainingTime: remaining, isExpanded: isExpanded,
            droppedCount: droppedCount, receiverEpoch: receiverEpoch, isDetail: isDetail,
            totalCount: entries.count, readingTime: readingTime)
        if snapshot != updated { snapshot = updated }
        if owesImmediateBadge {
            badgeRevision &+= 1
            badgeTimer?.cancel()
            badgeTimer = nil
            if badgeCount != entries.count { badgeCount = entries.count }
            owesImmediateBadge = false
        } else if badgeCount != entries.count && badgeTimer == nil {
            // Throttle from the FIRST change. A sustained stream cannot postpone this deadline.
            let revision = badgeRevision
            badgeTimer = scheduler.schedule(after: 0.1) { [weak self] in
                guard let self, self.badgeRevision == revision else { return }
                self.badgeTimer = nil
                self.badgeCount = self.entries.count
            }
        }
    }

    private func saturatedIncrement(_ value: Int) -> Int { value == Int.max ? value : value + 1 }
}
