import XCTest
import Foundation
import Darwin
@testable import LocalStorageManagement
final class PerformanceTests:XCTestCase {
 func testIndexedEligibilityAtOneTenAndHundredThousand() async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-perf-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
  let store=try LocalCleanupStore(url:dir.appendingPathComponent("evidence.sqlite"))
  for count in [1000,10000,100000]{
   let candidates=(0..<count).map{_ in candidate()},snapshots=Dictionary(uniqueKeysWithValues:candidates.map{($0.backedUp.localID,$0.backedUp)})
   let capture=Date();try await store.capture(candidates);let insertMs=Date().timeIntervalSince(capture)*1000
   let start=Date(),result=FreeUpSpaceEligibilityService().scan(candidates,current:snapshots,context:context,permission:.authorized),scanMs=Date().timeIntervalSince(start)*1000
   XCTAssertEqual(result.eligibleCount,count);XCTAssertEqual(result.knownBytes,Int64(count*5))
   let query=Date(),page=try await store.evidence(account:context.userID,after:candidates[count/2].id,limit:500),queryMs=Date().timeIntervalSince(query)*1000
   XCTAssertLessThanOrEqual(page.count,500);var usage=rusage();getrusage(RUSAGE_SELF,&usage)
   print("Cleanup generated metadata count \(count), scanMs \(scanMs), indexedPageMs \(queryMs), insertMs \(insertMs), processMaxRSSBytes \(usage.ru_maxrss)")
  }
 }
}
