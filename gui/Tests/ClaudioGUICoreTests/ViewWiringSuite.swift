import AppKit
import ClaudioGUICore
import Foundation

// MARK: - `ClaudioGUI` 这个 executable target 需要源码接线护栏
//
// `claudio-gui-tests` 只依赖 `ClaudioGUICore` + `ClaudioCore`。`ClaudioGUI` 是一个带 `@main` 的
// **executableTarget**，Swift 里没法 `import` 它。所以整棵 SwiftUI 视图树上的每一行接线，对这套
// 测试都是**不可见的**。因此「Panel 不再探测 Claude-only onboarding」、
// 「两条声音来源与运行控件恒显」、「每次打开请求共享 manager 刷新」和
// 「连接/修复/断开只存在于统一 Settings 集成 destination」必须由本 suite 读生产源来守。
//
// 真正的结构修法是把视图层拆成一个可被 import 的 library target（或引入 ViewInspector）—— 那是一次
// 独立的重构，不该跟一次 bugfix 混在一起（已记入 TODOS）。在那之前，这个 suite 是**唯一存在的护栏**：
// 它读源码文本。
//
// ⚠️ **诚实标注：这是文本绊线，不是行为测试。** 它证明不了那行代码**做对了**，只能证明它**还在**。
// 一个把 `.onChange` 改成 `.onChange(of: config)` 的改动照样能骗过它。它挡的是「顺手删掉 / 重构时
// 漏掉」这一类，而那恰恰是上述双宿主接线变异的形状。`ReleaseLayoutSuite` 已经为 release.yml 立下了同样的
// 先例：一个可执行的 harness 读得了文件，那就用它读。

/// 仓库根 —— 从 `#filePath` 推（编译期常量，不依赖 cwd）。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor
private func source(_ relativePath: String) -> String? {
    guard let data = try? Data(contentsOf: repoRoot().appendingPathComponent(relativePath)) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

/// 同一个文件，被 ``strippingComments(_:)`` 扫过之后的样子（代码 + 「扫描器不认识的构造」清单）。
@MainActor
private func scan(_ relativePath: String) -> StrippedSwiftSource? {
    guard let text = source(relativePath) else { return nil }
    return strippingComments(text)
}

/// 同一个文件，**剥掉注释**之后的样子。
///
/// 这不是洁癖：本 suite 的第一版直接对整份源码做 `contains("Bundle.main")`，然后**被
/// `MenuBarController` 自己那段解释「为什么这里不该有 Bundle.main」的注释**判红了。
/// 这与它上游的 `ReleaseLayoutSuite` 第一版翻的是**同一次车**（release.yml 的散文让 grep 命中，
/// 于是那条断言永远不会红）。一次文本断言若不区分「代码」与「谈论代码的文字」，它断的就不是代码。
/// T17c：也剥**行尾**注释，不只是整行注释。上一版只判断 `hasPrefix("//")`，于是一行
/// `foo()  // 见 hostSourcesSection` 能同时活过过滤器**又**让 `contains()`
/// 命中 —— 真代码被删掉了，绊线照样绿。这正是本 suite 头部说明的文本护栏局限：
/// 它修好了整行注释，没修行尾注释。（反向断言 `!contains("Bundle.main")` 则会被行尾注释假红。）
///
/// **同一个病的第三半**（`/codex review be332ff` 的 P3）：它此前在**每行第一个 `//`** 处无条件截断，
/// 而它不认识字符串字面量。于是一行 `let url = "https://…"; …("play.lock")` 会被剪掉后半截，
/// `play.lock` 对下面那条 `ClaudioGUICore` 普查**隐身**。helper 那边给自己配了一条守卫（还是恒真的），
/// GUI 这半边**连那条都没有**。现在剥注释的活儿交给 `TestSupport.strippingComments` —— 一个位置感知的
/// 状态机，两个包共用，字符串字面量里的 `//` 不再是注释起点；它自己的行为由 `SourceScannerSuite`
/// 喂合成输入钉死。剩下那点它不认识的（raw string），由本文件第一条 suite 盯着。
@MainActor
private func codeOnly(_ relativePath: String) -> String? {
    scan(relativePath)?.code
}

/// 同一个文件，剥掉注释**且清空字符串内容**之后的样子（界定符与插值里的代码保留）。
///
/// 需要看**代码结构**（数括号、切函数体）而不是「字符串里写了什么」的断言，必须读这一路 ——
/// `code` 里一句写着 `refresh()` 的错误消息，在 `contains("refresh()")` 眼里与一次真的调用完全同形。
/// 见 ``StrippedSwiftSource/codeWithoutStringLiterals``。
@MainActor
private func codeWithoutStrings(_ relativePath: String) -> String? {
    scan(relativePath)?.codeWithoutStringLiterals
}

/// 把连续空白（含换行、缩进）压成单个空格 —— 让文本断言对**排版**免疫。
///
/// `.swift-format` 的 `respectsExistingLineBreaks: true` 意味着 `case .full: refresh()` 既可能写成一行、
/// 也可能被人拆成两行。一条断言若要求其中一种，它守的就是排版而不是接线：下一个人换了行，它假红，
/// 然后被删掉。
///
/// ⚠️ **不是 `private`**：`SourceScannerSuite` 的锁转发腿（T3 内容围栏第四条腿）要拿同一份实现去
/// 归一化 `lockFile:` 实参。两份拷贝会漂移（一份收窄、另一份没有 ⇒ 同一段源码在两处得出不同结论），
/// 而这两个文件在同一个 target 里，去掉 `private` 就够了 —— 别为了「每个文件自带一份」再抄一遍。
func collapsingWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `marker` 在 `source` 里出现几次，对空白排版（任意长度的空格、换行、块注释被剥完后补的那个
/// 空格）免疫 —— 先 ``collapsingWhitespace(_:)`` 再数子串。
///
/// ⚠️ 生产扫描与它的合成正/负控**必须**共用这一个函数，不能各自重新拼一遍「collapse 再数」——
/// 两处各写一份看起来一样的表达式，正/负控测的就只是「这个表达式抽象上对不对」，测不出「生产那
/// 一行有没有真的在调它」：把生产那行悄悄改回不 collapse 的旧版，两份各自独立的表达式各判各的，
/// 正/负控一个字都不会变，围栏本体的回归却没有任何东西喊。（`gui/Tests/ClaudioGUICoreTests`
/// `extension` 普查那一刀第一版就是这么栽的：实测把生产那行改回
/// `source.code.components(separatedBy: marker)`，2472 条检查照样全绿。）
func whitespaceTolerantHitCount(of marker: String, in source: String) -> Int {
    collapsingWhitespace(source).components(separatedBy: marker).count - 1
}

/// `marker` 之后紧跟的那个 `{ … }` 的**闭包体**（按花括号配对切出来），`nil` = 找不到 marker 或它后面
/// 没有配平的闭包。
///
/// ## 它修的那个洞（`/codex review 8771946` P1 + 变异实测）
///
/// 本 suite 的绊线全是 `contains(修饰符字面量)`。那种断言能证明**修饰符在**，证明不了**闭包体做了
/// 什么** —— 而「做了什么」恰恰是这些修饰符存在的全部理由。实测变异体：
///
/// ```swift
/// .onChange(of: focusCoordinator.hideCount) { _ in
///     // flush() 被删掉，闭包留空
/// }
/// ```
///
/// 用户拖完滑块点面板外面关掉 popover，音量**静默丢失** —— 正是守着这一行的那条断言在失败消息里
/// 亲口写下的那个 bug —— 而 1973 checks **全绿**。绊线的措辞（「必须观察 hideCount 的变化**并冲刷
/// pending 的拖动**」）比它的覆盖范围（「`.onChange(of:` 这串字符在文件里」）大了一整个闭包体。
///
/// 这是本仓库反复复发的同一种病，已有两处判例记在案：`PanelRefreshRoute.swift:17`（把「静音失败必须
/// 全量 refresh」钉成 `contains("refresh()")`，而 `refresh()` 在那个文件里出现 37 次，那个合取子恒真）
/// 与本文件 ``sourcesUnder(_:)`` 的 T17h（措辞说「全 GUI」，范围只有一个文件）。所以这个 helper 是
/// **围栏**不是探针：切不出闭包体就返回 `nil`，调用方一律判红 —— 「我看不懂这段代码」绝不等于「这段
/// 代码是对的」。
///
/// 必须喂 ``codeWithoutStrings(_:)`` 的输出，不能喂 ``codeOnly(_:)``：后者保留字符串**内容**，一句写着
/// `flush()` 的错误消息在 `contains("flush()")` 眼里与一次真的调用完全同形。
private func closureBody(after marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker) else { return nil }
    var depth = 0
    var body = ""
    for ch in source[markerRange.upperBound...] {
        if ch == "{" {
            depth += 1
            if depth == 1 { continue }  // 最外层的开括号本身不算体
        }
        if ch == "}" {
            depth -= 1
            if depth == 0 { return body }  // 配平：闭包体到此为止
        }
        if depth >= 1 { body.append(ch) }
    }
    return nil  // 没配平（marker 后面根本没有闭包，或文件被截断）—— 围栏判红，不判绿
}

/// `marker` 所在位置的花括号嵌套深度。输入必须是 ``codeWithoutStrings(_:)`` 的结果。
///
/// T7 的 `.manageSounds` 双向诚实性不能只靠「出现一次 + 相对顺序」：把
/// `manageSoundsRow` 包进 `if !packCards.isEmpty { … }`，或把 `order.append(.manageSounds)`
/// 包进同型条件，字面量与先后顺序一个都没变，却会让零行面板再次出现幽灵焦点。层级与所在
/// `switch`/`case` 相同，才证明它没有被一个额外的 `if`/`switch`/`ForEach` 花括号条件化。
private func braceDepth(of marker: String, in source: String) -> Int? {
    guard let markerRange = source.range(of: marker) else { return nil }
    var depth = 0
    for ch in source[..<markerRange.lowerBound] {
        switch ch {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth < 0 { return nil }
        default:
            break
        }
    }
    return depth
}

/// `ClaudioGUI` target 下**每一个** Swift 源文件，剥掉注释之后的样子 —— `(文件名, 代码)`。
///
/// ## 它修的那个洞（T17h —— `/codex review a3c2d08` 独立评审逮到）
///
/// 上一版那条断言的**措辞**是「全 GUI 只许有一处 `NSAccessibility.post`」，它守的**范围**却是
/// `PanelView.swift` **一个文件**：
///
/// ```swift
/// expect(panel.components(separatedBy: "NSAccessibility.post").count - 1 == 1, "全 GUI 只许有一处…")
/// //     ^^^^^ 只有 PanelView.swift
/// ```
///
/// 于是在 `MenuBarController.swift` / `PackGalleryView.swift` / `OnboardingView.swift` 里加第二处
/// post —— 换完包顺手补一句「已切换到 X」，正是 ``PanelView/say(_:)`` 的文档亲口点名**最诱人**的那条路
/// —— 测试全绿，而那条 post 会截断用户还没听完的那句「你的包被换掉了」。T17g 的提交信息把这条断言
/// 写成「全 GUI 只剩一处 NSAccessibility.post，**由 ViewWiringSuite 数着**」：后半句当时是虚的。
///
/// 目录读不到 / 一个文件都数不到，必须**变红**，而不是安静地数出 0 —— 一个数不到任何文件的计数器
/// 永远等不到 1，它会一直绿下去。这与本文件头部那条「一次文本断言若不区分代码与谈论代码的文字，
/// 它断的就不是代码」是同一种病：一条永远不会红的断言，不是护栏。
/// 一个被扫过的源文件：路径、剥掉注释的代码、以及扫描器**自己不认识**的那些构造。
///
/// `unmodeled` 不是装饰：它非空 = `code` 不可信，而本文件的兜底全是负向断言（不可信的文本只会
/// 让它们更绿）。第一条 suite 就盯着它。
private typealias ScannedSource = (path: String, code: String, unmodeled: [String])

@MainActor
private func sourcesUnder(_ relativeRoot: String) -> [ScannedSource] {
    let root = repoRoot().appendingPathComponent(relativeRoot)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var found: [ScannedSource] = []
    for case let name as String in walker where name.hasSuffix(".swift") {
        guard let scanned = scan("\(relativeRoot)/\(name)") else { continue }
        found.append((path: name, code: scanned.code, unmodeled: scanned.unmodeledConstructs))
    }
    return found.sorted { $0.path < $1.path }
}

/// 生产普查与合成正/负控共用的唯一入口：逐文件扫描、空白归一后按 marker 计数。
/// 调用方不得绕过它另写一次 `collapsingWhitespace + components`，否则合成控制无法证明生产接线。
private func whitespaceTolerantMarkerCensus(
    _ marker: String,
    in sources: [ScannedSource],
    pathPrefix: String = ""
) -> [String: Int] {
    var census: [String: Int] = [:]
    for source in sources {
        let hits = whitespaceTolerantHitCount(of: marker, in: source.code)
        if hits > 0 { census["\(pathPrefix)\(source.path)"] = hits }
    }
    return census
}

/// 合成输入也先走与磁盘生产文件相同的 `strippingComments`，再交给同一个 census 入口。
private func scannedFixture(path: String, text: String) -> ScannedSource {
    let scanned = strippingComments(text)
    return (path: path, code: scanned.code, unmodeled: scanned.unmodeledConstructs)
}

private func repositoryRelativeSources(
    _ groups: [(root: String, sources: [ScannedSource])]
) -> [ScannedSource] {
    groups.flatMap { group in
        group.sources.map { source in
            (
                path: "\(group.root)/\(source.path)",
                code: source.code,
                unmodeled: source.unmodeled
            )
        }
    }
}

private func unmodeledConstructCensus(in sources: [ScannedSource]) -> [String: [String]] {
    var census: [String: [String]] = [:]
    for source in sources where !source.unmodeled.isEmpty {
        census[source.path] = source.unmodeled
    }
    return census
}

private func settingsAnnouncementSurfaceSources(
    executable: [ScannedSource],
    presentation: [ScannedSource],
    panelPresentation: [ScannedSource] = []
) -> [ScannedSource] {
    repositoryRelativeSources([
        (root: "gui/Sources/ClaudioGUI", sources: executable),
        (root: "gui/Sources/ClaudioPanelPresentation", sources: panelPresentation),
        (root: "gui/Sources/ClaudioSettingsPresentation", sources: presentation),
    ])
}

private func settingsAnnouncementSurfaceCensus(
    in sources: [ScannedSource]
) -> (posts: [String: Int], consumes: [String: Int]) {
    var posts: [String: Int] = [:]
    var consumes: [String: Int] = [:]
    for file in sources {
        let postCount = file.code.components(separatedBy: "NSAccessibility.post").count - 1
        let consumeCount =
            file.code.components(separatedBy: "announcer.consume(").count - 1
            + file.code.components(separatedBy: "announcer.scheduleLibraryUpdate(").count - 1
        if postCount > 0 { posts[file.path] = postCount }
        if consumeCount > 0 { consumes[file.path] = consumeCount }
    }
    return (posts: posts, consumes: consumes)
}

@MainActor
private func guiSources() -> [ScannedSource] {
    sourcesUnder("gui/Sources/ClaudioGUI")
}

/// 从 `lockLeaks` 普查里豁免的文件（**文件级单源**）。
///
/// ⚠️ 提到文件级不是为了复用，是为了让「每个豁免项都换来一条更严的锚定绊线」这句散文有一条
/// **可执行**版本：下面那条 suite 会断言这张表减去 `lockCensusSelfGuardedFiles` 之后，**逐项等于**
/// `expectedProductionLocks` 的文件集。上一版两张清单各自硬编码、互不绑定 —— 往这里加第四项
/// 而对价一条不写，普查静默少查一个文件、全绿、没有人会喊（`/review d7084be` 红队 P2 坐实）。
///
/// C1 之前 `PanelView.swift` 也在这张表里（它是面板 config.lock 的唯一注入点，由 config.lock
/// suite 守着）；C1 之后 PanelView 不再持有任何锁代码、也不住在被普查的 target 里，
/// 它的豁免与自我守卫项一并删除。
private let lockCensusExemptedFiles = [
    "MenuBarController.swift", "ClaudioGUIApp.swift", "StateGalleryView.swift",
    "NativeUIRegressionController.swift",
]

/// GUI composition 有一条专属接线断言，不能混进包锁的 environment 普查。
private let lockCensusSelfGuardedFiles: Set<String> = [
    "MenuBarController.swift"
]

/// 生产侧**每一处** `AudioImportEnvironment(…)` 构造点，连同它那把包锁应有的实参（**文件级单源**）。
///
/// ⚠️ 提到文件级的理由与 ``lockCensusExemptedFiles`` 逐字相同，只是又晚了一轮：这张表现在同时喂
/// **三**条断言 —— 豁免绑定（集合相等）、逐调用点的实参锚定、以及下面那条**构造点普查**。
/// `/codex review 51aebae,7caf6dc,e278736` 的 P1-B 坐实：它上一版是 suite 内部的局部 `let`，
/// 于是「生产侧两个构造点」这句话在整个仓库里**没有任何东西在数**——往 `ClaudioGUICore` 放一个
/// 就地算锁的第三个构造点（`packsLockFile: packDirectory.appendingPathComponent("packs.lock")`），
/// 编译通过、**2456 条检查全绿**、一条都不红（隔离 worktree 实测，不是推理）。
/// 再写第四张各自硬编码的清单就是同一个病第三次复发，所以从这里开始只有这一份。
///
/// `file` 是 **basename**；普查那条把它拼成 `ClaudioGUI/<file>` 去与实得的键比。那个前缀是硬编码的，
/// 而这正是要的极性：某天 `ClaudioGUICore` 里合法长出一个构造点，实得的键会是
/// `ClaudioGUICore/<file>`、与期望集合不等 ⇒ **红** ⇒ 有人必须来想清楚「lockLeaks 只扫
/// `ClaudioGUI`，那个新文件由谁守」。fail-closed，不是遗漏。
private let expectedProductionLocks:
    [(file: String, value: String, literal: String?, why: String)] = [
        (
            "ClaudioGUIApp.swift", "ClaudioPaths.packsLockFile", nil,
            "组装根是全 app 唯一该说出真实路径的地方。它若变成别的，两个 manifest.json 写者"
                + "（接管发布内置包走 helper 的 `performFirstRunSetup`、绑定/解绑走 "
                + "`mutateManifestJSON`）就不再是同一把 `flock`，跨进程互斥当场断开"
        ),
        (
            "NativeUIRegressionController.swift", "root.appendingPathComponent(\"\")", "packs.lock",
            "专用 DEBUG bundle 的所有声音写者使用同一隔离临时根的包锁；启动身份及无生产路径由 Native migration suite 另行检查"
        ),
        (
            "StateGalleryView.swift",
            "previewStateGalleryRoot.appendingPathComponent(\"\")", "packs.lock",
            "preview 必须从单一随机临时根派生包锁。它若变成 `ClaudioPaths.packsLockFile`，一个 "
                + "SwiftUI preview 就有了去碰用户 home 上那把锁的能力；若另算第二个根，gallery 的 "
                + "production owner 与 manifest writer 就不再共享同一把锁"
        ),
    ]

/// `ClaudioGUICore` target 下每一个源文件 —— 上面那个 `guiSources()` **看不见**的那一半 GUI。
///
/// 它存在的理由（`/review e7c38ea` 的 P1，变异实测）：接管路径的锁要过四手，而**中间那一手**
/// （`OnboardingActions.swift:589-596`，把 `OnboardingActionEnvironment` 的两把锁灌进
/// `SetupEnvironment`）住在 `ClaudioGUICore` 里 —— `guiSources()` 只扫 `gui/Sources/ClaudioGUI`，
/// `LockSeparationSuite` 只 `codeOnly("helper/…")`，于是这个 target **两套绊线都看不到**。
///
/// 把 `OnboardingActions.swift:595` 的 `configLockFile: environment.configLockFile` 改成
/// `configLockFile: ClaudioPaths.playLockFile` —— 用户点下「接管」之后那几秒，config.json 的写占住
/// `play` 的去抖锁，他的每一声提示音被静默吞掉 —— **1064 + 1607 全绿，零红**。
///
/// ⚠️ 这里只立**负向**兜底（不许出现 play 的去抖锁）。真正把「谁守谁」钉死的是
/// `OnboardingActionsSuite` 那四条**持锁行为断言** —— 它们绑的是真实锁文件路径，成对交换、
/// 值级假名、三元表达式、大小写差一个字母，在它们面前全部当场变红。这一条只是**便宜的第二道**：
/// 行为断言够不到的地方（比如将来 `ClaudioGUICore` 里长出第三个写者、而没人给它写行为测试），
/// 至少 play.lock 这条最要命的路是堵死的。
@MainActor
private func guiCoreSources() -> [ScannedSource] {
    sourcesUnder("gui/Sources/ClaudioGUICore")
}

