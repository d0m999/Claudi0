import Foundation

/// The sole observed Beijing OSS bucket. HTTP is accepted only as an input spelling;
/// no HTTP request is sent. Paths and signed query bytes are never rebuilt.
package enum BailianAssetContract {
    package static let hostname = "dashscope-result-bj.oss-cn-beijing.aliyuncs.com"

    // Observed on 2026-10-08: anonymous HTTPS GET, 200, no redirects or final URL drift.
    package static let downloadPolicy = try! AICueAssetPolicy(
        allowedOrigins: [AICueAssetOrigin("https://\(hostname):443")],
        acceptedMediaTypes: ["audio/x-wav"])

    package static func downloadURL(from literal: String) throws -> URL {
        guard literal.utf8.count <= 4_096,
            literal.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
            let components = URLComponents(string: literal),
            components.host == hostname,
            components.user == nil, components.password == nil, components.fragment == nil
        else { throw AICueAssetFetchError.invalidURL }

        let normalized: String
        if components.scheme == "http" {
            guard components.port == nil || components.port == 80 else {
                throw AICueAssetFetchError.invalidURL
            }
            let prefixes = ["http://\(hostname)/", "http://\(hostname):80/"]
            guard let prefix = prefixes.first(where: { literal.hasPrefix($0) }) else {
                throw AICueAssetFetchError.invalidURL
            }
            normalized = "https://\(hostname)/" + literal.dropFirst(prefix.count)
        } else {
            guard components.scheme == "https",
                components.port == nil || components.port == 443
            else { throw AICueAssetFetchError.invalidURL }
            normalized = literal
        }
        guard let url = URL(string: normalized), url.absoluteString == normalized else {
            throw AICueAssetFetchError.invalidURL
        }
        // Apply the shared exact-origin/path boundary before even an injected fetcher is called.
        _ = try AICueURLSessionAssetFetcher.request(
            url: url,
            policy: downloadPolicy,
            deadline: .startingNow())
        return url
    }
}
