import SwiftUI

struct SandboxesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showCreate = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if app.sandboxList?.available == false {
                    ContentUnavailableView(
                        "Sandbox API is disabled",
                        systemImage: "shippingbox",
                        description: Text("Enable mySandbox on the host and restart nixos-control.")
                    )
                } else if app.sandboxes.isEmpty {
                    if app.isLoadingSandboxes {
                        ProgressView("Loading sandboxes…")
                    } else {
                        ContentUnavailableView(
                            "No sandboxes",
                            systemImage: "shippingbox",
                            description: Text("Tap + to create one, or run sudo agent-vm on the host.")
                        )
                    }
                } else {
                    List {
                        if let actionError {
                            ErrorBanner(message: actionError)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(app.sandboxes) { sandbox in
                            NavigationLink(value: sandbox) {
                                SandboxRow(sandbox: sandbox)
                            }
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.border)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if sandbox.running {
                                    Button {
                                        run(sandbox, "restart")
                                    } label: {
                                        Label("Restart", systemImage: "arrow.clockwise")
                                    }
                                    .tint(Theme.accent)
                                } else {
                                    Button {
                                        run(sandbox, "start")
                                    } label: {
                                        Label("Start", systemImage: "play.fill")
                                    }
                                    .tint(Theme.success)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if sandbox.running {
                                    Button(role: .destructive) {
                                        run(sandbox, "stop")
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppBackground())
            .navigationTitle("Sandboxes")
            .navigationDestination(for: Sandbox.self) { sandbox in
                SandboxDetailView(sandboxName: sandbox.name)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(app.sandboxList?.available == false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.loadSandboxes() }
                    } label: {
                        if app.isLoadingSandboxes {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isLoadingSandboxes)
                }
            }
            .refreshable {
                await app.loadSandboxes()
            }
            .task {
                if app.sandboxList == nil {
                    await app.loadSandboxes()
                }
            }
            .sheet(isPresented: $showCreate) {
                SandboxCreateView()
                    .environmentObject(app)
            }
        }
    }

    private func run(_ sandbox: Sandbox, _ action: String) {
        Task {
            if let message = await app.performSandboxAction(sandbox.name, action: action) {
                actionError = message
            } else {
                actionError = nil
            }
        }
    }
}

private struct SandboxRow: View {
    let sandbox: Sandbox

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(sandbox.name)
                    .font(.subheadline.bold())
                Spacer()
                StatusBadge(text: sandbox.status.capitalized, tint: sandbox.statusTint)
            }
            Text(sandbox.image)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            HStack(spacing: 10) {
                Label("\(sandbox.cpus) vCPU", systemImage: "cpu")
                Label("\(sandbox.memory) MiB", systemImage: "memorychip")
                Label(sandbox.networkLabel, systemImage: sandbox.online ? "network" : "wifi.slash")
                if sandbox.docker {
                    Label("docker", systemImage: "shippingbox")
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            if !sandbox.ports.isEmpty {
                Text(sandbox.ports.map { "\($0.address):\($0.host) → \($0.guest)" }.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SandboxDetailView: View {
    @EnvironmentObject private var app: AppState
    let sandboxName: String
    @State private var error: String?
    @State private var confirmRemove = false

    private var sandbox: Sandbox? {
        app.sandboxes.first { $0.name == sandboxName }
    }

    var body: some View {
        Group {
            if let sandbox {
                ScrollView {
                    VStack(spacing: 16) {
                        if let error {
                            ErrorBanner(message: error)
                        }

                        Card("Runtime", systemImage: "shippingbox") {
                            InfoRow(label: "Status", value: sandbox.status.capitalized)
                            InfoRow(label: "Image", value: sandbox.image, monospaced: true)
                            InfoRow(label: "Workspace", value: sandbox.workspace, monospaced: true)
                            InfoRow(label: "Network", value: sandbox.networkLabel)
                            InfoRow(label: "CPUs", value: "\(sandbox.cpus)")
                            InfoRow(label: "Memory", value: "\(sandbox.memory) MiB")
                            if sandbox.docker {
                                InfoRow(label: "Docker", value: "enabled")
                            }
                            if sandbox.ephemeral {
                                InfoRow(label: "Lifecycle", value: "ephemeral")
                            }
                            InfoRow(label: "Created", value: sandbox.created)
                        }

                        if !sandbox.ports.isEmpty || !sandbox.shares.isEmpty {
                            Card("Exposure", systemImage: "point.3.connected.trianglepath.dotted") {
                                ForEach(sandbox.ports) { port in
                                    InfoRow(
                                        label: "\(port.address):\(port.host)",
                                        value: "guest \(port.guest)",
                                        monospaced: true
                                    )
                                }
                                ForEach(sandbox.shares) { share in
                                    InfoRow(
                                        label: share.name,
                                        value: share.path + (share.readOnly ? " (ro)" : ""),
                                        monospaced: true
                                    )
                                }
                            }
                        }

                        Card("Actions", systemImage: "bolt") {
                            HStack(spacing: 10) {
                                if sandbox.running {
                                    Button("Restart") { run("restart") }
                                        .buttonStyle(.bordered)
                                    Button("Stop") { run("stop") }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Theme.danger)
                                } else {
                                    Button("Start") { run("start") }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Theme.success)
                                        .disabled(sandbox.status == "starting")
                                }
                                Spacer()
                            }

                            NavigationLink {
                                SandboxLogsView(name: sandbox.name)
                            } label: {
                                Label("View logs", systemImage: "text.alignleft")
                            }

                            Button(role: .destructive) {
                                confirmRemove = true
                            } label: {
                                Label("Remove sandbox", systemImage: "trash")
                            }
                        }
                    }
                    .padding(16)
                }
                .background(AppBackground())
            } else if app.isLoadingSandboxes {
                ProgressView("Loading sandbox…")
            } else {
                ContentUnavailableView(
                    "Sandbox not found",
                    systemImage: "shippingbox",
                    description: Text("It may have been removed.")
                )
            }
        }
        .navigationTitle(sandboxName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await app.loadSandboxes()
        }
        .confirmationDialog(
            "Remove \(sandboxName)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                run("remove")
            }
        } message: {
            Text("The workspace is kept on the host.")
        }
    }

    private func run(_ action: String) {
        Task {
            error = await app.performSandboxAction(sandboxName, action: action)
        }
    }
}

struct SandboxLogsView: View {
    @EnvironmentObject private var app: AppState
    let name: String
    @State private var lines: [String]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Log unavailable", systemImage: "text.alignleft", description: Text(error))
            } else if let lines {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No log output",
                        systemImage: "text.alignleft",
                        description: Text("The sandbox has not written anything yet, or its runtime log was cleared by a reboot.")
                    )
                } else {
                    ScrollView {
                        Text(lines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .background(AppBackground())
                }
            } else {
                ProgressView("Loading log…")
            }
        }
        .navigationTitle("\(name) logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        error = nil
        let response = await app.fetchSandboxLogs(name)
        if let response {
            lines = response
        } else {
            error = app.lastError ?? "Could not read the sandbox log."
            lines = []
        }
    }
}

