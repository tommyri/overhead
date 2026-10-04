import Foundation

/// List prices in USD per million tokens. Used only to *estimate* cost for local log
/// sources that do not record billed amounts. Matching is prefix-based on the model id
/// after normalization; the longest matching pattern wins.
public struct ModelPrice: Sendable, Hashable {
    public let pattern: String
    public let input: Double
    public let output: Double
    /// Cache read / cached-input price. nil → billed as plain input.
    public let cacheRead: Double?
    /// 5-minute (default) cache write. nil → billed as plain input.
    public let cacheWrite: Double?
    /// 1-hour cache write (Anthropic). nil → falls back to `cacheWrite`.
    public let cacheWrite1h: Double?

    public init(_ pattern: String, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil) {
        self.pattern = pattern; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
    }

    /// Anthropic convention: 5m write = 1.25× input, 1h write = 2× input.
    static func anthropic(_ pattern: String, input: Double, output: Double, cacheRead: Double) -> ModelPrice {
        ModelPrice(pattern, input: input, output: output, cacheRead: cacheRead, cacheWrite: input * 1.25, cacheWrite1h: input * 2)
    }
}

public enum PriceTable {
    /// Date the table was last checked against vendor pricing pages.
    public static let lastReviewed = "2026-10-04"

    public static let all: [ModelPrice] = [
        // Anthropic — https://platform.claude.com/docs/en/about-claude/pricing
        .anthropic("claude-fable-5-1",  input: 10,   output: 50, cacheRead: 0.25),
        .anthropic("claude-mythos-5-1", input: 10,   output: 50, cacheRead: 0.25),
        .anthropic("claude-fable-5",    input: 10,   output: 50, cacheRead: 1.00),
        .anthropic("claude-opus-5-5",   input: 4,    output: 20, cacheRead: 0.20),
        .anthropic("claude-opus-5",     input: 5,    output: 25, cacheRead: 0.50),
        .anthropic("claude-opus-4-8",   input: 5,    output: 25, cacheRead: 0.50),
        .anthropic("claude-opus-4-7",   input: 5,    output: 25, cacheRead: 0.50),
        .anthropic("claude-opus-4-6",   input: 5,    output: 25, cacheRead: 0.50),
        .anthropic("claude-opus-4-5",   input: 5,    output: 25, cacheRead: 0.50),
        .anthropic("claude-opus-4-1",   input: 15,   output: 75, cacheRead: 1.50),
        .anthropic("claude-opus-4",     input: 15,   output: 75, cacheRead: 1.50),
        .anthropic("claude-sonnet-5-5", input: 2,    output: 10, cacheRead: 0.20),
        .anthropic("claude-sonnet-5",   input: 2,    output: 10, cacheRead: 0.20),
        .anthropic("claude-sonnet-4-6", input: 3,    output: 15, cacheRead: 0.30),
        .anthropic("claude-sonnet-4-5", input: 3,    output: 15, cacheRead: 0.30),
        .anthropic("claude-sonnet-4",   input: 3,    output: 15, cacheRead: 0.30),
        .anthropic("claude-haiku-4-5",  input: 1,    output: 5,  cacheRead: 0.10),
        .anthropic("claude-3-5-haiku",  input: 0.8,  output: 4,  cacheRead: 0.08),

        // OpenAI — https://developers.openai.com/api/docs/pricing (cache writes bill as input)
        ModelPrice("gpt-6-astra",       input: 10,   output: 50,   cacheRead: 1.00),
        ModelPrice("gpt-6.1-sol",       input: 2,    output: 10,   cacheRead: 0.10),
        ModelPrice("gpt-6-sol",         input: 2,    output: 10,   cacheRead: 0.20),
        ModelPrice("gpt-6-luna",        input: 0.10, output: 0.50, cacheRead: 0.01),
        ModelPrice("gpt-5.6-sol",       input: 4,    output: 20,   cacheRead: 0.40),
        ModelPrice("gpt-5.5",           input: 5,    output: 30,   cacheRead: 0.50),
        ModelPrice("gpt-5.4-mini",      input: 0.75, output: 4.50, cacheRead: 0.075),
        ModelPrice("gpt-5.4-nano",      input: 0.20, output: 1.25, cacheRead: 0.02),
        ModelPrice("gpt-5.4",           input: 2.50, output: 15,   cacheRead: 0.25),
        ModelPrice("gpt-5.2",           input: 1.75, output: 14,   cacheRead: 0.175),
        ModelPrice("gpt-5.1",           input: 1.25, output: 10,   cacheRead: 0.125),
        ModelPrice("gpt-5-codex",       input: 1.25, output: 10,   cacheRead: 0.125),
        ModelPrice("gpt-5-mini",        input: 0.25, output: 2,    cacheRead: 0.025),
        ModelPrice("gpt-5-nano",        input: 0.05, output: 0.40, cacheRead: 0.005),
        ModelPrice("gpt-5",             input: 1.25, output: 10,   cacheRead: 0.125),
        ModelPrice("codex-mini-latest", input: 1.50, output: 6,    cacheRead: 0.375),
        ModelPrice("gpt-4.1-mini",      input: 0.40, output: 1.60, cacheRead: 0.10),
        ModelPrice("gpt-4.1-nano",      input: 0.10, output: 0.40, cacheRead: 0.025),
        ModelPrice("gpt-4.1",           input: 2,    output: 8,    cacheRead: 0.50),
        ModelPrice("gpt-4o-mini",       input: 0.15, output: 0.60, cacheRead: 0.075),
        ModelPrice("gpt-4o",            input: 2.50, output: 10,   cacheRead: 1.25),
        ModelPrice("o1",                input: 15,   output: 60,   cacheRead: 7.50),
        ModelPrice("o3-mini",           input: 1.10, output: 4.40, cacheRead: 0.55),
        ModelPrice("o3",                input: 2,    output: 8,    cacheRead: 0.50),
        ModelPrice("o4-mini",           input: 1.10, output: 4.40, cacheRead: 0.275),

        // xAI — https://docs.x.ai/developers/pricing (standard <200k-token tier)
        ModelPrice("grok-4.7",          input: 2,    output: 6,    cacheRead: 0.50),
        ModelPrice("grok-4.6",          input: 2,    output: 6,    cacheRead: 0.50),
        ModelPrice("grok-4.5",          input: 2,    output: 6,    cacheRead: 0.30),
        ModelPrice("grok-4.3",          input: 1.25, output: 2.50, cacheRead: 0.20),
        ModelPrice("grok-4.20",         input: 1.25, output: 2.50, cacheRead: 0.20),
        ModelPrice("grok-build",        input: 1,    output: 2,    cacheRead: 0.20),

        // Google — https://ai.google.dev/gemini-api/docs/pricing (paid tier, ≤200k)
        ModelPrice("gemini-3.8-flash",      input: 0.75, output: 3.75, cacheRead: 0.075),
        ModelPrice("gemini-3.7-flash",      input: 0.75, output: 3.75, cacheRead: 0.075),
        ModelPrice("gemini-3.6-flash",      input: 0.75, output: 3.75, cacheRead: 0.075),
        ModelPrice("gemini-3.5-flash-lite", input: 0.30, output: 2.50),
        ModelPrice("gemini-3.5-flash",      input: 1.50, output: 9,    cacheRead: 0.15),
        ModelPrice("gemini-3.1-pro",        input: 2,    output: 12,   cacheRead: 0.20),
        ModelPrice("gemini-2.5-pro",        input: 1.25, output: 10,   cacheRead: 0.125),
        ModelPrice("gemini-2.5-flash-lite", input: 0.10, output: 0.40),
        ModelPrice("gemini-2.5-flash",      input: 0.30, output: 2.50, cacheRead: 0.03),
    ]

    /// Find the best price entry for a model id.
    public static func price(for model: String) -> ModelPrice? {
        let normalized = normalize(model)
        return all
            .filter { normalized.hasPrefix($0.pattern) }
            .max { $0.pattern.count < $1.pattern.count }
    }

    /// Lower-case, strip provider prefixes ("anthropic/", "openai/") and 8-digit date suffixes.
    public static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m
    }

    /// Estimated USD cost for a token breakdown, or nil if the model is unknown.
    /// `cacheWrite` is the 5-minute (default) bucket; `cacheWrite1h` the 1-hour bucket.
    public static func estimate(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int = 0) -> Double? {
        guard let p = price(for: model) else { return nil }
        let m = 1.0 / 1_000_000
        var cost = Double(input) * p.input * m + Double(output) * p.output * m
        cost += Double(cacheRead) * (p.cacheRead ?? p.input) * m
        cost += Double(cacheWrite) * (p.cacheWrite ?? p.input) * m
        cost += Double(cacheWrite1h) * (p.cacheWrite1h ?? p.cacheWrite ?? p.input) * m
        return cost
    }
}
