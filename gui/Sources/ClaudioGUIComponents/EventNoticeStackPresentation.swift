import ClaudioGUICore
import ClaudioLocalization
import Combine
import Foundation

/// Coordinates native measurements and a single model transaction. It owns neither a display
/// queue nor a clock: the model owns identities, budgets, motion and retirement; navigation owns
/// action state. Both the retained production panel and native fixtures consume this output.
@MainActor
package final class EventNoticeStackPresentation: @preconcurrency ObservableObject {
    package let objectWillChange = ObservableObjectPublisher()
    private let outputSubject: CurrentValueSubject<EventNoticeStackPresentationOutput, Never>
    package var output: EventNoticeStackPresentationOutput { outputSubject.value }
    package var outputs: AnyPublisher<EventNoticeStackPresentationOutput, Never> {
        outputSubject
            // A previous subscriber can synchronously withdraw this value while send is still
            // visiting subscribers. Validate at each delivery, before a window can render it.
            .filter { [weak self] value in self?.output == value }
            .eraseToAnyPublisher()
    }
    private let model: EventNoticeModel
    private let preferences: ClaudioPreferences
    private let navigation: SessionNavigationCoordinator
    private let scheduler: EventNoticeScheduler
    private var subscriptions: Set<AnyCancellable> = []
    private var scheduled: EventNoticeCancellation?
    private var running = false
    private var dirty = false
    private var width: Double = 440
    private var available: Double?
    private var fontEnvironment = ""
    private var generation: UInt64 = 0
    private var epoch: UUID
    private var requests: [EventNoticeMeasurementRequest] = []
    private var measurements: [EventNoticeMeasurementToken: Double] = [:]
    private var pending: [EventNoticeMeasurementToken: Double] = [:]
    private struct PaintedCard {
        let width: Double
        let height: Double
        let content: EventNoticeCardContent
    }
    private var painted: [UUID: PaintedCard] = [:]
    private var committedIDs: [UUID] = []
    private var lastSnapshot: EventNoticeStackSnapshot

    package init(
        model: EventNoticeModel, preferences: ClaudioPreferences,
        navigation: SessionNavigationCoordinator, scheduler: EventNoticeScheduler = .live
    ) {
        self.model = model
        self.preferences = preferences
        self.navigation = navigation
        self.scheduler = scheduler
        epoch = model.receiverEpoch
        lastSnapshot = model.stackSnapshot
        outputSubject = CurrentValueSubject(
            EventNoticeStackPresentationOutput(epoch: model.receiverEpoch))
        model.setVisibleCapacity(0, measuredIDs: [])
        model.$stackSnapshot.sink { [weak self] snapshot in
            self?.noticeChanged(snapshot)
        }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &subscriptions)
        navigation.objectWillChange.sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &subscriptions)
    }

    package func updateViewport(width: Double, availableHeight: Double?) {
        let validWidth = width.isFinite && width > 0 ? width : self.width
        let validHeight = availableHeight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard self.width != validWidth || available != validHeight else { return }
        if self.width != validWidth || (available == nil) != (validHeight == nil) {
            generation &+= 1
            requests.removeAll(); measurements.removeAll(); pending.removeAll()
        }
        self.width = validWidth
        available = validHeight
        if !canPreserveGeometry { suspendGeometry() }
        requestRefresh()
    }

    package func updateFontEnvironment(_ value: String) {
        guard fontEnvironment != value else { return }
        fontEnvironment = value
        generation &+= 1
        requests.removeAll(); measurements.removeAll(); pending.removeAll()
        requestRefresh()
    }

    /// Called by TimelineView for relative-time text. The signature comparison ignores ordinary
    /// ticks, so only an actual caption change invalidates a size.
    package func refreshContent() { requestRefresh() }

    package func receiveMeasurements(_ values: [EventNoticeMeasurementToken: Double]) {
        let known = Set(output.requests.map(\.token))
        for (token, height) in values where height.isFinite && height > 0 {
            guard known.contains(token), measurements[token] == nil, pending[token] == nil else {
                continue
            }
            pending[token] = height
        }
        if !pending.isEmpty { requestRefresh() }
    }

    private var canPreserveGeometry: Bool {
        guard let available else { return false }
        return output.isEligible && output.width == width && output.height <= available
    }

    private func canPreserveGeometry(for snapshot: EventNoticeStackSnapshot) -> Bool {
        let visibleIDs = snapshot.visible.map(\.id)
        // Removing a card leaves a safe ordered subset of the painted stack. Keep that frame
        // while controls are remeasured; newly admitted cards still need current measurements.
        return canPreserveGeometry
            && committedIDs.filter { visibleIDs.contains($0) } == visibleIDs
    }

    private func suspendGeometry() {
        var value = output
        value.isEligible = false
        publish(value)
        synchronizeGeometryPause()
    }

    private func noticeChanged(_ snapshot: EventNoticeStackSnapshot) {
        let retained = Set((snapshot.visible + snapshot.queued + snapshot.exiting).map(\.id))
        let old = Set((lastSnapshot.visible + lastSnapshot.queued + lastSnapshot.exiting).map(\.id))
        lastSnapshot = snapshot
        // Published sends in willSet. Use its value for synchronous withdrawal, and read the
        // committed model only in the scheduled refresh. No model mutation inside this sink.
        if snapshot.receiverEpoch != epoch || !old.subtracting(retained).isEmpty
            || !snapshot.hasPresentation
        {
            let preserveRemaining =
                snapshot.receiverEpoch == epoch
                && !snapshot.visible.isEmpty && canPreserveGeometry(for: snapshot)
            if snapshot.receiverEpoch != epoch {
                epoch = snapshot.receiverEpoch
                generation &+= 1
                requests.removeAll(); measurements.removeAll(); pending.removeAll()
            }
            requests.removeAll {
                if case .card(let id) = $0.token.role { return !retained.contains(id) }
                return true
            }
            let tokens = Set(requests.map(\.token))
            measurements = measurements.filter { tokens.contains($0.key) }
            pending = pending.filter { tokens.contains($0.key) }
            painted = painted.filter { retained.contains($0.key) }
            var value = output
            value.epoch = epoch
            value.isEligible = preserveRemaining
            value.requests = Array(requests.filter { measurements[$0.token] == nil }.prefix(8))
            value.cardHeights = value.cardHeights.filter { retained.contains($0.key) }
            value.retiredContent = value.retiredContent.filter { retained.contains($0.key) }
            publish(value)
        }
        requestRefresh()
    }

    private func requestRefresh() {
        dirty = true
        guard scheduled == nil, !running else { return }
        scheduled = scheduler.schedule(after: 0) { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.running = true
            self.dirty = false
            self.refresh()
            self.running = false
            if self.dirty { self.requestRefresh() }
        }
    }

    private func refresh() {
        let snapshot = model.stackSnapshot
        let calculationGeneration = generation
        guard snapshot.receiverEpoch == epoch else { requestRefresh(); return }
        let retained = Set((snapshot.candidates + snapshot.exiting).map(\.id))
        painted = painted.filter { retained.contains($0.key) }
        rebuildRequests(snapshot)
        let tokens = Set(requests.map(\.token))
        measurements = measurements.filter { tokens.contains($0.key) }
        for (token, height) in pending where tokens.contains(token) { measurements[token] = height }
        pending.removeAll()
        var value = output
        value.epoch = epoch
        // At most eight mounted measurement copies, including cards and the capacity hint.
        value.requests = Array(requests.filter { measurements[$0.token] == nil }.prefix(8))
        value.cardHeights = value.cardHeights.filter { retained.contains($0.key) }
        let validExits = painted.filter { id, card in
            card.width == width && snapshot.exiting.contains { $0.id == id }
        }
        value.retiredContent = validExits.mapValues(\.content)
        for item in snapshot.exiting { value.cardHeights[item.id] = validExits[item.id]?.height }
        let exitHeight =
            snapshot.exiting.compactMap { item in
                validExits[item.id].map { item.positionY + $0.height }
            }.max() ?? 0
        guard snapshot.hasPresentation, let available else {
            value.isEligible = false
            value.width = width
            publish(value)
            synchronizeGeometryPause()
            return
        }
        let heights = snapshot.candidates.map { height(for: .card($0.id)) ?? 0 }
        let missingVisible = snapshot.visible.contains { height(for: .card($0.id)) == nil }
        if missingVisible {
            value.isEligible = canPreserveGeometry(for: snapshot)
            if !value.isEligible { value.width = width }
            publish(value)
            synchronizeGeometryPause()
            return
        }
        // Wait for all control variants. Each k reserves only its own expanded/collapsed max.
        guard
            requests.filter({
                switch $0.token.role {
                case .card, .queueContent: return false
                case .queueEntry, .capacityHint: return true
                }
            })
            .allSatisfy({ measurements[$0.token] != nil })
        else {
            value.isEligible = canPreserveGeometry(for: snapshot)
            if !value.isEligible { value.width = width }
            publish(value)
            synchronizeGeometryPause()
            return
        }
        let hint = height(for: .capacityHint) ?? 0
        var capacity = 0, base: Double = 0, entry: Double = 0, showHint = false
        var fits = false
        for count in stride(from: min(3, snapshot.totalCount), through: 0, by: -1) {
            let prefix = Array(heights.prefix(count))
            guard prefix.count == count, prefix.allSatisfy({ $0 > 0 }) else { continue }
            let queueEntry =
                snapshot.totalCount > count
                ? max(
                    height(for: .queueEntry(visibleCount: count, expanded: false)) ?? 0,
                    height(for: .queueEntry(visibleCount: count, expanded: true)) ?? 0) : 0
            let cards = prefix.reduce(0, +) + Double(max(0, count - 1)) * 8
            let controls = queueEntry + (queueEntry > 0 && count > 0 ? 8 : 0)
            let withHint =
                cards + controls + (hint > 0 ? hint + (count > 0 || queueEntry > 0 ? 8 : 0) : 0)
            // With zero cards, preserve a complete queue entry before the capacity hint.
            let candidate = count == 0 && withHint > available ? controls : withHint
            guard candidate <= available else { continue }
            capacity = count; entry = queueEntry; base = candidate
            showHint = hint > 0 && withHint <= available
            fits = candidate > 0 || exitHeight > 0
            break
        }
        var positions: [UUID: Double] = [:], top: Double = 0
        for (index, item) in snapshot.candidates.prefix(capacity).enumerated() {
            positions[item.id] = top
            top += heights[index] + 8
        }
        guard model.commitStackLayout(expected: snapshot, capacity: capacity, positions: positions)
        else {
            requestRefresh(); return
        }
        // Subscribers may withdraw content during the atomic model publication.
        guard generation == calculationGeneration, model.receiverEpoch == snapshot.receiverEpoch,
            model.stackSnapshot.candidates.map(\.id) == snapshot.candidates.map(\.id),
            model.stackSnapshot.candidates.map(\.record.version)
                == snapshot.candidates.map(\.record.version),
            lastSnapshot.receiverEpoch == snapshot.receiverEpoch
        else { requestRefresh(); return }
        committedIDs = model.stackSnapshot.visible.map(\.id)
        for item in model.stackSnapshot.visible {
            if let request = requests.first(where: { $0.token.role == .card(item.id) }),
                let height = measurements[request.token], let content = request.content
            {
                value.cardHeights[item.id] = height
                painted[item.id] = PaintedCard(width: width, height: height, content: content)
            }
        }
        let occupied = max(base, exitHeight)
        // The content token describes this snapshot's queued suffix. If admission changed,
        // use the bounded provisional viewport until the new suffix is measured next turn.
        let naturalQueueHeight =
            capacity == snapshot.visible.count ? (height(for: .queueContent) ?? 220) : 220
        let queue =
            snapshot.isQueueExpanded && snapshot.totalCount > capacity
            ? min(220, naturalQueueHeight, max(0, available - occupied - 8)) : 0
        value.width = width
        value.height = min(available, max(1, occupied + (queue > 0 ? 8 + queue : 0)))
        value.queueHeight = queue
        value.queueClearance = max(0, exitHeight - base)
        value.queueEntryHeight = entry
        value.showsCapacityHint = showHint
        value.isEligible = fits && exitHeight <= available
        publish(value)
        synchronizeGeometryPause()
    }

    private func synchronizeGeometryPause() {
        // Output subscribers can synchronously change viewport or privacy. Apply the current
        // eligibility after those callbacks, never the superseded local calculation.
        model.setPauseReason(
            .geometryUnavailable,
            active: model.stackSnapshot.hasPresentation && !output.isEligible)
    }

    private func height(for role: EventNoticeMeasurementRole) -> Double? {
        guard let request = requests.first(where: { $0.token.role == role }) else { return nil }
        return measurements[request.token]
    }

    private func rebuildRequests(_ snapshot: EventNoticeStackSnapshot) {
        let language = preferences.language
        let now = Date()
        var next: [EventNoticeMeasurementRequest] = []
        func append(
            role: EventNoticeMeasurementRole, card: EventNoticeBannerItem? = nil,
            content: EventNoticeCardContent? = nil, queue: EventNoticeStackSnapshot? = nil,
            hint: Int = 0
        ) {
            let proposed = EventNoticeMeasurementRequest(
                token: EventNoticeMeasurementToken(
                    identity: UUID(), epoch: epoch,
                    generation: generation, width: width, role: role), language: language,
                card: card, content: content, queue: queue, hintCount: hint, capturedNow: now,
                queueContentIdentity: role == .queueContent
                    ? (queue?.queued.flatMap { item in
                        [
                            item.id.uuidString, item.record.id.uuidString,
                            String(item.record.version),
                            EventNoticeProjection.primaryLine(for: item.record, language: language),
                            EventNoticeProjection.secondaryLine(
                                for: item.record, language: language, now: now),
                        ]
                    } ?? []) : [])
            if let existing = requests.first(where: {
                $0.token.generation == generation && $0.hasSameContent(as: proposed)
            }) {
                next.append(existing)
            } else {
                next.append(proposed)
            }
        }
        for item in snapshot.candidates {
            append(
                role: .card(item.id), card: item,
                content: EventNoticeCardContent(
                    item: item, language: language, navigation: navigation, now: now))
        }
        if snapshot.capacityHintCount > 0 {
            append(role: .capacityHint, hint: snapshot.capacityHintCount)
        }
        for count in 0...min(3, snapshot.totalCount) where snapshot.totalCount > count {
            for expanded in [false, true] {
                let queue = EventNoticeStackSnapshot(
                    queued: Array((snapshot.visible + snapshot.queued).dropFirst(count)),
                    isQueueExpanded: expanded, receiverEpoch: epoch)
                append(role: .queueEntry(visibleCount: count, expanded: expanded), queue: queue)
            }
        }
        if snapshot.isQueueExpanded && !snapshot.queued.isEmpty {
            append(role: .queueContent, queue: snapshot)
        }
        requests = next
    }

    private func publish(_ value: EventNoticeStackPresentationOutput) {
        guard value != output else { return }
        objectWillChange.send()
        // CurrentValueSubject stores the new value before invoking subscribers. A subscriber
        // can synchronously clear privacy without a willSet assignment restoring the old frame.
        outputSubject.send(value)
    }
}
