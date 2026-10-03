import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SoundPacksWindow
import SwiftUI

/// Production Integrations destination. It owns no host configuration or capability-matrix
/// state; all facts and asynchronous lifecycle behavior come from the Core model.
@MainActor
struct IntegrationsSettingsDestinationView: View {
    @ObservedObject var model: IntegrationDestinationModel
    @ObservedObject var focusCoordinator: IntegrationDestinationFocusCoordinator
    @ObservedObject var languageStore: ClaudioPreferences
    var productImages: SettingsProductImages = .empty
    let onManageSoundScopes: @MainActor () -> Void
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTarget: IntegrationDestinationFocusTarget?
    @State private var detailsHost: HostID?
    @State private var receiptHistoryTarget: ReceiptHistoryTarget?
    @State private var pendingConnect: HostID?
    @State private var feedbackAnnouncer = IntegrationsFeedbackAnnouncementModel()

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    private struct ReceiptHistoryTarget: Identifiable {
        let host: HostID
        var id: HostID { host }
    }

    init(
        model: IntegrationDestinationModel,
        focusCoordinator: IntegrationDestinationFocusCoordinator,
        languageStore: ClaudioPreferences,
        productImages: SettingsProductImages = .empty,
        onManageSoundScopes: @escaping @MainActor () -> Void,
        onAnnouncement: @escaping @MainActor (String) -> Void
    ) {
        self.model = model
        self.focusCoordinator = focusCoordinator
        self.languageStore = languageStore
        self.productImages = productImages
        self.onManageSoundScopes = onManageSoundScopes
        self.onAnnouncement = onAnnouncement
    }

