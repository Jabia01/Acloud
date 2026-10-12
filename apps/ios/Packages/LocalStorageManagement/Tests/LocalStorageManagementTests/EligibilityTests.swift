import XCTest
import Foundation
@testable import LocalStorageManagement
let context=CleanupContext(userID:UUID(),deviceID:UUID(),libraryID:UUID())
func candidate(resources:Int=1,size:Int64?=5)->CleanupCandidate{
 let date=Date(timeIntervalSince1970:100),s=LocalSnapshot(localID:UUID().uuidString,mediaType:"image",creation:date,modification:date,resourceFingerprint:String(repeating:"a",count:64),resourceCount:resources,manifestComplete:true,availability:"local",knownBytes:size)
 return CleanupCandidate(context:context,backedUp:s,resources:(0..<resources).map{_ in ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64))})
}
final class EligibilityTests:XCTestCase {
 let engine=FreeUpSpaceEligibilityService()
 func reason(_ c:CleanupCandidate,_ current:LocalSnapshot?=nil,permission:CleanupPermission = .authorized)->CleanupReason{engine.reason(c,current:current ?? c.backedUp,context:context,permission:permission)}
 func testExactProtectedMatchEligible(){XCTAssertEqual(reason(candidate()),.eligible)}
 func testUnprotectedNeverEligible(){var c=candidate();c=CleanupCandidate(context:context,backedUp:c.backedUp,resources:[]);XCTAssertEqual(reason(c),.notProtected)}
 func testUploadedIsNotProtected(){let c=candidate();XCTAssertEqual(reason(CleanupCandidate(context:context,backedUp:c.backedUp,resources:[ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64),status:"UPLOADED")])),.pendingVerification)}
 func testVerifyingBlocks(){let c=candidate();XCTAssertEqual(reason(CleanupCandidate(context:context,backedUp:c.backedUp,resources:[ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64),status:"VERIFYING")])),.pendingVerification)}
 func testFailedVerificationBlocks(){let c=candidate();XCTAssertEqual(reason(CleanupCandidate(context:context,backedUp:c.backedUp,resources:[ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64),status:"FAILED")])),.notProtected)}
 func testUnknownProtectionBlocks(){let c=candidate();XCTAssertEqual(reason(CleanupCandidate(context:context,backedUp:c.backedUp,resources:[ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64),status:"UNKNOWN")])),.notProtected)}
 func testCrossAccountMismatch(){let c=candidate();XCTAssertEqual(engine.reason(c,current:c.backedUp,context:CleanupContext(userID:UUID(),deviceID:context.deviceID,libraryID:context.libraryID),permission:.authorized),.protectedButMismatched)}
 func testWrongDevice(){let c=candidate();XCTAssertEqual(engine.reason(c,current:c.backedUp,context:CleanupContext(userID:context.userID,deviceID:UUID(),libraryID:context.libraryID),permission:.authorized),.protectedButMismatched)}
 func testWrongLibrary(){let c=candidate();XCTAssertEqual(engine.reason(c,current:c.backedUp,context:CleanupContext(userID:context.userID,deviceID:context.deviceID,libraryID:UUID()),permission:.authorized),.protectedButMismatched)}
 func testMismatchedLocalIdentifier(){let c=candidate(),s=LocalSnapshot(localID:UUID().uuidString,mediaType:"image");XCTAssertEqual(reason(c,s),.protectedButMismatched)}
 func testMissingLocalAsset(){let c=candidate();XCTAssertEqual(engine.reason(c,current:nil,context:context,permission:.authorized),.localAssetMissing)}
 func testLimitedMissingBlocked(){let c=candidate();XCTAssertEqual(engine.reason(c,current:nil,context:context,permission:.limited),.limitedPermissionBlocked)}
 func testLimitedAccessibleExactMatch(){XCTAssertEqual(reason(candidate(),permission:.limited),.eligible)}
 func testDeniedPermission(){XCTAssertEqual(reason(candidate(),permission:.denied),.deniedPermissionBlocked)}
 func testRestrictedPermission(){XCTAssertEqual(reason(candidate(),permission:.restricted),.deniedPermissionBlocked)}
 func testUnknownPermission(){XCTAssertEqual(reason(candidate(),permission:.unknown),.deniedPermissionBlocked)}
 func testEditedModificationBlocks(){let c=candidate();var s=c.backedUp;s.modification=Date();XCTAssertEqual(reason(c,s),.localAssetChanged)}
 func testChangedDimensionsBlocks(){let c=candidate();var s=c.backedUp;s.width+=1;XCTAssertEqual(reason(c,s),.localAssetChanged)}
 func testChangedDurationBlocks(){let c=candidate();var s=c.backedUp;s.duration=4;XCTAssertEqual(reason(c,s),.localAssetChanged)}
 func testChangedResourceFingerprintBlocks(){let c=candidate();var s=c.backedUp;s.resourceFingerprint="other";XCTAssertEqual(reason(c,s),.localAssetChanged)}
 func testChangedSizeBlocks(){let c=candidate();var s=c.backedUp;s.knownBytes=6;XCTAssertEqual(reason(c,s),.localAssetChanged)}
 func testUnknownResourceState(){let c=candidate();var s=c.backedUp;s.availability="unknown";XCTAssertEqual(reason(c,s),.unknownResourceState)}
 func testICloudOnlyBlocks(){let c=candidate();var s=c.backedUp;s.availability="icloudOnly";XCTAssertEqual(reason(c,s),.iCloudOnly)}
 func testLivePhotoPartialBlocks(){let c=candidate();var s=c.backedUp;s.resourceCount=2;s.manifestComplete=false;XCTAssertEqual(reason(c,s),.unknownResourceState)}
 func testRawSidecarPartialBlocks(){let c=candidate();var s=c.backedUp;s.resourceCount=3;s.manifestComplete=false;XCTAssertEqual(reason(c,s),.unknownResourceState)}
 func testCompleteMultiResourceFixtureNeedsEveryProof(){XCTAssertEqual(reason(candidate(resources:2,size:10)),.eligible);XCTAssertEqual(reason(candidate(resources:2,size:5)),.localAssetChanged)}
 func testUnknownModificationFailsClosed(){let c=candidate();var s=c.backedUp;s.modification=nil;XCTAssertEqual(reason(c,s),.unknownResourceState)}
 func testUnknownFingerprintFailsClosed(){let c=candidate();var s=c.backedUp;s.resourceFingerprint=nil;XCTAssertEqual(reason(c,s),.unknownResourceState)}
 func testUnresolvedVerificationBlocks(){var c=candidate();c.unresolved=true;XCTAssertEqual(reason(c),.pendingVerification)}
 func testPendingDeletionBlocks(){var c=candidate();c.pending=true;XCTAssertEqual(reason(c),.pendingDeletion)}
 func testPolicyExclusionBlocks(){var c=candidate();c.excluded=true;XCTAssertEqual(reason(c),.excluded)}
 func testSizeUnknownNotFabricated(){let c=candidate(size:nil),s=engine.scan([c],current:[c.backedUp.localID:c.backedUp],context:context,permission:.authorized);XCTAssertEqual(s.knownBytes,0);XCTAssertEqual(s.unknownSizeCount,1);XCTAssertEqual(s.eligibleCount,1)}
 func testKnownSizeTotals(){let a=candidate(),b=candidate();let s=engine.scan([a,b],current:[a.backedUp.localID:a.backedUp,b.backedUp.localID:b.backedUp],context:context,permission:.authorized);XCTAssertEqual(s.knownBytes,10);XCTAssertEqual(s.unknownSizeCount,0)}
 func testDuplicateLocalMappingFailsClosed(){let a=candidate(),b=CleanupCandidate(context:context,backedUp:a.backedUp,resources:[ResourceProtection(assetID:UUID(),sizeBytes:5,checksum:String(repeating:"a",count:64))]);let s=engine.scan([a,b],current:[a.backedUp.localID:a.backedUp],context:context,permission:.authorized);XCTAssertEqual(s.eligibleCount,0)}
 func testDefaultFeatureGateDisabled(){XCTAssertFalse(CleanupGate().allows)}
 func testProductionGateDisabled(){XCTAssertFalse(CleanupGate(developmentBuild:false,explicitFlag:true,disposableContext:true,serverEnabled:true).allows)}
 func testServerDisableCannotBeOverridden(){XCTAssertFalse(CleanupGate(developmentBuild:true,explicitFlag:true,disposableContext:true,serverEnabled:false).allows)}
 func testDisposableContextRequired(){XCTAssertFalse(CleanupGate(developmentBuild:true,explicitFlag:true,disposableContext:false,serverEnabled:true).allows)}
 func testResourceSizeOverflowFailsClosed(){let a=candidate(resources:3,size:nil),r=a.resources.enumerated().map{index,r in ResourceProtection(assetID:r.assetID,sizeBytes:index==2 ? 5:Int64.max,checksum:r.checksum)};let c=CleanupCandidate(context:context,backedUp:a.backedUp,resources:r);XCTAssertEqual(reason(c),.error)}
 func testOneCloudResourceCannotCoverTwoLocalAssets(){let a=candidate(),b=candidate(),c=CleanupCandidate(context:context,backedUp:b.backedUp,resources:a.resources);let summary=engine.scan([a,c],current:[a.backedUp.localID:a.backedUp,b.backedUp.localID:b.backedUp],context:context,permission:.authorized);XCTAssertEqual(summary.eligibleCount,0)}
 func testInconsistentCapturedSizeCannotBeHiddenByUnknownCurrentSize(){let c=candidate(size:6);var current=c.backedUp;current.knownBytes=nil;XCTAssertEqual(reason(c,current),.unknownResourceState)}
}
