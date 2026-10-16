import Foundation

@main struct MobileNotificationPolicyTests {
    static func main() throws {
        for state in ["QUEUED", "UPLOADING", "UPLOADED", "VERIFYING", "FAILED_RETRYABLE", "CANCELLED"] {
            precondition(TransferNotificationPolicy.backupOutcome(state: state, isResource: false, error: nil) == "active")
        }
        precondition(TransferNotificationPolicy.backupOutcome(state: "PROTECTED", isResource: false, error: nil) == "protected")
        precondition(TransferNotificationPolicy.backupOutcome(state: "PROTECTED", isResource: true, error: nil) == "active")
        precondition(TransferNotificationPolicy.backupOutcome(state: "PAUSED", isResource: false, error: "NETWORK_POLICY") == "active")
        precondition(TransferNotificationPolicy.backupOutcome(state: "PAUSED", isResource: false, error: "WAITING_FOR_ICLOUD_ORIGINAL") == "attention")
        precondition(TransferNotificationPolicy.backupOutcome(state: "PAUSED", isResource: false, error: "LOCAL_ACCESS_UNAVAILABLE") == "attention")
        precondition(TransferNotificationPolicy.manifestOutcome(state: "PARTIALLY_PROTECTED") == "active")
        precondition(TransferNotificationPolicy.manifestOutcome(state: "FULLY_PROTECTED") == "protected")
        precondition(TransferNotificationPolicy.restoreOutcome(state: "SAVING_TO_PHOTOS") == "active")
        precondition(TransferNotificationPolicy.restoreOutcome(state: "RESTORED") == "restored")
        precondition(TransferNotificationPolicy.restoreOutcome(state: "RECONCILE_REQUIRED") == "attention")
        for id in ["transfer.test", "transfer.backup.protected", "transfer.backup.attention", "transfer.restore.restored", "transfer.restore.attention"] {
            precondition(TransferNotificationPolicy.shouldPresentForeground(identifier: id, enabled: true, eventAllowed: true))
            precondition(!TransferNotificationPolicy.shouldPresentForeground(identifier: id, enabled: false, eventAllowed: true))
            precondition(!TransferNotificationPolicy.shouldPresentForeground(identifier: id, enabled: true, eventAllowed: false))
        }
        for id in ["unknown", "transfer.unknown", "transfer.backup.restored", "transfer.restore.protected"] {
            precondition(!TransferNotificationPolicy.shouldPresentForeground(identifier: id, enabled: true, eventAllowed: true))
        }
        var policy = TransferNotificationPolicy()
        // Enabling the feature must not announce existing successes/failures.
        precondition(policy.observe(["old":"protected", "failed":"attention", "new":"active"]).isEmpty)
        precondition(policy.observe(["old":"protected", "failed":"attention", "new":"active"]).isEmpty)
        // Uploading, uploaded-but-unverified, retry waiting and user pauses are non-alert states.
        precondition(policy.observe(["old":"protected", "failed":"attention", "new":"active", "other":"active"]).isEmpty)
        precondition(policy.observe(["old":"protected", "failed":"attention", "new":"protected", "other":"protected"]) == ["protected":2])
        precondition(policy.observe(["old":"protected", "failed":"attention", "new":"protected", "other":"protected"]).isEmpty)
        // Deduplication survives relaunch; new failures and successful restores are distinct.
        var restarted = try JSONDecoder().decode(TransferNotificationPolicy.self, from: JSONEncoder().encode(policy))
        precondition(restarted.observe(policy.states).isEmpty)
        var next = policy.states
        next["restore"] = "restored"; next["newFailure"] = "attention"
        precondition(restarted.observe(next) == ["restored":1, "attention":1])
        // A retry can subsequently succeed without another attention alert.
        next["newFailure"] = "active"
        precondition(restarted.observe(next).isEmpty)
        next["newFailure"] = "protected"
        precondition(restarted.observe(next) == ["protected":1])
        // Separate account/library scopes have separate silent baselines.
        var otherAccount = TransferNotificationPolicy()
        precondition(otherAccount.observe(next).isEmpty)
        // Outcomes beyond the visible 100 rows remain eligible.
        var large = TransferNotificationPolicy()
        var rows = Dictionary(uniqueKeysWithValues: (0..<251).map { ("item-\($0)", "active") })
        precondition(large.observe(rows).isEmpty)
        rows["item-250"] = "protected"
        precondition(large.observe(rows) == ["protected":1])
        print("PASS: notification baseline, verified outcomes, aggregation, relaunch deduplication, retry, account isolation 251-item history and opt-out/session-gated foreground presentation")
    }
}
