//! HID++ 2.0 protocol and the read-only receiver probe.

use std::ffi::CString;
use std::fmt;
use std::time::{Duration, Instant};

use hidapi::{HidApi, HidDevice, HidError};

use super::{
    BatteryInfo, DeviceInfo, FirmwareEntry, HidDeviceSummary, ProbeReport, ReceiverInfo, SignalInfo,
};

const LOGITECH_VENDOR_ID: u16 = 0x046D;
const HIDPP_USAGE_PAGE: u16 = 0xFF00;
const HIDPP_USAGE: u16 = 0x0001;

const REPORT_SHORT: u8 = 0x10;
const REPORT_LONG: u8 = 0x11;
const REPORT_SHORT_LEN: usize = 7;
const REPORT_LONG_LEN: usize = 20;
const RECEIVER_INDEX: u8 = 0xFF;
const SW_ID: u8 = 0x01;

const FEATURE_DEVICE_FW_VERSION: u16 = 0x0003;
const FEATURE_DEVICE_NAME: u16 = 0x0005;
const FEATURE_WIRELESS_SIGNAL_STRENGTH: u16 = 0x0080;
const FEATURE_BATTERY_STATUS: u16 = 0x1000;
const FEATURE_BATTERY_VOLTAGE: u16 = 0x1001;
const FEATURE_UNIFIED_BATTERY: u16 = 0x1004;

const REGISTER_RECEIVER_CONNECTION: u16 = 0x02;
const REGISTER_FIRMWARE: u16 = 0xF1;
const REGISTER_RECEIVER_INFO: u16 = 0x2B5;

const INFO_RECEIVER_INFORMATION: u8 = 0x03;
const INFO_PAIRING_INFORMATION: u8 = 0x20;
const INFO_EXTENDED_PAIRING_INFORMATION: u8 = 0x30;
const INFO_BOLT_PAIRING_INFORMATION: u8 = 0x50;

/// USB product IDs that Logitech uses for receivers rather than peripherals.
const RECEIVER_PRODUCT_IDS: &[u16] = &[
    0xC548, // Bolt
    0xC52B, 0xC532, 0xC534, // Unifying
    0xC518, 0xC51A, 0xC51B, 0xC521, 0xC525, 0xC526, 0xC531, 0xC535, 0xC537, // Nano
    0xC539, 0xC53A, 0xC53D, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D, // Lightspeed
];

#[derive(Debug)]
pub enum ProbeError {
    Hidapi(HidError),
    Timeout { device: u8, request: u16 },
    FeatureCall { device: u8, request: u16, error: u8 },
    NoReceiver,
    InvalidPath(String),
    ShortWrite { expected: usize, actual: usize },
}

impl fmt::Display for ProbeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Hidapi(error) => write!(formatter, "HID access failed: {error}"),
            Self::Timeout { device, request } => write!(
                formatter,
                "timed out waiting for device 0x{device:02X} request 0x{request:04X}"
            ),
            Self::FeatureCall {
                device,
                request,
                error,
            } => write!(
                formatter,
                "device 0x{device:02X} rejected request 0x{request:04X} with HID++ error 0x{error:02X}"
            ),
            Self::NoReceiver => write!(
                formatter,
                "no Logitech receiver found (expected a Unifying, Nano, or Bolt receiver)"
            ),
            Self::InvalidPath(path) => write!(formatter, "invalid HID path: {path}"),
            Self::ShortWrite { expected, actual } => {
                write!(formatter, "short HID write: wrote {actual} of {expected} bytes")
            }
        }
    }
}

impl std::error::Error for ProbeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Hidapi(error) => Some(error),
            _ => None,
        }
    }
}

impl From<HidError> for ProbeError {
    fn from(error: HidError) -> Self {
        Self::Hidapi(error)
    }
}

/// The transport boundary, kept small so the protocol can be tested without a
/// physical receiver.
pub trait Transport {
    fn write_report(&self, report: &[u8]) -> Result<(), ProbeError>;
    fn read_report(&self, timeout_ms: i32) -> Result<Option<Vec<u8>>, ProbeError>;
}

/// `hidapi`-backed transport. The receiver is opened by path so the vendor
/// collection is used instead of the keyboard or mouse collection.
pub struct HidApiTransport {
    device: HidDevice,
}

impl Transport for HidApiTransport {
    fn write_report(&self, report: &[u8]) -> Result<(), ProbeError> {
        let written = self.device.write(report)?;
        if written != report.len() {
            return Err(ProbeError::ShortWrite {
                expected: report.len(),
                actual: written,
            });
        }
        Ok(())
    }

    fn read_report(&self, timeout_ms: i32) -> Result<Option<Vec<u8>>, ProbeError> {
        let mut buffer = [0u8; 64];
        let read = self.device.read_timeout(&mut buffer, timeout_ms)?;
        if read == 0 {
            return Ok(None);
        }
        Ok(Some(buffer[..read].to_vec()))
    }
}

