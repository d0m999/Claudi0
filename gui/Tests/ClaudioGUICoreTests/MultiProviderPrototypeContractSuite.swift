import Foundation

private func multiProviderPrototypeRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

private func multiProviderPrototypeSource(_ relativePath: String) -> String? {
    try? String(
        contentsOf: multiProviderPrototypeRepositoryRoot().appendingPathComponent(relativePath),
        encoding: .utf8)
}

private func multiProviderPrototypeSection(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) -> String? {
    guard
        let start = source.range(of: startMarker),
        let end = source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex)
    else {
        return nil
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private func multiProviderPrototypeOccurrences(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

private func multiProviderPrototypeCollapsed(_ source: String) -> String {
    source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@MainActor
func runMultiProviderPrototypeContractSuites() {
    suite("规范原型：现行五个 profile 与路线能力保持同步") {
        guard
            let html = multiProviderPrototypeSource(
                "designs/panel-and-settings/Panel and Settings Prototype.html"),
            let profiles = multiProviderPrototypeSection(
                html, from: "const profiles = [", to: "const profileName=")
        else { expect(false, "必须读取现行规范原型的 profile 表"); return }
        for id in [
            "elevenlabs-global", "minimax-global", "bailian-beijing",
            "senseaudio-cn",
        ] {
            expect(
                multiProviderPrototypeOccurrences(of: "id:'\(id)'", in: profiles) == 1,
                "现行原型每个 profile 只定义一次：\(id)")
        }
        expect(
            profiles.contains("routes:['speech','animal','soundEffect']")
                && profiles.contains("partial:true,local:true"),
            "SenseAudio 保持路线能力、部分候选及本地凭据事实")
        expect(
            profiles.contains("routes:['speech'],styled:false")
                && profiles.contains("workspace:true"),
            "MiniMax 与 Qwen 保持各自候选和验证政策")
    }

    suite("prototype compatibility boundary is synchronized across both plans") {
        let ttsPlan = multiProviderPrototypeSource("plan/PLAN-CONSUMER-TTS-EXECUTION.md")
        let settingsPlan = multiProviderPrototypeSource("plan/PLAN-SETTINGS-EXPERIENCE.md")
        for (name, plan) in [("TTS", ttsPlan), ("settings", settingsPlan)] {
            expect(plan != nil, "必须能读取 \(name) plan")
            expect(
                plan?.contains("credential=ready") == true
                    && plan?.contains("elevenlabs-global") == true
                    && plan?.contains("MiniMax/Qwen") == true,
                "\(name) plan 必须记录 ready 的 ElevenLabs-only 兼容边界")
        }
    }
}
