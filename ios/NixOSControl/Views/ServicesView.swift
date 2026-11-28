import SwiftUI

enum ServiceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case failed = "Failed"

    var id: String { rawValue }
}

struct ServicesView: View {
    @EnvironmentObject private var app: AppState
    @State private var search = ""
    @State private var filter: ServiceFilter = .all
    @State private var groupFilter: ServiceGroup?
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?

    private struct PendingAction {
        let service: ServiceUnit
        let action: String
    }

    private struct ServiceSection: Identifiable {
        let group: ServiceGroup
        let items: [GroupedService]

        var id: ServiceGroup { group }
    }

    var body: some View {
        NavigationStack {
            List {
                if app.isLoadingServices && app.services.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading services…")
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.surface)
                } else if groupedServices.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "gearshape.2")
                                .font(.title2)
                                .foregroundStyle(Theme.textMuted)
                            Text(app.services.isEmpty ? "No services loaded." : "No matching services.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    ForEach(groupedServices) { section in
                        Section {
                            ForEach(section.items) { item in
                                NavigationLink(value: item.service) {
                                    ServiceRow(service: item.service, tags: item.meta.tags)
                                }
                                .listRowBackground(Theme.surface)
                                .listRowSeparatorTint(Theme.border)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if item.service.isActive {
                                        Button {
                                            perform(item.service, "restart")
                                        } label: {
                                            Label("Restart", systemImage: "arrow.clockwise")
                                        }
                                        .tint(Theme.accent)
                                    } else {
                                        Button {
                                            perform(item.service, "start")
                                        } label: {
                                            Label("Start", systemImage: "play.fill")
                                        }
                                        .tint(Theme.success)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if item.service.isActive {
                                        Button(role: .destructive) {
                                            pendingAction = PendingAction(service: item.service, action: "stop")
                                        } label: {
                                            Label("Stop", systemImage: "stop.fill")
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.group.rawValue)
                                Spacer()
                                Text("\(section.items.count)")
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("Services")
            .navigationDestination(for: ServiceUnit.self) { service in
                ServiceDetailView(service: service)
            }
            .searchable(text: $search, prompt: "Search services")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(ServiceFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }

                        Divider()

                        Picker("Group", selection: $groupFilter) {
                            Text("All groups").tag(ServiceGroup?.none)
                            ForEach(ServiceGroup.allCases) { group in
                                Text(group.rawValue).tag(Optional(group))
                            }
                        }
                    } label: {
                        Label(
                            "Filter",
                            systemImage: filter == .all && groupFilter == nil
                                ? "line.3.horizontal.decrease.circle"
                                : "line.3.horizontal.decrease.circle.fill"
                        )
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.loadServices() }
                    } label: {
                        if app.isLoadingServices {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(app.isLoadingServices)
                }
            }
            .refreshable {
                await app.loadServices()
            }
            .task {
                if app.services.isEmpty {
                    await app.loadServices()
                }
            }
            .alert(
                "Stop service?",
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { if !$0 { pendingAction = nil } }
                ),
                presenting: pendingAction
            ) { pending in
                Button("Stop", role: .destructive) {
                    perform(pending.service, pending.action)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("Run systemctl stop \(pending.service.unit)? This may interrupt running work.")
            }
            .alert(
                "Action failed",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private var filteredItems: [GroupedService] {
        let base: [ServiceUnit]
        switch filter {
        case .all:
            base = app.services
        case .running:
            base = app.services.filter(\.isActive)
        case .failed:
            base = app.services.filter(\.isFailed)
        }

        var items = base.map { GroupedService(service: $0, meta: ServiceGroups.meta(for: $0)) }

        if let groupFilter {
            items = items.filter { $0.meta.group == groupFilter }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { item in
                item.service.unit.localizedCaseInsensitiveContains(query)
                    || item.service.description.localizedCaseInsensitiveContains(query)
                    || item.meta.group.rawValue.localizedCaseInsensitiveContains(query)
                    || item.meta.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        return items.sorted { first, second in
            if first.service.isFailed != second.service.isFailed {
                return first.service.isFailed
            }
            return first.service.unit.localizedStandardCompare(second.service.unit) == .orderedAscending
        }
    }

    private var groupedServices: [ServiceSection] {
        let items = filteredItems
        return ServiceGroup.allCases.compactMap { group in
            let bucket = items.filter { $0.meta.group == group }
            return bucket.isEmpty ? nil : ServiceSection(group: group, items: bucket)
        }
    }

    private func perform(_ service: ServiceUnit, _ action: String) {
        Task {
            if let error = await app.performServiceAction(service.unit, action: action) {
                actionError = error
            }
        }
    }
}

struct ServiceRow: View {
    let service: ServiceUnit
    var tags: [String] = []

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.serviceStatus(service.active))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.shortName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !service.description.isEmpty {
                    Text(service.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Text(service.sub)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 2)
    }
}
