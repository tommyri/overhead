import Foundation

/// The app's identifier, used for the Keychain service and (via the bundle) UserDefaults.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.overhead"

    /// If the bundle identifier ever changes again, list the previous one(s) here: Keychain
    /// items and preferences are carried over on first launch, then the old copies removed.
    static let legacyBundleIDs: [String] = ["app.llmoverview"]   // the app was called "LLM Overview" before 0.1.0

    /// Copy preferences from a legacy defaults domain the first time the new one is empty,
    /// then remove the legacy domain.
    static func migrateDefaultsIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: "enabledProviders") == nil else { return }
        for legacy in legacyBundleIDs where legacy != bundleID {
            guard let old = d.persistentDomain(forName: legacy), !old.isEmpty else { continue }
            for (k, v) in old { d.set(v, forKey: k) }
            d.removePersistentDomain(forName: legacy)
            return
        }
    }
}
