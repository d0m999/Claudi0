import ClaudioGUICore
import Foundation

@MainActor
func runSettingsHandbackSuites() {
    suite("Settings：Settings handback 在激活 Claudio 前选择外部前台 app") {
        expect(
            resolveSettingsHandbackApplication(
                frontmostApplication: "External App",
                previousApplication: "Previous App",
                isCurrentApplication: { $0 == "Claudio" }) == "External App",
            "外部 app 触发快捷键时必须直接捕获当前 frontmost app")
        expect(
            resolveSettingsHandbackApplication(
                frontmostApplication: "Claudio",
                previousApplication: "Previous App",
                isCurrentApplication: { $0 == "Claudio" }) == "Previous App",
            "Claudio 已在前台时必须保留现有 handback debt")
        expect(
            resolveSettingsHandbackApplication(
                frontmostApplication: Optional<String>.none,
                previousApplication: "Previous App",
                isCurrentApplication: { $0 == "Claudio" }) == nil,
            "无法读取 frontmost app 时不得猜测 handback target")
    }

}
