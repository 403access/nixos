import Foundation
import SwiftUI

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

enum DurationFormat {
    static func uptime(_ seconds: Int64) -> String {
        let value = max(0, seconds)
        let days = value / 86_400
        let hours = (value % 86_400) / 3_600
        let minutes = (value % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

enum PercentFormat {
    static func one(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func zero(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}

func usageFraction(_ used: Int64, _ total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(used) / Double(total)))
}

extension Color {
    static func serviceStatus(_ active: String) -> Color {
        switch active {
        case "active":
            return Theme.success
        case "failed":
            return Theme.danger
        case "activating", "deactivating", "reloading":
            return Theme.warning
        default:
            return Theme.textMuted
        }
    }

    static func poolHealth(_ health: String) -> Color {
        switch health.uppercased() {
        case "ONLINE":
            return Theme.success
        case "DEGRADED", "OFFLINE", "FAULTED", "UNAVAIL":
            return Theme.warning
        case "REMOVED":
            return Theme.danger
        default:
            return Theme.textMuted
        }
    }

    static func jobStatus(_ status: String) -> Color {
        switch status {
        case "running":
            return Theme.warning
        case "succeeded":
            return Theme.success
        case "failed":
            return Theme.danger
        case "cancelled":
            return Theme.textMuted
        default:
            return Theme.textSecondary
        }
    }
}
