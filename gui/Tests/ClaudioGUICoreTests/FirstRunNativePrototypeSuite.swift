import AppKit
import ClaudioCore
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import ClaudioPanelPresentation
import Foundation
import SwiftUI

enum FirstRunPrototypePhase: String, CaseIterable, Sendable {
    case detecting
    case fresh
    case choosing
    case waiting
    case completed
    case dismissed

    var label: String { rawValue }
}

struct FirstRunPrototypeHost: Identifiable, Equatable, Sendable {
    let host: HostID
    let supported: Int
    let total: Int

    var id: HostID { host }
    var coverageText: String { "\(supported)/\(total)" }
    var badge: String {
        switch host {
        case .claudeCode: "CC"
        case .codex: "CX"
        case .workBuddy: "WB"
        case .opencode: "OC"
        case .kimiCode: "KC"
        case .grokBuild: "GB"
        case .chatGPTDesktopAX, .claudeDesktopAX: "AX"
        }
    }

    // Fixture counts are not production coverage.
    static let fixtures: [Self] = [
        Self(host: .claudeCode, supported: 5, total: 5),
        Self(host: .codex, supported: 4, total: 5),
        Self(host: .workBuddy, supported: 4, total: 5),
        Self(host: .opencode, supported: 2, total: 5),
        Self(host: .kimiCode, supported: 1, total: 5),
    ]
}

struct FirstRunPrototypeInteraction: Equatable, Sendable {
    var phase: FirstRunPrototypePhase
    private(set) var suspendedPhase: FirstRunPrototypePhase?
    private(set) var heardEvents: Set<Event>

    init(phase: FirstRunPrototypePhase, heard: Bool? = nil) {
        self.phase = phase
        let defaultHeard = phase != .fresh && phase != .choosing && phase != .detecting
        heardEvents = (heard ?? defaultHeard) ? [.taskStart] : []
    }

    var hasHeardSample: Bool { !heardEvents.isEmpty }

    var statusPhase: FirstRunPrototypePhase {
        if phase == .dismissed, let suspendedPhase {
            return suspendedPhase
        }
        return phase
    }

    mutating func markHeard(_ event: Event) {
        heardEvents.insert(event)
    }

    mutating func dismissChecklist() {
        guard phase != .dismissed else { return }
        suspendedPhase = phase
        phase = .dismissed
    }

    mutating func resumeChecklist() {
        phase = suspendedPhase ?? .fresh
        suspendedPhase = nil
    }
}

@MainActor
struct FirstRunPrototypePanel: View {
    let language: ClaudioAppLanguage
    let hosts: [FirstRunPrototypeHost]

    @State private var interaction: FirstRunPrototypeInteraction
    @State private var selectedHostID: HostID?
    @State private var completedCardAcknowledged = false
    @StateObject private var focusCoordinator = PanelFocusCoordinator()
    @FocusState private var focusedTarget: PanelFocusTarget?
    @Environment(\.colorScheme) private var colorScheme

    init(
        language: ClaudioAppLanguage = .zhHans,
        phase: FirstRunPrototypePhase = .fresh,
        heard: Bool? = nil,
        hosts: [FirstRunPrototypeHost]? = nil,
        selectedHost: HostID? = nil
    ) {
        let resolvedHosts = hosts ?? FirstRunPrototypeHost.fixtures
        self.language = language
        self.hosts = resolvedHosts
        _interaction = State(
            initialValue: FirstRunPrototypeInteraction(phase: phase, heard: heard))
        _selectedHostID = State(initialValue: selectedHost ?? resolvedHosts.first?.host)
    }

