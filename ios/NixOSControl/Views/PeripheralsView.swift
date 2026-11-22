import Foundation
import SwiftUI

struct PeripheralsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = app.peripheralsError {
                    ErrorBanner(message: error)
                }

                if let report = app.peripherals {
                    receiverCard(report.receiver)
                    if report.devices.isEmpty {
                        emptyCard
                    } else {
                        ForEach(report.devices) { device in
                            deviceCard(device)
                        }
                    }
                } else if app.isLoadingPeripherals {
                    ProgressView("Reading receiver…")
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView(
                        "No receiver data",
                        systemImage: "keyboard",
                        description: Text(
                            "Pull to refresh or check that the Logitech receiver is connected."
                        )
                    )
                    .padding(.top, 24)
                }
            }
            .padding(16)
        }
        .appBackground()
        .navigationTitle("Peripherals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await app.loadPeripherals() }
                } label: {
                    if app.isLoadingPeripherals {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(app.isLoadingPeripherals)
            }
        }
        .refreshable {
            await app.loadPeripherals()
        }
        .task {
            await app.loadPeripherals()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled {
                    break
                }
                await app.loadPeripherals()
            }
        }
    }

    private func receiverCard(_ receiver: ReceiverInfo) -> some View {
        Card("Receiver", systemImage: "antenna.radiowaves.left.and.right") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receiver.product ?? "Logitech receiver")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(receiver.manufacturer ?? "Logitech")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                StatusBadge(text: receiver.kind, tint: Theme.accent)
            }

            InfoRow(label: "USB", value: usbID(receiver), monospaced: true)
            InfoRow(label: "Path", value: receiver.path, monospaced: true)
            InfoRow(label: "Serial", value: receiver.serial ?? "unknown", monospaced: true)
            InfoRow(
                label: "Slots",
                value: "\(receiver.pairedDevices) of \(receiver.maxDevices)"
            )
            if let remaining = receiver.remainingPairings {
                InfoRow(label: "Remaining", value: "\(remaining)")
            }

            firmwareView(receiver.firmware)
        }
    }

    private func deviceCard(_ device: DeviceInfo) -> some View {
        Card(
            "Slot \(device.slot) · \(device.kind ?? "device")",
            systemImage: deviceIcon(device.kind)
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name ?? device.kind ?? "Device \(device.slot)")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let wpid = device.wpid {
                        Text("WPID \(wpid)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer(minLength: 8)
                StatusBadge(
                    text: device.online ? "online" : "offline",
                    tint: device.online ? Theme.success : Theme.textMuted
                )
            }

            if let battery = device.battery {
                batteryView(battery)
            }

            InfoRow(label: "Serial", value: device.serial ?? "unknown", monospaced: true)
            if let signal = device.signal {
                InfoRow(label: "Signal", value: signalText(signal))
            }

            firmwareView(device.firmware)
        }
        .opacity(device.online ? 1 : 0.65)
    }

    private func batteryView(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(battery.percent.map { "\($0)%" } ?? "unknown")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
            }

            UsageBar(
                fraction: Double(battery.percent ?? 0) / 100,
                tint: batteryTint(battery.percent)
            )

            HStack {
                Text(statusText(battery.status))
                Spacer(minLength: 8)
                if let next = battery.nextPercent {
                    Text("next \(next)%")
                }
                if let voltage = battery.voltageMv {
                    Text(voltageText(voltage))
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private func firmwareView(_ entries: [FirmwareEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Firmware")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)

                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.kind)
                            .foregroundStyle(Theme.textSecondary)
                        if !entry.name.isEmpty {
                            Text(entry.name)
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer(minLength: 8)
                        Text(entry.version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var emptyCard: some View {
        Card("Paired devices", systemImage: "keyboard") {
            Text("No paired devices. The receiver is present, but nothing is currently paired.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func usbID(_ receiver: ReceiverInfo) -> String {
        String(format: "%04x:%04x", receiver.vendorId, receiver.productId)
    }

    private func deviceIcon(_ kind: String?) -> String {
        switch kind {
        case "keyboard", "numpad":
            return "keyboard"
        case "mouse":
            return "computermouse"
        case "trackball":
            return "computermouse"
        case "touchpad":
            return "rectangle.and.hand.point.up.left"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }

    private func batteryTint(_ percent: Int?) -> Color {
        guard let percent else {
            return Theme.textMuted
        }
        if percent >= 50 {
            return Theme.success
        }
        if percent >= 20 {
            return Theme.warning
        }
        return Theme.danger
    }

    private func voltageText(_ millivolts: Int) -> String {
        if millivolts >= 1_000 {
            return String(format: "%.2f V", Double(millivolts) / 1_000)
        }
        return "\(millivolts) mV"
    }

    private func signalText(_ signal: SignalInfo) -> String {
        signal.percent.map { "\($0)%" } ?? "raw \(signal.raw)"
    }

    private func statusText(_ status: String?) -> String {
        status?.replacingOccurrences(of: "_", with: " ") ?? "unknown"
    }
}