#if canImport(SwiftUI)
import XCTest
@testable import LocalStorageManagement

@MainActor final class StorageSummaryRefreshTests:XCTestCase {
 private func summary(_ bytes:Int64=10)throws->CloudStorageSummary {
  try JSONDecoder().decode(CloudStorageSummary.self,from:Data("{\"quotaBytes\":100,\"protectedBytes\":\(bytes),\"reservedBytes\":0,\"remainingBytes\":\(100-bytes),\"overQuota\":false}".utf8))
 }
 func testSameSessionRefreshRetainsFiguresAndCoalescesRequests()async throws {
  let model=StorageManagementModel(),time=Date(timeIntervalSince1970:1000)
  let firstResult=await model.beginSummaryRefresh(session:"generated-session-a",now:time)
  let first=try XCTUnwrap(firstResult)
  model.finishSummaryRefresh(try summary(),plan:"free",generation:first,now:time);model.endSummaryRefresh(generation:first)
  let recent=await model.beginSummaryRefresh(session:"generated-session-a",now:time.addingTimeInterval(10))
  XCTAssertNil(recent)
  let refreshResult=await model.beginSummaryRefresh(session:"generated-session-a",force:true)
  let refresh=try XCTUnwrap(refreshResult)
  XCTAssertEqual(model.cloud?.protectedBytes,10);XCTAssertTrue(model.summaryRefreshing)
  let concurrent=await model.beginSummaryRefresh(session:"generated-session-a",force:true)
  XCTAssertNil(concurrent)
  model.endSummaryRefresh(generation:refresh,message:"Connection unavailable")
  XCTAssertEqual(model.cloud?.protectedBytes,10);XCTAssertEqual(model.summaryUpdatedAt,time)
  XCTAssertFalse(model.summaryRefreshing);XCTAssertEqual(model.summaryMessage,"Connection unavailable")
 }
 func testNewSessionClearsOldFiguresAndRejectsLateResponse()async throws {
  let model=StorageManagementModel()
  let oldResult=await model.beginSummaryRefresh(session:"generated-session-a")
  let old=try XCTUnwrap(oldResult)
  model.finishSummaryRefresh(try summary(),plan:"free",generation:old);model.endSummaryRefresh(generation:old)
  let freshResult=await model.beginSummaryRefresh(session:"generated-session-b")
  let fresh=try XCTUnwrap(freshResult)
  XCTAssertNil(model.cloud);XCTAssertNil(model.summaryUpdatedAt)
  model.finishSummaryRefresh(try summary(90),plan:"old",generation:old);model.endSummaryRefresh(generation:old)
  XCTAssertNil(model.cloud);XCTAssertTrue(model.summaryRefreshing)
  model.finishSummaryRefresh(try summary(20),plan:"new",generation:fresh);model.endSummaryRefresh(generation:fresh)
  XCTAssertEqual(model.cloud?.protectedBytes,20);XCTAssertEqual(model.plan,"new")
  await model.invalidate()
  model.finishSummaryRefresh(try summary(99),plan:"late",generation:fresh)
  XCTAssertNil(model.cloud);XCTAssertNil(model.summaryUpdatedAt)
 }
 func testBackgroundInvalidationAllowsFreshRequestAndRejectsOldCompletion()async throws {
  let model=StorageManagementModel()
  let oldResult=await model.beginSummaryRefresh(session:"generated-session")
  let old=try XCTUnwrap(oldResult)
  await model.background()
  XCTAssertFalse(model.summaryRefreshing)
  let newResult=await model.beginSummaryRefresh(session:"generated-session",force:true)
  let fresh=try XCTUnwrap(newResult)
  model.finishSummaryRefresh(try summary(90),plan:"stale",generation:old)
  XCTAssertNil(model.cloud)
  model.finishSummaryRefresh(try summary(20),plan:"current",generation:fresh);model.endSummaryRefresh(generation:fresh)
  XCTAssertEqual(model.cloud?.protectedBytes,20)
 }
 func testNoSessionCannotReuseCachedSummary()async throws {
  let model=StorageManagementModel()
  let generationResult=await model.beginSummaryRefresh(session:"generated-session")
  let generation=try XCTUnwrap(generationResult)
  model.finishSummaryRefresh(try summary(),plan:"free",generation:generation);model.endSummaryRefresh(generation:generation)
  let noSession=await model.beginSummaryRefresh(session:nil)
  XCTAssertNil(noSession);XCTAssertNil(model.cloud);XCTAssertFalse(model.summaryRefreshing)
 }
}
#endif
