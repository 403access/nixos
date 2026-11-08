import SwiftUI

struct SystemView: View {
    @EnvironmentObject private var app: AppState
    @State private var rebuildAction = "switch"
    @State private var showRebuildConfirm = false
    @State private var pendingPower: PowerAction?
    @State private var actionError: String?
    @State private var powerNotice: String?

    private enum PowerAction: String, Identifiable {
        case reboot
        case shutdown

        var id: String { rawValue }

        var title: String {
            self == .reboot ? "Reboot" : "Shut down"
        }

        var message: String {
            self == .reboot
                ? "The machine will restart and the app will lose its connection."
                : "The machine will power off and the app will lose its connection."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error = app.lastError {
                        ErrorBanner(message: error)
                    }

                    if let status = app.status {
                        machineCard(status)
                        if status.capabilities.rebuild {
                            rebuildCard
                        }
                        if status.capabilities.power {
                            powerCard
                        }
                    } else if app.connectionState == .offline {
                        ContentUnavailableView(
                            "Server offline",
                            systemImage: "wifi.slash",
                            description: Text("Check Tailscale and the server, then pull to refresh.")
                        )
                        .padding(.top, 24)
                    } else {
                        ProgressView("Loading machine information…")
                            .padding(.top, 40)
                    }

                    generationsCard
                    journalLink
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("System")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await app.refreshStatus()
                            await app.loadGenerations()
                        }
                    } label: {
                        if app.isRefreshingStatus {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isRefreshingStatus)
                }
            }
            .refreshable {
                await app.refreshStatus()
                await app.loadGenerations()
            }
            .task {
                if app.status == nil {
                    await app.refreshStatus()
                }
                await app.loadGenerations()
                await app.loadLatestJob()
            }
            .confirmationDialog(
                "Run nixos-rebuild \(rebuildAction)?",
                isPresented: $showRebuildConfirm,
                titleVisibility: .visible
            ) {
                Button("Start rebuild") {
                    Task {
                        if let error = await app.startRebuild(action: rebuildAction) {
                            actionError = error
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(rebuildDescription)
            }
            .confirmationDialog(
                "Power action",
                isPresented: Binding(
                    get: { pendingPower != nil },
                    set: { if !$0 { pendingPower = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingPower
            ) { action in
                Button(action.title, role: .destructive) {
                    Task {
                        if let error = await app.requestPower(action: action.rawValue) {
                            actionError = error
                        } else {
                            powerNotice = "\(action.title) requested. The server will go offline."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(action.message)
            }
            .alert(
                "Action failed",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .alert(
                "Request sent",
                isPresented: Binding(
                    get: { powerNotice != nil },
                    set: { if !$0 { powerNotice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(powerNotice ?? "")
            }
        }
    }

    private var rebuildDescription: String {
        switch rebuildAction {
        case "boot":
            return "Build the configuration and set it as the default for the next boot. The running system is not changed."
        case "test":
            return "Build and activate the configuration for this boot only. It is not made the default."
        default:
            return "Build and activate the configuration immediately, and make it the default for the next boot."
        }
    }

    private func machineCard(_ status: SystemStatus) -> some View {
        Card("Machine", systemImage: "server.rack") {
            InfoRow(label: "NixOS", value: status.nixosVersion.isEmpty ? "Unknown" : status.nixosVersion)
            InfoRow(label: "Kernel", value: status.kernel)
            InfoRow(label: "Generation", value: "\(status.generation)")
            InfoRow(label: "Uptime", value: DurationFormat.uptime(status.uptimeSeconds))
            if let tailscale = status.tailscale {
                InfoRow(
                    label: "Tailscale",
                    value: tailscale.connected
                        ? (tailscale.dnsName.isEmpty ? "Connected" : tailscale.dnsName)
                        : tailscale.state
                )
            }
        }
    }

    private var rebuildCard: some View {
        Card("Rebuild", systemImage: "hammer") {
            Picker("Action", selection: $rebuildAction) {
                Text("Switch").tag("switch")
                Text("Boot").tag("boot")
                Text("Test").tag("test")
            }
            .pickerStyle(.segmented)

            Text(rebuildDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showRebuildConfirm = true
            } label: {
                Label("Start rebuild", systemImage: "hammer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.activeJob?.isRunning == true)

            if let job = app.activeJob {
                jobView(job)
            }
        }
    }

    private func jobView(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(text: job.status.capitalized, tint: .jobStatus(job.status))
                Spacer()
                Text(job.kind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if job.isRunning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !job.output.isEmpty {
                ScrollView {
                    Text(job.output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            if job.isRunning {
                Button("Cancel rebuild", role: .destructive) {
                    Task { await app.cancelActiveJob() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }

    private var powerCard: some View {
        Card("Power", systemImage: "power") {
            HStack(spacing: 10) {
                Button {
                    pendingPower = .reboot
                } label: {
                    Label("Reboot", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    pendingPower = .shutdown
                } label: {
                    Label("Shut down", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Text("Power actions take the server offline immediately.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var generationsCard: some View {
        Card("Generations", systemImage: "clock.arrow.circlepath") {
            if app.generations.isEmpty {
                if app.isLoadingGenerations {
                    ProgressView()
                } else {
                    Text("No generations reported.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(app.generations.sorted { $0.number > $1.number }.prefix(20))) { generation in
                    HStack(spacing: 8) {
                        Text("Generation \(generation.number)")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        if generation.current {
                            StatusBadge(text: "current", tint: .green)
                        }
                        Text(generation.date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var journalLink: some View {
        NavigationLink {
            LogsView(title: "System journal", unit: nil)
        } label: {
            HStack {
                Label("System journal", systemImage: "doc.text.magnifyingglass")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
