import ClaudioGUICore
import Foundation

@MainActor
func runAppUpdateSuites() {
    suite("AppUpdate：共享投影、重复检查、偏好不乐观伪写") {
        let model = AppUpdateModel(state: .idle, isPublicPreview: true)
        var checks = 0
        var preferences: [Bool] = []
        model.connect(
            check: { checks += 1 }, sessionInProgress: { false },
            setAutomaticChecks: { preferences.append($0) })
        model.project(state: .idle, canCheck: true, automaticChecks: false)
        model.checkForUpdates()
        model.checkForUpdates()
        expect(checks == 1 && model.state == .checking, "重复点击只启动一次更新会话")
        model.project(state: .available("0.0.10"), canCheck: true, automaticChecks: false)
        expect(checks == 1, "后台新版只改变状态，不打开窗口")
        model.setAutomaticallyChecksForUpdates(true)
        expect(preferences == [true] && !model.automaticallyChecksForUpdates, "偏好只由 adapter 事实确认")
        model.project(state: .available("0.0.10"), canCheck: true, automaticChecks: true)
        model.checkForUpdates()
        expect(checks == 2, "提醒可显式交给标准窗口")
        model.project(
            state: .unavailable(.moveToApplications), canCheck: true, automaticChecks: false)
        model.checkForUpdates()
        model.setAutomaticallyChecksForUpdates(true)
        expect(checks == 2 && preferences == [true], "不可用路径不启动更新或改偏好")
    }
    suite("AppUpdate：已有会话聚焦不等待新检查回调，可反复找回窗口") {
        let model = AppUpdateModel(state: .idle)
        var checks = 0
        var sessionInProgress = false
        model.connect(
            check: {
                checks += 1
                sessionInProgress = true
            },
            sessionInProgress: { sessionInProgress },
            setAutomaticChecks: { _ in })
        model.project(state: .idle, canCheck: true, automaticChecks: false)
        model.checkForUpdates()
        expect(sessionInProgress && model.state == .checking, "新检查仍进入检查中")
        expect(!model.canCheckForUpdates, "下载 feed 时禁止重复检查")
        model.project(state: .available("0.0.10"), canCheck: true, automaticChecks: false)
        model.project(state: .idle, canCheck: true, automaticChecks: false)
        // Sparkle already delivered user attention. Refocusing emits no KVO or delegate callback.
        model.checkForUpdates()
        expect(model.state == .idle, "聚焦已查看的窗口不伪装为新的检查")
        expect(model.canCheckForUpdates, "没有新回调时找回窗口的入口仍可用")
        model.checkForUpdates()
        expect(checks == 3 && model.state == .idle, "同一会话允许再次显式聚焦")
        sessionInProgress = false
        model.project(state: .upToDate, canCheck: true, automaticChecks: false)
        model.checkForUpdates()
        expect(checks == 4 && model.state == .checking, "会话结束后再次点击启动新检查")
    }
    suite("AppUpdate：后台提醒和权限会话聚焦保留当前投影") {
        for state: AppUpdateState in [.available("0.0.10"), .idle] {
            let model = AppUpdateModel(state: state)
            var focuses = 0
            model.connect(
                check: { focuses += 1 }, sessionInProgress: { true },
                setAutomaticChecks: { _ in })
            model.project(state: state, canCheck: true, automaticChecks: false)
            model.checkForUpdates()
            model.checkForUpdates()
            expect(focuses == 2, "后台提醒或权限窗口可反复显式聚焦")
            expect(model.state == state && model.canCheckForUpdates, "聚焦不伪写检查状态或禁用入口")
            model.project(state: state, canCheck: false, automaticChecks: false)
            model.checkForUpdates()
            expect(focuses == 2, "已有会话仍遵守 Sparkle 禁止操作的事实")
        }
    }
    suite("AppUpdate：DMG、只读卷、Translocation 与路径边界") {
        let roots = [URL(fileURLWithPath: "/Applications")]
        func allowed(_ path: String, readOnly: Bool? = false) -> Bool {
            appUpdateInstallationAllowsUpdates(
                bundleURL: URL(fileURLWithPath: path),
                applicationsDirectories: roots, volumeIsReadOnly: readOnly)
        }
        expect(allowed("/Applications/claudi0.app"), "可写安装允许更新")
        expect(!allowed("/Applications-other/claudi0.app"), "目录前缀不能冒充安装目录")
        expect(!allowed("/Volumes/claudi0/claudi0.app"), "挂载 DMG 禁止更新")
        expect(!allowed("/Applications/claudi0.app", readOnly: true), "只读卷禁止更新")
        expect(!allowed("/Applications/claudi0.app", readOnly: nil), "未知卷事实关闭")
        expect(!allowed("/private/var/folders/AppTranslocation/d/claudi0.app"), "Translocation 关闭")
    }
    suite("退出：等待采用事务，结束后重读风险，取消保留旧 app") {
        var gate = AICueTerminationGate()
        expect(gate.request(reason: .adopting) == .waitForAdoption, "采用不能中断")
        expect(gate.request(reason: .adopting) == .alreadyWaiting, "重复退出合并")
        expect(
            gate.adoptionCompleted(currentReason: .unsavedAudio) == .ask(.unsavedAudio), "事务结束重新判断")
        expect(gate.answer(quit: false, currentReason: .unsavedAudio) == .cancel, "取消退出保留进程")
        expect(gate.request(reason: .generating) == .ask(.generating), "新请求继续正常提示")
        expect(gate.answer(quit: true, currentReason: .adopting) == .waitForAdoption, "答复期间采用也等待")
        expect(gate.adoptionCompleted(currentReason: nil) == .allow, "完成后允许 Sparkle 继续退出")
    }
}