#[derive(Debug, Clone)]
pub struct ReceiverMetadata {
    pub product: Option<String>,
    pub manufacturer: Option<String>,
    pub vendor_id: u16,
    pub product_id: u16,
    pub path: String,
}

struct ReceiverCandidate {
    path: CString,
    product: Option<String>,
    manufacturer: Option<String>,
    vendor_id: u16,
    product_id: u16,
}

pub struct HidppClient<T: Transport> {
    transport: T,
    timeout_ms: i32,
    metadata: ReceiverMetadata,
}

impl HidppClient<HidApiTransport> {
    /// Open the first Logitech receiver found on the system.
    pub fn open(timeout_ms: i32) -> Result<Self, ProbeError> {
        let api = HidApi::new()?;
        let candidate = select_receiver(&api).ok_or(ProbeError::NoReceiver)?;
        Self::open_candidate(&api, candidate, timeout_ms)
    }

    /// Open a specific hidraw path, for example `/dev/hidraw2`.
    pub fn open_path(path: &str, timeout_ms: i32) -> Result<Self, ProbeError> {
        let api = HidApi::new()?;
        let c_path = CString::new(path).map_err(|_| ProbeError::InvalidPath(path.to_string()))?;
        let metadata = api
            .device_list()
            .find(|info| info.path() == c_path.as_c_str())
            .map(|info| ReceiverMetadata {
                product: info.product_string().map(str::to_string),
                manufacturer: info.manufacturer_string().map(str::to_string),
                vendor_id: info.vendor_id(),
                product_id: info.product_id(),
                path: info.path().to_string_lossy().to_string(),
            })
            .unwrap_or_else(|| ReceiverMetadata {
                product: None,
                manufacturer: None,
                vendor_id: LOGITECH_VENDOR_ID,
                product_id: 0,
                path: path.to_string(),
            });
        let device = api.open_path(c_path.as_c_str())?;
        Ok(Self::new(HidApiTransport { device }, timeout_ms, metadata))
    }

    fn open_candidate(
        api: &HidApi,
        candidate: ReceiverCandidate,
        timeout_ms: i32,
    ) -> Result<Self, ProbeError> {
        let metadata = ReceiverMetadata {
            product: candidate.product.clone(),
            manufacturer: candidate.manufacturer.clone(),
            vendor_id: candidate.vendor_id,
            product_id: candidate.product_id,
            path: candidate.path.to_string_lossy().to_string(),
        };
        let device = api.open_path(candidate.path.as_c_str())?;
        Ok(Self::new(HidApiTransport { device }, timeout_ms, metadata))
    }
}

impl<T: Transport> HidppClient<T> {
    pub fn new(transport: T, timeout_ms: i32, metadata: ReceiverMetadata) -> Self {
        Self {
            transport,
            timeout_ms,
            metadata,
        }
    }

    /// Read the receiver and every paired slot. This never writes pairing data
    /// or firmware.
    pub fn probe(&mut self, include_offline: bool) -> ProbeReport {
        let (serial, max_devices) = self.receiver_identity();
        let (remaining_pairings, _connected) = self.receiver_connection();
        let receiver_kind = self.detect_receiver_kind();
        let receiver_firmware = self.receiver_firmware();

        let mut devices = Vec::new();
        for slot in 1..=max_devices {
            let pairing = self.pairing_info(slot, &receiver_kind);
            if pairing.is_none() && max_devices > 1 && receiver_kind != "unknown" {
                continue;
            }

            let online = self.ping(slot);
            if !online && !include_offline {
                continue;
            }
            if pairing.is_none() && !online {
                continue;
            }

            let name = if online {
                self.device_name(slot)
            } else {
                self.legacy_device_name(slot)
            };
            let firmware = if online {
                self.device_firmware(slot)
            } else {
                Vec::new()
            };
            let battery = if online {
                self.device_battery(slot)
            } else {
                None
            };
            let signal = if online {
                self.device_signal(slot)
            } else {
                None
            };

            let pairing = pairing.unwrap_or_default();
            devices.push(DeviceInfo {
                slot,
                online,
                kind: pairing.kind,
                wpid: pairing.wpid,
                serial: pairing.serial,
                name,
                firmware,
                battery,
                signal,
            });
        }

        let paired_devices = devices.len() as u8;

        ProbeReport {
            receiver: ReceiverInfo {
                product: self.metadata.product.clone(),
                manufacturer: self.metadata.manufacturer.clone(),
                vendor_id: self.metadata.vendor_id,
                product_id: self.metadata.product_id,
                path: self.metadata.path.clone(),
                serial,
                kind: receiver_kind,
                max_devices,
                paired_devices,
                remaining_pairings,
                firmware: receiver_firmware,
            },
            devices,
        }
    }

