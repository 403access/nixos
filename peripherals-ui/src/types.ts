export interface FirmwareEntry {
  kind: string;
  name: string;
  version: string;
}

export interface BatteryInfo {
  percent: number | null;
  next_percent: number | null;
  status: string | null;
  voltage_mv: number | null;
}

export interface SignalInfo {
  raw: number;
  percent: number | null;
}

export interface ReceiverInfo {
  product: string | null;
  manufacturer: string | null;
  vendor_id: number;
  product_id: number;
  path: string;
  serial: string | null;
  kind: string;
  max_devices: number;
  paired_devices: number;
  remaining_pairings: number | null;
  firmware: FirmwareEntry[];
}

export interface DeviceInfo {
  slot: number;
  online: boolean;
  kind: string | null;
  wpid: string | null;
  serial: string | null;
  name: string | null;
  firmware: FirmwareEntry[];
  battery: BatteryInfo | null;
  signal: SignalInfo | null;
}

export interface ProbeReport {
  receiver: ReceiverInfo;
  devices: DeviceInfo[];
}

export interface HealthResponse {
  ok: boolean;
  version: string;
  hostname: string;
}