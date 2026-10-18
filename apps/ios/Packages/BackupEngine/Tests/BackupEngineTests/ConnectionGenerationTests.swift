import XCTest
@testable import BackupEngine

final class ConnectionGenerationTests:XCTestCase {
 func testDelayedResultCannotPublishAfterLogoutOrNewLogin()async throws {
  var gate=ConnectionGeneration()
  let old=try gate.begin()
  gate.suspend()
  await Task.yield()
  XCTAssertThrowsError(try gate.validate(old))
  XCTAssertThrowsError(try gate.begin())
  gate.resume()
  let current=try gate.begin()
  gate.finish(old)
  XCTAssertThrowsError(try gate.begin())
  XCTAssertThrowsError(try gate.validate(old))
  XCTAssertNoThrow(try gate.validate(current))
  gate.finish(current)
  XCTAssertNoThrow(try gate.begin())
 }
 func testConcurrentConnectIsRejectedUntilFirstFinishes()throws {
  var gate=ConnectionGeneration();let first=try gate.begin()
  XCTAssertThrowsError(try gate.begin())
  gate.finish(first)
  XCTAssertNoThrow(try gate.begin())
 }
}
