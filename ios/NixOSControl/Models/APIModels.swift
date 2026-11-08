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
}

struct PoolStatusResponse: Decodable {
    let name: String
    let status: String
}
