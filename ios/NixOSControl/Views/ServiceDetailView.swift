import SwiftUI

struct ServiceDetailView: View {
    let service: ServiceUnit

    @EnvironmentObject private var app: AppState
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
                NavigationLink {
                    LogsView(title: "\(current.shortName) journal", unit: current.unit)
                } label: {
                    Label("Open journal", systemImage: "text.alignleft")
                }
            } header: {
                Text("Journal")
            } footer: {
                Text("Structured entries with severity filters, search and expandable metadata.")
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
            }
        }
    }
}
