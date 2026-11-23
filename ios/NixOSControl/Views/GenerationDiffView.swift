import SwiftUI

struct GenerationDiffView: View {
    let generations: [Generation]

    @EnvironmentObject private var app: AppState
    @State private var from = 0
    @State private var to = 0
    @State private var diff: GenerationDiff?
    @State private var isLoading = false
    @State private var loadError: String?

    private var sorted: [Generation] {
        generations.sorted { $0.number < $1.number }
    }

    var body: some View {
        List {
            Section("Compare") {
                Picker("From", selection: $from) {
                    ForEach(sorted) { generation in
                        Text("Generation \(generation.number) — \(generation.date)")
                            .tag(generation.number)
                    }
                }

                Picker("To", selection: $to) {
                    ForEach(sorted) { generation in
                        Text("Generation \(generation.number) — \(generation.date)")
                            .tag(generation.number)
                    }
                }

                Button {
                    Task { await load(from: from, to: to) }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Label("Compare generations", systemImage: "arrow.left.arrow.right")
                    }
                }
                .disabled(isLoading || sorted.count < 2 || from == 0 || to == 0 || from == to)
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)

            if let diff {
                summarySection(diff)
                resultSections(diff)
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Comparing…")
                        Spacer()
                    }
                }
                .listRowBackground(Theme.surface)
            } else if let loadError {
                Section {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(Theme.danger)
                }
                .listRowBackground(Theme.surface)
            } else if sorted.count < 2 {
                Section {
                    Text("At least two generations are needed to compare configurations.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Compare generations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if from != 0 && to != 0 && from != to {
                await load(from: from, to: to)
            }
        }
        .task {
            let pair = defaultPair()
            if from == 0 {
                from = pair.from
                to = pair.to
            }
            if diff == nil && from != 0 && to != 0 && from != to {
                await load(from: from, to: to)
            }
        }
    }

    private func defaultPair() -> (from: Int, to: Int) {
        guard sorted.count >= 2 else {
            return (sorted.last?.number ?? 0, sorted.last?.number ?? 0)
        }
        return (sorted[sorted.count - 2].number, sorted[sorted.count - 1].number)
    }

    private func load(from: Int, to: Int) async {
        guard from != 0, to != 0, from != to else { return }
        isLoading = true
        loadError = nil
        let result = await app.fetchGenerationDiff(from: from, to: to)
        diff = result
        if result == nil {
            loadError = app.lastError ?? "Could not compare these generations."
        }
        isLoading = false
    }

    @ViewBuilder
    private func summarySection(_ diff: GenerationDiff) -> some View {
        Section("Summary") {
            InfoRow(label: "From", value: "Generation \(diff.from)")
            InfoRow(label: "To", value: "Generation \(diff.to)")

            HStack(spacing: 8) {
                StatusBadge(text: "\(diff.added) added", tint: Theme.success)
                StatusBadge(text: "\(diff.removed) removed", tint: Theme.danger)
                StatusBadge(text: "\(diff.changed) changed", tint: Theme.warning)
                Spacer(minLength: 0)
            }

            if diff.truncated {
                Text("The diff output was truncated.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.border)
    }

    @ViewBuilder
    private func resultSections(_ diff: GenerationDiff) -> some View {
        if diff.entries.isEmpty && diff.lines.isEmpty {
            Section {
                Text("No package changes between these generations.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        } else if !diff.entries.isEmpty {
            Section("Changes") {
                ForEach(diff.entries) { entry in
                    GenerationDiffRow(entry: entry)
                }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)
        } else {
            Section("Changes") {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)
        }

        if !diff.entries.isEmpty && !diff.lines.isEmpty {
            Section("Raw output") {
                DisclosureGroup("Show raw output") {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.border)
        }
    }
}

struct GenerationDiffRow: View {
    let entry: GenerationDiffEntry

    private var icon: String {
        switch entry.change {
        case "added":
            return "plus.circle.fill"
        case "removed":
            return "minus.circle.fill"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch entry.change {
        case "added":
            return Theme.success
        case "removed":
            return Theme.danger
        default:
            return Theme.warning
        }
    }

    private var versions: String? {
        guard entry.before != nil || entry.after != nil else { return nil }
        return "\(entry.before ?? "∅") → \(entry.after ?? "∅")"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let versions {
                    Text(versions)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            if let size = entry.size {
                Text(size)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }
}