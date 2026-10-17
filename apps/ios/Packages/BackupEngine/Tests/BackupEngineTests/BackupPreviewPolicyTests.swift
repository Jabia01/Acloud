import XCTest
@testable import BackupEngine
final class BackupPreviewPolicyTests:XCTestCase {
 let account=UUID(),asset=UUID(),digest=String(repeating:"a",count:64)
 func testVersionAndOwnerArePartOfCacheIdentity(){
  let first=BackupPreviewPolicy.key(account:account,asset:asset,checksum:digest)
  XCTAssertNotNil(first)
  XCTAssertNotEqual(first,BackupPreviewPolicy.key(account:UUID(),asset:asset,checksum:digest))
  XCTAssertNotEqual(first,BackupPreviewPolicy.key(account:account,asset:UUID(),checksum:digest))
  XCTAssertNotEqual(first,BackupPreviewPolicy.key(account:account,asset:asset,checksum:String(repeating:"b",count:64)))
 }
 func testUntrustedHashesCannotBecomePaths(){
  for value in ["../photo","",String(repeating:"A",count:64),String(repeating:"a",count:63),String(repeating:"a",count:65)] {XCTAssertNil(BackupPreviewPolicy.key(account:account,asset:asset,checksum:value))}
 }
 func testOnlyExactVerifiedBytesCanCapture(){
  XCTAssertTrue(BackupPreviewPolicy.mayCapture(protected:true,size:42,expectedSize:42,checksum:digest,expectedChecksum:digest))
  XCTAssertFalse(BackupPreviewPolicy.mayCapture(protected:false,size:42,expectedSize:42,checksum:digest,expectedChecksum:digest))
  XCTAssertFalse(BackupPreviewPolicy.mayCapture(protected:true,size:43,expectedSize:42,checksum:digest,expectedChecksum:digest))
  XCTAssertFalse(BackupPreviewPolicy.mayCapture(protected:true,size:42,expectedSize:42,checksum:String(repeating:"b",count:64),expectedChecksum:digest))
  XCTAssertFalse(BackupPreviewPolicy.mayCapture(protected:true,size:42,expectedSize:nil,checksum:digest,expectedChecksum:nil))
 }
 func testResourceUseIsBounded(){
  for size in [0,-1,BackupPreviewPolicy.maximumLocalBytes+1] {XCTAssertFalse(BackupPreviewPolicy.mayCapture(protected:true,size:size,expectedSize:size,checksum:digest,expectedChecksum:digest))}
  XCTAssertLessThan(BackupPreviewPolicy.maximumDownloadBytes,BackupPreviewPolicy.maximumLocalBytes)
 }
}
