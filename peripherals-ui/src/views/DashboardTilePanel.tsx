import { useEffect, useMemo, useState } from "react";

import { LineChart, type ChartSeries } from "../chart";
import {
  InfoRow,
  Modal,
  Spinner,
  formatBytes,
  formatPercent,
  formatPreciseTimestamp,
  formatUptime,
} from "../components";
import { useNixOSControl } from "../store";
import type { StatusSample, SystemStatus } from "../types";

export type DashboardTile = "cpu" | "memory" | "load" | "disk";

const WINDOW_MINUTES = 60;

const TITLES: Record<DashboardTile, { title: string; description: string }> = {
  cpu: { title: "CPU history", description: "Usage sampled every 10 seconds" },
  memory: { title: "Memory history", description: "Used memory over the last hour" },
  load: { title: "Load history", description: "1, 5 and 15 minute load averages" },
  disk: { title: "Root disk history", description: "Filesystem usage over time" },
};

interface HistoryView {
  series: ChartSeries[];
  min?: number;
  max?: number;
  formatValue: (value: number) => string;
  primary: (sample: StatusSample) => number;
  primaryLabel: string;
}

function historyView(
  tile: DashboardTile,
  status: SystemStatus,
): HistoryView {
  switch (tile) {
    case "memory":
      return {
        series: [
          {
            label: "Used",
            color: "var(--accent)",
            values: [],
          },
        ],
        min: 0,
        max: status.memory.total,
        formatValue: formatBytes,
        primary: (sample) => sample.memory.used,
        primaryLabel: "Used",
      };
    case "load":
      return {
        series: [
          { label: "1 min", color: "var(--accent)", values: [] },
          { label: "5 min", color: "var(--warn)", values: [] },
          { label: "15 min", color: "#4fd1c5", values: [] },
        ],
        min: 0,
        formatValue: (value) => value.toFixed(2),
        primary: (sample) => sample.load[0] ?? 0,
        primaryLabel: "1 min",
      };
    case "disk":
      return {
        series: [
          { label: "Used", color: "var(--warn)", values: [] },
        ],
        min: 0,
        max: 100,
        formatValue: (value) => formatPercent(value, 0),
        primary: (sample) => sample.root_disk.use_percent,
        primaryLabel: "Used",
      };
    default:
      return {
        series: [
          { label: "CPU", color: "var(--accent)", values: [] },
        ],
        min: 0,
        max: 100,
        formatValue: (value) => formatPercent(value, 0),
        primary: (sample) => sample.cpu.usage_percent,
        primaryLabel: "CPU",
      };
  }
}

function buildSeries(
  tile: DashboardTile,
  samples: StatusSample[],
  view: HistoryView,
): ChartSeries[] {
  return view.series.map((series, index) => ({
    ...series,
    values: samples.map((sample) => {
      switch (tile) {
        case "memory":
          return sample.memory.used;
        case "load":
          return sample.load[index] ?? 0;
        case "disk":
          return sample.root_disk.use_percent;
        default:
          return sample.cpu.usage_percent;
      }
    }),
  }));
}

function stats(values: number[]): { min: number; avg: number; max: number } | null {
  const finite = values.filter((value) => Number.isFinite(value));
  if (finite.length === 0) {
    return null;
  }
  const min = Math.min(...finite);
  const max = Math.max(...finite);
  const avg = finite.reduce((total, value) => total + value, 0) / finite.length;
  return { min, avg, max };
}