    var body: some View {
        AnyView(
            VStack(spacing: 0) {
                SettingsPageHeader {
                    if detailsHost != nil {
                        Button {
                            detailsHost = nil; focusedTarget = .title
                        } label: {
                            Label(l10n.text(.settingsNativeBack), systemImage: "chevron.left")
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .accessibilityIdentifier("integrations.destination.detail.back")
                    }
                    Text(detailsHost?.displayName ?? l10n.text(.settingsDestinationIntegrations))
                        .font(SettingsAppearance.pageTitle)
                        .accessibilityAddTraits(.isHeader)
                        .focusable().focused($focusedTarget, equals: .title)
                        .accessibilityIdentifier("integrations.destination.title")
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
                        if let detailsHost {
                            if let facts = model.selectedHostFacts, facts.host == detailsHost {
                                connectionSection(facts)
                                capabilitySection(facts)
                                infoCallout
                            } else {
                                FailureRow(message: l10n.text(.settingsNativeTargetUnavailable))
                                    .focusable().focused($focusedTarget, equals: .title)
                                    .accessibilityIdentifier(
                                        "integrations.destination.detail.unavailable")
                            }
                        } else {
                            Text(l10n.text(.integrationsDestinationSubtitle))
                                .font(SettingsAppearance.font(.secondary)).foregroundStyle(
                                    .secondary
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            agentSection
                            Text(l10n.text(.integrationsAgentHint))
                                .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !model.content.isUnavailable, let facts = model.selectedHostFacts {
                                connectionSection(facts)
                                Button {
                                    detailsHost = facts.host
                                    focusedTarget = .title
                                } label: {
                                    HStack {
                                        Text(l10n.text(.settingsNativeCapabilities))
                                        Spacer(minLength: 12)
                                        Image(systemName: "chevron.right").foregroundStyle(
                                            .secondary)
                                    }.frame(minHeight: 33).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).settingsSectionSurface(padding: 14)
                                .accessibilityIdentifier(
                                    "integrations.destination.open-capabilities")
                                infoCallout
                            } else {
                                unavailableSection
                            }
                        }
                        if let feedback = model.feedback { feedbackToast(feedback) }
                    }
                    .soundPacksLayoutProbe("settings.reading.integrations")
                    .settingsReadingColumn()
                }
                .accessibilityIdentifier("integrations.destination.scroll")
            }
        )
        .background(SettingsAppearance.background(colorScheme))
        .sheet(
            item: $receiptHistoryTarget,
            onDismiss: {
                focusedTarget = .connectionRow(.receiptHistory)
            }
        ) { target in
            receiptHistorySheet(target.host)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { isPresented in
                    if !isPresented { model.cancelPendingAction() }
                }),
            titleVisibility: .visible,
            presenting: model.pendingConfirmation
        ) { confirmation in
            confirmationButtons(confirmation)
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .onReceive(focusCoordinator.$requestRevision) { revision in
            guard focusCoordinator.consumeRequest(revision) else { return }
            applyFocusRequest(focusCoordinator.requestedTarget)
        }
        .onChange(of: model.selectedHost) { _ in
            receiptHistoryTarget = nil; detailsHost = nil; reconcileFocus()
        }
        .alert(
            l10n.text(.settingsNativeConnectTitle),
            isPresented: Binding(
                get: { pendingConnect != nil }, set: { if !$0 { pendingConnect = nil } }),
            presenting: pendingConnect
        ) { host in
            Button(l10n.text(.commonCancel), role: .cancel) { pendingConnect = nil }
                .keyboardShortcut(.cancelAction)
            Button(l10n.format(.integrationsEnable, host.displayName)) {
                pendingConnect = nil
                guard model.content.facts(for: host)?.status == .notConnected else { return }
                perform(.connect(host))
            }
        } message: { host in
            Text(l10n.format(.settingsNativeConnectMessage, host.displayName))
        }
        .onDisappear {
            receiptHistoryTarget = nil; pendingConnect = nil; model.cancelPendingAction()
        }
        .onChange(of: model.feedback?.revision) { _ in
            announceFeedbackIfNeeded()
            reconcileFocus()
        }
        .onChange(of: model.isWindowKey) { isKey in
            if isKey { announceFeedbackIfNeeded() }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: model.feedback?.revision
        )
        .accessibilityElement(children: .contain)
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.integrations))
    }

    private var agentSection: some View {
        SettingsSectionCard {
            VStack(spacing: 0) {
                ForEach(model.agentControls) { agent in
                    agentRow(agent)
                    if agent.host != model.agentControls.last?.host {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("integrations.destination.agent-list")
    }

    private func agentRow(_ agent: IntegrationAgentConnectionControlPresentation) -> AnyView {
        AnyView(
            HStack(spacing: 12) {
                if let image = productImages.image(agent.host, colorScheme == .dark) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 27, height: 27)
                        .accessibilityHidden(true)
                }
                Button {
                    _ = model.selectHost(agent.host)
                } label: {
                    Text(agent.title)
                        .font(SettingsAppearance.font(.body).weight(.semibold))
                        .foregroundColor(SettingsAppearance.text(colorScheme))
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedTarget, equals: .agent(agent.host))
                .accessibilityLabel(agent.title)
                .accessibilityValue(
                    "\(localizedAgentStatus(agent.status))，\(agent.coverageText)"
                )
                .accessibilityAddTraits(model.selectedHost == agent.host ? .isSelected : [])
                .accessibilityIdentifier("integrations.destination.agent.\(agent.host.rawValue)")

                SettingsStatusCapsule(localizedAgentStatus(agent.status), isEmphasized: agent.isOn)
                    .fixedSize()
                Text(agent.coverageText)
                    .font(SettingsAppearance.font(.technical))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .monospacedDigit()
                    .accessibilityLabel(l10n.text(.integrationsCoverage))
                Toggle(
                    "",
                    isOn: Binding(
                        get: { agent.isOn },
                        set: { _ in
                            if agent.isOn {
                                model.requestToggle(for: agent.host)
                            } else {
                                pendingConnect = agent.host
                            }
                        })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SettingsAppearance.accent(colorScheme))
                .disabled(!agent.isToggleEnabled)
                .focused($focusedTarget, equals: .toggle(agent.host))
                .accessibilityLabel(
                    l10n.format(
                        agent.isOn ? .integrationsDisable : .integrationsEnable,
                        agent.title)
                )
                .accessibilityIdentifier("integrations.destination.toggle.\(agent.host.rawValue)")

                if agent.isInFlight, let operation = model.inFlightOperation {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(localizedInFlightStatus(operation))
                        .font(SettingsAppearance.font(.caption).weight(.semibold))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        model.selectedHost == agent.host
                            ? Color.primary.opacity(0.06) : Color.clear)))
    }

    private func connectionSection(_ facts: IntegrationDestinationHostFacts) -> some View {
        let section = integrationConnectionSectionPresentation(for: facts)
        return SettingsSectionCard {
            VStack(spacing: 0) {
                ForEach(section.rows) { row in
                    connectionRow(row, facts: facts)
                    if row.kind != .receiptHistory { Divider() }
                }
            }
        }
        .accessibilityIdentifier("integrations.destination.connection-group")
    }

    private func connectionRow(
        _ row: IntegrationConnectionRowPresentation,
        facts: IntegrationDestinationHostFacts
    ) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localizedConnectionRowTitle(row.kind))
                        .font(SettingsAppearance.font(.body).weight(.semibold))
                        .foregroundColor(SettingsAppearance.text(colorScheme))
                    Text(localizedConnectionRowCaption(row.kind, facts: facts))
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 7) {
                    if row.kind == .connectionStatus {
                        SettingsStatusCapsule(
                            localizedAgentStatus(facts.status), isEmphasized: facts.status == .ready
                        )
                    } else if row.kind == .mechanism, let value = row.value {
                        Text(value)
                            .font(SettingsAppearance.font(.technical))
                            .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                            .monospacedDigit()
                    }
                    if row.kind == .receiptHistory {
                        Button(l10n.text(.integrationsReceiptHistoryView)) {
                            receiptHistoryTarget = ReceiptHistoryTarget(host: facts.host)
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedTarget, equals: .connectionRow(.receiptHistory))
                        .accessibilityIdentifier(
                            "integrations.destination.open-history.\(facts.host.rawValue)")
                    }
                    ForEach(row.actions, id: \.self) { action in
                        connectionActionButton(action, facts: facts)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minHeight: 61, alignment: .center)
            .padding(.vertical, 5)
            .focused($focusedTarget, equals: .connectionRow(row.kind))
            .accessibilityIdentifier("integrations.destination.row.\(row.kind.rawValue)"))
    }

    private func receiptHistorySheet(_ host: HostID) -> AnyView {
        let history = model.content.facts(for: host)?.receiptHistory
        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Text(l10n.text(.integrationsReceiptHistory))
                    .font(SettingsAppearance.font(.sectionTitle))
                    .accessibilityAddTraits(.isHeader)
                Text(host.displayName).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let history {
                            if case .damaged(let count) = history.state {
                                Text(l10n.format(.settingsUsageHistoryDamaged, count))
                            }
                            if history.state == .unreadable {
                                Text(l10n.text(.integrationsReceiptHistoryUnavailable))
                            } else if history.entries.isEmpty {
                                Text(l10n.text(.integrationsReceiptHistoryEmpty))
                            }
                            ForEach(history.entries.indices, id: \.self) { index in
                                Text(
                                    history.entries[index].text(language: languageStore.language)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(
                                    "integrations.destination.history.entry")
                                Divider()
                            }
                        } else {
                            Text(l10n.text(.integrationsReceiptHistoryUnavailable))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsSectionSurface()
                }
                if let feedback = model.feedback { feedbackToast(feedback) }
                HStack {
                    Button(l10n.text(.actionRedetect)) { perform(.redetect) }
                        .disabled(model.isPerformingAction)
                    Spacer()
                    Button(l10n.text(.commonClose)) { receiptHistoryTarget = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("integrations.destination.history.close")
                }
            }
            .font(SettingsAppearance.font(.body))
            .padding(24)
            .frame(width: 580, height: 420)
            .background(SettingsAppearance.background(colorScheme))
            .accessibilityIdentifier("integrations.destination.history.\(host.rawValue)")
        )
    }

    @ViewBuilder
    private func connectionActionButton(
        _ action: IntegrationConnectionRowAction,
        facts: IntegrationDestinationHostFacts
    ) -> some View {
        Group {
            switch action {
            case .redetect:
                Button(l10n.text(.actionRedetect)) { perform(.redetect) }
                    .accessibilityIdentifier(
                        "integrations.destination.redetect.\(facts.host.rawValue)")
            case .copyHooks:
                Button(l10n.text(.actionCopyHooks)) { perform(.copyHooksCommand) }
                    .accessibilityIdentifier(
                        "integrations.destination.copy-hooks.\(facts.host.rawValue)")
            case .repair(let host):
                Button(
                    localizedHostIntegrationUserActionTitle(
                        .repair(host),
                        hostStatus: facts.status,
                        language: languageStore.language)
                ) { perform(.repair(host)) }
            case .copyConfigurationSource(let host):
                Button(l10n.format(.integrationsCopyPathLabel, host.displayName)) {
                    _ = model.copyConfigurationSource(for: host)
                }
                .focused($focusedTarget, equals: .copyConfigurationSource(host))
                .accessibilityValue(facts.configurationSource ?? "")
                .accessibilityHint(l10n.text(.integrationsCopyPathHint))
                .accessibilityIdentifier("integrations.destination.copy-source.\(host.rawValue)")
            case .manageSoundScopes:
                Button(l10n.text(.settingsIntegrationsManageEvents)) {
                    onManageSoundScopes()
                }
                .accessibilityHint(l10n.text(.settingsIntegrationsManageEventsHint))
                .accessibilityIdentifier(
                    "integrations.destination.manage-events.\(facts.host.rawValue)")
            case .clearReceiptHistory(let host):
                Button(l10n.format(.actionClearReceiptHistory, host.displayName)) {
                    model.requestClearReceiptHistory(for: host)
                }
                .accessibilityHint(l10n.text(.actionClearReceiptHistoryHint))
                .accessibilityIdentifier("integrations.destination.clear-receipts.\(host.rawValue)")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isPerformingAction)
    }

    private var unavailableSection: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.text(.integrationsUnavailableTitle))
                    .font(SettingsAppearance.font(.body).weight(.semibold))
                Text(model.content.unavailableReason ?? l10n.text(.integrationsStoreUnavailable))
                    .font(SettingsAppearance.font(.caption))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n.text(.actionRedetect)) { perform(.redetect) }
                    .disabled(model.isPerformingAction)
            }
        }
        .padding(.top, 30)
    }

    private func capabilitySection(_ facts: IntegrationDestinationHostFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.text(.settingsNativeCapabilities)).font(
                SettingsAppearance.font(.sectionTitle)
            )
            .accessibilityAddTraits(.isHeader).padding(14)
            ForEach(Event.allCases, id: \.self) { event in
                VStack(alignment: .leading, spacing: 8) {
                    Text(localizedEventName(event, language: languageStore.language))
                        .font(SettingsAppearance.font(.sectionTitle))
                    ForEach(facts.capabilityReceipts.filter { $0.binding.event == event }) {
                        receipt in
                        Text(receipt.binding.nativeEvent ?? l10n.text(.panelCapabilityUnsupported))
                            .font(SettingsAppearance.font(.caption))
                        Text(receipt.capabilityText(language: languageStore.language))
                            .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                        Text(receipt.text(language: languageStore.language))
                            .font(SettingsAppearance.font(.caption)).foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "integrations.destination.capability.\(receipt.id.rawValue)")
                    }
                }
                .fixedSize(horizontal: false, vertical: true).padding(14)
                if event != Event.allCases.last { Divider().padding(.horizontal, 14) }
            }
        }
        .settingsSectionSurface(padding: 0)
        .accessibilityIdentifier("integrations.destination.capabilities")
    }

    private var infoCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(l10n.text(.integrationsActivationCallout))
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("integrations.destination.info-callout")
    }

    private func feedbackToast(_ feedback: IntegrationsFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedbackSymbol(feedback.kind))
                .foregroundColor(feedbackColor(feedback.kind))
                .accessibilityHidden(true)
            Text(feedback.message(language: languageStore.language))
                .font(SettingsAppearance.font(.caption).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.dismissFeedback(revision: feedback.revision)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(l10n.text(.integrationsCloseFeedback))
            .accessibilityIdentifier("integrations.destination.feedback.dismiss")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .settingsSectionSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feedback.localizedAccessibilityLabel(language: languageStore.language))
        .accessibilityIdentifier("integrations.destination.feedback.toast")
    }

    private var confirmationTitle: String {
        guard let confirmation = model.pendingConfirmation else {
            return l10n.text(.integrationsDisconnectTitle)
        }
        switch confirmation {
        case .disconnect(let host):
            return l10n.format(.integrationsDisconnectConfirm, host.displayName)
        case .clearReceiptHistory(let host):
            return l10n.format(.integrationsClearReceiptHistoryConfirm, host.displayName)
        }
    }

    @ViewBuilder
    private func confirmationButtons(
        _ confirmation: IntegrationDestinationConfirmation
    ) -> some View {
        switch confirmation {
        case .disconnect(let host):
            Button(l10n.format(.actionDisconnect, host.displayName), role: .destructive) {
                submitConfirmation(confirmation)
            }
            Button(l10n.text(.commonCancel), role: .cancel) {
                model.cancelPendingAction()
            }
        case .clearReceiptHistory(let host):
            Button(l10n.format(.actionClearReceiptHistory, host.displayName), role: .destructive) {
                submitConfirmation(confirmation)
            }
            Button(l10n.text(.commonCancel), role: .cancel) {
                model.cancelPendingAction()
            }
        }
    }

    private func submitConfirmation(
        _ confirmation: IntegrationDestinationConfirmation
    ) {
        guard let action = model.consumePendingAction(confirmation) else { return }
        Task { await model.perform(action) }
    }

    private func confirmationMessage(_ confirmation: IntegrationDestinationConfirmation) -> String {
        switch confirmation {
        case .disconnect(let host):
            return l10n.format(.integrationsDisconnectMessage, host.displayName)
        case .clearReceiptHistory(let host):
            return l10n.format(.integrationsClearReceiptHistoryMessage, host.displayName)
        }
    }

    private func applyFocusRequest(_ target: IntegrationDestinationFocusTarget?) {
        switch target {
        case .title:
            focusedTarget = .title
        case .agent(let host) where model.agent(for: host) != nil:
            focusedTarget = .agent(host)
        case .toggle(let host) where model.agent(for: host) != nil:
            focusedTarget = .toggle(host)
        case .connectionRow(let kind) where model.connectionSection?.row(kind) != nil:
            focusedTarget = .connectionRow(kind)
        case .copyConfigurationSource(let host)
        where model.selectedHostFacts?.configurationSource != nil && model.selectedHost == host:
            focusedTarget = .copyConfigurationSource(host)
        default:
            focusedTarget =
                model.selectedHost.map(IntegrationDestinationFocusTarget.agent)
                ?? model.agentControls.first.map { .agent($0.host) }
        }
    }

    private func reconcileFocus() {
        guard let focusedTarget else { return }
        switch focusedTarget {
        case .title:
            break
        case .agent(let host), .toggle(let host):
            guard model.agent(for: host) != nil else { self.focusedTarget = nil; return }
        case .connectionRow(let kind):
            guard model.connectionSection?.row(kind) != nil else {
                self.focusedTarget = nil; return
            }
        case .copyConfigurationSource(let host):
            guard model.selectedHostFacts?.configurationSource != nil,
                model.selectedHost == host
            else { self.focusedTarget = nil; return }
        case .dismissFeedback:
            break
        }
    }

    private func announceFeedbackIfNeeded() {
        guard model.isWindowVisible, model.isWindowKey,
            let sentence = feedbackAnnouncer.consume(
                model.feedback,
                language: languageStore.language)
        else { return }
        onAnnouncement(sentence)
    }

    private func localizedAgentStatus(_ status: HostSourceRowStatus) -> String {
        switch status {
        case .ready: return l10n.text(.integrationsStatusReady)
        case .awaitingActivation: return l10n.text(.integrationsStatusAwaiting)
        case .legacy: return l10n.text(.integrationsStatusLegacy)
        case .notConnected: return l10n.text(.integrationsStatusNotConnected)
        case .needsAttention: return l10n.text(.integrationsStatusNeedsAttention)
        }
    }

    private func localizedConnectionRowTitle(_ kind: IntegrationConnectionRowKind) -> String {
        switch kind {
        case .connectionStatus: return l10n.text(.integrationsConnection)
        case .mechanism: return l10n.text(.integrationsMechanism)
        case .eventsAndSounds: return l10n.text(.integrationsEventsAndSounds)
        case .receiptHistory: return l10n.text(.integrationsReceiptHistory)
        }
    }

    private func localizedConnectionRowCaption(
        _ kind: IntegrationConnectionRowKind,
        facts: IntegrationDestinationHostFacts
    ) -> String {
        switch kind {
        case .connectionStatus:
            let localizedRow = localizedHostSourceRow(
                facts.row,
                language: languageStore.language)
            let diagnosis: String
            if facts.status == .ready, facts.latestReceiptEvidence != nil {
                diagnosis = l10n.text(.integrationsActivatedDescription)
            } else {
                switch facts.status {
                case .notConnected: diagnosis = l10n.text(.integrationsNotConnectedDescription)
                case .needsAttention:
                    diagnosis =
                        localizedRow.detailText ?? l10n.text(.integrationsNeedsAttentionDescription)
                case .ready, .awaitingActivation, .legacy:
                    diagnosis = l10n.text(.integrationsConfiguredWaitingDescription)
                }
            }
            let diagnosisWithDetail: String
            if facts.status == .needsAttention {
                diagnosisWithDetail = diagnosis
            } else if let detail = localizedRow.detailText {
                diagnosisWithDetail = "\(diagnosis) \(detail)"
            } else {
                diagnosisWithDetail = diagnosis
            }
            if let receipt = localizedReceipt(facts) {
                return "\(diagnosisWithDetail) \(l10n.format(.integrationsLatestReceipt, receipt))"
            }
            return "\(diagnosisWithDetail) \(l10n.text(.integrationsNoReceipt))"
        case .mechanism:
            let mechanism = localizedMechanism(facts.mechanism)
            guard let source = facts.configurationSource else {
                return "\(mechanism) · \(l10n.text(.integrationsNoConfigurationSource))"
            }
            let configurationSourceValue = l10n.format(
                .integrationsConfigurationSourceValue,
                abbreviatedConfigurationPath(source))
            return "\(mechanism) · \(configurationSourceValue)"
        case .eventsAndSounds:
            if facts.host == .workBuddy { return l10n.text(.integrationsWorkBuddySoundsCaption) }
            return l10n.text(.integrationsSurfaceEventsCaption)
        case .receiptHistory:
            return l10n.text(.integrationsReceiptHistoryPolicy)
        }
    }

    private func localizedMechanism(_ mechanism: HostIntegrationMechanism) -> String {
        switch mechanism {
        case .nativeHooks: return l10n.text(.integrationsMechanismNativeHooks)
        case .accessibilityBeta: return l10n.text(.integrationsMechanismAccessibilityBeta)
        }
    }

    private func localizedReceipt(_ facts: IntegrationDestinationHostFacts) -> String? {
        guard let evidence = facts.latestReceiptEvidence else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(facts.host.displayName) · "
            + "\(localizedEventName(evidence.event, language: languageStore.language)) · "
            + "\(formatter.string(from: evidence.timestamp)) · "
            + localizedPlaybackResult(evidence.playbackResult, language: languageStore.language)
    }

    private func localizedInFlightStatus(
        _ operation: IntegrationDestinationInFlightPresentation
    ) -> String {
        switch operation.action {
        case .redetect: return l10n.text(.actionRedetectInProgress)
        case .connect: return l10n.text(.actionConnectInProgress)
        case .repair:
            return operation.isUpgrade
                ? l10n.text(.actionUpgradeInProgress)
                : l10n.text(.actionRepairInProgress)
        case .disconnect: return l10n.text(.actionDisconnectInProgress)
        case .clearReceiptHistory: return l10n.text(.actionClearReceiptHistoryInProgress)
        case .copyHooksCommand: return l10n.text(.actionCopyHooks)
        }
    }

    private func perform(_ action: HostIntegrationUserAction) {
        Task { await model.perform(action) }
    }

    private func feedbackSymbol(_ kind: IntegrationsFeedbackKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    private func feedbackColor(_ kind: IntegrationsFeedbackKind) -> Color {
        switch kind {
        case .success: return ClaudioTheme.success(colorScheme)
        case .information: return SettingsAppearance.accent(colorScheme)
        case .failure: return ClaudioTheme.error(colorScheme)
        }
    }
}
