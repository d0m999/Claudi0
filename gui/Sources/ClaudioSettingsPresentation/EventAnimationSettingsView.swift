import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
struct EventAnimationSettingsView: View {
    @ObservedObject private var preferences: ClaudioPreferences
    @ObservedObject private var preview: EventAnimationPreviewSession
    @ObservedObject private var resources: EventAnimationResources
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: SettingsPresentationSession) {
        _preferences = ObservedObject(wrappedValue: session.dependencies.preferences)
        _preview = ObservedObject(wrappedValue: session.animationPreview)
        _resources = ObservedObject(wrappedValue: session.dependencies.eventAnimations)
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: preferences.language) }
    private var dark: Bool { colorScheme == .dark }
    private var selected: EventAnimationPreferences { preferences.eventAnimation }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.sectionGap) {
            Text(l10n.text(.eventAnimationDescription)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            styleSection
            previewSection
            if selected.style != .original {
                VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {
                    Text(l10n.text(.eventAnimationCharacterOptions))
                        .font(SettingsAppearance.font(.sectionTitle))
                        .accessibilityAddTraits(.isHeader)
                    SettingsSectionCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsControlRow(title: l10n.text(.eventAnimationShowCharacter)) {
                                SettingsNativeSwitch(
                                    l10n.text(.eventAnimationShowCharacter), isOn: characterBinding,
                                    identifier: "settings.animation.show-character"
                                )
                                .accessibilityIdentifier("settings.animation.show-character")
                            }
                            .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                            Divider()
                            SettingsControlRow(title: l10n.text(.eventAnimationStaticExpression)) {
                                SettingsNativeSwitch(
                                    l10n.text(.eventAnimationStaticExpression), isOn: staticBinding,
                                    identifier: "settings.animation.static-expression"
                                )
                                .accessibilityIdentifier("settings.animation.static-expression")
                            }
                            .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                            if reduceMotion {
                                Text(l10n.text(.eventAnimationSystemReducedMotion)).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if preferences.recoveryIssues.contains(.invalidEventAnimation) {
                Text(l10n.text(.eventAnimationPreferenceRecovery)).font(.caption)
                    .accessibilityIdentifier("settings.animation.preference-recovery")
            }
            if let failure = resources.failure(selected.style, dark: dark),
                selected.style != .original
            {
                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.text(.eventAnimationResourceFallback))
                        Text(l10n.text(failure.localizationKey)).font(.caption).foregroundStyle(
                            .secondary)
                        SettingsFocusableButton(l10n.text(.commonRetry), requestsFocus: false) {
                            Task { await resources.load(selected.style, dark: dark, retry: true) }
                        }.accessibilityIdentifier("settings.animation.retry")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.animation.resource-failure")
            }
        }
        .accessibilityElement(children: .contain)
        .settingsMountIdentity("settings.notifications.event-animation-detail")
        .onAppear { preview.activate() }
        .onDisappear { preview.deactivate() }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {
            Text(l10n.text(.eventAnimationStyleSection))
                .font(SettingsAppearance.font(.sectionTitle))
                .accessibilityAddTraits(.isHeader)
            EventAnimationGallery(
                title: l10n.text(.eventAnimationTitle), selected: selected.style,
                label: { AnyView(styleLabel($0)) }, name: { l10n.text($0.localizationKey) },
                select: { preferences.selectEventAnimationStyle($0) }
            )
            .frame(height: 126)
            .soundPacksLayoutProbe("settings.animation.choices")
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .accessibilityIdentifier("settings.animation.status")
                    .soundPacksLayoutProbe("settings.animation.status")
            }
        }
    }

    private func styleLabel(_ style: EventAnimationStyle) -> some View {
        VStack(spacing: 12) {
            EventAnimationView(
                resources: resources,
                preferences: EventAnimationPreferences(style: style),
                event: .notification, action: "idle", reading: preview.reading,
                isVisible: false, size: 64)
            Text(l10n.text(style.localizationKey))
                .font(
                    .system(
                        size: 12, weight: selected.style == style ? .semibold : .regular)
                )
                .multilineTextAlignment(.center).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 15)
        .frame(maxWidth: .infinity)
        .background(SettingsNativeSurface(.group))
        .overlay {
            if selected.style == style {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                selected.style == style
                    ? Color.accentColor : SettingsAppearance.hairline(colorScheme),
                lineWidth: selected.style == style ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected.style == style {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.accentColor))
                    .padding(7)
                    .accessibilityHidden(true)
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: SettingsAppearance.informationGap) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n.text(.eventAnimationPreview)).font(SettingsAppearance.font(.sectionTitle))
                    .accessibilityAddTraits(
                    .isHeader)
                Spacer()
                SettingsFocusableButton(l10n.text(.eventAnimationReplay), requestsFocus: false) {
                    preview.replay()
                }
                .accessibilityIdentifier("settings.animation.replay")
                .soundPacksLayoutProbe("settings.animation.replay")
            }
            SettingsSectionCard(padding: 0) {
                VStack(spacing: 0) {
                    EventNoticeBannerContent(
                        event: preview.event,
                        title: localizedEventName(preview.event, language: preferences.language),
                        subtitle: l10n.text(.eventAnimationPreviewSubtitle),
                        action: preview.event.manifestKey,
                        preferences: selected, resources: resources, reading: preview.reading,
                        isVisible: preview.isActive, uptime: { preview.presentationUptime }
                    ) {
                        if preview.event == .notification || preview.event == .stopFailure {
                            Text(l10n.text(.eventNoticeOpenSource)).font(.caption).foregroundStyle(
                                .secondary
                            )
                            .accessibilityHidden(true)
                        }
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                    }
                    .padding(14).frame(width: 440, height: 75)
                    .background(ClaudioTheme.panelGradient(colorScheme))
                    .overlay(alignment: .bottom) {
                        EventNoticeReadingTrack(
                            reading: preview.reading, event: preview.event,
                            reduceMotion: reduceMotion,
                            uptime: { preview.presentationUptime })
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("settings.animation.banner-preview")
                    .soundPacksLayoutProbe("settings.animation.banner-preview")
                    Divider()
                    SettingsControlRow(title: l10n.text(.eventAnimationPreviewEvent)) {
                        SettingsNativeSelectionControl(
                            title: l10n.text(.eventAnimationPreview),
                            selection: Binding(get: { preview.event }, set: { preview.select($0) }),
                            options: Event.allCases.map {
                                SettingsMenuOption(
                                    $0,
                                    localizedEventName($0, language: preferences.language))
                            }, identifier: "settings.animation.event-selection"
                        )
                    }
                    .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
                    .soundPacksLayoutProbe("settings.animation.event-row")
                }
            }
            Text(l10n.text(.eventAnimationPreviewIsolation)).font(.caption).foregroundStyle(
                .secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsAppearance.controlRowHorizontalPadding)
        }
    }

    /// `nil` when the gallery selection already tells the whole story; the caption only
    /// reports states the tiles cannot show (character hidden, still expressions).
    private var status: String? {
        let effective = resources.effectiveStyle(for: selected, dark: dark)
        let base = l10n.format(.eventAnimationCurrentStyle, l10n.text(effective.localizationKey))
        if !selected.showsCharacter {
            return base + " · " + l10n.text(.eventAnimationSelectionKept)
        }
        if effective != .original, reduceMotion || selected.usesStaticExpression {
            return base + " · " + l10n.text(.eventAnimationStaticExpression)
        }
        return nil
    }

    private var characterBinding: Binding<Bool> {
        Binding(
            get: { selected.showsCharacter },
            set: {
                var next = selected; next.showsCharacter = $0; preferences.setEventAnimation(next)
            })
    }

    private var staticBinding: Binding<Bool> {
        Binding(
            get: { selected.usesStaticExpression },
            set: {
                var next = selected; next.usesStaticExpression = $0;
                preferences.setEventAnimation(next)
            })
    }
}

extension EventAnimationResourceFailure {
    fileprivate var localizationKey: ClaudioL10nKey {
        switch self {
        case .unavailable: .eventAnimationResourceUnavailable
        case .invalidManifest: .eventAnimationResourceInvalidManifest
        case .checksumMismatch: .eventAnimationResourceChecksum
        case .invalidAtlas: .eventAnimationResourceInvalidAtlas
        }
    }
}
