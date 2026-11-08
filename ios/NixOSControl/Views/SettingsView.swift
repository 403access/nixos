import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var url = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var isSuccess = false
    @State private var showDisconnectConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Server URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("API token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: save) {
                        HStack {
                            if isSaving {
                                ProgressView()
                            }
                            Text(isSaving ? "Testing…" : "Save & test")
                        }
                    }
                    .disabled(url.isEmpty || token.isEmpty || isSaving)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isSuccess ? .green : .red)
                    }
                }

                Section {
                    Picker("Method", selection: $app.connectionMethod) {
                        ForEach(ConnectionMethod.allCases) { method in
                            Label(method.title, systemImage: method.systemImage)
                                .tag(method)
                        }
                    }
                } header: {
                    Text("Connection method")
                } footer: {
                    Text("Choose how this iPhone reaches the server. Changing the method does not alter the saved URL.")
                }

                Section("Server") {
                    LabeledContent("Status") {
                        Text(statusText)
                    }
                    if let hostname = app.status?.hostname {
                        LabeledContent("Hostname") {
                            Text(hostname)
                        }
                    }
                    if let version = app.serverVersion {
                        LabeledContent("API version") {
                            Text(version)
                        }
                    }
                    if let tailscale = app.status?.tailscale {
                        LabeledContent("Tailscale") {
                            Text(
                                tailscale.connected
                                    ? (tailscale.dnsName.isEmpty ? "Connected" : tailscale.dnsName)
                                    : tailscale.state
                            )
                        }
                    }
                    if let updated = app.lastUpdated {
                        LabeledContent("Last update") {
                            Text(updated.formatted(date: .omitted, time: .standard))
                        }
                    }
                }

                Section {
                    Text("sudo nixos-control-token")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("sudo cat /var/lib/nixos-control/token")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Reading the API token")
                } footer: {
                    Text("The token is generated on the NixOS machine at first start and stored in the iOS Keychain.")
                }

                Section(app.connectionMethod.title) {
                    Text(app.connectionMethod.settingsHelp)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("App") {
                        Text(appVersion)
                    }
                    LabeledContent("Server") {
                        Text(app.serverURL.isEmpty ? "Not configured" : app.serverURL)
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        showDisconnectConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                url = app.serverURL
                token = app.token
            }
            .confirmationDialog(
                "Disconnect from this server?",
                isPresented: $showDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    app.clearConfiguration()
                    url = ""
                    token = ""
                    message = nil
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var statusText: String {
        switch app.connectionState {
        case .online:
            return "Online"
        case .connecting:
            return "Connecting"
        case .offline:
            return "Offline"
        case .unknown:
            return "Unknown"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        message = nil

        Task {
            let error = await app.testAndSave(serverURL: url, token: token)
            isSaving = false
            if let error {
                isSuccess = false
                message = error
            } else {
                isSuccess = true
                message = "Connected to \(app.status?.hostname ?? "the server")."
                url = app.serverURL
                token = app.token
            }
        }
    }
}
