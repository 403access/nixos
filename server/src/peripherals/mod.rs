//! Read-only inspection of Logitech receivers.
//!
//! The receiver speaks HID++ over a vendor-defined HID collection. This module
//! deliberately only reads: pairing, unpairing and firmware writes are not
//! implemented here.

pub mod hidpp;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeOptions {
    pub timeout_ms: i32,
    pub include_offline: bool,
    pub path: Option<String>,
}

impl Default for ProbeOptions {
    fn default() -> Self {
        Self {
            timeout_ms: 800,
            include_offline: true,
            path: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProbeReport {
    pub receiver: ReceiverInfo,
    pub devices: Vec<DeviceInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ReceiverInfo {
    pub product: Option<String>,
    pub manufacturer: Option<String>,
    pub vendor_id: u16,
    pub product_id: u16,
    pub path: String,
    pub serial: Option<String>,
    pub kind: String,
    pub max_devices: u8,
    pub paired_devices: u8,
    pub remaining_pairings: Option<i16>,
    pub firmware: Vec<FirmwareEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceInfo {
    pub slot: u8,
    pub online: bool,
    pub kind: Option<String>,
    pub wpid: Option<String>,
    pub serial: Option<String>,
    pub name: Option<String>,
    pub firmware: Vec<FirmwareEntry>,
    pub battery: Option<BatteryInfo>,
    pub signal: Option<SignalInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FirmwareEntry {
    pub kind: String,
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BatteryInfo {
    pub percent: Option<u8>,
    pub next_percent: Option<u8>,
    pub status: Option<String>,
    pub voltage_mv: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SignalInfo {
    pub raw: u8,
    pub percent: Option<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HidDeviceSummary {
    pub path: String,
    pub product: Option<String>,
    pub manufacturer: Option<String>,
    pub vendor_id: u16,
    pub product_id: u16,
    pub usage_page: u16,
    pub usage: u16,
    pub interface_number: i32,
}

/// Open the selected Logitech receiver and read its current state.
pub fn probe(options: &ProbeOptions) -> Result<ProbeReport, hidpp::ProbeError> {
    let mut client = match options.path.as_deref() {
        Some(path) => hidpp::HidppClient::open_path(path, options.timeout_ms)?,
        None => hidpp::HidppClient::open(options.timeout_ms)?,
    };
    Ok(client.probe(options.include_offline))
}

/// List every Logitech HID collection visible to `hidapi`.
pub fn list_devices() -> Result<Vec<HidDeviceSummary>, hidpp::ProbeError> {
    hidpp::list_logitech_devices()
}

/// The HTTP layer's view of the receiver. Tests inject a fixture implementation.
pub trait PeripheralProbe: Send + Sync {
    fn snapshot(&self) -> Result<ProbeReport, String>;
}

pub struct LocalPeripherals {
    options: ProbeOptions,
}

impl LocalPeripherals {
    pub fn new() -> Self {
        Self {
            options: ProbeOptions::default(),
        }
    }

    pub fn with_options(options: ProbeOptions) -> Self {
        Self { options }
    }
}

impl Default for LocalPeripherals {
    fn default() -> Self {
        Self::new()
    }
}

impl PeripheralProbe for LocalPeripherals {
    fn snapshot(&self) -> Result<ProbeReport, String> {
        probe(&self.options).map_err(|error| error.to_string())
    }
}
