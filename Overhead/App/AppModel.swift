import Foundation
import SwiftUI
import Observation
import OverheadCore

/// Per-provider fetch state shown next to each row.
enum FetchStatus: Equatable {
    case idle
    case loading
    case ok(Date)
    case failed(String)
    case notConfigured
}

@MainActor
@Observable
final class AppModel {
    // MARK: Persisted preferences
    var enabledProviders: Set<ProviderID> {
        didSet { Prefs.enabled = enabledProviders }
    }
    var rangePreset: DateRangePreset {
        didSet { Prefs.rangePreset = rangePreset }
    }
    var refreshMinutes: Int {
        didSet { Prefs.refreshMinutes = refreshMinutes; rescheduleTimer() }
    }
    var menuBarMetric: MenuBarMetric {
        didSet { Prefs.menuBarMetric = menuBarMetric }
    }
    /// How each provider is paid for; drives the "Paid vs value" comparison.
    var billingPlans: [ProviderID: BillingPlan] {
        didSet { Prefs.billingPlans = billingPlans }
    }

    enum MenuBarMetric: String, CaseIterable, Identifiable {
        case todayCost, monthCost, rangeCost
        var id: String { rawValue }
        var title: String {
            switch self {
            case .todayCost: return "Today's cost"
            case .monthCost: return "This month's cost"
            case .rangeCost: return "Selected range cost"
            }
        }
    }

    // MARK: Live state
    private(set) var recordsByProvider: [ProviderID: [UsageRecord]] = [:]
    private(set) var statusByProvider: [ProviderID: FetchStatus] = [:]
    private(set) var credentials: Credentials = [:]
    var selectedProvider: ProviderID? = nil {
        didSet { Prefs.selectedProvider = selectedProvider }
    }
    private(set) var planStatus: [ProviderID: PlanStatus] = [:]
    var lastRefresh: Date? = nil
    var isRefreshing: Bool { statusByProvider.values.contains(.loading) }

    let registry = ProviderRegistry()
    private let cache = UsageCache()
    private let keychain = Keychain(service: AppIdentity.bundleID, legacyServices: AppIdentity.legacyBundleIDs)
    private var timer: Timer?

    init() {
        AppIdentity.migrateDefaultsIfNeeded()
        enabledProviders = Prefs.enabled
        rangePreset = Prefs.rangePreset
        refreshMinutes = Prefs.refreshMinutes
        menuBarMetric = Prefs.menuBarMetric
        billingPlans = Prefs.billingPlans
        selectedProvider = Prefs.selectedProvider
        loadCredentials()
    }

    // MARK: Lifecycle

    func start() async {
        // Show cached data immediately, then refresh in the background.
        for p in ProviderID.allCases {
            if let snap = await cache.load(p) {
                recordsByProvider[p] = snap.records
                statusByProvider[p] = .ok(snap.fetchedAt)
            }
        }
        rescheduleTimer()
        await refreshAll(force: false)
    }

    /// Subscription-plan consumption (Codex rolling windows, Cursor included budget).
    private func loadPlanStatus(_ id: ProviderID) async {
        guard let provider = registry.provider(for: id), provider.isConfigured(credentials) else {
            planStatus[id] = nil
            return
        }
        let creds = credentials
        if let status = try? await provider.planStatus(credentials: creds) {
            planStatus[id] = status
            applyDetectedPlan(status.suggestedPlan, to: id)
        }
    }

    /// Pre-fill the billing plan from what the provider reports, unless the user has edited it.
    private func applyDetectedPlan(_ suggestion: PlanStatus.SuggestedPlan?, to id: ProviderID) {
        guard let suggestion else { return }
        var plan = billingPlan(for: id)
        let userEdited = billingPlans[id] != nil && !plan.autoDetected && (plan.monthlyFeeUSD > 0 || plan.planName != nil)
        if userEdited {
            if plan.planName == nil { plan.planName = suggestion.name; billingPlans[id] = plan }
            return
        }
        plan.kind = .subscription
        plan.planName = suggestion.name
        plan.autoDetected = true
        if let fee = suggestion.monthlyFeeUSD { plan.monthlyFeeUSD = fee }
        billingPlans[id] = plan
    }

