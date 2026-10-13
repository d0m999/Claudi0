import ClaudioCore
import CryptoKit
import Foundation

func nativeHookHostIdentities(selectedHost: String = "all") throws {
    struct Identity: Encodable {
        let host: String
        let version: String
        let binarySHA256: String
        let invocationPathSHA256: String
        let targetPathSHA256: String
        let metadataSHA256: String?
    }
    func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var value = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            value.update(data: bytes)
        }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    let locator = HostExecutableLocator.standard()
    let resolver = HostVersionResolver(executableLocator: locator)
    var identities: [Identity] = []
    let hosts = [HostID.claudeCode, .codex].filter {
        selectedHost == "all" || $0.rawValue == selectedHost
    }
    try require(!hosts.isEmpty, "invalid native identity host")
    for host in hosts {
        let command = host == .claudeCode ? "claude" : "codex"
        guard let call = locator.executablePath(command: command),
            let version = resolver.resolve(host, mode: .forceProbe)
        else { throw Failure(message: "native host identity unavailable") }
        let target = URL(fileURLWithPath: call).resolvingSymlinksInPath()
        let metadata = target.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("codex-package.json")
        identities.append(
            Identity(
                host: host.rawValue, version: version, binarySHA256: try fileHash(target),
                invocationPathSHA256: hash(Data(call.utf8)),
                targetPathSHA256: hash(Data(target.path.utf8)),
                metadataSHA256: host == .codex ? try fileHash(metadata) : nil))
    }
    print(String(decoding: try JSONEncoder().encode(identities), as: UTF8.self))
}