@MainActor
func runViewWiringSuites() {
    suite("Event Notice：交互式面板失去 key window 时沿关闭路径收起") {
        guard
            let controller = codeWithoutStrings(
                "gui/Sources/ClaudioGUI/EventNoticeWindowController.swift"),
            let resignKey = closureBody(after: "func windowDidResignKey", in: controller)
        else {
            expect(false, "必须能解析 EventNoticeWindowController 的失焦接线")
            return
        }
        let normalized = collapsingWhitespace(resignKey)
        expect(
            normalized.contains("close()")
                && normalized.contains("isInteractive")
                && !normalized.contains("!isInteractive")
                && normalized.contains("model.setKeyboardFocused(false)"),
            "失焦闭包体必须引用 isInteractive 判别（不得取反极性）并含 close() 与键盘暂停解除"
                + "（存在性+极性断言，不证明分支内归属；等价 guard 改写不得假红；"
                + "De Morgan 等价改写（`if !isInteractive` 互换两分支体）会假红，属已知边界；"
                + "`isInteractive == false` 式取反不含 `!` 词元、不判红，同为已披露边界）")
        expect(
            controller.contains("NSWindowDelegate")
                && controller.contains("window.delegate = self"),
            "resignKey 路径必须真实接线：控制器声明 NSWindowDelegate 并被设为窗口 delegate")
        expect(
            controller.contains("window.hidesOnDeactivate = false"),
            "自动非交互横幅必须继续使用自身生命周期，不得随应用失活强制隐藏")
    }

    suite("Event Notice：根辅助功能标签按当前 snapshot 与语言分流") {
        guard
            let view = codeWithoutStrings(
                "gui/Sources/ClaudioGUIComponents/EventNoticeView.swift"),
            let body = closureBody(after: "public var body: some View", in: view)
        else {
            expect(false, "必须能解析 EventNoticeView 的根视图接线")
            return
        }
        let normalized = collapsingWhitespace(body)
        expect(
            normalized.replacingOccurrences(of: " ", with: "").contains(
                ".accessibilityLabel(EventNoticeProjection.accessibilityLabel(for:snapshot,language:languageStore.language,now:context.date))"
            ),
            "根 AX label 必须把当前 snapshot 与语言交给共享投影决策")
        expect(
            !normalized.contains(".accessibilityLabel(l10n.text(.eventNoticeRecent))"),
            "根 AX label 不得重新硬连到 Needs You/需要你常量")
    }

    suite("Event Notice：executable 跨窗口接线转交 Settings restoration，重复交互不重捕获") {
        guard
            let settings = codeWithoutStrings(
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift"),
            let router = codeWithoutStrings("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let notice = codeWithoutStrings(
                "gui/Sources/ClaudioGUI/EventNoticeWindowController.swift"),
            let transfer = closureBody(after: "func closeForMutualExclusion()", in: settings),
            let route = closureBody(
                after: "func dismissSettingsForEventNoticeInteraction()", in: router),
            let entry = closureBody(after: "private func becomeInteractive()", in: notice),
            let firstEntry = closureBody(after: "if !isInteractive", in: entry),
            let close = closureBody(after: "func close()", in: notice),
            let privacy = closureBody(after: "func clearForPrivacy()", in: notice),
            let takeRange = transfer.range(of: "takeFocusRestoration()"),
            let closeRange = transfer.range(of: "window.close()")
        else {
            expect(false, "必须能解析 Settings → router → Event Notice 的 executable 接线")
            return
        }
        expect(
            transfer.contains("let restoration = takeFocusRestoration()")
                && transfer.contains("return restoration")
                && takeRange.lowerBound < closeRange.lowerBound,
            "Settings 必须在 close 前取出完整 restoration 并返回给调用者")
        expect(
            route.contains(
                "if let restoration = settingsWindowController.closeForMutualExclusion()")
                && route.contains("return restoration"),
            "router 必须优先转交 Settings restoration，不得被 frontmost Claudio 覆盖")
        expect(
            firstEntry.contains("focusRestoration = onWillBecomeInteractive()"),
            "转交回调只能绑定首次进入 interactive 的分支")
        expect(
            close.contains("let restoration = focusRestoration")
                && close.contains("focusRestoration = nil")
                && close.contains("isInteractive && window.isKeyWindow && NSApp.isActive")
                && close.contains("if owesHandback { restoration?() }"),
            "notice close 必须消费一次转交动作，并由当前焦点所有权守卫")
        expect(privacy.contains("focusRestoration = nil"), "隐私清空必须释放延迟归还动作")
        expect(
            closureBody(after: "func openInteractive()", in: notice)?
                .contains("onViewInPanel(nil)") == true
                && closureBody(after: "onOpenSourceApplication:", in: notice)?
                    .contains("self?.openSourceApplication(action)") == true,
            "菜单栏保留列表入口，胶囊主动作接到版本化来源应用打开")
        let render = closureBody(after: "private func render(", in: notice) ?? ""
        expect(
            closureBody(
                after: "guard (snapshot.current != nil || snapshot.isExpanded)", in: render)?
                .contains("focusRestoration = nil") == true,
            "runtime 经共享模型清空隐私时，也必须丢弃旧的焦点归还动作")
    }

    suite("Orbit Zero 字标是所有 UI 品牌入口的单一实现") {
        guard
            let branding = codeOnly(
                "gui/Sources/ClaudioGUIComponents/ClaudioBranding.swift"),
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let menuBarIcon = codeOnly("gui/Sources/ClaudioGUI/MenuBarIcon.swift")
        else {
            expect(false, "读不到 Orbit Zero 共享组件、面板标题或菜单栏图标源码")
            return
        }

        expect(
            branding.contains("public struct ClaudioOrbitWordmark")
                && branding.contains("public struct ClaudioOrbitZeroMark")
                && branding.contains(".accessibilityElement(children: .ignore)")
                && branding.contains(".accessibilityLabel(\"claudi0\")")
                && branding.contains(".accessibilityHidden(true)"),
            "完整字标必须由共享组件绘制；轨道细节不拆成 VoiceOver 节点，字标本身仍有 claudi0 文本替代")

        let normalizedBranding = collapsingWhitespace(branding)
        expect(
            normalizedBranding.components(separatedBy: ".offset(x: -size * 0.22)").count - 1 == 1
                && normalizedBranding.contains(
                    "} .offset(x: -size * 0.22) .frame(width: size * 1.36, height: size)")
                && !normalizedBranding.contains(".offset(x: size * 0.10)"),
            "Orbit Zero 的光晕、0 与斜轨必须共享 ZStack 中心，再由整个图形组统一左移")
        expect(
            !branding.contains("Circle()") && !branding.contains("signal dot"),
            "应用内 Orbit Zero 字标不得绘制装饰点")

        expect(
            panel.components(separatedBy: "ClaudioOrbitWordmark(").count - 1 == 1
                && !panel.contains("Text(\"claudi0\")"),
            "运行面板必须调用同一份 Orbit Zero 字标，不能退回两份手写 Text logo")

        expect(
            menuBarIcon.contains("static func make() -> NSImage")
                && menuBarIcon.contains("drawOrbitZero()")
                && menuBarIcon.contains("rotation.rotate(byDegrees: 16)")
                && !menuBarIcon.contains("dot.fill()")
                && menuBarIcon.contains("image.isTemplate = true"),
            "菜单栏必须使用同源 Orbit Zero 减法几何，并保持 template image 自动适配亮暗菜单栏")
    }

    suite("Orbit Zero 品牌母版与打包位图不含旧装饰点") {
        guard
            let mark = source("assets/branding/claudi0-mark.svg"),
            let appIcon = source("assets/branding/claudi0-app-icon.svg"),
            let generator = codeOnly("scripts/generate-brand-assets.swift"),
            let pngData = try? Data(
                contentsOf: repoRoot().appendingPathComponent(
                    "assets/branding/claudi0-app-icon.png")),
            let png = NSBitmapImageRep(data: pngData),
            let icns = NSImage(
                contentsOf: repoRoot().appendingPathComponent(
                    "assets/branding/claudi0.icns")),
            let icns1024 = icns.representations.first(where: { $0.pixelsWide == 1024 })
                as? NSBitmapImageRep
        else {
            expect(false, "必须能读取 Orbit Zero 母版、生成脚本、PNG 与 .icns")
            return
        }
        expect(
            !mark.contains("<circle") && !appIcon.contains("<circle")
                && !generator.contains("dot.fill()"),
            "两个 SVG 和图标生成脚本不得绘制原偏心装饰点")
        for (name, bitmap) in [("PNG", png), (".icns", icns1024)] {
            let oldDot = bitmap.colorAt(x: 755, y: 303)
            let background = bitmap.colorAt(x: 755, y: 280)
            expect(
                oldDot != nil && oldDot?.isEqual(background) == true,
                "\(name) 的原状态点中心应与周围底色一致")
        }
    }

    suite("扫描器的前提：三个 GUI production targets 没有一处它自己不认识的构造") {
        // ## GUI 这一半此前**一条守卫都没有**（`/codex review be332ff` 的 P3）
        //
        // 本文件下面的兜底全是**负向**断言（除 PanelView 外不许出现锁、ClaudioGUICore 里不许出现
        // `play.lock`、全 target 只许一处 `NSAccessibility.post`）。它们共享同一个失效模式：
        // **分析文本里少一段代码，它们只会更绿。**
        //
        // 上一版 `codeOnly` 在每行第一个 `//` 处无条件截断，不认识字符串字面量。于是
        //
        // ```swift
        // let url = "https://claudio.dev/locks"; let lock = ClaudioPaths.root.appendingPathComponent("play.lock")
        // ```
        //
        // 会被剪掉后半截 —— `play.lock` 对新增的 `ClaudioGUICore` 普查**隐身**。helper 那边给自己配了
        // 一条守卫（`be332ff`），可惜那条守卫检查的是**截断之后**的文本，`://` 自带 `//`，它**恒真**；
        // 而 GUI 这半边连那条恒真的都没有。两半的洞现在一起堵：剥注释交给两个包共用的
        // `TestSupport.strippingComments`（位置感知，字符串里的 `//` 不再是注释起点，行为由
        // `SourceScannerSuite` 喂合成输入钉死），剩下它不建模的 raw string 由这条盯着。
        //
        // 位置感知是必须的：`ClaudioColorHex.swift:206` / `ContrastRatio.swift:27` 里的
        // `hasPrefix("#")` 逐字包含 `#"` —— 一条纯文本的 `#"` 守卫会在它们身上当场假红，然后被
        // 下一个人删掉，洞原样回来。
        let scanned = repositoryRelativeSources([
            (root: "gui/Sources/ClaudioGUI", sources: guiSources()),
            (root: "gui/Sources/ClaudioGUICore", sources: guiCoreSources()),
            (
                root: "gui/Sources/ClaudioPanelPresentation",
                sources: sourcesUnder("gui/Sources/ClaudioPanelPresentation")
            ),
            (
                root: "gui/Sources/ClaudioSettingsPresentation",
                sources: sourcesUnder("gui/Sources/ClaudioSettingsPresentation")
            ),
        ])
        expect(
            scanned.count >= 10,
            "三个 target 加起来一个 Swift 文件都没数到（实得 \(scanned.count)）—— 这条是**普查**，"
                + "普查不到任何文件就永远等不到红，只会安静地绿下去")
        let expectedTargetRoots = [
            "gui/Sources/ClaudioGUI/",
            "gui/Sources/ClaudioGUICore/",
            "gui/Sources/ClaudioPanelPresentation/",
            "gui/Sources/ClaudioSettingsPresentation/",
        ]
        expect(
            expectedTargetRoots.allSatisfy { root in
                scanned.contains { $0.path.hasPrefix(root) }
            },
            "fail-closed census 必须以 repository-relative path 覆盖三个 production target")
        let unmodeled = unmodeledConstructCensus(in: scanned)
        expect(
            unmodeled.isEmpty,
            "这些文件里出现了扫描器不建模的词法构造：\(unmodeled) —— 它剥出来的「代码」从此不可信，"
                + "而本文件的兜底全是负向断言：一段被误判成字符串 / 注释而消失的代码只会让它们**更绿**，"
                + "一句藏在里面的 `ClaudioPaths.playLockFile` 或 `\"play.lock\"` 会对整套锁普查"
                + "**永久隐身**。要么把这个构造挪走，要么先教 `strippingComments` 认识它")

        let duplicateBasenameFixtures = repositoryRelativeSources([
            (
                root: "gui/Sources/ClaudioGUI",
                sources: [
                    scannedFixture(
                        path: "Duplicate.swift", text: "let pattern = ##\"a//b\"##")
                ]
            ),
            (
                root: "gui/Sources/ClaudioSettingsPresentation",
                sources: [
                    scannedFixture(
                        path: "Duplicate.swift", text: "let pattern = ##\"c//d\"##")
                ]
            ),
        ])
        let mutationCensus = unmodeledConstructCensus(in: duplicateBasenameFixtures)
        expect(
            Set(mutationCensus.keys)
                == [
                    "gui/Sources/ClaudioGUI/Duplicate.swift",
                    "gui/Sources/ClaudioSettingsPresentation/Duplicate.swift",
                ]
                && mutationCensus.values.allSatisfy { !$0.isEmpty },
            "同 basename 的不建模 mutation 必须保留两个 relative-path findings，不能覆盖成一个")
    }

    suite("主动播报出口按 surface 唯一：Panel、Integrations 与统一 Settings 各一个") {
        let sources = settingsAnnouncementSurfaceSources(
            executable: guiSources(),
            presentation: sourcesUnder("gui/Sources/ClaudioSettingsPresentation"),
            panelPresentation: sourcesUnder("gui/Sources/ClaudioPanelPresentation"))
        expect(
            sources.count >= 5,
            "在 executable 与 Settings presentation targets 下一个 Swift 文件都没数到"
                + "（实得 \(sources.count)）。"
                + "这条断言存在的全部意义就是去数那些文件 —— 数不到，它就永远等不到 1，安静地绿下去")
        expect(
            sources.contains { $0.path.hasSuffix("PanelView.swift") }
                && sources.contains {
                    $0.path.hasSuffix("IntegrationsSettingsDestinationView.swift")
                },
            "Panel 与统一 Settings 集成 destination 两个独立 surface 都必须在普查名册里")

        let census = settingsAnnouncementSurfaceCensus(in: sources)

        expect(
            census.posts == [
                "gui/Sources/ClaudioGUI/MenuBarController.swift": 1,
                "gui/Sources/ClaudioGUI/SettingsWindowController.swift": 1,
            ],
            "原生 AppKit 播报只能由 GUI composition 的 MenuBarController 与 Settings window controller"
                + "发出；Panel 通过注入 callback，destination 不得新增 AppKit post。实得 \(census.posts)")
        expect(
            census.consumes == ["gui/Sources/ClaudioPanelPresentation/PanelView.swift": 1],
            "Panel 的播报必须仍经过唯一去重器；原生出口由 GUI composition 注入。实得 \(census.consumes)")
        let integrations =
            sources.first {
                $0.path.hasSuffix("IntegrationsSettingsDestinationView.swift")
            }?.code ?? ""
        expect(
            integrations.components(separatedBy: "feedbackAnnouncer.consume(").count - 1 == 1,
            "集成 destination 的出口必须只经过一处 feedback revision 去重器")

        let collisionMutation = settingsAnnouncementSurfaceSources(
            executable: [
                scannedFixture(
                    path: "PanelView.swift",
                    text: "NSAccessibility.post; announcer.consume("),
                scannedFixture(
                    path: "SettingsWindowController.swift", text: "NSAccessibility.post"),
            ],
            presentation: [
                scannedFixture(path: "PanelView.swift", text: "NSAccessibility.post")
            ],
            panelPresentation: [
                scannedFixture(path: "PanelView.swift", text: "NSAccessibility.post")
            ])
        let mutationCensus = settingsAnnouncementSurfaceCensus(in: collisionMutation)
        expect(
            mutationCensus.posts
                == [
                    "gui/Sources/ClaudioGUI/PanelView.swift": 1,
                    "gui/Sources/ClaudioGUI/SettingsWindowController.swift": 1,
                    "gui/Sources/ClaudioSettingsPresentation/PanelView.swift": 1,
                    "gui/Sources/ClaudioPanelPresentation/PanelView.swift": 1,
                ]
                && mutationCensus.consumes
                    == ["gui/Sources/ClaudioGUI/PanelView.swift": 1],
            "同 basename 的 executable、presentation 与 panel target mutation 必须成为独立 finding，不能覆盖彼此")
    }

    suite("PanelView 单作用域边界：无宿主探测，固定呈现 scope/报告/当前来源内容") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let scopePicker = codeOnly(
                "gui/Sources/ClaudioPanelPresentation/PanelSoundScopePicker.swift"),
            let menu = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let integrationsView = codeOnly(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"),
            let integrationsModel = codeOnly(
                "gui/Sources/ClaudioGUICore/IntegrationDestinationModel.swift")
        else {
            expect(false, "读不到 Panel/MenuBar/集成 destination 生产源")
            return
        }
        for forbidden in [
            "OnboardingViewModel", "DiskOnboardingActionRunner",
            "OnboardingActionEnvironment", "detectOnboardingState(",
            "OnboardingView(viewModel:", "settings.json", "hooks.json",
            "Data(contentsOf:", "JSONDecoder",
        ] {
            expect(
                !panel.contains(forbidden),
                "PanelView 不得自行探测 Claude 或读取宿主配置，命中：\(forbidden)")
        }

        guard
            let bodyStart = panel.range(of: "public var body: some View")?.lowerBound,
            let headerStart = panel.range(
                of: "private var headerAccessibilityLabel")?.lowerBound,
            bodyStart < headerStart
        else {
            expect(false, "无法定位 PanelView.body")
            return
        }
        let body = panel[bodyStart..<headerStart]
        guard
            let headerAt = body.range(of: "header")?.lowerBound,
            let noticeAt = body.range(of: "noticeSection")?.lowerBound,
            let scopeAt = body.range(of: "soundScopePicker")?.lowerBound,
            let activityAt = body.range(of: "activityOverview")?.lowerBound,
            let contentAt = body.range(of: "mainContent")?.lowerBound
        else {
            expect(
                false,
                "Panel body 必须同时含 header、soundScopePicker、activityOverview、mainContent")
            return
        }
        expect(
            headerAt < noticeAt && noticeAt < scopeAt && scopeAt < contentAt
                && contentAt < activityAt,
            "Panel 必须按 header → 需要你 → 作用域 → 内容 → 静态活动摘要渲染")
        expect(
            panel.contains("panelSoundScopePresentations(")
                && panel.contains("hostIntegrations.content.sourceRows")
                && panel.contains("PanelSoundScopePicker(")
                && panel.contains("scopes: soundScopePresentations")
                && panel.contains("isExpanded: $isSoundScopeMenuExpanded")
                && !panel.contains("onManageIntegrations(")
                && !panel.contains("diagnosticsHost"),
            "全宽作用域选择器必须来自共享来源 presentation；宿主诊断动作保留在 Integrations destination")
        expect(
            scopePicker.contains("ForEach(scopes)")
                && scopePicker.contains(".frame(maxWidth: .infinity")
                && scopePicker.contains(".frame(height: 0, alignment: .top)")
                && scopePicker.contains("PanelSoundScopeOutsideClickMonitor(")
                && scopePicker.contains(".onMoveCommand(perform: moveMenuFocus)")
                && scopePicker.contains(".onExitCommand")
                && scopePicker.contains("panel.sound-scope")
                && !scopePicker.contains("Menu {")
                && !panel.contains("HostSourceRowView(")
                && !panel.contains("PanelPackSectionView("),
            "生产面板必须挂载不推移布局、可退出的全宽自绘选择器，且不再挂载来源卡片或包画廊")
        expect(
            panel.contains("configWritesAllowed: panelModel.soundControlsEnabled")
                && panel.contains("libraryUnavailableSection")
                && panel.contains("configFailureNotice()"),
            "事件写入必须消费共享可用性判断；声音库与 config 失败必须在当前 Panel 显式呈现")

        guard
            let showStart = panel.range(
                of: ".onChange(of: focusCoordinator.showCount)")?.lowerBound
        else {
            expect(false, "无法定位面板打开 handler")
            return
        }
        let showHandler = panel[showStart...]
        expect(
            showHandler.contains("panelModel.reload()")
                && showHandler.contains("applyFirstFocus()")
                && showHandler.contains("announcePanelSummary()"),
            "每次真实打开必须重读声音控制、恢复首焦点并主动播报当前作用域摘要")
        expect(
            panel.contains("Self.headerAccessibilityLabel(language: languageStore.language)")
                && panel.contains("from: panelModel.$libraryPresentationState")
                && panel.contains("announcer.scheduleLibraryUpdate(")
                && panel.contains("Self.libraryAnnouncementFacts(")
                && panel.contains("panelIsVisible: coordinator.isPanelVisible")
                && panel.contains("onAnnounce: onAnnounce"),
            "面板播报必须消费当前摘要、合并调度器，并在异步 post 前复核面板可见性")

        guard
            let didShowStart = menu.range(of: "func panelDidShow")?.lowerBound,
            let didCloseStart = menu.range(of: "func panelDidClose")?.lowerBound,
            didShowStart < didCloseStart
        else {
            expect(false, "无法定位 MenuBarController popover show/close 生命周期")
            return
        }
        let didShow = menu[didShowStart..<didCloseStart]
        expect(
            didShow.contains("requestHostIntegrationRefresh()")
                && didShow.contains("focusCoordinator.requestFocus("),
            "面板打开必须请求共享 manager 刷新双宿主，并继续恢复键盘焦点")

        for forbidden in [".connect(", ".repair(", ".disconnect("] {
            expect(
                !panel.contains(forbidden),
                "连接/修复/断开动作不得存在于 PanelView，命中：\(forbidden)")
        }
        expect(
            integrationsView.contains("model.requestToggle(for: agent.host)")
                && integrationsView.contains("model.requestClearReceiptHistory(for: host)")
                && integrationsModel.contains("func perform("),
            "连接、修复与破坏性断开只存在于集成 destination model/view")
    }
    suite("行内集成入口接线：选择器只转发宿主身份，typed route 提交留在 MenuBarController") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let scopePicker = codeOnly(
                "gui/Sources/ClaudioPanelPresentation/PanelSoundScopePicker.swift"),
            let theme = codeOnly("gui/Sources/ClaudioGUIComponents/ClaudioTheme.swift"),
            let menu = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "读不到 PanelView/PanelSoundScopePicker/ClaudioTheme/MenuBarController")
            return
        }
        expect(
            scopePicker.contains("panelSoundScopeIntegrationActionHost(")
                && scopePicker.contains("onOpenIntegration"),
            "行内状态动作必须消费 GUICore 决策级投影，并经回调上抛宿主身份")
        expect(
            !scopePicker.contains(".integrations(")
                && !scopePicker.contains("requestIntegrationsSettings"),
            "选择器不得自行构造 SettingsRoute 或触碰窗口呈现")
        expect(
            collapsingWhitespace(panel).contains("onOpenIntegration: onOpenIntegration")
                && panel.contains("onOpenIntegration: @escaping @MainActor (HostID) -> Void"),
            "PanelView 必须把行内动作回调原样转发给选择器，不夹带路由知识")
        guard
            let selectionStart = panel.range(of: "private func selectSoundScope")?.lowerBound,
            let selectionEnd = panel.range(
                of: "private var activityPresentation")?.lowerBound,
            selectionStart < selectionEnd
        else {
            expect(false, "无法定位 PanelView 的作用域选择写入边界")
            return
        }
        let selectionHandler = panel[selectionStart..<selectionEnd]
        expect(
            selectionHandler.contains("validatedPanelSoundScopeSelection(")
                && selectionHandler.contains(
                    "availableScopes: soundScopePresentations.map(\\.scope)")
                && selectionHandler.contains("panelModel.selectSoundScope(")
                && selectionHandler.contains(
                    "soundScopeSelection.projection.staleness == .staleRule"),
            "延迟选择写入前必须用最新可用作用域重验目标；写入、持久化与 stale 重钉判断都必须委托 C1 owner 投影")
        expect(
            menu.contains("requestIntegrationsSettings(")
                && collapsingWhitespace(menu).contains(
                    "preselect: host, returnFocusTo: .soundScope"),
            "MenuBarController 必须把行内动作接到既有 typed route 提交，并把焦点还回触发卡")
        // 这里只钉 GUI 对 GUICore/GUIComponents 接缝的消费；纯状态、门闩和
        // 动画投影的内部行为由 PanelSoundScopeInteractionSuite 编译执行验证。
        expect(
            scopePicker.contains("PanelSoundScopeActionCoordinator")
                && scopePicker.contains("!actionCoordinator.isPending")
                && whitespaceTolerantHitCount(
                    of: "PanelSoundScopeSuccessfulActionButton(",
                    in: scopePicker) == 2
                && whitespaceTolerantHitCount(
                    of:
                        "actionCoordinator: actionCoordinator, reduceMotion: reduceMotion",
                    in: scopePicker) == 2,
            "作用域选择与 Integrations 动作必须共用 GUIComponents 的单一成功提交路径")
        expect(
            scopePicker.contains("PanelSoundScopeRowInteractionContainer(")
                && scopePicker.contains("policy: .trigger")
                && scopePicker.contains("policy: .scopeAction")
                && scopePicker.contains("policy: .integrationAction"),
            "行级瞬时状态与三类按钮必须消费 GUIComponents 的共享 owner/策略")
        expect(
            scopePicker.contains("role: .integrationAction")
                && scopePicker.contains("role.usesPrimaryText(for: interactionState)"),
            "行内集成动作必须消费 GUICore 主文字强调策略")
        expect(
            scopePicker.contains("ClaudioTheme.panelSoundScopeSelectedInteractionOverlay(")
                && scopePicker.contains("ClaudioTheme.panelSoundScopeActionFocusFill(")
                && scopePicker.contains("ClaudioTheme.panelSoundScopeActionHoverStroke(")
                && scopePicker.contains("ClaudioTheme.panelSoundScopeFocusGlow(")
                && theme.contains("public enum PanelSoundScopeOpacity"),
            "Sound Scope 的选中叠层、动作焦点/hover 与焦点光晕必须由共享主题命名配方提供")
        for forbidden in [
            "elevated(colorScheme).opacity(0.22)",
            "statusColor(scope.status).opacity(0.12)",
            "statusColor(scope.status).opacity(0.70)",
            "statusColor(scope.status).opacity(0.55)",
        ] {
            expect(
                !scopePicker.contains(forbidden),
                "Sound Scope 不得绕开 ClaudioTheme 内联 opacity 配方：\(forbidden)")
        }
        expect(
            !scopePicker.contains("value: interactionState)")
                && scopePicker.contains("value: triggerHighlighted")
                && scopePicker.contains("value: interactionState.rowSurfaceAppearance")
                && scopePicker.contains("value: interactionState.isPressed")
                && scopePicker.contains("value: interactionState.isChevronEngaged")
                && whitespaceTolerantHitCount(
                    of: "value: interactionState.actionAppearance",
                    in: scopePicker) == 1
                && scopePicker.contains("value: interactionState.statusIconAppearance")
                && scopePicker.contains("value: interactionState.isInteractive"),
            "GUI 必须消费 GUICore 的最小动画投影，且胶囊不得靠 chevron 键让断言恒绿")
    }
    suite("config.lock 经 PanelAppComposition 灌进共享写者，PanelView 不持有任何锁") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let composition = codeOnly("gui/Sources/ClaudioGUICore/PanelAppComposition.swift"),
            let menu = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift")
        else {
            expect(false, "读不到 PanelView/PanelAppComposition/MenuBarController")
            return
        }

        expect(
            !panel.lowercased().contains("lockfile"),
            "C1：PanelView 不再构造 PanelConfigController（由组合层注入），任何锁 token 都不许回流进视图层")
        expect(
            menu.components(separatedBy: "configLockFile: ClaudioPaths.configLockFile").count - 1
                == 1
                && menu.lowercased().components(separatedBy: "lockfile").count - 1 == 2
                && composition.components(separatedBy: "lockFile: environment.configLockFile").count
                    - 1 == 2,
            "生产 config.lock 必须只由 Environment 注入；controller 与编辑 owner 使用同一锁，native shell 不得增加第二个锁")
        expect(
            !panel.contains("playLockFile") && !panel.contains("play.lock"),
            "PanelView 不写 play.state，不得碰宿主级防抖锁")
        for forbidden in ["settingsLockFile", "packsLockFile", "OnboardingActionEnvironment"] {
            expect(
                !panel.contains(forbidden),
                "PanelView 不再执行宿主连接，不得持有其锁/环境：\(forbidden)")
        }
    }
    suite("ClaudioGUI 只许一处生产 PanelView 构造点，且全 target 不得出现未锚定的锁") {
        // 这条 suite 的前身守的是「MenuBarController 构造 PanelView 时不许传 lockFile」——
        // C1 之后那个形参整个没了：PanelConfigController 由组合层（PanelComposition /
        // MenuBarController）构造并注入，PanelView 一行锁代码都不持有。于是这里的两道普查
        // 守的东西变成了：
        //
        //   1. 唯一构造点：第二个 `PanelView(` 构造点意味着第二个 panel 绕开共享的
        //      controller / C1 选择 owner（静音、切包、作用域选择各写各的）；
        //   2. 锁普查：任何 `lockfile` token 回流进 ClaudioGUI（比如有人图省事让 PanelView
        //      重新接一把锁）都必须是被锚定绊线按调用点绑住的那些。
        //
        // 它为什么必须是断言而不是注释：「MenuBarController.swift 是全仓唯一的 `PanelView(`
        // 构造点」曾是一句被写进注释的事实，而这个仓库自己的规矩是：该断言的地方不许放注释
        // （`/codex review 803c639,b74b7f3` 的完整性复查逮到的就是这一条）。
        //
        // D20 那条教训（「GUI 是显式向下传参的，改默认值挡不住调用点」）在这里依然成立，
        // 只是「默认值」已经随 C1 删除：现在没有默认值可依赖，构造点与锁 token 全靠下面两道普查。
        //
        // ## 为什么数的是整个 target，而不是 MenuBarController 一个文件（`/codex review d5ec97e,8f9cfa2`）
        //
        // 这条断言的**上一版**只读 `MenuBarController.swift`，措辞却写着「全仓唯一构造点」——
        // 与 T17h 那次（见 `guiSources()` 的文档）**逐字同一个病**：断言的措辞比它守的范围大。
        // 于是在 `ClaudioGUIApp.swift` 或任何一个新文件里写第二处
        //
        // ```swift
        // PanelView(configFile: …, lockFile: ClaudioPaths.playLockFile)
        // ```
        //
        // —— MenuBarController 里那个计数仍是 1、`!contains("lockFile")` 仍成立 —— **全绿**，
        // 而 GUI 的静音/切包写者已经回到 play.lock 上了。同一个洞在同一个 suite 里被修过一次，
        // 又在它旁边重开了一次；这次连措辞一起钉死。
        let sources = guiSources()
        expect(
            sources.count >= 5,
            "在 gui/Sources/ClaudioGUI 下一个 Swift 文件都没数到（实得 \(sources.count)）—— "
                + "下面两条都是**普查**，普查不到任何文件就永远等不到红，只会安静地绿下去")

        // 普查一：生产 target 只许 MenuBarController 构造 PanelView；State Gallery 另有一处
        // 整文件 `#if DEBUG` 的注入式预览构造点。
        //
        // 两种写法都数（`/codex review 840ea37` 的 P2）：`PanelView.init(` **不**包含 `PanelView(`，
        // 上一版只数后者，措辞却写着「唯一构造点」—— 又一次措辞比正则宽。真正守住锁的是下面的
        // 普查二（任何锁 token，不论写成哪种，都会漏出 `lockfile`）；普查一守的是「唯一生产构造点」
        // 这个前提本身 —— 第二个构造点就是第二个绕开共享 controller / C1 选择 owner 的面板。
        // 前提得连写法一起数，才配叫普查。
        var constructionSites: [String: Int] = [:]
        for file in sources {
            let bare = file.code.components(separatedBy: "PanelView(").count - 1
            let explicitInit = file.code.components(separatedBy: "PanelView.init(").count - 1
            let count = bare + explicitInit
            if count > 0 { constructionSites[file.path] = count }
        }
        expect(
            constructionSites == [
                "MenuBarController.swift": 1, "StateGalleryView.swift": 1,
                "NativeUIRegressionController.swift": 1,
            ],
            "ClaudioGUI 只许一处生产 PanelView 构造点和一处 DEBUG State Gallery 构造点，实得 "
                + "\(constructionSites)；新增入口必须重新证明它不绕开共享 controller / C1 选择 owner")
        if let gallery = sources.first(where: { $0.path == "StateGalleryView.swift" })?.code {
            expect(
                gallery.hasPrefix("#if DEBUG")
                    && gallery.contains("previewPanelModel:")
                    && !gallery.contains("ClaudioPaths.playLockFile"),
                "State Gallery 的额外 PanelView 构造点必须整文件 DEBUG、走预览注入且不得接触 play.lock")
        } else {
            expect(false, "找不到 StateGalleryView.swift，无法证明额外构造点只存在于 DEBUG")
        }

        // 普查二：全 target 的**代码**里不许出现任何未锚定的锁。
        // C1 之前 `PanelView.swift` 是唯一的例外（那个 config.lock 默认值与三条转发住在它里面）；
        // C1 之后它一行锁代码都不持有，而且根本不住在被普查的 target 里，它的豁免随之删除。
        // 剩下的豁免项见下（包锁构造点与 PanelComposition 的 config.lock 转发），每一项都换一条
        // 更严的锚定绊线。
        // `PackGalleryView` 的 doc comment 里提过 `selectPack(…lockFile:)`，`codeOnly` 已把它剥掉 ——
        // 这正是本文件头部记着的那次翻车（把谈论代码的文字当代码断）。
        //
        // ⚠️ **大小写不敏感**（`/review e7c38ea` 的 P1-2）：上一版数的是子串 `lockFile`，而
        // `configLockFile` / `settingsLockFile` 里那个 `L` 是**大写**的 —— 子串匹配大小写敏感，
        // 于是在任何一个 ClaudioGUI 文件里写
        //
        // ```swift
        // OnboardingActionEnvironment(…, configLockFile: ClaudioPaths.playLockFile, …)
        // ```
        //
        // —— 这条普查**一次都数不到**。措辞（「不许出现 lockFile」）比正则（「小写 l 那一种写法」）大，
        // 又一次。`lowercased()` 一行就把 `lockFile` / `configLockFile` / `settingsLockFile` 全收进来。
        // ## 豁免名单从一项变成三项，而净极性**没有**下降
        //
        // 拆掉 `AudioImportEnvironment.packsLockFile` 的默认值之后（`/codex review 95d16a5,b89a0ee,
        // 37745f2` 的 P1-A），生产侧两个构造点必须**显式**写出包锁 —— 于是这两个文件里出现了
        // `lockfile` 这个 token，而本普查的机制（数任何 `lockfile`）比它的目的（**config / settings**
        // 这两把锁只有一个来源）宽。
        //
        // ⚠️ 处理办法**不是**收窄 needle。本普查是**负向**的（出现 ⇒ 红），收窄 needle = 少数几处 =
        // 少红几次 = fail-**open**，与直觉相反。也不是白给两个文件开豁免 —— 那是同一个方向。
        //
        // 办法是：豁免它们，**同时**各给一条更严的锚定绊线（下面那条 suite）。那条绊线按调用点绑
        // 实参、做相等判定，并且用实参**自己的文本**算出该文件应有的命中数 —— 多出一个 token 就是
        // 第三处锁，当场红。所以每个被豁免的文件换来的是一条比本普查**更强**的守卫，不是一个洞。
        // `PanelComposition.swift` 的豁免同属这一类：它持有唯一一行 `lockFile: ClaudioPaths.configLockFile`
        // 转发（C1 之后 PanelView 不再碰锁），由上面的 config.lock suite 按调用点守着。
        //
        // ⚠️ 这里**直接读**文件级的 ``lockCensusExemptedFiles``，不许再套一层 suite 局部别名
        //   （`let lockCensusExemptions = lockCensusExemptedFiles`）。上一版套了，而那一层就是洞：
        //   下面那条绑定断言绑的是**常量**，普查消费的是**别名** —— 两者之间没有任何断言。往别名上
        //   写 `lockCensusExemptedFiles + ["MenuBarController.swift"]`，绑定断言逐字全绿
        //   （它读的常量一个字没变），而 MenuBarController.swift 从此静默退出本普查，对价一条没付；
        //   接着在它里面写 `PanelView(configFile: …, lockFile: ClaudioPaths.playLockFile)`，
        //   三个 GUI config 写者一起回到 play.lock 上 —— 整套仍然全绿。
        //   把常量提到文件级的**全部目的**就是让豁免集成为一个被绑住的值，再局部化一层等于原地
        //   把它解绑（memory 第九次那条「抽取一层接缝就往外挪一层」）。而且当时修复**自己的散文**
        //   与失败消息都指着 `lockCensusExemptions` 这个没被绑的名字，照着那句话去加第四项的人，
        //   落笔正好落在洞上。删掉那一层，编辑点就不存在了，代价为零。
        //   （`/codex review 51aebae,7caf6dc,e278736` 的红队对抗轮实测坐实。）
        //
        // ⚠️ **如实标注这一刀的性质：它消除的是编辑点，不是新增了一条守卫。**
        //   台账实测：把那层别名写回来、并在它上面加第四项（`lockCensusExemptedFiles +
        //   ["MenuBarController.swift"]`），**2468 条全绿**，没有任何断言会喊 —— 下面那条绑定
        //   断言读的是常量，常量一个字没变。也就是说这条路今天靠的是「源码里没有那个编辑点」，
        //   而不是「有人守着它」。要真正守住，得有一条断言去读本普查**实际消费的那个值**，
        //   而那需要一台能读自己源码又不自我污染的机器；不在本刀范围内，不声称封死。
        var lockLeaks: [String: Int] = [:]
        // ⚠️ 豁免按**文件名全等**判，不是 `hasSuffix` —— 极性在这里是反的，看清楚再改
        //   （`/review d7084be` 补，与 `/codex review d7084be` 那条 `hasPrefix(root.path)` 是同一个病
        //   的孪生体，只是坐在**豁免**这一侧）。`file.path` 是 `sourcesUnder` 交出来的**相对子路径**，
        //   于是裸 `hasSuffix("PanelView.swift")` 会连带命中**任何**以它收尾的文件名
        //   （`<任意前缀>PanelView.swift`）—— 它们会**自动**退出这条普查，而换来对价的那条锚定绊线
        //   按**精确文件名**读 `expectedProductionLocks`，够不到它们。
        //   实测（本轮，隔离 worktree）：往 `gui/Sources/ClaudioGUI/` 放一个含 `lockFile` token 的
        //   `SoundManagerPanelView.swift`，`lastPathComponent` 全等判据下**当场红** —— 这一刀有牙。
        //
        //   ⚠️ 另一个直觉上的泄漏形状 `Sub/PanelView.swift`（子目录下同名）**结构上不可达**，
        //   不要为它加判据：`sourcesUnder` 用的 `enumerator(atPath:)` 确实递归、确实会交出
        //   `Sub/PanelView.swift` 这种相对子路径，但同一个 SwiftPM target 里**不允许两个同名
        //   basename** —— 实测直接构建失败（`couldn't build …/PanelView.swift.o because of
        //   multiple producers`）。也就是说 SwiftPM 自己就是那一侧的围栏，源文件根本进不来。
        //   少豁免一个 = 多查一个文件 = 有人喊（fail-closed）；多豁免一个 = 一个文件静默退出审查 =
        //   **没有人会喊**（fail-open）。所以这里必须是最窄的那个判据。
        //
        //   ⚠️ 这里**不**举具体的未来文件名当论据。上一版写的是「plan/ 里已经写着
        //   `SoundManagerPanelView.swift`，这不是假想输入」—— 实测证伪：`plan/` 下确有
        //   `PLAN-SOUND-MANAGER.md`（规划了面板 + 独立管理窗口，点名的新 View 是 `AudioDropZoneView`
        //   与 `EventRowView`），但字符串 `SoundManagerPanelView` 全仓**只出现在那句声称它存在的注释
        //   自己身上**。那是一次凭空背书，与本分支 7caf6dc 修的是同一个病 —— 而这次它长在给修复
        //   背书的散文里。收窄判据的理由是**极性**（上一段），它自己站得住，不需要引用任何文件名。
        for file in sources
        where !lockCensusExemptedFiles.contains((file.path as NSString).lastPathComponent) {
            let count = file.code.lowercased().components(separatedBy: "lockfile").count - 1
            if count > 0 { lockLeaks[file.path] = count }
        }
        expect(
            lockLeaks.isEmpty,
            "ClaudioGUI 里出现了未锨定的锁：\(lockLeaks) —— "
                + "C1 之后 config.lock 的唯一来源是 PanelComposition 那一行转发，任何第二处锁 token 都会把"
                + "静音、切包两个 config.json 写者送回调用点指定的那把锁上。传 playLockFile = 阶段 A 的分锁"
                + "当场失效，而 PanelComposition.swift 一个字都不用改，整套 GUI 测试照样全绿。包锁不在此列，"
                + "由组装根和 preview 各自的锨定转发绊线守着。豁免名单：\(lockCensusExemptedFiles) —— "
                + "每一项都换来一条比本普查更严的锚定绊线，不是一个洞")
    }

    suite("C1：MenuBarController 注入共享选择 owner，面板与快捷键消费同一事实") {
        guard
            let menu = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let composition = codeOnly("gui/Sources/ClaudioGUICore/PanelAppComposition.swift"),
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift")
        else {
            expect(
                false, "读不到 MenuBarController/PanelAppComposition/PanelView —— 这条 suite 唯一的价值就是读它们")
            return
        }
        expect(
            composition.components(
                separatedBy: "SoundScopeSelection(defaults: environment.soundScopeDefaults)"
            ).count - 1 == 1
                && menu.contains("soundScopeDefaults: .standard")
                && menu.contains("private let composition: PanelAppComposition"),
            "生产选择 owner 必须以 .standard 构造（真实持久字节），且全 app 只有一个构造点")
        expect(
            menu.components(separatedBy: "soundScopeSelection: soundScopeSelection").count - 1 == 1,
            "executable 必须将同一个选择 owner 注入生产 PanelView；核心注入由组合行为检查保护")
        expect(
            menu.contains("soundScopeSelection.shortcutRoute()"),
            "全局快捷键必须消费 owner 的即时路由，不再直读 UserDefaults")
        expect(
            !menu.contains("panelSoundScopeDefaultsKey") && !panel.contains("@AppStorage"),
            "C1 之后持久字节只属于 owner：组合层不读 key，面板不持 AppStorage 副本")
        expect(
            panel.contains("panelModel: PanelConfigController,")
                && !panel.contains("PanelConfigController("),
            "PanelView 必须接收注入的 controller，不得再自构第二份")
    }

    suite("`AudioImportEnvironment.packsLockFile` 不许有默认值 —— 编译器执行「必须传」的那一半") {
        // 拆掉默认值那一刀（`/codex review 95d16a5,b89a0ee,37745f2` 的 P1-A）的守卫。
        //
        // ## 为什么编译器不能给它自己背书
        //
        // 把默认值加回去是一次**纯放宽**：现存调用点全都显式传着值，加完 `swift build` 零诊断。
        // 编译器强制的是默认值的*后果*，从不是它的*不存在* —— 本仓库为同一句话立过两个判例
        // （`@MainActor` 与「同步无挂起点」，都记在 `ManifestBinding.swift` 的 doc 里）。
        //
        // ## 它守的东西有多值钱：实测的那次实锤
        //
        // 默认值还在的时候，往 `gui/Tests` 里加一个漏传它、又走 `clearEventBinding` 的 fixture：
        // 编译通过、**2421 条断言全绿**；把用户真实的 `~/.claudio/packs.lock` 挪开再跑，那个文件被
        // **重新创建**出来（0 字节、`0600`，`FileLock` 的 `open(O_CREAT, 0o600)` 签名）。判据是
        // 「把它挪开再看它长不长回来」，不是退出码 —— 那个 0 字节文件在 `stat` 前后是同形的。
        guard
            let environment = codeWithoutStrings(
                "gui/Sources/ClaudioGUICore/AudioImportEnvironment.swift")
        else {
            expect(false, "读不到 AudioImportEnvironment.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        // ⚠️ 这个文件里有**两个** `public init`（`AudioImportEnvironment` 与 `AudioImportLimits`）——
        // 第一版按 `public init` 锚，实得 2 处当场红。所以锚的是「**带 `packsLockFile:` 形参**的那个
        // init」：0 处 ⇒ 形参没了（下面那条判定就是在守一段不存在的代码，对空集恒真绿），
        // >1 处 ⇒ 两个 init 都带这个形参，下面那条只看得住它逐个遍历到的，歧义必须有人来定。
        //
        // ## ⚠️ 那个 `.filter` 曾经**就是**这条 suite 的洞（`/codex review 51aebae,7caf6dc,e278736`
        //    的 P1-A，隔离 worktree 实测坐实）
        //
        // 它把「**不带** `packsLockFile:` 形参的 init」整个丢掉 —— 而那正是逃逸体本身。给这个
        // struct 加一个便利 init：
        //
        // ```swift
        // public init(
        //     userPacksDirectory: URL = ClaudioPaths.packsDirectory,
        //     bundledPacksDirectory: URL? = nil,
        //     durationProbe: any AudioDurationProbing,
        //     limits: AudioImportLimits = AudioImportLimits()
        // ) {
        //     self.init(…, packsLockFile: ClaudioPaths.packsLockFile)   // 静默回到用户真实 home
        // }
        // ```
        //
        // —— 12 行，`swift build` 零诊断，随后让任意 fixture 漏传那把锁：**2456 条检查全绿**，
        // 与基线逐字同数。「漏传 = 编译错误」这个性质当场没了，而这条 suite 一声不吭：它守的是
        // **一种语法形态**（形参上挂没挂默认值），不是它声称的那个**后果**（漏传能不能编过）。
        // 白名单式识别（认不出 ⇒ 静默放行）伪装成围栏 —— 本仓库反复立案的那一条，这次长在
        // 为「把绊线升成围栏」而写的这一刀自己身上。
        //
        // 下面三条把它补成围栏：**总数**锚定 + 非包锁 init 的形参表**逐字全等** + `extension` 普查。
        // 三条缺一不可：只锚总数，删掉 `AudioImportLimits` 的 init 再加便利 init 就绕过去了
        // （总数仍是 2）；只钉签名，加第三个 init 时它一眼都不看。
        let allPublicInits = callArguments(of: "public init", in: environment)
        expect(
            allPublicInits.count == 2,
            "`AudioImportEnvironment.swift` 里的 `public init(…)` 不是恰好 2 处（实得 "
                + "\(allPublicInits.count) 处）—— 这个文件按设计只住着两个类型的构造器："
                + "`AudioImportEnvironment` 一个（`packsLockFile:` 必填）与 `AudioImportLimits` 一个。"
                + "多出来的第三个最可能是一个**便利 init**：它不带 `packsLockFile:` 形参、内部转发一个"
                + "硬编码的 `ClaudioPaths.packsLockFile`，于是「漏传 = 编译错误」当场失效，而下面那条"
                + "按形参锚定的判定**结构上看不见它**（它先被 `.filter` 丢掉了）。"
                + "少一个 = 某个构造器没了，下面两条各自在守一段不存在的代码")
        // 非包锁的那一个 **必须**是 `AudioImportLimits` 的那个已知签名，逐字全等。
        //
        // ⚠️ 这一条与上面那条**不是**同一个靶子，别把任何一条当成锦上添花：
        //
        // * 上面那条（总数 == 2）逮的是「**多**一个 init」——便利 init 直接加进来那一种；
        // * 这一条逮的是「总数没变、但那个非包锁 init **换了个人**」。
        //
        // ⚠️ 那么「删掉 `AudioImportLimits.init` 腾出名额、再补一个便利 init」这条组合路呢？
        //    **实测走不通**（不是推理）：删掉它之后 Swift 合成的 memberwise init **不带默认值**，
        //    同一个文件里 `limits: AudioImportLimits = AudioImportLimits()` 那句空参调用当场编译
        //    失败 —— `error: missing arguments for parameters 'maxFileSizeBytes',`
        //    `'maxDurationSeconds' in call`。台账里那个变异因此是**三态里的第三态**（既不是红也不是
        //    绿，是编译不过），如实记在这里，免得下一个人以为它验过了。
        //    所以这两条合起来对「本文件里冒出第二个能不传包锁就造出环境的入口」是完备的。
        //
        // **相等**判定，不是 `contains`：`maxFileSizeBytes: Int = …` 逐字包含任何它的前缀。
        let audioImportLimitsInitSignature =
            "maxFileSizeBytes: Int = 5 * 1024 * 1024, maxDurationSeconds: Double = 3.0"
        let nonLockInits =
            allPublicInits
            .filter { argumentValue("packsLockFile", in: $0) == nil }
            .map(collapsingWhitespace)
        expect(
            nonLockInits == [audioImportLimitsInitSignature],
            "`AudioImportEnvironment.swift` 里**不带** `packsLockFile:` 形参的 `public init(…)` 的形参表"
                + "必须正好是 `AudioImportLimits` 那一个（`\(audioImportLimitsInitSignature)`），"
                + "实得 \(nonLockInits) —— 对不上就意味着这个文件里多了一个**可以不传包锁就构造出"
                + "环境**的入口（便利 init / 第二个 memberwise 风格入口）。那种入口让「漏传 = 编译"
                + "错误」退回成「漏传 = 静默去用户 home 上开锁」，而测试照样全绿：实测 2456 条一条不红")
        let initializerArguments =
            allPublicInits
            .filter { argumentValue("packsLockFile", in: $0) != nil }
        expect(
            initializerArguments.count == 1,
            "`AudioImportEnvironment.swift` 里带 `packsLockFile:` 形参的 `public init(…)` 不是恰好 1 处"
                + "（实得 \(initializerArguments.count) 处）—— 0 处 = 形参整个没了，下面那条判定在守一段"
                + "不存在的代码（对空集恒真绿）；>1 处 = 有第二个入口，而包锁只该有一个必填入口")
        for arguments in initializerArguments {
            expect(
                argumentValue("packsLockFile", in: arguments) == "URL",
                "`AudioImportEnvironment.init` 的 `packsLockFile:` 形参不是**没有默认值的** `URL`，"
                    + "实际是 `\(argumentValue("packsLockFile", in: arguments) ?? "<没有这个形参>")` —— "
                    + "带上默认值，漏传这把锁就从编译错误变回**静默**落回那个值。而这一把与它的兄弟"
                    + "`userPacksDirectory` 的失败模式不一样：忘了后者会当场断言失败（真实 packs 里"
                    + "没有 fixture），忘了这一把只会安静地去用户机器上开一把真锁 —— 测试照样全绿，"
                    + "只是与正在运行的 Claudio.app 抢锁、并在 `~/.claudio/` 里落一个文件。静默那一类"
                    + "不能靠纪律，只能靠编译器。**相等**判定，不是 `hasPrefix`：`URL = ClaudioPaths.…` "
                    + "逐字以 `URL` 开头")
        }

        // ## 第三条：`extension` 普查 —— 上面两条**唯一**够不到的那条路
        //
        // 上面两条都只读 `AudioImportEnvironment.swift` 这**一个文件**。而 Swift 允许在同一个
        // 模块的**任何**文件里给这个 struct 加构造器：
        //
        // ```swift
        // // 随便哪个新文件，甚至就在测试包里
        // extension AudioImportEnvironment {
        //     public init(userPacksDirectory: URL, durationProbe: any AudioDurationProbing) {
        //         self.init(…, packsLockFile: ClaudioPaths.packsLockFile)
        //     }
        // }
        // ```
        //
        // 效果与那个便利 init 逐字相同（漏传重新变得能编过、静默落到用户真实 home），而上面两条
        // 一个字都读不到它 —— 又是「新调用点最可能的落点是**新文件**」那条老规律。
        //
        // 扫三个目录：两个生产 target **加测试包**。测试包必须一起扫，因为那里才是漏传真正会发生
        // 的地方（b89a0ee 那个潜伏洞：四个 fixture 漏传，八十余个调用点在用户真实 home 上开锁，
        // 全程 2421 条全绿）。
        //
        // ⚠️ needle **分段拼**，源码里永远不出现连续的那个串：本普查扫的目录**包含本文件**，
        // 把它逐字写进来 = 命中的第一处就是我自己的判据 = 这条断言永久假红。本仓库为这个形状翻过车
        // （`SourceScannerSuite` 的自纠⑤，以及本文件那条 `injected` + `-locks`）。失败消息里的那一份
        // 也是运行时插值，不是源码文本。
        let environmentExtensionMarker = "extension " + "AudioImportEnvironment"
        var environmentExtensions: [String: Int] = [:]
        for root in [
            "gui/Sources/ClaudioGUI", "gui/Sources/ClaudioGUICore",
            "gui/Tests/ClaudioGUICoreTests",
        ] {
            let scanned = sourcesUnder(root)
            expect(
                scanned.count >= 5,
                "在 \(root) 下只数到 \(scanned.count) 个 Swift 文件 —— 这条是**普查**，普查不到文件"
                    + "就永远等不到红，只会安静地绿下去")
            // 读 `code`（剥注释、保留字符串内容）：注释里谈论这个形状的散文**不该**被数到。
            // 生产与下面合成控制都必须走同一个 census 入口，防止生产悄悄绕回固定空白匹配而控制仍绿。
            environmentExtensions.merge(
                whitespaceTolerantMarkerCensus(
                    environmentExtensionMarker, in: scanned, pathPrefix: "\(root)/")
            ) { _, replacement in replacement }
        }
        expect(
            environmentExtensions.isEmpty,
            "有文件给 `AudioImportEnvironment` 开了 `\(environmentExtensionMarker)`："
                + "\(environmentExtensions) —— 本 suite 上面那两条只读 "
                + "`AudioImportEnvironment.swift` 一个文件，一个开在别处的扩展构造器让「漏传包锁 = "
                + "编译错误」当场失效，而它们结构上看不见。这不是「扩展一律不许」的教条：包锁的"
                + "**必填性**是这个类型今天唯一靠编译器执行的不变量，而扩展是绕开它最短的一条路。"
                + "真要加扩展，先把上面那两条改成能读到扩展里的构造器，再来放行这一条")

        // 上面那条 `whitespaceTolerantHitCount` 的**正/负控**：合成输入直接喂**同一个函数**（定义
        // 见 91 行附近，紧跟 `collapsingWhitespace` 之后），不各自重新拼一遍「collapse 再数」——
        // 那样正/负控测的只是「这段逻辑抽象上对不对」，测不出「生产那行有没有真的在调它」（该函数
        // 的 doc comment 里记着这条教训第一版是怎么栽的：生产那行独立改回旧版，正/负控一个字不变，
        // 2472 条检查照样全绿）。现在两边共用同一个函数体，回退生产那一行就是回退这四条正/负控在
        // 测的同一段代码，才会真的红。
        //
        // 真实仓库里从来没人写过两个空格的 `extension`，所以「以前逮不住、现在逮得住」这件事没有
        // 真实文件能验证，只能靠合成输入。
        //
        // ⚠️ 下面四个变体的 needle **分段拼**，与 `environmentExtensionMarker` 自己那行同一个理由：
        // 本条 suite 扫的目录**包含本文件**，若哪个变体在源码里连续写出 `extension AudioImportEnvironment`
        // （哪怕中间隔的是两个空格、一个 `\n`），`source.code` 保留字符串字面量内容，扫到自己这行
        // 就会算作一次命中 —— 上面那条围栏当场对着自己的正/负控假红。第一版就是这么栽的（实测：
        // `swift run` 直接报 `ViewWiringSuite.swift: 2` 次命中）。
        let extensionKeyword = "extension"
        let typeName = "AudioImportEnvironment"
        let whitespaceControls = [
            scannedFixture(
                path: "SingleSpace.swift", text: extensionKeyword + " " + typeName + " {}"),
            scannedFixture(
                path: "DoubleSpace.swift", text: extensionKeyword + "  " + typeName + " {}"),
            scannedFixture(
                path: "Newline.swift", text: extensionKeyword + "\n" + typeName + " {}"),
            scannedFixture(
                path: "Negative.swift",
                text: extensionKeyword + " " + "SomeUnrelatedType {}"),
        ]
        let controlCensus = whitespaceTolerantMarkerCensus(
            environmentExtensionMarker, in: whitespaceControls)
        expect(
            controlCensus == [
                "SingleSpace.swift": 1,
                "DoubleSpace.swift": 1,
                "Newline.swift": 1,
            ],
            "生产同入口的空白正/负控失配：实得 \(controlCensus) —— 单空格、双空格与换行必须命中，"
                + "无关类型必须保持不命中")

        guard
            let thisSuite = codeWithoutStrings(
                "gui/Tests/ClaudioGUICoreTests/ViewWiringSuite.swift")
        else {
            expect(false, "读不到 ViewWiringSuite.swift，无法证明生产与控制共用 census 入口")
            return
        }
        let sharedPipelineCallCount =
            thisSuite.components(separatedBy: "whitespaceTolerantMarkerCensus(").count - 1
        expect(
            sharedPipelineCallCount == 3,
            "`whitespaceTolerantMarkerCensus` 必须恰好出现三次（声明、生产普查、合成控制），实得 "
                + "\(sharedPipelineCallCount) 次 —— 生产若绕回独立的固定空白匹配，控制即使全绿也证明不了"
                + "生产接线；新增调用同样必须先解释它属于哪条证明边")
    }

    suite("生产侧两处显式包锁各自锚到调用点 —— 它们换来了 lockLeaks 普查的两个豁免") {
        // 这条 suite 是上面那条普查两个新豁免项的**对价**。普查按文件名放行它们，这里按**调用点**
        // 逐个绑回来：实参做相等判定，再用实参自己的文本算出该文件应有的 `lockfile` 命中数 ——
        // 多出一个 token 就是第三处锁，当场红。所以豁免换来的是更严，不是更松。
        // `literal` = 该文件里必须**逐字**出现的字符串**内容**。上面读的是清空字符串之后的文本，
        // 字面量在那里一律是空串，于是「占位路径有没有偷偷变成真实路径」在那一路上完全不可判。
        // 这一列补上那一半，而且它**跟着表走** —— 上一版把这半条检查写死在循环外、只覆盖
        // `StateGalleryView.swift` 一个文件，表里再加第三项时那一半会静默不存在；同时循环里
        // `let raw = codeOnly(…)` 绑了却一次没用，Swift 为它报 `immutable value 'raw' was never used`。
        // 那条警告在这台机器上**一直看不见**：每次 build 都是增量的（零条 Compiling），
        // 而 e278736 / 51aebae 的 commit message 写的是「两个包 Build complete 零警告」——
        // `/review d7084be` 用 `--scratch-path` 全新编译一次才把它照出来（8 条，全是这一条）。
        // 这张表现在住在文件级（见 ``expectedProductionLocks`` 的 doc）—— 它同时喂三条断言，
        // 其中一条是下面那条**构造点普查**，而普查按定义不能读一张 suite 私有的表。
        // ⚠️ [10] 「每个豁免项都换来一条更严的锚定绊线」的**可执行**版本（`/review d7084be` 红队 P2）。
        //    上一版这句话只是散文：两张硬编码清单互不绑定，往 `lockCensusExemptedFiles` 加第四项而这里
        //    一条不写 —— 那个文件从此静默退出普查，编译通过、全绿、没有人会喊（豁免侧放宽 = fail-open）。
        //    判据是**集合相等**不是 `count`：数目对得上而成员错位同样是一个没人守的文件。
        expect(
            Set(lockCensusExemptedFiles).subtracting(lockCensusSelfGuardedFiles)
                == Set(expectedProductionLocks.map(\.file)),
            "`lockCensusExemptedFiles` 减掉 GUI composition 的专属接线豁免（它由本文件"
                + "另一条 suite 按调用点守着）之后，必须**逐项等于** `expectedProductionLocks` 的文件集 —— 否则「豁免换来的是"
                + "更严，不是更松」这句话就有一项没兑现。豁免侧="
                + "\(Set(lockCensusExemptedFiles).subtracting(lockCensusSelfGuardedFiles).sorted())，"
                + "对价侧=\(Set(expectedProductionLocks.map(\.file)).sorted())")

        for expected in expectedProductionLocks {
            // ⚠️ [9] `literal` 是 `String?`，而 `if let` 意味着「没填 ⇒ 不查」—— 那正是这一刀声称要
            //    修掉的 fail-open，只是从「第三项」挪到了「literal 填 nil 的那一项」。
            //    这条把「哪一行**必须**填」从散文变成断言：`value` 里出现被清空的字符串字面量（`""`）
            //    就说明这一处的真实实参含字面量内容，而相等判定对内容恒不可判 ⇒ 必须有 `literal` 那一半。
            expect(
                !expected.value.contains("\"\"") || expected.literal != nil,
                "`expectedProductionLocks` 里 `\(expected.file)` 那一行的 `value` 是 "
                    + "`\(expected.value)` —— 它含一个被清空的字符串字面量，说明真实实参里有字面量内容，"
                    + "而相等判定读的是清空之后的文本、对内容完全不可判。这一行**必须**填 `literal`，"
                    + "否则那半条检查静默不存在（漏填 = 不查 = fail-open）")

            guard let code = codeWithoutStrings("gui/Sources/ClaudioGUI/\(expected.file)"),
                let raw = codeOnly("gui/Sources/ClaudioGUI/\(expected.file)")
            else {
                expect(false, "读不到 \(expected.file) —— 这条 suite 唯一的价值就是读它")
                continue
            }
            let calls = callArguments(of: "AudioImportEnvironment", in: code)
            expect(
                calls.count == 1,
                "\(expected.file) 里必须正好有 1 处 `AudioImportEnvironment(…)` 构造点，实得 "
                    + "\(calls.count) 处 —— 0 处 = 下面两条在守一段不存在的代码，>1 处 = 多出来的那个"
                    + "可能是喂饱断言的死代码诱饵，也可能是一次真实重构，两种都必须有人看一眼再放行")
            for arguments in calls {
                expect(
                    argumentValue("packsLockFile", in: arguments) == expected.value,
                    "\(expected.file) 的 `AudioImportEnvironment(…)` 的 `packsLockFile:` 实参必须**正好"
                        + "是** `\(expected.value)`，实际是 "
                        + "`\(argumentValue("packsLockFile", in: arguments) ?? "<没有这个实参>")` —— "
                        + expected.why
                        + "。（读的是清空字符串内容之后的文本，所以字面量在这里一律是空串 —— 内容"
                        + "由下面那条单独钉。）")
            }
            // 用实参**自己的文本**算出该文件应有的命中数，不写死一个数字：写死的数字与实参一起
            // 漂移时不会有人喊，而这里两者是同一个来源。多出来的每一个 token 都是第三处锁。
            let packageLocksAccounted =
                calls
                .compactMap { argumentValue("packsLockFile", in: $0) }
                .map {
                    "packsLockFile: \($0)".lowercased().components(separatedBy: "lockfile").count
                        - 1
                }
                .reduce(0, +)
            var accounted = packageLocksAccounted
            if expected.file == "NativeUIRegressionController.swift" {
                // 核心写者共用组合根 Environment 注入的 config.lock；本地活动与日志仍留在
                // executable 夹具层。逐个调用点锚定隔离根，并普查未解释的额外锁。
                for (constructor, label, literal) in [
                    ("PanelAppComposition.Environment", "configLockFile", "config.lock"),
                    ("LocalActivitySummaryStore", "lockFile", "activity.lock"),
                    ("ActivityDiagnosticLogStore", "logLockFile", "log.lock"),
                    ("appendLogLine", "lockFile", "log.lock"),
                ] {
                    let sites = callArguments(of: constructor, in: code)
                    expect(
                        sites.count == 1
                            && sites.allSatisfy {
                                argumentValue(label, in: $0) == "root.appendingPathComponent(\"\")"
                            }, "验收构造点必须锚定同一隔离根：\(constructor)")
                    let rawSites = callArguments(of: constructor, in: raw)
                    expect(
                        rawSites.count == 1
                            && rawSites.allSatisfy {
                                argumentValue(label, in: $0)
                                    == "root.appendingPathComponent(\"\(literal)\")"
                            }, "验收锁字面量必须在实际调用点匹配：\(constructor)")
                    accounted += sites.count
                }
            }
            let actual = code.lowercased().components(separatedBy: "lockfile").count - 1
            expect(
                actual == accounted,
                "\(expected.file) 里 `lockfile` 命中 \(actual) 次，而上面那个被锚定的包锁实参只解释得了"
                    + " \(accounted) 次 —— 多出来的 \(actual - accounted) 处是**没有人在断言**的第三处锁。"
                    + "这个文件之所以能从 `lockLeaks` 普查里豁免，全部理由就是「它里面的锁都被这条 suite "
                    + "按调用点绑住了」。多一处没绑的，那句话就不成立了")

            // 字面量那一半，**跟着表走**（上一版写死在循环外、只覆盖 StateGalleryView 一个文件）。
            // 上面读的是清空字符串内容之后的文本，字面量在那里一律是空串，于是「占位路径有没有偷偷
            // 变成真实路径」在上面完全不可判 —— 这一条是那一半，读的是 `raw`（保留字符串内容）。
            // 字面量那一半 —— **绑回调用点**，不是全文件 `contains`（`/review d7084be` 红队 P1）。
            //
            // ⚠️ 上一版写的是 `raw.contains(literal)`：全文件、无锚点。于是把真实实参换成
            //    `URL(fileURLWithPath: "/Users/<me>/.claudio/packs.lock")`、同时在文件里任意位置
            //    留一句死代码 `private let note = "/dev/null/claudio-preview-packs.lock"`，三条断言
            //    逐条通过 —— 相等判定读的是清空字符串的文本（两种写法都被清成 `URL(fileURLWithPath: "")`），
            //    而 `contains` 被那句诱饵喂饱。**这与本文件上面亲口判过死刑的见证值形状逐字同构**，
            //    只是换了个位置重开一次。
            //
            //    修法是换**判据种类**（不是换读模型）：从 `raw` 里按同一个调用点切出实参，
            //    在**那一段**里找字面量。同文件别处的诱饵从此够不着。
            if let literal = expected.literal {
                let rawCalls = callArguments(of: "AudioImportEnvironment", in: raw)
                let rawValue = rawCalls.compactMap { argumentValue("packsLockFile", in: $0) }.first
                // 切不出来一律判红（围栏，不是探针）——`raw` 保留字符串内容，一句带 `(` 的字面量
                // 会把配平括号的扫描带偏，那时我们**不知道**自己在看什么，不能默认它是对的。
                expect(
                    rawValue != nil,
                    "从 \(expected.file) 的**原始文本**（保留字符串内容）里切不出 "
                        + "`AudioImportEnvironment(…)` 的 `packsLockFile:` 实参 —— 切不出来就无从判定"
                        + "字面量内容，而「无从判定」必须落在红那一侧。实得 \(rawCalls.count) 处调用")
                expect(
                    rawValue?.contains(literal) == true,
                    "\(expected.file) 的 `packsLockFile:` **实参本身**里必须逐字出现 `\(literal)`，"
                        + "实得 `\(rawValue ?? "<切不出来>")` —— 上面那条相等判定读的是清空字符串内容"
                        + "之后的文本（`\(expected.value)`），对「字面量换成了什么」完全不可判；这一条是"
                        + "那一半。判据绑在**调用点**上而不是全文件：同文件别处留一句提到该串的死代码"
                        + "喂不饱它。preview 是 `#if DEBUG` 里的代码，没有任何行为测试跑它，一条指向"
                        + "真实 home 的占位路径不会有别的东西喊")
            }
        }
    }

    suite("注入包锁的构造点全测试包只此一处 ——「唯一来源」这句散文的可执行版本") {
        // ## 它治的病
        //
        // `AudioImportFixtures.swift` 的 doc 把 ``injectedPacksLock(under:)`` 称作「**全包唯一来源**」。
        // 那句话在 `/codex review 95d16a5,b89a0ee,37745f2` 之前是**假的**：`OnboardingActionsSuite` 的
        // `FixtureTargets.init` 里另有一段**同形而不同源**的内联构造。代价不是理论上的 —— d7084be
        // 那一刀为了同一个病要改**两处**，而只改一处不会有任何断言变红。
        //
        // 两处已经合并。这条普查是那句话的**可执行版本**：散文说「唯一」，就得有人数着。
        //
        // ## ⚠️ 判据不能是会被自己污染的那次 grep
        //
        // 这条普查扫的是 `gui/Tests/ClaudioGUICoreTests` —— **包含本文件**。把目录名逐字写进本文件，
        // grep 当场多命中一处，命中的还是我自己的判据。本仓库为这个形状翻过车（`SourceScannerSuite`
        // 里那条自纠⑤：「`packsLockBusy` 在整个 `gui/` 目录零命中」—— 写下这句话本身就把这个词写进了
        // `gui/`）。所以 needle **分段拼**，源码里永远不出现连续的那个串；失败消息里的那一份是运行时
        // 插值，不是源码文本。
        //
        // 读 `code`（剥注释、**保留字符串内容**）而不是 `codeWithoutStrings`：要数的东西
        // （`"injected-locks-\(nonce)"`）本身就是一个字符串字面量，清空内容会把靶子一起清掉。
        // 代价如实标注：注释里谈论这个目录名的散文不会被数到（那是**想要**的，本文件下面就有几段），
        // 但一段被误判成字符串的代码同样数不到 —— 后者由本文件第一条 suite（`unmodeled` 普查）兜。
        //
        // ## ⚠️ 它的天花板，别把措辞写大
        //
        // 它按**这一种形状的目录名**认人。一个换了名字的第二处构造（`fixture-locks-<nonce>/…`）它
        // 认不出来。所以它守的是「**同一个病原样复发**」（这正是实际发生过的那一种），**不是**
        // 「所有可能的第二来源」。真正管住「值必须来自被注入的那把锁」的是持锁行为测试。
        let lockDirectoryMarker = "injected" + "-locks"
        let testSources = sourcesUnder("gui/Tests/ClaudioGUICoreTests")
        expect(
            testSources.count >= 20,
            "在 gui/Tests/ClaudioGUICoreTests 下只数到 \(testSources.count) 个 Swift 文件 —— 这条是"
                + "**普查**，普查不到文件就永远等不到红，只会安静地绿下去（实测该目录下有三十余个）")
        let constructionSites =
            testSources
            .filter { $0.code.contains(lockDirectoryMarker) }
            .map(\.path)
        expect(
            constructionSites == ["AudioImportFixtures.swift"],
            "注入包锁的构造点不是恰好一处（实得 \(constructionSites)）—— 期望只有 "
                + "`AudioImportFixtures.swift` 里的 `injectedPacksLock(under:)`。"
                + "多出来一处 = 又一份**同形而不同源**的拷贝：它今天可能写得一模一样，但下次给这个"
                + "形状打补丁（比如把固定名字换成运行时随机成分，d7084be 干的正是这件事）只改一处"
                + "不会有任何断言变红，另一处静默留在可派生的老位置上，而那正是「就地算一把锁」的"
                + "变异体求值出来会撞上的地方 —— 持锁行为测试于是全绿，保护力归零。"
                + "少了那一处 = 要么文件改名了（把这条断言的期望值一起更新），要么唯一来源没了"
                + "（那 `AudioImportFixtures.swift` 的 doc 里「全包唯一来源」那句话又变回散文）")
    }

    suite("生产侧 `AudioImportEnvironment(…)` 构造点**普查** ——「两个构造点」那句散文的可执行版本") {
        // ## 它治的病（`/codex review 51aebae,7caf6dc,e278736` 的 P1-B，隔离 worktree 实测坐实）
        //
        // `AudioImportEnvironment.swift` 的 doc 逐字写着「生产侧两个构造点显式写出真实路径，
        // **各自有绊线看着**」。那个「两个」此前是一句**没有任何东西在数**的散文：上面那条
        // 「生产侧两处显式包锁各自锚到调用点」按 ``expectedProductionLocks`` 里**硬编码的两个
        // 文件名**逐一去读，它不枚举任何目录 —— 措辞比覆盖范围大，本仓库第 N 次，而这一次长在
        // 「把绊线从硬编码文件升成围栏」那一刀**自己**身上。
        //
        // 实测的第三构造点（往 `gui/Sources/ClaudioGUICore/` 放一个文件）：
        //
        // ```swift
        // public func makeAudioImportEnvironmentForPack(
        //     at d: URL, durationProbe: any AudioDurationProbing
        // ) -> AudioImportEnvironment {
        //     AudioImportEnvironment(
        //         userPacksDirectory: d, durationProbe: durationProbe,
        //         packsLockFile: d.appendingPathComponent("packs.lock"))   // 就地算一把锁
        // }
        // ```
        //
        // —— `swift build` 零诊断、**2456 条检查全绿**、一条都不红。三张网一张都罩不到它：
        // `lockLeaks` 只扫 `gui/Sources/ClaudioGUI`（`guiSources()`）；`guiCoreSources()` 那条只禁
        // `playLockFile` 与字面量 `play.lock`；`SourceScannerSuite` 的 T3 四条腿只纳入**代码里出现
        // `mutateManifestJSON` 的文件**，而一个环境**工厂**一个字节的 manifest 都不写。
        //
        // 它一旦被任何一个 manifest 写者用上，那个写者转发的**文本**依旧逐字是
        // `environment.packsLockFile`（第四条腿全绿 —— 它守的是转发，不是被转发的那把锁自己
        // 从哪来），求值出来却是包目录里的另一把锁：与 helper `performFirstRunSetup` 在
        // `~/.claudio/packs.lock` 上取的那把**永不冲突** ⇒ 跨进程互斥断开 ⇒ 用户刚绑好的音效被
        // 包发布循环整目录 `moveItem` 吞掉，而那次写照旧返回 `.success`。
        //
        // ## 为什么挂在这里而不是给上面那条再补一个文件名
        //
        // 与第四条腿搬家时逐字同一个理由：新构造点最可能的落点是**新文件**（`gui/Package.swift`
        // 没有 `sources:` 白名单，默认目录下任意 `.swift` 直接进 target），而一张文件名清单
        // 结构上读不到它。所以这里数的是**目录**，期望值从 ``expectedProductionLocks``（文件级
        // 单源）派生 —— 不是第三张互不绑定的硬编码清单。
        let productionRoots = [
            (root: "gui/Sources/ClaudioGUI", target: "ClaudioGUI"),
            (root: "gui/Sources/ClaudioGUICore", target: "ClaudioGUICore"),
        ]
        var constructionCensus: [String: Int] = [:]
        var scannedFileCount = 0
        var unreadable: [String] = []
        var hiddenShapes: [String: [String]] = [:]
        for entry in productionRoots {
            for source in sourcesUnder(entry.root) {
                scannedFileCount += 1
                let key = "\(entry.target)/\(source.path)"
                // 喂 `codeWithoutStringLiterals`，**不是** `code`：后者保留字符串内容，一句
                // `"pack (1.json"` 里的 `(` 会被计进深度、括号从此永不配平（`callArguments` 的
                // doc 里立着这条判例）。`sourcesUnder` 只交 `code`，所以这里按相对路径再要一次。
                guard let code = codeWithoutStrings("\(entry.root)/\(source.path)") else {
                    unreadable.append(key)
                    continue
                }
                let count = callArguments(of: "AudioImportEnvironment", in: code).count
                if count > 0 { constructionCensus[key] = count }

                // 围栏那一半：`callArguments` 是白名单（`head(` / `head (` / `head.init(` /
                // `head .init (` 四种），而白名单永远不完整。凡是**结构上认不出**的构造形状都必须
                // 变成红 —— 「我读不到它怎么构造的」绝不等于「它没事」。
                //
                // ⚠️ 过滤掉「条件编译」那一类，而这**有论证**、不是随手收窄：`unmodeledConstruction`
                // `Shapes` 记 `#if` 的理由是「非活跃分支的构造点会替真实构造喂饱『≥1 处 / 正好 N 处』
                // 那类断言」。本条的判据是**集合相等**（文件 → 计数），`#if` 只会让计数**偏多**、
                // 让键**变多**，两种都是红 —— 它在这条判据上不构成隐身路径。不过滤则
                // `StateGalleryView.swift`（整份 `#if DEBUG`）永久假红，然后被下一个人删掉。
                //
                // 对两个 target 的**每一个**文件跑，而不是先要求文件提到类型名。否则
                // `someCall(environment: .init(…))` 这类完全依赖上下文推断的构造既不含类型名、也不会被
                // `callArguments` 计数，能静默绕过整份 census。当前生产代码没有这种不透明构造；未来若要
                // 引入，必须先给扫描器一条可判定的类型边界，而不是让它在这里无声通过。
                let shapes = unmodeledConstructionShapes(
                    of: "AudioImportEnvironment", in: code
                ).filter { !$0.contains("条件编译") }
                if !shapes.isEmpty { hiddenShapes[key] = shapes }
            }
        }
        expect(
            scannedFileCount >= 10,
            "两个生产 target 加起来一个 Swift 文件都没数到（实得 \(scannedFileCount)）—— 这条是"
                + "**普查**，普查不到文件就永远等不到红，只会安静地绿下去")
        expect(
            unreadable.isEmpty,
            "这些生产源文件读不出来：\(unreadable) —— 读不到 ⇒ 那个文件里的构造点对本普查**隐身**，"
                + "而隐身在这条判据上是静默放行。认不出 ⇒ 红，不许静默跳过")
        expect(
            hiddenShapes.isEmpty,
            "这些文件里出现了 `callArguments` **结构上认不出**、且可能构造 "
                + "`AudioImportEnvironment` 的形状："
                + "\(hiddenShapes) —— 那一处会静默退出本普查，而普查是「就地算一把锁的第三个构造点」"
                + "唯一的守卫。要么把它改成扫描器认得的直接构造，要么先把 `callArguments` 教会这个"
                + "形状再放行")

        var expectedCensus: [String: Int] = [:]
        for expected in expectedProductionLocks {
            expectedCensus["ClaudioGUI/\(expected.file)"] = 1
        }
        expect(
            constructionCensus == expectedCensus,
            "生产侧 `AudioImportEnvironment(…)` 的构造点集合必须**逐项等于** "
                + "\(expectedCensus.keys.sorted())，实得 \(constructionCensus) —— "
                + "多出来的那一处就是一个**没有任何断言在看**的包锁来源：上面那条按调用点锚定的 "
                + "suite 只读 ``expectedProductionLocks`` 里点名的文件，它对一个新文件结构上是瞎的。"
                + "它若就地算一把锁（`packDirectory` 的兄弟位、每包一把的 `<id>.lock`），这个环境喂给"
                + "任何 manifest 写者之后，那个写者与 helper 的 `performFirstRunSetup` 就用上**两把"
                + "不同路径**的 `flock` ⇒ 跨进程互斥当场断开 ⇒ 用户刚绑好的音效被包发布循环整目录 "
                + "`moveItem` 吞掉，而那次写照旧返回 `.success`。"
                + "少了一处 = 要么文件改名/构造点搬家（把 ``expectedProductionLocks`` 一起更新），"
                + "要么它被换成了本普查认不出的形状（上面那条围栏该先红）。"
                + "**不许**靠往 ``expectedProductionLocks`` 里加一行让新构造点变绿：那张表同时是"
                + "`lockLeaks` 豁免名单的对价侧，加一行会让豁免绑定那条集合相等**当场红** —— "
                + "两条断言咬合在一起，正是要的那次停顿")
    }

    suite(
        "ClaudioGUIApp.swift 的 AudioImportEnvironment(…) 必须显式传 factoryPacksDirectory —— 否则 builtinPackIDs 生产环境恒为空集"
    ) {
        // ## 它治的病（swift-reviewer 终审 blocker，PLAN-SOUND-MANAGER.md T6 验收表实测未过）
        //
        // `factoryPacksDirectory` 有默认值 `nil`（大多数测试 fixture 不需要它，见其 doc）。但生产侧
        // **唯一**那一处构造点如果沿用默认值，`environment.builtinPackIDs` 就恒为空集
        // （``AudioImportEnvironment/builtinPackIDs`` 的实现：`factoryPacksDirectory == nil` ⇒ `[]`），
        // T6「内置包只读」唯一的判据 `environment.builtinPackIDs.contains(packID)` 对任何包永远是
        // `false` —— 用户依旧能直接拖文件覆盖『极简铃音』，这正是 T6 想根治的那个 bug 以完全相同的
        // 方式原地复发。而 `swift run claudio-gui-tests` 全绿掩盖了这一点：全部测试都走显式注入
        // `factoryPacksDirectory` 的 fixture（`AudioImportFixtures.swift`），唯独这一个生产构造点
        // 不受任何 fixture 覆盖 —— 上面那条「生产侧 `AudioImportEnvironment(…)` 构造点普查」按
        // ``expectedProductionLocks`` 逐调用点锚的是 `packsLockFile:` 一个实参，从未看过
        // `factoryPacksDirectory:`。这条补的就是那半条缺口。
        //
        // ## 为什么不塞进 ``expectedProductionLocks`` 那张表
        //
        // 那张表是**文件级单源**，同时喂三条断言（豁免绑定的集合相等 / 逐调用点包锁实参锚定 /
        // 构造点普查的期望计数）——它的字段（`value` / `literal`）与「跟着表走」的相等判定全部是
        // 为 `packsLockFile:` 一个实参设计的。硬塞第二个实参会让那三条断言的语义变得含糊（豁免的
        // 对价到底是「这把锁被钉住」还是「这两个实参都被钉住」？）。这里单开一条自成一体的 suite，
        // 只读 `ClaudioGUIApp.swift` 这一个已知的、唯一合法的构造点，不重新发明普查。
        guard let code = codeWithoutStrings("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift") else {
            expect(false, "读不到 ClaudioGUIApp.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        let calls = callArguments(of: "AudioImportEnvironment", in: code)
        expect(
            calls.count == 1,
            "ClaudioGUIApp.swift 里必须正好有 1 处 AudioImportEnvironment(…) 构造点，实得 "
                + "\(calls.count) 处 —— 0 处 = 下面的断言在守一段不存在的代码，>1 处 = 多出来的那个"
                + "需要有人看一眼再放行")
        guard let arguments = calls.first else { return }

        let expectedValue = "factoryPacksDirectory"
        let actualValue = argumentValue("factoryPacksDirectory", in: arguments)
        let actualDescription =
            actualValue
            ?? "<没有这个实参 —— 默认值 nil 会静默生效，builtinPackIDs 在真实出货的 app 里恒为空集>"
        expect(
            actualValue == expectedValue,
            "ClaudioGUIApp.swift 的 AudioImportEnvironment(…) 的 factoryPacksDirectory: 实参必须**正好"
                + "是** `\(expectedValue)`（字符串内容被清空之后的文本），实际是 `\(actualDescription)` "
                + "—— release.yml 把 minimal-chime 打进 Contents/Resources/packs/，这一处实参是唯一"
                + "把真实 app bundle 接进 T6 只读判据的线。开发态与正式 bundle 的路径"
                + "分类由这个纯函数的行为测试守住，不再在不可 import 的 composition root 里"
                + "手写 `Bundle.main.resourceURL` 判断")
        let compactCode = code.filter { !$0.isWhitespace }
        expect(
            compactCode.contains(
                "letfactoryPacksDirectory=applicationFactoryPacksDirectory("
                    + "bundleURL:Bundle.main.bundleURL)"),
            "factoryPacksDirectory 局部值必须由真实 Bundle.main.bundleURL 经可测试的"
                + " applicationFactoryPacksDirectory 分类，不得回落到 resourceURL/packs")
    }

    suite("锁转发的**编译期前提**：`mutateManifestJSON` 的 `lockFile:` 不许有默认值") {
        // ## 这条 suite 取代了什么
        //
        // 这里原本是一条「`ManifestBinding.swift` 的每一处 `lockFile:` 都必须是转发来的那把」的绊线。
        // 它的**措辞**（suite 标题与失败消息都逐字写着「每一处」「一个新增的、没人测的调用点」）比它
        // 的**覆盖范围**大了整整一个目录树：它读的是**一个硬编码文件**
        // （`codeWithoutStrings("gui/Sources/ClaudioGUICore/ManifestBinding.swift")`），而新调用点最
        // 可能的落点恰恰是**新文件** —— `gui/Package.swift` 没有 `sources:` 白名单，默认目录下任意
        // `.swift` 直接进 target，连 manifest 都不用改。实测（`/codex review 95d16a5,b89a0ee,37745f2`
        // 的 P1-B）：往 `ClaudioGUICore` 里塞一个就地算锁的第三写者，两个包 Build complete 零警告，
        // 整套 2411 条断言**一条都不红**。
        //
        // 那条判定现在住在 `SourceScannerSuite` 的 T3 内容围栏里，作为**第四条腿** —— 那台机器递归
        // 枚举 `gui/Sources`（两个 target）、按内容纳入、点开头/`UF_HIDDEN`/symlink/属性读不到全部
        // 已建模，而且是全仓唯一一条有合格递归自证的枚举。它的三个独占靶子（就地派生 / 硬编码真实
        // 路径 / 子目录）与两条极性腿（认不出的用法 / 条件编译）各配了常驻正/负控，跑遍两个
        // `pathPrefix` 向量。删这条之前逐条确认过靶子都已搬走 —— 除了下面这一个。
        //
        // ## 唯一没搬走的那个靶子，就是这条 suite
        //
        // 老绊线有一条 `!sites.isEmpty` 兜底：「一处 `lockFile:` 都找不到 ⇒ 红」。它**不能**原样搬进
        // 第四条腿 —— 那条腿的宿主 suite 里有几十个 `mutateManifestJSON()` 无实参形状的合成 fixture
        // （它们是另外三条腿的正/负控），一条 `isEmpty ⇒ 红` 会让它们集体假红，而最省事的修补
        // （「文件里已出现 `lockFile:` 才检查」）恰好把极性改回 fail-open。红队实测过这条路。
        //
        // 所以把它换成**更硬**的那一种：钉住形参**没有默认值**。这样「漏传锁」在生产上是一次
        // **编译错误**，根本到不了第四条腿；第四条腿因此可以对「取不到 `lockFile:` 标签」的调用点
        // 安心沉默，而那份沉默由这条 suite 背书 —— 两条合起来才是完整的极性，单独任何一条都不是。
        //
        // ⚠️ 为什么编译器强制**不能**给它自己背书：给形参加回一个默认值是一次**放宽**，现存调用方
        // 全都显式传着值，加完 `swift build` 零诊断（本文件与 `ManifestBinding.swift` 各记着同一句话
        // 的两个判例：`@MainActor` 与 `async`）。编译器强制的是默认值的*后果*，从不是它的*不存在*。
        guard let manifest = codeWithoutStrings("gui/Sources/ClaudioGUICore/ManifestBinding.swift")
        else {
            expect(false, "读不到 ManifestBinding.swift —— 这条 suite 唯一的价值就是读它")
            return
        }
        // 正向：形参在。它若整个消失（原语改从别处取锁），第四条腿会对每一处调用点取不到标签而
        // **静默**，整条锁转发判定退化成对空集的恒真绿 —— 那正是老绊线 `!sites.isEmpty` 守的东西。
        expect(
            collapsingWhitespace(manifest).contains("lockFile: URL"),
            "`mutateManifestJSON` 的形参表里找不到 `lockFile: URL` —— 要么读-改-写原语不再按锁参数"
                + "取锁（那 `SourceScannerSuite` 第四条腿就是在守一段不存在的代码：它逐处取 "
                + "`lockFile:` 标签，取不到就沉默，整条判定对空集恒真绿），要么扫描器读串了。"
                + "两种都必须有人看一眼再放行")
        // 负向：不许有默认值。`lockFile: URL = ClaudioPaths.packsLockFile` 会让**漏传**从编译错误
        // 变成静默生效，而 `claudio-gui-tests` 压根不编译 `ClaudioGUI`，那一手在测试进程里无人看守。
        expect(
            !collapsingWhitespace(manifest).contains("lockFile: URL ="),
            "`mutateManifestJSON` 的 `lockFile:` 形参被加上了**默认值** —— 漏传这把锁从此不再是编译"
                + "错误，而是静默落回那个默认值。包锁只有一个来源：调用方转发进来的那把；一个默认值"
                + "就是第二个来源，两个 manifest.json 写者从「同一个源」退化成「两个碰巧相等的常量」，"
                + "而 `SourceScannerSuite` 第四条腿对「没有 `lockFile:` 标签」的调用点是**沉默**的"
                + "（那份沉默正是靠这一条背书）。要加默认值，先把那条腿的极性一起改了")
    }

    suite("ClaudioGUICore 的代码里一个字都不许出现 play 的去抖锁（两套绊线中间那条缝）") {
        // 见 `guiCoreSources()` 的文档：这个 target 是 `guiSources()`（只扫 ClaudioGUI）与
        // `LockSeparationSuite`（只读 helper/）双方的盲区，而接管路径把两把锁灌进 `SetupEnvironment`
        // 的那个构造点（`OnboardingActions.swift:589-596`）就住在这里。
        let sources = guiCoreSources()
        expect(
            sources.count >= 5,
            "在 gui/Sources/ClaudioGUICore 下一个 Swift 文件都没数到（实得 \(sources.count)）—— "
                + "下面那条是**普查**，普查不到任何文件就永远等不到红，只会安静地绿下去")

        // 与 PanelView 那条同样连**值级假名**一起拦：`ClaudioPaths.root.appendingPathComponent`
        // `("play.lock")` 拿到的是同一把去抖锁，而标识符 `playLockFile` 一次都不出现。
        var debounceLockLeaks: [String: Int] = [:]
        for file in sources {
            let byIdentifier = file.code.components(separatedBy: "playLockFile").count - 1
            let byLiteral = file.code.components(separatedBy: "play.lock").count - 1
            let count = byIdentifier + byLiteral
            if count > 0 { debounceLockLeaks[file.path] = count }
        }
        expect(
            debounceLockLeaks.isEmpty,
            "ClaudioGUICore 的**代码**里出现了 playLockFile 或字面量 `play.lock`：\(debounceLockLeaks) —— "
                + "这个 target 里的每一个写者写的都是 config.json（静音、切包）或 settings.json"
                + "（接管、断开），**一个字节都不写 play.state**。让它们中的任何一个去占去抖锁，"
                + "就是在用户点下按钮之后的那几秒里，把他的每一声提示音静默吞掉 —— 而那正是他"
                + "最需要听见反馈的一刻。各生产写入 seam 的行为回归继续验证锁边界；"
                + "这一条只是把最要命的那把锁从整个 target 里赶出去")
    }

    suite("MenuBarController：Panel 关闭必须先发出隐藏信号，保证主音量冲刷") {
        guard
            let controller = codeWithoutStrings("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let close = closureBody(
                after: "private func panelDidClose(_ reason: MenuBarPanel.Dismissal)",
                in: controller)
        else {
            expect(false, "读不到 MenuBarController.panelDidClose 的关闭路径")
            return
        }
        // 任何关闭原因都必须先冲刷主音量。设置路由和外部点击各有后续处理，
        // 不能让它们的条件分支或早返绕过隐藏信号。
        expect(
            close.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("focusCoordinator.notePanelHidden()"),
            "panelDidClose 的首个操作必须是 notePanelHidden()；MasterVolumeRow 的 pending"
                + "拖动值必须在设置路由、焦点恢复或任何早返前冲刷（D22/D37）")
    }

    suite("MenuBarController 里没有 Bundle.main —— 那次查找必须留在可测的核心里") {
        guard let controller = codeOnly("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let app = codeOnly("gui/Sources/ClaudioGUI/ClaudioGUIApp.swift")
        else {
            expect(false, "读不到 MenuBarController.swift / ClaudioGUIApp.swift")
            return
        }
        expect(
            !controller.contains("Bundle.main"),
            "MenuBarController 里不该有 Bundle.main —— T17 的整个 bug 就住在那一行：把它写成"
                + " `Bundle.main.executableURL` 会解析到 Contents/MacOS/Claudio（SwiftUI app 自己），"
                + "而留在 AppKit 层的话整套测试抓不到。它必须走 `bundledHelperBinary(in:)`。")
        expect(
            app.contains("bundledHelperBinary(in: .main)"),
            "ClaudioGUIApp 必须用 ClaudioGUICore 的 bundledHelperBinary(in:) 解析 helper —— 剩下的只有"
                + "一个无分支的 `.main`，没有任何决定可以做错")
    }

    // ── D23 定稿④：面板路由的渲染层接线（红队 9cccc9c 之后，行为那半已经搬走了）─────────────
    //
    // ## 这条 suite 缩了一圈，因为它守的东西一半**不在这里了**
    //
    // 曾经这里有一整套 `functionBody("toggleMute")` 切片装置，逐条钉 `toggleMute` 函数体里的三条路由
    // （`panelRefreshRoute(` / `case .full: refresh()` / …）。那套装置存在的**全部理由**，是 `toggleMute`
    // 连同它操作的 `configState` / `eventRows` 困在 `PanelView`（`@main` executableTarget，测试 import 不
    // 进来）—— 逻辑测不到，只能退而用文本切片守「代码长什么样」。而红队 9cccc9c 实测证明：文本切片守不住
    // 「执行 / 可达性 / 翻转」（refresh 不重载 configState、某条 case 早退成死代码、静音去掉取反，三条各自
    // 改坏行为而两套测试全绿）。
    //
    // 所以 `toggleMute` / `switchPack` / `reload` / `reloadEnabledFlags` **整体搬进了**
    // `ClaudioGUICore.PanelConfigController`（一个可实例化的 `@MainActor` 类），由 `PanelConfigControllerSuite`
    // **new 它、喂真磁盘、调真方法、断言 configState/eventRows 真的变**。那三条变异现在各有一条行为断言当场
    // 逮住 —— 切片装置连同 `functionBody` 一起删了，它是为一个已经不存在的问题写的脚手架。
    //
    // 剩在 `PanelView` 里、这条 suite 还在守的，只有**渲染层接线**：顶部按 `configState` 路由、两张替换
    // 视图被引用到、按钮接到 `panelModel.toggleMute`、`.configMissing` 被滤掉、焦点只收可见行。它们是
    // `@main` View 的 body 接线，纯逻辑测试**本质上**到不了（只有 UI / 快照测试够得着，本机 CommandLineTools
    // 无 XCTest）——所以这里仍是**存在性**级文本绊线，且**如实**标注成存在性级：它证明「body 里写着这根线」，
    // 不证明「这根线运行期真的接通、接对了地方」。别把这条 suite 全绿读成「面板行为被守住了」——行为那半
    // 由 `PanelConfigControllerSuite` + `PanelRefreshRouteSuite` 守，这半只守「渲染层的线还在不在」。
    suite("PanelView：config 不可用时必须换态（渲染层接线的存在性；行为那半在 PanelConfigControllerSuite）") {
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioPanelPresentation/PanelView.swift")
        else {
            expect(false, "读不到 PanelView.swift")
            return
        }
        // ⚠️ 检查的是 **case → view 的映射**，不是裸标识符（红队 b86ec0a）。上一版写的是
        // `panel.contains("needsPackNotice")` —— 而这个标识符在它**自己的定义行**
        // `private var needsPackNotice: some View {` 里就出现了，于是把 `.needsPack` 分支体改成
        // `EmptyView()`（空态卡连同它唯一的 VoiceOver 播报被删）时，contains 仍恒真、测试全绿。
        // 收紧成 collapsed 后的 `case .needsPack: needsPackNotice` —— 它区分「定义存在」与「case 真的
        // 渲染它」。仍是 SwiftUI body 接线的存在性级（运行期接没接通到不了），但不再被自身定义满足。
        let panelCollapsed = collapsingWhitespace(panel)

        // 按钮 → handler 的那根线：静音的**行为**（翻转 + 路由 + 刷新）现在住在可测的 `PanelConfigController`
        // 里、由 `PanelConfigControllerSuite` 用真磁盘钉死。这里只剩守**最外层这根接线**：EventRowView 的
        // 静音钮真的接到 `panelModel.toggleMute`。红队 9cccc9c 实测把它剪成 `onToggleMute: {}`，五行静音钮
        // 点了毫无反应（连失败都没有）。
        //
        // ⚠️ 存在性级：证明「body 里写着这根线」，证明不了它运行期真的接通（SwiftUI body 接线，只有 UI /
        // 快照测试够得着）。挡「线被剪断」，不挡「运行期没接通」。

        // D43 的 `.configMissing` 过滤（PLAN-MASTER-VOLUME.md 阶段 D）：过滤逻辑已经搬进纯函数
        // `panelWriteFailureItems(muteError:packSwitchError:masterVolumeError:)`（`PanelWriteFailuresSuite`
        // 逐条钉死「.configMissing 被排除」），不再是 PanelView.swift 里裸露的 `error != .configMissing`
        // 字面量——这里改守**接线本身**：三个写者的错误必须全部喂给这一个合并函数，一个都不许漏
        // （漏掉 masterVolumeError，主音量的写失败就会从错误列表里悄悄消失，且这条断言此前测不到它）。
        expect(
            collapsingWhitespace(panel).contains(
                "panelWriteFailureItems( muteError: panelModel.muteError, packSwitchError:"
                    + " panelModel.packSwitchError, masterVolumeError: panelModel.masterVolumeError"
            ),
            "operationalPanel 必须把三个写者的错误全部喂给 panelWriteFailureItems(muteError:packSwitchError:"
                + "masterVolumeError:)（D3 合并列表）—— 少喂一个，那个写者的失败就从错误列表里静默消失。"
                + ".configMissing 的排除逻辑本身已经下沉进这个纯函数，由 PanelWriteFailuresSuite 钉死")
        expect(
            panelCollapsed.contains("panelWriteFailureRecoveryFiles(")
                && panelCollapsed.contains("ForEach(Array(writeFailureRecoveryFiles.enumerated())")
                && panelCollapsed.contains("onRevealConfig(current)")
                && panelCollapsed.contains("panelExistingRecoveryFileTarget(file)"),
            "每个发布冲突恢复文件须验证现存节点后通过既有 Finder 通道定位")
        expect(
            panel.contains("let visibleEvents"),
            "applyFirstFocus 必须只把**真的被渲染出来**的行送进焦点序 —— 非 .operational 态下"
                + " eventRows 仍会算出五行（走 resolvedConfig 的空包默认值），但它们一个像素都没上屏；"
                + "把它们送进开局焦点 = 焦点落在一个不存在的控件上")

        // 现状（PLAN-MASTER-VOLUME.md 阶段 D 已落地）：`MasterVolumeRow` 真的渲染在 `operationalPanel`
        // 的 `.events`（= `.operational`）分支里。`hasMasterVolume` 现在转发的是 `content.showsEventContent`
        // —— `PanelTopContent` 上一颗**单测钉过返回值**的投影（`= .events`，`PanelConfigSuite` 钉死），
        // 而不是视图里一颗未测的 `content == .events` 闭包（f54d335 P1#1 follow-up：对抗复核逮到，值级单源
        // 不够，视图里重解释的布尔翻个返回值就能让渲染 / 焦点分叉还全绿）。渲染判据与焦点判据从此在**决策层**
        // 一致：投影返回值由单测钉，视图只转发，本断言钉住这句转发原样还在。
        //
        // 历史，别再当现状读（这段注释本身在阶段 D 落地时说过一次反话，被 /codex review 逮到过 ——
        // 1fcd96f 就是修同一个病的）：341d9b7 修掉的是「`.masterVolume` 在三个边缘态
        // （`.needsPack`/`.malformed`/`.unwritable`）里指向一个不存在的滑块」；紧接着那一轮 /codex review
        // 的 P2 指出，在阶段 D 落地**之前**，从 `configState` 派生这个布尔只是把同一个 bug 从边缘态搬到最
        // 常见的 `.operational` 态，于是它一度被钉死成字面量 fail-closed 值。阶段 D 落地就是那颗钉子自己
        // 写明的退出条件。下面两条断言：正向要求转发 `content.showsEventContent`，反向禁止钉回字面量。
        expect(
            panelCollapsed.contains(
                "hasMasterVolume: content.showsEventContent && panelModel.libraryPresentationState.hasUsableSnapshot"
            ),
            "hasMasterVolume 现在必须转发 `content.showsEventContent`（`PanelTopContent` 上单测钉过返回值的投影，"
                + " = `.events`）—— 钉死字面量 false 会让 .masterVolume 在滑块真的在屏幕上时也永远抢不到焦点，"
                + "键盘 / VoiceOver 用户走 Tab 会跳过一个明明可操作的控件；换成别的投影名 = render/focus 分叉")
        expect(
            !panelCollapsed.contains("hasMasterVolume: false"),
            "hasMasterVolume 不许再钉死字面量 false —— 那是 MasterVolumeRow 落地前的占位值（341d9b7 之后"
                + "那一轮 /codex review 的临时状态），见上一条断言")

        // /codex review f54d335 P1#1（单源化 + 决策级钉法，取代 26bba37 那轮的双 switch 设计）：诚实失败卡上的
        //「在访达中显示 config.json」是一颗真控件（焦点目标 `.configReveal`），`.malformed`/`.unwritable` 开局
        // 焦点该落在它上面而不是越过它。此前**渲染判据**（operationalPanel 的 switch 分支渲染 configFailureNotice）
        // 与**焦点判据**（applyFirstFocus 派生 hasConfigFailureNotice）是**两段**独立 `switch panelModel.configState`，
        // 只靠本 suite 的文本绊线防漂移。现在链条是：configState →（`PanelConfigState.topContent` 映射）→
        // topContent →（`PanelTopContent.hasConfigFailureNotice` 投影）→ Bool，**两级都由 `PanelConfigSuite` 真行为
        // 单测钉返回值**；render 在 `.topContent` 上 switch，focus **原样转发** `content.hasConfigFailureNotice`。
        //（对抗复核实测的教训：只让两边读同一个 topContent **值**不够——视图里若再用一颗未测闭包把值重解释成
        // Bool，翻个返回值就能让失败卡照画、焦点跳过 Reveal 钮还全绿。把投影上提到单测属性、视图只转发，才把
        // 漂移堵在决策层。）所以本块只钉视图层无法被 import 单测的那几件**转发 / 接线**事实：① render switch 在
        // `.topContent`；② focus 的 `content` 绑的就是这个单源；③ focus 原样转发 `content.hasConfigFailureNotice`
        //（不是本地重解释、不是钉字面量）；④ 视图接线半：Reveal 按钮带 `.focused(... .configReveal)`。
        expect(
            panelCollapsed.contains("switch panelModel.configState.topContent"),
            "operationalPanel 顶部必须 switch 在 `panelModel.configState.topContent` 上 —— 直接 switch 裸 configState "
                + "会复活「渲染判据 / 焦点判据两段独立 switch」的漂移隐患（/codex review f54d335 P1#1 抽掉的正是它）")
        expect(
            panelCollapsed.contains("let content = panelModel.configState.topContent"),
            "applyFirstFocus 必须把 `content` 绑到单源 `panelModel.configState.topContent` 上 —— 焦点判据从此和"
                + "渲染判据同源，不是各自 switch 一遍 configState")
        expect(
            panelCollapsed.contains("hasConfigFailureNotice: content.hasConfigFailureNotice"),
            "applyFirstFocus 必须**原样转发** `content.hasConfigFailureNotice`（`PanelTopContent` 上单测钉过返回值的"
                + "投影）进 panelFocusOrder/panelFirstFocusTarget 的 scope —— 换成视图里本地重解释（`if case .configFailure = content { … }`）那颗"
                + "闭包的返回值没测过，翻成 false 就让失败卡照画、`.configReveal` 被踢出焦点序还全绿（f54d335 P1#1 "
                + "follow-up 对抗复核逮到的洞）；钉死字面量 / 换投影名同样让 render/focus 分叉")
        expect(
            !panelCollapsed.contains("hasConfigFailureNotice: false"),
            "hasConfigFailureNotice 不许钉死字面量 false —— 那会让失败卡上的真控件永远抢不到开局焦点")
        // 视图接线半（此前完全没人钉，/codex review f54d335 P1#2 逮到）：把 `focusedTarget = .configReveal`
        // 真正接到那颗控件的，是 configFailureNotice 里 Reveal 按钮上的 `.focused($focusedTarget, equals:
        // .configReveal)`。删掉那一行，上面几条 + 纯 `PanelFocusOrderSuite` 仍会全绿，而 `.configReveal` 又变回
        // 一个没有视图认领的悬空焦点位（`panelFocusOrder` 仍把它排进焦点序，PanelFocusOrder.swift:146）——
        // 正是 cc59d52 删 `.dropZone`、26bba37 → 本分支要根除的那个形状。
        // ⚠️ 存在性级绊线（同本文件头部自陈 + 下面 `.disconnect` 同款）：它只证明那一行**还在**，证不了它接在
        // **对的**视图上（把这个修饰符原样挪到隐藏 / 别的兄弟视图照样绿——那只有 ViewInspector / XCTest 挡得住，
        // 本机 CommandLineTools 没有）。它切实挡的是「顺手删掉 / 注释掉 / 改错 case」这一类，恰是本 bug 的复发形状。
        expect(
            panelCollapsed.contains(".focused($focusedTarget, equals: .configReveal)"),
            "configFailureNotice 的「在访达中显示 config.json」按钮必须带 `.focused($focusedTarget, equals: "
                + ".configReveal)` 把开局焦点接到自己身上 —— 删掉它，`.malformed`/`.unwritable` 开局焦点落到一个"
                + "没有视图认领的 .configReveal（panelFocusOrder 仍排它进序），Reveal 钮永远抢不到键盘 / VoiceOver 焦点")

        guard
            let focusModel = codeWithoutStrings(
                "gui/Sources/ClaudioGUICore/PanelFocusOrder.swift")
        else {
            expect(false, "读不到 PanelFocusOrder.swift")
            return
        }
        let focusCollapsed = collapsingWhitespace(focusModel)
        expect(
            panelCollapsed.contains("focused($focusedTarget, equals: .headerSettings)")
                && panelCollapsed.contains("onOpenSettings"),
            "Panel 设置入口必须进入 retained Settings，并把焦点 owner 留在 headerSettings")
        expect(
            !panelCollapsed.contains("openSoundSettings")
                && !panelCollapsed.contains("resetSelectedSurfaceOverrides()")
                && !panelCollapsed.contains("resetSurface"),
            "当前 Panel 不得重新承载 Events/Sounds 的窗口级编辑或 Surface reset 写路径")
        expect(
            focusCollapsed.contains(
                "var order: [PanelFocusTarget] = [.headerSettings, .recentNotices, .soundScope]")
                && !focusCollapsed.contains("order.append(.activityRange)")
                && focusCollapsed.contains("order.append(.quitApplication)"),
            "当前 Panel 焦点模型不为静态活动摘要添加交互焦点")
        expect(
            !panelCollapsed.contains("PanelPackSectionView(")
                && !panelCollapsed.contains("manageSoundsRow")
                && !focusCollapsed.contains("order.append(.manageSounds)")
                && !focusCollapsed.contains("order.append(contentsOf: packCardIDs"),
            "旧包画廊、管理声音包行及其焦点路径必须从生产面板撤下")
        expect(
            panelCollapsed.contains("activityPresentation")
                && panelCollapsed.contains("selectedScope.name")
                && panelCollapsed.contains(".panelEventsMappable"),
            "Panel 必须从共享活动投影与当前声音作用域生成事件区摘要")
    }

    // ── PLAN-MASTER-VOLUME.md 阶段 D：MasterVolumeRow 的三个硬约束 + 三条接线绊线 ──────────────
    //
    // `MasterVolumeRow.swift` 是 SwiftUI body 接线，纯逻辑测试到不了（本机 CommandLineTools 无
    // XCTest）—— 与本文件其余每一条同一个理由（见文件头部）。「全 GUI 只许一处 NSAccessibility.post /
    // announcer.consume(」已经由上面「T17h 播报出口」那条 suite 覆盖（它数的是整个 `guiSources()`，
    // MasterVolumeRow.swift 自然落进普查范围），这里不重复；这里守的是这个文件**自己**独有的三个
    // 已实证的坑（D5/D10 已作废、D18）+ 三条本步新增的接线（D21 的 rebase、D22/D37 的 popover 冲刷、
    // D22-bis 的 willTerminate 冲刷）。
    suite("MasterVolumeRow：三个已作废/已实证的坑不许出现（step: / onDisappear / 任何动画入口）") {
        // 读 codeWithoutStrings：负向断言（「不许出现 X」）若读保留字符串内容的 codeOnly，任何一句
        // 恰好把 X 写进错误消息的代码都会让它**假红**；更要命的是正向那半（下面 closureBody 那几条）
        // 会被同一份字符串**假绿**。统一读这一路。
        guard
            let row = codeWithoutStrings(
                "gui/Sources/ClaudioPanelPresentation/MasterVolumeRow.swift"),
            let shared = codeWithoutStrings(
                "gui/Sources/ClaudioGUIComponents/SharedMasterVolumeSlider.swift")
        else {
            expect(false, "读不到 MasterVolumeRow/SharedMasterVolumeSlider.swift")
            return
        }
        let sliderSources = row + shared
        expect(
            !sliderSources.contains("step:"),
            "MasterVolumeRow 不许使用 Slider(…, step:)（D24）—— 本机 key 窗口截图实证：`step: 0.05` 会被"
                + "直译成 NSSlider.numberOfTickMarks = 21，在轨道下方画出一条 21 个灰点的刻度带，撑破"
                + "DESIGN.md「控件行」的 ~28pt 行高。档位吸附交给 VolumeDragSession.snap()，视图侧只转发")
        expect(
            !row.contains("onDisappear"),
            "MasterVolumeRow 不许用 onDisappear 冲刷（D10 已作废，全仓零命中且本仓库已明文否定该回调—— "
                + "PanelFocusCoordinator.swift 的文档：popover 不保证在每次 show/close 之间重建视图层级）。"
                + "冲刷信号走 focusCoordinator.hideCount")
        // 动画有**两个**入口，这条绊线上一版只堵了一个。
        //
        // `.animation(` 是修饰符那一路；`withAnimation { … }` 是命令式那一路，它照样能给这一行接上
        // 隐式动画，而 `!contains(".animation(")` 对它完全看不见。实测变异体
        // `.opacity(withAnimation(.easeInOut) { 1.0 })` 注入 MasterVolumeRow —— 1973 checks 全绿
        // （`/codex review 8771946`）。措辞（「全行零动画」）比覆盖范围（「零 `.animation(`」）大了
        // 一整个入口，与本文件 `sourcesUnder(_:)` 的 T17h 是同一种病。
        //
        // 围栏，不是白名单：认不出的动画入口只会更多（`.transaction {}`、`Animation` 值本身），所以
        // 判据是「这两个入口一个都不许在」，任何一个命中即红。
        for entry in [".animation(", "withAnimation"] {
            expect(
                !sliderSources.contains(entry),
                "MasterVolumeRow 全行零动画（D18）—— 命中了 `\(entry)`。拖动跟手不加动画、失败回滚一律"
                    + "瞬跳；给控件行加动画 = 必须同批接上 accessibilityReduceMotion 门控，代价远大于收益"
                    + "（PanelView.swift 顶部那条「本视图树的动画绊线」记录着同一条纪律）")
        }
    }

    // 实际 SwiftUI 生命周期与输入接线由 MountedVolumeLifecycleSuite 挂载生产 Panel 验证。
    suite("MasterVolumeRow：popover 隐藏必须冲刷（D22/D37，复用既有 hideCount 信号，不新增 closeCount）") {
        guard
            let wrapper = codeWithoutStrings(
                "gui/Sources/ClaudioPanelPresentation/MasterVolumeRow.swift"),
            let row = codeWithoutStrings(
                "gui/Sources/ClaudioGUIComponents/SharedMasterVolumeSlider.swift")
        else {
            expect(false, "读不到 MasterVolumeRow/SharedMasterVolumeSlider.swift")
            return
        }
        let flat = collapsingWhitespace(row)
        expect(
            !flat.contains("closeCount") && !wrapper.contains("closeCount"),
            "不许新增 closeCount —— PanelFocusCoordinator 今天已经有 hideCount 且 "
                + "MenuBarController.panelDidClose 的第一条语句已经是 notePanelHidden()（T17d），语义"
                + "与这里要的冲刷信号完全一致，复用它")
    }

    // MARK: - PLAN-SOUND-MANAGER.md T2：按钮试听由可导入的生产 Panel 挂载 suite 检验；
    // 这里只守旧编辑器与声音包窗口之间仍无可编译接线边界的跨文件契约。

    suite("声音包窗口：清除绑定只走窗口；面板恢复携带精确包与事件路由") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let window = codeOnly("gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 PanelView 或 SoundPacksWindowView")
            return
        }
        expect(
            panel.contains("PanelAgentEventRow(")
                && !panel.contains("EventRowView(")
                && !panel.contains("onOpenEditor:")
                && !panel.contains("clearEventBinding(")
                && panel.contains("onConfigureSound(")
                && panel.contains("packID: panelModel.config.selectedPack"),
            "面板只提交当前包与事件的设置路由，不在行内写包映射")
        expect(
            window.contains("Button(l10n.text(.soundPacksClearBinding), role: .destructive)")
                && window.contains("invoke(row.clearAction)")
                && !window.contains("model."),
            "窗口必须把 owner 签发的 clear capability 回送唯一 interface，不得旁路调用 raw model")
    }

    suite("生产面板事件行：旧版绑定详情来自共享矩阵并进入可见文案与 VoiceOver") {
        guard
            let panel = codeWithoutStrings(
                "gui/Sources/ClaudioPanelPresentation/PanelView.swift")
        else {
            expect(false, "读不到生产 PanelView.swift")
            return
        }
        let flat = collapsingWhitespace(panel)
        guard
            let eventSection = closureBody(after: "private var eventSection: some View", in: flat),
            let rowBody = closureBody(after: "private struct PanelAgentEventRow: View", in: flat),
            let identity = closureBody(after: "private var identity: some View", in: rowBody),
            let accessibility = closureBody(
                after: "private var identityAccessibilityLabel: String", in: rowBody)
        else {
            expect(false, "切不出生产事件区、事件行或身份无障碍文案")
            return
        }
        expect(
            eventSection.contains("localizedPanelEventHostIndicators(")
                && eventSection.contains("event: event.event, content: hostIntegrations.content")
                && eventSection.contains("hostIndicators:")
                && rowBody.contains("let hostIndicators: [EventHostIndicatorPresentation]"),
            "生产事件区必须用当前面板适用的绑定详情投影，交给实际挂载的 PanelAgentEventRow")
        expect(
            identity.contains("Text(presentation.title)")
                && !identity.contains("presentation.nativeEventText")
                && !identity.contains("presentation.soundFileText")
                && accessibility.contains("presentation.title")
                && !accessibility.contains("hostBindingDetails.map"),
            "正常事件行及 VoiceOver 身份只显示用户名称，异常原因保持独立可见")
    }

    suite("生产面板事件行：复用批准的 24pt 双波纹静音图标，不回退 SF Symbols") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let icon = codeOnly("gui/Sources/ClaudioGUIComponents/EventMuteSpeakerIcon.swift")
        else {
            expect(false, "读不到生产面板、旧事件行或共享静音图标组件")
            return
        }
        expect(
            panel.contains("EventMuteSpeakerIcon("),
            "生产事件行必须复用批准组件")
        expect(
            !panel.contains("speaker.wave.2.fill")
                && !panel.contains("speaker.slash.fill"),
            "生产面板静音按钮不得回退为 SF Symbols")
        expect(
            icon.contains("struct EventMuteSpeakerIcon: View")
                && icon.components(separatedBy: "SpeakerWaveShape(").count - 1 == 2
                && icon.contains("color.opacity(isMuted ? 0.24 : 1)")
                && icon.contains("SpeakerSlashShape()")
                && icon.contains(".frame(width: 24, height: 24)"),
            "共享组件必须保留 24×24、双声波、静音弱化与斜线几何")
    }

    suite("全状态画廊：声音包窗口用生产视图覆盖复杂库与失败态，且预览不读用户磁盘") {
        guard
            let gallery = codeOnly(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowStateGalleryView.swift"),
            let rootGallery = codeOnly("gui/Sources/ClaudioGUI/StateGalleryView.swift")
        else {
            expect(false, "读不到声音包窗口画廊或根画廊接线")
            return
        }
        expect(
            gallery.contains("SoundPacksWindowView(")
                && gallery.contains("builtinOwner")
                && gallery.contains("customOwner")
                && gallery.contains("emptyOwner")
                && gallery.contains("libraryState: .refreshing")
                && gallery.contains("libraryState: .refreshFailed")
                && gallery.contains("loadingOwner")
                && gallery.contains("loadFailedOwner")
                && gallery.contains("largeLibraryOwner")
                && gallery.contains("brokenPackOwner")
                && gallery.contains("writingOwner")
                && gallery.contains("startsBusy: true")
                && gallery.contains("restoreFailureStatus")
                && gallery.contains("deletionFailureStatus")
                && gallery.components(separatedBy: "galleryFrame(").count - 1 == 12,
            "声音包画廊必须通过生产 owner/view 渲染 100-pack、broken、busy、恢复/删除失败及 SWR 状态")
        expect(
            rootGallery.contains("SoundPacksWindowStateGalleryView(language: language)"),
            "全产品根画廊必须实际挂入声音包窗口画廊")
        expect(
            gallery.contains("@StateObject private var owner")
                && gallery.contains("SoundPacksEditorOwner.stateGalleryFixture(")
                && gallery.contains(
                    "makeOwner: @escaping @MainActor () -> SoundPacksEditorOwner")
                && gallery.contains(#"id: "\(id)-default""#)
                && gallery.contains(#"id: "\(id)-minimum""#)
                && gallery.contains("_owner = StateObject(wrappedValue: makeOwner())")
                && gallery.contains("UUID().uuidString")
                && !gallery.contains("/dev/null")
                && !gallery.contains("~/.claudio"),
            "画廊每个尺寸必须在独立 StateObject autoclosure 内预建 owner，并使用唯一 temp root 做零用户盘 I/O fixture")
    }

    suite("三界面无障碍护栏：每个交互构造都有显式非空 Name 与稳定 identifier") {
        let paths = [
            "gui/Sources/ClaudioPanelPresentation/PanelView.swift",
            "gui/Sources/ClaudioPanelPresentation/PanelQuitFooter.swift",
            "gui/Sources/ClaudioPanelPresentation/PackGalleryView.swift",
            "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift",
        ]
        let interactivePattern = try! NSRegularExpression(
            pattern: #"\b(?:Button|Menu|Picker|List)\s*(?:\(|\{)"#)
        let labelPattern = try! NSRegularExpression(pattern: #"\.accessibilityLabel\s*\("#)
        let identifierPattern = try! NSRegularExpression(
            pattern: #"\.accessibilityIdentifier\s*\("#)

        for path in paths {
            guard let source = codeOnly(path) else {
                expect(false, "读不到无障碍受控界面：\(path)")
                continue
            }
            let range = NSRange(source.startIndex..., in: source)
            let controls = interactivePattern.numberOfMatches(
                in: source, options: [], range: range)
            let labels = labelPattern.numberOfMatches(in: source, options: [], range: range)
            let identifiers = identifierPattern.numberOfMatches(
                in: source, options: [], range: range)
            expect(
                labels >= controls,
                "\(path) 的交互构造必须逐个有显式 accessibilityLabel；控件 \(controls)，label \(labels)")
            expect(
                identifiers >= controls,
                "\(path) 的交互构造必须逐个有稳定 accessibilityIdentifier；控件 \(controls)，identifier \(identifiers)"
            )
            expect(
                !source.contains(".accessibilityLabel(\"\")")
                    && !source.contains(".accessibilityIdentifier(\"\")"),
                "\(path) 不得用空 Name 或空 identifier 蒙混过关")
        }

        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let scopePicker = codeOnly(
                "gui/Sources/ClaudioPanelPresentation/PanelSoundScopePicker.swift"),
            let integrations = codeOnly(
                "gui/Sources/ClaudioSettingsPresentation/IntegrationsSettingsDestinationView.swift"),
            let packs = codeOnly(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到三界面的关键 AX identifier")
            return
        }
        for identifier in [
            "panel.reveal-config",
            #"panel.event.\(presentation.event.rawValue).row"#,
            #"panel.event.\(presentation.event.rawValue).preview"#,
            #"panel.event.\(presentation.event.rawValue).mute"#,
        ] {
            expect(panel.contains(identifier), "主面板缺少稳定 AX identifier：\(identifier)")
        }
        for identifier in [
            "panel.sound-scope",
            #"panel.sound-scope.item.\(scope.scope.storedValue)"#,
        ] {
            expect(
                scopePicker.contains(identifier),
                "声音作用域选择器缺少稳定 AX identifier：\(identifier)")
        }
        for identifier in [
            "integrations.destination.scroll", "integrations.destination.agent-list",
            #"integrations.destination.agent.\(agent.host.rawValue)"#,
            #"integrations.destination.toggle.\(agent.host.rawValue)"#,
            "integrations.destination.connection-group",
            #"integrations.destination.row.\(row.kind.rawValue)"#,
            "integrations.destination.feedback.toast",
            "integrations.destination.feedback.dismiss",
        ] {
            expect(
                integrations.contains(identifier), "集成 destination 缺少稳定 AX identifier：\(identifier)"
            )
        }
        for identifier in [
            "sound-packs.pack-list",
            "sound-packs.restore-selected-factory-pack", "sound-packs.fork-selected-pack",
            "sound-packs.add-audio", "sound-packs.use-selected-pack",
            #"sound-packs.event.\(row.event.rawValue).mapping"#,
            #"sound-packs.event.\(row.event.rawValue).preview"#,
        ] {
            expect(packs.contains(identifier), "声音包窗口缺少稳定 AX identifier：\(identifier)")
        }
    }

    suite("Panel 固定退出入口：required onQuit 无默认值；实际 geometry/action 由挂载回归保护") {
        guard let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift") else {
            expect(false, "读不到 PanelView 的 required onQuit interface")
            return
        }
        let flatPanel = collapsingWhitespace(panel)
        expect(panel.contains("VStack(spacing: 0)"), "PanelView 根布局必须是零间距 VStack")
        guard
            let layout = codeWithoutStrings("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let body = closureBody(after: "public var body: some View", in: layout)
        else {
            expect(false, "必须能切出 PanelView 根布局，才能保护 footer 的条件容器限制")
            return
        }
        expect(
            braceDepth(of: "ScrollView(.vertical, showsIndicators: true)", in: body) != nil
                && braceDepth(of: "ScrollView(.vertical, showsIndicators: true)", in: body)
                    == braceDepth(of: "PanelQuitFooter(", in: body),
            "footer 与 ScrollView 必须处于同一层级；所有非运行态的等价挂载证据未齐，保留此护栏")
        expect(
            flatPanel.contains("private let onQuit: @MainActor () -> Void")
                && flatPanel.contains("onQuit: @escaping @MainActor () -> Void,")
                && !flatPanel.contains("onQuit: @escaping @MainActor () -> Void ="),
            "退出意图必须由调用者显式注入，不能新增默认生命周期来源")
    }

    suite("退出生命周期：SwiftUI 只发意图，唯一 composition root 正常 terminate 且不预关闭") {
        guard
            let menu = codeWithoutStrings("gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let footer = codeWithoutStrings(
                "gui/Sources/ClaudioPanelPresentation/PanelQuitFooter.swift"),
            let quitBody = closureBody(after: "onQuit:", in: menu)
        else {
            expect(false, "读不到退出接线或无法切出 onQuit 闭包")
            return
        }
        expect(
            collapsingWhitespace(quitBody) == "NSApp.terminate(nil)",
            "composition root 的退出闭包必须且只能调用 NSApp.terminate(nil)，实际：\(quitBody)")
        for forbidden in [
            "panelWindow.close()", "performClose", "notePanelHidden()", "exit(", "_exit(", "abort(",
            "killall",
        ] {
            expect(
                !quitBody.contains(forbidden),
                "退出闭包不得预关闭面板或直接杀进程，命中：\(forbidden)")
            expect(
                !footer.contains(forbidden),
                "SwiftUI footer 不得接管应用生命周期，命中：\(forbidden)")
        }
    }

    suite("退出按钮 AX 与焦点：精确 label/hint/id、图标隐藏，quit 明确不是事件焦点") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let footer = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelQuitFooter.swift")
        else {
            expect(false, "读不到 PanelView/PanelQuitFooter")
            return
        }
        let flatFooter = collapsingWhitespace(footer)
        expect(
            flatFooter.contains(".focused(focusedTarget, equals: .quitApplication)")
                && footer.contains(".accessibilityHint(l10n.text(.panelQuitApplicationHint))")
                && footer.contains(".help(l10n.text(.panelQuitApplicationHint))"),
            "退出按钮的末位焦点与独立 hint/help 入口仍保留；AX 名称、Help 与身份由挂载读回保护")
        expect(
            flatFooter.contains("Image(systemName: \"power\") .accessibilityHidden(true)"),
            "power 图标必须从 AX 树隐藏，避免 VoiceOver 重复朗读")
        expect(
            collapsingWhitespace(panel).contains(
                "case .eventPreview, .eventMute: true default: false"),
            "PanelView.isEventFocusTarget 必须明确把 quitApplication 归为 false")
    }

    suite("State Gallery：直接复用生产 PanelQuitFooter，覆盖双语固定紧凑布局") {
        guard let gallery = codeOnly("gui/Sources/ClaudioGUI/StateGalleryView.swift") else {
            expect(false, "读不到 StateGalleryView")
            return
        }
        let flat = collapsingWhitespace(gallery)
        expect(
            gallery.contains("PanelQuitFooter(")
                && gallery.contains("ForEach(ClaudioAppLanguage.allCases)")
                && gallery.contains("ForEach([ClaudioCompactPreviewDensity.standard])"),
            "State Gallery 必须直接渲染生产 footer 的双语固定紧凑组合")
        expect(
            flat.contains("frame(width: CGFloat(standardPanelWidth))")
                && gallery.contains("onQuit: {}")
                && !flat.contains("typeScale: CGFloat(density.scale)"),
            "gallery 宽度必须来自固定 Panel 真相源，且退出闭包必须无副作用")
    }

    suite("State Gallery：生产 Agent 面板覆盖双语固定紧凑布局与六个关键状态") {
        guard let gallery = codeOnly("gui/Sources/ClaudioGUI/StateGalleryView.swift") else {
            expect(false, "读不到 StateGalleryView")
            return
        }
        for required in [
            "ProductionPanelGalleryView()",
            "ForEach(ClaudioAppLanguage.allCases)",
            "ForEach([ClaudioCompactPreviewDensity.standard])",
            "ForEach(ProductionPanelGalleryScenario.allCases)",
            "previewPanelModel:",
            "PreviewFixtures.workBuddyVisualScenarios",
            ".allImplementedBindingsCurrent",
            ".awaitingActivation",
            "previewSoundScopeExpanded: soundScopeExpanded",
        ] {
            expect(gallery.contains(required), "生产 Panel 画廊缺少 wiring：\(required)")
        }
        for scenario in [
            "case workBuddy", "case workBuddyAwaitingExpanded", "case needsPack",
            "case configFailure", "case libraryFailure", "case surfaceFailure",
        ] {
            expect(gallery.contains(scenario), "生产 Panel 画廊缺少关键状态：\(scenario)")
        }
        expect(
            gallery.contains(".preferredColorScheme(.light)")
                && gallery.contains(".preferredColorScheme(.dark)"),
            "State Gallery 必须保留浅色与深色两个生产渲染入口")
    }

    suite("生产 Panel 固定紧凑布局，Settings 不再挂载 Display") {
        guard
            let panel = codeOnly("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let settings = codeOnly(
                "gui/Sources/ClaudioSettingsPresentation/SettingsRootView.swift"),
            let preferences = codeOnly("gui/Sources/ClaudioGUICore/SettingsPreferences.swift")
        else {
            expect(false, "读不到 Panel、Settings 或 Preferences 源码")
            return
        }
        let flatPanel = collapsingWhitespace(panel)
        expect(
            panel.contains("standardPanelWidth")
                && !panel.contains("interfaceTextSize")
                && !panel.contains("panelWidthPreference")
                && !panel.contains("dynamicTypeSize"),
            "Panel 必须固定使用紧凑宽度，不再读取字号或宽度偏好")
        expect(
            !settings.contains("settings.display.status-dot")
                && !settings.contains("displaySettings")
                && !settings.contains("interfaceTextSize")
                && !settings.contains("panelWidthPreference"),
            "Settings root 不得保留 Display 页面或旧字号、宽度偏好")
        expect(
            !preferences.contains("interfaceTextSize")
                && !preferences.contains("panelWidthPreference")
                && !preferences.contains("setInterfaceTextSize")
                && !preferences.contains("setPanelWidthPreference"),
            "Preferences owner 不得保留旧字号或宽度写路径")
        expect(
            flatPanel.contains(".focused($focusedTarget, equals: .headerSettings)"),
            "设置入口的焦点归还接线仍保留；实际 AX 身份与动作由挂载回归保护")
    }

    suite("PanelView：设置入口进入保留的统一 Settings session") {
        guard let panel = codeWithoutStrings("gui/Sources/ClaudioPanelPresentation/PanelView.swift")
        else {
            expect(false, "读不到 PanelView.swift")
            return
        }
        expect(
            collapsingWhitespace(panel).contains(
                ".focused($focusedTarget, equals: .headerSettings)"),
            "设置入口的焦点归还接线仍保留；实际 AX 身份与动作由挂载回归保护")
    }

    suite("声音包窗口：完整映射菜单列出已有音频并经窗口 model 绑定；面板不消费 inventory") {
        guard
            let panel = codeWithoutStrings("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let window = codeOnly("gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到面板或声音包窗口源码")
            return
        }
        expect(
            window.contains("ForEach(inventoryFiles)")
                && window.contains("file.isOrphan")
                && window.contains("invoke(")
                && window.contains("file.assignments.first(where:"),
            "窗口映射菜单必须列出 owner inventory、标识孤儿并回送签发的 assign capability")
        expect(
            window.contains("if inventoryIsLoading")
                && window.contains("case .loading = activeSounds.inventory")
                && window.contains("ProgressView()")
                && window.contains("l10n.text(.soundPacksAudioLoading)"),
            "按需清单未完成时必须显示真 loading，不能把临时空数组说成空包")
        expect(
            !panel.contains("selectedPackAudioFiles"),
            "主面板事件行不得继续消费映射 inventory")
    }

    suite("声音包窗口：提示音卡片与映射控件使用统一全宽列，文件名不再推动试听按钮") {
        guard
            let source = codeWithoutStrings(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 SoundPacksWindowView.swift")
            return
        }
        let flat = collapsingWhitespace(source)
        guard
            let rowBody = closureBody(after: "private func eventMappingRow", in: flat),
            let controlsBody = closureBody(after: "private func eventControls", in: flat),
            let audioControlBody = closureBody(after: "private func eventAudioControl", in: flat)
        else {
            expect(false, "必须能切出事件卡片、控件行与音频选择控件")
            return
        }
        let fullWidthLeadingFrame = ".frame(maxWidth: .infinity, alignment: .leading)"
        expect(
            rowBody.contains(
                ".frame( maxWidth: .infinity, minHeight: SettingsAppearance.controlRowHeight, alignment: .leading ) .background"
            ),
            "每张提示音卡片必须在绘制背景与描边前撑满详情列，不能随文件名产生不同外框宽度")
        expect(
            controlsBody.contains(
                "eventAudioControl(row) " + fullWidthLeadingFrame)
                && controlsBody.contains(
                    ".fixedSize(horizontal: true, vertical: false) .frame(minHeight:")
                && controlsBody.contains(fullWidthLeadingFrame),
            "音频选择框必须消费剩余宽度，试听按钮保持固有宽度，整行才能共享同一右侧基线")
        expect(
            audioControlBody.contains(
                ".lineLimit(1) .fixedSize(horizontal: false, vertical: true) "
                    + fullWidthLeadingFrame)
                && audioControlBody.contains(
                    "} .nativeMenuControl() " + fullWidthLeadingFrame + " .frame(minHeight:"),
            "映射菜单的标签与菜单表面都必须全宽，长短文件名不能改变可见控件宽度")
    }

    suite("T11：管理窗口孤儿行的删除是显式永久确认，分配与删除都接到窗口 model") {
        guard
            let view = codeOnly(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 SoundPacksWindowView.swift")
            return
        }
        let flat = collapsingWhitespace(view)
        expect(
            flat.contains("inventoryFiles.filter(\\.isOrphan)")
                && flat.contains("l10n.format(.soundPacksOrphanUnused, file.fileName)"),
            "窗口必须只把未引用项列进孤儿区，并逐字点名文件")
        expect(
            flat.contains("ForEach(file.assignments)")
                && flat.contains("invoke(assignment.action)"),
            "孤儿分配菜单必须回送 owner 签发的 T3 bind capability")
        expect(
            flat.contains(".accessibilityElement(children: .contain)"),
            "事件行必须保留 Menu/试听的 VoiceOver 子节点；内置只读行也有真实试听控件")
        expect(
            flat.contains(".confirmationDialog(")
                && flat.contains("Button(l10n.text(.soundPacksDeleteButton), role: .destructive)")
                && flat.contains("l10n.format(.soundPacksDeleteMessage"),
            "删除必须是 destructive confirmation，并明确告知不可撤销")
        expect(
            flat.contains("invoke(confirmation.confirmAction)")
                && flat.contains("confirmation.kind == .deleteOrphan")
                && !flat.contains("deleteSelectedOrphanAudioFileAfterConfirmation("),
            "只有 owner confirmation 签发的 destructive capability 才能触发永久删除")
        guard
            let contentView = closureBody(
                after: "private struct SoundPacksWindowContentView: View", in: flat),
            let rootBody = closureBody(after: "var body: some View", in: contentView),
            let scrollBody = closureBody(after: "ScrollView(.vertical", in: rootBody),
            let statusRegionAt = scrollBody.range(of: "activeSounds.windowStatuses")?.lowerBound,
            let detailAt = scrollBody.range(of: "detailContent")?.lowerBound
        else {
            expect(false, "必须挂载共享 ScrollView、统一窗口状态及详情内容")
            return
        }
        expect(
            statusRegionAt < detailAt,
            "音频错误必须在详情条件之外：唯一包被外部移走时仍显示失败和恢复入口")
    }

    suite("T10：CoverageTrack 的 present 接事件色、missing 接 text-2，且真实行底是糖果盘 surface") {
        // ContrastSuite 的四对数学断言只能证明「这些 hex 配在一起能过 ≥3:1」，看不见不可 import 的
        // ClaudioGUI 视图到底用了哪一个 token。少了这半，把 present 改成 hairline-strong，或把
        // missing 改回 muted `#6F665B`（暗色对 surface-2 只有 2.77:1）时，那四条都会继续全绿
        // ——断言措辞就比覆盖范围大。
        guard
            let source = codeWithoutStrings(
                "gui/Sources/ClaudioPanelPresentation/PackGalleryView.swift"),
            let packCardBody = closureBody(after: "private struct PackCardView: View", in: source),
            let coverageTrackBody = closureBody(
                after: "private struct CoverageTrack: View", in: source),
            let coverageBody = closureBody(after: "var body: some View", in: coverageTrackBody),
            let slotBody = closureBody(
                after: "private func slot(isPresent: Bool, color: Color) -> some View",
                in: coverageTrackBody),
            let presentBody = closureBody(after: "if isPresent", in: slotBody)
        else {
            expect(
                false,
                "读不到 PackGalleryView.swift，或切不出 PackCardView / CoverageTrack.body / "
                    + "CoverageTrack.slot 的 present 分支 —— "
                    + "T10 接线无从判起")
            return
        }
        let flatCoverage = collapsingWhitespace(coverageBody)
        let flatSlot = collapsingWhitespace(slotBody)
        let flatPresent = collapsingWhitespace(presentBody)
        expect(
            whitespaceTolerantHitCount(
                of: "slot( isPresent: presentEvents.contains(event), "
                    + "color: ClaudioTheme.event(event, colorScheme))",
                in: coverageBody) == 1,
            "CoverageTrack.body 必须把每个 event 的 ClaudioColor.event(...) 作为 color 参数传给"
                + " slot；否则 ContrastSuite 量到的事件色没有进入真实胶囊。body 实际是："
                + "\(flatCoverage)")
        expect(
            whitespaceTolerantHitCount(of: ".fill(color)", in: presentBody) == 1,
            "CoverageTrack present 分支必须用传入的事件色 .fill(color)；改成 hairline-strong 等"
                + "其它 token 会让静态对比度断言继续假绿。present 分支实际是：\(flatPresent)")
        expect(
            whitespaceTolerantHitCount(
                of: ".strokeBorder(ClaudioTheme.secondaryText(colorScheme), lineWidth: 1)",
                in: slotBody) == 1,
            "CoverageTrack missing 的空槽描边必须接 text-2；改回 muted 会让暗色掉到 2.77:1。"
                + "slot 实际是：\(flatSlot)")
        expect(
            whitespaceTolerantHitCount(
                of: ".stroke(ClaudioTheme.secondaryText(colorScheme), lineWidth: 1)",
                in: slotBody) == 1,
            "CoverageTrack missing 的斜杠必须与空槽同接 text-2；只修描边、不修斜杠仍是半个违规。"
                + "slot 实际是：\(flatSlot)")
        expect(
            whitespaceTolerantHitCount(
                of: ".fill(ClaudioTheme.surface(colorScheme))",
                in: packCardBody) == 1,
            "ContrastSuite 量的是覆盖轨对糖果盘 surface；PackCardView 的真实行底若换了 token，必须同步"
                + "重做四对数学断言，不能让旧底的绿灯冒充真实渲染路径")
    }

    suite("声音包窗口剩余动作：共享 picker/player、底部动作栏、异步身份与统一公告均接到生产视图") {
        let componentsPicker =
            "gui/Sources/ClaudioGUIComponents/AudioOpenPanel.swift"
        let componentsPlayer =
            "gui/Sources/ClaudioGUIComponents/AudioPreviewPlayer.swift"
        let oldPicker = repoRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/AudioOpenPanel.swift")
        let oldPlayer = repoRoot().appendingPathComponent(
            "gui/Sources/ClaudioGUI/AudioPreviewPlayer.swift")
        expect(
            !FileManager.default.fileExists(atPath: oldPicker.path)
                && !FileManager.default.fileExists(atPath: oldPlayer.path),
            "picker/player 已下沉 ClaudioGUIComponents；ClaudioGUI 下不许残留第二份实现")
        guard
            let picker = codeWithoutStrings(componentsPicker),
            let player = codeWithoutStrings(componentsPlayer),
            let panel = codeWithoutStrings("gui/Sources/ClaudioPanelPresentation/PanelView.swift"),
            let window = codeWithoutStrings(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift"),
            let nativeEffects = codeWithoutStrings(
                "gui/Sources/SoundPacksWindow/SoundPacksEditorNativeEffects.swift"),
            let menuBar = codeWithoutStrings(
                "gui/Sources/ClaudioGUI/MenuBarController.swift"),
            let package = source("gui/Package.swift")
        else {
            expect(false, "读不到共享 AppKit 实现、两处消费者、Settings owner 或 Package.swift")
            return
        }

        let allProduction = sourcesUnder("gui/Sources").map(\.code).joined(separator: "\n")
        expect(
            allProduction.components(separatedBy: "NSOpenPanel()").count - 1 == 2
                && picker.contains("NSOpenPanel()"),
            "全 GUI 仅共享组件拥有两个独立选择器：音频文件与工作区目录")
        expect(
            allProduction.components(separatedBy: "NSSound(contentsOf:").count - 1 == 1
                && player.contains("NSSound(contentsOf:"),
            "全 GUI 只允许共享组件里一处 NSSound 播放实现，避免 retention/volume 语义漂移")
        expect(
            package.contains("name: \"ClaudioGUIComponents\"")
                && package.contains("\"ClaudioGUIComponents\"")
                && !panel.contains("runAudioOpenPanel")
                && !window.contains("runAudioOpenPanel")
                && nativeEffects.contains("runAudioOpenPanel(")
                && nativeEffects.contains("allowsMultipleSelection:"),
            "picker 只能由 SoundPacksWindow native-effects adapter 经共享 ClaudioGUIComponents API 使用；"
                + "逐事件绑定单选，批量添加多选")
        expect(
            window.contains("nativeEffects.consume(")
                && nativeEffects.contains("await owner.perform(operation)")
                && nativeEffects.contains("outcome.previewAction")
                && nativeEffects.contains("owner.send(.invoke(action))"),
            "管理窗口导入必须经 typed operation 返回 owner-signed preview follow-up 后才播放；"
                + "不能按回调时的新选择串包反馈/试听")
        expect(
            nativeEffects.contains(
                "package final class SoundPacksEditorNativeEffectsDispatcher: ObservableObject")
                && !window.contains("@StateObject private var nativeEffects")
                && !window.contains("SystemSoundPacksEditorNativeEffectsAdapter()")
                && menuBar.contains("SystemSoundPacksEditorNativeEffectsAdapter()")
                && window.components(separatedBy: "@ObservedObject private var editorOwner").count
                    - 1 == 2
                && window.contains("let presentation: SoundPacksEditorPresentation")
                && window.contains("presentation: presentation"),
            "dispatcher/player 必须由 executable 构造，SoundPacks view 只消费 required adapter/owner projection"
        )
        expect(
            !window.contains(".onChange(of: editorOwner.presentation.revision)")
                && window.contains(".onChange(of: focusProjection)")
                && window.contains("requestRevision: sounds.requestRevision")
                && window.contains("routeState: sounds.routeState"),
            "普通 inventory/activity/status publication 不得触发 route focus；"
                + "只观察 request identity/route state")
        expect(
            window.contains("row.previewAvailability")
                && window.contains("invoke(row.previewAction)")
                && window.contains(".disabled(row.previewAction == nil)")
                && window.contains("previewableEvents: eventRows.filter")
                && window.contains("$0.previewAction != nil")
                && window.contains("l10n.text(.soundPacksPreview)"),
            "preview enabled 与 focus eligibility 必须同取 owner-signed capability；availability 只提供语义文案")
        expect(
            window.contains(".accessibilityValue(card.revealDisplayValue ?? \"\")")
                && window.contains(".accessibilityValue(displayValue)")
                && !window.contains(".accessibilityValue(card.id)")
                && !window.contains("displayValue.resolve("),
            "selected pack 与 empty root 的 Finder AX Value 必须直接渲染 owner-projected display path")
        expect(
            window.contains("card.isBuiltinReadOnly ? card.forkAction : card.copyAction")
                && window.contains("invoke(card.useAction)")
                && window.contains("case .restoreFactory(let action)")
                && window.contains("invoke(confirmation.confirmAction)"),
            "复制、显式启用与空态恢复必须只回送 owner-signed actions")
        expect(
            collapsingWhitespace(window).contains("packActionRow( .soundPacksCopy")
                && window.contains("l10n.text(.soundPacksAddAudio)")
                && window.contains("l10n.text(.soundPacksUse)")
                && window.contains("l10n.text(.soundPacksEmptyRestore)")
                && !window.contains("l10n.text(.soundPacksPanelVisible)"),
            "包操作、音频详情与空态主行动的用户标签必须全部真实可见")
        expect(
            window.contains("ForEach(activeSounds.windowStatuses)")
                && window.contains("activeSounds.recoveryActions.filter"),
            "窗口必须从 owner 的持久 status/recovery 投影渲染")
    }

    suite("T12：管理窗口恢复出厂是内置包专属的显式替换确认，成功/失败告知都在窗口内可见") {
        guard
            let view = codeOnly(
                "gui/Sources/SoundPacksWindow/SoundPacksWindowView.swift")
        else {
            expect(false, "读不到 SoundPacksWindowView.swift")
            return
        }
        let flat = collapsingWhitespace(view)
        expect(
            flat.contains("if card.restoreAction != nil")
                && flat.contains("Button(l10n.text(.soundPacksRestore))")
                && flat.contains("invoke(card.restoreAction)"),
            "恢复入口必须只由 owner 对真实可恢复包签发 capability，并用带省略号的动作标签")
        expect(
            flat.contains(".confirmationDialog(")
                && flat.contains("Button(l10n.text(.soundPacksRestoreButton), role: .destructive)")
                && flat.contains("factoryRestoreConfirmationMessage(confirmation)"),
            "替换必须有 destructive confirmation，并在执行前说清旧目录会搬走、零删除和路径告知")
        expect(
            flat.contains("case .restoreFactory, .retryRestore, .restoreAllFactory:")
                && flat.contains("invoke(confirmation.confirmAction)")
                && !flat.contains("restoreSelectedFactoryPackAfterConfirmation("),
            "只有 owner confirmation 内签发且最终重验的 destructive capability 才能触发 restore")
        expect(
            flat.contains("l10n.format(.soundPacksRetryRestore, displayName)")
                && flat.contains("invoke(recovery.retryAction)")
                && flat.contains("activeSounds.recoveryActions.filter")
                && flat.contains("equals: .retryFactoryRestore(packID: packID)"),
            "单包或批量 publish 失败移除原包后，每个窗口级失败项都必须保留经过确认的重试入口，"
                + "并接入可区分的真实焦点序")
        expect(
            flat.contains("ForEach(activeSounds.windowStatuses)")
                && flat.contains("private func windowStatusRow(")
                && flat.contains("status.recovery"),
            "恢复成功/失败必须进入统一状态投影，并保留可执行 retry recovery")
        guard
            let contentView = closureBody(
                after: "private struct SoundPacksWindowContentView: View", in: flat),
            let rootBody = closureBody(after: "var body: some View", in: contentView),
            let scrollBody = closureBody(after: "ScrollView(.vertical", in: rootBody),
            let detailBody = closureBody(
                after: "private var detailContent: AnyView", in: contentView),
            let overviewBody = closureBody(
                after: "private var overviewDetail: some View", in: contentView),
            let statusRegionAt = scrollBody.range(of: "windowStatusRegion")?.lowerBound,
            let detailAt = scrollBody.range(of: "detailContent")?.lowerBound,
            let statusRegionBody = closureBody(
                after: "private var windowStatusRegion: some View", in: contentView)
        else {
            expect(false, "必须切出共享 ScrollView、统一状态区和包详情")
            return
        }
        expect(
            statusRegionAt < detailAt && detailBody.contains("AnyView(overviewDetail)")
                && overviewBody.contains("emptyState")
                && statusRegionBody.contains("ForEach(activeSounds.windowStatuses)")
                && statusRegionBody.contains("windowStatusRow(status)"),
            "统一状态与每包重试必须在共享 ScrollView 中先于详情，空态不能吞掉失败")
        expect(
            braceDepth(of: "detailContent", in: scrollBody) == 1,
            "详情入口只属于阅读列，不得嵌入 selected-card 条件")
        expect(
            overviewBody.contains("libraryActions") && !scrollBody.contains("packActionBar"),
            "声音页的包和库操作跟随影响对象滚动，旧固定操作栏不再挂载")
        expect(
            flat.contains(".focused($focusedTarget, equals: .restoreFactoryPack)"),
            "恢复出厂按钮必须接进窗口专用焦点模型")
    }

    suite("任务开始事件：共享身份字形保持 paperplane.fill") {
        guard let theme = codeOnly("gui/Sources/ClaudioGUIComponents/ClaudioTheme.swift") else {
            expect(false, "必须能读取共享主题"); return
        }
        expect(
            theme.contains(#"case .taskStart: "paperplane.fill""#),
            "任务开始身份字形必须与语义固定绑定到 paperplane.fill")
    }

}
