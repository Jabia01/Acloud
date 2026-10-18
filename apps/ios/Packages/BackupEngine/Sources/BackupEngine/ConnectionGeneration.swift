import Foundation

/// Owned by the UI actor. Rejects stale asynchronous results across account teardown.
public struct ConnectionGeneration {
 private var generation=UUID()
 private var suspended=false
 private var connecting=false
 public init(){}
 public var isConnecting:Bool{connecting}
 public var current:UUID{generation}
 public mutating func begin() throws -> UUID {
  guard !suspended,!connecting else{throw CancellationError()}
  connecting=true;return generation
 }
 public func validate(_ token:UUID)throws {
  guard !suspended,token==generation else{throw CancellationError()}
 }
 public mutating func finish(_ token:UUID){if token==generation{connecting=false}}
 public mutating func suspend(){generation=UUID();suspended=true;connecting=false}
 public mutating func resume(){generation=UUID();suspended=false;connecting=false}
}
