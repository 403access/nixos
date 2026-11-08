import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @Binding var selection: AppTab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error = app.lastError {
                        ErrorBanner(message: error)
                    }

                    header

                    if let status = app.status {
                        metrics(status)
                        servicesCard(status)
                        poolsCard(status)
                        temperaturesCard(status)
                        networkCard(status)
                    } else if app.connectionState == .connecting {
                        ProgressView("Connecting…")
                            .padding(.top, 40)
                    } else {
                        ContentUnavailableView(
                            "No data yet",
                            systemImage: "bolt.horizontal.circle",
                            description: Text("Pull to refresh or check your connection.")
                        )
                        .padding(.top, 24)
                    }

                    footer
                }
                .padding(16)
            }
            .appBackground()
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.refreshStatus() }
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
            }
            .task {
                await app.refreshStatus()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if Task.isCancelled {
                        break
                    }
                    await app.refreshStatus()
                }
            }
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.status?.hostname ?? "NixOS")
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                        Text(app.status?.os ?? "Connecting to your machine…")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    connectionBadge
                }

                if let status = app.status {
                    HStack(spacing: 16) {
                        Label(DurationFormat.uptime(status.uptimeSeconds), systemImage: "clock")
                        Label(status.kernel, systemImage: "cpu")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                }
            }
        }
    }

    private var connectionBadge: some View {
        let info = connectionInfo
        return HStack(spacing: 6) {
            Circle()
                .fill(info.color)
                .frame(width: 8, height: 8)
            Text(info.text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(info.color.opacity(0.12), in: Capsule())
        .foregroundStyle(info.color)
    }

    private var connectionInfo: (text: String, color: Color) {
        switch app.connectionState {
        case .online:
            return ("Online", Theme.success)
        case .connecting:
            return ("Connecting", Theme.warning)
        case .offline:
            return ("Offline", Theme.danger)
        case .unknown:
            return ("Unknown", Theme.textMuted)
        }
    }

    private func metrics(_ status: SystemStatus) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            MetricTile(
                title: "CPU",
                value: PercentFormat.one(status.cpu.usagePercent),
                caption: "\(status.cpu.cores) cores",
                icon: "cpu",
                tint: Theme.accent,
                progress: status.cpu.usagePercent / 100
            )
            MetricTile(
                title: "Memory",
                value: ByteFormat.string(status.memory.used),
                caption: "of \(ByteFormat.string(status.memory.total))",
                icon: "memorychip",
                tint: Theme.teal,
                progress: usageFraction(status.memory.used, status.memory.total)
            )
            MetricTile(
                title: "Load average",
                value: status.load.map { String(format: "%.2f", $0) }.joined(separator: "  "),
                caption: "1 / 5 / 15 minutes",
                icon: "waveform.path.ecg",
                tint: Theme.warning
            )
            MetricTile(
                title: "Root disk",
                value: PercentFormat.one(status.rootDisk.usePercent),
                caption: "\(ByteFormat.string(status.rootDisk.used)) of \(ByteFormat.string(status.rootDisk.total))",
                icon: "internaldrive",
                tint: Theme.success,
                progress: status.rootDisk.usePercent / 100
            )
        }
    }

    private func servicesCard(_ status: SystemStatus) -> some View {
        Card("Services", systemImage: "gearshape.2") {
            HStack(spacing: 24) {
                countPill(value: status.services.running, label: "running", color: Theme.success)
                countPill(
                    value: status.services.failed,
                    label: "failed",
                    color: status.services.failed > 0 ? Theme.danger : Theme.textMuted
                )
                countPill(value: status.services.total, label: "total", color: Theme.textSecondary)
                Spacer(minLength: 0)
                Button("Manage") {
                    selection = .services
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
    }

    private func countPill(value: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func poolsCard(_ status: SystemStatus) -> some View {
        if !status.pools.isEmpty {
            Card("ZFS pools", systemImage: "externaldrive") {
                ForEach(status.pools) { pool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(pool.name)
                                .font(.subheadline.bold())
                            Spacer()
                            StatusBadge(text: pool.health, tint: .poolHealth(pool.health))
                        }
                        UsageBar(
                            fraction: usageFraction(pool.allocated, pool.size),
                            tint: .poolHealth(pool.health)
                        )
                        HStack {
                            Text("\(ByteFormat.string(pool.allocated)) of \(ByteFormat.string(pool.size))")
                            Spacer()
                            Text("\(ByteFormat.string(pool.free)) free")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                    }

                    if pool.id != status.pools.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func temperaturesCard(_ status: SystemStatus) -> some View {
        if !status.temperatures.isEmpty {
            Card("Temperatures", systemImage: "thermometer.medium") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(status.temperatures) { temperature in
                            VStack(spacing: 3) {
                                Text(String(format: "%.0f°C", temperature.celsius))
                                    .font(.headline)
                                    .monospacedDigit()
                                Text(temperature.label)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Theme.raised,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkCard(_ status: SystemStatus) -> some View {
        Card("Network", systemImage: "network") {
            if status.addresses.isEmpty {
                Text("No network addresses reported.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(status.addresses, id: \.self) { address in
                    Text(address)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let tailscale = status.tailscale {
                Divider()
                HStack {
                    Text("Tailscale")
                        .font(.subheadline)
                    Spacer()
                    StatusBadge(
                        text: tailscale.connected
                            ? (tailscale.dnsName.isEmpty ? "Connected" : tailscale.dnsName)
                            : tailscale.state.capitalized,
                        tint: tailscale.connected ? Theme.success : Theme.warning
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let updated = app.lastUpdated {
            Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 4)
        }
    }
}
