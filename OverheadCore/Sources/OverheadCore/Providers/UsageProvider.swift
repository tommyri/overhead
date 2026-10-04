import Foundation

/// A single credential field a provider needs. Rendered as a secure text field in Settings.
public struct CredentialField: Sendable, Hashable, Identifiable {
    public var id: String { key }
    /// Keychain account name, e.g. "openai.adminKey".
    public let key: String
    public let label: String
    public let placeholder: String
    /// Not secret (e.g. a team id). Rendered as a plain text field.
    public let isPlainText: Bool
    /// The provider works without it, with reduced data.
    public let isOptional: Bool

    public init(key: String, label: String, placeholder: String, isPlainText: Bool = false, isOptional: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isPlainText = isPlainText
        self.isOptional = isOptional
    }
}

/// Values the user has entered, keyed by `CredentialField.key`.
public typealias Credentials = [String: String]

/// An explicit, user-triggered way to fill a credential field from something already on
/// this Mac (e.g. the session the Cursor app is signed in with). Never run automatically.
public struct CredentialImport: Sendable {
    public let fieldKey: String
    public let buttonTitle: String
    /// Shown next to the button so the user knows exactly what will be read.
    public let explanation: String
    public let run: @Sendable () throws -> String

    public init(fieldKey: String, buttonTitle: String, explanation: String, run: @escaping @Sendable () throws -> String) {
        self.fieldKey = fieldKey; self.buttonTitle = buttonTitle; self.explanation = explanation; self.run = run
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case notConfigured
    case unauthorized(String)
    case http(status: Int, body: String)
    case decoding(String)
    case noData(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:            return "Not configured. Add credentials in Settings."
        case .unauthorized(let m):      return "Unauthorized: \(m)"
        case .http(let s, let body):    return "HTTP \(s): \(body.prefix(300))"
        case .decoding(let m):          return "Could not read response: \(m)"
        case .noData(let m):            return m
        case .other(let m):             return m
        }
    }
}

/// Contract every usage source implements. Adapters are stateless; the app passes in
/// credentials and the requested window and gets back normalized day/model records.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Credentials this provider needs. Empty for local log parsers.
    var credentialFields: [CredentialField] { get }
    /// Optional one-click imports for credential fields (see `CredentialImport`).
    var credentialImports: [CredentialImport] { get }
    /// Whether enough credentials are present to attempt a fetch.
    func isConfigured(_ credentials: Credentials) -> Bool
    /// Fetch usage covering `interval` (local calendar days). Implementations may return a
    /// superset; the app filters. Records must already be deduped per (day, model).
    func fetch(interval: DateInterval, credentials: Credentials) async throws -> [UsageRecord]
    /// Subscription-plan consumption, if the source exposes it. nil when not applicable.
    func planStatus(credentials: Credentials) async throws -> PlanStatus?
    /// Lines of code the tool produced, per day. Empty when the source has no such data.
    func codeActivity(interval: DateInterval, credentials: Credentials) async throws -> [CodeActivity]
    /// Tool calls per tool and day. Empty when the source has no such data.
    func toolActivity(interval: DateInterval, credentials: Credentials) async throws -> [ToolActivity]
    /// Past observations of the plan windows, when the source records them itself (Codex logs,
    /// the Claude status-line helper). Empty otherwise; the app then samples `planStatus`.
    func planHistory(interval: DateInterval, credentials: Credentials) async throws -> [PlanSample]
    /// Sessions (one per transcript or rollout) with their active time. Empty for sources without them.
    func sessions(interval: DateInterval, credentials: Credentials) async throws -> [SessionActivity]
    /// Model responses per local hour, for the weekday × hour heatmap. Empty where only daily data exists.
    func hourlyActivity(interval: DateInterval, credentials: Credentials) async throws -> [HourlyActivity]
}

public extension UsageProvider {
    var credentialFields: [CredentialField] { [] }
    var credentialImports: [CredentialImport] { [] }
    func planStatus(credentials: Credentials) async throws -> PlanStatus? { nil }
    func codeActivity(interval: DateInterval, credentials: Credentials) async throws -> [CodeActivity] { [] }
    func toolActivity(interval: DateInterval, credentials: Credentials) async throws -> [ToolActivity] { [] }
    func planHistory(interval: DateInterval, credentials: Credentials) async throws -> [PlanSample] { [] }
    func sessions(interval: DateInterval, credentials: Credentials) async throws -> [SessionActivity] { [] }
    func hourlyActivity(interval: DateInterval, credentials: Credentials) async throws -> [HourlyActivity] { [] }

    func isConfigured(_ credentials: Credentials) -> Bool {
        credentialFields.filter { !$0.isOptional }.allSatisfy { field in
            !(credentials[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
