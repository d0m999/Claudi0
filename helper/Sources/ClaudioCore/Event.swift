import Foundation

/// The five stable semantic sound events.
///
/// This enum is the **single source of truth** for the event-name mapping shared by
/// `install` / `play` / `uninstall` (ENGINEERING.md 决议 · 指令) and for the switches a
/// newly created group starts with (``isOnInNewGroupByDefault``). Claude Code's
/// `settings.json` uses camelCase (`Stop`, `SubagentStop`), while the CLI `<event>`
/// token and the `manifest.json` event key use snake_case (`stop`, `subagent_stop`).
///
/// The mapping MUST go through this table — never `lowercased()`, which would turn
/// `SubagentStop` into `subagentstop` and fail to match the manifest key
/// `subagent_stop`. 宿主原生事件名由 ``HostCapabilityCatalog`` 持有。
public enum Event: String, CaseIterable, Codable, Sendable, Hashable {
    // Raw values are pinned to `cliName` explicitly (rather than left to Swift's default
    // camelCase-derived rawValue, which would give `stopFailure`/`subagentStop`) — anyone
    // who later reaches for `Event(rawValue:)` or `.rawValue` (e.g. in a config/log/test
    // fixture) must not get a third, undocumented spelling alongside `cliName`/`manifestKey`
    // (`/codex review` 2026-07-08).
    case taskStart = "task_start"
    case stop = "stop"
    case stopFailure = "stop_failure"
    case notification = "notification"
    case subagentStop = "subagent_stop"

    /// CLI `<event>` token — identical to the `manifest.json` event key (snake_case).
    public var cliName: String {
        switch self {
        case .taskStart: "task_start"
        case .stop: "stop"
        case .stopFailure: "stop_failure"
        case .notification: "notification"
        case .subagentStop: "subagent_stop"
        }
    }

    /// `manifest.json` event key — identical to ``cliName`` per the mapping table.
    public var manifestKey: String { cliName }

    /// 用户界面的稳定声音语义；宿主原生事件名由各 adapter 提供。
    public var displayName: String {
        switch self {
        case .taskStart: "用户发起"
        case .stop: "响应结束"
        case .stopFailure: "执行中断"
        case .notification: "等待介入"
        case .subagentStop: "子任务结束"
        }
    }

    /// Resolve from a CLI `<event>` token / `manifest.json` key (snake_case).
    public init?(cliName: String) {
        guard let match = Event.allCases.first(where: { $0.cliName == cliName })
        else { return nil }
        self = match
    }

    /// 通用（非新建组）默认：完整五键全开。
    ///
    /// 服务 ``WorkspaceSoundProfile/init(selectedPack:volume:events:systemSounds:)`` 的 `events: nil`、
    /// GUI 预览夹具与测试夹具。**不是**新建组默认——新建组只认 ``newGroupDefaultSwitches``。
    /// 两张表并存是刻意的：通用构造器被既有规则与大量 fixture 复用。
    public static var allEnabledSwitches: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.cliName, true) })
    }

    /// 新建组（首次装机写出的 `config.json`；新建工作区规则）的默认开关。
    ///
    /// 唯一事实源：默认组的新鲜创建分支（`updateConfigJSON` 的 `.createFresh`）与
    /// ``WorkspaceSoundProfile/newGroup(selectedPack:volume:)`` 两个**创建 seam** 都从这里取值，
    /// 别处不得再写第二份字面量。通用构造器 ``WorkspaceSoundProfile/init(selectedPack:volume:events:systemSounds:)``
    /// 不参与新建组默认，它只保证一份完整有效的五键表。
    ///
    /// 用穷尽 `switch` 而不是 `Set<Event>` 成员判定：将来新增第六个事件时这里必须编译失败，
    /// 迫使默认值被显式决定，而不是被「不在集合里即 false」悄悄吞掉。
    public var isOnInNewGroupByDefault: Bool {
        switch self {
        case .stop, .stopFailure, .notification: true
        case .taskStart, .subagentStop: false
        }
    }

    /// 新建组落盘时的完整五键开关表。
    ///
    /// 必须是**完整五键**：``WorkspaceSoundProfile/isValid`` 要求五键齐全，稀疏表会让每条
    /// 新建工作区当场失效并停播。读侧「缺键 = 开」只服务存量文件，不参与新建。
    public static var newGroupDefaultSwitches: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.cliName, $0.isOnInNewGroupByDefault) })
    }

    /// Claude Code legacy `claudi0 play` 安装器继续只管理原有四个 lifecycle 事件。
    /// `UserPromptSubmit` 必须由现代宿主 adapter 在用户显式 connect / repair / upgrade
    /// 时写入，启动 bootstrap 不得借由 `Event.allCases` 静默修改宿主配置。
    public static let legacyLifecycleCases: [Event] = [
        .stop, .stopFailure, .notification, .subagentStop,
    ]
}
