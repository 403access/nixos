import Foundation

struct HealthResponse: Decodable {
    let ok: Bool
    let version: String
    let hostname: String
}

struct SystemStatus: Decodable {
    let serverVersion: String
    let hostname: String
    let os: String
    let kernel: String
    let nixosVersion: String
    let uptimeSeconds: Int64
    let bootTime: String
    let load: [Double]
    let cpu: CPUInfo
    let memory: MemoryInfo
    let rootDisk: DiskUsage
    let pools: [PoolSummary]
    let temperatures: [Temperature]
    let addresses: [String]
    let generation: Int
    let tailscale: TailscaleInfo?
    let services: ServiceCounts
    let capabilities: Capabilities
}

struct CPUInfo: Decodable {
    let model: String
    let cores: Int
    let usagePercent: Double
}

struct MemoryInfo: Decodable {
    let total: Int64
    let used: Int64
    let free: Int64
    let available: Int64
    let cached: Int64
    let swapTotal: Int64
    let swapUsed: Int64
}

struct DiskUsage: Decodable {
    let mount: String
    let total: Int64
    let used: Int64
    let available: Int64
    let usePercent: Double
}

struct PoolSummary: Decodable, Identifiable {
    let name: String
    let size: Int64
    let allocated: Int64
    let free: Int64
    let health: String
    let fragmentation: String

    var id: String { name }
}

struct Temperature: Decodable, Identifiable {
    let label: String
    let celsius: Double

    var id: String { label }
}

struct TailscaleInfo: Decodable {
    let connected: Bool
    let hostname: String
    let dnsName: String
    let ips: [String]
    let state: String
}

struct ServiceCounts: Decodable {
    let running: Int
    let failed: Int
    let total: Int
}

struct Capabilities: Decodable {
    let services: Bool
    let rebuild: Bool
    let power: Bool
}

struct ServiceUnit: Decodable, Identifiable, Hashable {
    let unit: String
    let load: String
    let active: String
    let sub: String
    let description: String

    var id: String { unit }

    var shortName: String {
        unit.hasSuffix(".service") ? String(unit.dropLast(".service".count)) : unit
    }

    var isFailed: Bool {
        active == "failed" || sub == "failed"
    }

    var isActive: Bool {
        active == "active"
    }
}

struct DatasetInfo: Decodable, Identifiable {
    let name: String
    let used: Int64
    let available: Int64
    let refer: Int64
    let mountpoint: String

    var id: String { name }
}

struct FilesystemInfo: Decodable, Identifiable {
    let source: String
    let fstype: String
    let size: Int64
    let used: Int64
    let available: Int64
    let usePercent: Double
    let mountpoint: String

    var id: String { mountpoint + "|" + source }
}

struct StorageSnapshot: Decodable {
    let pools: [PoolSummary]
    let datasets: [DatasetInfo]
    let filesystems: [FilesystemInfo]
}

struct GenerationsResponse: Decodable {
    let generations: [Generation]
}

struct Generation: Decodable, Identifiable {
    let number: Int
    let date: String
    let current: Bool

    var id: Int { number }
}

struct GenerationDiffEntry: Decodable, Identifiable {
    let name: String
    let change: String
    let before: String?
    let after: String?
    let size: String?
    let line: String

    var id: String { name + "|" + line }
}

struct GenerationDiff: Decodable {
    let from: Int
    let to: Int
    let entries: [GenerationDiffEntry]
    let lines: [String]
    let added: Int
    let removed: Int
    let changed: Int
    let truncated: Bool
}

struct Job: Decodable, Identifiable {
    let id: String
    let kind: String
    let status: String
    let startedAt: String
    let finishedAt: String?
    let exitCode: Int?
    let output: String
    let error: String?

    var isRunning: Bool { status == "running" }
}

struct ActionResponse: Decodable {
    let ok: Bool
}

