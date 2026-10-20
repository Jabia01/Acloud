import XCTest
import CBackupSQLite
@testable import BackupEngine
final class ThumbnailOutboxTests:XCTestCase {
 private let jpeg=Data([255,216,1,2,255,217]),checksum=String(repeating:"a",count:64)
 func testPendingUploadSurvivesRelaunchAndAcknowledgementIsIdempotent()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let account=UUID(),asset=UUID(),first=ThumbnailOutbox(directory:root)
  try await first.enqueue(account:account,asset:asset,checksum:checksum,data:jpeg)
  try await first.enqueue(account:account,asset:asset,checksum:checksum,data:jpeg)
  let second=ThumbnailOutbox(directory:root),jobs=try await second.due(account:account)
  XCTAssertEqual(jobs.count,1);XCTAssertEqual(jobs[0].data,jpeg)
  let foreign=try await second.due(account:UUID());XCTAssertTrue(foreign.isEmpty)
  try await second.acknowledge(jobs[0]);try await second.acknowledge(jobs[0])
  try await ThumbnailOutbox(directory:root).enqueue(account:account,asset:asset,checksum:checksum,data:jpeg)
  let cleared=try await first.due(account:account);XCTAssertTrue(cleared.isEmpty)
 }
 func testRetryPersistsAndDoesNotStarveOtherJobs()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let account=UUID(),box=ThumbnailOutbox(directory:root),now=Date()
  for _ in 0..<6{try await box.enqueue(account:account,asset:UUID(),checksum:checksum,data:jpeg)}
  let jobs=try await box.due(account:account,now:now);try await box.deferJob(jobs[0],reason:.network,now:now)
  let restored=ThumbnailOutbox(directory:root),due=try await restored.due(account:account,now:now)
  XCTAssertEqual(due.count,5)
  let later=try await restored.due(account:account,now:now.addingTimeInterval(20));XCTAssertEqual(later.count,6)
  XCTAssertEqual(later.first(where:{$0.asset==jobs[0].asset})?.attempts,1)
  try await restored.deferJob(jobs[1],reason:.unsupported,now:now)
  let future=try await restored.due(account:account,now:now.addingTimeInterval(100000));XCTAssertEqual(future.count,5)
 }
 func testCorruptedBytesAndInvalidInputsAreNeverPublished()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let account=UUID(),box=ThumbnailOutbox(directory:root)
  do{try await box.enqueue(account:account,asset:UUID(),checksum:checksum,data:Data(repeating:0,count:40961));XCTFail()}catch{}
  try await box.enqueue(account:account,asset:UUID(),checksum:checksum,data:jpeg)
  let directory=root.appendingPathComponent(account.uuidString.lowercased()),file=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)[0]
  var object=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];object["dataChecksum"]=String(repeating:"0",count:64);try JSONSerialization.data(withJSONObject:object).write(to:file)
  let due=try await box.due(account:account);XCTAssertTrue(due.isEmpty)
 }
 func testLegacyPreviewScanIncludesOlderPagesAndKeepsAccountsIsolated()async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("queue.sqlite"),queue=try SQLiteBackupQueue(url:file),account=UUID(),other=UUID(),device=UUID()
  var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(file.path,&db),SQLITE_OK);defer{sqlite3_close(db)}
  // Seed generated historical records directly: this test exercises migration paging, not protection authority.
  for index in 0..<106 {
   var item=BackupItem(libraryID:UUID(),localAssetIdentifier:"generated-\(index)",mediaType:"image")
   item.accountID=index==0 ? other:account;item.deviceID=device
   _=try await queue.enqueue(item);item.state = .protected
   let bytes=try JSONEncoder().encode(item);var statement:OpaquePointer?
   XCTAssertEqual(sqlite3_prepare_v2(db,"UPDATE queue SET state='PROTECTED',record=? WHERE id=?",-1,&statement,nil),SQLITE_OK)
   let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
   _=bytes.withUnsafeBytes{sqlite3_bind_blob(statement,1,$0.baseAddress,Int32(bytes.count),transient)}
   _=item.id.uuidString.withCString{sqlite3_bind_text(statement,2,$0,-1,transient)}
   XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE);sqlite3_finalize(statement)
  }
  let first=try await queue.previewItems(account:account);XCTAssertEqual(first.count,100)
  let last=try XCTUnwrap(first.last),second=try await queue.previewItems(account:account,after:last.id)
  XCTAssertEqual(second.count,5);XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with:Set(second.map(\.id))))
  XCTAssertTrue((first+second).allSatisfy{$0.accountID==account})
 }

}
