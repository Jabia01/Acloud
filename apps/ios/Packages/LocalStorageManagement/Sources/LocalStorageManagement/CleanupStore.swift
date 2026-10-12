import Foundation
import CCleanupSQLite
public enum DeletionState:String,Codable,Sendable,CaseIterable {case selected,awaitingConfirmation,deletionRequested,systemPending,removed,cancelled,failed,reconcileRequired}
public struct CleanupJob:Identifiable,Codable,Sendable {
 public let id:UUID,context:CleanupContext,candidates:[CleanupCandidate],createdAt:Date
 public var state:DeletionState,removed:Set<UUID>
 public init(context:CleanupContext,candidates:[CleanupCandidate]){id=UUID();self.context=context;self.candidates=candidates;createdAt=Date();state = .selected;removed=[]}
}
public struct CleanupHistory:Sendable {public let date:Date,removedCount:Int,knownBytes:Int64,unknownSizes:Int,state:DeletionState}
public actor LocalCleanupStore {
 private var db:OpaquePointer?;private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
 public init(url:URL)throws{
  let d=url.deletingLastPathComponent();try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);var excluded=d;var v=URLResourceValues();v.isExcludedFromBackup=true;try excluded.setResourceValues(v)
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:d.path)
  #endif
  guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{throw CleanupFailure.storage}
  var version:OpaquePointer?
  guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&version,nil)==SQLITE_OK,let version else{throw CleanupFailure.storage}
  let validVersion=sqlite3_step(version)==SQLITE_ROW && [0,1].contains(sqlite3_column_int(version,0));sqlite3_finalize(version)
  guard validVersion else{sqlite3_close(db);db=nil;throw CleanupFailure.storage}
  guard sqlite3_exec(db,"PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;CREATE TABLE IF NOT EXISTS cleanup_jobs(id TEXT PRIMARY KEY,account TEXT NOT NULL,created REAL NOT NULL,record BLOB NOT NULL);CREATE INDEX IF NOT EXISTS cleanup_account ON cleanup_jobs(account,created);CREATE TABLE IF NOT EXISTS cleanup_evidence(id TEXT PRIMARY KEY,account TEXT NOT NULL,local_id TEXT NOT NULL,record BLOB NOT NULL,UNIQUE(account,local_id));CREATE INDEX IF NOT EXISTS cleanup_evidence_page ON cleanup_evidence(account,id);PRAGMA user_version=1;",nil,nil,nil)==SQLITE_OK else{throw CleanupFailure.storage}
  for p in [url.path,url.path+"-wal",url.path+"-shm"] where FileManager.default.fileExists(atPath:p){try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:p)}
 }
 deinit{sqlite3_close(db)}
 private func statement(_ sql:String)throws->OpaquePointer{var s:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK,let s else{throw CleanupFailure.storage};return s}
 private func text(_ v:String,_ s:OpaquePointer,_ n:Int32){_=v.withCString{sqlite3_bind_text(s,n,$0,-1,transient)}}
 private func blob<T:Encodable>(_ v:T,_ s:OpaquePointer,_ n:Int32)throws{let b=try JSONEncoder().encode(v);_=b.withUnsafeBytes{sqlite3_bind_blob(s,n,$0.baseAddress,Int32(b.count),transient)}}
 private func decode<T:Decodable>(_ s:OpaquePointer,_ type:T.Type)throws->T{guard let b=sqlite3_column_blob(s,0) else{throw CleanupFailure.storage};return try JSONDecoder().decode(type,from:Data(bytes:b,count:Int(sqlite3_column_bytes(s,0))))}
 public func save(_ job:CleanupJob)throws{guard !job.candidates.isEmpty,job.candidates.count<=10,job.candidates.allSatisfy({$0.context==job.context}) else{throw CleanupFailure.storage};let s=try statement("INSERT INTO cleanup_jobs VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record WHERE account=excluded.account");defer{sqlite3_finalize(s)};text(job.id.uuidString,s,1);text(job.context.userID.uuidString,s,2);sqlite3_bind_double(s,3,job.createdAt.timeIntervalSince1970);try blob(job,s,4);guard sqlite3_step(s)==SQLITE_DONE else{throw CleanupFailure.storage}}
 public func jobs(account:UUID,limit:Int=100,after:UUID?=nil)throws->[CleanupJob]{let s=try statement("SELECT record FROM cleanup_jobs WHERE account=? AND id>? ORDER BY id LIMIT ?");defer{sqlite3_finalize(s)};text(account.uuidString,s,1);text(after?.uuidString ?? "",s,2);sqlite3_bind_int(s,3,Int32(max(1,min(limit,1000))));var list:[CleanupJob]=[];var step=sqlite3_step(s);while step==SQLITE_ROW{list.append(try decode(s,CleanupJob.self));step=sqlite3_step(s)};guard step==SQLITE_DONE else{throw CleanupFailure.storage};return list}
 public func pendingLocalIDs(context:CleanupContext)throws->Set<String>{
  var pending:Set<String>=[],after:UUID?
  while true{let page=try jobs(account:context.userID,after:after);if page.isEmpty{break};for j in page where j.context==context && [.selected,.awaitingConfirmation,.deletionRequested,.systemPending,.reconcileRequired].contains(j.state){pending.formUnion(j.candidates.map{$0.backedUp.localID})};after=page.last?.id};return pending
 }
 public func history(account:UUID)throws->[CleanupHistory]{let s=try statement("SELECT record FROM cleanup_jobs WHERE account=? ORDER BY created DESC LIMIT 20");defer{sqlite3_finalize(s)};text(account.uuidString,s,1);var result:[CleanupHistory]=[];var step=sqlite3_step(s);while step==SQLITE_ROW{let j=try decode(s,CleanupJob.self);var total:Int64=0,unknown=0;for c in j.candidates where j.removed.contains(c.id){if let b=c.backedUp.knownBytes,b>=0{let sum=total.addingReportingOverflow(b);if !sum.overflow{total=sum.partialValue}else{unknown+=1}}else{unknown+=1}};result.append(CleanupHistory(date:j.createdAt,removedCount:j.removed.count,knownBytes:total,unknownSizes:unknown,state:j.state));step=sqlite3_step(s)};guard step==SQLITE_DONE else{throw CleanupFailure.storage};return result}
 // Only validated backup capture may populate this index. Discovery alone never writes protection evidence.
 public func capture(_ candidates:[CleanupCandidate])throws{
  guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK else{throw CleanupFailure.storage}
  do{let s=try statement("INSERT OR REPLACE INTO cleanup_evidence VALUES(?,?,?,?)");defer{sqlite3_finalize(s)};for c in candidates{sqlite3_reset(s);text(c.id.uuidString,s,1);text(c.context.userID.uuidString,s,2);text(c.backedUp.localID,s,3);try blob(c,s,4);guard sqlite3_step(s)==SQLITE_DONE else{throw CleanupFailure.storage}};guard sqlite3_exec(db,"COMMIT",nil,nil,nil)==SQLITE_OK else{throw CleanupFailure.storage}}catch{sqlite3_exec(db,"ROLLBACK",nil,nil,nil);throw error}
 }
 public func evidence(account:UUID,after:UUID?=nil,limit:Int=500)throws->[CleanupCandidate]{let s=try statement("SELECT record FROM cleanup_evidence WHERE account=? AND id>? ORDER BY id LIMIT ?");defer{sqlite3_finalize(s)};text(account.uuidString,s,1);text(after?.uuidString ?? "",s,2);sqlite3_bind_int(s,3,Int32(max(1,min(limit,1000))));var list:[CleanupCandidate]=[];var step=sqlite3_step(s);while step==SQLITE_ROW{list.append(try decode(s,CleanupCandidate.self));step=sqlite3_step(s)};guard step==SQLITE_DONE else{throw CleanupFailure.storage};return list}
}
