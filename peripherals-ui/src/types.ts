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

export interface FileEntry {
  name: string;
  path: string;
  kind: "dir" | "file" | "symlink" | "other" | string;
  size: number;
  modified?: string | null;
  hidden: boolean;
}

export interface FileListing {
  root: string;
  path: string;
  parent?: string | null;
  entries: FileEntry[];
  total: number;
  truncated: boolean;
}

export interface Generation {
  number: number;
  date: string;
  current: boolean;
}

export interface GenerationsResponse {
  generations: Generation[];
}

export interface StatusSample {
  at: string;
  cpu: CpuInfo;
  load: number[];
  memory: MemoryInfo;
  root_disk: DiskUsage;
  services: ServiceCounts;
  generation: number;
  uptime_seconds: number;
  temperatures: Temperature[];
  pools: PoolSummary[];
}

export interface StatusHistoryResponse {
  samples: StatusSample[];
}

export interface ResourceEntry {
  name: string;
  kind: string;
  unit: string;
  tasks: number;
  cpu_percent: number;
  memory_bytes: number;
  read_bps: number;
  write_bps: number;
  network_rx_bps: number;
  network_tx_bps: number;
}

export interface ResourceProcess {
  pid: number;
  name: string;
  command: string;
  unit: string;
  kind: string;
  cpu_percent: number;
  memory_bytes: number;
  read_bps: number;
  write_bps: number;
  network_rx_bps: number;
  network_tx_bps: number;
}

export interface ResourceUsage {
  at: string;
  interval_ms: number;
  cpu_count: number;
  memory_total: number;
  total_cpu_percent: number;
  total_memory_bytes: number;
  total_read_bps: number;
  total_write_bps: number;
  total_network_rx_bps: number;
  total_network_tx_bps: number;
  services: ResourceEntry[];
  apps: ResourceEntry[];
  processes: ResourceProcess[];
}

export interface ResourceSeriesPoint {
  at: string;
  cpu_percent: number;
  memory_bytes: number;
  read_bps: number;
  write_bps: number;
  network_rx_bps: number;
  network_tx_bps: number;
}

export interface ResourceSeries {
  key: string;
  name: string;
  kind: string;
  points: ResourceSeriesPoint[];
}

export interface ResourceHistory {
  from: string;
  to: string;
  kind: string;
  series: ResourceSeries[];
  totals: ResourceSeriesPoint[];
}

export type ResourceHistoryMetric =
  | "cpu"
  | "memory"
  | "read"
  | "write"
  | "rx"
  | "tx";

export interface CurrentTheme {
  profile: string;
  flavour: string;
  accent: string;
  gtkTheme: string;
  wallpaper: string;
}

export interface ThemeCard {
  id: string;
  name: string;
  description: string;
  details: string[];
  screenshot?: string | null;
  accent: string;
  current: boolean;
}

export interface ThemeCatalog {
  current: CurrentTheme;
  profiles: ThemeCard[];
  gtkThemes: ThemeCard[];
  wallpapers: ThemeCard[];
}

export interface ThemeApplyResult {
  theme: CurrentTheme;
  job: Job;
}

export interface RdpResetResult {
  status: string;
  force: boolean;
  exit_code?: number | null;
  output: string;
}

export interface GenerationDiffEntry {
  name: string;
  change: "added" | "removed" | "changed" | string;
  before?: string | null;
  after?: string | null;
  size?: string | null;
  line: string;
}

export interface GenerationDiff {
  from: number;
  to: number;
  entries: GenerationDiffEntry[];
  lines: string[];
  added: number;
  removed: number;
  changed: number;
  truncated: boolean;
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
  entries: LogEntry[];
}

export interface LogEntry {
  timestamp: string;
  priority: number;
  level: string;
  message: string;
  identifier?: string | null;
  unit?: string | null;
  pid?: number | null;
  hostname?: string | null;
  transport?: string | null;
  comm?: string | null;
  exe?: string | null;
}

export interface SessionSummary {
  id: string;
  kind: "app" | "login";
  source: string;
  title: string;
  user?: string | null;
  tty?: string | null;
  seat?: string | null;
  remote_host?: string | null;
  service?: string | null;
  state: string;
  started_at: string;
  last_active_at: string;
  action_count: number;
  status: string;
  summary: string;
}

export interface SessionsResponse {
  sessions: SessionSummary[];
}

export interface SessionAction {
  id: string;
  at: string;
  action: string;
  target?: string | null;
  status: string;
  detail?: string | null;
  job_id?: string | null;
  output?: string | null;
  method?: string | null;
  path?: string | null;
  status_code?: number | null;
  duration_ms?: number | null;
}

export interface SessionCommand {
  at?: string | null;
  command: string;
  duration_ms?: number | null;
  exit_code?: number | null;
  status?: string | null;
  cwd?: string | null;
  source?: string | null;
}

export interface SessionDetail extends SessionSummary {
  actions: SessionAction[];
  logs: string[];
  commands: SessionCommand[];
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
  | "sessions"
  | "services"
  | "resources"
  | "logs"
  | "themes"
  | "storage"
  | "system"
  | "peripherals"
  | "settings";