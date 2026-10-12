import Foundation
import CryptoKit

public struct OriginalBinding:Codable,Equatable,Sendable {
 public let accountID:UUID,deviceID:UUID,libraryID:UUID
 public init(accountID:UUID,deviceID:UUID,libraryID:UUID){self.accountID=accountID;self.deviceID=deviceID;self.libraryID=libraryID}
}
public struct OriginalDescriptor:Codable,Equatable,Sendable {
 public let localID:String,mediaType:String,resourceTypes:[Int],resourceUTIs:[String]
 public let width:Int,height:Int,duration:Double?,creation:Date?,modification:Date?
 public let livePhoto:Bool
 public init(localID:String,mediaType:String,resourceTypes:[Int],resourceUTIs:[String],width:Int,height:Int,duration:Double?=nil,creation:Date?,modification:Date?,livePhoto:Bool=false){self.localID=localID;self.mediaType=mediaType;self.resourceTypes=resourceTypes;self.resourceUTIs=resourceUTIs;self.width=width;self.height=height;self.duration=duration;self.creation=creation;self.modification=modification;self.livePhoto=livePhoto}
 public var supported:Bool { !livePhoto && resourceTypes.count==1 && resourceUTIs.count==1 && width>0 && height>0 && ((mediaType=="image" && resourceTypes==[1]) || (mediaType=="video" && resourceTypes==[2])) && !resourceUTIs.contains{$0.lowercased().contains("raw")} }
 public var fingerprint:String {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return SHA256.hash(data:(try? e.encode(self)) ?? Data()).map{String(format:"%02x",$0)}.joined()}
}
public struct OriginalManifest:Codable,Equatable,Sendable {
 public let format:Int, binding:OriginalBinding,source:OriginalDescriptor,sizeBytes:Int,checksum:String,capturedAt:Date
 public var cloudAssetID:UUID?,verificationID:UUID?
 // Even a complete ordinary original requires a separate fresh local validation and
 // destructive-device/legal gate. This record alone never authorizes deletion.
 public var cleanupCandidateEvidence:Bool {source.supported && source.modification != nil && cloudAssetID != nil && verificationID != nil}
 public init(binding:OriginalBinding,source:OriginalDescriptor,sizeBytes:Int,checksum:String){format=1;self.binding=binding;self.source=source;self.sizeBytes=sizeBytes;self.checksum=checksum;capturedAt=Date()}
 public func matches(_ proof:OriginalServerProof)->Bool {proof.status=="PROTECTED" && proof.mediaType==source.mediaType && proof.sizeBytes==sizeBytes && proof.checksum==checksum}
}
public struct OriginalServerProof:Codable,Sendable {
 public let id:UUID,status:String,mediaType:String,sizeBytes:Int,checksum:String,verificationId:UUID
 public init(id:UUID,status:String="PROTECTED",mediaType:String,sizeBytes:Int,checksum:String,verificationId:UUID){self.id=id;self.status=status;self.mediaType=mediaType;self.sizeBytes=sizeBytes;self.checksum=checksum;self.verificationId=verificationId}
}
public protocol OriginalResourceSource:Sendable {
 func describe(_ localID:String) async throws -> OriginalDescriptor
 func stream(_ localID:String,to:URL,allowNetwork:Bool,progress:@escaping @Sendable(Double)->Void) async throws
}
// Public-API source adapter is separate so bounded file streaming/cancellation and
// evidence changes can be tested using generated fixtures without Photos access.
public struct OriginalResourcePreparer:ResourcePreparer {
 private let source:any OriginalResourceSource,files:ManagedTemporaryFiles,binding:OriginalBinding
 private let progress:@Sendable(Double)->Void
 public init(source:any OriginalResourceSource,files:ManagedTemporaryFiles,binding:OriginalBinding,progress:@escaping @Sendable(Double)->Void={_ in}){self.source=source;self.files=files;self.binding=binding;self.progress=progress}
 public func prepare(_ item:BackupItem,policy:BackupPolicy,network:NetworkSnapshot) async throws -> PreparedResource {
  guard item.libraryID==binding.libraryID,item.accountID==binding.accountID,item.deviceID==binding.deviceID else{throw BackupFailure.authorization}
  let before=try await source.describe(item.localAssetIdentifier)
  guard before.supported,before.mediaType==item.mediaType else{throw BackupFailure.unsupported}
  if let prior=item.originalManifest,prior.binding != binding || prior.source != before {throw BackupFailure.sourceChanged}
  let target=files.url(item.id);try files.remove(target)
  do {
   do{try await source.stream(item.localAssetIdentifier,to:target,allowNetwork:false,progress:progress)}catch BackupFailure.waitingForOriginal {
    try files.remove(target)
    guard policy.allowICloudOriginals,network.connected,network.wifi,!network.cellular,!network.constrained else{throw BackupFailure.waitingForOriginal}
    try await source.stream(item.localAssetIdentifier,to:target,allowNetwork:true,progress:progress)
   }
   try Task.checkCancellation();try files.secure(target)
   let integrity=try StreamingIntegrity.inspect(target)
   guard before==((try await source.describe(item.localAssetIdentifier))) else{throw BackupFailure.sourceChanged}
   if let prior=item.originalManifest,prior.checksum != integrity.checksum || prior.sizeBytes != integrity.sizeBytes {throw BackupFailure.sourceChanged}
   return PreparedResource(fileURL:target,sizeBytes:integrity.sizeBytes,checksum:integrity.checksum,manifest:OriginalManifest(binding:binding,source:before,sizeBytes:integrity.sizeBytes,checksum:integrity.checksum))
  }catch{try? files.remove(target);throw error}
 }
 public func cleanup(_ item:BackupItem) async throws {try files.cleanup(item.id)}
}
