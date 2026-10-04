import SwiftUI
import OverheadCore

enum Fmt {
    static func usd(_ v: Double?, estimate: Bool = false) -> String {
        guard let v else { return "—" }
        // Everything is billed in USD; use a fixed "$1,234.56" style regardless of locale.
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = v < 1000 ? 2 : 0
        f.minimumFractionDigits = v < 1000 ? 2 : 0
        let s = f.string(from: NSNumber(value: v)) ?? "$\(v)"
        return estimate ? "≈\(s)" : s
    }

    static func cost(_ c: UsageRecord.Cost) -> String {
        usd(c.value, estimate: c.isEstimate)
    }

    /// "mcp__Claude_Browser__browser_batch" → "Claude Browser · browser_batch"; others unchanged.
    static func toolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return raw }
        let server = parts[0].replacingOccurrences(of: "_", with: " ")
        return "\(server) · \(parts.dropFirst().joined(separator: "__"))"
    }

    static func multiple(_ m: Double?) -> String {
        guard let m else { return "—" }
        return m >= 10 ? String(format: "%.0f×", m) : String(format: "%.1f×", m)
    }

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.2fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", v / 1_000)
        default:               return "\(n)"
        }
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    static func relative(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// "claude-sonnet-4-5-20250929" → "Sonnet 4.5"; "gpt-5-codex" → "GPT-5 Codex". Best-effort.
    static func modelName(_ id: String) -> String {
        if id.isEmpty { return "All models" }
        var s = id
        // Strip Anthropic date suffixes.
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.hasPrefix("claude-") {
            s.removeFirst("claude-".count)
            // "sonnet-4-5" -> "Sonnet 4.5"
            let parts = s.split(separator: "-").map(String.init)
            if let first = parts.first {
                let rest = parts.dropFirst().joined(separator: ".")
                return rest.isEmpty ? first.capitalized : "\(first.capitalized) \(rest)"
            }
        }
        if s.hasPrefix("gpt-") {
            return "GPT-" + s.dropFirst(4)
                .replacingOccurrences(of: "-codex", with: " Codex")
                .replacingOccurrences(of: "-mini", with: " mini")
                .replacingOccurrences(of: "-nano", with: " nano")
        }
        if s.hasPrefix("grok-") { return "Grok " + s.dropFirst(5) }
        if s.hasPrefix("gemini-") { return "Gemini " + s.dropFirst(7) }
        return s
    }
}

extension ProviderID {
    /// Dynamic color: resolves to the light or dark palette step for the current appearance.
    var color: Color {
        let hex = seriesHex
        let ns = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: dark ? hex.dark : hex.light)
        }
        return Color(nsColor: ns)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: 1)
    }
}

extension FetchStatus {
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .loading: return "arrow.triangle.2.circlepath"
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .notConfigured: return "key.slash"
        }
    }
    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .loading: return .accentColor
        case .ok: return .green
        case .failed: return .orange
        case .notConfigured: return .secondary
        }
    }
    var text: String {
        switch self {
        case .idle: return "Not loaded"
        case .loading: return "Refreshing…"
        case .ok(let d): return "Updated \(Fmt.relative(d))"
        case .failed(let m): return m
        case .notConfigured: return "Needs credentials"
        }
    }
}