    fn receiver_identity(&mut self) -> (Option<String>, u8) {
        match self.read_register(REGISTER_RECEIVER_INFO, &[INFO_RECEIVER_INFORMATION]) {
            Ok(reply) => {
                let serial = if reply.len() >= 5 {
                    Some(hex(&reply[1..5]))
                } else {
                    None
                };
                let max_devices = reply.get(6).copied().unwrap_or(1).clamp(1, 6);
                (serial, max_devices)
            }
            Err(error) => {
                log::debug!("receiver information unavailable: {error}");
                (None, fallback_max_devices(self.metadata.product_id))
            }
        }
    }

    fn receiver_connection(&mut self) -> (Option<i16>, Option<u8>) {
        let Some(reply) = self.read_register(REGISTER_RECEIVER_CONNECTION, &[]).ok() else {
            return (None, None);
        };
        let connected = reply.get(1).copied();
        let remaining =
            reply
                .get(2)
                .copied()
                .map(|value| if value >= 5 { i16::from(value) - 5 } else { -1 });
        (remaining, connected)
    }

    fn detect_receiver_kind(&mut self) -> String {
        if self.metadata.product_id == 0xC548 {
            return "bolt".to_string();
        }
        if self
            .read_register(REGISTER_RECEIVER_INFO, &[INFO_PAIRING_INFORMATION])
            .is_ok()
        {
            return "unifying".to_string();
        }
        if self
            .read_register(REGISTER_RECEIVER_INFO, &[INFO_BOLT_PAIRING_INFORMATION + 1])
            .is_ok()
        {
            return "bolt".to_string();
        }
        "unknown".to_string()
    }

    fn pairing_info(&mut self, slot: u8, receiver_kind: &str) -> Option<PairingInfo> {
        if receiver_kind == "bolt" {
            let sub = INFO_BOLT_PAIRING_INFORMATION + slot;
            let reply = self.read_register(REGISTER_RECEIVER_INFO, &[sub]).ok()?;
            if reply.len() < 2 {
                return None;
            }
            // Bolt pairing metadata uses a different layout. Only report that
            // the slot is occupied and let the HID++ 2.0 queries fill in the
            // device details.
            return Some(PairingInfo::default());
        }

        let pair_sub = INFO_PAIRING_INFORMATION + slot.saturating_sub(1);
        let ext_sub = INFO_EXTENDED_PAIRING_INFORMATION + slot.saturating_sub(1);
        let reply = self
            .read_register(REGISTER_RECEIVER_INFO, &[pair_sub])
            .ok()?;
        if reply.len() < 8 {
            return None;
        }
        let wpid = hex(&reply[3..5]);
        if wpid == "0000" {
            return None;
        }
        let kind = device_kind(reply[7] & 0x0F);
        let serial = self
            .read_register(REGISTER_RECEIVER_INFO, &[ext_sub])
            .ok()
            .and_then(|reply| {
                if reply.len() >= 5 {
                    Some(hex(&reply[1..5]))
                } else {
                    None
                }
            });

        Some(PairingInfo {
            kind,
            wpid: Some(wpid),
            serial,
        })
    }

    fn receiver_firmware(&mut self) -> Vec<FirmwareEntry> {
        let mut entries = Vec::new();

        if let Some(reply) = self
            .read_register(REGISTER_FIRMWARE, &[0x01])
            .ok()
            .filter(|reply| reply.len() >= 3)
        {
            let mut version = format!("{:02X}.{:02X}", reply[1], reply[2]);
            if let Some(build) = self
                .read_register(REGISTER_FIRMWARE, &[0x02])
                .ok()
                .filter(|reply| reply.len() >= 3)
            {
                version.push_str(&format!(".B{:02X}{:02X}", build[1], build[2]));
            }
            entries.push(FirmwareEntry {
                kind: "firmware".to_string(),
                name: String::new(),
                version,
            });
        }

        for (sub, kind) in [(0x04_u8, "bootloader"), (0x03, "other")] {
            if let Some(reply) = self
                .read_register(REGISTER_FIRMWARE, &[sub])
                .ok()
                .filter(|reply| reply.len() >= 3)
            {
                entries.push(FirmwareEntry {
                    kind: kind.to_string(),
                    name: String::new(),
                    version: format!("{:02X}.{:02X}", reply[1], reply[2]),
                });
            }
        }

        entries
    }

    fn ping(&mut self, slot: u8) -> bool {
        let request_id = 0x0010 | u16::from(SW_ID);
        let timeout = self.timeout_ms.clamp(100, 500);
        self.request(slot, request_id, &[0x00, 0x00, 0x00], None, timeout, false)
            .is_ok()
    }

