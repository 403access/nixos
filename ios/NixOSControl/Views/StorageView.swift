import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var app: AppState
    @State private var selectedPool: PoolSummary?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error = app.lastError {
                        ErrorBanner(message: error)
                    }

                    if let storage = app.storage {
                        poolsSection(storage)
                        datasetsSection(storage)
                        filesystemsSection(storage)
                    } else if app.isLoadingStorage {
                        ProgressView("Loading storage…")
                            .padding(.top, 40)
                    } else {
                        ContentUnavailableView(
                            "No storage data",
                            systemImage: "internaldrive",
                            description: Text("Pull to refresh.")
                        )
                        .padding(.top, 24)
                    }
                }
                .padding(16)
            }
            .appBackground()
            .navigationTitle("Storage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.loadStorage() }
                    } label: {
                        if app.isLoadingStorage {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isLoadingStorage)
                }
            }
            .refreshable {
                await app.loadStorage()
            }
            .task {
                if app.storage == nil {
                    await app.loadStorage()
                }
            }
            .sheet(item: $selectedPool) { pool in
                PoolStatusSheet(pool: pool)
                    .environmentObject(app)
            }
        }
    }

    @ViewBuilder
    private func poolsSection(_ storage: StorageSnapshot) -> some View {
        if !storage.pools.isEmpty {
            Card("ZFS pools", systemImage: "externaldrive.connected.to.line.below") {
                ForEach(storage.pools) { pool in
                    Button {
                        selectedPool = pool
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(pool.name)
                                    .font(.subheadline.bold())
                                Spacer()
                                StatusBadge(text: pool.health, tint: .poolHealth(pool.health))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
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

                            if pool.fragmentation != "-" && !pool.fragmentation.isEmpty {
                                Text("Fragmentation \(pool.fragmentation)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if pool.id != storage.pools.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func datasetsSection(_ storage: StorageSnapshot) -> some View {
        if !storage.datasets.isEmpty {
            Card("ZFS datasets", systemImage: "square.stack.3d.up") {
                ForEach(storage.datasets) { dataset in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dataset.name)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                            Text(dataset.mountpoint)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteFormat.string(dataset.used))
                                .font(.caption)
                            Text("\(ByteFormat.string(dataset.available)) free")
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    if dataset.id != storage.datasets.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filesystemsSection(_ storage: StorageSnapshot) -> some View {
        if !storage.filesystems.isEmpty {
            Card("Filesystems", systemImage: "internaldrive") {
                ForEach(storage.filesystems) { filesystem in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(filesystem.mountpoint)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Spacer()
                            Text(PercentFormat.zero(filesystem.usePercent))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(filesystem.usePercent >= 90 ? Theme.danger : Theme.textSecondary)
                        }
                        UsageBar(
                            fraction: filesystem.usePercent / 100,
                            tint: filesystem.usePercent >= 90 ? Theme.danger : Theme.accent
                        )
                        HStack {
                            Text("\(filesystem.source) · \(filesystem.fstype)")
                            Spacer()
                            Text("\(ByteFormat.string(filesystem.used)) of \(ByteFormat.string(filesystem.size))")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    }

                    if filesystem.id != storage.filesystems.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

struct PoolStatusSheet: View {
    let pool: PoolSummary

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var statusText = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    } else {
                        Text(statusText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .appBackground()
            .navigationTitle(pool.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        isLoading = true
        statusText = await app.fetchPoolStatus(pool.name) ?? "Could not load pool status."
        isLoading = false
    }
}
