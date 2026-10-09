import Foundation

/// API list prices (USD per million tokens), used to estimate what usage would cost at API rates.
/// Subscriptions (Pro/Max, ChatGPT, Cursor) bill differently — this is an "API estimate".
/// Claude rates: Anthropic's published pricing (cache writes 1.25× / 2× input for the 5-minute / 1-hour TTL;
/// cache reads per model). Models we have no reliable price for are reported as unpriced, never guessed.
struct Price {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double

    static func standard(_ input: Double, _ output: Double, readMultiplier: Double = 0.1) -> Price {
        Price(input: input, output: output, cacheRead: input * readMultiplier,
              cacheWrite5m: input * 1.25, cacheWrite1h: input * 2)
    }
}

enum Pricing {
    /// Longest prefix wins, so "claude-opus-4-8" beats "claude-opus-4".
    private static let table: [(String, Price)] = [
        ("claude-fable-5-1", .standard(10, 50, readMultiplier: 0.025)),
        ("claude-mythos-5-1", .standard(10, 50, readMultiplier: 0.025)),
        ("claude-fable-5", .standard(10, 50)),
        ("claude-mythos-5", .standard(10, 50)),
        ("claude-opus-5-5", .standard(4, 20, readMultiplier: 0.05)),
        ("claude-opus-5", .standard(5, 25)),
        ("claude-opus-4-8", .standard(5, 25)),
        ("claude-opus-4-7", .standard(5, 25)),
        ("claude-opus-4-6", .standard(5, 25)),
        ("claude-opus-4-5", .standard(5, 25)),
        ("claude-opus-4-1", .standard(15, 75)),
        ("claude-opus-4", .standard(15, 75)),
        ("claude-sonnet-5-5", .standard(2, 10)),
        ("claude-sonnet-5", .standard(2, 10)),
        ("claude-sonnet-4-6", .standard(3, 15)),
        ("claude-sonnet-4-5", .standard(3, 15)),
        ("claude-sonnet-4", .standard(3, 15)),
        ("claude-haiku-5-5", .standard(0.10, 0.50)),
        ("claude-haiku-4-5", .standard(1, 5)),
        ("claude-3-5-haiku", .standard(0.8, 4)),
    ]

    /// Normalises tool-specific names: Cursor appends effort ("-medium"), Claude Code may add dates.
    static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        for suffix in ["-thinking", "-max", "-xhigh", "-high", "-medium", "-low", "-fast"] where m.hasSuffix(suffix) {
            m = String(m.dropLast(suffix.count))
        }
        return m
    }

    static func price(for model: String) -> Price? {
        let m = normalize(model)
        return table.filter { m.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }?.1
    }

    /// Estimated cost in USD, or nil when the model is unpriced.
    static func cost(_ t: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(t.input) * p.input + Double(t.output) * p.output + Double(t.cacheRead) * p.cacheRead
                + Double(t.cacheWrite5m) * p.cacheWrite5m + Double(t.cacheWrite1h) * p.cacheWrite1h) / 1_000_000
    }

    /// What the cache reads would have cost as regular input, minus what they did cost.
    static func cacheSavings(_ t: TokenCounts, model: String) -> Double {
        guard let p = price(for: model) else { return 0 }
        return Double(t.cacheRead) * (p.input - p.cacheRead) / 1_000_000
    }
}

/// Token counts in one bucket. `input` is uncached input only.
struct TokenCounts: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }
    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}