    fn device_name(&mut self, slot: u8) -> Option<String> {
        if let Some(name) = self.hidpp20_device_name(slot) {
            return Some(name);
        }
        self.legacy_device_name(slot)
    }

    fn hidpp20_device_name(&mut self, slot: u8) -> Option<String> {
        let index = self.feature_index(slot, FEATURE_DEVICE_NAME)?;
        let length = self
            .feature_call(slot, index, 0x00, &[])?
            .first()
            .copied()? as usize;
        if length == 0 {
            return Some(String::new());
        }

        let mut name = Vec::with_capacity(length);
        while name.len() < length {
            let reply = self.feature_call(slot, index, 0x10, &[name.len() as u8])?;
            if reply.is_empty() {
                break;
            }
            let take = (length - name.len()).min(reply.len());
            name.extend_from_slice(&reply[..take]);
        }
        Some(String::from_utf8_lossy(&name).to_string())
    }

    fn legacy_device_name(&mut self, slot: u8) -> Option<String> {
        let sub = 0x40 + slot.saturating_sub(1);
        let reply = self.read_register(REGISTER_RECEIVER_INFO, &[sub]).ok()?;
        let length = reply.get(1).copied()? as usize;
        if length == 0 || reply.len() < 2 + length {
            return None;
        }
        Some(String::from_utf8_lossy(&reply[2..2 + length]).to_string())
    }

    fn device_firmware(&mut self, slot: u8) -> Vec<FirmwareEntry> {
        let entries = self.hidpp20_device_firmware(slot);
        if entries.is_empty() {
            self.legacy_device_firmware(slot)
        } else {
            entries
        }
    }

    fn hidpp20_device_firmware(&mut self, slot: u8) -> Vec<FirmwareEntry> {
        let Some(index) = self.feature_index(slot, FEATURE_DEVICE_FW_VERSION) else {
            return Vec::new();
        };
        let Some(count) = self
            .feature_call(slot, index, 0x00, &[])
            .and_then(|reply| reply.first().copied())
        else {
            return Vec::new();
        };

        let mut entries = Vec::new();
        for entity in 0..count {
            if let Some(entry) = self
                .feature_call(slot, index, 0x10, &[entity])
                .and_then(|reply| parse_firmware_entity(&reply))
            {
                entries.push(entry);
            }
        }
        entries
    }

    fn legacy_device_firmware(&mut self, slot: u8) -> Vec<FirmwareEntry> {
        let mut entries = Vec::new();
        if let Some(reply) = self
            .read_device_register(slot, REGISTER_FIRMWARE, &[0x01])
            .ok()
            .filter(|reply| reply.len() >= 3)
        {
            let mut version = format!("{:02X}.{:02X}", reply[1], reply[2]);
            if let Some(build) = self
                .read_device_register(slot, REGISTER_FIRMWARE, &[0x02])
                .ok()
                .filter(|reply| reply.len() >= 3)
            {
                version.push_str(&format!(".B{:02X}{:02X}", build[1], build[2]));
            }
            entries.push(FirmwareEntry {
                kind: "firmware".to_string(),
                name: String::new(),
                version,
            });
        }
        for (sub, kind) in [(0x04_u8, "bootloader"), (0x03, "other")] {
            if let Some(reply) = self
                .read_device_register(slot, REGISTER_FIRMWARE, &[sub])
                .ok()
                .filter(|reply| reply.len() >= 3)
            {
                entries.push(FirmwareEntry {
                    kind: kind.to_string(),
                    name: String::new(),
                    version: format!("{:02X}.{:02X}", reply[1], reply[2]),
                });
            }
        }
        entries
    }

    fn device_battery(&mut self, slot: u8) -> Option<BatteryInfo> {
        let status_reply = self
            .feature_index(slot, FEATURE_BATTERY_STATUS)
            .and_then(|index| self.feature_call(slot, index, 0x00, &[]));
        if let Some(reply) = status_reply.filter(|reply| reply.len() >= 3) {
            return Some(BatteryInfo {
                percent: nonzero(reply[0]),
                next_percent: nonzero(reply[1]),
                status: battery_status(reply[2]),
                voltage_mv: self.voltage(slot).map(|(millivolts, _)| millivolts),
            });
        }

        let unified_reply = self
            .feature_index(slot, FEATURE_UNIFIED_BATTERY)
            .and_then(|index| self.feature_call(slot, index, 0x10, &[]));
        if let Some(reply) = unified_reply.filter(|reply| reply.len() >= 3) {
            let percent = Some(if reply[0] > 0 {
                reply[0]
            } else {
                unified_level(reply[1])
            });
            return Some(BatteryInfo {
                percent,
                next_percent: None,
                status: battery_status(reply[2]),
                voltage_mv: self.voltage(slot).map(|(millivolts, _)| millivolts),
            });
        }

        if let Some((voltage_mv, flags)) = self.voltage(slot) {
            let status = if flags & 0x80 != 0 {
                "recharging"
            } else {
                "discharging"
            };
            return Some(BatteryInfo {
                percent: Some(estimate_battery_percent(voltage_mv)),
                next_percent: None,
                status: Some(status.to_string()),
                voltage_mv: Some(voltage_mv),
            });
        }

        self.legacy_battery(slot)
    }

