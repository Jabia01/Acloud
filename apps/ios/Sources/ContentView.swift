import SwiftUI
import HealthClient

struct ContentView: View {
    @State private var status = "Checking..."

    var body: some View {
        TabView {
            DiscoveryView().tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            AccountView().tabItem { Label("Account", systemImage: "person") }
            VStack(spacing: 16) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Acloud")
                .font(.largeTitle)
            Text("Development Build")
            Text("API Status: \(status)")
                .accessibilityLabel("API Status: \(status)")
            }
            .padding()
            .tabItem { Label("Development", systemImage: "heart.text.square") }
        }
        .task { await checkHealth() }
    }

    @MainActor
    private func checkHealth() async {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
              let url = URL(string: value) else {
            status = "Unavailable"
            return
        }
        status = await HealthAPI(baseURL: url).isConnected() ? "Connected" : "Unavailable"
    }
}
