import Foundation
import Combine

/// In-memory account state, scoped to the current credential. Never persists credentials or profile data.
@MainActor public final class AccountRefreshModel: ObservableObject {
    @Published public private(set) var account: AccountStatus?
    @Published public private(set) var refreshing = false
    @Published public private(set) var hasSession = false
    @Published public private(set) var message = ""
    private var credential: String?
    private var generation = 0
    private var lastAttempt: Date?
    private let readSession: () throws -> String?
    private let load: () async throws -> AccountStatus
    private let now: () -> Date

    public init(readSession: @escaping () throws -> String?, load: @escaping () async throws -> AccountStatus, now: @escaping () -> Date = Date.init) {
        self.readSession = readSession; self.load = load; self.now = now
        credential = try? readSession(); hasSession = credential != nil
    }
    public func invalidate() {
        generation += 1; credential = nil; account = nil; refreshing = false
        hasSession = false; lastAttempt = nil; message = ""
    }
    public func accept(_ value: AccountStatus) {
        invalidate()
        guard let token = try? readSession() else { return }
        credential = token; hasSession = true; account = value; lastAttempt = now()
    }
    public func refresh(force: Bool = false) async {
        let token: String?
        do { token = try readSession() }
        catch { message = "Account could not be checked. Unlock your device and retry."; return }
        if token != credential { invalidate(); credential = token; hasSession = token != nil }
        guard token != nil else { return }
        guard !refreshing else { return }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 60 { return }
        let epoch = generation
        refreshing = true; lastAttempt = now()
        defer { if epoch == generation { refreshing = false } }
        do {
            let value = try await load()
            guard epoch == generation else { return }
            guard try readSession() == token else { invalidate(); return }
            account = value; message = ""
        } catch {
            guard epoch == generation else { return }
            // A session change must never leave another account's details visible.
            do { if try readSession() != token { invalidate(); return } }
            catch { invalidate(); message = "Account could not be checked. Unlock your device and retry."; return }
            if (error as? AccountAPIError) == .unauthorized { invalidate(); message = "Your session has expired. Sign in again." }
            else if (error as? AccountAPIError) == .invalidConfiguration { invalidate(); message = "Account configuration unavailable." }
            else if error is CancellationError || (error as? URLError)?.code == .cancelled { lastAttempt = nil }
            else { message = account == nil ? "Account could not be loaded. Check your connection and retry." : "Could not update your account. Showing your last loaded details." }
        }
    }
}
