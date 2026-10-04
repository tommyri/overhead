import SwiftUI
import ServiceManagement
import OverheadCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings()
                .tabItem { Label("Providers", systemImage: "rectangle.stack") }
            PricingSettings()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem()

    private var alertsNote: String {
        if model.alertsEnabled, model.notifier.authorized == false {
            return "Notifications are blocked for Overhead in System Settings → Notifications."
        }
        return "Also alerts when a window is on pace to run out before it resets. Codex and Cursor report windows; Claude Code's need the status-line helper (Providers → Claude Code)."
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let note = loginItem.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Show in Dock", isOn: $model.showInDock)
                Text("Off keeps Overhead in the menu bar only. The Dock icon and the app menu come back while a window is open and disappear again when you close it; use the menu bar item to open the window.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Plan-limit alerts", isOn: Binding(
                    get: { model.alertsEnabled },
                    set: { on in
                        if on { Task { _ = await model.enableAlerts() } } else { model.alertsEnabled = false }
                    }
                ))
                Picker("Notify when a window passes", selection: $model.alertThreshold) {
                    Text("70%").tag(70)
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                }
                .disabled(!model.alertsEnabled)
                HStack {
                    Text(alertsNote).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send test") { model.sendTestNotification() }.disabled(!model.alertsEnabled)
                }
            }
            Picker("Refresh every", selection: $model.refreshMinutes) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Manually").tag(0)
            }
            Picker("Menu bar shows", selection: $model.menuBarMetric) {
                ForEach(AppModel.MenuBarMetric.allCases) { Text($0.title).tag($0) }
            }
            Section {
                LabeledContent("Cache") {
                    Button("Clear cached data") {
                        Task { for p in ProviderID.allCases { await model.clearData(for: p) }; await model.refreshAll(force: true) }
                    }
                }
                LabeledContent("Credentials") {
                    Text("Stored in the macOS Keychain under “\(AppIdentity.bundleID)”.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ProviderID = UserDefaults.standard.string(forKey: "settingsProvider").flatMap(ProviderID.init(rawValue:)) ?? .claudeCode

    var body: some View {
        HSplitView {
            List(ProviderID.allCases, selection: $selected) { p in
                HStack {
                    Circle().fill(p.color).frame(width: 9, height: 9)
                    Text(p.displayName)
                    Spacer()
                    if model.enabledProviders.contains(p) {
                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(p)
            }
            .frame(minWidth: 170, maxWidth: 200)

            ProviderSettingsPane(provider: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProviderSettingsPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderID
    @State private var drafts: [String: String] = [:]
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var feeText: String = ""
    @State private var planNameText: String = ""
    /// What the fields were last loaded with, so programmatic loads never count as edits.
    @State private var loadedFeeText: String = ""
    @State private var loadedPlanNameText: String = ""

    private var fields: [CredentialField] {
        model.registry.provider(for: provider)?.credentialFields ?? []
    }
    private var imports: [CredentialImport] {
        model.registry.provider(for: provider)?.credentialImports ?? []
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.enabledProviders.contains(provider) },
                    set: { on in
                        if on { model.enabledProviders.insert(provider) } else { model.enabledProviders.remove(provider) }
                        if on { Task { await model.refresh(provider, force: true) } }
                    }
                )) {
                    Text("Enabled")
                }
                Text(provider.setupHint).font(.callout).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Circle().fill(provider.color).frame(width: 10, height: 10)
                    Text(provider.displayName)
                    Text(provider.kind == .local ? "Local logs" : "API")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if !fields.isEmpty {
                Section("Credentials") {
                    ForEach(fields) { f in
                        if f.isPlainText {
                            TextField(f.label, text: binding(f), prompt: Text(f.placeholder))
                        } else {
                            SecureField(f.label, text: binding(f), prompt: Text(f.placeholder))
                        }
                        if let imp = imports.first(where: { $0.fieldKey == f.key }) {
                            HStack(alignment: .firstTextBaseline) {
                                Button(imp.buttonTitle) { runImport(imp) }
                                Text(imp.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("Save & test") { save(andTest: true) }
                            .buttonStyle(.borderedProminent)
                            .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let testResult {
                            Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button("Remove") {
                            for f in fields { model.setCredential(f.key, value: "") }
                            drafts = [:]; testResult = nil
                        }
                        .disabled(fields.allSatisfy { (model.credentials[$0.key] ?? "").isEmpty })
                    }
                }
            }

            if provider == .claudeCode {
                ClaudeStatusLineSection()
            }

            Section("Billing") {
                let plan = model.billingPlan(for: provider)
                Picker("Billed as", selection: Binding(
                    get: { plan.kind },
                    set: { kind in var p = plan; p.kind = kind; model.billingPlans[provider] = p }
                )) {
                    ForEach(BillingPlan.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if plan.isSubscription {
                    TextField("Plan", text: $planNameText, prompt: Text("e.g. Cursor Pro+"))
                        .onChange(of: planNameText) { _, _ in commitPlanName() }
                    HStack {
                        TextField("Monthly fee", text: $feeText, prompt: Text("e.g. 60"))
                            .onSubmit { commitFee() }
                            .onChange(of: feeText) { _, _ in commitFee() }
                        Text("USD / month").foregroundStyle(.secondary)
                    }
                    if let detected = model.planStatus[provider]?.suggestedPlan {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: plan.autoDetected ? "checkmark.circle" : "info.circle").foregroundStyle(.secondary)
                            Text(detectedText(detected, plan: plan)).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if !plan.autoDetected {
                                Button("Use detected") { model.useDetectedPlan(for: provider); loadFee() }
                            }
                        }
                    } else {
                        Text("Tier not detected; enter your plan and fee.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Token figures for this source are API-equivalent value, not spend. The fee is what you actually pay; both appear under “Paid vs value”, with the fee prorated to the selected range.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Costs reported by this provider are what you pay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                let status = model.statusByProvider[provider] ?? .idle
                HStack {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                    Text(status.text).lineLimit(3)
                }
                let count = model.recordsByProvider[provider]?.count ?? 0
                if count > 0 {
                    Text("\(count) day/model records cached").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadDrafts(); loadFee() }
        .onChange(of: provider) { _, _ in loadDrafts(); loadFee(); testResult = nil }
        .onChange(of: model.billingPlan(for: provider)) { _, _ in
            // Detection (or another window) changed the plan: refresh the fields unless mid-edit.
            if feeText == loadedFeeText && planNameText == loadedPlanNameText { loadFee() }
        }
    }

    private func loadFee() {
        let plan = model.billingPlan(for: provider)
        let fee = plan.monthlyFeeUSD
        feeText = fee > 0 ? (fee == fee.rounded() ? String(Int(fee)) : String(fee)) : ""
        planNameText = plan.planName ?? ""
        loadedFeeText = feeText
        loadedPlanNameText = planNameText
    }

    private func detectedText(_ d: PlanStatus.SuggestedPlan, plan: BillingPlan) -> String {
        let price = d.monthlyFeeUSD.map { Fmt.usd($0) + "/month" } ?? "price not known"
        if plan.autoDetected {
            return "Detected from \(d.source): \(d.name), \(price). Edit to override."
        }
        return "Your account reports \(d.name), \(price). Using your manual values."
    }

    private func commitPlanName() {
        guard planNameText != loadedPlanNameText else { return }
        var plan = model.billingPlan(for: provider)
        let name = planNameText.trimmingCharacters(in: .whitespaces)
        let newName: String? = name.isEmpty ? nil : name
        guard plan.planName != newName else { return }
        plan.planName = newName
        if newName != model.planStatus[provider]?.suggestedPlan?.name { plan.autoDetected = false }
        model.billingPlans[provider] = plan
        loadedPlanNameText = planNameText
    }

    private func commitFee() {
        guard feeText != loadedFeeText else { return }
        let cleaned = feeText.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        let fee = Double(cleaned) ?? 0
        var plan = model.billingPlan(for: provider)
        if plan.monthlyFeeUSD != fee {
            plan.monthlyFeeUSD = max(0, fee)
            plan.autoDetected = false     // a typed fee is never overwritten by detection
            model.billingPlans[provider] = plan
        }
        loadedFeeText = feeText
    }

    private func binding(_ f: CredentialField) -> Binding<String> {
        Binding(get: { drafts[f.key] ?? "" }, set: { drafts[f.key] = $0 })
    }

    private func loadDrafts() {
        drafts = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, model.credentials[$0.key] ?? "") })
    }

    private func runImport(_ imp: CredentialImport) {
        do {
            drafts[imp.fieldKey] = try imp.run()
            testResult = "Imported. Press “Save & test” to use it."
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func save(andTest: Bool) {
        for f in fields { model.setCredential(f.key, value: drafts[f.key] ?? "") }
        model.enabledProviders.insert(provider)
        guard andTest else { return }
        testing = true; testResult = nil
        Task {
            await model.refresh(provider, force: true)
            testing = false
            testResult = (model.statusByProvider[provider] ?? .idle).text
        }
    }
}

struct PricingSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated costs").font(.headline)
            Text("Local sources (Claude Code, Codex CLI) do not record what you were billed. The app multiplies their token counts by the vendors' published list prices; figures marked ≈ are such estimates. For subscription plans this is API-equivalent value, not spend: enter each plan's monthly fee under Providers → Billing to see paid vs value. API sources report billed cost directly.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Price table (USD per million tokens)").font(.headline).padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Input").frame(width: 70, alignment: .trailing)
                        Text("Output").frame(width: 70, alignment: .trailing)
                        Text("Cache w").frame(width: 70, alignment: .trailing)
                        Text("Cache r").frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    Divider()
                    ForEach(PriceTable.all, id: \.pattern) { p in
                        HStack {
                            Text(p.pattern).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(fmt(p.input)).frame(width: 70, alignment: .trailing)
                            Text(fmt(p.output)).frame(width: 70, alignment: .trailing)
                            Text(fmt(p.cacheWrite)).frame(width: 70, alignment: .trailing)
                            Text(fmt(p.cacheRead)).frame(width: 70, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit()).padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            Text("Prices last reviewed \(PriceTable.lastReviewed). Edit OverheadCore/Pricing/PriceTable.swift to update.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 1 ? String(format: "%.3f", v) : String(format: "%.2f", v)
    }
}


/// Wraps SMAppService so the toggle reflects the real registration state, including the
/// case where macOS wants the user to approve the login item in System Settings.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String? = nil

    var isEnabled: Bool { status == .enabled }

    var note: String? {
        if let lastError { return lastError }
        switch status {
        case .requiresApproval:
            return "Approval needed: allow “Overhead” under System Settings → General → Login Items."
        default:
            // .notRegistered and .notFound both mean "off"; .notFound is what macOS reports
            // before the app has ever been registered.
            return "Starts the menu bar item when you log in."
        }
    }

    func setEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}


/// Install/remove the status-line helper that records Claude's 5-hour and weekly windows.
struct ClaudeStatusLineSection: View {
    @Environment(AppModel.self) private var model
    @State private var status = ClaudeStatusLine.status()
    @State private var message: String? = nil

    var body: some View {
        Section("Plan windows") {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: status.installed ? "checkmark.circle.fill" : "circle").foregroundStyle(status.installed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.installed ? "Status-line helper installed" : "Status-line helper not installed")
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.installed {
                    Button("Remove") { run { try model.removeClaudeStatusLine() } }
                } else {
                    Button("Install") { run { try model.installClaudeStatusLine() } }.buttonStyle(.borderedProminent)
                }
            }
            Text("Claude Code only exposes your plan's 5-hour and weekly windows to its status-line command. Installing sets that command in ~/.claude/settings.json (a backup is kept) to a small helper that records the windows for Overhead and otherwise shows a normal status line; an existing status line keeps working through it. Windows appear after Claude Code's next response.")
                .font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .onAppear { status = ClaudeStatusLine.status() }
    }

    private var detail: String {
        var parts: [String] = []
        if let chained = status.chainedCommand { parts.append("Chains to: \(chained)") }
        if let last = status.lastRecord {
            parts.append(status.hasWindows ? "Windows recorded \(Fmt.relative(last))" : "Status line ran \(Fmt.relative(last)), no windows reported by Claude Code")
        } else if status.installed { parts.append("Not run yet; use Claude Code once") }
        return parts.isEmpty ? "Not configured in ~/.claude/settings.json" : parts.joined(separator: " · ")
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
        status = ClaudeStatusLine.status()
        Task { await model.refresh(.claudeCode, force: true) }
    }
}
