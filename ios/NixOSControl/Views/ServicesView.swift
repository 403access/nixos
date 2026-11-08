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
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?

    private struct PendingAction {
        let service: ServiceUnit
        let action: String
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
                } else if filteredServices.isEmpty {
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
                    ForEach(filteredServices) { service in
                        NavigationLink(value: service) {
                            ServiceRow(service: service)
                        }
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.border)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if service.isActive {
                                Button {
                                    perform(service, "restart")
                                } label: {
                                    Label("Restart", systemImage: "arrow.clockwise")
                                }
                                .tint(Theme.accent)
                            } else {
                                Button {
                                    perform(service, "start")
                                } label: {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .tint(Theme.success)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if service.isActive {
                                Button(role: .destructive) {
                                    pendingAction = PendingAction(service: service, action: "stop")
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                }
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
                    } label: {
                        Label(
                            "Filter",
                            systemImage: filter == .all
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

    private var filteredServices: [ServiceUnit] {
        let base: [ServiceUnit]
        switch filter {
        case .all:
            base = app.services
        case .running:
            base = app.services.filter(\.isActive)
        case .failed:
            base = app.services.filter(\.isFailed)
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? base : base.filter {
            $0.unit.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }

        return matching.sorted { first, second in
            if first.isFailed != second.isFailed {
                return first.isFailed
            }
            return first.unit.localizedStandardCompare(second.unit) == .orderedAscending
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

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.serviceStatus(service.active))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.shortName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !service.description.isEmpty {
                    Text(service.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
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
