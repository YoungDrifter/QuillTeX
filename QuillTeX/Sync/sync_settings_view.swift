import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject private var settings = SyncSettings.shared
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testIsError = false

    var body: some View {
        SettingsPage(
            title: "Sync",
            subtitle: "Upload PDFs and library details to Nutstore. One-way only."
        ) {
            SettingsCard(title: "Nutstore WebDAV") {
                VStack(alignment: .leading, spacing: 12) {
                    field("Account", text: $settings.account, prompt: "name@example.com")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("App password").font(.system(size: 12)).foregroundStyle(.secondary)
                        SecureField("Nutstore app password", text: $settings.password)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.flushPassword() }
                        Text("Use a Nutstore app password, not your account password.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    field("Remote folder", text: $settings.remoteFolder, prompt: "QuillTeX")
                    if let error = settings.credentialError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 8)

                Divider()

                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test Connection") { testConnection() }
                        .buttonStyle(SettingsActionStyle())
                        .disabled(testing || !settings.isConfigured)
                    if let testMessage {
                        Text(testMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(testIsError ? .red : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Link("Create an app password",
                         destination: URL(string: "https://help.jianguoyun.com/?p=2064")!)
                        .font(.system(size: 11))
                }
                .padding(.vertical, 10)
            }
        }
        .onAppear {
            settings.loadPasswordIfNeeded()
        }
        .onDisappear {
            settings.flushPassword()
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func testConnection() {
        settings.loadPasswordIfNeeded()
        guard let baseURL = settings.baseURL else {
            testMessage = "Enter a valid https:// WebDAV URL."
            testIsError = true
            return
        }
        guard !settings.trimmedAccount.isEmpty, !settings.password.isEmpty else {
            testMessage = "Enter the account and app password first."
            testIsError = true
            return
        }

        testing = true
        testMessage = nil
        testIsError = false
        let client = WebDAVClient(baseURL: baseURL,
                                  username: settings.trimmedAccount,
                                  password: settings.password)
        Task { @MainActor in
            do {
                try await client.testConnection()
                testing = false
                testMessage = "Connected"
                testIsError = false
            } catch {
                testing = false
                testMessage = error.localizedDescription
                testIsError = true
            }
        }
    }
}
