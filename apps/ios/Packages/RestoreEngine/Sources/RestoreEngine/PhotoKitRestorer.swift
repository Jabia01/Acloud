#if canImport(Photos)
import Foundation
import Photos
public struct PhotoKitRestorer:PhotoLibraryRestorer {
 public init(){}
 public func canSave()async->Bool{let add=PHPhotoLibrary.authorizationStatus(for:.addOnly),read=PHPhotoLibrary.authorizationStatus(for:.readWrite);return Self.writeAllowed(add:add,read:read)}
 static func writeAllowed(add:PHAuthorizationStatus,read:PHAuthorizationStatus)->Bool{add == .authorized || read == .authorized || read == .limited}
 public func presence(_ id:String)async->LocalPresence{let auth=PHPhotoLibrary.authorizationStatus(for:.readWrite);guard auth == .authorized || auth == .limited else{return .unknown};if PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject != nil{return .exists};return auth == .authorized ? .absent:.unknown}
 public func validate(_ file:URL,mediaType:String)async throws{_=try resourceType(file,mediaType:mediaType)}
 private func resourceType(_ file:URL,mediaType:String)throws->String {
  let handle=try FileHandle(forReadingFrom:file);let prefix=try handle.read(upToCount:128) ?? Data();try handle.close();let signature=[UInt8](prefix);let uti:String
  if mediaType=="image",signature.starts(with:[0xff,0xd8,0xff]){uti="public.jpeg"}
  else if mediaType=="image",signature.starts(with:[137,80,78,71,13,10,26,10]){uti="public.png"}
  else if signature.count>=12,String(bytes:signature[4..<8],encoding:.ascii)=="ftyp"{let brand=String(bytes:signature[8..<12],encoding:.ascii) ?? "";if mediaType=="image",["heic","heix","hevc","hevx","mif1"].contains(brand){uti="public.heic"}else if mediaType=="video",["qt  ","isom","iso2","mp41","mp42","avc1","M4V "].contains(brand){uti=brand=="qt  " ? "com.apple.quicktime-movie":"public.mpeg-4"}else{throw RestoreFailure.unsupported}}
  else{throw RestoreFailure.unsupported}
  return uti
 }
 public func save(_ file:URL,mediaType:String)async throws->String{guard await canSave() else{throw RestoreFailure.permission};let uti=try resourceType(file,mediaType:mediaType)
  let typed=try PhotoSaveFile(file:file,uti:uti);defer{typed.remove()}
  let identifier=LocalIdentifierBox()
  return try await withCheckedThrowingContinuation{continuation in PHPhotoLibrary.shared().performChanges({let request=PHAssetCreationRequest.forAsset();let options=PHAssetResourceCreationOptions();options.shouldMoveFile=false;options.uniformTypeIdentifier=uti;options.originalFilename="Restored."+typed.url.pathExtension;request.addResource(with:mediaType=="video" ? .video:.photo,fileURL:typed.url,options:options);identifier.set(request.placeholderForCreatedAsset?.localIdentifier)},completionHandler:{success,error in if success,let local=identifier.get(){continuation.resume(returning:local)}else if let error=error as NSError?,error.domain == "PHPhotosErrorDomain"{continuation.resume(throwing:RestoreFailure.photosSave(error.code))}else{continuation.resume(throwing:RestoreFailure.ambiguousSave)}})}
 }
}
private final class LocalIdentifierBox:@unchecked Sendable{private let lock=NSLock();private var value:String?;func set(_ value:String?){lock.lock();self.value=value;lock.unlock()};func get()->String?{lock.lock();defer{lock.unlock()};return value}}
#endif
#if canImport(Photos)
import MediaPreservation
import UniformTypeIdentifiers
public struct CompoundPhotoKitRestorer:CompoundPhotoLibraryRestorer{
 public init(){}
 public func canSave()async->Bool{await PhotoKitRestorer().canSave()}
 public func presence(_ identifier:String)async->LocalPresence{await PhotoKitRestorer().presence(identifier)}
 private func dng(_ file:URL,uti:String)throws{guard uti==UTType(filenameExtension:"dng")?.identifier else{throw RestoreFailure.unsupported};let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};let bytes=[UInt8](try handle.read(upToCount:65536) ?? Data());guard bytes.count>=8 else{throw RestoreFailure.unsupported};let little=bytes[0]==73&&bytes[1]==73,big=bytes[0]==77&&bytes[1]==77;guard little||big else{throw RestoreFailure.unsupported};func number(_ offset:Int,_ count:Int)->Int{guard offset>=0,offset+count<=bytes.count else{return -1};return (0..<count).reduce(0){$0 | Int(bytes[offset+$1])<<(little ? $1*8:(count-1-$1)*8)}};guard number(2,2)==42 else{throw RestoreFailure.unsupported};let offset=number(4,4),count=number(offset,2);guard offset>=8,count>0,count<=2048,offset+2+count*12<=bytes.count,(0..<count).contains(where:{number(offset+2+$0*12,2)==50706}) else{throw RestoreFailure.unsupported}}
 public func validate(_ resources:[CompoundSaveResource])async throws{guard !resources.isEmpty,resources.count<=2 else{throw RestoreFailure.unsupported};let roles=resources.map(\.role);if roles.contains(.pairedVideo){guard resources.count==2,roles.contains(.still) else{throw RestoreFailure.unsupported}}else if roles.contains(.raw){guard resources.count==1||resources.count==2&&roles.contains(.jpeg) else{throw RestoreFailure.unsupported}}else{guard resources.count==1,[ResourceRole.still,.video,.edited].contains(roles[0]) else{throw RestoreFailure.unsupported}};for r in resources{if r.role == .raw{try dng(r.file,uti:r.uti)}else{try await PhotoKitRestorer().validate(r.file,mediaType:[2,6,9,10,11,12].contains(r.resourceType) ? "video":"image")}}}
 public func save(_ resources:[CompoundSaveResource])async throws->String{guard await canSave() else{throw RestoreFailure.permission};try await validate(resources);try Task.checkCancellation();let identifier=LocalIdentifierBox();return try await withCheckedThrowingContinuation{continuation in PHPhotoLibrary.shared().performChanges({let request=PHAssetCreationRequest.forAsset();for r in resources{let type:PHAssetResourceType;if r.role == .pairedVideo{type = .pairedVideo}else if r.role == .jpeg || r.role == .raw{type = resources.count==1 ? .photo:r.resourceType==4 ? .alternatePhoto:.photo}else{type=[2,6].contains(r.resourceType) ? .video:.photo};let options=PHAssetResourceCreationOptions();options.shouldMoveFile=false;options.uniformTypeIdentifier=r.uti;request.addResource(with:type,fileURL:r.file,options:options)};identifier.set(request.placeholderForCreatedAsset?.localIdentifier)},completionHandler:{success,_ in if success,let local=identifier.get(){continuation.resume(returning:local)}else{continuation.resume(throwing:RestoreFailure.ambiguousSave)}})}}
}
#endif
