import Foundation

// Only opaque queue IDs and coarse states are persisted; never media metadata.
struct TransferNotificationPolicy: Codable {
    static func backupOutcome(state: String, isResource: Bool, error: String?) -> String {
        if state == "PROTECTED", !isResource { return "protected" }
        if state == "FAILED_PERMANENT" || (state == "PAUSED" &&
            ["WAITING_FOR_ICLOUD_ORIGINAL", "LOCAL_ACCESS_UNAVAILABLE"].contains(error ?? "")) { return "attention" }
        return "active"
    }
    static func manifestOutcome(state: String) -> String {
        if ["FULLY_PROTECTED", "RESTORE_READY"].contains(state) { return "protected" }
        if ["SOURCE_CHANGED", "UNSUPPORTED", "ERROR", "INCOMPLETE"].contains(state) { return "attention" }
        return "active"
    }
    static func restoreOutcome(state: String) -> String {
        if state == "RESTORED" { return "restored" }
        if ["FAILED_PERMANENT", "RECONCILE_REQUIRED"].contains(state) { return "attention" }
        return "active"
    }
    var states: [String: String] = [:]
    var initialized = false
    mutating func observe(_ snapshot: [String: String]) -> [String: Int] {
        defer { states = snapshot; initialized = true }
        guard initialized else { return [:] } // Do not announce historical transfers.
        var events: [String: Int] = [:]
        for (id, state) in snapshot where states[id] != state {
            if ["protected", "restored", "attention"].contains(state) {
                events[state, default: 0] += 1
            }
        }
        return events
    }
}