struct SandboxCreateView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image = "docker.io/library/alpine:latest"
    @State private var workspace = ""
    @State private var cpus = 4
    @State private var memory = 4096
    @State private var online = false
    @State private var lan = false
    @State private var docker = false
    @State private var ports = ""
    @State private var command = ""
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Image", text: $image)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Workspace (optional)", text: $workspace)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Workspaces are created below \(app.sandboxList?.workspaceRoot ?? "/var/lib/agent-workspaces").")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                Section("Resources") {
                    Stepper("CPUs: \(cpus)", value: $cpus, in: 1...8)
                    Stepper("Memory: \(memory) MiB", value: $memory, in: 256...16384, step: 256)
                }

                Section("Network") {
                    Toggle("Internet egress", isOn: $online)
                    Toggle("Also allow LAN (never the host)", isOn: $lan)
                        .disabled(!online)
                    TextField("Ports (HOST:GUEST, comma separated)", text: $ports)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Runtime") {
                    Toggle("Start Docker inside the guest", isOn: $docker)
                    TextField("Command (optional, /bin/sh -c)", text: $command, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The image must contain dockerd when Docker is enabled. The guest cannot reach the host or another sandbox.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                if let error {
                    Section {
                        ErrorBanner(message: error)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("New sandbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isCreating)
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Enter a sandbox name."
            return
        }

        let parsed = parsePorts()
        if !ports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isEmpty {
            error = "Ports must be HOST:GUEST, for example 8080:80."
            return
        }

        let request = SandboxCreateRequest(
            name: trimmedName,
            image: image.trimmingCharacters(in: .whitespacesAndNewlines),
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines),
            cpus: cpus,
            memory: memory,
            online: online || lan,
            lan: lan,
            docker: docker,
            ephemeral: false,
            ports: parsed,
            shares: [],
            command: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : ["/bin/sh", "-c", command]
        )

        isCreating = true
        error = nil
        Task {
            let message = await app.createSandbox(request)
            isCreating = false
            if let message {
                error = message
            } else {
                dismiss()
            }
        }
    }

    private func parsePorts() -> [SandboxPortRequest] {
        ports
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .compactMap { value -> SandboxPortRequest? in
                let parts = value.split(separator: ":")
                guard parts.count == 2,
                      let host = Int(parts[0]),
                      let guest = Int(parts[1]),
                      host >= 1024,
                      (1...65535).contains(guest) else {
                    return nil
                }
                return SandboxPortRequest(address: nil, host: host, guest: guest)
            }
    }
}
