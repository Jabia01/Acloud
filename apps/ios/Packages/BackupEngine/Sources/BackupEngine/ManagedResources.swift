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
 public func secure(_ url:URL) throws {
  try validate(url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  #if os(iOS)
  try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
  #endif
 }
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

// Private derived-preview keys bind both owner and immutable verified bytes.
public enum BackupPreviewPolicy {
 public static let maximumLocalBytes=256*1024*1024
 public static let maximumDownloadBytes=32*1024*1024
 public static func key(account:UUID,asset:UUID,checksum:String)->String? {
  guard checksum.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{return nil}
  return account.uuidString.lowercased()+"/"+asset.uuidString.lowercased()+"-"+checksum+".jpg"
 }
 public static func mayCapture(protected:Bool,size:Int,expectedSize:Int?,checksum:String,expectedChecksum:String?)->Bool {
  protected && size>0 && size<=maximumLocalBytes && size==expectedSize && checksum==expectedChecksum && checksum.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
 }
}

// Strip display-irrelevant metadata from derived JPEGs; never modify the original resource.
public enum PreviewJPEG {
 public static func withoutMetadata(_ data:Data)throws->Data {
  let bytes=[UInt8](data);guard bytes.count>=4,bytes[0]==255,bytes[1]==216 else{throw BackupFailure.unsupported}
  var output=Data(bytes.prefix(2)),offset=2
  while offset+4<=bytes.count {
   let start=offset;guard bytes[offset]==255 else{throw BackupFailure.unsupported};offset+=1
   while offset<bytes.count,bytes[offset]==255{offset+=1}
   guard offset+2<bytes.count else{throw BackupFailure.unsupported};let marker=bytes[offset];offset+=1
   if marker==218{output.append(contentsOf:bytes[start...]);return output}
   let length=Int(bytes[offset])*256+Int(bytes[offset+1]);guard length>=2,offset+length<=bytes.count else{throw BackupFailure.unsupported}
   if ![225,237,254].contains(marker){output.append(contentsOf:bytes[start..<(offset+length)])}
   offset+=length
  }
  throw BackupFailure.unsupported
 }
}

#if canImport(ImageIO) && canImport(AVFoundation)
import ImageIO
import AVFoundation
public actor VerifiedPreviewCache {
    public static let shared=VerifiedPreviewCache()
    private let root:URL
    public init(directory:URL?=nil){root=(directory ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("SavedVersionPreviews",isDirectory:true)).standardizedFileURL.resolvingSymlinksInPath()}
    private func file(account:UUID,asset:UUID,checksum:String)throws->URL {
        guard let key=BackupPreviewPolicy.key(account:account,asset:asset,checksum:checksum) else{throw BackupFailure.sourceChanged}
        let url=root.appendingPathComponent(key),directory=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:directory.path)
        #endif
        var excluded=root;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
        return url
    }
    public func cached(account:UUID,asset:UUID,checksum:String)throws->Data? {
        let url=try file(account:account,asset:asset,checksum:checksum)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        guard (try url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])).isSymbolicLink != true,
              let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,size<=256*1024 else{return nil}
        return try Data(contentsOf:url)
    }
    // Cloud derivatives are authenticated/version-bound by the caller, then decoded and bounded here.
    public func storeThumbnail(_ data:Data,account:UUID,asset:UUID,checksum:String)throws {
        guard data.count<=40*1024,let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              (1...240).contains(width),(1...240).contains(height),CGImageSourceCreateImageAtIndex(source,0,nil) != nil else{throw BackupFailure.unsupported}
        let url=try file(account:account,asset:asset,checksum:checksum)
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        #else
        try data.write(to:url,options:.atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);trimCache()
    }
    public func capture(file source:URL,account:UUID,asset:UUID,checksum:String,size:Int,mediaType:String)async throws->Data {
        guard size>0,size<=BackupPreviewPolicy.maximumLocalBytes else{throw BackupFailure.unsupported}
        guard try source.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]).isSymbolicLink != true,try source.resourceValues(forKeys:[.fileSizeKey]).fileSize==size else{throw BackupFailure.sourceChanged}
        let integrity=try StreamingIntegrity.inspect(source)
        guard BackupPreviewPolicy.mayCapture(protected:true,size:integrity.sizeBytes,expectedSize:size,checksum:integrity.checksum,expectedChecksum:checksum) else{throw BackupFailure.sourceChanged}
        let image:CGImage
        if mediaType=="image" {
            guard let input=CGImageSourceCreateWithURL(source as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let thumbnail=CGImageSourceCreateThumbnailAtIndex(input,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{throw BackupFailure.unsupported}
            image=thumbnail
        } else if mediaType=="video" {
            // Give AVFoundation a recognizable extension without modifying the verified source.
            let link=source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            try FileManager.default.linkItem(at:source,to:link);defer{try? FileManager.default.removeItem(at:link)}
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:link));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:240,height:240)
            image=try await generator.image(at:.zero).image
        } else {throw BackupFailure.unsupported}
        var encoded:Data?
        for quality in [0.75,0.55,0.35,0.15] {
            guard let output=CFDataCreateMutable(nil,0),let destination=CGImageDestinationCreateWithData(output,"public.jpeg" as CFString,1,nil) else{throw BackupFailure.unsupported}
            CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else{throw BackupFailure.unsupported}
            if CFDataGetLength(output)<=40*1024{encoded=output as Data;break}
        }
        guard let encoded else{throw BackupFailure.unsupported}
        let data=try PreviewJPEG.withoutMetadata(encoded)
        try Task.checkCancellation()
        let url=try file(account:account,asset:asset,checksum:checksum)
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        #else
        try data.write(to:url,options:.atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        trimCache()
        return data
    }
    // Bound disposable derived data; evicting it never affects backups or device originals.
    private func trimCache() {
        let keys:Set<URLResourceKey>=[.isRegularFileKey,.contentModificationDateKey,.fileSizeKey]
        if let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys)) {
            var files:[(URL,Date,Int)]=[]
            for case let candidate as URL in enumerator {
                if let values=try? candidate.resourceValues(forKeys:keys),values.isRegularFile==true {files.append((candidate,values.contentModificationDate ?? .distantPast,values.fileSize ?? 0))}
            }
            var bytes=files.reduce(0){$0+$1.2}
            for old in files.sorted(by:{$0.1<$1.1}) where bytes>32*1024*1024 {try? FileManager.default.removeItem(at:old.0);bytes-=old.2}
        }
    }
}

#endif
