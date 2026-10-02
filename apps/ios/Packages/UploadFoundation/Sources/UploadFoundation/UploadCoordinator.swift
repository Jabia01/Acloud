import Foundation

public actor UploadCoordinator {
    private let client: any UploadSessionClient
    private let transport: any UploadTransport
    private let store: any UploadStateStore
    private let directory: URL
    private var active: [UUID:Task<Void,Error>] = [:]
    public init(client: any UploadSessionClient, transport: any UploadTransport, store: any UploadStateStore, generatedDirectory: URL) {
        self.client = client; self.transport = transport; self.store = store; directory = generatedDirectory
    }
    public func enqueueGeneratedFile(_ url: URL) async throws -> UUID {
        let payload = try GeneratedPayload.inspect(at: url, in: directory)
        let record = UploadRecord(payload: payload); try await store.save(record); return record.id
    }
    private func cancelled(_ id: UUID) async throws -> Bool {
        try Task.checkCancellation()
        return try await store.read(id)?.phase == .cancelled
    }
    private func verified(_ asset: ServerAsset, record: UploadRecord) -> Bool {
        asset.id == record.assetID && asset.status == .protected && asset.sizeBytes == record.payload.sizeBytes
    }
    public func run(_ id: UUID) async throws {
        guard active[id] == nil else { throw UploadError.alreadyRunning }
        let task = Task { try await self.execute(id) }
        active[id] = task; defer { active[id] = nil }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func execute(_ id: UUID) async throws {
        guard var record = try await store.read(id) else { throw UploadError.missingRecord }
        do {
            if record.phase == .protected { return }
            if let assetID = record.assetID, verified(try await client.asset(id: assetID), record: record) {
                record.phase = .protected; record.cancellationPending = false; try await store.save(record); return
            }
            if record.phase == .cancelled {
                if record.cancellationPending {
                    if record.sessionID == nil {
                        // Recover a create response lost to cancellation/timeout using its stable key.
                        let recovered = try await client.create(payload: record.payload, idempotencyKey: record.idempotencyKey)
                        record.sessionID = recovered.id; record.assetID = recovered.assetId; try await store.save(record)
                    }
                    guard let sessionID = record.sessionID else { throw UploadError.missingRecord }
                    _ = try await client.cancel(id: sessionID); record.cancellationPending = false; try await store.save(record)
                }
                return
            }
            if let sessionID = record.sessionID, let assetID = record.assetID,
               [.uploading,.uploaded,.verifying,.failed].contains(record.phase) {
                // A PUT response may have been lost after storage accepted the whole file.
                // Probe verification before retransmission; create-only PUT replay is rejected.
                let recovery = try await client.complete(id: sessionID)
                let recoveredAsset = try await client.asset(id: assetID)
                if verified(recoveredAsset, record: record) {
                    record.phase = .protected; try await store.save(record); return
                }
                if recovery.status == .verifying {
                    record.phase = .verifying; try await store.save(record); return
                }
                if recovery.status == .expired || recovery.status == .cancelled { throw UploadError.expired }
            }
            guard try GeneratedPayload.inspect(at: record.payload.fileURL, in: directory) == record.payload else { throw UploadError.sourceChanged }
            let session = try await client.create(payload: record.payload, idempotencyKey: record.idempotencyKey)
            record.sessionID = session.id; record.assetID = session.assetId
            if var current = try await store.read(id), current.phase == .cancelled {
                current.sessionID = session.id; current.assetID = session.assetId; try await store.save(current)
                return // The durable cancellation reconciles on the next run.
            }
            try Task.checkCancellation()
            try await store.save(record) // Persist identity before any bytes are sent.
            if session.status == .expired || session.status == .cancelled { throw UploadError.expired }
            if let authorization = session.authorization {
                let intent = try await client.start(id: session.id)
                if intent.status == .cancelled || intent.status == .expired { throw UploadError.expired }
                record.phase = .uploading; try await store.save(record)
                try await transport.upload(file: record.payload, authorization: authorization)
                if try await cancelled(id) { return }
                record.phase = .uploaded; try await store.save(record)
            }
            record.phase = .verifying; try await store.save(record)
            let result = try await client.complete(id: session.id)
            if try await cancelled(id) { return }
            let asset = try await client.asset(id: session.assetId)
            if verified(asset, record: record) { record.phase = .protected }
            else if result.status == .failed || result.status == .expired || result.status == .cancelled { record.phase = .failed }
            else { record.phase = .verifying } // Retry run polls; no tight loop or false protection.
            try await store.save(record)
        } catch {
            if let current = try await store.read(id), current.phase != .cancelled {
                record.phase = .failed; try await store.save(record)
            }
            throw error
        }
    }
    public func cancel(_ id: UUID) async throws {
        guard var record = try await store.read(id) else { throw UploadError.missingRecord }
        if record.phase == .protected { return } // Cancellation cannot delete verified objects.
        record.phase = .cancelled; record.cancellationPending = true; try await store.save(record)
        active[id]?.cancel() // Cancels URLSession's async upload, not just the UI state.
        if let sessionID = record.sessionID {
            _ = try await client.cancel(id: sessionID)
            // Re-read to avoid overwriting a concurrent verified server result.
            if var current = try await store.read(id), current.phase == .cancelled {
                current.cancellationPending = false; try await store.save(current)
            }
        }
    }
}
