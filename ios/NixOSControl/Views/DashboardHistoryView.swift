import Charts
import SwiftUI

enum DashboardMetric: String, Identifiable {
    case cpu
    case memory
    case load
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU history"
        case .memory: return "Memory history"
        case .load: return "Load history"
        case .disk: return "Root disk history"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu: return "Usage sampled every 10 seconds"
        case .memory: return "Used memory over the last hour"
        case .load: return "1, 5 and 15 minute load averages"
        case .disk: return "Filesystem usage over time"
        }
    }
}

/// Mirrors the web dashboard's tile side panel: a server-side history chart,
/// min/avg/max, current values and the most recent samples.
struct DashboardHistoryView: View {
    let metric: DashboardMetric
    let status: SystemStatus

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var samples: [StatusSample] = []
    @State private var loading = true

    private struct HistoryPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if loading && samples.isEmpty {
                        ProgressView("Loading history…")
                            .padding(.top, 40)
                    } else if samples.isEmpty {
                        ContentUnavailableView(
                            "No history yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("The server records one sample every 10 seconds.")
                        )
                        .padding(.top, 24)
                    } else {
                        chartCard
                        statsCard
                    }

                    currentCard
                    recentCard
                }
                .padding(16)
            }
            .appBackground()
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private var chartCard: some View {
        Card(metric.subtitle, systemImage: "chart.xyaxis.line") {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: yDomain)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(format(number))
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
    }

    private var statsCard: some View {
        Card("Statistics", systemImage: "function") {
            let values = primaryValues
            if let min = values.min(), let max = values.max() {
                let average = values.reduce(0, +) / Double(values.count)
                HStack(spacing: 16) {
                    stat(label: "Min", value: format(min))
                    stat(label: "Average", value: format(average))
                    stat(label: "Max", value: format(max))
                    stat(label: "Samples", value: String(samples.count))
                }
            }
        }
    }

    private var currentCard: some View {
        Card("Current", systemImage: "gauge.with.dots.needle.50percent") {
            VStack(spacing: 8) {
                switch metric {
                case .cpu:
                    InfoRow(label: "Model", value: status.cpu.model)
                    InfoRow(label: "Cores", value: String(status.cpu.cores))
                    InfoRow(label: "Usage", value: PercentFormat.one(status.cpu.usagePercent))
                    InfoRow(label: "Load 1 / 5 / 15", value: status.load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                    InfoRow(label: "Uptime", value: DurationFormat.uptime(status.uptimeSeconds))
                    InfoRow(label: "Generation", value: String(status.generation))
                case .memory:
                    InfoRow(label: "Total", value: ByteFormat.string(status.memory.total))
                    InfoRow(label: "Used", value: ByteFormat.string(status.memory.used))
                    InfoRow(label: "Free", value: ByteFormat.string(status.memory.free))
                    InfoRow(label: "Available", value: ByteFormat.string(status.memory.available))
                    InfoRow(label: "Cached", value: ByteFormat.string(status.memory.cached))
                    InfoRow(label: "Swap", value: "\(ByteFormat.string(status.memory.swapUsed)) of \(ByteFormat.string(status.memory.swapTotal))")
                case .load:
                    InfoRow(label: "1 minute", value: String(format: "%.2f", status.load.first ?? 0))
                    InfoRow(label: "5 minutes", value: String(format: "%.2f", status.load.count > 1 ? status.load[1] : 0))
                    InfoRow(label: "15 minutes", value: String(format: "%.2f", status.load.count > 2 ? status.load[2] : 0))
                    InfoRow(label: "Cores", value: String(status.cpu.cores))
                    InfoRow(label: "Uptime", value: DurationFormat.uptime(status.uptimeSeconds))
                case .disk:
                    InfoRow(label: "Mount", value: status.rootDisk.mount, monospaced: true)
                    InfoRow(label: "Total", value: ByteFormat.string(status.rootDisk.total))
                    InfoRow(label: "Used", value: ByteFormat.string(status.rootDisk.used))
                    InfoRow(label: "Available", value: ByteFormat.string(status.rootDisk.available))
                    InfoRow(label: "Usage", value: PercentFormat.zero(status.rootDisk.usePercent))
                    InfoRow(label: "Generation", value: String(status.generation))
                }
            }
        }
    }

    @ViewBuilder
    private var recentCard: some View {
        let recent = samples.suffix(10).reversed()
        if !recent.isEmpty {
            Card("Recent samples", systemImage: "clock.arrow.circlepath") {
                VStack(spacing: 8) {
                    ForEach(Array(recent)) { sample in
                        HStack {
                            Text(SessionFormat.preciseTimestamp(sample.at))
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(format(primary(sample)))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var seriesNames: [String] {
        switch metric {
        case .load: return ["1 min", "5 min", "15 min"]
        case .cpu: return ["CPU"]
        case .memory: return ["Used"]
        case .disk: return ["Used"]
        }
    }

    private var points: [HistoryPoint] {
        samples.flatMap { sample -> [HistoryPoint] in
            guard let date = SessionFormat.date(sample.at) else { return [] }
            return seriesValues(sample).map {
                HistoryPoint(date: date, value: $0.value, series: $0.series)
            }
        }
    }

    private func seriesValues(_ sample: StatusSample) -> [(series: String, value: Double)] {
        switch metric {
        case .cpu:
            return [("CPU", sample.cpu.usagePercent)]
        case .memory:
            return [("Used", Double(sample.memory.used))]
        case .load:
            return [
                ("1 min", sample.load.first ?? 0),
                ("5 min", sample.load.count > 1 ? sample.load[1] : 0),
                ("15 min", sample.load.count > 2 ? sample.load[2] : 0),
            ]
        case .disk:
            return [("Used", sample.rootDisk.usePercent)]
        }
    }

    private func primary(_ sample: StatusSample) -> Double {
        switch metric {
        case .cpu: return sample.cpu.usagePercent
        case .memory: return Double(sample.memory.used)
        case .load: return sample.load.first ?? 0
        case .disk: return sample.rootDisk.usePercent
        }
    }

    private var primaryValues: [Double] {
        samples.map { primary($0) }
    }

    private var yDomain: ClosedRange<Double> {
        switch metric {
        case .memory:
            return 0...Double(max(status.memory.total, 1))
        case .cpu, .disk:
            return 0...100
        case .load:
            let maximum = max(samples.flatMap { $0.load }.max() ?? 1, 1)
            return 0...(maximum * 1.15)
        }
    }

    private func format(_ value: Double) -> String {
        switch metric {
        case .cpu, .disk: return PercentFormat.zero(value)
        case .memory: return ByteFormat.string(Int64(value))
        case .load: return String(format: "%.2f", value)
        }
    }

    @MainActor
    private func load() async {
        let next = await app.fetchStatusHistory(minutes: 60, limit: 720)
        if Task.isCancelled { return }
        samples = next
        loading = false
    }
}