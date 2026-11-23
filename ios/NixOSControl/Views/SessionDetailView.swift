import SwiftUI

struct SessionDetailView: View {
    let session: SessionSummary

    @EnvironmentObject private var app: AppState
    @State private var detail: SessionDetail?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let detail {
                sessionSection(detail)

                if !detail.actions.isEmpty {
                    Section("Actions") {
                        ForEach(detail.actions) { action in
                            SessionActionRow(action: action)
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.border)
                }

                if !detail.commands.isEmpty {
                    Section {
                        ForEach(Array(detail.commands.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 3) {
                                if let at = entry.at {
                                    Text(SessionFormat.timestamp(at))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textMuted)
                                }
                                Text(entry.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Shell history")
                    } footer: {
                        Text("Recent commands recovered from the user's shell history. Timestamps are approximate when the shell does not store them.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.border)
                }

                if !detail.logs.isEmpty {
                    Section("Logs") {
                        ForEach(Array(detail.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .listRowSeparatorTint(Theme.border)
                }
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading session…")
                        Spacer()
                    }
                }
                .listRowBackground(Theme.surface)
            } else {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                        Text(loadError ?? "Session details are unavailable.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            if detail == nil {
                await load()
            }
        }
    }

    @ViewBuilder
    private func sessionSection(_ detail: SessionDetail) -> some View {
        Section("Session") {
            InfoRow(label: "Source", value: sessionSourceLabel(detail.source))
            InfoRow(label: "Type", value: detail.kind == "app" ? "App actions" : "Host login")
            if let user = detail.user {
                InfoRow(label: "User", value: user)
            }
            if let service = detail.service {
                InfoRow(label: "Service", value: service)
            }
            if let tty = detail.tty {
                InfoRow(label: "TTY", value: tty, monospaced: true)
            }
            if let seat = detail.seat {
                InfoRow(label: "Seat", value: seat)
            }
            if let remoteHost = detail.remoteHost {
                InfoRow(label: "Remote", value: remoteHost, monospaced: true)
            }
            HStack {
                Text("State")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                StatusBadge(
                    text: detail.state.capitalized,
                    tint: .sessionStatus(detail.status)
                )
            }
            .font(.subheadline)
            InfoRow(label: "Started", value: SessionFormat.timestamp(detail.startedAt))
            InfoRow(label: "Last active", value: SessionFormat.timestamp(detail.lastActiveAt))
            InfoRow(label: "Actions", value: "\(detail.actionCount)")
        }
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.border)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let next = await app.fetchSession(session.id)
        detail = next
        loadError = next == nil ? (app.lastError ?? "Could not load the session.") : nil
    }
}

struct SessionActionRow: View {
    let action: SessionAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadge(
                    text: action.status,
                    tint: .sessionStatus(action.status)
                )
                Text(action.action + (action.target.map { " \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(SessionFormat.ago(action.at))
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            if let requestLine {
                Text(requestLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }

            if let detail = action.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            if let output = action.output, !output.isEmpty {
                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var requestLine: String? {
        guard let path = action.path else { return nil }
        var parts = ["\(action.method?.uppercased() ?? "POST") \(path)"]
        if let code = action.statusCode {
            parts.append("\(code)")
        }
        if let duration = action.durationMs {
            parts.append("\(duration)ms")
        }
        return parts.joined(separator: " · ")
    }
}