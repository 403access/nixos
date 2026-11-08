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

                Card("Server", systemImage: "network") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://nixos.tailnet.ts.net", text: $url)
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
                            .foregroundStyle(.secondary)
                    }
                }

                Card("Setup checklist", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: 12) {
                        checklistRow("1", "Install Tailscale on this iPhone and sign in to the same tailnet as your NixOS machine.")
                        checklistRow("2", "Enable HTTPS certificates for your tailnet in the Tailscale admin console, then run `sudo tailscale up` on the machine.")
                        checklistRow("3", "Read the token with `sudo nixos-control-token` or `sudo cat /var/lib/nixos-control/token`.")
                        checklistRow("4", "Enter the machine's Tailscale HTTPS URL above, for example `https://nixos.tailnet-name.ts.net`.")
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button(action: connect) {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isTesting ? "Connecting…" : "Save & Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(url.isEmpty || token.isEmpty || isTesting)

                Text("All traffic stays inside your Tailscale network. The API server never listens on the public internet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(background)
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
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .shadow(color: .accentColor.opacity(0.3), radius: 18, y: 8)

            Text("NixOS Control")
                .font(.largeTitle.bold())

            Text("Monitor and manage your NixOS machine from your pocket.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), Color(uiColor: .systemGroupedBackground)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func checklistRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
