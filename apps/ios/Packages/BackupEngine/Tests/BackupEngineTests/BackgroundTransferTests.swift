import Foundation
import XCTest
@testable import BackupEngine

private final class CompletionCounter:@unchecked Sendable {
 let lock=NSLock();private var count=0
 func add(){lock.lock();count+=1;lock.unlock()}
 var value:Int{lock.lock();defer{lock.unlock()};return count}
}
private final class CompletionBox:@unchecked Sendable {var receipt:BackgroundEventCompletion?}
final class BackgroundTransferTests:XCTestCase {
 func testWakeAcknowledgementIsExactlyOnceAcrossConcurrentFinishAndTimeout(){
  let counter=CompletionCounter(),receipt=BackgroundEventCompletion{counter.add()}
  DispatchQueue.concurrentPerform(iterations:100){_ in receipt.finish()}
  receipt.finish();XCTAssertEqual(counter.value,1)
 }
 func testWakeAcknowledgementCanReenterWithoutDeadlock(){
  let counter=CompletionCounter(),box=CompletionBox()
  box.receipt=BackgroundEventCompletion{counter.add();box.receipt?.finish()}
  box.receipt?.finish();box.receipt=nil;XCTAssertEqual(counter.value,1)
 }
 func testSessionIdentityPreservesInstalledDebugTasksAndSeparatesReleaseApps(){
  XCTAssertEqual(PartURLSessionTransport.sessionIdentifier(bundleIdentifier:"com.example.backupclient.dev"),"com.example.backupclient.dev.multipart")
  XCTAssertEqual(PartURLSessionTransport.sessionIdentifier(bundleIdentifier:"com.acloud.beta"),"com.acloud.beta.multipart")
  XCTAssertNotEqual(PartURLSessionTransport.sessionIdentifier(bundleIdentifier:"com.acloud.beta"),PartURLSessionTransport.sessionIdentifier(bundleIdentifier:"com.acloud.other"))
 }
}
