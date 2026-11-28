import SwiftUI

private enum FileSortOption: String, CaseIterable, Identifiable {
    case name
    case size
    case modified
    case type

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        case .type: return "Type"
        }
    }
}

private enum FileFilterOption: String, CaseIterable, Identifiable {
    case all
    case files
    case dirs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Everything"
        case .files: return "Files"
        case .dirs: return "Folders"
        }
    }
}

/// Read-only server-side file browser for a mounted filesystem. Mirrors the
/// web console's file explorer: breadcrumbs, recursive search, sorting and
/// type filters.
struct FileExplorerView: View {
    let filesystem: FilesystemInfo

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var path: String
    @State private var query = ""
    @State private var sort: FileSortOption = .name
    @State private var ascending = true
    @State private var filter: FileFilterOption = .all
    @State private var showHidden = false
    @State private var listing: FileListing?
    @State private var loading = false
    @State private var error: String?
    @State private var refreshTick = 0

    init(filesystem: FilesystemInfo) {
        self.filesystem = filesystem
        _path = State(initialValue: filesystem.mountpoint)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    breadcrumbs
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Theme.surface)
                }

                if let error {
                    Section {
                        ErrorBanner(message: error)
                            .listRowBackground(Theme.surface)
                    }
                }

                Section {
                    if loading && listing == nil {
                        HStack {
                            Spacer()
                            ProgressView("Reading files…")
                            Spacer()
                        }
                        .padding(.vertical, 20)
                        .listRowBackground(Theme.surface)
                    } else if let listing, listing.entries.isEmpty {
                        Text(searching ? "No files match this search." : "This folder is empty.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                    } else if let listing {
                        ForEach(listing.entries) { entry in
                            row(entry)
                                .listRowBackground(Theme.surface)
                                .listRowSeparatorTint(Theme.border)
                        }
                    }
                } header: {
                    Text("\(filesystem.source) · \(filesystem.fstype)")
                } footer: {
                    if let listing {
                        Text(
                            "\(listing.total) \(searching ? "matches" : "entries")"
                                + (listing.truncated ? " · limited" : "")
                                + (loading ? " · updating…" : "")
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(filesystem.mountpoint)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search this folder and below"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    optionsMenu
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let parent = listing?.parent {
                            path = parent
                            query = ""
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(listing?.parent == nil)

                    Button {
                        refreshTick += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load() }
        }
        .task(id: requestKey) {
            if searching {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            await load()
        }
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var requestKey: String {
        [path, query, sort.rawValue, ascending ? "asc" : "desc", filter.rawValue, showHidden ? "1" : "0", String(refreshTick)]
            .joined(separator: "|")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(FileSortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Button {
                ascending.toggle()
            } label: {
                Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
            }

            Picker("Show", selection: $filter) {
                ForEach(FileFilterOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Toggle("Hidden files", isOn: $showHidden)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Button {
                        path = crumb.path
                        query = ""
                    } label: {
                        Text(crumb.label)
                            .font(.caption.monospaced())
                            .foregroundStyle(index == crumbs.count - 1 ? Theme.textPrimary : Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == crumbs.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let content = FileRowView(
            entry: entry,
            subtitle: subtitle(for: entry)
        )

        if entry.isDirectory {
            Button {
                path = entry.path
                query = ""
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func subtitle(for entry: FileEntry) -> String {
        if searching {
            return relativePath(entry.path, from: listing?.path ?? path)
        }
        switch entry.kind {
        case "dir": return "Folder"
        case "symlink": return "Symlink"
        default: return "File"
        }
    }

    private struct Crumb: Identifiable {
        let label: String
        let path: String
        var id: String { path }
    }

    private var crumbs: [Crumb] {
        let root = filesystem.mountpoint
        let current = listing?.path ?? path
        let relative = relativePath(current, from: root)
        let parts = relative.split(separator: "/").map(String.init)

        var result = [Crumb(label: root == "/" ? "/" : root, path: root)]
        var running = root
        for part in parts {
            running = running == "/" ? "/\(part)" : "\(running)/\(part)"
            result.append(Crumb(label: part, path: running))
        }
        return result
    }

    private func relativePath(_ value: String, from base: String) -> String {
        if value == base {
            return ""
        }
        let prefix = base == "/" ? "/" : "\(base)/"
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }

        let next = await app.fetchFiles(
            root: filesystem.mountpoint,
            path: path,
            query: query,
            sort: sort.rawValue,
            order: ascending ? "asc" : "desc",
            filter: filter.rawValue,
            hidden: showHidden
        )

        if Task.isCancelled { return }
        if let next {
            listing = next
            error = nil
        } else {
            error = "Could not read this folder."
        }
    }
}

private struct FileRowView: View {
    let entry: FileEntry
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon)
                .font(.body)
                .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.textSecondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.isDirectory ? "—" : ByteFormat.string(entry.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                if let modified = entry.modified, !modified.isEmpty {
                    Text(SessionFormat.timestamp(modified))
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var fileIcon: String {
        switch entry.kind {
        case "symlink": return "arrow.turn.up.right"
        default: return "doc.text"
        }
    }
}