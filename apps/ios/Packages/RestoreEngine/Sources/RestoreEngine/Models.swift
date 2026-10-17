import Foundation
public enum RestoreState:String,Codable,Sendable,CaseIterable{case queued="QUEUED",authorizing="AUTHORIZING",downloading="DOWNLOADING",verifying="VERIFYING",ready="READY_TO_SAVE",saving="SAVING_TO_PHOTOS",restored="RESTORED",paused="PAUSED",retryable="FAILED_RETRYABLE",permanent="FAILED_PERMANENT",cancelled="CANCELLED",reconcile="RECONCILE_REQUIRED"}
public extension RestoreState{func allows(_ next:RestoreState)->Bool{if self == .restored||self == .cancelled{return false};if self == next{return true};if self == .saving{return next == .reconcile};if self == .reconcile{return false};if [.paused,.cancelled,.retryable,.permanent].contains(next){return true};switch self{case .queued:return next == .authorizing;case .retryable:return next == .authorizing||next == .queued;case .authorizing:return next == .downloading||next == .queued;case .downloading:return next == .verifying||next == .queued;case .verifying:return next == .ready||next == .queued;case .ready:return next == .saving;case .paused,.permanent:return next == .queued;default:return false}}}
public enum RestoreFailure:Error,Equatable{case authorization,disabled,versionChanged,integrity,unsupported,permission,storage,missing,stale,duplicate,ambiguousSave,photosSave(Int),http(Int)}
public struct RestoreEvidence:Codable,Equatable,Sendable {
 public let id:UUID,cloudVersionId:String,mediaType:String,expectedSize:Int,expectedSha256:String,resourcePolicy:String
 public init(id:UUID,cloudVersionId:String,mediaType:String,expectedSize:Int,expectedSha256:String,resourcePolicy:String="SINGLE_PROTECTED_RESOURCE"){self.id=id;self.cloudVersionId=cloudVersionId;self.mediaType=mediaType;self.expectedSize=expectedSize;self.expectedSha256=expectedSha256;self.resourcePolicy=resourcePolicy}
 public var previewSupported:Bool{resourcePolicy=="VERIFIED_PREVIEW_RESOURCE" && ["image","video"].contains(mediaType) && expectedSize>0 && expectedSize<=32*1024*1024 && [cloudVersionId,expectedSha256].allSatisfy{$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}}
 public var supported:Bool{resourcePolicy=="SINGLE_PROTECTED_RESOURCE" && ["image","video"].contains(mediaType) && expectedSize>0 && expectedSize<=10*1024*1024*1024 && [cloudVersionId,expectedSha256].allSatisfy{$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}}
}
public struct RestoreItem:Codable,Identifiable,Sendable {
 public let id:UUID,accountID:UUID,libraryID:UUID,evidence:RestoreEvidence,createdAt:Date
 public var state:RestoreState = .queued,bytesDownloaded=0,retryCount=0,revision=0
 public var nextRetryAt:Date?,lastErrorCode:String?,localIdentifier:String?,restoredAt:Date?
 public var updatedAt=Date()
 public init(accountID:UUID,libraryID:UUID,evidence:RestoreEvidence,id:UUID=UUID()){self.id=id;self.accountID=accountID;self.libraryID=libraryID;self.evidence=evidence;createdAt=Date()}
}
public struct RestoreAuthorization:Decodable,Sendable{public let evidence:RestoreEvidence,authorization:RestoreCapability;public init(evidence:RestoreEvidence,authorization:RestoreCapability){self.evidence=evidence;self.authorization=authorization}}
public struct RestoreCapability:Decodable,Sendable{public let method:String,url:URL,expiresAt:String;public init(method:String="GET",url:URL,expiresAt:String){self.method=method;self.url=url;self.expiresAt=expiresAt}}
public protocol RestoreAPI:Sendable{func authorize(_ evidence:RestoreEvidence)async throws->RestoreAuthorization;func recheck(_ evidence:RestoreEvidence)async throws->RestoreEvidence;func report(_ code:String,retry:Int,durationMs:Int?)async}
public extension RestoreAPI{func report(_ code:String,retry:Int,durationMs:Int?)async{}}
public protocol RestoreDownloader:Sendable{func download(_ capability:RestoreCapability,to:URL,expectedSize:Int,progress:@escaping @Sendable(Int)->Void)async throws;func cancel()async}
public enum LocalPresence:Sendable{case exists,absent,unknown}
public protocol PhotoLibraryRestorer:Sendable{func canSave()async->Bool;func validate(_ file:URL,mediaType:String)async throws;func save(_ file:URL,mediaType:String)async throws->String;func presence(_ identifier:String)async->LocalPresence}
public protocol DeviceCapacity:Sendable{func available(at:URL)throws->Int64?}
public struct SystemDeviceCapacity:DeviceCapacity{public init(){};public func available(at url:URL)throws->Int64?{(try url.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage}}
public enum RestoreCopy{public static let iCloudWarning="Items restored to your Photos library may sync to iCloud Photos and your other Apple devices if iCloud Photos is enabled."}

public extension PhotoLibraryRestorer{func validate(_ file:URL,mediaType:String)async throws{}}
