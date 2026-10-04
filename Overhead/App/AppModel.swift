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
    /// Synthetic data for screenshots (`-demoData YES`); nothing is read, fetched or saved.
    let isDemo = DemoData.isEnabled

    // MARK: Persisted preferences
    var enabledProviders: Set<ProviderID> {
        didSet { if !isDemo { Prefs.enabled = enabledProviders } }
    }
    var rangePreset: DateRangePreset {
        didSet { if !isDemo { Prefs.rangePreset = rangePreset } }
    }
    var refreshMinutes: Int {
        didSet { if !isDemo { Prefs.refreshMinutes = refreshMinutes }; rescheduleTimer() }
    }
    var menuBarMetric: MenuBarMetric {
        didSet { if !isDemo { Prefs.menuBarMetric = menuBarMetric } }
    }
    /// How each provider is paid for; drives the "Paid vs value" comparison.
    var billingPlans: [ProviderID: BillingPlan] {
        didSet { if !isDemo { Prefs.billingPlans = billingPlans } }
    }
    /// Plan-limit alerts: macOS notifications when a window passes `alertThreshold` percent
    /// or is on pace to run out before it resets.
    var alertsEnabled: Bool {
        didSet { if !isDemo { Prefs.alertsEnabled = alertsEnabled }; evaluateAlerts() }
    }
    var alertThreshold: Int {
        didSet { if !isDemo { Prefs.alertThreshold = alertThreshold }; evaluateAlerts() }
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
    private(set) var codeByProvider: [ProviderID: [CodeActivity]] = [:]
    private(set) var toolsByProvider: [ProviderID: [ToolActivity]] = [:]
    private(set) var statusByProvider: [ProviderID: FetchStatus] = [:]
    private(set) var credentials: Credentials = [:]
    var selectedProvider: ProviderID? = nil {
        didSet { if !isDemo { Prefs.selectedProvider = selectedProvider } }
    }

    /// Sidebar destination. `nil` provider = Overview.
    enum Page: Hashable {
        case overview
        case provider(ProviderID)
    }
    var selectedPage: Page {
        get { selectedProvider.map(Page.provider) ?? .overview }
        set { if case .provider(let p) = newValue { selectedProvider = p } else { selectedProvider = nil } }
    }
    private(set) var planStatus: [ProviderID: PlanStatus] = [:]
    private(set) var activeAlerts: [PlanAlert] = []
    let notifier = AlertNotifier()
    var lastRefresh: Date? = nil
    var isRefreshing: Bool { statusByProvider.values.contains(.loading) }

    let registry = ProviderRegistry()
    private let cache = UsageCache()
    private let keychain = Keychain(service: AppIdentity.bundleID, legacyServices: AppIdentity.legacyBundleIDs)
    private var timer: Timer?

    init() {
        if DemoData.isEnabled {
            enabledProviders = Set(DemoData.providers)
            rangePreset = .last30
            refreshMinutes = 0
            menuBarMetric = .todayCost
            billingPlans = DemoData.billingPlans
            alertsEnabled = true
            alertThreshold = 80
            selectedProvider = Prefs.selectedProvider   // honoured from launch arguments, never written
            return
        }
        AppIdentity.migrateDefaultsIfNeeded()
        enabledProviders = Prefs.enabled
        rangePreset = Prefs.rangePreset
        refreshMinutes = Prefs.refreshMinutes
        menuBarMetric = Prefs.menuBarMetric
        billingPlans = Prefs.billingPlans
        alertsEnabled = Prefs.alertsEnabled
        alertThreshold = Prefs.alertThreshold
        selectedProvider = Prefs.selectedProvider
        loadCredentials()
    }

    // MARK: Lifecycle

    func start() async {
        if isDemo {
            let all = DemoData.records()
            let allCode = DemoData.codeActivity()
            let allTools = DemoData.toolActivity()
            for p in DemoData.providers {
                recordsByProvider[p] = all.filter { $0.provider == p }
                codeByProvider[p] = allCode.filter { $0.provider == p }
                toolsByProvider[p] = allTools.filter { $0.provider == p }
                statusByProvider[p] = .ok(Date().addingTimeInterval(-90))
                planStatus[p] = DemoData.planStatus(for: p)
            }
            lastRefresh = Date().addingTimeInterval(-90)
            evaluateAlerts()
            return
        }
        if alertsEnabled { await notifier.refreshAuthorization() }
        // Show cached data immediately, then refresh in the background.
        for p in ProviderID.allCases {
            if let snap = await cache.load(p) {
                recordsByProvider[p] = snap.records
                codeByProvider[p] = snap.code
                toolsByProvider[p] = snap.tools
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
            evaluateAlerts()
        }
    }

    // MARK: Claude status-line helper

    var claudeStatusLine: ClaudeStatusLine.Status { ClaudeStatusLine.status() }

    /// The helper binary shipped inside the app bundle.
    static var bundledStatusLineHelper: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "overhead-statusline")
    }

    func installClaudeStatusLine() throws {
        guard let source = Self.bundledStatusLineHelper else { throw ClaudeStatusLine.InstallError.helperMissing("app bundle") }
        try ClaudeStatusLine.install(helperSource: source)
    }

    func removeClaudeStatusLine() throws {
        try ClaudeStatusLine.remove()
    }

    // MARK: Alerts

    /// Recompute which windows are alerting; notify about new ones when alerts are on.
    func evaluateAlerts() {
        var alerts: [PlanAlert] = []
        for (provider, status) in planStatus where enabledProviders.contains(provider) {
            for w in status.windows {
                if let a = PlanAlert.evaluate(provider: provider, window: w, threshold: alertThreshold) { alerts.append(a) }
            }
        }
        alerts.sort { ($0.level, $0.window.usedPercent) > ($1.level, $1.window.usedPercent) }
        activeAlerts = alerts
        if alertsEnabled && !isDemo { notifier.deliver(alerts) }
    }

    var hasAlerts: Bool { !activeAlerts.isEmpty }

    /// Turn alerts on, asking macOS for notification permission first.
    func enableAlerts() async -> Bool {
        let ok = await notifier.requestAuthorization()
        alertsEnabled = ok
        return ok
    }

    func sendTestNotification() {
        notifier.post(title: "Overhead alerts are on", body: "You'll be told when a plan window passes \(alertThreshold)% or is on pace to run out.", id: "test")
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
        guard !isDemo else { lastRefresh = Date(); return }
        let targets = ProviderID.allCases.filter { enabledProviders.contains($0) }
        // One child task per provider so a slow API does not block the local parsers.
        let tasks = targets.map { p in Task { await self.refresh(p, force: force) } }
        for t in tasks { await t.value }
        lastRefresh = Date()
    }

    func refresh(_ id: ProviderID, force: Bool) async {
        guard !isDemo else { return }
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
            let code = (try? await provider.codeActivity(interval: interval, credentials: creds)) ?? []
            codeByProvider[id] = code
            let tools = (try? await provider.toolActivity(interval: interval, credentials: creds)) ?? []
            toolsByProvider[id] = tools
            statusByProvider[id] = .ok(Date())
            try? await cache.save(id, records: records, code: code, tools: tools)
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

    var allCode: [CodeActivity] {
        codeByProvider.filter { enabledProviders.contains($0.key) }.values.flatMap { $0 }
    }

    var codeInRange: [CodeActivity] {
        UsageAggregator.filter(allCode, in: currentInterval)
    }

    func code(for provider: ProviderID) -> [CodeActivity] {
        UsageAggregator.filter(codeByProvider[provider] ?? [], in: currentInterval)
    }

    var allTools: [ToolActivity] {
        toolsByProvider.filter { enabledProviders.contains($0.key) }.values.flatMap { $0 }
    }

    var toolsInRange: [ToolActivity] {
        UsageAggregator.filter(allTools, in: currentInterval)
    }

    func tools(for provider: ProviderID) -> [ToolActivity] {
        UsageAggregator.filter(toolsByProvider[provider] ?? [], in: currentInterval)
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
        codeByProvider[id] = nil
        toolsByProvider[id] = nil
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

    static var alertsEnabled: Bool {
        get { d.bool(forKey: "alertsEnabled") }
        set { d.set(newValue, forKey: "alertsEnabled") }
    }

    static var alertThreshold: Int {
        get { d.object(forKey: "alertThreshold") == nil ? 80 : d.integer(forKey: "alertThreshold") }
        set { d.set(newValue, forKey: "alertThreshold") }
    }

    static var menuBarMetric: AppModel.MenuBarMetric {
        get { AppModel.MenuBarMetric(rawValue: d.string(forKey: "menuBarMetric") ?? "") ?? .todayCost }
        set { d.set(newValue.rawValue, forKey: "menuBarMetric") }
    }
}
