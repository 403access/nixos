import SwiftUI

enum ResourceMode: String, CaseIterable, Identifiable {
    case services = "Services"
    case apps = "Apps"
    case processes = "Processes"

    var id: String { rawValue }
}

enum ResourceSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case read = "Disk read"
    case write = "Disk write"

    var id: String { rawValue }
}

private struct ResourceRow: Identifiable {
    let id: String
    let name: String
    let kind: String
    let subtitle: String
    let cpu: Double
    let memory: Int64
    let read: Double
    let write: Double
}

struct ResourcesView: View {
    @EnvironmentObject private var app: AppState
    @State private var mode: ResourceMode = .services
    @State private var sort: ResourceSort = .cpu
    @State private var search = ""

    var body: some View {
        List {
            if let error = app.lastError, app.resources == nil {
                ErrorBanner(message: error)
                    .listRowBackground(Theme.surface)
            }

            if let usage = app.resources {
                summary(usage)

                Section {
                    Picker("Group", selection: $mode) {
                        ForEach(ResourceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Theme.surface)

                rowsSection(usage)

                Section {
                    Text("CPU is relative to one core and can exceed 100% on multi-core machines. Memory is resident memory (RSS) summed per process. Disk values are actual block I/O.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.surface)
            } else if app.isLoadingResources {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Sampling resource usage…")
                        Spacer()
                    }
                }
                .listRowBackground(Theme.surface)
            } else {
                ContentUnavailableView(
                    "No resource data yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("The server records resource usage every 5 seconds.")
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Resources")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search names, units or commands")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ResourceSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await app.loadResources() }
                } label: {
                    if app.isLoadingResources {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(app.isLoadingResources)
            }
        }
        .refreshable {
            await app.loadResources()
        }
        .task {
            await app.loadResources()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled {
                    break
                }
                await app.loadResources()
            }
        }
    }

    private func summary(_ usage: ResourceUsage) -> some View {
        Section("Totals") {
            InfoRow(
                label: "CPU",
                value: "\(String(format: "%.1f%%", usage.totalCpuPercent)) · \(usage.cpuCount) cores"
            )
            InfoRow(
                label: "Memory",
                value: "\(ByteFormat.string(usage.totalMemoryBytes)) of \(ByteFormat.string(usage.memoryTotal))"
            )
            InfoRow(label: "Disk read", value: rate(usage.totalReadBps))
            InfoRow(label: "Disk write", value: rate(usage.totalWriteBps))
            InfoRow(label: "Processes", value: "\(usage.processes.count)")
            InfoRow(label: "Sampled", value: SessionFormat.preciseTimestamp(usage.at))
        }
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.border)
    }

    @ViewBuilder
    private func rowsSection(_ usage: ResourceUsage) -> some View {
        let rows = filteredRows(usage)
        let maxCpu = max(100.0, rows.map(\.cpu).max() ?? 0)

        Section(mode.rawValue) {
            if rows.isEmpty {
                Text("No matching resource consumers.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(rows) { row in
                    ResourceRowView(row: row, maxCpu: maxCpu)
                }
            }
        }
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.border)
    }

    private func filteredRows(_ usage: ResourceUsage) -> [ResourceRow] {
        let rows: [ResourceRow]
        switch mode {
        case .services:
            rows = usage.services.map { entry in
                ResourceRow(
                    id: entry.id,
                    name: entry.name,
                    kind: entry.kind,
                    subtitle: entry.unit,
                    cpu: entry.cpuPercent,
                    memory: entry.memoryBytes,
                    read: entry.readBps,
                    write: entry.writeBps
                )
            }
        case .apps:
            rows = usage.apps.map { entry in
                ResourceRow(
                    id: entry.id,
                    name: entry.name,
                    kind: entry.kind,
                    subtitle: entry.unit,
                    cpu: entry.cpuPercent,
                    memory: entry.memoryBytes,
                    read: entry.readBps,
                    write: entry.writeBps
                )
            }
        case .processes:
            rows = usage.processes.map { process in
                ResourceRow(
                    id: "pid-\(process.pid)",
                    name: "\(process.name) · \(process.pid)",
                    kind: process.kind,
                    subtitle: process.command,
                    cpu: process.cpuPercent,
                    memory: process.memoryBytes,
                    read: process.readBps,
                    write: process.writeBps
                )
            }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? rows : rows.filter { row in
            [row.name, row.subtitle, row.kind]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }

        return matching.sorted { left, right in
            switch sort {
            case .cpu:
                return left.cpu > right.cpu
            case .memory:
                return left.memory > right.memory
            case .read:
                return left.read > right.read
            case .write:
                return left.write > right.write
            }
        }
    }

    private func rate(_ value: Double) -> String {
        "\(ByteFormat.string(Int64(value)))/s"
    }
}

private struct ResourceRowView: View {
    let row: ResourceRow
    let maxCpu: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StatusBadge(text: row.kind, tint: color)
                Spacer(minLength: 4)
                Text(String(format: "%.1f%%", row.cpu))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }

            Text(row.subtitle)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)

            HStack(spacing: 12) {
                Label(ByteFormat.string(row.memory), systemImage: "memorychip")
                Label("\(ByteFormat.string(Int64(row.read)))/s", systemImage: "arrow.down.circle")
                Label("\(ByteFormat.string(Int64(row.write)))/s", systemImage: "arrow.up.circle")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)

            UsageBar(fraction: row.cpu / maxCpu, tint: Theme.accent)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch row.kind {
        case "service":
            return Theme.accent
        case "machine":
            return Theme.warning
        case "app":
            return Theme.success
        default:
            return Theme.textMuted
        }
    }
}