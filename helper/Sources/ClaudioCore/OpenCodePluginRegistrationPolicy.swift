import Foundation

enum OpenCodePluginRegistrationPolicy {
    static func validate(configurationRoot: URL, pluginFile: URL) throws {
        for name in ["opencode.json", "opencode.jsonc"] {
            let file = configurationRoot.appendingPathComponent(name)
            guard
                FileManager.default.fileExists(atPath: file.path)
                    || leafNodeIsSymbolicLink(at: file)
            else { continue }
            guard
                case .success(let data) = readRegularFileBounded(
                    at: file, maxBytes: 1 << 20,
                    followSymlink: true),
                let clean = jsonc(data),
                HostEventSourceParser.duplicateTopLevelKeys(clean).isEmpty,
                let object = (try? JSONSerialization.jsonObject(with: clean)) as? [String: Any]
            else { throw rejected("OpenCode 配置无法安全读取；opencode.json/jsonc 保持原样") }
            if let raw = object["plugin"] {
                guard let plugins = raw as? [Any] else { throw rejected("OpenCode plugin 配置类型无效") }
                for value in plugins {
                    let name = (value as? String) ?? (value as? [Any])?.first as? String
                    guard let name else { throw rejected("OpenCode plugin 注册无法安全识别") }
                    if name.contains("claudio.opencode") || name == "claudio.js"
                        || name.hasSuffix("/plugins/claudio.js")
                        || name.hasSuffix("/plugins/claudio.ts")
                    {
                        throw rejected("OpenCode 已显式注册 Claudio 插件；请先处理与自动发现的重复注册")
                    }
                }
            }
        }
        let directory = pluginFile.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        guard files.count <= 256 else { throw rejected("OpenCode 插件目录超过安全检查上限") }
        // Directory enumeration may resolve /var to /private/var. This is the direct child
        // name in the very same directory, not a comparison of two path spellings.
        for file in files
        where file.lastPathComponent != pluginFile.lastPathComponent
            && ["js", "ts"].contains(file.pathExtension)
        {
            guard
                case .success(let data) = readRegularFileBounded(
                    at: file, maxBytes: 1 << 20,
                    followSymlink: true)
            else { throw rejected("OpenCode 插件目录无法安全检查") }
            if let source = String(data: data, encoding: .utf8),
                source.contains("Claudio managed OpenCode bridge v1")
                    || source.contains("claudio.opencode.v1")
            {
                throw rejected("OpenCode 插件目录含另一份 Claudio 插件，已拒绝重复安装")
            }
        }
    }

    /// Remove comments and trailing commas without touching bytes inside JSON strings.
    private static func jsonc(_ data: Data) -> Data? {
        let bytes = Array(data)
        var output = bytes
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == 92 { index += 2; continue }
                if byte == 34 { inString = false }
                index += 1
                continue
            }
            if byte == 34 { inString = true; index += 1; continue }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                while index < bytes.count, bytes[index] != 10 { output[index] = 32; index += 1 }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                output[index] = 32; output[index + 1] = 32; index += 2
                while index + 1 < bytes.count && !(bytes[index] == 42 && bytes[index + 1] == 47) {
                    if bytes[index] != 10 && bytes[index] != 13 { output[index] = 32 }
                    index += 1
                }
                guard index + 1 < bytes.count else { return nil }
                output[index] = 32; output[index + 1] = 32; index += 2
                continue
            }
            index += 1
        }
        guard !inString else { return nil }
        index = 0
        inString = false
        while index < output.count {
            let byte = output[index]
            if inString {
                if byte == 92 { index += 2; continue }
                if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
            } else if byte == 44 {
                var next = index + 1
                while next < output.count && [9, 10, 13, 32].contains(output[next]) { next += 1 }
                if next < output.count && [93, 125].contains(output[next]) { output[index] = 32 }
            }
            index += 1
        }
        return Data(output)
    }

    private static func rejected(_ reason: String) -> ConfigFileTransactionError {
        .mutationRejected(reason: reason)
    }
}