struct LogsResponse: Decodable {
    let lines: [String]
    let entries: [LogEntry]
}

struct LogEntry: Decodable, Identifiable {
    let timestamp: String
    let priority: Int
    let level: String
    let message: String
    let identifier: String?
    let unit: String?
    let pid: Int?
    let hostname: String?
    let transport: String?
    let comm: String?
    let exe: String?

    var id: String {
        "\(timestamp)|\(priority)|\(identifier ?? "")|\(pid ?? 0)|\(message)"
    }
}

struct PoolStatusResponse: Decodable {
    let name: String
    let status: String
}

struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let source: String
    let title: String
    let user: String?
    let tty: String?
    let seat: String?
    let remoteHost: String?
    let service: String?
    let state: String
    let startedAt: String
    let lastActiveAt: String
    let actionCount: Int
    let status: String
    let summary: String
}

struct SessionsResponse: Decodable {
    let sessions: [SessionSummary]
}

struct SessionAction: Decodable, Identifiable {
    let id: String
    let at: String
    let action: String
    let target: String?
    let status: String
    let detail: String?
    let jobId: String?
    let output: String?
    let method: String?
    let path: String?
    let statusCode: Int?
    let durationMs: Int?
}

struct SessionCommand: Decodable {
    let at: String?
    let command: String
    let durationMs: Int?
    let exitCode: Int?
    let status: String?
    let cwd: String?
    let source: String?
}

struct SessionDetail: Decodable {
    let id: String
    let kind: String
    let source: String
    let title: String
    let user: String?
    let tty: String?
    let seat: String?
    let remoteHost: String?
    let service: String?
    let state: String
    let startedAt: String
    let lastActiveAt: String
    let actionCount: Int
    let status: String
    let summary: String
    let actions: [SessionAction]
    let logs: [String]
    let commands: [SessionCommand]
}

struct ResourceEntry: Decodable, Identifiable {
    let name: String
    let kind: String
    let unit: String
    let tasks: Int
    let cpuPercent: Double
    let memoryBytes: Int64
    let readBps: Double
    let writeBps: Double

    var id: String { unit + "|" + name }
}

struct ResourceProcess: Decodable, Identifiable {
    let pid: Int
    let name: String
    let command: String
    let unit: String
    let kind: String
    let cpuPercent: Double
    let memoryBytes: Int64
    let readBps: Double
    let writeBps: Double

    var id: Int { pid }
}

struct ResourceUsage: Decodable {
    let at: String
    let intervalMs: Int
    let cpuCount: Int
    let memoryTotal: Int64
    let totalCpuPercent: Double
    let totalMemoryBytes: Int64
    let totalReadBps: Double
    let totalWriteBps: Double
    let services: [ResourceEntry]
    let apps: [ResourceEntry]
    let processes: [ResourceProcess]
}

struct ResourceSeriesPoint: Decodable {
    let at: String
    let cpuPercent: Double
    let memoryBytes: Int64
    let readBps: Double
    let writeBps: Double
}

struct ResourceSeries: Decodable, Identifiable {
    let key: String
    let name: String
    let kind: String
    let points: [ResourceSeriesPoint]

    var id: String { key }
}

struct ResourceHistory: Decodable {
    let from: String
    let to: String
    let kind: String
    let series: [ResourceSeries]
    let totals: [ResourceSeriesPoint]
}

struct CurrentTheme: Decodable {
    let profile: String
    let flavour: String
    let accent: String
    let gtkTheme: String
    let wallpaper: String
}

struct ThemeCard: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let details: [String]
    let screenshot: String?
    let accent: String
    let current: Bool
}

struct ThemeCatalog: Decodable {
    let current: CurrentTheme
    let profiles: [ThemeCard]
    let gtkThemes: [ThemeCard]
    let wallpapers: [ThemeCard]
}

struct ThemeApplyResponse: Decodable {
    let theme: CurrentTheme
    let job: Job
}
