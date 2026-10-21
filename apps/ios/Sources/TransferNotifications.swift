import SwiftUI
import UserNotifications
import UIKit

@MainActor final class TransferNotifications: ObservableObject {
    static let shared = TransferNotifications()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "transferAlertsEnabled")
    @Published private(set) var status = "Checking notification permission…"
    @Published private(set) var denied = false
    @Published private(set) var requestingPermission = false
    private let center = UNUserNotificationCenter.current()
    private var generation = 0
    private var testNotificationActive = false
    private var activeScopes: Set<String> = []
    private var policies: [String: TransferNotificationPolicy] = [:]

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        denied = settings.authorizationStatus == .denied
        switch settings.authorizationStatus {
        case .denied: status = "Notifications are blocked in Settings."
        case .notDetermined: status = "Turn on transfer alerts to allow notifications."
        default: status = enabled ? "Transfer alerts are on." : "Transfer alerts are off."
        }
    }
    func setEnabled(_ value: Bool) async {
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        if value {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    enabled = false
                    UserDefaults.standard.set(false, forKey: "transferAlertsEnabled")
                    await refreshPermission(); return
                }
            } catch { status = "Notification permission could not be checked. Try again."; return }
        }
        if !value { generation += 1 }
        enabled = value
        UserDefaults.standard.set(value, forKey: "transferAlertsEnabled")
        if !value { clearDelivered() }
        await refreshPermission()
    }
    func sendTest() async {
        let currentGeneration = generation
        let settings = await center.notificationSettings()
        guard enabled, currentGeneration == generation,
              [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            await refreshPermission(); return
        }
        let content = UNMutableNotificationContent()
        content.title = "Acloud notification test"
        content.body = "Notifications are working. This test does not change your backups."
        content.sound = .default
        testNotificationActive = true
        do {
            try await center.add(UNNotificationRequest(identifier: "transfer.test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            if !enabled || currentGeneration != generation { clearDelivered(); return }
            status = "Test scheduled for five seconds from now. Keep Acloud open to check its banner, or lock the screen to check the lock-screen alert."
        } catch { testNotificationActive = false; status = "The test alert could not be scheduled. Try again." }
    }
    func mayPresentForeground(_ identifier: String) -> Bool {
        let eventAllowed: Bool
        if identifier == "transfer.test" { eventAllowed = testNotificationActive }
        else if identifier.hasPrefix("transfer.backup.") { eventAllowed = activeScopes.contains { $0.hasPrefix("backup.") } }
        else if identifier.hasPrefix("transfer.restore.") { eventAllowed = activeScopes.contains { $0.hasPrefix("restore.") } }
        else { eventAllowed = false }
        return TransferNotificationPolicy.shouldPresentForeground(identifier: identifier, enabled: enabled, eventAllowed: eventAllowed)
    }
    func activate(_ scope: String) { activeScopes.insert(scope) }
    func signOut() {
        generation += 1
        activeScopes.removeAll()
        policies.removeAll()
        clearDelivered()
    }
    private func clearDelivered() {
        testNotificationActive = false
        // This app schedules only transfer alerts. Clear them on opt-out/sign-out.
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    func observe(scope: String, snapshot: [String: String]) async {
        guard activeScopes.contains(scope) else { return }
        let key = "transferAlertState." + scope
        var policy = policies[scope] ?? UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(TransferNotificationPolicy.self, from: $0) }
            ?? TransferNotificationPolicy()
        guard !policy.initialized || policy.states != snapshot else { return }
        let events = policy.observe(snapshot)
        policies[scope] = policy
        if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: key) }
        guard enabled, !events.isEmpty else { return }
        let currentGeneration = generation
        let settings = await center.notificationSettings()
        guard enabled, currentGeneration == generation, activeScopes.contains(scope),
              [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        for (event, count) in events.sorted(by: { $0.key < $1.key }) {
            let content = UNMutableNotificationContent()
            switch event {
            case "protected":
                content.title = "Backup verified"
                content.body = count == 1 ? "An item is now protected in Acloud." : "\(count) items are now protected in Acloud."
            case "restored":
                content.title = "Restore complete"
                content.body = count == 1 ? "An item was saved to Photos." : "\(count) items were saved to Photos."
            default:
                content.title = "A transfer needs attention"
                content.body = "Open Acloud to review your transfers. Your originals have not been deleted."
            }
            let tab = scope.hasPrefix("restore.") ? "restore" : "backup"
            content.userInfo = ["transferTab": tab]
            content.threadIdentifier = "transfer." + tab
            content.sound = .default
            // Coalesce each outcome; no asset IDs, filenames, URLs or account details in payloads.
            let id = "transfer." + tab + "." + event
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
            catch { status = "An alert could not be scheduled. Check your transfers in the app." }
            if !enabled || currentGeneration != generation {
                clearDelivered(); return
            }
        }
    }
}

struct TransferNotificationSettings: View {
    @ObservedObject private var alerts = TransferNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Section("Notifications") {
            Toggle("Transfer alerts", isOn: Binding(get: { alerts.enabled }, set: { value in
                Task { await alerts.setEnabled(value) }
            })).disabled(alerts.requestingPermission)
            if alerts.enabled && !alerts.denied {
                Button("Try a notification") { Task { await alerts.sendTest() } }
            }
            Text(alerts.status).font(.footnote)
            Text("Get alerts when backups and restores finish or need attention. Background delivery depends on iOS. Photo names and previews stay private.").font(.footnote).foregroundStyle(.secondary)
            if alerts.denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }.task { await alerts.refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await alerts.refreshPermission() } }
        }
    }
}
