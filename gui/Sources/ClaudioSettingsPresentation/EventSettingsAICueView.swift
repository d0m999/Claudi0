import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Foundation
import SoundPacksWindow
import SwiftUI

@MainActor
struct EventSettingsAICueServiceCard: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences
    let compact: Bool
    let onManageCredential: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences,
        compact: Bool = false,
        onManageCredential: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
        self.compact = compact
        self.onManageCredential = onManageCredential
    }

    var body: some View {
        let status = statusPresentation
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SettingsAppearance.accent(colorScheme))
                        .frame(width: 30, height: 30)
                        .background(SettingsAppearance.accent(colorScheme).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: SettingsAppearance.groupRadius))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.text(.aiCueServiceTitle))
                            .font(SettingsAppearance.font(.body).weight(.semibold))
                            .foregroundColor(SettingsAppearance.text(colorScheme))

                    }
                }
            }

            SettingsControlRow(title: l10n.text(.aiCueProviderLabel)) {
                SettingsNativePopUp(
                    l10n.text(.aiCueProviderLabel),
                    selection: Binding(
                        get: { viewModel.providerProfileID },
                        set: { profileID in
                            try? viewModel.selectProviderProfile(profileID)
                            Task {
                                await viewModel.refreshCredentialStatus()
                            }
                        }),
                    options: viewModel.availableProviderProfiles.map {
                        SettingsMenuOption($0.id, l10n.text($0.displayNameKey))
                    }, identifier: "event-settings.ai-cue.provider-profile"
                )
                .fixedSize(horizontal: true, vertical: false)
                .disabled(
                    viewModel.phase == .adopting
                        || viewModel.credentialActivity != .idle
                )
                .accessibilityLabel(l10n.text(.aiCueProviderLabel))
                .accessibilityValue(l10n.text(viewModel.providerProfile.displayNameKey))
                .accessibilityHint(capabilityText)
                .accessibilityIdentifier("event-settings.ai-cue.provider-profile")
                .soundPacksLayoutProbe("event-settings.ai-cue.provider-profile.control")
            }
            .soundPacksLayoutProbe("event-settings.ai-cue.provider-profile.row")

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .foregroundColor(status.symbolColor)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .font(SettingsAppearance.font(.caption).weight(.medium))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    l10n.text(viewModel.providerProfile.displayNameKey) + " · " + status.text
                )
                .accessibilityIdentifier("event-settings.ai-cue.credential-status")
                Spacer(minLength: 8)
                Button(manageButtonTitle, action: onManageCredential)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(manageButtonTitle)
                    .accessibilityIdentifier("event-settings.ai-cue.credential-manage")
            }
        }
        .settingsSectionSurface(padding: SettingsAppearance.controlRowHorizontalPadding)
        .tint(SettingsAppearance.accent(colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.service")
    }

    private var statusPresentation: (text: String, symbol: String, symbolColor: Color) {
        if viewModel.credentialActivity != .idle {
            return (
                l10n.text(aiCueCredentialActivityKey(viewModel.credentialActivity)),
                "clock.arrow.circlepath",
                SettingsAppearance.secondaryText(colorScheme)
            )
        }
        switch viewModel.credentialStatus {
        case nil:
            return (
                l10n.text(.aiCueServiceChecking),
                "clock.arrow.circlepath",
                SettingsAppearance.secondaryText(colorScheme)
            )
        case .missing:
            return (
                l10n.text(.aiCueServiceMissing),
                "key.slash",
                SettingsAppearance.secondaryText(colorScheme)
            )
        case .stored(_, true):
            return (
                l10n.text(.aiCueServicePendingReplacement),
                "arrow.triangle.2.circlepath",
                SettingsAppearance.secondaryText(colorScheme)
            )
        case .stored(.verified, false):
            return (
                l10n.text(.aiCueServiceStoredVerified),
                "checkmark.circle.fill",
                ClaudioTheme.success(colorScheme)
            )
        case .stored(.deferred, false):
            return (
                l10n.text(.aiCueServiceStoredDeferred),
                "clock.badge.checkmark",
                SettingsAppearance.secondaryText(colorScheme)
            )
        case .stored(.rejected, false):
            return (
                l10n.text(.aiCueServiceStoredRejected),
                "xmark.circle.fill",
                ClaudioTheme.error(colorScheme)
            )
        case .unavailable:
            return (
                l10n.text(.aiCueServiceUnavailable),
                "xmark.circle.fill",
                ClaudioTheme.error(colorScheme)
            )
        }
    }

    private var manageButtonTitle: String {
        if case .stored = viewModel.credentialStatus {
            return l10n.text(.aiCueManageKey)
        }
        return l10n.text(.aiCueConfigureKey)
    }

    private var capabilityText: String {
        let modalities = AICueModality.allCases
            .filter(viewModel.providerProfile.supportedModalities.contains)
            .map { l10n.text(aiCueModalityKey($0)) }
            .joined(separator: languageStore.language == .english ? ", " : "，")
        return l10n.format(.aiCueProviderCapabilities, modalities)
    }
}

