import SwiftUI
import Charts

enum ResourceMode: String, CaseIterable, Identifiable {
    case services = "Services"
    case apps = "Apps"
    case processes = "Processes"

    var id: String { rawValue }
}

enum ResourceHistoryKind: String, CaseIterable, Identifiable {
    case services = "Services"
    case apps = "Apps"

    var id: String { rawValue }

    var apiValue: String {
        self == .apps ? "apps" : "services"
    }
}

enum ResourceHistoryMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case read = "Disk read"
    case write = "Disk write"

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .read: return "read"
        case .write: return "write"
        }
    }
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

private struct ResourceChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let series: String
}

struct ResourcesView: View {
    @EnvironmentObject private var app: AppState
    @State private var mode: ResourceMode = .services
    @State private var sort: ResourceSort = .cpu
    @State private var search = ""
    @State private var history: ResourceHistory?
    @State private var historyKind: ResourceHistoryKind = .services
    @State private var historyMetric: ResourceHistoryMetric = .cpu
    @State private var historyMinutes = 15

    var body: some View {
        List {
            if let error = app.lastError, app.resources == nil {
                ErrorBanner(message: error)
                    .listRowBackground(Theme.surface)
            }

            if let usage = app.resources {
                summary(usage)
                historySection()

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
                    Task {
                        await app.loadResources()
                        await loadHistory()
                    }
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
            await loadHistory()
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
        .task {
            await loadHistory()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled {
                    break
                }
                await loadHistory()
            }
        }
        .onChange(of: historyKind) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: historyMetric) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: historyMinutes) { _, _ in
            Task { await loadHistory() }
        }
        .onChange(of: mode) { _, value in
            if value == .apps {
                historyKind = .apps
            } else if value == .services {
                historyKind = .services
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
    private func historySection() -> some View {
        let points = chartPoints

        Section {
            Picker("Entities", selection: $historyKind) {
                ForEach(ResourceHistoryKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Picker("Metric", selection: $historyMetric) {
                ForEach(ResourceHistoryMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            Picker("Range", selection: $historyMinutes) {
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            .pickerStyle(.menu)

            if points.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Collecting history…")
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(by: .value("Entity", point.series))
                    .interpolationMethod(.catmullRom)
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(formatMetric(number))
                                    .font(.system(size: 8, design: .monospaced))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 220)
                .padding(.vertical, 4)
            }
        } header: {
            Text("Usage over time")
        } footer: {
            Text("Top \(historyKind.rawValue.lowercased()) by \(historyMetric.rawValue.lowercased()). Five-second samples, kept for up to one hour.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.border)
    }

    private var chartPoints: [ResourceChartPoint] {
        guard let history else {
            return []
        }
        return history.series.flatMap { series in
            series.points.compactMap { point in
                guard let date = SessionFormat.date(point.at) else {
                    return nil
                }
                return ResourceChartPoint(
                    date: date,
                    value: metricValue(point),
                    series: series.name
                )
            }
        }
    }

    private func metricValue(_ point: ResourceSeriesPoint) -> Double {
        switch historyMetric {
        case .cpu:
            return point.cpuPercent
        case .memory:
            return Double(point.memoryBytes)
        case .read:
            return point.readBps
        case .write:
            return point.writeBps
        }
    }

    private func formatMetric(_ value: Double) -> String {
        switch historyMetric {
        case .cpu:
            return String(format: "%.0f%%", value)
        case .memory:
            return ByteFormat.string(Int64(value))
        case .read, .write:
            return "\(ByteFormat.string(Int64(value)))/s"
        }
    }

    private func loadHistory() async {
        history = await app.fetchResourceHistory(
            kind: historyKind.apiValue,
            minutes: historyMinutes,
            metric: historyMetric.apiValue,
            top: 8
        )
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