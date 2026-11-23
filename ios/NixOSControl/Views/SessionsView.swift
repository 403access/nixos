import SwiftUI

enum SessionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case app = "App actions"
    case login = "Host logins"

    var id: String { rawValue }
}

func sessionSourceLabel(_ source: String) -> String {
    switch source {
    case "web": return "Web console"
    case "ios": return "iOS app"
    case "api": return "API client"
    case "ssh": return "SSH login"
    case "rdp": return "RDP login"
    case "console": return "Console login"
    default: return source
    }
}

func sessionSourceIcon(_ source: String) -> String {
    switch source {
    case "web": return "display"
    case "ios": return "iphone"
    case "api": return "terminal"
    case "ssh": return "network"
    case "rdp": return "rectangle.on.rectangle"
    case "console": return "desktopcomputer"
    default: return "clock.arrow.circlepath"
    }
}

extension SessionSummary {
    var sourceLabel: String { sessionSourceLabel(source) }

    var badgeText: String {
        kind == "login" ? state.capitalized : status.capitalized
    }

    var actionText: String {
        if kind == "login" {
            return actionCount > 0 ? "\(actionCount) commands" : "live login"
        }
        return "\(actionCount) action\(actionCount == 1 ? "" : "s")"
    }
}

struct SessionsView: View {
    @EnvironmentObject private var app: AppState
    @State private var search = ""
    @State private var filter: SessionFilter = .all

    var body: some View {
        NavigationStack {
            List {
                if app.isLoadingSessions && app.sessions.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading sessions…")
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.surface)
                } else if filteredSessions.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title2)
                                .foregroundStyle(Theme.textMuted)
                            Text(app.sessions.isEmpty ? "No sessions yet" : "No matching sessions")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(
                                app.sessions.isEmpty
                                    ? "Actions taken in the apps and host logins appear here."
                                    : "Change the search or filter."
                            )
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    ForEach(filteredSessions) { session in
                        NavigationLink(value: session) {
                            SessionRow(session: session)
                        }
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.border)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionSummary.self) { session in
                SessionDetailView(session: session)
            }
            .searchable(text: $search, prompt: "Search sessions, users or actions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(SessionFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        Label(
                            "Filter",
                            systemImage: filter == .all
                                ? "line.3.horizontal.decrease.circle"
                                : "line.3.horizontal.decrease.circle.fill"
                        )
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.loadSessions() }
                    } label: {
                        if app.isLoadingSessions {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isLoadingSessions)
                }
            }
            .refreshable {
                await app.loadSessions()
            }
            .task {
                await app.loadSessions()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if Task.isCancelled { break }
                    await app.loadSessions()
                }
            }
        }
    }

    private var filteredSessions: [SessionSummary] {
        let base: [SessionSummary]
        switch filter {
        case .all:
            base = app.sessions
        case .app:
            base = app.sessions.filter { $0.kind == "app" }
        case .login:
            base = app.sessions.filter { $0.kind == "login" }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? base : base.filter { session in
            [
                session.title,
                session.summary,
                session.user ?? "",
                session.remoteHost ?? "",
                session.source,
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }

        return matching.sorted { left, right in
            (SessionFormat.date(left.lastActiveAt) ?? .distantPast)
                > (SessionFormat.date(right.lastActiveAt) ?? .distantPast)
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sessionSourceIcon(session.source))
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusBadge(
                        text: session.badgeText,
                        tint: .sessionStatus(session.status)
                    )
                }

                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Text(session.sourceLabel)
                    if let user = session.user {
                        Label(user, systemImage: "person")
                    }
                    if let host = session.remoteHost {
                        Label(host, systemImage: "network")
                    }
                    Spacer(minLength: 0)
                    Text(SessionFormat.ago(session.lastActiveAt))
                    Text(session.actionText)
                }
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}