@MainActor
struct EventSettingsAICueComposerView: View {
    private enum DescriptionFocus: Hashable {
        case editor
    }

    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences
    let eventTitle: String
    let playingCandidateID: UUID?
    let adoptionEnabled: Bool
    let generationEnabled: Bool
    let onGenerate: (() -> Void)?
    let attributionDisclosure: String?
    let adoptionUnavailableHint: String
    let onConfigureCredential: () -> Void
    let onPreviewCandidate: (AICueCandidate) -> Void
    let onAdoptCandidate: (UUID) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var descriptionFocus: DescriptionFocus?

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences,
        eventTitle: String,
        playingCandidateID: UUID?,
        adoptionEnabled: Bool,
        generationEnabled: Bool = true,
        onGenerate: (() -> Void)? = nil,
        attributionDisclosure: String? = nil,
        adoptionUnavailableHint: String,
        onConfigureCredential: @escaping () -> Void,
        onPreviewCandidate: @escaping (AICueCandidate) -> Void,
        onAdoptCandidate: @escaping (UUID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
        self.eventTitle = eventTitle
        self.playingCandidateID = playingCandidateID
        self.adoptionEnabled = adoptionEnabled
        self.generationEnabled = generationEnabled
        self.onGenerate = onGenerate
        self.attributionDisclosure = attributionDisclosure
        self.adoptionUnavailableHint = adoptionUnavailableHint
        self.onConfigureCredential = onConfigureCredential
        self.onPreviewCandidate = onPreviewCandidate
        self.onAdoptCandidate = onAdoptCandidate
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(l10n.format(.aiCueComposerTitle, eventTitle))
                    .font(SettingsAppearance.font(.sectionTitle).weight(.bold))
                    .foregroundColor(SettingsAppearance.text(colorScheme))
                Spacer(minLength: 8)
                Button(l10n.text(.commonClose), action: onClose)
                    .buttonStyle(ClaudioCompactButtonStyle())
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .accessibilityLabel(l10n.text(.commonClose))
                    .accessibilityIdentifier("event-settings.ai-cue.close")
            }

            if let failure = viewModel.failure {
                errorNotice(
                    aiCueFailureText(
                        failure, providerProfileID: viewModel.providerProfileID, l10n: l10n))
            }

