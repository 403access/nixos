import SwiftUI

struct LogsView: View {
    let title: String
    let unit: String?

    @EnvironmentObject private var app: AppState
    @State private var lines: [String] = []
    @State private var lineCount = 300
    @State private var autoRefresh = false
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading && lines.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Theme.surface)
            } else if lines.isEmpty {
                Text("No journal entries.")
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.border)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Auto refresh", isOn: $autoRefresh)
                    Picker("Lines", selection: $lineCount) {
                        Text("100").tag(100)
                        Text("300").tag(300)
                        Text("1000").tag(1000)
                    }
                    Button("Refresh now") {
                        Task { await load() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await load()
        }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if autoRefresh {
                    await load()
                }
            }
        }
        .onChange(of: lineCount) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        lines = await app.fetchLogs(unit: unit, lines: lineCount)
        isLoading = false
    }
}