    fn legacy_battery(&mut self, slot: u8) -> Option<BatteryInfo> {
        // HID++ 1.0 devices expose battery through registers 0x0D and 0x07.
        if let Some(reply) = self
            .read_device_register(slot, 0x0D, &[])
            .ok()
            .filter(|reply| !reply.is_empty())
        {
            let charge = reply[0];
            let status_byte = reply.get(2).copied().unwrap_or(0) & 0xF0;
            let status = match status_byte {
                0x30 => Some("discharging"),
                0x50 => Some("recharging"),
                0x90 => Some("full"),
                _ => None,
            };
            if charge > 0 || status.is_some() {
                return Some(BatteryInfo {
                    percent: nonzero(charge),
                    next_percent: None,
                    status: status.map(str::to_string),
                    voltage_mv: None,
                });
            }
        }

        if let Some(reply) = self
            .read_device_register(slot, 0x07, &[])
            .ok()
            .filter(|reply| reply.len() >= 2)
        {
            let status_byte = reply[0];
            let charging_byte = reply[1];
            let percent = match status_byte {
                7 => 90,
                5 => 50,
                3 => 20,
                1 => 5,
                _ => 0,
            };
            let status = if charging_byte == 0x00 {
                Some("discharging")
            } else if charging_byte & 0x21 == 0x21 {
                Some("recharging")
            } else if charging_byte & 0x22 == 0x22 {
                Some("full")
            } else {
                None
            };
            if percent > 0 || status.is_some() {
                return Some(BatteryInfo {
                    percent: Some(percent),
                    next_percent: None,
                    status: status.map(str::to_string),
                    voltage_mv: None,
                });
            }
        }

        None
    }

    fn voltage(&mut self, slot: u8) -> Option<(u16, u8)> {
        let index = self.feature_index(slot, FEATURE_BATTERY_VOLTAGE)?;
        let reply = self.feature_call(slot, index, 0x00, &[])?;
        if reply.len() < 2 {
            return None;
        }
        Some((
            u16::from_be_bytes([reply[0], reply[1]]),
            reply.get(2).copied().unwrap_or(0),
        ))
    }

    fn device_signal(&mut self, slot: u8) -> Option<SignalInfo> {
        let index = self.feature_index(slot, FEATURE_WIRELESS_SIGNAL_STRENGTH)?;
        let reply = self.feature_call(slot, index, 0x00, &[])?;
        let raw = reply.first().copied()?;
        Some(SignalInfo {
            raw,
            percent: (raw <= 100).then_some(raw),
        })
    }

    fn feature_index(&mut self, device: u8, feature_id: u16) -> Option<u8> {
        let params = [(feature_id >> 8) as u8, feature_id as u8];
        let request_id = feature_request_id(0x00, 0x00);
        match self.request(device, request_id, &params, None, self.timeout_ms, true) {
            Ok(reply) => {
                let index = reply.first().copied().unwrap_or(0);
                (index != 0).then_some(index)
            }
            Err(error) => {
                log::debug!(
                    "feature 0x{feature_id:04X} unavailable on device 0x{device:02X}: {error}"
                );
                None
            }
        }
    }

    fn feature_call(
        &mut self,
        device: u8,
        feature_index: u8,
        function: u8,
        params: &[u8],
    ) -> Option<Vec<u8>> {
        let request_id = feature_request_id(feature_index, function);
        self.request(device, request_id, params, None, self.timeout_ms, true)
            .ok()
    }

    fn read_register(&mut self, register: u16, params: &[u8]) -> Result<Vec<u8>, ProbeError> {
        let request_id = 0x8100 | (register & 0x02FF);
        let expected_first = if request_id == 0x83B5 || request_id == 0x81F1 {
            params.first().copied()
        } else {
            None
        };
        self.request(
            RECEIVER_INDEX,
            request_id,
            params,
            expected_first,
            self.timeout_ms,
            params.len() > 3,
        )
    }

    fn read_device_register(
        &mut self,
        device: u8,
        register: u16,
        params: &[u8],
    ) -> Result<Vec<u8>, ProbeError> {
        let request_id = 0x8100 | (register & 0x02FF);
        let expected_first = if request_id == 0x83B5 || request_id == 0x81F1 {
            params.first().copied()
        } else {
            None
        };
        self.request(
            device,
            request_id,
            params,
            expected_first,
            self.timeout_ms,
            params.len() > 3,
        )
    }

