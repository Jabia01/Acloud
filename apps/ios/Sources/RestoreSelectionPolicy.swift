import Foundation

enum RestoreSelectionPolicy {
    static let maximum = 10
    static func accepts(_ selected: Set<UUID>, allowed: Set<UUID>) -> Bool {
        !selected.isEmpty && selected.count <= maximum && selected.isSubset(of: allowed)
    }
}
