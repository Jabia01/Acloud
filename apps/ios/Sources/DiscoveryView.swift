import SwiftUI
import UIKit
import DiscoveryCore
import PhotoKitDiscovery

@MainActor final class DiscoveryViewModel: ObservableObject {
    @Published private(set) var authorization: LibraryAuthorization = .notDetermined
    @Published private(set) var summary: DiscoverySummary?
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var status = "Not scanned"
    @Published private(set) var scanning = false
    private let library = PhotoKitLibrary()
    private var scanner: PhotoLibraryScanner?
    private var scanTask: Task<Void,Never>?
    private var active = false
    private var pendingRescan = false
    private var initialized = false
    private var initialization: Task<SQLiteDiscoveredAssetStore,Error>?
    func activate() async {
        active = true
        do {
            if !initialized {
                // Opening/migrating SQLite is off the main actor.
                if initialization == nil {
                    initialization = Task.detached {
                        try SQLiteDiscoveredAssetStore(url:SQLiteDiscoveredAssetStore.applicationStoreURL())
                    }
                }
                guard let initialization else { return }
                let store = try await initialization.value
                if !initialized {
                    scanner = PhotoLibraryScanner(library:library,store:store)
                    initialized = true
                    await library.setChangeHandler { [weak self] in Task { @MainActor in await self?.refresh() } }
                }
                self.initialization = nil
            }
            await refresh()
        } catch { initialization = nil; status = "Local discovery storage unavailable. Unlock the device and try again." }
    }
    func deactivate() { active = false; pendingRescan = false; scanTask?.cancel() }
    func allowAccess() async {
        guard authorization == .notDetermined else { return }
        authorization = await library.requestAccess()
        await refresh()
    }
    func refresh() async {
        // Clear counts immediately when returning from Settings/picker/change events.
        summary = nil; progress = nil
        authorization = await library.authorization()
        await library.invalidateSnapshots()
        pendingRescan = active && authorization.canRead
        if let scanTask { scanTask.cancel(); return }
        if pendingRescan { start() }
        else {
            try? await scanner?.invalidateAccess()
            status = authorization.canRead ? "Not scanned" : "Photo access unavailable"
        }
    }
    func start() {
        guard active, authorization.canRead, let scanner, scanTask == nil else { return }
        pendingRescan = false; scanning = true; summary = nil; status = "Scanning"
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await scanner.run { [weak self] value in
                    await MainActor.run {
                        guard let self, !self.pendingRescan, self.active, self.authorization.canRead else { return }
                        self.progress = value
                    }
                }
                // Never display counts from a permission/snapshot superseded by refresh.
                if !pendingRescan, active {
                    switch outcome {
                    case .complete(let value): summary = value; status = "Complete"
                    case .cancelled(let value): summary = value; status = "Cancelled — partial results"
                    case .libraryChanged: summary = nil; pendingRescan = true; status = "Library changed; refreshing"
                    case .noAccess(let value): summary = nil; authorization = value; status = "Photo access unavailable"
                    }
                }
            } catch { summary = nil; status = "Scan unavailable. Try again after unlocking the device." }
            scanning = false; scanTask = nil
            if pendingRescan && active { await refresh() }
            else if !authorization.canRead { try? await scanner.invalidateAccess() }
        }
    }
    func cancel() { pendingRescan = false; scanTask?.cancel() }
}

private struct LimitedAccessPicker: UIViewControllerRepresentable {
    let completed: () -> Void
    func makeUIViewController(context: Context) -> PickerController { PickerController(completed:completed) }
    func updateUIViewController(_ uiViewController: PickerController, context: Context) {}
    final class PickerController: UIViewController {
        private let completed: () -> Void
        private var presented = false
        init(completed: @escaping () -> Void) { self.completed = completed; super.init(nibName:nil,bundle:nil) }
        required init?(coder: NSCoder) { fatalError("Unavailable") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }; presented = true
            PhotoLibraryAccessUI.manageLimitedAccess(from:self,completion:completed)
        }
    }
}

struct DiscoveryView: View {
    @StateObject private var model = DiscoveryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var managingAccess = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch model.authorization {
                    case .notDetermined:
                        Text("Allow photo access to discover photos and videos on this device. Discovery reads metadata only.")
                        Button("Allow Photo Access") { Task { await model.allowAccess() } }
                    case .restricted:
                        Text("Photo access is restricted by device or parental controls. The library cannot be scanned.")
                    case .denied:
                        Text("Photo access is turned off. The library cannot be scanned.")
                        settingsButton
                    case .authorized:
                        Text("Accessible photos and videos on this device")
                    case .limited:
                        Text("Limited Photo Access").font(.headline)
                        Text("Only selected photos and videos are visible. Your full library may contain additional items.")
                        Button("Manage Photo Access") { managingAccess = true }
                        settingsButton
                    }
                }
                if model.authorization.canRead {
                    Section("Discovery summary") {
                        if let summary = model.summary {
                            LabeledContent("Photos",value:summary.images.formatted())
                            LabeledContent("Videos",value:summary.videos.formatted())
                            LabeledContent("Known resource size",value:summary.knownSizeAssets == 0 ? "Unknown" : ByteCountFormatter.string(fromByteCount:summary.knownResourceBytes,countStyle:.file))
                            Text("\(summary.unknownSizeAssets.formatted()) items have unknown size. Known resource sizes do not establish that originals are on this device.").font(.footnote)
                            if !summary.isComplete { Text("Partial scan: these are not final library totals.") }
                        }
                        if model.scanning, let progress = model.progress {
                            ProgressView(value:Double(progress.processed),total:Double(max(1,progress.total)))
                            Text("\(progress.processed.formatted()) of \(progress.total.formatted()) assets scanned")
                            Text("\(progress.newlyDiscovered.formatted()) newly discovered")
                        }
                        Text("Scan status: \(model.status)")
                        if model.scanning { Button("Cancel") { model.cancel() } }
                        else { Button(model.status.hasPrefix("Cancelled") ? "Resume Scan" : "Scan Again") { model.start() } }
                    }
                } else { Text(model.status).font(.footnote) }
            }
            .navigationTitle("Photo Library")
        }
        .task { await model.activate() }
        .onChange(of:scenePhase) { _, phase in
            if phase == .active { Task { await model.activate() } } else { model.deactivate() }
        }
        .sheet(isPresented:$managingAccess,onDismiss:{ Task { await model.refresh() } }) {
            LimitedAccessPicker { managingAccess = false }
        }
    }
    private var settingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}