    fn request(
        &mut self,
        device: u8,
        request_id: u16,
        params: &[u8],
        expected_first: Option<u8>,
        timeout_ms: i32,
        long: bool,
    ) -> Result<Vec<u8>, ProbeError> {
        let (report_id, report_len) = if long {
            (REPORT_LONG, REPORT_LONG_LEN)
        } else {
            (REPORT_SHORT, REPORT_SHORT_LEN)
        };
        let mut frame = Vec::with_capacity(report_len);
        frame.push(report_id);
        frame.push(device);
        frame.push((request_id >> 8) as u8);
        frame.push(request_id as u8);
        frame.extend_from_slice(params);
        frame.resize(report_len, 0);
        self.transport.write_report(&frame)?;

        let timeout = timeout_ms.max(1);
        let deadline = Instant::now() + Duration::from_millis(timeout as u64);
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(ProbeError::Timeout {
                    device,
                    request: request_id,
                });
            }
            let remaining = deadline.saturating_duration_since(now);
            let remaining_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
            let Some(report) = self.transport.read_report(remaining_ms.max(1))? else {
                continue;
            };
            if report.len() < 4 {
                continue;
            }

            let report_id = report[0];
            if report_id != REPORT_SHORT && report_id != REPORT_LONG {
                continue;
            }
            let reply_device = report[1];
            if reply_device != device && reply_device != (device ^ 0xFF) {
                continue;
            }

            if report.len() >= 6 && report[2] == 0xFF {
                let reply_request = u16::from_be_bytes([report[3], report[4]]);
                if reply_request == request_id {
                    return Err(ProbeError::FeatureCall {
                        device,
                        request: request_id,
                        error: report[5],
                    });
                }
                continue;
            }

            if report_id == REPORT_SHORT && report.len() >= 6 && report[2] == 0x8F {
                let reply_request = u16::from_be_bytes([report[3], report[4]]);
                if reply_request == request_id {
                    return Err(ProbeError::FeatureCall {
                        device,
                        request: request_id,
                        error: report[5],
                    });
                }
                continue;
            }

            let reply_request = u16::from_be_bytes([report[2], report[3]]);
            if reply_request != request_id {
                continue;
            }
            let payload = report[4..].to_vec();
            if let Some(expected) = expected_first {
                if payload.first().copied() != Some(expected) {
                    continue;
                }
            }
            return Ok(payload);
        }
    }
}

#[derive(Debug, Default)]
struct PairingInfo {
    kind: Option<String>,
    wpid: Option<String>,
    serial: Option<String>,
}

fn receiver_score(
    product_id: u16,
    product: Option<&str>,
    usage_page: u16,
    usage: u16,
    interface_number: i32,
) -> i32 {
    let mut score = 0;
    if RECEIVER_PRODUCT_IDS.contains(&product_id) {
        score += 100;
    }
    if product
        .map(|name| name.to_ascii_lowercase().contains("receiver"))
        .unwrap_or(false)
    {
        score += 50;
    }
    if usage_page == HIDPP_USAGE_PAGE && usage == HIDPP_USAGE {
        score += 20;
    }
    if interface_number == 2 {
        score += 10;
    }
    score
}

fn select_receiver(api: &HidApi) -> Option<ReceiverCandidate> {
    let mut best: Option<(i32, ReceiverCandidate)> = None;

    for info in api.device_list() {
        if info.vendor_id() != LOGITECH_VENDOR_ID {
            continue;
        }
        let score = receiver_score(
            info.product_id(),
            info.product_string(),
            info.usage_page(),
            info.usage(),
            info.interface_number(),
        );
        if score <= 0 {
            continue;
        }
        let candidate = ReceiverCandidate {
            path: info.path().to_owned(),
            product: info.product_string().map(str::to_string),
            manufacturer: info.manufacturer_string().map(str::to_string),
            vendor_id: info.vendor_id(),
            product_id: info.product_id(),
        };
        if best
            .as_ref()
            .map(|(best_score, _)| score > *best_score)
            .unwrap_or(true)
        {
            best = Some((score, candidate));
        }
    }

    best.map(|(_, candidate)| candidate)
}

pub fn list_logitech_devices() -> Result<Vec<HidDeviceSummary>, ProbeError> {
    let api = HidApi::new()?;
    let mut devices = Vec::new();
    for info in api.device_list() {
        if info.vendor_id() != LOGITECH_VENDOR_ID {
            continue;
        }
        devices.push(HidDeviceSummary {
            path: info.path().to_string_lossy().to_string(),
            product: info.product_string().map(str::to_string),
            manufacturer: info.manufacturer_string().map(str::to_string),
            vendor_id: info.vendor_id(),
            product_id: info.product_id(),
            usage_page: info.usage_page(),
            usage: info.usage(),
            interface_number: info.interface_number(),
        });
    }
    devices.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(devices)
}

