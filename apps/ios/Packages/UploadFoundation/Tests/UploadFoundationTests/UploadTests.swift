import XCTest
@testable import UploadFoundation

private actor MockStateStore: UploadStateStore {
    var rows: [UUID:UploadRecord] = [:]
    private(set) var phases: [UploadPhase] = []
    func save(_ record: UploadRecord) throws {
        if rows[record.id]?.phase == .cancelled && record.phase != .cancelled && record.phase != .protected { throw CancellationError() }
        rows[record.id] = record; phases.append(record.phase)
    }
    func read(_ id: UUID) -> UploadRecord? { rows[id] }
}
private actor MockClient: UploadSessionClient {
    let sessionID = UUID(), assetID = UUID()
    var status: RemoteAssetStatus = .queued
    var size: Int?
    var keys: [UUID] = []
    var shouldProtect = true
    var wrongSize = false
    var failNextComplete = false
    private(set) var completions = 0
    private(set) var cancellations = 0
    func configure(protect: Bool = true, wrongSize: Bool = false) { shouldProtect = protect; self.wrongSize = wrongSize }
    func missingOnNextVerification() { failNextComplete = true }
    private func session(authorization: Bool = false) -> UploadSession {
        UploadSession(id: sessionID, assetId: assetID, status: status, expiresAt: "2099-01-01T00:00:00Z", errorCode: nil,
            authorization: authorization ? UploadAuthorization(method: "PUT", url: URL(string: "https://storage.example.invalid/signed")!, headers: [:], expiresAt: "2099-01-01T00:00:00Z") : nil)
    }
    func create(payload: GeneratedPayload, idempotencyKey: UUID) -> UploadSession { keys.append(idempotencyKey); size = payload.sizeBytes; return session(authorization: status == .queued || status == .failed) }
    func complete(id: UUID) -> UploadSession {
        completions += 1
        if failNextComplete { failNextComplete = false; status = .failed }
        else { status = shouldProtect ? .protected : .verifying }
        return session()
    }
    func start(id: UUID) -> UploadSession { status = .uploading; return session() }
    func asset(id: UUID) -> ServerAsset { ServerAsset(id: assetID, mediaType: "test", status: status, sizeBytes: wrongSize ? (size ?? 0) + 1 : size) }
    func cancel(id: UUID) -> UploadSession { cancellations += 1; status = .cancelled; return session() }
}
private actor MockTransport: UploadTransport {
    private(set) var calls = 0
    var failNext = false
    func interruptOnce() { failNext = true }
    func upload(file: GeneratedPayload, authorization: UploadAuthorization) throws {
        calls += 1
        if failNext { failNext = false; throw UploadError.requestFailed }
    }
}
private actor BlockingTransport: UploadTransport {
    private var started = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func upload(file: GeneratedPayload, authorization: UploadAuthorization) async throws {
        started = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }
}

