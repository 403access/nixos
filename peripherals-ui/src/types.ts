export interface HealthResponse {
  ok: boolean;
  version: string;
  hostname: string;
  time?: string;
}

export interface SystemStatus {
  server_version: string;
  hostname: string;
  os: string;
  kernel: string;
  nixos_version: string;
  uptime_seconds: number;
  boot_time: string;
  load: number[];
  cpu: CpuInfo;
  memory: MemoryInfo;
  root_disk: DiskUsage;
  pools: PoolSummary[];
  temperatures: Temperature[];
  addresses: string[];
  generation: number;
  tailscale: TailscaleInfo | null;
  services: ServiceCounts;
  capabilities: Capabilities;
}

export interface CpuInfo {
  model: string;
  cores: number;
  usage_percent: number;
}

export interface MemoryInfo {
  total: number;
  used: number;
  free: number;
  available: number;
  cached: number;
  swap_total: number;
  swap_used: number;
}

export interface DiskUsage {
  mount: string;
  total: number;
  used: number;
  available: number;
  use_percent: number;
}

export interface PoolSummary {
  name: string;
  size: number;
  allocated: number;
  free: number;
  health: string;
  fragmentation: string;
}

export interface Temperature {
  label: string;
  celsius: number;
}

export interface TailscaleInfo {
  connected: boolean;
  hostname: string;
  dns_name: string;
  ips: string[];
  state: string;
}

export interface ServiceCounts {
  running: number;
  failed: number;
  total: number;
}

export interface Capabilities {
  services: boolean;
  rebuild: boolean;
  power: boolean;
}

export interface ServiceUnit {
  unit: string;
  load: string;
  active: string;
  sub: string;
  description: string;
}

export interface DatasetInfo {
  name: string;
  used: number;
  available: number;
  refer: number;
  mountpoint: string;
}

export interface FilesystemInfo {
  source: string;
  fstype: string;
  size: number;
  used: number;
  available: number;
  use_percent: number;
  mountpoint: string;
}

export interface StorageSnapshot {
  pools: PoolSummary[];
  datasets: DatasetInfo[];
  filesystems: FilesystemInfo[];
}

export interface Generation {
  number: number;
  date: string;
  current: boolean;
}

export interface GenerationsResponse {
  generations: Generation[];
}

export interface Job {
  id: string;
  kind: string;
  status: string;
  started_at: string;
  finished_at: string | null;
  exit_code: number | null;
  output: string;
  error: string | null;
}

export interface LogsResponse {
  lines: string[];
}

export interface PoolStatusResponse {
  name: string;
  status: string;
}

export interface ActionResponse {
  ok: boolean;
}

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

export type AppTab =
  | "dashboard"
  | "services"
  | "storage"
  | "system"
  | "peripherals"
  | "settings";