            phaseContent
        }
        .padding(.top, 12)
        .tint(SettingsAppearance.accent(colorScheme))
        .accessibilityElement(children: .contain)
        .settingsMountIdentity("event-settings.ai-cue.composer")
        .onChange(of: viewModel.phase) { _ in
            // Clear outgoing focus first; replacement tasks yield so this cannot overwrite
            // their focus request while SwiftUI reconciles the native hosts.
            descriptionFocus = nil
        }
    }

    private var phaseContent: AnyView {
        switch viewModel.phase {
        case .editing, .generating: AnyView(descriptionStep)
        case .candidatesReady, .adopting: AnyView(candidatesStep)
        case .applied: AnyView(appliedStep)
        }
    }

    private var descriptionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text(.aiCueDescriptionLabel))
                .font(SettingsAppearance.font(.body).weight(.semibold))
                .foregroundColor(SettingsAppearance.text(colorScheme))
            Text(l10n.text(.aiCueDescriptionHelp))
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))

            ZStack(alignment: .topLeading) {
                if viewModel.soundDescription.isEmpty {
                    Text(l10n.text(.aiCueDescriptionPlaceholder))
                        .font(SettingsAppearance.font(.body))
                        .foregroundColor(
                            SettingsAppearance.secondaryText(colorScheme).opacity(0.75)
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                Group {
                    if viewModel.phase == .generating {
                        ScrollView(.vertical) {
                            Text(viewModel.soundDescription)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 9)
                        }
                        .frame(height: 92)
                        .accessibilityElement(children: .ignore)
                        .accessibilityValue(viewModel.soundDescription)
                    } else {
                        TextEditor(
                            text: Binding(
                                get: { viewModel.soundDescription },
                                set: { viewModel.updateDescription($0) })
                        )
                        .focused($descriptionFocus, equals: .editor)
                        .task {
                            await Task.yield()
                            guard viewModel.phase == .editing, !Task.isCancelled else { return }
                            descriptionFocus = .editor
                        }
                    }
                }
                .font(SettingsAppearance.font(.body))
                .frame(minHeight: 92)
                .padding(4)
                .background(SettingsAppearance.background(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control)
                        .stroke(SettingsAppearance.hairline(colorScheme), lineWidth: 1)
                )
                .accessibilityLabel(l10n.text(.aiCueDescriptionLabel))
                .accessibilityHint(
                    l10n.text(
                        viewModel.phase == .generating
                            ? .aiCueDescriptionLocked : .aiCueDescriptionHelp)
                )
                .accessibilityIdentifier("event-settings.ai-cue.description")
            }

            if viewModel.phase == .generating {
                Text(l10n.text(.aiCueDescriptionLocked))
                    .font(SettingsAppearance.font(.caption))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
            }

            HStack(spacing: 10) {
                Spacer()
                if viewModel.phase == .generating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(l10n.text(.aiCueGenerating))
                    Text(l10n.text(.aiCueGenerating))
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    cancelGenerationButton
                        .accessibilityLabel(l10n.text(.commonCancel))
                        .accessibilityIdentifier("event-settings.ai-cue.cancel-generation")
                } else {
                    Button(
                        l10n.text(
                            viewModel.requiresCredentialConfiguration
                                ? .aiCueConfigureKey : .aiCueGenerateCue)
                    ) {
                        if viewModel.requiresCredentialConfiguration {
                            onConfigureCredential()
                        } else if generationEnabled {
                            if let onGenerate {
                                onGenerate()
                            } else {
                                viewModel.startGeneration(locale: languageStore.language.rawValue)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!generationEnabled)
                    .accessibilityLabel(
                        l10n.text(
                            viewModel.requiresCredentialConfiguration
                                ? .aiCueConfigureKey : .aiCueGenerateCue)
                    )
                    .accessibilityHint(l10n.text(.aiCueGenerateHint))
                    .accessibilityIdentifier("event-settings.ai-cue.generate")
                    .soundPacksLayoutProbe("event-settings.ai-cue.generate.control")
                }
            }

        }
    }

    private var cancelGenerationButton: some View {
        SettingsFocusableButton(l10n.text(.commonCancel), requestsFocus: true) {
            viewModel.returnToDescription()
        }
        .fixedSize()
    }

    private var candidatesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.text(.aiCuePreviewAndChoose))
                .font(SettingsAppearance.font(.sectionTitle))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.text(.aiCueDescriptionSummary))
                        .font(SettingsAppearance.font(.caption).weight(.semibold))
                        .foregroundColor(SettingsAppearance.text(colorScheme))
                    Text(viewModel.soundDescription)
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Button(l10n.text(.aiCueModifyDescription)) {
                    viewModel.returnToDescription()
                }
                .disabled(viewModel.phase == .adopting)
                .accessibilityLabel(l10n.text(.aiCueModifyDescription))
                .accessibilityIdentifier("event-settings.ai-cue.modify-description")
            }
            .padding(10)
            .background(SettingsAppearance.background(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                    .stroke(SettingsAppearance.hairline(colorScheme), lineWidth: 1)
            )

            Text(l10n.text(.aiCueNameLabel))
                .font(SettingsAppearance.font(.body).weight(.semibold))
                .foregroundColor(SettingsAppearance.text(colorScheme))
            TextField(
                l10n.text(.aiCueNameLabel),
                text: Binding(
                    get: { viewModel.displayName },
                    set: { viewModel.updateDisplayName($0) })
            )
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.phase == .adopting)
            .accessibilityLabel(l10n.text(.aiCueNameLabel))
            .accessibilityHint(l10n.text(.aiCueNameHelp))
            .accessibilityIdentifier("event-settings.ai-cue.name")
            Text(l10n.text(.aiCueNameHelp))
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
            if (try? AICueDisplayName(viewModel.displayName)) == nil {
                Text(
                    l10n.text(
                        viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            ? .aiCueErrorNameRequired : .aiCueErrorNameInvalid)
                )
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(ClaudioTheme.error(colorScheme))
                .accessibilityIdentifier("event-settings.ai-cue.name-error")
            }

            if let generation = viewModel.generation {
                if let attributionDisclosure {
                    Text(attributionDisclosure)
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if generation.completion == .partial {
                    partialCandidateNotice(count: generation.candidates.count)
                }
                VStack(spacing: 0) {
                    ForEach(Array(generation.candidates.enumerated()), id: \.element.id) {
                        index, candidate in
                        if index != 0 { Divider() }
                        candidateRow(candidate)
                    }
                }
            }

            HStack {
                Text(l10n.text(.aiCueRegenerate))
                    .font(SettingsAppearance.font(.caption))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                    .accessibilityHidden(true)
                Spacer()
                Button(l10n.text(.aiCueRegenerate)) {
                    if generationEnabled {
                        if let onGenerate {
                            onGenerate()
                        } else {
                            viewModel.startGeneration(locale: languageStore.language.rawValue)
                        }
                    }
                }
                .disabled(viewModel.phase == .adopting || !generationEnabled)
                .accessibilityLabel(l10n.text(.aiCueRegenerate))
                .accessibilityHint(l10n.text(.aiCueGenerateHint))
                .accessibilityIdentifier("event-settings.ai-cue.regenerate")
            }
        }
    }

    private func candidateRow(_ candidate: AICueCandidate) -> some View {
        HStack(spacing: 10) {
            Button {
                onPreviewCandidate(candidate)
            } label: {
                Label(
                    l10n.text(
                        playingCandidateID == candidate.id
                            ? .aiCueCandidateStopAction : .soundPacksPreview),
                    systemImage: playingCandidateID == candidate.id ? "stop.fill" : "play.fill"
                )
                .claudioPreviewPulse(
                    trigger: playingCandidateID == candidate.id ? 1 : 0)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(candidatePreviewLabel(candidate))
            .accessibilityIdentifier(
                "event-settings.ai-cue.candidate.\(candidateIdentifierComponent(candidate)).preview"
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    localizedAICueCandidateTitle(
                        candidate.identity,
                        language: languageStore.language)
                )
                .font(SettingsAppearance.font(.body).weight(.semibold))
                .foregroundColor(SettingsAppearance.text(colorScheme))
                Text(candidateDuration(candidate))
                    .font(SettingsAppearance.font(.caption))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
            }

            Spacer(minLength: 8)

            if viewModel.adoptingCandidateID == candidate.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(l10n.text(.aiCueUseForEvent))
            }
            Button(l10n.format(.aiCueUseNamedEvent, eventTitle)) {
                onAdoptCandidate(candidate.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.phase == .adopting || !adoptionEnabled
                    || (try? AICueDisplayName(viewModel.displayName)) == nil
            )
            .accessibilityLabel(
                localizedAICueCandidateUseAccessibilityLabel(
                    identity: candidate.identity,
                    language: languageStore.language)
                    + " · " + l10n.format(.aiCueUseNamedEvent, eventTitle)
            )
            .accessibilityHint(
                adoptionEnabled
                    ? l10n.format(.aiCueUseNamedEvent, eventTitle) : adoptionUnavailableHint
            )
            .accessibilityIdentifier(
                "event-settings.ai-cue.candidate.\(candidateIdentifierComponent(candidate)).use")
        }
        .frame(minHeight: 61)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "event-settings.ai-cue.candidate.\(candidateIdentifierComponent(candidate)).row")
    }

    private var appliedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(ClaudioTheme.success(colorScheme))
                    .accessibilityHidden(true)
                Text(l10n.text(.aiCueAppliedTitle))
                    .foregroundColor(SettingsAppearance.text(colorScheme))
            }
            .font(SettingsAppearance.font(.sectionTitle).weight(.semibold))
            .accessibilityElement(children: .combine)
            if let outcome = viewModel.adoptionOutcome {
                Text(l10n.format(.aiCueAppliedMessage, outcome.finalDisplayName))
                    .font(SettingsAppearance.font(.body))
                    .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
            }
            Button(l10n.text(.commonClose), action: onClose)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(l10n.text(.commonClose))
                .accessibilityIdentifier("event-settings.ai-cue.applied-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-settings.ai-cue.applied")
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ClaudioTheme.error(colorScheme))
                .accessibilityHidden(true)
            Text(message)
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.error")
    }

    private func partialCandidateNotice(count: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ClaudioTheme.warning(colorScheme))
                .accessibilityHidden(true)
            Text(l10n.format(.aiCueCandidatePartial, Int64(count)))
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.partial")
    }

    private func candidateDuration(_ candidate: AICueCandidate) -> String {
        let seconds = Double(candidate.durationMilliseconds) / 1_000
        let value = String(format: "%.1f", seconds)
        return l10n.format(.aiCueCandidateDuration, value)
    }

    private func candidatePreviewLabel(_ candidate: AICueCandidate) -> String {
        localizedAICueCandidatePreviewAccessibilityLabel(
            identity: candidate.identity,
            duration: candidateDuration(candidate),
            isPlaying: playingCandidateID == candidate.id,
            language: languageStore.language)
    }

    private func candidateIdentifierComponent(_ candidate: AICueCandidate) -> String {
        aiCueCandidateAccessibilityIdentifierComponent(candidate.identity)
    }
}

