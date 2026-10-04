import Foundation
import OverheadCore

/// The one place that knows which concrete adapter backs each `ProviderID`.
struct ProviderRegistry: Sendable {
    private let providers: [ProviderID: any UsageProvider]

    init() {
        let list: [any UsageProvider] = ProviderRegistry.makeProviders()
        providers = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func provider(for id: ProviderID) -> (any UsageProvider)? { providers[id] }

    var all: [any UsageProvider] {
        ProviderID.allCases.compactMap { providers[$0] }
    }
}
