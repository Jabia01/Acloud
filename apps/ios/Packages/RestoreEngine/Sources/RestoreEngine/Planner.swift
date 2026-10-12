import Foundation
public struct RestorePlanner:Sendable {
 private let queue:RestoreQueue,photos:any PhotoLibraryRestorer
 public init(queue:RestoreQueue,photos:any PhotoLibraryRestorer){self.queue=queue;self.photos=photos}
 public func enqueue(account:UUID,library:UUID,evidence:RestoreEvidence,restoreAgain:Bool=false)async throws->UUID{guard evidence.supported else{throw RestoreFailure.unsupported};let prior=try await queue.history(account:account,library:library,evidence:evidence);for record in prior{if ![.restored,.cancelled,.permanent,.reconcile].contains(record.state){throw RestoreFailure.duplicate};if record.state == .reconcile && !restoreAgain{throw RestoreFailure.ambiguousSave};if record.state == .restored,let id=record.localIdentifier{let presence=await photos.presence(id);if presence != .absent && !restoreAgain{throw RestoreFailure.duplicate}}};let item=RestoreItem(accountID:account,libraryID:library,evidence:evidence);try await queue.enqueue(item);return item.id}
}
