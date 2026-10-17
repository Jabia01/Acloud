import Foundation

// UIKit acknowledgement can race normal completion, timeout and expiration.
// Finishing it must never cancel a daemon transfer or claim server protection.
public final class BackgroundEventCompletion:@unchecked Sendable {
 private let lock=NSLock()
 private var completion:(@Sendable()->Void)?
 public init(_ completion:@escaping @Sendable()->Void){self.completion=completion}
 public func finish(){lock.lock();let callback=completion;completion=nil;lock.unlock();callback?()}
}
