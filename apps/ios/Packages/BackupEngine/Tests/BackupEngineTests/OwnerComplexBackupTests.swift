import XCTest
import MediaPreservation
@testable import BackupEngine
final class OwnerComplexBackupTests:XCTestCase {
 func snapshot(_ types:[Int],live:Bool=false,media:String="image",raw:Bool=false)->MediaSourceSnapshot {
  MediaSourceSnapshot(localID:"generated",mediaType:media,livePhoto:live,resources:types.enumerated().map{ResourceDescriptor(ordinal:$0.offset,resourceType:$0.element,uti:raw ? "com.adobe.raw-image":"public.data")})
 }
 func testCompleteLivePhotoAllowed(){XCTAssertTrue(OwnerComplexBackupPolicy.permits(snapshot([1,9],live:true)))}
 func testCompleteEditedPhotoAllowed(){XCTAssertTrue(OwnerComplexBackupPolicy.permits(snapshot([1,5,7])))}
 func testEditedLivePhotoRequiresAllEditResources(){XCTAssertTrue(OwnerComplexBackupPolicy.permits(snapshot([1,9,5,7],live:true)));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1,9,5],live:true)))}
 func testMissingPairOrEditRecipeRejected(){XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1],live:true)));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1,5])));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1,7])))}
 func testRawUnknownAndEditedVideoRemainExcluded(){XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1,5,7],raw:true)));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1,9,999],live:true)));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([2,6,7],media:"video")))}
 func testOrdinaryMediaUsesExistingPath(){XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([1])));XCTAssertFalse(OwnerComplexBackupPolicy.permits(snapshot([2],media:"video")))}
}
