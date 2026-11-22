import {
  Card,
  EmptyState,
  ErrorBanner,
  MetricTile,
  Spinner,
  StatusBadge,
  formatBytes,
  formatPercent,
  formatTime,
  formatUptime,
  poolTone,
} from "../components";
import { useNixOSControl } from "../store";
import type { AppTab } from "../types";

export default function DashboardView({
  onNavigate,
}: {
  onNavigate: (tab: AppTab) => void;
}) {
  const {
    status,
    loading,
    error,
    refreshStatus,
    peripherals,
    lastUpdated,
    connectionState,
  } = useNixOSControl();

  if (!status && loading.status) {
    return <Spinner label="Loading system status…" />;
  }

  if (!status) {
    return (
      <>
        {error ? <ErrorBanner message={error} /> : null}
        <EmptyState
          icon="◈"
          title="No status data yet"
          description="Check the connection and refresh."
          action={
            <button type="button" className="button primary" onClick={() => void refreshStatus()}>
              Refresh
            </button>
          }
        />
      </>
    );
  }

  const memoryFraction = usageFraction(status.memory.used, status.memory.total);
  const diskFraction = status.root_disk.use_percent / 100;
  const receiver = peripherals?.receiver;
  const onlineDevices = peripherals?.devices.filter((device) => device.online).length ?? 0;

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}

      <Card className="hero-card">
        <div className="hero">
          <div>
            <div className="eyebrow">NixOS host</div>
            <h2>{status.hostname}</h2>
            <p>{status.os || "NixOS"}</p>
          </div>
          <StatusBadge
            text={connectionState}
            tone={
              connectionState === "online"
                ? "good"
                : connectionState === "connecting"
                  ? "warn"
                  : connectionState === "offline"
                    ? "bad"
                    : "muted"
            }
          />
        </div>
        <div className="hero-meta">
          <span>{status.kernel}</span>
          <span>up {formatUptime(status.uptime_seconds)}</span>
          <span>generation {status.generation}</span>
          {status.tailscale ? (
            <span>
              tailscale {status.tailscale.connected ? status.tailscale.dns_name || "connected" : status.tailscale.state}
            </span>
          ) : null}
        </div>
      </Card>

      <div className="metric-grid">
        <MetricTile
          label="CPU"
          value={formatPercent(status.cpu.usage_percent, 1)}
          caption={`${status.cpu.cores} cores · ${status.cpu.model}`}
          progress={status.cpu.usage_percent / 100}
        />
        <MetricTile
          label="Memory"
          value={formatBytes(status.memory.used)}
          caption={`of ${formatBytes(status.memory.total)}`}
          progress={memoryFraction}
          tone={memoryFraction >= 0.9 ? "bad" : "accent"}
        />
        <MetricTile
          label="Load average"
          value={status.load.map((value) => value.toFixed(2)).join(" / ")}
          caption="1 / 5 / 15 minutes"
        />
        <MetricTile
          label="Root disk"
          value={formatPercent(status.root_disk.use_percent, 0)}
          caption={`${formatBytes(status.root_disk.used)} of ${formatBytes(status.root_disk.total)}`}
          progress={diskFraction}
          tone={diskFraction >= 0.9 ? "bad" : "accent"}
        />
      </div>

      <div className="two-column">
        <Card
          title="Services"
          subtitle={`${status.services.running} running · ${status.services.failed} failed · ${status.services.total} total`}
          action={
            <button type="button" className="button ghost" onClick={() => onNavigate("services")}>
              Manage
            </button>
          }
        >
          <div className="count-row">
            <Count value={status.services.running} label="running" tone="good" />
            <Count value={status.services.failed} label="failed" tone={status.services.failed > 0 ? "bad" : "muted"} />
            <Count value={status.services.total} label="total" tone="muted" />
          </div>
        </Card>

        <Card
          title="Peripherals"
          subtitle="Logitech receiver and paired devices"
          action={
            <button type="button" className="button ghost" onClick={() => onNavigate("peripherals")}>
              Open
            </button>
          }
        >
          {receiver ? (
            <div className="receiver-summary">
              <div>
                <strong>{receiver.product ?? "Logitech receiver"}</strong>
                <span>{receiver.kind} · {receiver.paired_devices} paired · {onlineDevices} online</span>
              </div>
              <StatusBadge text={receiver.path} tone="accent" />
            </div>
          ) : (
            <p className="muted">Open Peripherals to inspect the receiver.</p>
          )}
        </Card>
      </div>

      {status.pools.length > 0 ? (
        <Card title="ZFS pools" subtitle="Health and capacity">
          <div className="list">
            {status.pools.map((pool) => (
              <div className="pool-row" key={pool.name}>
                <div className="pool-row-head">
                  <strong>{pool.name}</strong>
                  <StatusBadge text={pool.health} tone={poolTone(pool.health)} />
                </div>
                <div className="usage-bar">
                  <div
                    className={`usage-fill ${poolTone(pool.health)}`}
                    style={{ width: `${usageFraction(pool.allocated, pool.size) * 100}%` }}
                  />
                </div>
                <div className="pool-row-foot">
                  <span>{formatBytes(pool.allocated)} of {formatBytes(pool.size)}</span>
                  <span>{formatBytes(pool.free)} free</span>
                </div>
              </div>
            ))}
          </div>
        </Card>
      ) : null}

      {status.temperatures.length > 0 ? (
        <Card title="Temperatures">
          <div className="chip-row">
            {status.temperatures.map((temperature) => (
              <div className="temp-chip" key={temperature.label}>
                <strong>{temperature.celsius.toFixed(0)}°C</strong>
                <span>{temperature.label}</span>
              </div>
            ))}
          </div>
        </Card>
      ) : null}

      <Card title="Network">
        {status.addresses.length === 0 ? (
          <p className="muted">No network addresses reported.</p>
        ) : (
          <div className="address-list">
            {status.addresses.map((address) => (
              <code key={address}>{address}</code>
            ))}
          </div>
        )}
        {status.tailscale ? (
          <div className="info-row">
            <span>Tailscale</span>
            <strong>
              {status.tailscale.connected
                ? status.tailscale.dns_name || "Connected"
                : status.tailscale.state}
            </strong>
          </div>
        ) : null}
      </Card>

      <div className="view-footer">
        {lastUpdated ? `Updated ${formatTime(lastUpdated)}` : null}
      </div>
    </div>
  );
}

function Count({
  value,
  label,
  tone,
}: {
  value: number;
  label: string;
  tone: "good" | "warn" | "bad" | "muted" | "accent";
}) {
  return (
    <div className="count">
      <strong className={`tone-${tone}`}>{value}</strong>
      <span>{label}</span>
    </div>
  );
}

function usageFraction(used: number, total: number): number {
  if (!Number.isFinite(used) || !Number.isFinite(total) || total <= 0) {
    return 0;
  }
  return Math.min(Math.max(used / total, 0), 1);
}