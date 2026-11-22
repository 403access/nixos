import Foundation

struct PeripheralsReport: Decodable {
    let receiver: ReceiverInfo
    let devices: [DeviceInfo]
}

struct ReceiverInfo: Decodable {
    let product: String?
    let manufacturer: String?
    let vendorId: UInt16
    let productId: UInt16
    let path: String
    let serial: String?
    let kind: String
    let maxDevices: Int
    let pairedDevices: Int
    let remainingPairings: Int?
    let firmware: [FirmwareEntry]
}

struct DeviceInfo: Decodable, Identifiable {
    let slot: Int
    let online: Bool
    let kind: String?
    let wpid: String?
    let serial: String?
    let name: String?
    let firmware: [FirmwareEntry]
    let battery: BatteryInfo?
    let signal: SignalInfo?

    var id: Int { slot }
}

struct FirmwareEntry: Decodable, Identifiable {
    let kind: String
    let name: String
    let version: String

    var id: String { "\(kind)|\(name)|\(version)" }
}

struct BatteryInfo: Decodable {
    let percent: Int?
    let nextPercent: Int?
    let status: String?
    let voltageMv: Int?
}

struct SignalInfo: Decodable {
    let raw: Int
    let percent: Int?
}