fn feature_request_id(feature_index: u8, function: u8) -> u16 {
    ((feature_index as u16) << 8) | u16::from(function & 0xF0) | u16::from(SW_ID)
}

fn parse_firmware_entity(reply: &[u8]) -> Option<FirmwareEntry> {
    let level = reply.first()? & 0x0F;
    let kind = match level {
        0 => "firmware",
        1 => "bootloader",
        2 => "hardware",
        _ => "other",
    };

    if level == 0 || level == 1 {
        if reply.len() < 8 {
            return None;
        }
        let name = String::from_utf8_lossy(&reply[1..4])
            .trim_end_matches('\0')
            .to_string();
        let major = reply[4];
        let minor = reply[5];
        let build = u16::from_be_bytes([reply[6], reply[7]]);
        let version = if build > 0 {
            format!("{major:02X}.{minor:02X}.B{build:04X}")
        } else {
            format!("{major:02X}.{minor:02X}")
        };
        return Some(FirmwareEntry {
            kind: kind.to_string(),
            name,
            version,
        });
    }

    if level == 2 {
        return Some(FirmwareEntry {
            kind: kind.to_string(),
            name: String::new(),
            version: reply.get(1).copied().unwrap_or(0).to_string(),
        });
    }

    Some(FirmwareEntry {
        kind: kind.to_string(),
        name: String::new(),
        version: String::new(),
    })
}

fn battery_status(value: u8) -> Option<String> {
    Some(
        match value {
            0x00 => "discharging",
            0x01 => "recharging",
            0x02 => "almost full",
            0x03 => "full",
            0x04 => "slow recharge",
            0x05 => "invalid battery",
            0x06 => "thermal error",
            _ => return None,
        }
        .to_string(),
    )
}

fn unified_level(level: u8) -> u8 {
    match level {
        8 => 90,
        4 => 50,
        2 => 20,
        1 => 5,
        _ => 0,
    }
}

fn estimate_battery_percent(millivolts: u16) -> u8 {
    const CURVE: &[(u16, u8)] = &[
        (4186, 100),
        (4067, 90),
        (3989, 80),
        (3922, 70),
        (3859, 60),
        (3811, 50),
        (3778, 40),
        (3751, 30),
        (3717, 20),
        (3671, 10),
        (3646, 5),
        (3579, 2),
        (3500, 0),
    ];

    if millivolts >= CURVE[0].0 {
        return CURVE[0].1;
    }
    if millivolts <= CURVE[CURVE.len() - 1].0 {
        return CURVE[CURVE.len() - 1].1;
    }

    for pair in CURVE.windows(2) {
        let (high_voltage, high_percent) = pair[0];
        let (low_voltage, low_percent) = pair[1];
        if (low_voltage..=high_voltage).contains(&millivolts) {
            let percent = f32::from(low_percent)
                + (f32::from(high_percent) - f32::from(low_percent))
                    * (f32::from(millivolts) - f32::from(low_voltage))
                    / (f32::from(high_voltage) - f32::from(low_voltage));
            return percent.round() as u8;
        }
    }
    0
}

fn device_kind(value: u8) -> Option<String> {
    Some(
        match value {
            0x01 => "keyboard",
            0x02 => "mouse",
            0x03 => "numpad",
            0x04 => "presenter",
            0x07 => "remote",
            0x08 => "trackball",
            0x09 => "touchpad",
            0x0A => "tablet",
            0x0B => "gamepad",
            0x0C => "joystick",
            0x0D => "headset",
            0x0E => "remote control",
            0x0F => "receiver",
            _ => return None,
        }
        .to_string(),
    )
}

fn fallback_max_devices(product_id: u16) -> u8 {
    if matches!(product_id, 0xC52B | 0xC532 | 0xC534 | 0xC548) {
        6
    } else {
        1
    }
}