export default function DashboardTilePanel({
  tile,
  status,
  onClose,
}: {
  tile: DashboardTile;
  status: SystemStatus;
  onClose: () => void;
}) {
  const { fetchStatusHistory } = useNixOSControl();
  const [samples, setSamples] = useState<StatusSample[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      const next = await fetchStatusHistory(WINDOW_MINUTES, 720);
      if (!cancelled) {
        setSamples(next);
        setLoading(false);
      }
    };

    void load();
    const interval = window.setInterval(() => {
      void load();
    }, 10_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [fetchStatusHistory]);

  const view = useMemo(() => historyView(tile, status), [tile, status]);
  const series = useMemo(
    () => buildSeries(tile, samples, view),
    [tile, samples, view],
  );
  const primary = useMemo(
    () => samples.map((sample) => view.primary(sample)),
    [samples, view],
  );
  const summary = stats(primary);
  const labels = samples.map((sample) => sample.at);
  const recent = samples.slice(-10).reverse();

  return (
    <Modal title={TITLES[tile].title} onClose={onClose}>
      <p className="muted session-note">
        {TITLES[tile].description}. Server-side history, kept for six hours.
      </p>

      {loading && samples.length === 0 ? (
        <Spinner label="Loading history…" />
      ) : samples.length === 0 ? (
        <p className="muted">
          No samples yet. The server records one every 10 seconds.
        </p>
      ) : (
        <>
          <LineChart
            series={series}
            labels={labels}
            min={view.min}
            max={view.max}
            formatValue={view.formatValue}
            ariaLabel={`${TITLES[tile].title} chart`}
          />

          {summary ? (
            <div className="chart-stats">
              <div>
                <span>Min</span>
                <strong>{view.formatValue(summary.min)}</strong>
              </div>
              <div>
                <span>Average</span>
                <strong>{view.formatValue(summary.avg)}</strong>
              </div>
              <div>
                <span>Max</span>
                <strong>{view.formatValue(summary.max)}</strong>
              </div>
              <div>
                <span>Samples</span>
                <strong>{samples.length}</strong>
              </div>
            </div>
          ) : null}
        </>
      )}

      <section className="session-section">
        <h3>Current</h3>
        <div className="detail-grid">
          {tile === "cpu" ? (
            <>
              <InfoRow label="Model" value={status.cpu.model} />
              <InfoRow label="Cores" value={String(status.cpu.cores)} />
              <InfoRow
                label="Usage"
                value={formatPercent(status.cpu.usage_percent, 1)}
              />
              <InfoRow
                label="Load 1 / 5 / 15"
                value={status.load.map((value) => value.toFixed(2)).join(" / ")}
              />
              <InfoRow label="Uptime" value={formatUptime(status.uptime_seconds)} />
              <InfoRow label="Generation" value={String(status.generation)} />
            </>
          ) : null}

          {tile === "memory" ? (
            <>
              <InfoRow label="Total" value={formatBytes(status.memory.total)} />
              <InfoRow label="Used" value={formatBytes(status.memory.used)} />
              <InfoRow label="Free" value={formatBytes(status.memory.free)} />
              <InfoRow
                label="Available"
                value={formatBytes(status.memory.available)}
              />
              <InfoRow label="Cached" value={formatBytes(status.memory.cached)} />
              <InfoRow
                label="Swap"
                value={`${formatBytes(status.memory.swap_used)} of ${formatBytes(status.memory.swap_total)}`}
              />
            </>
          ) : null}

          {tile === "load" ? (
            <>
              <InfoRow
                label="1 minute"
                value={(status.load[0] ?? 0).toFixed(2)}
              />
              <InfoRow
                label="5 minutes"
                value={(status.load[1] ?? 0).toFixed(2)}
              />
              <InfoRow
                label="15 minutes"
                value={(status.load[2] ?? 0).toFixed(2)}
              />
              <InfoRow label="Cores" value={String(status.cpu.cores)} />
              <InfoRow label="Uptime" value={formatUptime(status.uptime_seconds)} />
            </>
          ) : null}

          {tile === "disk" ? (
            <>
              <InfoRow label="Mount" value={status.root_disk.mount} mono />
              <InfoRow label="Total" value={formatBytes(status.root_disk.total)} />
              <InfoRow label="Used" value={formatBytes(status.root_disk.used)} />
              <InfoRow
                label="Available"
                value={formatBytes(status.root_disk.available)}
              />
              <InfoRow
                label="Usage"
                value={formatPercent(status.root_disk.use_percent, 0)}
              />
              <InfoRow label="Generation" value={String(status.generation)} />
            </>
          ) : null}
        </div>
      </section>

      {recent.length > 0 ? (
        <section className="session-section">
          <h3>Recent samples</h3>
          <div className="history-list">
            {recent.map((sample, index) => (
              <div className="history-row" key={`${sample.at}-${index}`}>
                <span>{formatPreciseTimestamp(sample.at)}</span>
                <strong>{view.formatValue(view.primary(sample))}</strong>
              </div>
            ))}
          </div>
        </section>
      ) : null}
    </Modal>
  );
}