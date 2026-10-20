import Foundation
import CBackupSQLite
import UploadFoundation

public actor SQLiteBackupQueue {
 private var db: OpaquePointer?
 private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
 public init(url: URL) throws {
  let directory=url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
  var excluded=directory; var values=URLResourceValues(); values.isExcludedFromBackup=true; try excluded.setResourceValues(values)
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:directory.path)
  #endif
  guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else { throw BackupFailure.storage }
  sqlite3_busy_timeout(db,5000)
  guard sqlite3_exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",nil,nil,nil)==SQLITE_OK else { throw BackupFailure.storage }
  var s:OpaquePointer?; sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&s,nil)
  let version=sqlite3_step(s)==SQLITE_ROW ? sqlite3_column_int(s,0) : -1; sqlite3_finalize(s)
  guard version>=0 && version<=1 else { throw BackupFailure.storage }
  let sql="""
  BEGIN IMMEDIATE;
  CREATE TABLE IF NOT EXISTS queue(id TEXT PRIMARY KEY, library_id TEXT NOT NULL, local_id TEXT NOT NULL, state TEXT NOT NULL, retry_at REAL, revision INTEGER NOT NULL, record BLOB NOT NULL, UNIQUE(library_id,local_id));
  CREATE INDEX IF NOT EXISTS queue_due ON queue(state,retry_at,id);
  CREATE TABLE IF NOT EXISTS parts(item_id TEXT NOT NULL REFERENCES queue(id), number INTEGER NOT NULL, size INTEGER NOT NULL, PRIMARY KEY(item_id,number));
  PRAGMA user_version=1; COMMIT;
  """
  guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw BackupFailure.storage }
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
  for path in [url.path,url.path+"-wal",url.path+"-shm"] where FileManager.default.fileExists(atPath:path) {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)}
 }
 deinit { sqlite3_close(db) }
 private func statement(_ sql:String) throws -> OpaquePointer {
  var s:OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK, let s else { throw BackupFailure.storage }; return s
 }
 private func bind(_ text:String,_ s:OpaquePointer,_ index:Int32) { _=text.withCString { sqlite3_bind_text(s,index,$0,-1,transient) } }
 private func done(_ s:OpaquePointer) throws { guard sqlite3_step(s)==SQLITE_DONE else { throw BackupFailure.storage } }
 private func decode(_ s:OpaquePointer,_ col:Int32=0) throws -> BackupItem {
  guard let bytes=sqlite3_column_blob(s,col) else { throw BackupFailure.storage }
  return try JSONDecoder().decode(BackupItem.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,col))))
 }
 private func record(_ item:BackupItem,_ s:OpaquePointer,_ index:Int32) throws {
  let data=try JSONEncoder().encode(item); _=data.withUnsafeBytes { sqlite3_bind_blob(s,index,$0.baseAddress,Int32(data.count),transient) }
 }
 public func enqueue(_ item:BackupItem) throws -> UUID {
  guard (item.accountID == nil) == (item.deviceID == nil), item.originalManifest == nil, item.state == .queued, item.localAssetIdentifier.utf8.count<=1024 else { throw BackupFailure.illegalTransition }
  let s=try statement("INSERT OR IGNORE INTO queue VALUES(?,?,?, ?,NULL,0,?)"); defer{sqlite3_finalize(s)}
  bind(item.id.uuidString,s,1); bind(item.libraryID.uuidString,s,2); bind(item.localAssetIdentifier,s,3); bind(item.state.rawValue,s,4); try record(item,s,5); try done(s)
  let lookup=try statement("SELECT record FROM queue WHERE library_id=? AND local_id=?"); defer{sqlite3_finalize(lookup)}
  bind(item.libraryID.uuidString,lookup,1); bind(item.localAssetIdentifier,lookup,2)
  guard sqlite3_step(lookup)==SQLITE_ROW else { throw BackupFailure.storage }; return try decode(lookup).id
 }
 // Explicit replacement keeps cancelled history immutable and frees only its dedup key.
 public func enqueueAgain(afterCancelled id:UUID)throws->UUID {
  guard let old=try read(id),old.state == .cancelled,!old.cancellationPending,old.mediaResourceBinding==nil else{throw BackupFailure.illegalTransition}
  if let latest=try find(library:old.libraryID,localID:old.localAssetIdentifier),latest.id != id{return latest.id}
  var fresh=BackupItem(libraryID:old.libraryID,localAssetIdentifier:old.localAssetIdentifier,mediaType:old.mediaType)
  fresh.accountID=old.accountID;fresh.deviceID=old.deviceID
  guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK else{throw BackupFailure.storage}
  do {
   let archive=try statement("UPDATE queue SET local_id=? WHERE id=? AND state='CANCELLED' AND revision=?")
   defer{sqlite3_finalize(archive)}
   bind("cancelled-attempt:"+id.uuidString,archive,1);bind(id.uuidString,archive,2);sqlite3_bind_int(archive,3,Int32(old.revision));try done(archive)
   guard sqlite3_changes(db)==1 else{throw BackupFailure.staleWrite}
   let inserted=try enqueue(fresh);guard inserted==fresh.id else{throw BackupFailure.staleWrite}
   guard sqlite3_exec(db,"COMMIT",nil,nil,nil)==SQLITE_OK else{throw BackupFailure.storage}
   return inserted
  }catch{sqlite3_exec(db,"ROLLBACK",nil,nil,nil);throw error}
 }
 public func find(library:UUID,localID:String) throws -> BackupItem? {
  let s=try statement("SELECT record FROM queue WHERE library_id=? AND local_id=?"); defer{sqlite3_finalize(s)}
  bind(library.uuidString,s,1);bind(localID,s,2); let r=sqlite3_step(s); if r==SQLITE_DONE{return nil};guard r==SQLITE_ROW else{throw BackupFailure.storage};return try decode(s)
 }
 public func read(_ id:UUID) throws -> BackupItem? {
  let s=try statement("SELECT record FROM queue WHERE id=?"); defer{sqlite3_finalize(s)}; bind(id.uuidString,s,1)
  let r=sqlite3_step(s); if r==SQLITE_DONE{return nil}; guard r==SQLITE_ROW else{throw BackupFailure.storage};return try decode(s)
 }
 @discardableResult public func save(_ item:BackupItem) throws -> BackupItem { try update(item,proof:nil,integrity:nil) }
 public func protect(_ item:BackupItem,proof:ServerAsset,integrity:OriginalServerProof?=nil) throws -> BackupItem { try update(item,proof:proof,integrity:integrity) }
 private func update(_ item:BackupItem,proof:ServerAsset?,integrity:OriginalServerProof?) throws -> BackupItem {
  guard let old=try read(item.id),old.revision==item.revision else{throw BackupFailure.staleWrite}
  guard old.mediaResourceBinding==item.mediaResourceBinding,old.localRemovedAfterProtection==item.localRemovedAfterProtection,old.libraryID==item.libraryID,old.localAssetIdentifier==item.localAssetIdentifier,old.accountID==item.accountID,old.deviceID==item.deviceID else{throw BackupFailure.illegalTransition}
  guard old.originalManifest == nil || item.originalManifest != nil else {throw BackupFailure.illegalTransition}
  if let manifest=item.originalManifest {guard manifest.binding.accountID==item.accountID,manifest.binding.deviceID==item.deviceID,manifest.binding.libraryID==item.libraryID,manifest.source.localID==item.localAssetIdentifier,manifest.source.mediaType==item.mediaType,manifest.source.supported,manifest.sizeBytes==item.expectedSizeBytes,manifest.checksum==item.expectedChecksum else{throw BackupFailure.illegalTransition};if let oldManifest=old.originalManifest{guard oldManifest.source==manifest.source,oldManifest.binding==manifest.binding,oldManifest.checksum==manifest.checksum,oldManifest.sizeBytes==manifest.sizeBytes else{throw BackupFailure.sourceChanged}}}
  if item.state == .protected {
   guard item.accountID == nil || item.originalManifest != nil || item.mediaResourceBinding != nil else {throw BackupFailure.illegalTransition}
   guard let proof,proof.id==item.assetID,proof.status == .protected,proof.mediaType==item.mediaType,proof.sizeBytes==item.expectedSizeBytes,proof.sizeBytes != nil else{throw BackupFailure.illegalTransition}
   if let binding=item.mediaResourceBinding{guard binding.binding.accountID==item.accountID,binding.binding.deviceID==item.deviceID,binding.binding.libraryID==item.libraryID,let integrity,integrity.id==item.assetID,integrity.status=="PROTECTED",integrity.mediaType==item.mediaType,integrity.checksum==item.expectedChecksum,integrity.sizeBytes==item.expectedSizeBytes else{throw BackupFailure.illegalTransition}}
   if let m=item.originalManifest{guard let integrity,m.matches(integrity),integrity.id==item.assetID,m.cloudAssetID==item.assetID,m.verificationID==integrity.verificationId else{throw BackupFailure.illegalTransition}}
  } else { guard old.state.allows(item.state) else{throw BackupFailure.illegalTransition} }
  var next=item;next.revision+=1;next.updatedAt=Date()
  let s=try statement("UPDATE queue SET state=?,retry_at=?,revision=?,record=? WHERE id=? AND revision=?");defer{sqlite3_finalize(s)}
  bind(next.state.rawValue,s,1);if let date=next.nextRetryAt{sqlite3_bind_double(s,2,date.timeIntervalSince1970)}else{sqlite3_bind_null(s,2)}
  sqlite3_bind_int(s,3,Int32(next.revision));try record(next,s,4);bind(next.id.uuidString,s,5);sqlite3_bind_int(s,6,Int32(item.revision));try done(s)
  guard sqlite3_changes(db)==1 else{throw BackupFailure.staleWrite};return next
 }
 public func recordLocalRemoval(_ id:UUID,assetID:UUID,size:Int,checksum:String,removed:Bool=true)throws {
  guard var item=try read(id),item.state == .protected,item.assetID==assetID,item.expectedSizeBytes==size,item.expectedChecksum==checksum else{throw BackupFailure.illegalTransition}
  item.localRemovedAfterProtection=removed;item.revision+=1;item.updatedAt=Date()
  let s=try statement("UPDATE queue SET revision=?,record=? WHERE id=? AND state='PROTECTED' AND revision=?");defer{sqlite3_finalize(s)}
  sqlite3_bind_int(s,1,Int32(item.revision));try record(item,s,2);bind(id.uuidString,s,3);sqlite3_bind_int(s,4,Int32(item.revision-1));try done(s);guard sqlite3_changes(db)==1 else{throw BackupFailure.staleWrite}
 }
 public func page(after:UUID?=nil,limit:Int=100) throws -> [BackupItem] {
  guard (1...1000).contains(limit) else{throw BackupFailure.storage}
  let s=try statement("SELECT record FROM queue WHERE id>? ORDER BY id LIMIT ?");defer{sqlite3_finalize(s)};bind(after?.uuidString ?? "",s,1);sqlite3_bind_int(s,2,Int32(limit))
  var result:[BackupItem]=[];while true{let r=sqlite3_step(s);if r==SQLITE_DONE{break};guard r==SQLITE_ROW else{throw BackupFailure.storage};result.append(try decode(s))};return result
 }
 public func recent(before:BackupItem?=nil,limit:Int=100)throws->[BackupItem]{
  guard (1...1000).contains(limit) else{throw BackupFailure.storage}
  // Date is encoded numerically by JSONEncoder; UUID breaks equal-time ties.
  let created="json_extract(CAST(record AS TEXT),'$.createdAt')"
  let s=try statement("SELECT record FROM queue WHERE (? IS NULL OR (\(created),id)<(?,?)) ORDER BY \(created) DESC,id DESC LIMIT ?")
  defer{sqlite3_finalize(s)}
  if let before {sqlite3_bind_double(s,1,before.createdAt.timeIntervalSinceReferenceDate);sqlite3_bind_double(s,2,before.createdAt.timeIntervalSinceReferenceDate);bind(before.id.uuidString,s,3)}
  else{sqlite3_bind_null(s,1);sqlite3_bind_null(s,2);sqlite3_bind_null(s,3)}
  sqlite3_bind_int(s,4,Int32(limit));var result:[BackupItem]=[]
  while true{let r=sqlite3_step(s);if r==SQLITE_DONE{break};guard r==SQLITE_ROW else{throw BackupFailure.storage};result.append(try decode(s))};return result
 }
 // Scan protected preview candidates independently of the visible transfer-history page.
 public func previewItems(account:UUID,after:UUID?=nil,limit:Int=100)throws->[BackupItem] {
  let s=try statement("SELECT record FROM queue WHERE state='PROTECTED' AND json_extract(CAST(record AS TEXT),'$.accountID')=? AND (? IS NULL OR id>?) ORDER BY id LIMIT ?");defer{sqlite3_finalize(s)}
  bind(account.uuidString,s,1);if let after{bind(after.uuidString,s,2);bind(after.uuidString,s,3)}else{sqlite3_bind_null(s,2);sqlite3_bind_null(s,3)}
  sqlite3_bind_int(s,4,Int32(max(1,min(100,limit))));var result:[BackupItem]=[]
  while true{let r=sqlite3_step(s);if r==SQLITE_DONE{break};guard r==SQLITE_ROW else{throw BackupFailure.storage};let item=try decode(s);if item.accountID==account{result.append(item)}}
  return result
 }
 public func due(now:Date=Date(),limit:Int=32) throws -> [BackupItem] {
  let s=try statement("SELECT record FROM queue WHERE state IN ('QUEUED','FAILED_RETRYABLE','UPLOADED','VERIFYING','PREPARING','UPLOADING') AND (retry_at IS NULL OR retry_at<=?) ORDER BY state,retry_at,id LIMIT ?");defer{sqlite3_finalize(s)}
  sqlite3_bind_double(s,1,now.timeIntervalSince1970);sqlite3_bind_int(s,2,Int32(max(1,min(limit,100))));var records:[BackupItem]=[]
  while true{let r=sqlite3_step(s);if r==SQLITE_DONE{break};guard r==SQLITE_ROW else{throw BackupFailure.storage};records.append(try decode(s))};return records
 }
 public func summary() throws -> [BackupState:Int] {
  let s=try statement("SELECT state,COUNT(*) FROM queue GROUP BY state");defer{sqlite3_finalize(s)};var result:[BackupState:Int]=[:]
  while sqlite3_step(s)==SQLITE_ROW{if let p=sqlite3_column_text(s,0),let state=BackupState(rawValue:String(cString:p)){result[state]=Int(sqlite3_column_int64(s,1))}};return result
 }
 public func replaceParts(_ id:UUID,parts:[CompletedPart]) throws {
  guard parts.count<=10000,Set(parts.map(\.partNumber)).count==parts.count,parts.allSatisfy({(1...10000).contains($0.partNumber) && $0.sizeBytes>0}) else{throw BackupFailure.storage}
  guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK else{throw BackupFailure.storage}
  do {
   let delete=try statement("DELETE FROM parts WHERE item_id=?");defer{sqlite3_finalize(delete)};bind(id.uuidString,delete,1);try done(delete)
   let s=try statement("INSERT INTO parts VALUES(?,?,?)");defer{sqlite3_finalize(s)}
   for part in parts {sqlite3_reset(s);bind(id.uuidString,s,1);sqlite3_bind_int(s,2,Int32(part.partNumber));sqlite3_bind_int64(s,3,Int64(part.sizeBytes));try done(s)}
   guard sqlite3_exec(db,"COMMIT",nil,nil,nil)==SQLITE_OK else{throw BackupFailure.storage}
  } catch{sqlite3_exec(db,"ROLLBACK",nil,nil,nil);throw error}
 }
 public func parts(_ id:UUID) throws -> [CompletedPart] {
  let s=try statement("SELECT number,size FROM parts WHERE item_id=? ORDER BY number");defer{sqlite3_finalize(s)};bind(id.uuidString,s,1);var parts:[CompletedPart]=[]
  while sqlite3_step(s)==SQLITE_ROW{parts.append(CompletedPart(partNumber:Int(sqlite3_column_int(s,0)),sizeBytes:Int(sqlite3_column_int64(s,1))))};return parts
 }
}
