import { useEffect } from "react";

import {
  EmptyState,
  ErrorBanner,
  Spinner,
  StatusBadge,
  UsageBar,
  deviceIcon,
  formatPercent,
  formatSignal,
  formatStatus,
  formatVoltage,
} from "../components";
import { useNixOSControl } from "../store";
import type { BatteryInfo, DeviceInfo, FirmwareEntry, ReceiverInfo } from "../types";

export default function PeripheralsView() {
  const {
    peripherals,
    loading,
    peripheralsError,
    loadPeripherals,
  } = useNixOSControl();

  useEffect(() => {
    void loadPeripherals();
    const interval = window.setInterval(() => {
      void loadPeripherals();
    }, 15_000);
    return () => window.clearInterval(interval);
  }, [loadPeripherals]);

  return (
    <div className="view-stack">
      {peripheralsError ? <ErrorBanner message={peripheralsError} /> : null}

      <div className="toolbar-row">
        <span className="toolbar-count">
          Read-only HID++ · auto-refreshes every 15s
        </span>
        <button
          type="button"
          className="button ghost"
          onClick={() => void loadPeripherals()}
          disabled={loading.peripherals}
        >
          {loading.peripherals ? "Reading…" : "Refresh"}
        </button>
      </div>

      {!peripherals && loading.peripherals ? (
        <Spinner label="Reading Logitech receiver…" />
      ) : !peripherals ? (
        <EmptyState
          icon="⌨"
          title="No receiver data"
          description="Check that the receiver is connected and the API is reachable."
          action={
            <button type="button" className="button primary" onClick={() => void loadPeripherals()}>
              Retry
            </button>
          }
        />
      ) : (
        <>
          <ReceiverCard receiver={peripherals.receiver} />
          <section className="section">
            <div className="section-head">
              <div>
                <h2>Paired devices</h2>
                <span>
                  {peripherals.devices.length}{" "}
                  {peripherals.devices.length === 1 ? "device" : "devices"}
                </span>
              </div>
            </div>
            {peripherals.devices.length === 0 ? (
              <EmptyState
                icon="⌘"
                title="No paired devices"
                description="The receiver is present, but nothing is currently paired."
              />
            ) : (
              <div className="device-grid">
                {peripherals.devices.map((device) => (
                  <DeviceCard device={device} key={device.slot} />
                ))}
              </div>
            )}
          </section>
        </>
      )}
    </div>
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
        <StatusBadge text={receiver.kind} tone="accent" />
      </div>

      <div className="stat-grid">
        <Stat label="USB" value={`${hex4(receiver.vendor_id)}:${hex4(receiver.product_id)}`} mono />
        <Stat label="Path" value={receiver.path} mono />
        <Stat label="Serial" value={receiver.serial ?? "unknown"} mono />
        <Stat
          label="Slots"
          value={`${receiver.paired_devices} / ${receiver.max_devices}`}
        />
        {receiver.remaining_pairings !== null ? (
          <Stat
            label="Remaining"
            value={receiver.remaining_pairings < 0 ? "unlimited" : String(receiver.remaining_pairings)}
          />
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
          <StatusBadge
            text={device.online ? "online" : "offline"}
            tone={device.online ? "good" : "muted"}
          />
        </div>
      </div>

      {device.battery ? <Battery battery={device.battery} /> : null}

      <div className="device-meta">
        <Meta label="WPID" value={device.wpid ?? "—"} mono />
        <Meta label="Serial" value={device.serial ?? "—"} mono />
        {device.signal ? <Meta label="Signal" value={formatSignal(device.signal)} /> : null}
      </div>

      <FirmwareList entries={device.firmware} compact />
    </article>
  );
}

function Battery({ battery }: { battery: BatteryInfo }) {
  const percent = battery.percent;
  const tone =
    percent === null ? "muted" : percent >= 50 ? "good" : percent >= 20 ? "warn" : "bad";
  const voltage = formatVoltage(battery.voltage_mv);

  return (
    <div className="battery">
      <div className="battery-head">
        <span>Battery</span>
        <strong>{percent === null ? "unknown" : formatPercent(percent, 0)}</strong>
      </div>
      <UsageBar fraction={(percent ?? 0) / 100} tone={tone} />
      <div className="battery-foot">
        <span>{formatStatus(battery.status)}</span>
        {battery.next_percent !== null ? <span>next {battery.next_percent}%</span> : null}
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
          <span className="firmware-chip" key={`${entry.kind}-${entry.name}-${entry.version}-${index}`}>
            <span>{entry.kind}</span>
            {entry.name ? <span className="firmware-name">{entry.name}</span> : null}
            {entry.version ? <strong>{entry.version}</strong> : null}
          </span>
        ))}
      </div>
    </div>
  );
}

function Stat({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className={`stat-value${mono ? " mono" : ""}`}>{value}</span>
    </div>
  );
}

function Meta({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="meta">
      <span className="stat-label">{label}</span>
      <span className={mono ? "mono" : undefined}>{value}</span>
    </div>
  );
}

function hex4(value: number): string {
  return value.toString(16).padStart(4, "0");
}