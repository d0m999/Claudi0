import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import Combine
import SwiftUI

@MainActor
struct AboutSettingsView: View {
    @ObservedObject var model: AboutSettingsModel
    @ObservedObject var preferences: ClaudioPreferences
    let focusedTarget: FocusState<SettingsWindowFocusTarget?>.Binding
    let onAnnouncement: @MainActor (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var unknown: String { l10n.text(.settingsAboutUnknown) }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            identity
            SettingsSectionCard(
                title: l10n.text(.settingsAboutResourcesTitle),
                description: l10n.text(.settingsAboutResourcesDescription),
                padding: SettingsAppearance.controlRowHorizontalPadding
            ) { resources }
            SettingsSectionCard(
                title: l10n.text(.settingsAboutDiagnosticsTitle),
                description: l10n.text(.settingsAboutDiagnosticsDescription)
            ) { diagnostics }

            if let feedback = model.feedback {
                Label {
                    Text(feedbackText(feedback))
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: feedbackIcon(feedback))
                        .foregroundColor(
                            feedback.isFailure
                                ? ClaudioTheme.error(colorScheme)
                                : ClaudioTheme.success(colorScheme))
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.about.feedback")
            }
        }
        .font(SettingsAppearance.font(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsMountIdentity(SettingsPresentationAccessibilityID.destination(.about))
        .onReceive(model.$feedback.dropFirst().compactMap { $0 }) { feedback in
            onAnnouncement(feedbackText(feedback))
        }
    }

    private var identity: some View {
        // T2 关于页形制（2026-10-11 品牌修订；2026-10-15 简化）：96pt 酸柠容器 + 产品名，
        // 纵向居中排列（与主原型 about-identity 同结构）。横向字标与品牌行已移除；事实行与
        // 复制按钮保持在身份块内，原有键盘焦点与无障碍接线不变。
        VStack(spacing: 14) {
            VStack(alignment: .center, spacing: 14) {
                ClaudioT2Badge(size: 96, cornerRadius: 23, glyphSize: 60, dropShadow: true)
                Text(model.bundleFacts.productName ?? unknown)
                    .font(SettingsAppearance.font(.productTitle))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.about.identity")

            VStack(alignment: .leading, spacing: 0) {
                factRow(.settingsAboutVersion, value: model.bundleFacts.version)
                Divider()
                factRow(.settingsAboutBuild, value: model.bundleFacts.build)
                Divider()
                factRow(.settingsAboutArchitecture, value: model.bundleFacts.architecture)
                Divider()
                factRow(.settingsAboutMinimumMacOS, value: model.bundleFacts.minimumSystemVersion)
                Divider()
                factRow(.settingsAboutCurrentMacOS, value: model.bundleFacts.operatingSystemVersion)
            }.settingsSectionSurface(padding: 0)

            SettingsFocusableButton(
                l10n.text(.settingsAboutCopyVersion),
                requestsFocus: focusedTarget.wrappedValue == .firstAction(.about)
            ) {
                model.copyVersionInformation(language: preferences.language)
            }
            .focused(focusedTarget, equals: .firstAction(.about))
            .accessibilityHint(l10n.text(.settingsAboutCopyVersionHint))
            .accessibilityIdentifier("settings.about.copy-version")
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {

            ForEach(Array(model.resources.enumerated()), id: \.element.id) { index, resource in
                if index > 0 { Divider() }
                let presentation = resourcePresentation(resource.kind)
                if resource.url != nil {
                    EventAnimationActionButton(
                        title: presentation.name,
                        identifier: "settings.about.resource.\(resource.kind.rawValue)",
                        action: { model.openResource(resource) }
                    ) {
                        HStack {
                            Label(presentation.name, systemImage: presentation.icon)
                            Spacer(minLength: 12)
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
                        .frame(minHeight: SettingsAppearance.controlRowHeight)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityHint(
                            l10n.format(
                                .settingsAboutOpenResourceHint,
                                presentation.name as NSString)
                        )
                        .accessibilityIdentifier(
                            "settings.about.resource.\(resource.kind.rawValue)")
                } else {
                    Label {
                        Text(
                            l10n.format(
                                .settingsAboutResourceMissing,
                                presentation.name as NSString)
                        )
                        .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(ClaudioTheme.error(colorScheme))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "settings.about.resource.\(resource.kind.rawValue).missing")
                }
            }
        }
    }

    private var diagnostics: some View {
        let preview = model.diagnosticSummary
        return VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {

            Text(preview)
                .font(SettingsAppearance.font(.technical))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: SettingsAppearance.groupRadius))
                .accessibilityLabel(l10n.text(.settingsAboutDiagnosticsTitle))
                .accessibilityValue(preview)
                .accessibilityIdentifier("settings.about.diagnostics.summary")
            SettingsFocusableButton(l10n.text(.settingsAboutCopyDiagnostics), requestsFocus: false)
            {
                model.copyPresentedDiagnostics(preview)
            }
            .accessibilityHint(l10n.text(.settingsAboutCopyDiagnosticsHint))
            .accessibilityIdentifier("settings.about.diagnostics.copy")
        }
    }

    private func factRow(_ labelKey: ClaudioL10nKey, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(l10n.text(labelKey))
                .foregroundColor(.secondary)
                .frame(width: 128, alignment: .leading)
            Spacer(minLength: 12)
            Text(value ?? unknown)
                .textSelection(.enabled)
        }
        .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
        .padding(.vertical, SettingsAppearance.controlRowVerticalPadding)
        .frame(minHeight: SettingsAppearance.controlRowHeight)
        .accessibilityElement(children: .combine)
    }

    private func resourcePresentation(
        _ kind: AboutBundledResourceKind
    ) -> (name: String, icon: String) {
        switch kind {
        case .openSourceLicense:
            (l10n.text(.settingsAboutResourceOpenSourceLicense), "doc.text")
        case .soundAttribution:
            (l10n.text(.settingsAboutResourceSoundAttribution), "music.note.list")
        case .privacyStatement:
            (l10n.text(.settingsAboutResourcePrivacy), "hand.raised")
        }
    }

    private func feedbackText(_ feedback: AboutSettingsFeedback) -> String {
        switch feedback {
        case .versionCopied:
            l10n.text(.settingsAboutVersionCopied)
        case .diagnosticsCopied:
            l10n.text(.settingsAboutDiagnosticsCopied)
        case .clipboardFailed:
            l10n.text(.settingsAboutClipboardFailed)
        case .resourceOpenFailed(let resource):
            l10n.format(
                .settingsAboutOpenFailed,
                resourcePresentation(resource).name as NSString)
        }
    }

    private func feedbackIcon(_ feedback: AboutSettingsFeedback) -> String {
        feedback.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
}
