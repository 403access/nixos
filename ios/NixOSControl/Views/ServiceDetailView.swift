import SwiftUI

struct ServiceDetailView: View {
    let service: ServiceUnit

    @EnvironmentObject private var app: AppState
    @State private var logs: [String] = []
    @State private var isLoadingLogs = false
    @State private var autoRefresh = false
    @State private var lineCount = 200
    @State private var actionError: String?
    @State private var showStopConfirm = false
    @State private var showRestartConfirm = false

    private var current: ServiceUnit {
        app.services.first(where: { $0.unit == service.unit }) ?? service
    }

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    Circle()
                        .fill(Color.serviceStatus(current.active))
                        .frame(width: 10, height: 10)
                    Text(current.active.capitalized)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    StatusBadge(text: current.sub, tint: Color.serviceStatus(current.active))
                }
                InfoRow(label: "Unit", value: current.unit, monospaced: true)
                InfoRow(label: "Load state", value: current.load)
                if !current.description.isEmpty {
                    InfoRow(label: "Description", value: current.description)
                }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)

            Section("Actions") {
                HStack(spacing: 10) {
                    actionButton("Start", "play.fill", tint: Theme.success, disabled: current.isActive) {
                        perform("start")
                    }
                    actionButton("Restart", "arrow.clockwise", tint: Theme.accent) {
                        showRestartConfirm = true
                    }
                    actionButton("Stop", "stop.fill", tint: Theme.danger, disabled: !current.isActive) {
                        showStopConfirm = true
                    }
                }
                .padding(.vertical, 2)

                Menu {
                    Button("Enable at boot") { perform("enable") }
                    Button("Disable at boot") { perform("disable") }
                    if current.isFailed {
                        Button("Reset failed state") { perform("reset-failed") }
                    }
                } label: {
                    Label("Boot behaviour", systemImage: "power")
                }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)

            Section {
                Toggle("Auto refresh", isOn: $autoRefresh)

                if isLoadingLogs && logs.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if logs.isEmpty {
                    Text("No journal entries.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Journal")
            } footer: {
                Text("Showing the last \(lineCount) lines.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(service.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Lines", selection: $lineCount) {
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                    }
                    Button("Refresh now") {
                        Task { await loadLogs() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await loadLogs()
        }
        .task {
            await loadLogs()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if autoRefresh {
                    await loadLogs()
                }
            }
        }
        .onChange(of: lineCount) { _, _ in
            Task { await loadLogs() }
        }
        .alert("Stop \(current.shortName)?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) { perform("stop") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs systemctl stop \(current.unit).")
        }
        .alert("Restart \(current.shortName)?", isPresented: $showRestartConfirm) {
            Button("Restart") { perform("restart") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs systemctl restart \(current.unit).")
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
    }

    private func actionButton(
        _ title: String,
        _ icon: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
    }

    private func perform(_ action: String) {
        Task {
            if let error = await app.performServiceAction(service.unit, action: action) {
                actionError = error
            } else {
                await loadLogs()
            }
        }
    }

    private func loadLogs() async {
        isLoadingLogs = true
        logs = await app.fetchLogs(unit: service.unit, lines: lineCount)
        isLoadingLogs = false
    }
}
