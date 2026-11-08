import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var url = ""
    @State private var token = ""
    @State private var isTesting = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                Card("Connection method", systemImage: "point.3.connected.trianglepath.dotted") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Connection method", selection: $app.connectionMethod) {
                            ForEach(ConnectionMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)

                        Label(app.connectionMethod.subtitle, systemImage: app.connectionMethod.systemImage)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Card("Server", systemImage: "network") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(app.connectionMethod.urlPlaceholder, text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)

                        SecureField("API token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)

                        Text("The token is stored in the iOS Keychain.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                Card("Setup checklist", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(app.connectionMethod.checklist.enumerated()), id: \.offset) { _, item in
                            checklistRow(item.number, item.text)
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.danger.opacity(0.25), lineWidth: 1)
                        )
                }

                Button(action: connect) {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .tint(Theme.onAccent)
                        }
                        Text(isTesting ? "Connecting…" : "Save & Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(url.isEmpty || token.isEmpty || isTesting)

                Text(app.connectionMethod.footnote)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .appBackground()
        .onAppear {
            if url.isEmpty {
                url = app.serverURL
            }
            if token.isEmpty {
                token = app.token
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 92, height: 92)
                .background(
                    Theme.brandGradient,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .shadow(color: Theme.teal.opacity(0.3), radius: 18, y: 8)

            Text("NixOS Control")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.textPrimary)

            Text("Monitor and manage your NixOS machine from your pocket.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 20)
    }

    private func checklistRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption2.bold())
                .foregroundStyle(Theme.accentLight)
                .frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.15), in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        guard !isTesting else { return }
        isTesting = true
        message = nil

        Task {
            let error = await app.testAndSave(serverURL: url, token: token)
            isTesting = false
            if let error {
                message = error
            }
        }
    }
}
