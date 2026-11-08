import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum ConnectionState {
        case unknown
        case connecting
        case online
        case offline
    }

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    @Published var token: String {
        didSet { KeychainStore.save(token, account: Keys.tokenAccount) }
    }

    @Published private(set) var status: SystemStatus?
    @Published private(set) var services: [ServiceUnit] = []
    @Published private(set) var storage: StorageSnapshot?
    @Published private(set) var generations: [Generation] = []
    @Published private(set) var activeJob: Job?
    @Published private(set) var serverVersion: String?
    @Published private(set) var connectionState: ConnectionState = .unknown
    @Published private(set) var isRefreshingStatus = false
    @Published private(set) var isLoadingServices = false
    @Published private(set) var isLoadingStorage = false
    @Published private(set) var isLoadingGenerations = false
    @Published var lastError: String?
    @Published private(set) var lastUpdated: Date?

    private let defaults = UserDefaults.standard
    private var jobPollTask: Task<Void, Never>?

    private enum Keys {
        static let serverURL = "serverURL"
        static let tokenAccount = "api-token"
    }

    init() {
        var initialURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? ""
        var initialToken = KeychainStore.read(account: Keys.tokenAccount) ?? ""

        #if DEBUG
        // Allows running the app against a local fixture server during development.
        let environment = ProcessInfo.processInfo.environment
        if let overrideURL = environment["NIXOS_CONTROL_SERVER"], !overrideURL.isEmpty {
            initialURL = overrideURL
            initialToken = environment["NIXOS_CONTROL_TOKEN"] ?? ""
        }
        #endif

        serverURL = initialURL
        token = initialToken
    }

    var isConfigured: Bool {
        normalizedURL != nil && !token.isEmpty
    }

    var normalizedURL: URL? {
        Self.normalizeURL(serverURL)
    }

    static func normalizeURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        if components.scheme == nil {
            components.scheme = "https"
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    private var client: APIClient? {
        guard let url = normalizedURL, !token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    // MARK: - Configuration

    func testAndSave(serverURL: String, token: String) async -> String? {
        guard let url = Self.normalizeURL(serverURL) else {
            return "Enter a valid server URL, for example https://nixos.tailnet.ts.net."
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return "Enter the API token."
        }

        connectionState = .connecting
        do {
            let health: HealthResponse = try await APIClient(baseURL: url, token: trimmedToken).get("/api/health")
            self.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            self.token = trimmedToken
            serverVersion = health.version
            connectionState = .online
            lastError = nil
            await refreshStatus()
            return nil
        } catch {
            connectionState = .offline
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func clearConfiguration() {
        jobPollTask?.cancel()
        jobPollTask = nil
        serverURL = ""
        token = ""
        status = nil
        services = []
        storage = nil
        generations = []
        activeJob = nil
        serverVersion = nil
        connectionState = .unknown
        lastError = nil
        lastUpdated = nil
        defaults.removeObject(forKey: Keys.serverURL)
        KeychainStore.delete(account: Keys.tokenAccount)
    }

    // MARK: - Loading

    func refreshStatus() async {
        guard let client else { return }
        if isRefreshingStatus { return }

        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        do {
            let status: SystemStatus = try await client.get("/api/status")
            self.status = status
            serverVersion = status.serverVersion
            connectionState = .online
            lastUpdated = Date()
            lastError = nil
        } catch {
            connectionState = .offline
            lastError = error.localizedDescription
        }
    }

    func loadServices() async {
        guard let client, !isLoadingServices else { return }
        isLoadingServices = true
        defer { isLoadingServices = false }

        do {
            services = try await client.get("/api/services")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadStorage() async {
        guard let client, !isLoadingStorage else { return }
        isLoadingStorage = true
        defer { isLoadingStorage = false }

        do {
            storage = try await client.get("/api/storage")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadGenerations() async {
        guard let client, !isLoadingGenerations else { return }
        isLoadingGenerations = true
        defer { isLoadingGenerations = false }

        do {
            let response: GenerationsResponse = try await client.get("/api/system/generations")
            generations = response.generations
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLatestJob() async {
        guard let client else { return }
        do {
            let jobs: [Job] = try await client.get("/api/jobs")
            if let latest = jobs.first {
                activeJob = latest
            }
        } catch {
            // Not fatal: the jobs endpoint is optional for the rest of the UI.
        }
    }

    func fetchLogs(unit: String?, lines: Int) async -> [String] {
        guard let client else { return [] }
        let path = unit.map { "/api/services/\(APIClient.encodePathComponent($0))/logs" } ?? "/api/logs"
        do {
            let response: LogsResponse = try await client.get(
                path,
                query: [URLQueryItem(name: "lines", value: String(lines))]
            )
            return response.lines
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func fetchPoolStatus(_ name: String) async -> String? {
        guard let client else { return nil }
        do {
            let response: PoolStatusResponse = try await client.get(
                "/api/storage/pools/\(APIClient.encodePathComponent(name))"
            )
            return response.status
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Actions

    func performServiceAction(_ unit: String, action: String) async -> String? {
        guard let client else { return "Not configured." }
        do {
            let _: ActionResponse = try await client.post(
                "/api/services/\(APIClient.encodePathComponent(unit))/\(action)"
            )
            await loadServices()
            await refreshStatus()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func startRebuild(action: String) async -> String? {
        guard let client else { return "Not configured." }
        do {
            let job: Job = try await client.post(
                "/api/system/rebuild",
                body: RebuildRequest(action: action)
            )
            activeJob = job
            jobPollTask?.cancel()
            jobPollTask = Task { [weak self] in
                await self?.pollJob(id: job.id)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func cancelActiveJob() async {
        guard let client, let job = activeJob else { return }
        do {
            let updated: Job = try await client.post("/api/jobs/\(job.id)/cancel")
            activeJob = updated
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requestPower(action: String) async -> String? {
        guard let client else { return "Not configured." }
        do {
            let _: ActionResponse = try await client.post(
                "/api/system/power",
                body: PowerRequest(action: action)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func pollJob(id: String) async {
        var failures = 0

        while !Task.isCancelled {
            guard let client else { return }
            do {
                let job: Job = try await client.get("/api/jobs/\(id)")
                activeJob = job
                failures = 0
                if job.status != "running" {
                    await refreshStatus()
                    return
                }
            } catch {
                failures += 1
                if failures >= 5 {
                    lastError = error.localizedDescription
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}

private struct RebuildRequest: Encodable {
    let action: String
}

private struct PowerRequest: Encodable {
    let action: String
}
