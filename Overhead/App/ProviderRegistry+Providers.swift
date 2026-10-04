import Foundation
import OverheadCore

extension ProviderRegistry {
    /// Concrete adapters. Add a case here when a new provider lands in Core.
    static func makeProviders() -> [any UsageProvider] {
        [
            ClaudeCodeProvider(),
            AnthropicAdminProvider(),
            CodexProvider(),
            OpenAIAdminProvider(),
            CursorProvider(),
            XAIProvider(),
            OpenRouterProvider(),
        ]
    }
}
