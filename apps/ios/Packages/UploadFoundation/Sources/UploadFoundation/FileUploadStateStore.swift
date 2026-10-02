import Foundation

// Bounded development queue. No bearers, signed URLs, provider keys or media bytes.
public actor FileUploadStateStore: UploadStateStore {
    private let url: URL
    private var records: [UUID:UploadRecord]
    public init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1024 * 1024 else { throw UploadError.invalidPayload }
            let loaded = try JSONDecoder().decode([UploadRecord].self, from: Data(contentsOf: url))
            guard loaded.count <= 32, Set(loaded.map(\.id)).count == loaded.count else { throw UploadError.invalidPayload }
            records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id,$0) })
        } else { records = [:] }
    }
    public func save(_ record: UploadRecord) throws {
        guard records[record.id] != nil || records.count < 32 else { throw UploadError.queueFull }
        if records[record.id]?.phase == .cancelled && record.phase != .cancelled && record.phase != .protected {
            throw CancellationError() // A stale transfer callback cannot revive a cancelled record.
        }
        var next = records; next[record.id] = record
        let data = try JSONEncoder().encode(Array(next.values))
        #if os(iOS)
        try data.write(to: url, options: [.atomic,.completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        records = next // No in-memory transition until durable persistence succeeds.
    }
    public func read(_ id: UUID) -> UploadRecord? { records[id] }
}
