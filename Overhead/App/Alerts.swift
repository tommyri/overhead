import Foundation
import UserNotifications
import OverheadCore

/// A plan window that deserves attention: past the user's threshold, or on pace to run out
/// before it resets.
struct PlanAlert: Identifiable, Hashable {
    enum Level: Int, Comparable { case warning = 1, critical = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue } }

    let provider: ProviderID
    let window: PlanStatus.Window
    let level: Level
    let projection: Forecast.WindowProjection?

    var id: String { "\(provider.rawValue)|\(window.title)" }

    var headline: String {
        "\(provider.displayName): \(window.title.lowercased()) at \(Int(window.usedPercent.rounded()))%"
    }

    var detail: String {
        var parts: [String] = []
        if let p = projection, let at = p.exhaustsAt, window.usedPercent < 100 {
            parts.append("At this pace it runs out \(at.formatted(.relative(presentation: .named)))")
        } else if window.usedPercent >= 100 {
            parts.append("Limit reached")
        }
        if let reset = window.resetsAt {
            parts.append("resets \(reset.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// Decide whether a window warrants an alert at the given threshold.
    static func evaluate(provider: ProviderID, window: PlanStatus.Window, threshold: Int, now: Date = Date()) -> PlanAlert? {
        let projection = Forecast.project(window, now: now)
        let onPaceToRunOut = (projection?.exhaustsAt != nil) && window.usedPercent >= 50
        let level: Level?
        if window.usedPercent >= 95 { level = .critical }
        else if window.usedPercent >= Double(threshold) || onPaceToRunOut { level = .warning }
        else { level = nil }
        guard let level else { return nil }
        return PlanAlert(provider: provider, window: window, level: level, projection: projection)
    }
}

/// Delivers one macOS notification per window and level per period, never repeating.
@MainActor
final class AlertNotifier {
    private let defaultsKey = "notifiedPlanAlerts"
    private var sent: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private(set) var authorized: Bool? = nil

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func requestAuthorization() async -> Bool {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            authorized = ok
            return ok
        } catch {
            authorized = false
            return false
        }
    }

    /// Notify for alerts not yet announced at this level in this period.
    func deliver(_ alerts: [PlanAlert]) {
        var record = sent
        for a in alerts {
            let period = a.window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            let stamp = "\(a.level.rawValue)|\(period)"
            guard record[a.id] != stamp else { continue }
            // Allow a critical notification after a warning one, but not the other way round.
            if let previous = record[a.id], previous.hasSuffix("|\(period)"),
               let prevLevel = Int(previous.split(separator: "|").first ?? ""), prevLevel >= a.level.rawValue { continue }
            record[a.id] = stamp
            post(title: a.headline, body: a.detail, id: a.id)
        }
        // Forget windows that are no longer alerting so a future period can notify again.
        let active = Set(alerts.map(\.id))
        for key in record.keys where !active.contains(key) { record[key] = nil }
        sent = record
    }

    func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