    /// Re-adopt the detected tier and price after a manual override.
    func useDetectedPlan(for id: ProviderID) {
        guard let suggestion = planStatus[id]?.suggestedPlan else { return }
        billingPlans[id] = BillingPlan(kind: .subscription, monthlyFeeUSD: suggestion.monthlyFeeUSD ?? 0, autoDetected: true, planName: suggestion.name)
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        guard refreshMinutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Refresh

    func refreshAll(force: Bool) async {
        let targets = ProviderID.allCases.filter { enabledProviders.contains($0) }
        // One child task per provider so a slow API does not block the local parsers.
        let tasks = targets.map { p in Task { await self.refresh(p, force: force) } }
        for t in tasks { await t.value }
        lastRefresh = Date()
    }

    func refresh(_ id: ProviderID, force: Bool) async {
        guard let provider = registry.provider(for: id) else { return }
        guard provider.isConfigured(credentials) else {
            statusByProvider[id] = .notConfigured
            return
        }
        // Skip if the cache is fresh (< 2 minutes) and not forced.
        if !force, case .ok(let at) = statusByProvider[id] ?? .idle, Date().timeIntervalSince(at) < 120 {
            if planStatus[id] == nil { await loadPlanStatus(id) }
            return
        }
        statusByProvider[id] = .loading
        let interval = fetchInterval(for: id)
        let creds = credentials
        do {
            let records = try await provider.fetch(interval: interval, credentials: creds)
            recordsByProvider[id] = records
            statusByProvider[id] = .ok(Date())
            try? await cache.save(id, records: records)
            await loadPlanStatus(id)
        } catch {
            // Keep stale cached data visible, just mark the error.
            statusByProvider[id] = .failed(error.localizedDescription)
        }
    }

    /// API providers are asked for the last 90 days so every preset is covered by one fetch.
    private func fetchInterval(for id: ProviderID) -> DateInterval {
        DateRangePreset.last90.interval()
    }

    // MARK: Derived data

    var currentInterval: DateInterval { rangePreset.interval() }

    var allRecords: [UsageRecord] {
        recordsByProvider
            .filter { enabledProviders.contains($0.key) }
            .values.flatMap { $0 }
    }

    var recordsInRange: [UsageRecord] {
        UsageAggregator.filter(allRecords, in: currentInterval)
    }

    func records(for provider: ProviderID) -> [UsageRecord] {
        UsageAggregator.filter(recordsByProvider[provider] ?? [], in: currentInterval)
    }

    var activeProviders: [ProviderID] {
        ProviderID.allCases.filter { enabledProviders.contains($0) }
    }

    /// Providers that actually have data in the current range, in canonical order.
    var providersWithData: [ProviderID] {
        let present = Set(recordsInRange.map(\.provider))
        return ProviderID.allCases.filter { present.contains($0) }
    }

    func cost(in interval: DateInterval) -> UsageRecord.Cost {
        UsageAggregator.totals(UsageAggregator.filter(allRecords, in: interval)).cost
    }

    var menuBarCost: UsageRecord.Cost {
        switch menuBarMetric {
        case .todayCost: return cost(in: DateRangePreset.today.interval())
        case .monthCost: return cost(in: DateRangePreset.thisMonth.interval())
        case .rangeCost: return cost(in: currentInterval)
        }
    }

    // MARK: Paid vs value

    func billingPlan(for id: ProviderID) -> BillingPlan {
        billingPlans[id] ?? .default(for: id)
    }

    struct PaidVsValue: Identifiable {
        let provider: ProviderID
        let plan: BillingPlan
        /// Prorated subscription fee, or billed cost for pay-per-use. nil when unknown.
        let paid: Double?
        /// API-equivalent value (subscription) or billed cost (pay-per-use).
        let value: UsageRecord.Cost
        var id: ProviderID { provider }
        var multiple: Double? {
            guard let paid, paid > 0, let v = value.value else { return nil }
            return v / paid
        }
    }

    func paidVsValue(in interval: DateInterval, providers: [ProviderID]) -> [PaidVsValue] {
        let records = UsageAggregator.filter(allRecords, in: interval)
        let byProvider = UsageAggregator.totalsByProvider(records)
        return providers.map { p in
            let plan = billingPlan(for: p)
            let value = byProvider[p]?.cost ?? .unknown
            let paid: Double?
            if plan.isSubscription {
                paid = plan.paid(in: interval)
            } else if case .reported(let v) = value {
                paid = v
            } else {
                paid = nil
            }
            return PaidVsValue(provider: p, plan: plan, paid: paid, value: value)
        }
    }

    struct PaidSummary {
        var fees: Double = 0
        var billed: Double = 0
        var missingFee: [ProviderID] = []
        var total: Double { fees + billed }
    }

    func paidSummary(in interval: DateInterval, providers: [ProviderID]) -> PaidSummary {
        var out = PaidSummary()
        for row in paidVsValue(in: interval, providers: providers) {
            if row.plan.isSubscription {
                if let paid = row.paid { out.fees += paid } else { out.missingFee.append(row.provider) }
            } else if let paid = row.paid {
                out.billed += paid
            }
        }
        return out
    }

    // MARK: Credentials

    private func loadCredentials() {
        var creds: Credentials = [:]
        for p in ProviderID.allCases {
            guard let provider = registry.provider(for: p) else { continue }
            for field in provider.credentialFields {
                if let v = try? keychain.read(account: field.key), !v.isEmpty {
                    creds[field.key] = v
                }
            }
        }
        credentials = creds
    }

    func setCredential(_ key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials[key] = nil
            try? keychain.delete(account: key)
        } else {
            credentials[key] = trimmed
            try? keychain.write(account: key, value: trimmed)
        }
    }

