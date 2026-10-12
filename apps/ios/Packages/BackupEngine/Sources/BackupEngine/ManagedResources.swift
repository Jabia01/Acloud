import Foundation
import CryptoKit

public enum StreamingIntegrity {
 public static func inspect(_ url:URL) throws -> PreparedResource {
  let h=try FileHandle(forReadingFrom:url);defer{try? h.close()};var sha=SHA256();var size=0
  while let data=try autoreleasepool(invoking:{try h.read(upToCount:64*1024)}),!data.isEmpty{try Task.checkCancellation();sha.update(data:data);size+=data.count;guard size<=10*1024*1024*1024 else{throw BackupFailure.unsupported}}
  guard size>0 else{throw BackupFailure.unsupported}
  return PreparedResource(fileURL:url,sizeBytes:size,checksum:sha.finalize().map{String(format:"%02x",$0)}.joined())
 }
}
public struct ManagedTemporaryFiles: Sendable {
 public let directory:URL
 public init(directory:URL) throws {
  self.directory=directory.standardizedFileURL.resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  var excluded=self.directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:self.directory.path)
  #endif
 }
 public func url(_ id:UUID,part:Int?=nil) -> URL { directory.appendingPathComponent(id.uuidString + (part.map{"-part-\($0)"} ?? "") + ".bin") }
 private func validate(_ url:URL) throws {
  guard url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path==directory.path else{throw BackupFailure.sourceChanged}
 }
 public func secure(_ url:URL) throws {try validate(url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
 public func remove(_ url:URL) throws {try validate(url);if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}
 public func cleanup(_ id:UUID) throws {
  for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where url.lastPathComponent==id.uuidString+".bin" || url.lastPathComponent.hasPrefix(id.uuidString+"-part-") {try remove(url)}
 }
 public func part(_ resource:PreparedResource,id:UUID,number:Int,size:Int) throws -> PreparedResource {
  guard number>0,size>=5*1024*1024,size<=64*1024*1024 else{throw BackupFailure.unsupported}
  let target=url(id,part:number);try remove(target)
  guard FileManager.default.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw BackupFailure.storage}
  let input=try FileHandle(forReadingFrom:resource.fileURL),output=try FileHandle(forWritingTo:target)
  defer{try? input.close();try? output.close()}
  try input.seek(toOffset:UInt64((number-1)*size));var remaining=min(size,resource.sizeBytes-(number-1)*size)
  guard remaining>0 else{throw BackupFailure.unsupported}
  do{while remaining>0{try Task.checkCancellation();guard let data=try input.read(upToCount:min(64*1024,remaining)),!data.isEmpty else{throw BackupFailure.sourceChanged};try output.write(contentsOf:data);remaining-=data.count};try output.synchronize();try secure(target);return try StreamingIntegrity.inspect(target)}catch{try? remove(target);throw error}
 }
}
#if DEBUG
public struct GeneratedResourcePreparer: ResourcePreparer {
 public let sourceDirectory:URL;public let files:ManagedTemporaryFiles
 public init(sourceDirectory:URL,files:ManagedTemporaryFiles){self.sourceDirectory=sourceDirectory.standardizedFileURL.resolvingSymlinksInPath();self.files=files}
 public func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot) async throws -> PreparedResource {
  guard item.mediaType=="test",let sourceID=UUID(uuidString:item.localAssetIdentifier) else{throw BackupFailure.unsupported}
  let source=sourceDirectory.appendingPathComponent(sourceID.uuidString+".bin").resolvingSymlinksInPath()
  guard source.deletingLastPathComponent().path==sourceDirectory.path,try source.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else{throw BackupFailure.inaccessible}
  let target=files.url(item.id);try files.remove(target)
  try FileManager.default.copyItem(at:source,to:target);try files.secure(target)
  return try StreamingIntegrity.inspect(target)
 }
 public func cleanup(_ item:BackupItem) async throws {try files.cleanup(item.id)}
}

#endif
