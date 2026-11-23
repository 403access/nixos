import SwiftUI

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case errors = "Errors"
    case warnings = "Warnings"
    case info = "Info"
    case debug = "Debug"

    var id: String { rawValue }
}

private struct LogGroup: Identifiable {
    let id: String
    let entry: LogEntry
    let count: Int
}

struct LogsView: View {
    let title: String
    let unit: String?

    @EnvironmentObject private var app: AppState
    @State private var response: LogsResponse?
    @State private var search = ""
    @State private var level: LogLevelFilter = .all
    @State private var lineCount = 300
    @State private var autoRefresh = false
    @State private var follow = true
    @State private var collapseRepeats = true
    @State private var expanded: Set<String> = []
    @State private var isLoading = false

    private var entries: [LogEntry] {
        response?.entries ?? []
    }

    private var groups: [LogGroup] {
        let terms = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            if !matches(entry, level: level) {
                return false
            }
            guard !terms.isEmpty else { return true }
            return [entry.message, entry.identifier ?? "", entry.unit ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(terms) }
        }

        guard collapseRepeats else {
            return filtered.enumerated().map { index, entry in
                LogGroup(id: "\(entry.id)#\(index)", entry: entry, count: 1)
            }
        }

        var result: [LogGroup] = []
        for entry in filtered {
            if let last = result.last,
               last.entry.priority == entry.priority,
               last.entry.message == entry.message,
               last.entry.identifier == entry.identifier,
               last.entry.unit == entry.unit {
                result[result.count - 1] = LogGroup(
                    id: last.id,
                    entry: last.entry,
                    count: last.count + 1
                )
            } else {
                result.append(
                    LogGroup(
                        id: "\(entry.id)#\(result.count)",
                        entry: entry,
                        count: 1
                    )
                )
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(LogLevelFilter.allCases) { filter in
                                Button {
                                    level = filter
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(filter.rawValue)
                                        Text("\(count(filter))")
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        level == filter
                                            ? Theme.accent.opacity(0.18)
                                            : Theme.raised.opacity(0.6),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                level == filter
                                                    ? Theme.accent.opacity(0.35)
                                                    : Theme.border,
                                                lineWidth: 1
                                            )
                                    )
                                    .foregroundStyle(
                                        level == filter ? Theme.accent : Theme.textSecondary
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                .listRowSeparator(.hidden)

                if let response, !response.entries.isEmpty {
                    ForEach(groups) { group in
                        LogGroupRow(
                            group: group,
                            expanded: expanded.contains(group.id),
                            onToggle: { toggle(group.id) }
                        )
                        .id(group.id)
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.border)
                    }
                } else if let response, !response.lines.isEmpty {
                    ForEach(Array(response.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .listRowBackground(Theme.surface)
                            .listRowSeparatorTint(Theme.border)
                    }
                } else if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Reading journal…")
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    ContentUnavailableView(
                        "No journal entries",
                        systemImage: "text.alignleft",
                        description: Text("The selected journal is empty.")
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search messages, units or identifiers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Lines", selection: $lineCount) {
                            Text("100").tag(100)
                            Text("300").tag(300)
                            Text("1000").tag(1000)
                            Text("2000").tag(2000)
                        }
                        Toggle("Auto refresh", isOn: $autoRefresh)
                        Toggle("Follow tail", isOn: $follow)
                        Toggle("Collapse repeats", isOn: $collapseRepeats)
                        Button("Refresh now") {
                            Task { await load() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onChange(of: groups.count) { _, _ in
                guard follow, let last = groups.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: follow) { _, value in
                guard value, let last = groups.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        .refreshable {
            await load()
        }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled || !autoRefresh {
                    continue
                }
                await load()
            }
        }
        .onChange(of: lineCount) { _, _ in
            Task { await load() }
        }
    }

    private func matches(_ entry: LogEntry, level: LogLevelFilter) -> Bool {
        switch level {
        case .all:
            return true
        case .errors:
            return entry.priority <= 3
        case .warnings:
            return entry.priority == 4
        case .info:
            return entry.priority == 5 || entry.priority == 6
        case .debug:
            return entry.priority == 7
        }
    }

    private func count(_ filter: LogLevelFilter) -> Int {
        entries.filter { matches($0, level: filter) }.count
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func load() async {
        isLoading = true
        response = await app.fetchLogs(unit: unit, lines: lineCount)
        isLoading = false
    }
}

private struct LogGroupRow: View {
    let group: LogGroup
    let expanded: Bool
    let onToggle: () -> Void

    private var entry: LogEntry { group.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(entry.level.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(tint)

                Text(SessionFormat.clock(entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)

                Text(source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if group.count > 1 {
                    Text("×\(group.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.raised, in: Capsule())
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    meta("Time", SessionFormat.preciseTimestamp(entry.timestamp))
                    if let unit = entry.unit { meta("Unit", unit) }
                    if let hostname = entry.hostname { meta("Host", hostname) }
                    if let transport = entry.transport { meta("Transport", transport) }
                    if let comm = entry.comm { meta("Command", comm) }
                    if let exe = entry.exe { meta("Executable", exe) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var source: String {
        let identifier = entry.identifier ?? entry.unit ?? "journal"
        if let pid = entry.pid {
            return "\(identifier)[\(pid)]"
        }
        return identifier
    }

    private var tint: Color {
        if entry.priority <= 3 { return Theme.danger }
        if entry.priority == 4 { return Theme.warning }
        if entry.priority == 6 { return Theme.accent }
        return Theme.textMuted
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }
}