import Foundation
import CryptoKit
public struct RestoreFiles:Sendable {
 public let directory:URL
 public init(directory:URL)throws{self.directory=directory.standardizedFileURL.resolvingSymlinksInPath();try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);var d=self.directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try d.setResourceValues(values)
 #if os(iOS)
 try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:d.path)
 #endif
 }
 public func url(_ id:UUID)->URL{directory.appendingPathComponent(id.uuidString+".bin")}
 public func validate(_ url:URL)throws{guard url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path==directory.path else{throw RestoreFailure.storage}}
 public func remove(_ id:UUID)throws{let file=url(id);try validate(file);if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)}}
 public func verify(_ item:RestoreItem)throws{let file=url(item.id);try validate(file);guard try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else{throw RestoreFailure.integrity};let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};var sha=SHA256(),size=0;while let bytes=try autoreleasepool(invoking:{try handle.read(upToCount:65536)}),!bytes.isEmpty{try Task.checkCancellation();size+=bytes.count;guard size<=item.evidence.expectedSize else{throw RestoreFailure.integrity};sha.update(data:bytes)};guard size == item.evidence.expectedSize,sha.finalize().map({String(format:"%02x",$0)}).joined() == item.evidence.expectedSha256 else{throw RestoreFailure.integrity}}
}

// A typed hard link gives PhotoKit a recognizable extension without transcoding
// or moving the verified download. Only the new link is removed after its callback.
struct PhotoSaveFile {
 let url:URL
 init(file:URL,uti:String)throws {
  let extensions=["public.jpeg":"jpg","public.png":"png","public.heic":"heic","public.mpeg-4":"mp4","com.apple.quicktime-movie":"mov"]
  guard let ext=extensions[uti],try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile == true,try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw RestoreFailure.unsupported}
  url=file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
  try FileManager.default.linkItem(at:file,to:url)
 }
 func remove(){try? FileManager.default.removeItem(at:url)}
}
