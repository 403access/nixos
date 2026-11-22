import { useEffect, useState } from "react";
import type { FormEvent } from "react";

import { checkHealth, errorMessage, fetchPeripherals } from "./api";
import type {
  BatteryInfo,
  DeviceInfo,
  FirmwareEntry,
  ProbeReport,
  ReceiverInfo,
  SignalInfo,
} from "./types";

interface Settings {
  serverUrl: string;
  token: string;
}

const STORAGE_KEY = "nixos-control.peripherals.settings";
const DEFAULT_SERVER_URL = import.meta.env.VITE_API_BASE ?? "";

const initialSettings = loadSettings();

export default function App() {
  const [active, setActive] = useState<Settings | null>(initialSettings);
  const [editing, setEditing] = useState(initialSettings === null);
  const [report, setReport] = useState<ProbeReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [refreshTick, setRefreshTick] = useState(0);
  const [serverVersion, setServerVersion] = useState<string | null>(null);

  useEffect(() => {
    if (!active) {
      return;
    }

    let cancelled = false;

    const load = async () => {
      setLoading(true);
      try {
        const data = await fetchPeripherals(active.serverUrl, active.token);
        if (cancelled) {
          return;
        }
        setReport(data);
        setError(null);
        setLastUpdated(new Date());
      } catch (cause) {
        if (!cancelled) {
          setError(errorMessage(cause));
        }
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    };

    void load();

    if (!autoRefresh) {
      return () => {
        cancelled = true;
      };
    }

    const interval = window.setInterval(() => {
      void load();
    }, 5_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [active, autoRefresh, refreshTick]);

  async function saveSettings(next: Settings) {
    setSaving(true);
    setSettingsError(null);
    try {
      const health = await checkHealth(next.serverUrl, next.token);
      setServerVersion(health.version);
      setActive(next);
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      setEditing(false);
      setReport(null);
      setError(null);
      setLastUpdated(null);
    } catch (cause) {
      setSettingsError(errorMessage(cause));
    } finally {
      setSaving(false);
    }
  }

  function clearSettings() {
    localStorage.removeItem(STORAGE_KEY);
    setActive(null);
    setReport(null);
    setError(null);
    setSettingsError(null);
    setLastUpdated(null);
    setServerVersion(null);
    setEditing(true);
  }

  const status = error
    ? report
      ? "stale"
      : "offline"
    : loading
      ? "syncing"
      : report
        ? "online"
        : "idle";

  const tone =
    status === "online"
      ? "good"
      : status === "syncing"
        ? "warn"
        : status === "offline"
          ? "bad"
          : "idle";

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">
            ◉
          </div>
          <div>
            <h1>Peripherals</h1>
            <p>Logitech receiver · read-only HID++</p>
          </div>
        </div>

        <div className="topbar-actions">
          <span className={`status-pill status-${tone}`}>
            <span className="dot" aria-hidden="true" />
            {status}
          </span>
          <button
            type="button"
            className="button ghost"
            onClick={() => setRefreshTick((value) => value + 1)}
            disabled={!active}
          >
            Refresh
          </button>
          <button
            type="button"
            className="button ghost"
            onClick={() => setEditing(true)}
          >
            Settings
          </button>
        </div>
      </header>

      {editing || !active ? (
        <SettingsPanel
          initial={active ?? { serverUrl: DEFAULT_SERVER_URL, token: "" }}
          hasSaved={active !== null}
          saving={saving}
          error={settingsError}
          onSave={saveSettings}
          onCancel={() => {
            setEditing(false);
            setSettingsError(null);
          }}
          onClear={clearSettings}
        />
      ) : (
        <>
          <div className="meta-row">
            <span className="mono">{active.serverUrl || "same-origin proxy"}</span>
            {serverVersion ? <span>server {serverVersion}</span> : null}
            <span>
              {lastUpdated
                ? `updated ${formatTime(lastUpdated)}`
                : loading
                  ? "loading…"
                  : "waiting for data"}
            </span>
            <label className="toggle">
              <input
                type="checkbox"
                checked={autoRefresh}
                onChange={(event) => setAutoRefresh(event.target.checked)}
              />
              Auto-refresh
            </label>
          </div>

          {error ? <div className="banner error">{error}</div> : null}

          {!report && loading ? <LoadingCards /> : null}

          {report ? (
            <>
              <ReceiverCard receiver={report.receiver} />
              <section className="section">
                <div className="section-head">
                  <h2>Paired devices</h2>
                  <span>
                    {report.devices.length}{" "}
                    {report.devices.length === 1 ? "device" : "devices"}
                  </span>
                </div>
                {report.devices.length === 0 ? (
                  <EmptyDevices />
                ) : (
                  <div className="device-grid">
                    {report.devices.map((device) => (
                      <DeviceCard key={device.slot} device={device} />
                    ))}
                  </div>
                )}
              </section>
            </>
          ) : null}
        </>
      )}

      <footer className="footer">
        <span>Read-only HID++ inspector</span>
        <span>{serverVersion ? `NixOS Control ${serverVersion}` : "NixOS Control"}</span>
      </footer>
    </div>
  );
}

function SettingsPanel({
  initial,
  hasSaved,
  saving,
  error,
  onSave,
  onCancel,
  onClear,
}: {
  initial: Settings;
  hasSaved: boolean;
  saving: boolean;
  error: string | null;
  onSave: (settings: Settings) => void | Promise<void>;
  onCancel: () => void;
  onClear: () => void;
}) {
  const [serverUrl, setServerUrl] = useState(initial.serverUrl);
  const [token, setToken] = useState(initial.token);
  const [showToken, setShowToken] = useState(false);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void onSave({ serverUrl: serverUrl.trim(), token: token.trim() });
  }

  return (
    <section className="settings-card">
      <div className="settings-head">
        <div>
          <div className="eyebrow">Connection</div>
          <h2>Connect to the NixOS API</h2>
        </div>
        <span className="badge">bearer token</span>
      </div>

      <p className="muted">
        The token and URL are stored in this browser&apos;s localStorage. Leave the
        server URL empty to use the local proxy from <code>bun run dev</code> or{" "}
        <code>bun run start</code>.
      </p>

      <form className="settings-form" onSubmit={submit}>
        <label>
          Server URL
          <input
            value={serverUrl}
            onChange={(event) => setServerUrl(event.target.value)}
            placeholder="http://192.168.178.5:8787 or leave blank"
            autoComplete="url"
            spellCheck={false}
          />
        </label>

        <label>
          API token
          <span className="token-row">
            <input
              type={showToken ? "text" : "password"}
              value={token}
              onChange={(event) => setToken(event.target.value)}
              placeholder="nixos-control-token"
              autoComplete="off"
              spellCheck={false}
            />
            <button
              type="button"
              className="button ghost"
              onClick={() => setShowToken((value) => !value)}
            >
              {showToken ? "Hide" : "Show"}
            </button>
          </span>
        </label>

        {error ? <div className="form-error">{error}</div> : null}

        <div className="form-actions">
          <button
            type="submit"
            className="button primary"
            disabled={saving || token.trim().length === 0}
          >
            {saving ? "Testing…" : "Test & save"}
          </button>
          {hasSaved ? (
            <button type="button" className="button ghost" onClick={onCancel}>
              Cancel
            </button>
          ) : null}
          {hasSaved ? (
            <button type="button" className="button danger" onClick={onClear}>
              Forget
            </button>
          ) : null}
        </div>
      </form>

      <div className="hint">
        Run <code>sudo nixos-control-token</code> on the host to print the token.
        The API must be reachable from this browser.
      </div>
    </section>
  );
}

function ReceiverCard({ receiver }: { receiver: ReceiverInfo }) {
  return (
    <section className="receiver-card">
      <div className="receiver-head">
        <div>
          <div className="eyebrow">Receiver</div>
          <h2>{receiver.product ?? "Logitech receiver"}</h2>
          <p>
            {receiver.manufacturer ?? "Logitech"} · {receiver.kind}
          </p>
        </div>
        <span className="badge badge-accent">{receiver.kind}</span>
      </div>

      <div className="stat-grid">
        <Stat
          label="USB"
          value={`${hex4(receiver.vendor_id)}:${hex4(receiver.product_id)}`}
          mono
        />
        <Stat label="Path" value={receiver.path} mono />
        <Stat label="Serial" value={receiver.serial ?? "unknown"} mono />
        <Stat
          label="Slots"
          value={`${receiver.paired_devices} / ${receiver.max_devices}`}
        />
        {receiver.remaining_pairings !== null ? (
          <Stat label="Remaining" value={String(receiver.remaining_pairings)} />
        ) : null}
      </div>

      <FirmwareList entries={receiver.firmware} />
    </section>
  );
}

function DeviceCard({ device }: { device: DeviceInfo }) {
  return (
    <article className={`device-card${device.online ? "" : " offline"}`}>
      <div className="device-head">
        <div className="device-icon" aria-hidden="true">
          {deviceIcon(device.kind)}
        </div>
        <div className="device-title">
          <div className="eyebrow">
            Slot {device.slot} · {device.kind ?? "device"}
          </div>
          <h3>{device.name ?? device.kind ?? `Device ${device.slot}`}</h3>
          <span className={`badge ${device.online ? "badge-online" : "badge-offline"}`}>
            {device.online ? "online" : "offline"}
          </span>
        </div>
      </div>

      {device.battery ? <Battery battery={device.battery} /> : null}

      <div className="device-meta">
        <Meta label="WPID" value={device.wpid ?? "—"} mono />
        <Meta label="Serial" value={device.serial ?? "—"} mono />
        {device.signal ? (
          <Meta label="Signal" value={formatSignal(device.signal)} />
        ) : null}
      </div>

      <FirmwareList entries={device.firmware} compact />
    </article>
  );
}

function Battery({ battery }: { battery: BatteryInfo }) {
  const percent = battery.percent;
  const tone =
    percent === null
      ? "muted"
      : percent >= 50
        ? "good"
        : percent >= 20
          ? "warn"
          : "bad";
  const voltage = formatVoltage(battery.voltage_mv);

  return (
    <div className="battery">
      <div className="battery-head">
        <span>Battery</span>
        <strong>{percent === null ? "unknown" : `${percent}%`}</strong>
      </div>
      <div className="battery-track">
        <div
          className={`battery-fill ${tone}`}
          style={{ width: `${percent ?? 0}%` }}
        />
      </div>
      <div className="battery-foot">
        <span>{formatStatus(battery.status)}</span>
        {battery.next_percent !== null ? (
          <span>next {battery.next_percent}%</span>
        ) : null}
        {voltage ? <span>{voltage}</span> : null}
      </div>
    </div>
  );
}

function FirmwareList({
  entries,
  compact = false,
}: {
  entries: FirmwareEntry[];
  compact?: boolean;
}) {
  if (entries.length === 0) {
    return null;
  }

  return (
    <div className={`firmware${compact ? " compact" : ""}`}>
      <div className="eyebrow">Firmware</div>
      <div className="firmware-list">
        {entries.map((entry, index) => (
          <span
            className="firmware-chip"
            key={`${entry.kind}-${entry.name}-${entry.version}-${index}`}
          >
            <span>{entry.kind}</span>
            {entry.name ? <span className="firmware-name">{entry.name}</span> : null}
            {entry.version ? <strong>{entry.version}</strong> : null}
          </span>
        ))}
      </div>
    </div>
  );
}

function Stat({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className={`stat-value${mono ? " mono" : ""}`}>{value}</span>
    </div>
  );
}

function Meta({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="meta">
      <span className="stat-label">{label}</span>
      <span className={mono ? "mono" : undefined}>{value}</span>
    </div>
  );
}

function LoadingCards() {
  return (
    <div className="skeleton-grid">
      <div className="skeleton-card" />
      <div className="skeleton-card" />
      <div className="skeleton-card" />
    </div>
  );
}

function EmptyDevices() {
  return (
    <div className="empty">
      <div className="empty-icon" aria-hidden="true">
        ⌘
      </div>
      <h3>No paired devices</h3>
      <p>The receiver is present, but no device is currently paired.</p>
    </div>
  );
}

function loadSettings(): Settings | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw) as Partial<Settings>;
    if (!parsed.token) {
      return null;
    }
    return {
      serverUrl: parsed.serverUrl ?? "",
      token: parsed.token,
    };
  } catch {
    return null;
  }
}

function hex4(value: number): string {
  return value.toString(16).padStart(4, "0");
}

function formatVoltage(millivolts: number | null): string | null {
  if (millivolts === null) {
    return null;
  }
  return millivolts >= 1_000
    ? `${(millivolts / 1_000).toFixed(2)} V`
    : `${millivolts} mV`;
}

function formatSignal(signal: SignalInfo): string {
  return signal.percent === null ? `raw ${signal.raw}` : `${signal.percent}%`;
}

function formatStatus(status: string | null): string {
  return status ? status.replaceAll("_", " ") : "unknown";
}

function formatTime(date: Date): string {
  return date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function deviceIcon(kind: string | null): string {
  switch (kind) {
    case "keyboard":
      return "⌨";
    case "mouse":
      return "🖱";
    case "trackball":
      return "🖲";
    case "touchpad":
      return "▭";
    case "numpad":
      return "⌨";
    default:
      return "•";
  }
}