@MainActor
struct EventSettingsAICueCredentialSheet: View {
    @ObservedObject var viewModel: AICueGenerationViewModel
    @ObservedObject var languageStore: ClaudioPreferences
    var onDone: (() -> Void)?

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var keyInput = ""
    @State private var inputError: AICueCredentialInputError?
    @State private var confirmsDeletion = false

    private var l10n: ClaudioL10n { ClaudioL10n(language: languageStore.language) }

    init(
        viewModel: AICueGenerationViewModel,
        languageStore: ClaudioPreferences,
        onDone: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.languageStore = languageStore
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(credentialTitle)
                .font(SettingsAppearance.pageTitle)
                .foregroundColor(SettingsAppearance.text(colorScheme))

            Text(l10n.text(viewModel.providerProfile.privacyDisclosureKey))
                .font(SettingsAppearance.font(.body))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.text(viewModel.providerProfile.credentialStorageDisclosureKey))
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.credentialActivity != .idle {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(l10n.text(aiCueCredentialActivityKey(viewModel.credentialActivity)))
                        .font(SettingsAppearance.font(.caption))
                        .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("event-settings.ai-cue.credential-activity")
            }

            Text(l10n.text(.aiCueCredentialKeyLabel))
                .font(SettingsAppearance.font(.body).weight(.semibold))
            SecureField(l10n.text(.aiCueCredentialKeyLabel), text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityLabel(l10n.text(.aiCueCredentialKeyLabel))
                .accessibilityIdentifier("event-settings.ai-cue.credential-input")

            if let inputError {
                credentialErrorNotice(credentialInputErrorText(inputError, l10n: l10n))
            } else if let failure = viewModel.credentialFailure {
                credentialErrorNotice(
                    aiCueCredentialFailureText(
                        failure,
                        providerProfileID: viewModel.providerProfileID,
                        credentialStatus: viewModel.credentialStatus,
                        l10n: l10n))
            }

            HStack(spacing: 10) {
                if case .stored(_, true) = viewModel.credentialStatus {
                    Button(l10n.text(.aiCueCredentialCancelReplacement)) {
                        Task {
                            await viewModel.cancelPendingCredentialReplacement()
                        }
                    }
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(l10n.text(.aiCueCredentialCancelReplacement))
                    .accessibilityIdentifier(
                        "event-settings.ai-cue.credential-cancel-replacement")
                }
                if case .stored = viewModel.credentialStatus {
                    Button(l10n.text(.aiCueCredentialDelete), role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(viewModel.credentialActivity != .idle)
                    .accessibilityLabel(l10n.text(.aiCueCredentialDelete))
                    .accessibilityIdentifier("event-settings.ai-cue.credential-delete")
                }
                Spacer()
                Button(l10n.text(.commonCancel)) {
                    keyInput = ""
                    if let onDone { onDone() } else { presentationMode.wrappedValue.dismiss() }
                }
                .accessibilityLabel(l10n.text(.commonCancel))
                .accessibilityIdentifier("event-settings.ai-cue.credential-cancel")

                Button(saveButtonTitle) {
                    submitCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyInput.isEmpty || viewModel.credentialActivity != .idle)
                .accessibilityLabel(saveButtonTitle)
                .accessibilityIdentifier("event-settings.ai-cue.credential-save")
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(SettingsAppearance.background(colorScheme))
        .tint(SettingsAppearance.accent(colorScheme))
        .alert(
            l10n.text(.aiCueCredentialDeleteTitle),
            isPresented: $confirmsDeletion
        ) {
            Button(l10n.text(.commonCancel), role: .cancel) {}
            Button(l10n.text(.commonDeletePermanently), role: .destructive) {
                Task {
                    await viewModel.deleteCredential()
                    if viewModel.credentialStatus == .missing {
                        if let onDone { onDone() } else { presentationMode.wrappedValue.dismiss() }
                    }
                }
            }
        } message: {
            Text(l10n.text(.aiCueCredentialDeleteMessage))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(credentialTitle)
        .settingsMountIdentity("event-settings.ai-cue.credential-sheet")
    }

    private var credentialTitle: String {
        l10n.format(
            .aiCueCredentialTitle,
            l10n.text(viewModel.providerProfile.displayNameKey))
    }

    private var saveButtonTitle: String {
        switch viewModel.providerProfile.credentialValidationPolicy {
        case .readOnlyProbe: return l10n.text(.aiCueCredentialValidateSave)
        case .deferredUntilExplicitGeneration: return l10n.text(.aiCueCredentialSave)
        }
    }

    private func submitCredential() {
        let credential: SensitiveCredentialInput
        do {
            credential = try SensitiveCredentialInput(keyInput)
        } catch let error as AICueCredentialInputError {
            inputError = error
            return
        } catch {
            inputError = .empty
            return
        }
        inputError = nil
        keyInput = ""
        Task {
            await viewModel.saveCredential(credential)
            if viewModel.credentialFailure == nil,
                case .stored = viewModel.credentialStatus
            {
                if let onDone { onDone() } else { presentationMode.wrappedValue.dismiss() }
            }
        }
    }

    private func credentialErrorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ClaudioTheme.error(colorScheme))
                .accessibilityHidden(true)
            Text(message)
                .font(SettingsAppearance.font(.caption))
                .foregroundColor(SettingsAppearance.secondaryText(colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("event-settings.ai-cue.credential-error")
    }
}

private func credentialInputErrorText(
    _ error: AICueCredentialInputError,
    l10n: ClaudioL10n
) -> String {
    switch error {
    case .empty, .tooLong, .containsControlCharacters:
        return l10n.text(.aiCueErrorCredentialInvalid)
    }
}

private func aiCueCredentialActivityKey(
    _ activity: AICueCredentialActivity
) -> ClaudioL10nKey {
    switch activity {
    case .idle: return .aiCueServiceChecking
    case .probing: return .aiCueCredentialProbing
    case .saving: return .aiCueCredentialSaving
    case .pendingReplacement: return .aiCueCredentialUpdatingReplacement
    case .deleting: return .aiCueCredentialDeleting
    }
}

func aiCueModalityKey(_ modality: AICueModality) -> ClaudioL10nKey {
    switch modality {
    case .speech: return .aiCueModalitySpeech
    case .animal: return .aiCueModalityAnimal
    case .soundEffect: return .aiCueModalitySoundEffect
    case .mixed: return .aiCueModalityMixed
    }
}

package func aiCueCredentialFailureText(
    _ failure: AICueCredentialFailure,
    providerProfileID: AICueProviderProfileID,
    credentialStatus: AICueCredentialStatus?,
    l10n: ClaudioL10n
) -> String {
    switch failure {
    case .provider(.invalidCredential), .provider(.forbidden):
        return l10n.text(.aiCueErrorCredentialInvalid)
    case .provider(.requiredModelsUnavailable):
        guard providerProfileID == .senseAudioChina else {
            return l10n.text(.aiCueErrorCredentialValidationFailed)
        }
        if case .stored = credentialStatus {
            return l10n.text(.aiCueErrorRequiredVoiceUnavailableExistingKey)
        }
        return l10n.text(.aiCueErrorRequiredVoiceUnavailable)
    case .provider(.insufficientCredits):
        return l10n.text(.aiCueErrorCredits)
    case .provider(.rateLimited):
        return l10n.text(.aiCueErrorRateLimited)
    case .provider:
        return l10n.text(.aiCueErrorCredentialValidationFailed)
    case .storageUnavailable:
        return l10n.text(
            providerProfileID == .senseAudioChina
                ? .aiCueErrorLocalCredentialUnavailable : .aiCueErrorCredentialUnavailable)
    }
}

package func aiCueFailureText(
    _ failure: AICueComposerFailure,
    providerProfileID: AICueProviderProfileID,
    l10n: ClaudioL10n
) -> String {
    switch failure {
    case .generation(.validation(.emptyDescription)):
        return l10n.text(.aiCueErrorDescriptionRequired)
    case .generation(.validation(.descriptionTooLong)):
        return l10n.text(.aiCueErrorDescriptionTooLong)
    case .generation(.validation(.spokenContentRequired)):
        return l10n.text(.aiCueErrorSpeechNeedsText)
    case .generation(.validation(.invalidLocale)),
        .generation(.requestCompilation(.unsupportedLocale)):
        return l10n.text(.aiCueErrorUnsupportedLocale)
    case .generation(.requestCompilation(.unsupportedModality)):
        return l10n.text(.aiCueErrorUnsupportedModality)
    case .generation(.requestCompilation(.spokenContentRequired)):
        return l10n.text(.aiCueErrorSpeechNeedsText)
    case .generation(.credentialRequired):
        return l10n.text(.aiCueErrorCredentialRequired)
    case .generation(.credentialUnavailable):
        return aiCueCredentialFailureText(
            .storageUnavailable, providerProfileID: providerProfileID, credentialStatus: nil,
            l10n: l10n)
    case .generation(.provider(.invalidCredential)),
        .generation(.provider(.forbidden)):
        return l10n.text(.aiCueErrorCredentialInvalid)
    case .generation(.provider(.requiredModelsUnavailable)):
        return l10n.text(.aiCueErrorGeneration)
    case .generation(.provider(.insufficientCredits)):
        return l10n.text(.aiCueErrorCredits)
    case .generation(.provider(.rateLimited)):
        return l10n.text(.aiCueErrorRateLimited)
    case .generation(.audioTooLarge), .generation(.unsupportedAudio),
        .generation(.audioDurationUnavailable), .generation(.audioTooLong):
        return l10n.text(.aiCueErrorAudioInvalid)
    case .generation(.insufficientValidCandidates):
        return l10n.text(.aiCueErrorNoValidCandidates)
    case .generation:
        return l10n.text(.aiCueErrorGeneration)
    case .displayName(.emptyDisplayName):
        return l10n.text(.aiCueErrorNameRequired)
    case .displayName:
        return l10n.text(.aiCueErrorNameInvalid)
    case .adoption(.importedButNotBound):
        return l10n.text(.aiCueErrorAdoptionPartial)
    case .adoption(.targetChanged):
        return l10n.text(.aiCueErrorAdoptionTarget)
    case .adoption:
        return l10n.text(.aiCueErrorAdoption)
    }
}