    private var phase: FirstRunPrototypePhase { interaction.phase }
    private var heard: Bool { interaction.hasHeardSample }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(13)
            Rectangle()
                .fill(ClaudioTheme.hairline(colorScheme))
                .frame(height: ClaudioTheme.Metrics.hairline)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if phase == .fresh {
                        intro
                    }
                    eventList
                    volumeRow
                    switch phase {
                    case .detecting:
                        detectingCard
                    case .fresh, .choosing:
                        if hosts.isEmpty {
                            noHostCard
                        } else {
                            onboardingCard
                        }
                    case .waiting:
                        waitingCard
                    case .completed:
                        if completedCardAcknowledged {
                            activityPlaceholder(
                                copy(
                                    "最近一次事件会出现在这里",
                                    "Your latest event will appear here"))
                        } else {
                            completedCard
                            activityPlaceholder(
                                copy(
                                    "最近一次事件会出现在这里",
                                    "Your latest event will appear here"))
                        }
                    case .dismissed:
                        resumeStrip
                        activityPlaceholder(
                            copy(
                                "接上宿主后，最近事件会出现在这里",
                                "Recent events will appear here once a host is connected"))
                    }
                }
                .padding(13)
            }
            footer
        }
        .frame(width: 312, height: 560)
        .background(ClaudioTheme.panelGradient(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.panel")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            ClaudioT2Badge(size: 22, cornerRadius: 5, glyphSize: 14)
            Text("claudi0")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .kerning(-0.13)
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Spacer(minLength: 8)
            Button {
            } label: {
                Label(l10n.text(.panelOpenSettings), systemImage: "gearshape")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minHeight: ClaudioTheme.Metrics.compactControlHeight)
                    .contentShape(
                        RoundedRectangle(cornerRadius: ClaudioTheme.Radius.control))
            }
            .buttonStyle(ClaudioIconButtonStyle())
            .accessibilityLabel(l10n.text(.panelOpenSettings))
            .accessibilityIdentifier("first-run.prototype.settings")
        }
        .accessibilityElement(children: .contain)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(copy("先听听它什么时候响", "Hear when it speaks"))
                .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
            Text(
                copy(
                    "点任意一行试听。示例只读本地声音，不写入配置，也不算接入。",
                    "Play any row. Samples are read-only: no config writes, no connection.")
            )
            .font(.system(size: 10.5, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            ForEach(Array(Event.allCases.enumerated()), id: \.element) { index, event in
                eventRow(event)
                if index < Event.allCases.count - 1 {
                    Rectangle()
                        .fill(ClaudioTheme.hairline(colorScheme))
                        .frame(height: ClaudioTheme.Metrics.hairline)
                }
            }
        }
        .padding(.horizontal, 8)
        .background(ClaudioTheme.surface(colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.events")
    }

    private func eventRow(_ event: Event) -> some View {
        HStack(spacing: 7) {
            Button {
                interaction.markHeard(event)
            } label: {
                HStack(spacing: 7) {
                    ClaudioEventGlyph(event: event, size: 23)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(eventTitle(event))
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundColor(ClaudioTheme.text(colorScheme))
                        Text(eventDetail(event))
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if interaction.heardEvents.contains(event) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(ClaudioTheme.success(colorScheme))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            MotionPreviewButton(
                isPlaying: false,
                playLabel: copy("试听\(eventTitle(event))", "Preview \(eventTitle(event))"),
                stopLabel: l10n.text(.soundsStop),
                reservesSpace: false
            ) {
                interaction.markHeard(event)
            }
            .help(
                copy(
                    "原型只改变已听状态，不播放音频",
                    "Prototype only marks the row as heard; no audio plays")
            )
            .accessibilityIdentifier("first-run.prototype.preview.\(event.rawValue)")
        }
        .padding(.vertical, 5.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.event.\(event.rawValue)")
    }

    private var volumeRow: some View {
        MasterVolumeRow(
            diskVolume: 0.72,
            onCommit: { $0 },
            focusCoordinator: focusCoordinator,
            focusedTarget: $focusedTarget,
            language: language
        )
    }

    private var selectedHost: FirstRunPrototypeHost? {
        hosts.first { $0.host == selectedHostID } ?? hosts.first
    }

    private var currentHostName: String {
        selectedHost?.host.displayName ?? copy("宿主", "Host")
    }

    private var currentCoverage: String {
        selectedHost?.coverageText ?? "—"
    }

    private var hostSummary: String {
        let names = hosts.map(\.host.displayName)
        switch names.count {
        case 0:
            return copy("未检测到已安装的宿主", "No installed hosts detected")
        case 1:
            return copy("检测到 \(names[0])", "Detected \(names[0])")
        case 2:
            return copy(
                "检测到 \(names[0]) 与 \(names[1])",
                "Detected \(names[0]) and \(names[1])")
        default:
            return copy(
                "检测到 \(names[0])、\(names[1]) 等 \(names.count) 个",
                "Detected \(names[0]), \(names[1]) and \(names.count - 2) more")
        }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(copy("开始使用", "GET STARTED"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                Spacer(minLength: 4)
                Button {
                    interaction.dismissChecklist()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(ClaudioIconButtonStyle())
                .accessibilityLabel(
                    copy("暂时收起上手清单", "Dismiss the getting-started checklist")
                )
                .accessibilityIdentifier("first-run.prototype.dismiss")
            }
            onboardingRow(
                mark: heard ? "checkmark.circle.fill" : "circle",
                markColor:
                    heard
                    ? ClaudioTheme.success(colorScheme)
                    : ClaudioTheme.textMuted(colorScheme),
                title: copy("听听它", "Hear a sample"),
                detail:
                    heard
                    ? copy("已听过示例 · 可以再听一次", "Sample heard · play it again anytime")
                    : copy("10 秒就能听到第一个提示音", "The first cue takes about 10 seconds"),
                actionTitle: heard ? copy("再听", "Again") : copy("播放", "Play"),
                action: { interaction.markHeard(.taskStart) },
                identifier: "first-run.prototype.sample")
            if phase == .choosing {
                Text(copy("选择一个宿主", "Choose a host"))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .padding(.top, 7)
                hostGrid
                    .padding(.top, 5)
                if hosts.count > 4 {
                    Button(
                        copy(
                            "查看全部 \(hosts.count) 个宿主",
                            "View all \(hosts.count) hosts")
                    ) {}
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("first-run.prototype.all-hosts")
                }
                Text(
                    copy(
                        "配置写入不等于已接入。宿主发来一次真实事件后，状态才会变化。",
                        "Configured is not connected. State changes after the host sends one real event."
                    )
                )
                .font(.system(size: 8, design: .rounded))
                .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            } else {
                onboardingRow(
                    mark: "circle",
                    markColor: ClaudioTheme.textMuted(colorScheme),
                    title: copy("接上一个宿主", "Connect a host"),
                    detail: hostSummary,
                    actionTitle: copy("选择", "Choose"),
                    action: { interaction.phase = .choosing },
                    identifier: "first-run.prototype.connect")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 7)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(ClaudioTheme.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.onboarding")
    }

    private func onboardingRow(
        mark: String,
        markColor: Color,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mark)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(markColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                Text(detail)
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.clay(colorScheme))
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ClaudioTheme.hairline(colorScheme))
                .frame(height: ClaudioTheme.Metrics.hairline)
        }
    }

    private var hostGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
            ],
            spacing: 6
        ) {
            ForEach(Array(hosts.prefix(4))) { host in
                hostChip(host)
            }
        }
    }

    private func hostChip(_ host: FirstRunPrototypeHost) -> some View {
        Button {
            selectedHostID = host.host
            interaction.phase = .waiting
        } label: {
            HStack(spacing: 5) {
                Text(host.badge)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
                    .frame(width: 18, height: 18)
                    .background(ClaudioTheme.elevated(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(host.host.displayName)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                        .lineLimit(1)
                    Text(
                        copy(
                            "\(host.coverageText) 声音可用",
                            "\(host.coverageText) sounds")
                    )
                    .font(.system(size: 7.5, design: .rounded))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                    .lineLimit(1)
                }
                Spacer(minLength: 1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(ClaudioTheme.elevated(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        ClaudioTheme.hairline(colorScheme),
                        lineWidth: ClaudioTheme.Metrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            copy(
                "连接 \(host.host.displayName)，\(host.coverageText) 声音可用",
                "Connect \(host.host.displayName), \(host.coverageText) sounds")
        )
        .accessibilityIdentifier("first-run.prototype.host.\(host.host.rawValue)")
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(copy("开始使用", "GET STARTED"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                Spacer(minLength: 4)
                Button {
                    interaction.dismissChecklist()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(ClaudioIconButtonStyle())
                .accessibilityLabel(
                    copy("暂时收起上手清单", "Dismiss the getting-started checklist"))
            }
            onboardingRow(
                mark: "clock.fill",
                markColor: ClaudioTheme.warning(colorScheme),
                title: copy(
                    "\(currentHostName) 配置已写入",
                    "\(currentHostName) configured"),
                detail: copy(
                    "等待宿主发来一次真实事件。配置写入不等于已接入。",
                    "Waiting for one real host event. Configured is not connected."),
                actionTitle: copy("设置", "Settings"),
                action: {},
                identifier: "first-run.prototype.waiting")
            HStack(spacing: 6) {
                Circle()
                    .fill(ClaudioTheme.warning(colorScheme))
                    .frame(width: 5, height: 5)
                Text(copy("原型：模拟一次真实事件", "Prototype: simulate a real event"))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                Spacer(minLength: 4)
                Button(copy("模拟", "Simulate")) {
                    interaction.phase = .completed
                }
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.clay(colorScheme))
                .buttonStyle(.plain)
                .accessibilityIdentifier("first-run.prototype.simulate-receipt")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(ClaudioTheme.warning(colorScheme).opacity(0.08))
            )
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(ClaudioTheme.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.waiting-card")
    }

    private var detectingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy("正在检查已安装的宿主…", "Checking installed hosts…"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(ClaudioTheme.text(colorScheme))
                    Text(
                        copy(
                            "只读取本机安装状态，不会自动连接。",
                            "Reads local install state only; nothing connects automatically.")
                    )
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(copy("打开连接设置", "Open connection settings")) {}
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .buttonStyle(.plain)
                Button(copy("稍后再说", "Not now")) { interaction.dismissChecklist() }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(ClaudioTheme.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.detecting-card")
    }

    private var noHostCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                    .accessibilityHidden(true)
                Text(copy("还没检测到可连接的宿主", "No connectable host detected"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.text(colorScheme))
            }
            Text(
                copy(
                    "示例试听仍然可用；事件声音要等接上宿主后才会响。",
                    "Samples still work. Event sounds start after you connect a host.")
            )
            .font(.system(size: 9, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(copy("打开连接设置", "Open connection settings")) {}
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ClaudioTheme.clay(colorScheme))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("first-run.prototype.open-settings")
                Button(copy("稍后再说", "Not now")) { interaction.dismissChecklist() }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("first-run.prototype.no-host-dismiss")
            }
            Text(
                copy(
                    "也可以在设置 → 连接中重新检测。",
                    "You can also redetect in Settings → Connections.")
            )
            .font(.system(size: 8, design: .rounded))
            .foregroundColor(ClaudioTheme.textMuted(colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(ClaudioTheme.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.hairline(colorScheme),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.no-host-card")
    }

    private var completedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ClaudioTheme.success(colorScheme))
                    .frame(width: 7, height: 7)
                Text(
                    copy(
                        "\(currentHostName) 已接上",
                        "\(currentHostName) connected")
                )
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(ClaudioTheme.text(colorScheme))
                Spacer(minLength: 4)
                Text(
                    copy(
                        "\(currentCoverage) 声音可用",
                        "\(currentCoverage) sounds")
                )
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.success(colorScheme))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ClaudioTheme.success(colorScheme).opacity(0.10))
                )
            }
            Text(
                copy(
                    "这条状态来自宿主发来的一次真实事件，不是示例试听。",
                    "This state comes from a real host event, not a sample.")
            )
            .font(.system(size: 8.5, design: .rounded))
            .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            .padding(.top, 3)
            if let host = selectedHost, host.supported < host.total {
                Text(
                    copy(
                        "该宿主支持 \(host.supported) 个事件；其余事件见设置。",
                        "This host supports \(host.supported) events; see Settings for the rest.")
                )
                .font(.system(size: 8, design: .rounded))
                .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
            HStack {
                Button(copy("收走", "Done")) {
                    completedCardAcknowledged = true
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(ClaudioTheme.clay(colorScheme))
                .buttonStyle(.plain)
                .accessibilityIdentifier("first-run.prototype.accept")
                Spacer()
            }
            .padding(.top, 5)
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .fill(ClaudioTheme.success(colorScheme).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudioTheme.Radius.row)
                .strokeBorder(
                    ClaudioTheme.success(colorScheme).opacity(0.25),
                    lineWidth: ClaudioTheme.Metrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-run.prototype.completed-card")
    }

    private var resumeStrip: some View {
        HStack(spacing: 8) {
            Text(copy("上手清单已收起", "Getting-started checklist hidden"))
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            Spacer(minLength: 4)
            Button(copy("继续", "Resume")) {
                interaction.resumeChecklist()
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundColor(ClaudioTheme.clay(colorScheme))
            .buttonStyle(.plain)
            .accessibilityIdentifier("first-run.prototype.resume")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    ClaudioTheme.hairline(colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }

    private func activityPlaceholder(_ text: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ClaudioTheme.textMuted(colorScheme))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(ClaudioTheme.textMuted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    ClaudioTheme.hairline(colorScheme),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-run.prototype.activity-placeholder")
    }

    private var footer: some View {
        ZStack(alignment: .leading) {
            PanelQuitFooter(
                language: language,
                focusedTarget: $focusedTarget,
                onQuit: {})
            footerHint
                .padding(.leading, 13)
                .allowsHitTesting(false)
        }
    }

    private var footerHint: some View {
        let status = interaction.statusPhase
        return HStack(spacing: 5) {
            if status == .completed {
                Circle()
                    .fill(ClaudioTheme.success(colorScheme))
                    .frame(width: 5, height: 5)
                Text(
                    copy(
                        "\(currentHostName) 已接上 · \(currentCoverage)",
                        "\(currentHostName) connected · \(currentCoverage)")
                )
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            } else if status == .waiting {
                Circle()
                    .fill(ClaudioTheme.warning(colorScheme))
                    .frame(width: 5, height: 5)
                Text(
                    copy(
                        "配置已写入 · 等待第一次真实事件",
                        "Configured · awaiting first event")
                )
                .foregroundColor(ClaudioTheme.secondaryText(colorScheme))
            } else if status == .detecting {
                Circle()
                    .fill(ClaudioTheme.textMuted(colorScheme))
                    .frame(width: 5, height: 5)
                Text(copy("正在检查已安装的宿主", "Checking installed hosts"))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
            } else if hosts.isEmpty {
                Circle()
                    .fill(ClaudioTheme.textMuted(colorScheme))
                    .frame(width: 5, height: 5)
                Text(copy("未连接宿主", "No host connected"))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
            } else {
                Text(copy("示例试听不写入配置", "Samples don't change your config"))
                    .foregroundColor(ClaudioTheme.textMuted(colorScheme))
            }
        }
        .font(.system(size: 9, design: .rounded))
        .lineLimit(1)
    }

    private func eventTitle(_ event: Event) -> String {
        l10n.text(event.localizationKey)
    }

    private func eventDetail(_ event: Event) -> String {
        switch event {
        case .taskStart:
            copy("提示已提交", "Prompt submitted")
        case .stop:
            copy("这一轮停止", "This response finished")
        case .stopFailure:
            copy("限流、欠费或认证", "Rate limit, billing or auth")
        case .notification:
            copy("需要你操作", "Needs your action")
        case .subagentStop:
            copy("从属任务停止", "A subtask finished")
        }
    }

    private func copy(_ zh: String, _ english: String) -> String {
        language == .english ? english : zh
    }

    private var l10n: ClaudioL10n { ClaudioL10n(language: language) }
}

extension Event {
    fileprivate var localizationKey: ClaudioL10nKey {
        switch self {
        case .taskStart: .eventTaskStart
        case .stop: .eventStop
        case .stopFailure: .eventStopFailure
        case .notification: .eventNotification
        case .subagentStop: .eventSubagentStop
        }
    }
}

@MainActor
struct FirstRunPrototypeShowcase: View {
    @State private var phase: FirstRunPrototypePhase = .fresh
    @State private var language: ClaudioAppLanguage = .zhHans
    @State private var dark = false
    @State private var noHosts = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Picker("State", selection: $phase) {
                    ForEach(FirstRunPrototypePhase.allCases, id: \.self) { phase in
                        Text(phase.label).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Language", selection: $language) {
                    Text("中文").tag(ClaudioAppLanguage.zhHans)
                    Text("EN").tag(ClaudioAppLanguage.english)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Dark", isOn: $dark)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("No hosts", isOn: $noHosts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            FirstRunPrototypePanel(
                language: language,
                phase: phase,
                hosts: noHosts ? [] : nil
            )
            .id("\(phase.rawValue)-\(language.rawValue)-\(dark)-\(noHosts)")
            .preferredColorScheme(dark ? .dark : .light)
            Text(
                "SwiftUI · production tokens/components · samples and receipts are prototype-only"
            )
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(24)
    }
}

@MainActor
func runFirstRunNativePrototypeRenderSuites() {
    suite("first-run native prototype renders production-token panel states") {
        let output = firstRunPrototypeOutputDirectory(
            environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory)
        try? FileManager.default.createDirectory(
            at: output, withIntermediateDirectories: true)
        let cases:
            [(
                name: String, language: ClaudioAppLanguage, phase: FirstRunPrototypePhase,
                scheme: ColorScheme, hosts: [FirstRunPrototypeHost]?, selectedHost: HostID?
            )] = [
                ("01-fresh-light-zh", .zhHans, .fresh, .light, nil, nil),
                ("02-choosing-light-zh", .zhHans, .choosing, .light, nil, nil),
                ("03-waiting-light-zh", .zhHans, .waiting, .light, nil, nil),
                ("04-completed-light-zh", .zhHans, .completed, .light, nil, nil),
                ("05-dismissed-light-zh", .zhHans, .dismissed, .light, nil, nil),
                ("06-fresh-dark-zh", .zhHans, .fresh, .dark, nil, nil),
                ("07-completed-dark-zh", .zhHans, .completed, .dark, nil, nil),
                ("08-fresh-light-en", .english, .fresh, .light, nil, nil),
                ("09-detecting-light-zh", .zhHans, .detecting, .light, [], nil),
                ("10-no-hosts-light-zh", .zhHans, .fresh, .light, [], nil),
                ("11-completed-codex-light-zh", .zhHans, .completed, .light, nil, .codex),
                ("12-choosing-many-light-en", .english, .choosing, .light, nil, nil),
                ("13-no-hosts-dark-zh", .zhHans, .fresh, .dark, [], nil),
            ]
        for item in cases {
            let url = output.appendingPathComponent("\(item.name).png")
            let result = renderFirstRunPrototypePanel(
                language: item.language, phase: item.phase, scheme: item.scheme,
                hosts: item.hosts, selectedHost: item.selectedHost, to: url)
            expect(result, "native first-run prototype render failed: \(item.name)")
        }
        print("  first-run prototype renders: \(output.path)")
    }
}

@MainActor
private func renderFirstRunPrototypePanel(
    language: ClaudioAppLanguage,
    phase: FirstRunPrototypePhase,
    scheme: ColorScheme,
    hosts: [FirstRunPrototypeHost]?,
    selectedHost: HostID?,
    to url: URL
) -> Bool {
    let root = FirstRunPrototypePanel(
        language: language, phase: phase, hosts: hosts, selectedHost: selectedHost
    )
    .environment(\.colorScheme, scheme)
    let hosting = NSHostingView(rootView: root)
    if #available(macOS 13, *) { hosting.sizingOptions = [] }
    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    hosting.frame = NSRect(x: 0, y: 0, width: 312, height: 560)
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 312, height: 560),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = hosting
    window.setFrame(NSRect(x: 80, y: 80, width: 312, height: 560), display: true)
    window.orderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    hosting.layoutSubtreeIfNeeded()
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 624,
            pixelsHigh: 1120,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
    else {
        window.orderOut(nil)
        window.close()
        return false
    }
    bitmap.size = NSSize(width: 312, height: 560)
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]),
        firstRunPrototypePNGIsAcceptable(data)
    else {
        window.orderOut(nil)
        window.close()
        return false
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        window.orderOut(nil)
        window.close()
        return false
    }
    let written = (try? Data(contentsOf: url)) ?? Data()
    window.orderOut(nil)
    window.close()
    return written == data && firstRunPrototypePNGIsAcceptable(written)
}

@MainActor
func presentFirstRunNativePrototypeWindow() {
    let hosting = NSHostingView(rootView: FirstRunPrototypeShowcase())
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.title = "claudio · first-run native prototype"
    window.contentView = hosting
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    firstRunPrototypeWindow = window
}

@MainActor
private var firstRunPrototypeWindow: NSWindow?

func firstRunPrototypeOutputDirectory(
    environment: [String: String],
    temporaryDirectory: URL
) -> URL {
    let override = environment["CLAUDIO_FIRST_RUN_PROTOTYPE_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return temporaryDirectory.appendingPathComponent(
        "claudio-first-run-prototype", isDirectory: true)
}

func firstRunPrototypePNGIsAcceptable(_ data: Data) -> Bool {
    guard !data.isEmpty, let rep = NSBitmapImageRep(data: data) else { return false }
    return rep.pixelsWide == 624 && rep.pixelsHigh == 1120
}

@MainActor
func runFirstRunNativePrototypeSuites() {
    suite("first-run prototype keeps the receipt across dismiss") {
        var waiting = FirstRunPrototypeInteraction(phase: .waiting)
        expect(
            waiting.heardEvents == [.taskStart], "waiting starts with the task-start sample marked")
        waiting.dismissChecklist()
        expect(waiting.phase == .dismissed, "dismiss hides the waiting checklist")
        expect(
            waiting.statusPhase == .waiting, "a hidden waiting checklist still reports the receipt")
        waiting.dismissChecklist()
        waiting.resumeChecklist()
        expect(waiting.phase == .waiting, "resume restores waiting instead of a fresh list")
        expect(waiting.statusPhase == .waiting, "the restored waiting checklist keeps the receipt")

        var completed = FirstRunPrototypeInteraction(phase: .completed)
        completed.dismissChecklist()
        expect(completed.statusPhase == .completed, "a hidden completion stays distinct from fresh")
        completed.resumeChecklist()
        expect(completed.phase == .completed, "resume restores completion")

        var fresh = FirstRunPrototypeInteraction(phase: .fresh)
        fresh.dismissChecklist()
        fresh.resumeChecklist()
        expect(fresh.phase == .fresh, "resume from a fresh dismiss returns to the fresh list")

        var cold = FirstRunPrototypeInteraction(phase: .dismissed)
        expect(cold.statusPhase == .dismissed, "a cold dismissed panel has no stored receipt")
        cold.resumeChecklist()
        expect(cold.phase == .fresh, "resume without a stored phase opens the fresh list")
    }

    suite("first-run prototype marks the row that was heard") {
        var session = FirstRunPrototypeInteraction(phase: .fresh)
        expect(session.heardEvents.isEmpty, "a fresh list has not been heard")
        expect(!session.hasHeardSample, "the sample step starts incomplete")
        session.markHeard(.stop)
        expect(session.heardEvents == [.stop], "hearing stop does not mark task start")
        expect(session.hasHeardSample, "any heard row completes the sample step")
        session.markHeard(.notification)
        expect(
            session.heardEvents == [.stop, .notification],
            "each row keeps its own heard mark")
        let explicit = FirstRunPrototypeInteraction(phase: .waiting, heard: false)
        expect(explicit.heardEvents.isEmpty, "an explicit unheard waiting state stays unmarked")
    }

    suite("first-run prototype render output stays out of the evidence folder") {
        let temporary = URL(
            fileURLWithPath: "/tmp/claudio-first-run-prototype-temp", isDirectory: true)
        let fallback = firstRunPrototypeOutputDirectory(
            environment: [:], temporaryDirectory: temporary)
        let expected = temporary.appendingPathComponent(
            "claudio-first-run-prototype", isDirectory: true)
        expect(
            fallback.standardizedFileURL.path == expected.standardizedFileURL.path,
            "the default render directory is a temporary folder")
        expect(
            !fallback.path.contains("designs/ux-optimization/renders"),
            "the default render directory is not the evidence renders folder")
        let blank = firstRunPrototypeOutputDirectory(
            environment: ["CLAUDIO_FIRST_RUN_PROTOTYPE_DIR": "   "],
            temporaryDirectory: temporary)
        expect(
            blank.standardizedFileURL.path == fallback.standardizedFileURL.path,
            "a blank override does not select a directory")
        let explicit = firstRunPrototypeOutputDirectory(
            environment: ["CLAUDIO_FIRST_RUN_PROTOTYPE_DIR": "/tmp/claudio-evidence"],
            temporaryDirectory: temporary)
        expect(
            explicit.standardizedFileURL.path
                == URL(fileURLWithPath: "/tmp/claudio-evidence", isDirectory: true)
                .standardizedFileURL.path,
            "an explicit directory is used only when it is set")
    }

    suite("first-run prototype accepts only a full-size panel bitmap") {
        expect(!firstRunPrototypePNGIsAcceptable(Data()), "empty bytes are not a panel render")
        let tiny = bitmapPNG(pixelsWide: 1, pixelsHigh: 1)
        expect(!firstRunPrototypePNGIsAcceptable(tiny), "a 1×1 PNG is not a panel render")
        let panel = bitmapPNG(pixelsWide: 624, pixelsHigh: 1120)
        expect(
            firstRunPrototypePNGIsAcceptable(panel),
            "a 624×1120 PNG is an acceptable panel render")
    }
}

private func bitmapPNG(pixelsWide: Int, pixelsHigh: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    return rep?.representation(using: .png, properties: [:]) ?? Data()
}