    func clearData(for id: ProviderID) async {
        recordsByProvider[id] = nil
        planStatus[id] = nil
        statusByProvider[id] = .idle
        await cache.clear(id)
    }
}

// MARK: - UserDefaults-backed preferences

@MainActor
private enum Prefs {
    private static let d = UserDefaults.standard

    static var enabled: Set<ProviderID> {
        get {
            guard let raw = d.array(forKey: "enabledProviders") as? [String] else {
                // First launch: enable the local, zero-config sources.
                return [.claudeCode, .codexCLI]
            }
            return Set(raw.compactMap(ProviderID.init(rawValue:)))
        }
        set { d.set(newValue.map(\.rawValue).sorted(), forKey: "enabledProviders") }
    }

    static var rangePreset: DateRangePreset {
        get { DateRangePreset(rawValue: d.string(forKey: "rangePreset") ?? "") ?? .last30 }
        set { d.set(newValue.rawValue, forKey: "rangePreset") }
    }

    static var refreshMinutes: Int {
        get { d.object(forKey: "refreshMinutes") == nil ? 15 : d.integer(forKey: "refreshMinutes") }
        set { d.set(newValue, forKey: "refreshMinutes") }
    }

    static var selectedProvider: ProviderID? {
        get { d.string(forKey: "selectedProvider").flatMap(ProviderID.init(rawValue:)) }
        set { d.set(newValue?.rawValue ?? "", forKey: "selectedProvider") }
    }

    static var billingPlans: [ProviderID: BillingPlan] {
        get {
            // Stored as JSON data; a string is accepted too so a launch argument can override it.
            let data: Data?
            switch d.object(forKey: "billingPlans") {
            case let x as Data: data = x
            case let x as String: data = Data(x.utf8)
            case let x as [String: Any]:  // launch-argument plist form: numbers come through as strings
                let coerced = x.mapValues { v -> Any in
                    guard var plan = v as? [String: Any] else { return v }
                    if let fee = plan["monthlyFeeUSD"] as? String { plan["monthlyFeeUSD"] = Double(fee) ?? 0 }
                    return plan
                }
                data = try? JSONSerialization.data(withJSONObject: coerced)
            default: data = nil
            }
            guard let data, let raw = try? JSONDecoder().decode([String: BillingPlan].self, from: data) else { return [:] }
            var out: [ProviderID: BillingPlan] = [:]
            for (k, v) in raw { if let id = ProviderID(rawValue: k) { out[id] = v } }
            return out
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            d.set(try? JSONEncoder().encode(raw), forKey: "billingPlans")
        }
    }

    static var menuBarMetric: AppModel.MenuBarMetric {
        get { AppModel.MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .todayCost }
        set { d.set(newValue.rawValue, forKey: "menuBarMetric") }
    }
}