final class UploadTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("generated.bin")
        try Data("abc".utf8).write(to: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func make(client: MockClient = MockClient(), transport: any UploadTransport = MockTransport(), store: MockStateStore = MockStateStore()) -> (UploadCoordinator,MockClient,MockStateStore) {
        (UploadCoordinator(client: client, transport: transport, store: store, generatedDirectory: directory),client,store)
    }
    func testGeneratedPayloadUsesStrongDigestAndExactSize() throws {
        let payload = try GeneratedPayload.inspect(at: file, in: directory)
        XCTAssertEqual(payload.sizeBytes,3)
        XCTAssertEqual(payload.checksumSHA256,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testEmptyAndOversizedFilesAreRejected() throws {
        try Data().write(to: file); XCTAssertThrowsError(try GeneratedPayload.inspect(at: file, in: directory))
        try Data(repeating:1,count:5*1024*1024+1).write(to: file)
        XCTAssertThrowsError(try GeneratedPayload.inspect(at: file, in: directory))
    }
    func testFileOutsideGeneratedDirectoryIsRejected() throws {
        XCTAssertThrowsError(try GeneratedPayload.inspect(at: file, in: directory.appendingPathComponent("different")))
    }
    func testQueuedRecordHasStableIdempotencyAndNoAuthorizationSecrets() async throws {
        let (coordinator,_,store) = make(); let id = try await coordinator.enqueueGeneratedFile(file)
        let loaded = await store.read(id)
        let record = try XCTUnwrap(loaded); XCTAssertEqual(record.phase,.queued)
        let json = String(decoding:try JSONEncoder().encode(record),as:UTF8.self)
        XCTAssertFalse(json.contains("authorization")); XCTAssertFalse(json.contains("sessionToken"))
        XCTAssertFalse(json.contains("storage_object_key"))
    }
    func testSuccessRequiresServerProtectedAndPersistsEveryPhase() async throws {
        let (coordinator,_,store) = make(); let id = try await coordinator.enqueueGeneratedFile(file)
        try await coordinator.run(id)
        let record = await store.read(id); let phases = await store.phases
        XCTAssertEqual(record?.phase,.protected)
        XCTAssertTrue(phases.contains(.queued)); XCTAssertTrue(phases.contains(.uploading))
        XCTAssertTrue(phases.contains(.uploaded)); XCTAssertTrue(phases.contains(.verifying))
    }
    func testTransmittedBytesAloneRemainVerifying() async throws {
        let client = MockClient(); await client.configure(protect:false)
        let (coordinator,_,store) = make(client:client); let id = try await coordinator.enqueueGeneratedFile(file)
        try await coordinator.run(id); let record = await store.read(id)
        XCTAssertEqual(record?.phase,.verifying)
    }
    func testProtectedResponseWithWrongSizeIsNotAccepted() async throws {
        let client = MockClient(); await client.configure(wrongSize:true)
        let (coordinator,_,store) = make(client:client); let id = try await coordinator.enqueueGeneratedFile(file)
        try await coordinator.run(id); let record = await store.read(id)
        XCTAssertNotEqual(record?.phase,.protected)
    }
    func testInterruptedRetryReusesIdempotencyKeyAndWholeFile() async throws {
        let transport = MockTransport(); await transport.interruptOnce()
        let (coordinator,client,store) = make(transport:transport); let id = try await coordinator.enqueueGeneratedFile(file)
        do { try await coordinator.run(id); XCTFail("Expected interruption") } catch {}
        let failed = await store.read(id); XCTAssertEqual(failed?.phase,.failed)
        await client.missingOnNextVerification()
        try await coordinator.run(id)
        let record = await store.read(id); let keys = await client.keys; let transfers = await transport.calls
        XCTAssertEqual(record?.phase,.protected); XCTAssertEqual(keys.count,2); XCTAssertEqual(Set(keys).count,1)
        XCTAssertEqual(transfers,2)
    }
    func testRepeatedRunDoesNotReuploadProtectedAsset() async throws {
        let transport = MockTransport(); let (coordinator,_,store) = make(transport:transport)
        let id = try await coordinator.enqueueGeneratedFile(file); try await coordinator.run(id); try await coordinator.run(id)
        let calls = await transport.calls; let record = await store.read(id)
        XCTAssertEqual(calls,1); XCTAssertEqual(record?.phase,.protected)
    }
    func testChangedFileCannotUseOldChecksumAuthorization() async throws {
        let (coordinator,client,store) = make(); let id = try await coordinator.enqueueGeneratedFile(file)
        try Data("different".utf8).write(to:file)
        do { try await coordinator.run(id); XCTFail("Expected changed source") } catch {}
        let keys = await client.keys; let record = await store.read(id)
        XCTAssertEqual(keys.count,0); XCTAssertEqual(record?.phase,.failed)
    }
    func testCancelInterruptsActiveTransportAndCannotReviveRecord() async throws {
        let transport = BlockingTransport(); let (coordinator,client,store) = make(transport:transport)
        let id = try await coordinator.enqueueGeneratedFile(file)
        let run = Task { try await coordinator.run(id) }
        await transport.waitForStart(); try await coordinator.cancel(id); _ = try? await run.value
        let record = await store.read(id); let cancellations = await client.cancellations
        XCTAssertEqual(record?.phase,.cancelled); XCTAssertEqual(cancellations,1)
    }
    func testQueuedCancellationReconcilesLostCreateByStableKeyWithoutTransfer() async throws {
        let transport = MockTransport(); let (coordinator,client,store) = make(transport:transport)
        let id = try await coordinator.enqueueGeneratedFile(file); try await coordinator.cancel(id); try await coordinator.run(id)
        let record = await store.read(id); let calls = await transport.calls; let cancellations = await client.cancellations
        XCTAssertEqual(record?.phase,.cancelled); XCTAssertFalse(record?.cancellationPending ?? true)
        XCTAssertEqual(calls,0); XCTAssertEqual(cancellations,1)
    }
    func testStatePersistsAcrossRestartAndExcludesTransientAuthorization() async throws {
        let url = directory.appendingPathComponent("state.json")
        let first = try FileUploadStateStore(url:url)
        let record = UploadRecord(payload:try GeneratedPayload.inspect(at:file,in:directory))
        try await first.save(record)
        let reopened = try FileUploadStateStore(url:url); let read = try await reopened.read(record.id)
        XCTAssertEqual(read?.idempotencyKey,record.idempotencyKey); XCTAssertEqual(read?.payload,record.payload)
    }
    func testStateQueueIsBoundedAndCancellationSticky() async throws {
        let store = try FileUploadStateStore(url:directory.appendingPathComponent("bounded.json"))
        let payload = try GeneratedPayload.inspect(at:file,in:directory)
        var first = UploadRecord(payload:payload); try await store.save(first)
        first.phase = .cancelled; try await store.save(first); first.phase = .uploaded
        do { try await store.save(first); XCTFail("Cancelled state revived") } catch {}
        for _ in 1..<32 { try await store.save(UploadRecord(payload:payload)) }
        do { try await store.save(UploadRecord(payload:payload)); XCTFail("Queue exceeded") } catch {}
    }
    func testUnsignedOrForeignStorageAuthorizationIsRejectedBeforeNetwork() async throws {
        let transport = try SinglePartUploadTransport(allowedOrigin:URL(string:"https://storage.example.invalid")!)
        let payload = try GeneratedPayload.inspect(at:file,in:directory)
        let authorization = UploadAuthorization(method:"PUT",url:URL(string:"https://other.example.invalid/object")!,headers:[:],expiresAt:"2099-01-01T00:00:00Z")
        do { try await transport.upload(file:payload,authorization:authorization); XCTFail("Wrong origin allowed") } catch {}
    }
    func testRemoteInsecureHTTPConfigurationIsRejected() {
        XCTAssertThrowsError(try SinglePartUploadTransport(allowedOrigin:URL(string:"http://storage.example.invalid")!,allowLocalHTTP:true))
    }
    func testLostPutResponseIsVerifiedBeforeReplayOnRestart() async throws {
        let transport = MockTransport(); let (coordinator,client,store) = make(transport:transport)
        let id = try await coordinator.enqueueGeneratedFile(file)
        let loaded = await store.read(id); var record = try XCTUnwrap(loaded)
        let session = await client.create(payload:record.payload,idempotencyKey:record.idempotencyKey)
        record.sessionID = session.id; record.assetID = session.assetId; record.phase = .uploading; try await store.save(record)
        try await coordinator.run(id)
        let restored = await store.read(id); let calls = await transport.calls
        XCTAssertEqual(restored?.phase,.protected); XCTAssertEqual(calls,0)
    }
}
