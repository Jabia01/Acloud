import Foundation
import CSQLite

// The connection is confined to its owning actor. No media bytes are stored.
private final class MetadataConnection {
    var db: OpaquePointer?
    init(url: URL?) throws {
        if let url {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
        }
        guard sqlite3_open_v2(url?.path ?? ":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw DiscoveryError.storageUnavailable
        }
        do {
            sqlite3_busy_timeout(db, 2000)
            let version = try scalar("PRAGMA user_version")
            guard version <= 1 else { throw DiscoveryError.unsupportedStoreVersion }
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            // Local schema version 1; future migrations must preserve observations.
            try execute("""
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS discovered_assets (
              local_asset_id TEXT PRIMARY KEY NOT NULL, media_type TEXT NOT NULL CHECK(media_type IN ('image','video')),
              creation_date REAL, modification_date REAL, pixel_width INTEGER, pixel_height INTEGER, duration REAL,
              known_bytes INTEGER CHECK(known_bytes IS NULL OR known_bytes >= 0),
              state TEXT NOT NULL CHECK(state IN ('visible','unavailable')),
              first_seen REAL NOT NULL, last_seen REAL NOT NULL, seen_generation TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS discovery_generation ON discovered_assets(seen_generation,state);
            CREATE TABLE IF NOT EXISTS scan_checkpoint (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation TEXT NOT NULL, snapshot_key TEXT NOT NULL,
              authorization TEXT NOT NULL, total INTEGER NOT NULL, next_offset INTEGER NOT NULL,
              newly_discovered INTEGER NOT NULL, status TEXT NOT NULL);
            PRAGMA user_version=1;
            COMMIT;
            """)
            #if os(iOS)
            if let url {
                for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
                }
            }
            #endif
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DiscoveryError.storageUnavailable }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DiscoveryError.storageUnavailable }
        return statement
    }
    func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DiscoveryError.storageUnavailable }
        return sqlite3_column_int64(statement, 0)
    }
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try work(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

public actor SQLiteDiscoveredAssetStore: DiscoveredAssetStore {
    private let connection: MetadataConnection
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    // nil creates an in-memory store for tests; the app supplies Application Support.
    public init(url: URL?) throws { connection = try MetadataConnection(url: url) }
    public static func applicationStoreURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw DiscoveryError.storageUnavailable }
        return base.appendingPathComponent("Discovery", isDirectory: true).appendingPathComponent("metadata.sqlite")
    }
    private func text(_ value: String, _ statement: OpaquePointer, _ index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func number(_ value: Double?, _ statement: OpaquePointer, _ index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DiscoveryError.storageUnavailable }
    }
    private func readCheckpoint() throws -> (ScanCheckpoint, String)? {
        let s = try connection.prepare("SELECT generation,snapshot_key,authorization,total,next_offset,newly_discovered,status FROM scan_checkpoint WHERE singleton=1")
        defer { sqlite3_finalize(s) }
        let result = sqlite3_step(s)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let authorization = LibraryAuthorization(rawValue: string(s, 2)) else { throw DiscoveryError.storageUnavailable }
        return (ScanCheckpoint(generation: string(s, 0), snapshotKey: string(s, 1), authorization: authorization,
                               total: Int(sqlite3_column_int64(s, 3)), nextOffset: Int(sqlite3_column_int64(s, 4)),
                               newlyDiscovered: Int(sqlite3_column_int64(s, 5))), string(s, 6))
    }
    private func save(_ c: ScanCheckpoint, status: String) throws {
        let s = try connection.prepare("INSERT OR REPLACE INTO scan_checkpoint VALUES(1,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(s) }
        text(c.generation,s,1); text(c.snapshotKey,s,2); text(c.authorization.rawValue,s,3)
        sqlite3_bind_int64(s,4,Int64(c.total)); sqlite3_bind_int64(s,5,Int64(c.nextOffset)); sqlite3_bind_int64(s,6,Int64(c.newlyDiscovered))
        text(status,s,7); try done(s)
    }
    private func validate(_ c: ScanCheckpoint) throws {
        guard let (current,status) = try readCheckpoint(), status != "complete",
              current.generation == c.generation, current.snapshotKey == c.snapshotKey,
              current.nextOffset == c.nextOffset, current.total == c.total else { throw DiscoveryError.inconsistentSnapshot }
    }
    public func begin(snapshotKey: String, total: Int, authorization: LibraryAuthorization) throws -> ScanCheckpoint {
        guard authorization.canRead, total >= 0 else { throw DiscoveryError.inconsistentSnapshot }
        if let (previous,status) = try readCheckpoint(), status != "complete", previous.snapshotKey == snapshotKey,
           previous.authorization == authorization, previous.total == total {
            try save(previous,status: "running"); return previous
        }
        let checkpoint = ScanCheckpoint(generation: UUID().uuidString, snapshotKey: snapshotKey, authorization: authorization, total: total, nextOffset: 0, newlyDiscovered: 0)
        try save(checkpoint,status: "running"); return checkpoint
    }
    public func writeBatch(_ assets: [AssetMetadata], checkpoint: ScanCheckpoint, nextOffset: Int) throws -> ScanCheckpoint {
        guard assets.count <= 1000, nextOffset == checkpoint.nextOffset + assets.count, nextOffset <= checkpoint.total else { throw DiscoveryError.inconsistentSnapshot }
        return try connection.transaction {
            try validate(checkpoint)
            let insert = try connection.prepare("INSERT OR IGNORE INTO discovered_assets VALUES(?,?,?,?,?,?,?,?, 'visible',?,?,?)")
            let update = try connection.prepare("UPDATE discovered_assets SET media_type=?,creation_date=?,modification_date=?,pixel_width=?,pixel_height=?,duration=?,known_bytes=?,state='visible',last_seen=?,seen_generation=? WHERE local_asset_id=?")
            defer { sqlite3_finalize(insert); sqlite3_finalize(update) }
            let now = Date().timeIntervalSince1970
            var newCount = checkpoint.newlyDiscovered
            for asset in assets {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                text(asset.localAssetID,insert,1); bindMetadata(asset,insert,start:2)
                number(now,insert,9); number(now,insert,10); text(checkpoint.generation,insert,11)
                try done(insert)
                if sqlite3_changes(connection.db) == 1 { newCount += 1 }
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                bindMetadata(asset,update,start:1); number(now,update,8)
                text(checkpoint.generation,update,9); text(asset.localAssetID,update,10); try done(update)
            }
            let updated = ScanCheckpoint(generation: checkpoint.generation, snapshotKey: checkpoint.snapshotKey, authorization: checkpoint.authorization, total: checkpoint.total, nextOffset: nextOffset, newlyDiscovered: newCount)
            try save(updated,status: "running"); return updated
        }
    }
    private func bindMetadata(_ a: AssetMetadata, _ s: OpaquePointer, start: Int32) {
        text(a.mediaType.rawValue,s,start)
        number(a.creationDate?.timeIntervalSince1970,s,start+1); number(a.modificationDate?.timeIntervalSince1970,s,start+2)
        number(a.pixelWidth.map(Double.init),s,start+3); number(a.pixelHeight.map(Double.init),s,start+4); number(a.duration,s,start+5)
        if let bytes = a.knownResourceBytes { sqlite3_bind_int64(s,start+6,bytes) } else { sqlite3_bind_null(s,start+6) }
    }
    public func finish(_ checkpoint: ScanCheckpoint) throws {
        guard checkpoint.nextOffset == checkpoint.total else { throw DiscoveryError.inconsistentSnapshot }
        try connection.transaction {
            try validate(checkpoint)
            let s = try connection.prepare("UPDATE discovered_assets SET state='unavailable' WHERE seen_generation <> ?")
            defer { sqlite3_finalize(s) }; text(checkpoint.generation,s,1); try done(s)
            try save(checkpoint,status: "complete")
        }
    }
    public func pause(_ checkpoint: ScanCheckpoint) throws {
        // A late cancellation must not overwrite a completed/invalidation checkpoint.
        guard let (current,status) = try readCheckpoint(), current.generation == checkpoint.generation, status != "complete" else { return }
        try save(current,status: "paused")
    }
    public func invalidateVisibility() throws {
        try connection.transaction {
            try connection.execute("UPDATE discovered_assets SET state='unavailable'; DELETE FROM scan_checkpoint;")
        }
    }
    public func summary() throws -> DiscoverySummary {
        let checkpoint = try readCheckpoint()
        let s = try connection.prepare("""
        SELECT COALESCE(SUM(media_type='image'),0),COALESCE(SUM(media_type='video'),0),
          COALESCE(SUM(known_bytes),0),COUNT(known_bytes),COALESCE(SUM(known_bytes IS NULL),0)
        FROM discovered_assets WHERE state='visible' AND seen_generation=?
        """)
        defer { sqlite3_finalize(s) }; text(checkpoint?.0.generation ?? "",s,1)
        guard sqlite3_step(s) == SQLITE_ROW else { throw DiscoveryError.storageUnavailable }
        return DiscoverySummary(images:Int(sqlite3_column_int64(s,0)),videos:Int(sqlite3_column_int64(s,1)),knownResourceBytes:sqlite3_column_int64(s,2),knownSizeAssets:Int(sqlite3_column_int64(s,3)),unknownSizeAssets:Int(sqlite3_column_int64(s,4)),unavailableAssets:Int(try connection.scalar("SELECT COUNT(*) FROM discovered_assets WHERE state='unavailable'")),isComplete:checkpoint?.1 == "complete")
    }
    public func rowCount() throws -> Int { Int(try connection.scalar("SELECT COUNT(*) FROM discovered_assets")) }
    public func checkpoint() throws -> ScanCheckpoint? { try readCheckpoint()?.0 }
    public func asset(localID: String) throws -> StoredDiscoveredAsset? {
        let s = try connection.prepare("SELECT media_type,creation_date,modification_date,pixel_width,pixel_height,duration,known_bytes,state,first_seen,last_seen FROM discovered_assets WHERE local_asset_id=?")
        defer { sqlite3_finalize(s) }; text(localID,s,1)
        let result = sqlite3_step(s); if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let type = DiscoveredMediaType(rawValue:string(s,0)), let state = LocalDiscoveryState(rawValue:string(s,7)) else { throw DiscoveryError.storageUnavailable }
        func optional(_ index: Int32) -> Double? { sqlite3_column_type(s,index) == SQLITE_NULL ? nil : sqlite3_column_double(s,index) }
        let bytes: Int64? = sqlite3_column_type(s,6) == SQLITE_NULL ? nil : sqlite3_column_int64(s,6)
        let metadata = AssetMetadata(localAssetID:localID,mediaType:type,creationDate:optional(1).map(Date.init(timeIntervalSince1970:)),modificationDate:optional(2).map(Date.init(timeIntervalSince1970:)),pixelWidth:optional(3).map(Int.init),pixelHeight:optional(4).map(Int.init),duration:optional(5),knownResourceBytes:bytes)
        return StoredDiscoveredAsset(metadata:metadata,state:state,firstSeenAt:Date(timeIntervalSince1970:sqlite3_column_double(s,8)),lastSeenAt:Date(timeIntervalSince1970:sqlite3_column_double(s,9)))
    }
}
