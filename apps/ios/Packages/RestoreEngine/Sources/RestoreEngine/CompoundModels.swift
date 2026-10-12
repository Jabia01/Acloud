import Foundation
import MediaPreservation
public enum ManifestRestoreChoice:String,Codable,Sendable{case all="ALL",original="ORIGINAL",edited="EDITED"}
public struct CompoundPlanResource:Codable,Equatable,Sendable{public let id:UUID,role:ResourceRole,resourceType:Int,uti:String,required:Bool,resourceClass:ResourceClass,expectedSize:Int?,expectedSha256:String?,assetId:UUID?,cloudVersionId:String?,status:String,evidence:RestoreEvidence}
public struct CompoundRestorePlan:Codable,Equatable,Sendable{
 public let manifest:ServerManifestProof,choice:ManifestRestoreChoice,resources:[CompoundPlanResource]
 public var valid:Bool{
 guard manifest.manifestVersion==1,manifest.protection=="FULLY_PROTECTED",!manifest.sourceChanged,!manifest.reviewRequired,!manifest.integrityDegraded,!resources.isEmpty,resources.count<=16,Set(resources.map(\.id)).count==resources.count else{return false}
 let selected=manifest.resources.filter{$0.required && (choice == .all || choice == .original && $0.resourceClass == .original || choice == .edited && $0.role == .edited)}
 guard Set(selected.map(\.id))==Set(resources.map(\.id)),choice != .all || selected.count==manifest.requiredCount else{return false}
 return resources.allSatisfy{r in selected.contains{p in p.id==r.id && p.role==r.role && p.resourceType==r.resourceType && p.uti==r.uti && p.required==r.required && p.resourceClass==r.resourceClass && p.expectedSize==r.expectedSize && p.expectedSha256==r.expectedSha256 && p.assetId==r.assetId && p.cloudVersionId==r.cloudVersionId && p.status=="PROTECTED"} && r.status=="PROTECTED" && r.assetId==r.evidence.id && r.cloudVersionId==r.evidence.cloudVersionId && r.expectedSize==r.evidence.expectedSize && r.expectedSha256==r.evidence.expectedSha256}
 }
 public var reconstructable:Bool{guard valid else{return false};let roles=resources.map(\.role);if roles.contains(.pairedVideo){return roles.count==2&&roles.contains(.still)&&choice == .all};if roles.contains(.raw){return roles.count==1||roles.count==2&&roles.contains(.jpeg)};return resources.count==1&&[.still,.video,.edited].contains(resources[0].role)}
}
public struct CompoundRestoreRecord:Codable,Identifiable,Sendable{
 public let id:UUID,account:UUID,library:UUID,plan:CompoundRestorePlan,fileIDs:[UUID:UUID],createdAt:Date
 public var state:RestoreState = .queued,localIdentifier:String?,lastErrorCode:String?,revision=0
 public init(account:UUID,library:UUID,plan:CompoundRestorePlan,id:UUID=UUID()){self.id=id;self.account=account;self.library=library;self.plan=plan;fileIDs=Dictionary(uniqueKeysWithValues:plan.resources.map{($0.id,UUID())});createdAt=Date()}
}
public struct CompoundSaveResource:Sendable{public let role:ResourceRole,resourceType:Int,uti:String,file:URL;public init(role:ResourceRole,resourceType:Int,uti:String,file:URL){self.role=role;self.resourceType=resourceType;self.uti=uti;self.file=file}}
public protocol CompoundRestoreAPI:RestoreAPI{func compoundPlan(_ id:UUID,fingerprint:String,choice:ManifestRestoreChoice)async throws->CompoundRestorePlan;func compoundAuthorization(manifest:UUID,resource:CompoundPlanResource,fingerprint:String)async throws->RestoreAuthorization}
public protocol CompoundPhotoLibraryRestorer:Sendable{func canSave()async->Bool;func validate(_ resources:[CompoundSaveResource])async throws;func save(_ resources:[CompoundSaveResource])async throws->String;func presence(_ identifier:String)async->LocalPresence}
