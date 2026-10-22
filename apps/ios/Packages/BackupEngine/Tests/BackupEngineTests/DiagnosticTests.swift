import XCTest
@testable import BackupEngine
final class DiagnosticTests:XCTestCase {
 func testDistinctBoundedFailures() {
  XCTAssertEqual(BackupFailure.http(403).diagnosticCode,"HTTP_403")
  XCTAssertEqual(BackupFailure.http(409).diagnosticCode,"HTTP_409")
  XCTAssertEqual(BackupFailure.http(410).diagnosticCode,"SESSION_EXPIRED")
  XCTAssertEqual(BackupFailure.http(9999).diagnosticCode,"HTTP_ERROR")
  XCTAssertEqual(BackupFailure.authorization.diagnosticCode,"AUTHORIZATION_UNAVAILABLE")
  XCTAssertEqual(BackupFailure.unsupported.diagnosticCode,"UNSUPPORTED_MEDIA")
  XCTAssertEqual(BackupFailure.sourceChanged.diagnosticCode,"SOURCE_CHANGED")
 }
}

final class CapacityResponseTests:XCTestCase {
 func testQuotaResponseIsSpecificAndNeverTreatsOtherConflictsAsStorageFull(){let quota=Data("{\"code\":\"CLOUD_QUOTA_EXCEEDED\"}".utf8);XCTAssertEqual(BackupFailure.responseFailure(status:409,body:quota),.cloudQuota);XCTAssertEqual(BackupFailure.responseFailure(status:503,body:quota),.http(503));XCTAssertEqual(BackupFailure.responseFailure(status:409,body:Data("{}".utf8)),.http(409));XCTAssertEqual(BackupFailure.responseFailure(status:409,body:Data(repeating:0,count:4097)),.http(409))}
}
