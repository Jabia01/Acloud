import Foundation
import MediaPreservation
public enum CleanupReason:String,Codable,Sendable,CaseIterable {
 case eligible,notProtected,protectedButMismatched,localAssetMissing,localAssetChanged,unknownResourceState,iCloudOnly,limitedPermissionBlocked,deniedPermissionBlocked,pendingVerification,error,excluded,pendingDeletion
}
public enum CleanupPermission:String,Codable,Sendable {case authorized,limited,denied,restricted,unknown}
public enum LocalPresence:String,Codable,Sendable {case present,absentConfirmed,inaccessible,unknown}
public struct CleanupContext:Equatable,Codable,Sendable {
 public let userID:UUID,deviceID:UUID,libraryID:UUID
 public init(userID:UUID,deviceID:UUID,libraryID:UUID){self.userID=userID;self.deviceID=deviceID;self.libraryID=libraryID}
}
public struct ResourceProtection:Equatable,Codable,Sendable {
 enum CodingKeys:String,CodingKey {case assetID="assetId",sizeBytes,checksum,status}
 public let assetID:UUID,sizeBytes:Int64,checksum:String
 public var status:String
 public init(assetID:UUID,sizeBytes:Int64,checksum:String,status:String="PROTECTED"){self.assetID=assetID;self.sizeBytes=sizeBytes;self.checksum=checksum;self.status=status}
}
public struct LocalSnapshot:Equatable,Codable,Sendable {
 public let localID:String
 public var mediaType:String,width:Int,height:Int,duration:Double?,creation:Date?,modification:Date?
 public var resourceFingerprint:String?,resourceCount:Int,manifestComplete:Bool,availability:String,knownBytes:Int64?
 public init(localID:String,mediaType:String,width:Int=1,height:Int=1,duration:Double?=nil,creation:Date?=Date(),modification:Date?=Date(),resourceFingerprint:String?=nil,resourceCount:Int=1,manifestComplete:Bool=false,availability:String="unknown",knownBytes:Int64?=nil){self.localID=localID;self.mediaType=mediaType;self.width=width;self.height=height;self.duration=duration;self.creation=creation;self.modification=modification;self.resourceFingerprint=resourceFingerprint;self.resourceCount=resourceCount;self.manifestComplete=manifestComplete;self.availability=availability;self.knownBytes=knownBytes}
}
public struct CleanupCandidate:Identifiable,Codable,Sendable {
 public let id:UUID,context:CleanupContext,backedUp:LocalSnapshot,resources:[ResourceProtection]
 public var unresolved:Bool,pending:Bool,excluded:Bool
 public init(id:UUID=UUID(),context:CleanupContext,backedUp:LocalSnapshot,resources:[ResourceProtection],unresolved:Bool=false,pending:Bool=false,excluded:Bool=false){self.id=id;self.context=context;self.backedUp=backedUp;self.resources=resources;self.unresolved=unresolved;self.pending=pending;self.excluded=excluded}
}
public struct EligibilitySummary:Sendable {
 public var reasons:[UUID:CleanupReason]=[:],knownBytes:Int64=0,unknownSizeCount=0,eligibleCount=0
}
public struct FreeUpSpaceEligibilityService:Sendable {
 public init(){}
 public func reason(_ item:CleanupCandidate,current:LocalSnapshot?,context:CleanupContext,permission:CleanupPermission)->CleanupReason {
  guard permission == .authorized || permission == .limited else{return .deniedPermissionBlocked}
  guard item.context==context else{return .protectedButMismatched}
  if item.pending{return .pendingDeletion};if item.excluded{return .excluded};if item.unresolved{return .pendingVerification}
  guard !item.resources.isEmpty else{return .notProtected}
  if item.resources.contains(where:{["UPLOADED","VERIFYING","QUEUED","UPLOADING"].contains($0.status)}){return .pendingVerification}
  guard item.resources.allSatisfy({$0.status=="PROTECTED"}) else{return .notProtected}
  guard let current else{return permission == .limited ? .limitedPermissionBlocked:.localAssetMissing}
  guard current.localID==item.backedUp.localID,current.mediaType==item.backedUp.mediaType else{return .protectedButMismatched}
  if current.availability=="icloudOnly"{return .iCloudOnly}
  guard current.availability=="local",item.backedUp.manifestComplete,current.manifestComplete,item.backedUp.resourceCount==item.resources.count,current.resourceCount==item.resources.count,Set(item.resources.map(\.assetID)).count==item.resources.count else{return .unknownResourceState}
  guard item.resources.allSatisfy({$0.sizeBytes>0 && $0.checksum.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}),let before=item.backedUp.resourceFingerprint,let now=current.resourceFingerprint,!before.isEmpty,!now.isEmpty,item.backedUp.modification != nil,current.modification != nil else{return .unknownResourceState}
  guard item.backedUp.modification==current.modification,item.backedUp.creation==current.creation,item.backedUp.width==current.width,item.backedUp.height==current.height,item.backedUp.duration==current.duration,before==now else{return .localAssetChanged}
  if let old=item.backedUp.knownBytes,let new=current.knownBytes,old != new{return .localAssetChanged}
  var sizes:Int64=0
  for r in item.resources{let sum=sizes.addingReportingOverflow(r.sizeBytes);guard !sum.overflow else{return .error};sizes=sum.partialValue}
  guard sizes>0 else{return .error}
  if let size=current.knownBytes,size != sizes{return .localAssetChanged}
  if let size=item.backedUp.knownBytes,size != sizes{return .unknownResourceState}
  return .eligible
 }
 public func scan(_ candidates:[CleanupCandidate],current:[String:LocalSnapshot],context:CleanupContext,permission:CleanupPermission)->EligibilitySummary {
  var resourceUses:[UUID:Int]=[:];for c in candidates{for r in c.resources{resourceUses[r.assetID,default:0]+=1}}
  var result=EligibilitySummary();let duplicates=Dictionary(grouping:candidates,by:{$0.backedUp.localID}).filter{$0.value.count>1}
  for c in candidates{let reason=(duplicates[c.backedUp.localID] != nil || c.resources.contains{resourceUses[$0.assetID,default:0]>1}) ? CleanupReason.protectedButMismatched:self.reason(c,current:current[c.backedUp.localID],context:context,permission:permission);result.reasons[c.id]=reason;if reason == .eligible{result.eligibleCount+=1;if let bytes=current[c.backedUp.localID]?.knownBytes,bytes>=0{let sum=result.knownBytes.addingReportingOverflow(bytes);if !sum.overflow{result.knownBytes=sum.partialValue}else{result.unknownSizeCount+=1}}else{result.unknownSizeCount+=1}}};return result
 }
}
public struct CleanupGate:Sendable {
 public var developmentBuild:Bool,explicitFlag:Bool,disposableContext:Bool,serverEnabled:Bool
 public init(developmentBuild:Bool=false,explicitFlag:Bool=false,disposableContext:Bool=false,serverEnabled:Bool=false){self.developmentBuild=developmentBuild;self.explicitFlag=explicitFlag;self.disposableContext=disposableContext;self.serverEnabled=serverEnabled}
 public var allows:Bool{
  #if DEBUG
  return developmentBuild && explicitFlag && disposableContext && serverEnabled
  #else
  return false
  #endif
 }
}

public extension FreeUpSpaceEligibilityService{
 func reason(manifest:MediaManifest,proof:ServerManifestProof,fresh:MediaSourceSnapshot?,context:CleanupContext,fidelityAccepted:Bool=false)->CleanupReason{
 guard let fresh else{return .localAssetMissing};let binding=ManifestBinding(accountID:context.userID,deviceID:context.deviceID,libraryID:context.libraryID)
 guard manifest.binding==binding else{return .protectedButMismatched};guard manifest.matches(fresh),manifest.state != .sourceChanged else{return .localAssetChanged};guard manifest.source.shapeComplete,!proof.reviewRequired else{return .unknownResourceState};guard proof.protection=="FULLY_PROTECTED",!proof.integrityDegraded else{return .notProtected};guard fidelityAccepted else{return .excluded};return MediaCleanupEligibility.eligible(manifest,proof:proof,fresh:fresh,binding:binding,fidelityAccepted:fidelityAccepted) ? .eligible:.protectedButMismatched
 }
}
