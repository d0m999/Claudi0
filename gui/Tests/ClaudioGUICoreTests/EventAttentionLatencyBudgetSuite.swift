import Foundation

/// Explicit budget for the synthetic ingress p95 assertion. The harness never infers CI from
/// the environment: an override must arrive through this named variable, and an invalid value
/// fails the suite instead of silently falling back to the local budget.
enum EventAttentionLatencyBudget {
    static let environmentKey = "CLAUDIO_EVENT_ATTENTION_P95_MS"
    static let localDefaultMilliseconds = 100.0
    static let maximumMilliseconds = 60_000.0

    enum Resolution: Equatable {
        case localDefault
        case explicit(Double)
        case invalid(String)
    }

    static func resolve(_ rawValue: String?) -> Resolution {
        guard let rawValue else { return .localDefault }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid("empty value") }
        guard let value = Double(trimmed), value.isFinite else {
            return .invalid("not a finite number: \(rawValue)")
        }
        guard value > 0, value <= maximumMilliseconds else {
            return .invalid("outside (0, \(Int(maximumMilliseconds))]: \(rawValue)")
        }
        return .explicit(value)
    }

    static func resolve(environment: [String: String]) -> Resolution {
        resolve(environment[environmentKey])
    }
}

@MainActor
func runEventAttentionLatencyBudgetSuites() {
    suite("event attention p95 budget: missing value keeps the 100ms local default") {
        expect(
            EventAttentionLatencyBudget.resolve(environment: [:]) == .localDefault,
            "an absent override must keep the 100ms local budget")
        expect(
            EventAttentionLatencyBudget.resolve(nil) == .localDefault,
            "a nil value must keep the 100ms local budget")
    }

    suite("event attention p95 budget: explicit finite values in range are accepted") {
        expect(
            EventAttentionLatencyBudget.resolve("250") == .explicit(250),
            "250ms must be accepted verbatim")
        expect(
            EventAttentionLatencyBudget.resolve("1e3") == .explicit(1000),
            "scientific notation must parse as milliseconds")
        expect(
            EventAttentionLatencyBudget.resolve(" 250\n") == .explicit(250),
            "surrounding whitespace must be trimmed")
        expect(
            EventAttentionLatencyBudget.resolve("60000") == .explicit(60_000),
            "the upper bound is inclusive")
    }

    suite("event attention p95 budget: invalid values fail closed, never fall back") {
        let rejected = ["", "   ", "abc", "250ms", "nan", "inf", "-1", "0", "60001"]
            .allSatisfy {
                if case .invalid = EventAttentionLatencyBudget.resolve($0) { return true }
                return false
            }
        expect(rejected, "every malformed override must be rejected, never silently defaulted")
    }

    suite("event attention p95 budget: the CI gui lane passes the explicit budget") {
        let ciURL = guiTestRepositoryRoot().appendingPathComponent(".github/workflows/ci.yml")
        guard let ci = try? String(contentsOf: ciURL, encoding: .utf8),
            let guiStart = ci.range(of: "\n  gui:\n")?.upperBound,
            let guiEnd = ci.range(of: "\n  gui-foreground:\n")?.lowerBound,
            guiStart < guiEnd
        else {
            expect(false, "读不到 CI gui lane")
            return
        }
        expect(
            ci[guiStart..<guiEnd].contains(
                "CLAUDIO_EVENT_ATTENTION_P95_MS: \"250\""),
            "CI gui lane must set the explicit 250ms p95 budget")
    }
}
