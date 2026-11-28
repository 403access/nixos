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

    @Published var connectionMethod: ConnectionMethod {
        didSet { defaults.set(connectionMethod.rawValue, forKey: Keys.connectionMethod) }
    }

    @Published private(set) var status: SystemStatus?
    @Published private(set) var services: [ServiceUnit] = []
    @Published private(set) var sandboxes: [Sandbox] = []
    @Published private(set) var sandboxList: SandboxList?
    @Published private(set) var storage: StorageSnapshot?
    @Published private(set) var generations: [Generation] = []
    @Published private(set) var peripherals: PeripheralsReport?
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var resources: ResourceUsage?
    @Published private(set) var themes: ThemeCatalog?
    @Published private(set) var isLoadingPeripherals = false
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var isLoadingResources = false
    @Published private(set) var isLoadingThemes = false
    @Published private(set) var peripheralsError: String?
    @Published private(set) var activeJob: Job?
    @Published private(set) var serverVersion: String?
    @Published private(set) var connectionState: ConnectionState = .unknown
    @Published private(set) var isRefreshingStatus = false
    @Published private(set) var isLoadingServices = false
    @Published private(set) var isLoadingSandboxes = false
    @Published private(set) var isLoadingStorage = false
    @Published private(set) var isLoadingGenerations = false
    @Published var lastError: String?
    @Published private(set) var lastUpdated: Date?

    private let defaults = UserDefaults.standard
    private var jobPollTask: Task<Void, Never>?

    private enum Keys {
        static let serverURL = "serverURL"
        static let tokenAccount = "api-token"
        static let connectionMethod = "connectionMethod"
    }

    init() {
        var initialURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? ""
        var initialToken = KeychainStore.read(account: Keys.tokenAccount) ?? ""
        let initialMethod = UserDefaults.standard.string(forKey: Keys.connectionMethod)
            .flatMap(ConnectionMethod.init(rawValue:)) ?? .tailscale

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
        connectionMethod = initialMethod
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
            // Tailscale names use HTTPS. IP addresses, mDNS names and
            // FRITZ!Box hostnames are reached over plain HTTP when the app is
            // connected through a LAN or router VPN.
            text = (isLocalHost(text) ? "http://" : "https://") + text
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

    private static func isLocalHost(_ value: String) -> Bool {
        let authority = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        let lowercased = host.lowercased()

        if !lowercased.contains(".")
            || lowercased.hasSuffix(".local")
            || lowercased.hasSuffix(".fritz.box") {
            return true
        }

        let parts = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    private var client: APIClient? {
        guard let url = normalizedURL, !token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    // MARK: - Configuration

    func testAndSave(serverURL: String, token: String) async -> String? {
        guard let url = Self.normalizeURL(serverURL) else {
            return "Enter a valid server URL, for example https://nixos.tailnet.ts.net or http://192.168.178.10:8787."
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
            peripherals = nil
            peripheralsError = nil
            sessions = []
            resources = nil
            themes = nil
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
        connectionMethod = .tailscale
        status = nil
        services = []
        sandboxes = []
        sandboxList = nil
        isLoadingSandboxes = false
        storage = nil
        generations = []
        peripherals = nil
        isLoadingPeripherals = false
        peripheralsError = nil
        sessions = []
        isLoadingSessions = false
        resources = nil
        isLoadingResources = false
        themes = nil
        isLoadingThemes = false
        activeJob = nil
        serverVersion = nil
        connectionState = .unknown
        lastError = nil
        lastUpdated = nil
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.connectionMethod)
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

    func loadSandboxes() async {
        guard let client, !isLoadingSandboxes else { return }
        isLoadingSandboxes = true
        defer { isLoadingSandboxes = false }

        do {
            let list = try await client.getSandboxes()
            sandboxList = list
            sandboxes = list.sandboxes
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Start, stop, remove or restart a sandbox. Returns an error message on
    /// failure, or nil when the action succeeded.
    func performSandboxAction(_ name: String, action: String) async -> String? {
        guard let client else { return "Not configured." }
        do {
            _ = try await client.sandboxAction(name: name, action: action)
            await loadSandboxes()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Create a sandbox and wait for the server-side create job so the list is
    /// up to date when the sheet closes. Returns an error message on failure.
    func createSandbox(_ request: SandboxCreateRequest) async -> String? {
        guard let client else { return "Not configured." }
        do {
            let job = try await client.createSandbox(request)
            activeJob = job

            var current = job
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let next: Job = try? await client.get("/api/jobs/\(job.id)") {
                    current = next
                    if !next.isRunning {
                        break
                    }
                }
            }
            await loadSandboxes()
            if let error = current.error, !error.isEmpty {
                return error
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func fetchSandboxLogs(_ name: String, lines: Int = 400) async -> [String]? {
        guard let client else { return nil }
        do {
            let response = try await client.getSandboxLogs(name: name, lines: lines)
            return response.lines
        } catch {
            lastError = error.localizedDescription
            return nil
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

    func fetchGenerationDiff(from: Int, to: Int) async -> GenerationDiff? {
        guard let client else { return nil }
        do {
            return try await client.get(
                "/api/system/generations/diff",
                query: [
                    URLQueryItem(name: "from", value: String(from)),
                    URLQueryItem(name: "to", value: String(to)),
                ]
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func loadPeripherals() async {
        guard let client, !isLoadingPeripherals else { return }
        isLoadingPeripherals = true
        defer { isLoadingPeripherals = false }

        do {
            peripherals = try await client.get("/api/peripherals")
            peripheralsError = nil
        } catch {
            peripheralsError = error.localizedDescription
        }
    }

    func loadSessions() async {
        guard let client, !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let response: SessionsResponse = try await client.get(
                "/api/sessions",
                query: [URLQueryItem(name: "limit", value: "100")]
            )
            sessions = response.sessions
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadResources() async {
        guard let client, !isLoadingResources else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }

        do {
            resources = try await client.get("/api/resources")
            lastError = nil
        } catch let error as APIError where error.statusCode == 503 {
            // The server is still taking its first resource sample.
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadThemes() async {
        guard let client, !isLoadingThemes else { return }
        isLoadingThemes = true
        defer { isLoadingThemes = false }

        do {
            themes = try await client.get("/api/themes")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyTheme(
        profile: String? = nil,
        gtkTheme: String? = nil,
        wallpaper: String? = nil
    ) async -> String? {
        guard let client else { return "Not configured." }
        do {
            let response: ThemeApplyResponse = try await client.post(
                "/api/themes/apply",
                body: ThemeApplyRequest(
                    profile: profile,
                    gtkTheme: gtkTheme,
                    wallpaper: wallpaper
                )
            )
            activeJob = response.job
            jobPollTask?.cancel()
            jobPollTask = Task { [weak self] in
                await self?.pollJob(id: response.job.id)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resetRdp(force: Bool = true) async -> RdpResetResult? {
        guard let client else { return nil }
        do {
            return try await client.post(
                "/api/rdp/reset",
                body: RdpResetRequest(force: force)
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func fetchResourceHistory(
        kind: String,
        minutes: Int,
        metric: String,
        top: Int = 8,
        entities: [String] = []
    ) async -> ResourceHistory? {
        guard let client else { return nil }
        var query = [
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "minutes", value: String(minutes)),
            URLQueryItem(name: "metric", value: metric),
            URLQueryItem(name: "top", value: String(top)),
        ]
        if !entities.isEmpty {
            query.append(URLQueryItem(name: "entities", value: entities.joined(separator: ",")))
        }
        do {
            return try await client.get("/api/resources/history", query: query)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func fetchSession(_ id: String, lines: Int = 300) async -> SessionDetail? {
        guard let client else { return nil }
        do {
            return try await client.get(
                "/api/sessions/\(APIClient.encodePathComponent(id))",
                query: [URLQueryItem(name: "lines", value: String(lines))]
            )
        } catch {
            lastError = error.localizedDescription
            return nil
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

    func fetchLogs(unit: String?, lines: Int) async -> LogsResponse? {
        guard let client else { return nil }
        let path = unit.map { "/api/services/\(APIClient.encodePathComponent($0))/logs" } ?? "/api/logs"
        do {
            return try await client.get(
                path,
                query: [URLQueryItem(name: "lines", value: String(lines))]
            )
        } catch {
            lastError = error.localizedDescription
            return nil
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

    func fetchFiles(
        root: String,
        path: String? = nil,
        query: String = "",
        sort: String = "name",
        order: String = "asc",
        filter: String = "all",
        hidden: Bool = false
    ) async -> FileListing? {
        guard let client else { return nil }
        var items = [
            URLQueryItem(name: "root", value: root),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "hidden", value: hidden ? "true" : "false"),
        ]
        if let path, !path.isEmpty {
            items.append(URLQueryItem(name: "path", value: path))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        do {
            return try await client.get("/api/storage/files", query: items)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func fetchStatusHistory(minutes: Int = 60, limit: Int = 720) async -> [StatusSample] {
        guard let client else { return [] }
        do {
            let response: StatusHistoryResponse = try await client.get(
                "/api/status/history",
                query: [
                    URLQueryItem(name: "minutes", value: String(minutes)),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
            )
            return response.samples
        } catch {
            lastError = error.localizedDescription
            return []
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
                    await loadThemes()
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

private struct ThemeApplyRequest: Encodable {
    let profile: String?
    let gtkTheme: String?
    let wallpaper: String?
}

private struct RdpResetRequest: Encodable {
    let force: Bool
}
