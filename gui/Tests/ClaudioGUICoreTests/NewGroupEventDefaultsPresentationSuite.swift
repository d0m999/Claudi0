import ClaudioCore
import ClaudioGUICore
import Foundation

// MARK: - 新建组默认开关在界面投影里必须是三个（2026-11-15）
//
// helper 侧的 `NewGroupEventDefaultsSuite` 已经钉住落盘形状与切包不重置。这里只补用户**看得见**的
// 那一层：设置页「默认组／工作区」摘要显示的开启数，以及用户能把默认关闭的事件重新打开。
// `WorkspaceSettingsSummary.enabledEventCount` 是这条投影的唯一出口，别在视图里另算一份。

@MainActor
private func makeDefaultSwitchPack(at url: URL, id: String) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    writeFixture(
        #"{"id":"\#(id)","name":"\#(id)","events":{}}"#,
        to: url.appendingPathComponent("manifest.json"))
}

/// 从 `source` 里抽出以 `declaration` 整行开头的那个顶层声明（到其后第一行**行首 `}`** 为止）。
///
/// 只读创建表单这一段，不读整份 1300+ 行的 `EventSettingsWindowView.swift`：整份文件里只要出现
/// 一个扫描器不建模的构造（raw string、未建模插值），`unmodeledConstructs` 就非空，这条断言会
/// 永久假红。`SourceScannerSuite` 为同一个坑已经抽过段（见那里 `fenceCallSiteBegin` 的说明）。
/// 抽段还有第二个好处：下面的否定断言只作用于创建表单，不误伤同文件的其他视图。
private func declarationBody(startingWith declaration: String, in source: String) -> String? {
    let lines = source.components(separatedBy: "\n")
    guard
        let start = lines.firstIndex(where: { $0 == declaration }),
        let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" })
    else { return nil }
    return lines[start...end].joined(separator: "\n")
}

@MainActor
func runNewGroupEventDefaultsPresentationSuites() {
    suite(
        "new group defaults: the settings summary projects three enabled events for a fresh group"
    ) {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            makeDefaultSwitchPack(
                at: packs.appendingPathComponent("pika", isDirectory: true), id: "pika")
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs,
                    lockFile: root.appendingPathComponent("config.lock"))
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            let summary = WorkspaceSettingsSummary(
                scope: .global, config: loadPanelConfig(from: configFile).resolvedConfig)
            expect(
                summary?.enabledEventCount == 3,
                "新建组在界面上必须只显示三个开启事件，got"
                    + " \(String(describing: summary?.enabledEventCount))")
        }
    }

    suite("new group defaults: the workspace create form calls the explicit creation seam") {
        // `AddWorkspaceSoundRuleView` 是 private SwiftUI 视图，harness 无法 import 它来断言接线；
        // 这条跨文件契约只能用剥注释后的源码文本钉住。
        let url = guiTestRepositoryRoot().appendingPathComponent(
            "gui/Sources/ClaudioSettingsPresentation/EventSettingsWindowView.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            expect(false, "读不到 EventSettingsWindowView.swift")
            return
        }
        guard
            let body = declarationBody(
                startingWith: "private struct AddWorkspaceSoundRuleView: View {", in: source)
        else {
            expect(
                false,
                "抽不出创建表单那一段——声明被改名或删除，下面每条断言都会在空串上恒真")
            return
        }
        let scanned = strippingComments(body)
        // 抹掉空白再比对：`swift-format` 会把长实参表折行，带空格的整串匹配会因此假红。
        let squashed = scanned.codeWithoutStringLiterals.filter { !$0.isWhitespace }
        expect(
            scanned.unmodeledConstructs.isEmpty,
            "源码扫描器必须能完整建模创建表单这一段，got \(scanned.unmodeledConstructs)")
        expect(
            squashed.contains(".newGroup(selectedPack:selectedPack,volume:volume)"),
            "新建工作区表单必须走 WorkspaceSoundProfile.newGroup 创建 seam，"
                + "不得依赖通用构造器的默认参数")
        // 上面那条只证明「有一处」。创建表单里**不许再出现**第二条 profile 构造：写全
        // `WorkspaceSoundProfile(...)`、`.init(...)` 或补一个 `events:` 实参都会绕开工厂、
        // 拿回通用构造器的全开表，而正向包含断言看不见它们。
        // 允许 `WorkspaceSoundProfile.newGroup(...)` 这种显式限定写法，所以先摘掉工厂调用。
        let withoutFactory = squashed.replacingOccurrences(
            of: "WorkspaceSoundProfile.newGroup(", with: "")
        for forbidden in ["WorkspaceSoundProfile(", ".init(", "events:"] {
            expect(
                !withoutFactory.contains(forbidden),
                "创建表单里不得出现 \(forbidden)——那会绕开 newGroup 工厂")
        }
    }

    suite("new group defaults: the panel can still turn the two muted events back on") {
        withTempDirectory { root in
            let configFile = root.appendingPathComponent("config.json")
            let packs = root.appendingPathComponent("packs", isDirectory: true)
            makeDefaultSwitchPack(
                at: packs.appendingPathComponent("pika", isDirectory: true), id: "pika")
            expect(
                selectPack(
                    "pika", configFile: configFile, userPacksDirectory: packs,
                    lockFile: root.appendingPathComponent("config.lock"))
                    == .success(.selected(packID: "pika")),
                "fixture: fresh config")

            let controller = PanelConfigController(
                configFile: configFile,
                lockFile: root.appendingPathComponent("config.lock"),
                environment: AudioImportEnvironment(
                    userPacksDirectory: packs,
                    bundledPacksDirectory: nil,
                    durationProbe: StubDurationProbe(fixedDuration: 1.0),
                    packsLockFile: injectedPacksLock(besideUserPacks: packs)))
            expect(
                controller.eventRows.first(where: { $0.event == .taskStart })?.enabled == false,
                "前提：task_start 那行初始必须是关的")

            controller.toggleMute(.taskStart)

            let onDisk = loadPanelConfig(from: configFile).resolvedConfig
            expect(
                onDisk.eventsEnabled == [
                    "task_start": true, "stop": true, "stop_failure": true,
                    "notification": true, "subagent_stop": false,
                ],
                "用户打开 task_start 后必须只翻这一位、其余四键原样，got"
                    + " \(onDisk.eventsEnabled)")
            expect(
                WorkspaceSettingsSummary(scope: .global, config: onDisk)?.enabledEventCount == 4,
                "摘要必须跟着变成四个开启事件")
        }
    }
}
