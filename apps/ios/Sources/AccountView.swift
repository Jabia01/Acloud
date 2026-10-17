import SwiftUI
import HealthClient

struct AccountView: View {
    private let api: AuthAPI?
    @State private var account: AccountStatus?
    @State private var email = ""
    @State private var password = ""
    @State private var message = ""
    @State private var busy = false
    private let deviceIdentifier: String
    init() {
        if BetaReleaseSafety.acceptedConfiguration, let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String, let url = URL(string: value) {
            api = AuthAPI(baseURL: url, store: KeychainSessionStore(service: (Bundle.main.bundleIdentifier ?? "com.example.backupclient") + ".session"))
        } else { api = nil }
        // This is non-secret device metadata; authentication tokens use Keychain only.
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "backup_device_identifier") { deviceIdentifier = existing }
        else { let created = UUID().uuidString; defaults.set(created, forKey: "backup_device_identifier"); deviceIdentifier = created }
    }
    var body: some View {
        Form {
            Section {
                AcloudHero(icon:"person.crop.circle",eyebrow:"Your Acloud",title:"A little peace of mind.",message:"Manage your sign-in and find help with backup, restore or privacy.").acloudFeatureRow()
            }

            if let account {
                Section("Your account") {
                    Label(account.email,systemImage:"person.crop.circle.fill").font(.headline)
                    Label(account.emailVerified ? "Email verified" : "Email unverified",systemImage:account.emailVerified ? "checkmark.seal.fill":"envelope.badge").foregroundStyle(account.emailVerified ? AcloudStyle.accent:Color.secondary)
                    Button("Sign Out") { Task { await signOut() } }.disabled(busy)
                }
            } else {
                Section("Account") {
                    TextField("Email", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Sign In") { Task { await signIn() } }.disabled(busy)
                    Button("Create Account") { Task { await register() } }.disabled(busy)
                    Text("New passwords require at least 12 characters. Verification and recovery links open on the Acloud website.").font(.footnote)
                }
            }
            TransferNotificationSettings()
            Section("Help") {
                Link("Contact support", destination: URL(string:"mailto:Support247.acloud@useacloud.com")!)
                Link("Privacy requests", destination: URL(string:"mailto:Privacy247.acloud@useacloud.com")!)
                Text("Never send passwords, verification codes or private photos. Staging support contact delivery is still being verified.").font(.footnote)
            }
            if !message.isEmpty { Text(message).accessibilityLabel(message) }
        }.acloudCanvas().task { if let api { account = try? await api.me() } }
    }
    @MainActor private func signIn() async {
        guard let api else { message = "API configuration unavailable."; return }
        busy = true; defer { busy = false }
        TransferNotifications.shared.signOut()
        AcloudPreviewRegistry.shared.clear()
        await RestoreModel.shared.invalidate()
        await StorageScreen.model.invalidate()
        do { try await BackupQueueModel.shared.stopForSignOut(); account = try await api.login(email: email, password: password, deviceIdentifier: deviceIdentifier); password = ""; message = "" }
        catch { message = "Unable to sign in. Check your credentials or connection." }
    }
    @MainActor private func register() async {
        guard let api else { message = "API configuration unavailable."; return }
        busy = true; defer { busy = false }
        do { try await api.register(email: email, password: password); password = ""; message = "If eligible, a verification email has been sent." }
        catch { message = "Unable to register. Use a valid email and at least 12 password characters." }
    }
    @MainActor private func signOut() async {
        guard let api else { return }
        busy = true; defer { busy = false }
        AcloudPreviewRegistry.shared.clear()
        await RestoreModel.shared.invalidate()
        await StorageScreen.model.invalidate()
        do { try await BackupQueueModel.shared.stopForSignOut(); try await api.logout(); TransferNotifications.shared.signOut(); account = nil; message = "Signed out." }
        catch { message = "Sign out could not be confirmed. Retry when connected." }
    }
}
