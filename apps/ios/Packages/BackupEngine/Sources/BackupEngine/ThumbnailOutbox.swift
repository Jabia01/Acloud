import Foundation
import CryptoKit

public enum ThumbnailRetryReason:String,Codable,Sendable {case network,access,preservation,budget,unsupported,integrity}
public struct ThumbnailOutboxSummary:Sendable {public var pending=0,failed=0,waitingForAccess=0,waitingForBudget=0}
public struct PendingThumbnail:Codable,Sendable {
 public let account:UUID,asset:UUID,sourceChecksum:String,data:Data,dataChecksum:String
 public var attempts:Int=0,nextAttempt:Date = .distantPast,reason:ThumbnailRetryReason?,terminal=false
}
// Pending derivatives are durable app support data, separate from disposable display caches.
public actor ThumbnailOutbox {
 public static let shared = ThumbnailOutbox()
 private let root:URL
 public init(directory:URL?=nil){root=(directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ThumbnailOutbox",isDirectory:true)).standardizedFileURL}
 private func directory(_ account:UUID)throws->URL {
  let directory=root.appendingPathComponent(account.uuidString.lowercased(),isDirectory:true)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:directory.path)
  #endif
  var excluded=root;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
  return directory
 }
 private func url(_ account:UUID,_ asset:UUID,_ checksum:String)throws->URL {
  guard checksum.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw BackupFailure.sourceChanged}
  return try directory(account).appendingPathComponent(asset.uuidString.lowercased()+"-"+checksum+".json")
 }
 private func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
 private func read(_ file:URL,account:UUID)throws->PendingThumbnail {
  let info=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
  guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>0,size<=64*1024 else{throw BackupFailure.storage}
  let item=try JSONDecoder().decode(PendingThumbnail.self,from:Data(contentsOf:file))
  guard item.account==account,item.data.count>=4,item.data.count<=40*1024,item.dataChecksum==hash(item.data),try url(account,item.asset,item.sourceChecksum).standardizedFileURL.resolvingSymlinksInPath().path==file.standardizedFileURL.resolvingSymlinksInPath().path else{throw BackupFailure.sourceChanged}
  return item
 }
 private func save(_ item:PendingThumbnail)throws {
  let file=try url(item.account,item.asset,item.sourceChecksum),bytes=try JSONEncoder().encode(item)
  #if os(iOS)
  try bytes.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
  #else
  try bytes.write(to:file,options:.atomic)
  #endif
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
 }
 public func enqueue(account:UUID,asset:UUID,checksum:String,data:Data)throws {
  guard data.count>=4,data.count<=40*1024,data.starts(with:[255,216]),data.suffix(2)==Data([255,217]) else{throw BackupFailure.unsupported}
  let file=try url(account,asset,checksum)
  if FileManager.default.fileExists(atPath:file.appendingPathExtension("synced").path){return}
  if FileManager.default.fileExists(atPath:file.path){_=try read(file,account:account);return}
  let files=try FileManager.default.contentsOfDirectory(at:directory(account),includingPropertiesForKeys:[.fileSizeKey])
  let pending=files.filter{$0.pathExtension=="json"}
  let usage=try pending.reduce(0){try $0+($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
  guard pending.count<4096,usage+data.count*2<64*1024*1024 else{throw BackupFailure.storage}
  try save(PendingThumbnail(account:account,asset:asset,sourceChecksum:checksum,data:data,dataChecksum:hash(data)))
 }
 public func due(account:UUID,now:Date=Date(),limit:Int=32)throws->[PendingThumbnail] {
  var items:[PendingThumbnail]=[]
  for file in try FileManager.default.contentsOfDirectory(at:directory(account),includingPropertiesForKeys:nil) where file.pathExtension=="json" {
   // A corrupt job cannot starve unrelated pending jobs. Leave it for diagnostics, never upload it.
   if let item=try? read(file,account:account),!item.terminal,item.nextAttempt<=now,!FileManager.default.fileExists(atPath:file.appendingPathExtension("synced").path){items.append(item)}
  }
  return Array(items.sorted{$0.nextAttempt==$1.nextAttempt ? $0.asset.uuidString<$1.asset.uuidString:$0.nextAttempt<$1.nextAttempt}.prefix(max(1,min(100,limit))))
 }
 public func acknowledge(_ item:PendingThumbnail)throws {
  let file=try url(item.account,item.asset,item.sourceChecksum)
  if FileManager.default.fileExists(atPath:file.path){let saved=try read(file,account:item.account);guard saved.dataChecksum==item.dataChecksum else{throw BackupFailure.sourceChanged};let receipt=file.appendingPathExtension("synced")
   #if os(iOS)
   try Data().write(to:receipt,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
   #else
   try Data().write(to:receipt,options:.atomic)
   #endif
   try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
   try FileManager.default.removeItem(at:file)}
 }
 public func summary(account:UUID)throws->ThumbnailOutboxSummary {
  var result=ThumbnailOutboxSummary()
  for file in try FileManager.default.contentsOfDirectory(at:directory(account),includingPropertiesForKeys:nil) where file.pathExtension=="json" {
   guard !FileManager.default.fileExists(atPath:file.appendingPathExtension("synced").path) else{continue}
   if let item=try? read(file,account:account),!item.terminal{result.pending+=1;if item.reason == .access{result.waitingForAccess+=1};if item.reason == .budget{result.waitingForBudget+=1}}else{result.failed+=1}
  }
  return result
 }
 public func deferJob(_ item:PendingThumbnail,reason:ThumbnailRetryReason,now:Date=Date())throws {
  let file=try url(item.account,item.asset,item.sourceChecksum)
  guard FileManager.default.fileExists(atPath:file.path) else{return}
  var updated=try read(file,account:item.account)
  updated.attempts=min(30,updated.attempts+1);updated.reason=reason
  updated.terminal=[.unsupported,.integrity].contains(reason)
  let base:Double=reason == .access ? 300:reason == .budget ? 3600:reason == .preservation ? 60:5
  let delay=min(3600,base*pow(2,Double(min(8,updated.attempts-1))))
  // Stable per-job jitter avoids synchronized reconnect bursts and remains testable.
  let jitter=Double(Int(item.dataChecksum.prefix(2),radix:16) ?? 0)/255*min(30,delay/4)
  updated.nextAttempt=now.addingTimeInterval(delay+jitter);try save(updated)
 }
}