fn nonzero(value: u8) -> Option<u8> {
    (value != 0).then_some(value)
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02X}");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct MockTransport {
        writes: RefCell<Vec<Vec<u8>>>,
        replies: RefCell<Vec<Vec<u8>>>,
    }

    impl MockTransport {
        fn new(replies: Vec<Vec<u8>>) -> Self {
            Self {
                writes: RefCell::new(Vec::new()),
                replies: RefCell::new(replies),
            }
        }
    }

    impl Transport for MockTransport {
        fn write_report(&self, report: &[u8]) -> Result<(), ProbeError> {
            self.writes.borrow_mut().push(report.to_vec());
            Ok(())
        }

        fn read_report(&self, _timeout_ms: i32) -> Result<Option<Vec<u8>>, ProbeError> {
            Ok(self.replies.borrow_mut().pop())
        }
    }

    fn metadata() -> ReceiverMetadata {
        ReceiverMetadata {
            product: Some("USB Receiver".to_string()),
            manufacturer: Some("Logitech".to_string()),
            vendor_id: LOGITECH_VENDOR_ID,
            product_id: 0xC52B,
            path: "/dev/hidraw-test".to_string(),
        }
    }

    fn reply(device: u8, request_id: u16, payload: &[u8]) -> Vec<u8> {
        let mut frame = vec![
            REPORT_LONG,
            device,
            (request_id >> 8) as u8,
            request_id as u8,
        ];
        frame.extend_from_slice(payload);
        frame.resize(REPORT_LONG_LEN, 0);
        frame
    }

    #[test]
    fn feature_request_id_puts_the_software_id_in_the_low_nibble() {
        assert_eq!(feature_request_id(0x07, 0x10), 0x0711);
        assert_eq!(feature_request_id(0x00, 0x00), 0x0001);
    }

    #[test]
    fn read_register_uses_a_short_report_and_matches_the_subregister() {
        let response = reply(
            RECEIVER_INDEX,
            0x83B5,
            &[0x03, 0x11, 0x22, 0x33, 0x44, 0x00, 0x06],
        );
        let transport = MockTransport::new(vec![response]);
        let mut client = HidppClient::new(transport, 100, metadata());

        let payload = client
            .read_register(REGISTER_RECEIVER_INFO, &[0x03])
            .unwrap();
        assert_eq!(payload[0], 0x03);
        assert_eq!(&payload[1..5], &[0x11, 0x22, 0x33, 0x44]);
        assert_eq!(payload[6], 6);

        let writes = client.transport.writes.borrow();
        assert_eq!(writes.len(), 1);
        assert_eq!(&writes[0][..5], &[0x10, 0xFF, 0x83, 0xB5, 0x03]);
        assert_eq!(writes[0].len(), REPORT_SHORT_LEN);
    }

    #[test]
    fn feature_index_reads_the_root_feature() {
        let response = reply(1, 0x0001, &[0x07, 0x00, 0x00]);
        let transport = MockTransport::new(vec![response]);
        let mut client = HidppClient::new(transport, 100, metadata());

        assert_eq!(client.feature_index(1, FEATURE_DEVICE_FW_VERSION), Some(7));

        let writes = client.transport.writes.borrow();
        assert_eq!(&writes[0][..6], &[0x11, 1, 0x00, 0x01, 0x00, 0x03]);
    }

    #[test]
    fn parses_a_firmware_entity() {
        let entry =
            parse_firmware_entity(&[0x00, b'R', b'Q', b'R', 0x07, 0x01, 0x00, 0x52]).unwrap();
        assert_eq!(entry.kind, "firmware");
        assert_eq!(entry.name, "RQR");
        assert_eq!(entry.version, "07.01.B0052");
    }

    #[test]
    fn battery_helpers_match_solaar_values() {
        assert_eq!(battery_status(0x03).as_deref(), Some("full"));
        assert_eq!(estimate_battery_percent(4186), 100);
        assert_eq!(estimate_battery_percent(3811), 50);
        assert_eq!(estimate_battery_percent(3500), 0);
        assert_eq!(unified_level(8), 90);
        assert_eq!(unified_level(4), 50);
    }

    #[test]
    fn receiver_score_prefers_a_receiver_over_a_paired_peripheral() {
        let receiver = receiver_score(
            0xC52B,
            Some("USB Receiver"),
            HIDPP_USAGE_PAGE,
            HIDPP_USAGE,
            2,
        );
        let keyboard = receiver_score(
            0x2010,
            Some("Logitech K800"),
            HIDPP_USAGE_PAGE,
            HIDPP_USAGE,
            2,
        );
        assert_eq!(receiver, 180);
        assert_eq!(keyboard, 30);
        assert!(receiver > keyboard);
    }

    #[test]
    fn fallback_slot_count_matches_the_receiver_family() {
        assert_eq!(fallback_max_devices(0xC52B), 6);
        assert_eq!(fallback_max_devices(0xC548), 6);
        assert_eq!(fallback_max_devices(0x2010), 1);
    }

    #[test]
    fn device_kinds_use_the_logitech_receiver_mapping() {
        assert_eq!(device_kind(0x00), None);
        assert_eq!(device_kind(0x01).as_deref(), Some("keyboard"));
        assert_eq!(device_kind(0x02).as_deref(), Some("mouse"));
        assert_eq!(device_kind(0x03).as_deref(), Some("numpad"));
        assert_eq!(device_kind(0x0F).as_deref(), Some("receiver"));
    }
}
