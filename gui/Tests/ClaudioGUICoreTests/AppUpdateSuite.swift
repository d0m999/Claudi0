import ClaudioGUICore
import Foundation

@MainActor
func runAppUpdateSuites() {
    suite("AppUpdate：共享投影、重复检查、偏好不乐观伪写") {
        let model = AppUpdateModel(state: .idle, isPublicPreview: true)
        var checks = 0
        var preferences: [Bool] = []
        model.connect(check: { checks += 1 }, setAutomaticChecks: { preferences.append($0) })
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
