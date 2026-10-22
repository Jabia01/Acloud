import XCTest
@testable import MediaPreservation
final class StorageSpaceTests:XCTestCase {
 func testCapacityBoundaryAndUnknownEstimate(){let required=StorageSpace.required(bytes:100);XCTAssertEqual(required,200+StorageSpace.margin);XCTAssertTrue(StorageSpace.permits(available:required,required:required));XCTAssertFalse(StorageSpace.permits(available:required-1,required:required));XCTAssertTrue(StorageSpace.permits(available:nil,required:required))}
 func testOversizedOrInvalidEstimateCannotOverflowIntoPermission(){XCTAssertEqual(StorageSpace.required(bytes:Int64.max),Int64.max);XCTAssertEqual(StorageSpace.required(bytes:-1),Int64.max);XCTAssertFalse(StorageSpace.permits(available:1000,required:StorageSpace.required(bytes:Int64.max)))}
 func testDiskFullIsDistinctFromNetworkOrGeneralStorageFailure(){XCTAssertTrue(StorageSpace.isFull(NSError(domain:NSCocoaErrorDomain,code:NSFileWriteOutOfSpaceError)));let underlying=NSError(domain:NSPOSIXErrorDomain,code:28);XCTAssertTrue(StorageSpace.isFull(NSError(domain:NSCocoaErrorDomain,code:512,userInfo:[NSUnderlyingErrorKey:underlying])));XCTAssertFalse(StorageSpace.isFull(URLError(.timedOut)));XCTAssertFalse(StorageSpace.isFull(NSError(domain:NSPOSIXErrorDomain,code:13)))}
}
