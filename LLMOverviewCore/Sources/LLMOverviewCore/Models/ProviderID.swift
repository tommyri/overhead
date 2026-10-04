import Foundation

/// Stable identifier for every usage source the app knows about.
/// The raw value is persisted (cache file names, settings), so never rename a case.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case claudeCode      = "claude-code"
    case anthropicAPI    = "anthropic-api"
    case codexCLI        = "codex-cli"
    case openAIAPI       = "openai-api"
    case cursor          = "cursor"
    case xai             = "xai"
    case openRouter      = "openrouter"

    public var id: String { rawValue }

    /// How the data is obtained. Drives which settings UI is shown.
    public enum Kind: String, Sendable, Codable {
        /// Parsed from log files the tool leaves on this Mac. No credentials needed.
        case local
        /// Fetched from the vendor's HTTP API with a credential stored in Keychain.
        case api
    }

    public var kind: Kind {
        switch self {
        case .claudeCode, .codexCLI: return .local
        case .anthropicAPI, .openAIAPI, .cursor, .xai, .openRouter: return .api
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .anthropicAPI: return "Anthropic API"
        case .codexCLI:     return "Codex CLI"
        case .openAIAPI:    return "OpenAI API"
        case .cursor:       return "Cursor"
        case .xai:          return "xAI (Grok)"
        case .openRouter:   return "OpenRouter"
        }
    }

    /// Vendor family, used to group providers in the UI ("Anthropic" covers both Claude Code and the API).
    public var vendor: String {
        switch self {
        case .claudeCode, .anthropicAPI: return "Anthropic"
        case .codexCLI, .openAIAPI:      return "OpenAI"
        case .cursor:                    return "Cursor"
        case .xai:                       return "xAI"
        case .openRouter:                return "OpenRouter"
        }
    }

    /// SF Symbol used in sidebars and the menu bar list.
    public var symbolName: String {
        switch self {
        case .claudeCode:   return "terminal"
        case .anthropicAPI: return "a.circle"
        case .codexCLI:     return "chevron.left.forwardslash.chevron.right"
        case .openAIAPI:    return "o.circle"
        case .cursor:       return "cursorarrow.rays"
        case .xai:          return "x.circle"
        case .openRouter:   return "arrow.triangle.branch"
        }
    }

    /// Position in the stacked-chart order and categorical palette. Stacking and legend
    /// order follow this so adjacent series always come from validated adjacent slots.
    public var paletteSlot: Int {
        switch self {
        case .cursor:       return 1
        case .claudeCode:   return 2
        case .codexCLI:     return 3
        case .anthropicAPI: return 4
        case .openRouter:   return 5
        case .openAIAPI:    return 6
        case .xai:          return 7
        }
    }

    /// Categorical series colors (hex, no `#`) for light and dark surfaces. Same eight
    /// hues stepped per surface; validated for adjacent-pair colorblind separation.
    public var seriesHex: (light: String, dark: String) {
        switch self {
        case .cursor:       return ("2a78d6", "3987e5")
        case .claudeCode:   return ("eb6834", "d95926")
        case .codexCLI:     return ("1baf7a", "199e70")
        case .anthropicAPI: return ("eda100", "c98500")
        case .openRouter:   return ("e87ba4", "d55181")
        case .openAIAPI:    return ("008300", "008300")
        case .xai:          return ("4a3aa7", "9085e9")
        }
    }

    /// All providers in chart/legend order.
    public static var chartOrder: [ProviderID] {
        allCases.sorted { $0.paletteSlot < $1.paletteSlot }
    }

    /// Short explanation shown in the provider's settings pane.
    public var setupHint: String {
        switch self {
        case .claudeCode:
            return "Reads session logs in ~/.claude/projects. Nothing to configure. Costs are estimated from list prices."
        case .anthropicAPI:
            return "Requires an Admin API key (sk-ant-admin…) from console.anthropic.com → Settings → Admin keys. Returns organization-wide usage and billed cost."
        case .codexCLI:
            return "Reads session logs in ~/.codex/sessions. Nothing to configure. Costs are API-equivalent estimates from list prices; with a ChatGPT plan you are not billed per token."
        case .openAIAPI:
            return "Requires an Admin API key (sk-admin…) from platform.openai.com → Settings → Admin keys. Returns organization-wide usage and billed cost."
        case .cursor:
            return "Pro / Pro+ / Ultra: uses your cursor.com login session — import it from the Cursor app or paste the WorkosCursorSessionToken cookie from your browser. Teams: use a team Admin API key instead."
        case .xai:
            return "Requires a Management API key and your Team ID from console.x.ai. Returns billed cost per model and day (no token counts)."
        case .openRouter:
            return "Requires a regular OpenRouter API key (shows today's spend). Add a Management key to get 30 days of per-model history."
        }
    }
}
