import XCTest
@testable import HealthClient

@MainActor final class AccountRefreshTests: XCTestCase {
    private func user(_ id: String = "a") -> AccountStatus {
        AccountStatus(id: id, email: "test@example.invalid", emailVerified: true, status: "ACTIVE")
    }
    func testFreshAppearanceSkipsRequestsAndForceRefreshes() async {
        var calls = 0
        var clock = Date(timeIntervalSince1970: 100)
        let model = AccountRefreshModel(readSession: { "session" }, load: { calls += 1; return self.user() }, now: { clock })
        await model.refresh(); await model.refresh()
        XCTAssertEqual(calls, 1)
        await model.refresh(force: true)
        XCTAssertEqual(calls, 2)
        clock.addTimeInterval(61)
        await model.refresh()
        XCTAssertEqual(calls, 3)
    }
    func testNetworkFailurePreservesDetailsAndThrottlesRetry() async {
        var fail = false
        var calls = 0
        let model = AccountRefreshModel(readSession: { "session" }, load: {
            calls += 1
            if fail { throw URLError(.notConnectedToInternet) }
            return self.user()
        })
        await model.refresh(); fail = true
        await model.refresh(force: true); await model.refresh()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.account?.id, "a")
        XCTAssertTrue(model.hasSession)
        XCTAssertFalse(model.message.isEmpty)
    }
    func testSessionExpiryClearsDetails() async {
        var expired = false
        let model = AccountRefreshModel(readSession: { "session" }, load: {
            if expired { throw AccountAPIError.unauthorized }
            return self.user()
        })
        await model.refresh(); expired = true; await model.refresh(force: true)
        XCTAssertNil(model.account)
        XCTAssertFalse(model.hasSession)
    }
    func testAccountSwitchDoesNotKeepOldDetailsOnFailure() async {
        var token = "first"
        var fail = false
        let model = AccountRefreshModel(readSession: { token }, load: {
            if fail { throw URLError(.timedOut) }
            return self.user()
        })
        await model.refresh(); token = "second"; fail = true
        await model.refresh()
        XCTAssertNil(model.account)
        XCTAssertTrue(model.hasSession)
    }
    func testOverlappingRefreshAndStaleCompletionAfterSignOut() async {
        var calls = 0
        var pending: CheckedContinuation<AccountStatus, Error>?
        let model = AccountRefreshModel(readSession: { "session" }, load: {
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        let task = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        await model.refresh(force: true)
        XCTAssertEqual(calls, 1)
        model.invalidate()
        pending?.resume(returning: user())
        await task.value
        XCTAssertNil(model.account)
        XCTAssertFalse(model.refreshing)
    }
    func testCancellationKeepsAccountAndAllowsRetry() async {
        var cancel = false
        let model = AccountRefreshModel(readSession: { "session" }, load: {
            if cancel { throw CancellationError() }
            return self.user()
        })
        await model.refresh(); cancel = true
        await model.refresh(force: true)
        XCTAssertNotNil(model.account)
        XCTAssertTrue(model.message.isEmpty)
        cancel = false; await model.refresh()
        XCTAssertNotNil(model.account)
    }
}
