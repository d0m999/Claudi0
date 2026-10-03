import ClaudioGUICore
import Foundation

/// Harness coverage for the ADR 0022 panel↔settings choreography decisions: close-before-show
/// ordering, handback application resolution (including stale PIDs), status-activation
/// protection and restored-focus-target delivery. Window-order mechanics stay covered by
/// PanelSettingsHandbackSuite / StatusItemWindowOrderGuardSuite.
@MainActor
func runPanelSettingsChoreographySuites() {
    suite("Choreography：面板打开捕获 Settings key 归属与前台外部应用，显式关闭一次性归还") {
        var choreography = PanelSettingsChoreography<String>()
        choreography.notePanelWillShow(
            settingsWasForeground: true,
            frontmostApplication: PanelHandbackApplication(
                processIdentifier: 4242, bundleIdentifier: "dev.test.host"))
        expect(
            choreography.previousApplication
                == PanelHandbackApplication(
                    processIdentifier: 4242, bundleIdentifier: "dev.test.host"),
            "打开必须记录面板借走键盘前的外部应用")
        guard case .restoreSettingsKeyFocus = choreography.panelDidClose(explicitDismissal: true)
        else {
            expect(false, "前台 Settings 在显式关闭菜单后必须取回 key")
            return
        }
        expect(
            choreography.previousApplication == nil,
            "普通关闭必须丢弃捕获的应用，不留给下一次打开")
        guard case .none = choreography.panelDidClose(explicitDismissal: true) else {
            expect(false, "同一次 key 归属只消费一次")
            return
        }
    }

    suite("Choreography：点外或切换应用关闭绝不归还旧 Settings 焦点") {
        var choreography = PanelSettingsChoreography<String>()
        choreography.notePanelWillShow(settingsWasForeground: true, frontmostApplication: nil)
        guard case .none = choreography.panelDidClose(explicitDismissal: false) else {
            expect(false, "外部交互的接收者保留用户的新焦点选择")
            return
        }
        choreography.notePanelWillShow(settingsWasForeground: false, frontmostApplication: nil)
        guard case .none = choreography.panelDidClose(explicitDismissal: true) else {
            expect(false, "后台 Settings 不能借菜单关闭抢键盘")
            return
        }
    }

    suite("Choreography：close-before-show——面板在时排队、关闭时交付同一份 presentation") {
        var choreography = PanelSettingsChoreography<String>()
        let captured = PanelHandbackApplication(processIdentifier: 700)
        choreography.notePanelWillShow(
            settingsWasForeground: false, frontmostApplication: captured)
        let queued = choreography.requestSettingsPresentation(
            request: "events", returnFocusTo: .soundScope,
            handbackApplication: nil, panelIsShown: true)
        expect(
            queued == nil && choreography.pendingPresentation != nil,
            "面板打开时请求必须排队等待关闭，不得立即呈现")
        expect(
            choreography.previousApplication == nil,
            "排队的 presentation 必须消费捕获的应用，不留第二份事实")
        guard
            case .presentSettings(let presentation) = choreography.panelDidClose(
                explicitDismissal: true)
        else {
            expect(false, "面板关闭必须交付排队的 presentation")
            return
        }
        expect(
            presentation.request == "events"
                && presentation.panelFocusTarget == .soundScope
                && presentation.handbackApplication == captured,
            "typed route、精确面板焦点目标与 handback 应用必须一起旅行")
        expect(
            choreography.pendingPresentation == nil,
            "交付后不得残留第二次关闭会重复呈现的排队请求")
    }

    suite("Choreography：面板未打开时立即呈现，显式 handback 赢过捕获的应用") {
        var choreography = PanelSettingsChoreography<String>()
        let captured = PanelHandbackApplication(processIdentifier: 700)
        let explicit = PanelHandbackApplication(processIdentifier: 900)
        choreography.notePanelWillShow(
            settingsWasForeground: false, frontmostApplication: captured)
        let immediate = choreography.requestSettingsPresentation(
            request: "settings", returnFocusTo: nil,
            handbackApplication: explicit, panelIsShown: false)
        expect(
            immediate?.request == "settings"
                && immediate?.handbackApplication == explicit
                && choreography.pendingPresentation == nil,
            "全局快捷键入口必须立即呈现并使用自己的 handback 解析")
    }

    suite("Choreography：Settings 关闭回调把最新宿主与精确面板目标一起归还") {
        var choreography = PanelSettingsChoreography<String>()
        let original = PanelHandbackApplication(processIdentifier: 700)
        let latest = PanelHandbackApplication(processIdentifier: 800)

        switch choreography.resolveSettingsCloseHandback(
            panelFocusTarget: .soundScope,
            presentationHandback: original,
            latestHandbackApplication: latest)
        {
        case .restorePanelFocus(let target):
            expect(target == .soundScope, "归还必须瞄准打开 Settings 的那颗控件")
        case .activateApplication:
            expect(false, "带面板目标的关闭必须恢复面板而不是激活应用")
        }
        expect(
            choreography.pendingRestoredPanelFocusTarget == .soundScope
                && choreography.consumeRestoredPanelFocusTarget() == .soundScope
                && choreography.consumeRestoredPanelFocusTarget() == nil,
            "恢复的面板焦点目标必须一次性交付给下一次真实打开")
        expect(
            choreography.previousApplication == latest,
            "恢复面板后若再进 Settings，handback 必须沿用关闭时观察到的最新宿主")

        switch choreography.resolveSettingsCloseHandback(
            panelFocusTarget: nil,
            presentationHandback: original,
            latestHandbackApplication: latest)
        {
        case .activateApplication(let application):
            expect(
                application == latest,
                "无面板目标时必须把激活归还给可见期间观察到的最新宿主")
        case .restorePanelFocus:
            expect(false, "无面板目标的关闭不得重开面板")
        }
        switch choreography.resolveSettingsCloseHandback(
            panelFocusTarget: nil,
            presentationHandback: original,
            latestHandbackApplication: nil)
        {
        case .activateApplication(let application):
            expect(
                application == original,
                "没有后续外部激活时必须交回请求展示时捕获的原始应用")
        case .restorePanelFocus:
            expect(false, "无面板目标的关闭不得重开面板")
        }
    }

    suite("Choreography：handback 应用解析——自身与陈旧 PID 都不得激活") {
        let captured = PanelHandbackApplication(
            processIdentifier: 700, bundleIdentifier: "dev.test.host", launchTimestamp: 100)
        let resolved = resolvePanelHandbackApplication(
            captured,
            currentProcessIdentifier: 1000,
            lookup: { pid in pid == 700 ? captured : nil },
            identityOf: { $0 })
        expect(resolved == captured, "存活的原始应用实例必须解析出来")
        let stale = resolvePanelHandbackApplication(
            captured,
            currentProcessIdentifier: 1000,
            lookup: { _ in nil as PanelHandbackApplication? },
            identityOf: { $0 })
        expect(stale == nil, "进程已退出的陈旧 PID 不得激活任何东西")
        let itself = resolvePanelHandbackApplication(
            captured,
            currentProcessIdentifier: 700,
            lookup: { _ in captured },
            identityOf: { $0 })
        expect(itself == nil, "当前进程绝不激活自己")
        let missing = resolvePanelHandbackApplication(
            nil as PanelHandbackApplication?,
            currentProcessIdentifier: 1000,
            lookup: { _ in captured },
            identityOf: { $0 })
        expect(missing == nil, "没有 handback 债务时不解析")
    }

    suite("Choreography：handback 拒绝 PID 复用及无法确认的应用实例") {
        let captured = PanelHandbackApplication(
            processIdentifier: 700, bundleIdentifier: "dev.test.original", launchTimestamp: 100)
        let replacements = [
            PanelHandbackApplication(
                processIdentifier: 700, bundleIdentifier: "dev.test.replacement",
                launchTimestamp: 100),
            PanelHandbackApplication(
                processIdentifier: 700, bundleIdentifier: "dev.test.original",
                launchTimestamp: 200),
            PanelHandbackApplication(
                processIdentifier: 701, bundleIdentifier: "dev.test.original",
                launchTimestamp: 100),
            PanelHandbackApplication(
                processIdentifier: 700, bundleIdentifier: "dev.test.original"),
        ]
        for replacement in replacements {
            let resolved = resolvePanelHandbackApplication(
                captured,
                currentProcessIdentifier: 1000,
                lookup: { _ in replacement },
                identityOf: { $0 })
            expect(
                resolved == nil,
                "bundle、PID、启动时间不符或缺失时，不得回交焦点：\(replacement)")
        }

        let unknownLaunch = PanelHandbackApplication(
            processIdentifier: 700, bundleIdentifier: "dev.test.original")
        let resolved = resolvePanelHandbackApplication(
            unknownLaunch,
            currentProcessIdentifier: 1000,
            lookup: { _ in unknownLaunch },
            identityOf: { $0 })
        expect(resolved == nil, "捕获和查找都缺少启动身份时，不能仅凭 PID 与 bundle 相同激活")
    }

    suite("Choreography：状态栏转发点击保护只在三项当前事实同时成立时启动") {
        expect(
            panelSettingsShouldProtectDuringStatusActivation(
                settingsOwnsKeyFocus: true, primaryMouseButtonDown: true, statusItemHit: true),
            "key 归属、主键按下、命中状态按钮三者同时成立才保护")
        for facts in [
            (false, true, true), (true, false, true), (true, true, false),
            (false, false, false),
        ] {
            expect(
                !panelSettingsShouldProtectDuringStatusActivation(
                    settingsOwnsKeyFocus: facts.0,
                    primaryMouseButtonDown: facts.1,
                    statusItemHit: facts.2),
                "后台 Settings、非主键点击或其他状态项都不得进入保护 \(facts)")
        }
    }
}
