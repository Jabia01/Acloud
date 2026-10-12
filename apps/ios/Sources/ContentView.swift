import SwiftUI
import HealthClient

struct ContentView: View {
    @State private var status = "Checking..."

    var body: some View {
        TabView {
            RestoreView().tabItem { Label("Restore", systemImage: "arrow.down.doc") }
            BackupQueueView().tabItem { Label("Backup Queue", systemImage: "arrow.up.doc") }
            DiscoveryView().tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            StorageView().tabItem { Label("Storage", systemImage: "externaldrive") }
            AccountView().tabItem { Label("Account", systemImage: "person") }
            #if DEBUG
            VStack(spacing: 16) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Acloud")
                .font(.largeTitle)
            Text("Development Build")
            Text("API Status: \(status)")
                .accessibilityLabel("API Status: \(status)")
            }
            .padding()
            .tabItem { Label("Development", systemImage: "heart.text.square") }
            #endif
        }
        .task { await checkHealth() }
    }

    @MainActor
    private func checkHealth() async {
        guard BetaReleaseSafety.acceptedConfiguration, let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let url = URL(string: value) else {
            status = "Unavailable"
            return
        }
        status = await HealthAPI(baseURL: url).isConnected() ? "Connected" : "Unavailable"
    }
}
