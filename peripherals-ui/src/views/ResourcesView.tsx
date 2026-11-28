import { useEffect, useMemo, useState } from "react";

import { LineChart, type ChartSeries } from "../chart";
import {
  Card,
  EmptyState,
  ErrorBanner,
  InfoRow,
  MetricTile,
  Modal,
  Spinner,
  StatusBadge,
  UsageBar,
  formatBytes,
  formatPercent,
  formatPreciseTimestamp,
} from "../components";
import { useNixOSControl } from "../store";
import type {
  ResourceEntry,
  ResourceHistory,
  ResourceHistoryMetric,
  ResourceProcess,
  ResourceSeriesPoint,
  ResourceUsage,
} from "../types";

type Mode = "services" | "apps" | "processes";
type SortKey = "cpu" | "memory" | "read" | "write" | "rx" | "tx";
type HistoryMetric = ResourceHistoryMetric;
type HistoryKind = "services" | "apps";

const CHART_COLORS = [
  "#5aa9ff",
  "#fbbf24",
  "#4fd1c5",
  "#c084fc",
  "#f472b6",
  "#facc15",
  "#94a3b8",
  "#fb923c",
  "#34d399",
  "#60a5fa",
  "#a78bfa",
  "#f97316",
];

interface Row {
  key: string;
  name: string;
  kind: string;
  unit: string;
  tasks: number;
  pid?: number;
  command?: string;
  cpu: number;
  memory: number;
  read: number;
  write: number;
  rx: number;
  tx: number;
}

function kindTone(kind: string): "good" | "warn" | "bad" | "muted" | "accent" {
  switch (kind) {
    case "service":
      return "accent";
    case "machine":
      return "warn";
    case "app":
      return "good";
    default:
      return "muted";
  }
}

function formatRate(value: number): string {
  return `${formatBytes(value)}/s`;
}

function metricValue(
  point: ResourceSeriesPoint,
  metric: HistoryMetric,
): number {
  switch (metric) {
    case "memory":
      return point.memory_bytes;
    case "read":
      return point.read_bps;
    case "write":
      return point.write_bps;
    case "rx":
      return point.network_rx_bps;
    case "tx":
      return point.network_tx_bps;
    default:
      return point.cpu_percent;
  }
}

function formatMetric(metric: HistoryMetric, value: number): string {
  switch (metric) {
    case "memory":
      return formatBytes(value);
    case "read":
    case "write":
    case "rx":
    case "tx":
      return formatRate(value);
    default:
      return formatPercent(value, 1);
  }
}

function rowsFor(usage: ResourceUsage, mode: Mode): Row[] {
  if (mode === "processes") {
    return usage.processes.map((process) => ({
      key: `pid-${process.pid}`,
      name: process.name,
      kind: process.kind,
      unit: process.unit,
      tasks: 0,
      pid: process.pid,
      command: process.command,
      cpu: process.cpu_percent,
      memory: process.memory_bytes,
      read: process.read_bps,
      write: process.write_bps,
      rx: process.network_rx_bps,
      tx: process.network_tx_bps,
    }));
  }

  const entries: ResourceEntry[] =
    mode === "services" ? usage.services : usage.apps;
  return entries.map((entry) => ({
    key: `${entry.unit}|${entry.name}`,
    name: entry.name,
    kind: entry.kind,
    unit: entry.unit,
    tasks: entry.tasks,
    cpu: entry.cpu_percent,
    memory: entry.memory_bytes,
    read: entry.read_bps,
    write: entry.write_bps,
    rx: entry.network_rx_bps,
    tx: entry.network_tx_bps,
  }));
}

export default function ResourcesView() {
  const { fetchResources, fetchResourceHistory, error } = useNixOSControl();
  const [usage, setUsage] = useState<ResourceUsage | null>(null);
  const [mode, setMode] = useState<Mode>("services");
  const [sort, setSort] = useState<SortKey>("cpu");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [refreshTick, setRefreshTick] = useState(0);
  const [history, setHistory] = useState<ResourceHistory | null>(null);
  const [historyKind, setHistoryKind] = useState<HistoryKind>("services");
  const [historyMetric, setHistoryMetric] = useState<HistoryMetric>("cpu");
  const [historyMinutes, setHistoryMinutes] = useState(15);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      const next = await fetchResources();
      if (!cancelled && next) {
        setUsage(next);
      }
    };

    void load();
    const interval = window.setInterval(() => {
      void load();
    }, 5_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [fetchResources, refreshTick]);

  useEffect(() => {
    if (mode === "apps") {
      setHistoryKind("apps");
    } else if (mode === "services") {
      setHistoryKind("services");
    }
  }, [mode]);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      const next = await fetchResourceHistory({
        kind: historyKind,
        minutes: historyMinutes,
        metric: historyMetric,
        top: 8,
      });
      if (!cancelled) {
        setHistory(next);
      }
    };

    void load();
    const interval = window.setInterval(() => {
      void load();
    }, 15_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [
    historyKind,
    historyMinutes,
    historyMetric,
    fetchResourceHistory,
  ]);

  const rows = useMemo(() => {
    if (!usage) {
      return [];
    }
    const query = search.trim().toLowerCase();
    return rowsFor(usage, mode)
      .filter((row) => {
        if (!query) {
          return true;
        }
        return [row.name, row.unit, row.command ?? ""]
          .join(" ")
          .toLowerCase()
          .includes(query);
      })
      .sort((left, right) => {
        switch (sort) {
          case "memory":
            return right.memory - left.memory;
          case "read":
            return right.read - left.read;
          case "write":
            return right.write - left.write;
          case "rx":
            return right.rx - left.rx;
          case "tx":
            return right.tx - left.tx;
          default:
            return right.cpu - left.cpu;
        }
      });
  }, [usage, mode, search, sort]);

  const maxRead = Math.max(1, ...rows.map((row) => row.read));
  const maxWrite = Math.max(1, ...rows.map((row) => row.write));
  const maxRx = Math.max(1, ...rows.map((row) => row.rx));
  const maxTx = Math.max(1, ...rows.map((row) => row.tx));
  const maxCpu = Math.max(100, ...rows.map((row) => row.cpu));

  const historyChart = useMemo(() => {
    if (!history) {
      return null;
    }
    const labels = history.totals.map((point) => point.at);
    const series: ChartSeries[] = history.series.map((item, index) => ({
      label: item.name,
      color: CHART_COLORS[index % CHART_COLORS.length],
      values: item.points.map((point) => metricValue(point, historyMetric)),
    }));
    return {
      labels,
      series,
      min: 0,
      max: historyMetric === "memory" ? usage?.memory_total : undefined,
      formatValue: (value: number) => formatMetric(historyMetric, value),
    };
  }, [history, historyMetric, usage?.memory_total]);

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}

      {!usage ? (
        <Spinner label="Sampling resource usage…" />
      ) : (
        <>
          <div className="metric-grid resource-summary">
            <MetricTile
              label="CPU"
              value={formatPercent(usage.total_cpu_percent, 1)}
              caption={`${(usage.total_cpu_percent / 100).toFixed(2)} of ${usage.cpu_count} cores`}
            />
            <MetricTile
              label="Process memory"
              value={formatBytes(usage.total_memory_bytes)}
              caption={`of ${formatBytes(usage.memory_total)}`}
              progress={
                usage.memory_total > 0
                  ? usage.total_memory_bytes / usage.memory_total
                  : 0
              }
              tone="accent"
            />
            <MetricTile
              label="Disk read"
              value={formatRate(usage.total_read_bps)}
              caption={`${usage.processes.length} processes sampled`}
            />
            <MetricTile
              label="Disk write"
              value={formatRate(usage.total_write_bps)}
              caption={`updated ${formatPreciseTimestamp(usage.at)}`}
            />
            <MetricTile
              label="Network in"
              value={formatRate(usage.total_network_rx_bps)}
              caption="TCP received"
              tone="accent"
            />
            <MetricTile
              label="Network out"
              value={formatRate(usage.total_network_tx_bps)}
              caption="TCP sent"
            />
          </div>

          <Card
            title="Usage over time"
            subtitle="Five-second samples, kept for up to one hour"
          >
            <div className="resource-history-controls">
              <div className="resource-tabs" role="group" aria-label="History entity">
                {(
                  [
                    ["services", "Services"],
                    ["apps", "Apps"],
                  ] as const
                ).map(([value, label]) => (
                  <button
                    key={value}
                    type="button"
                    className={`button tiny${historyKind === value ? " primary" : " ghost"}`}
                    onClick={() => setHistoryKind(value)}
                  >
                    {label}
                  </button>
                ))}
              </div>
              <label className="inline-field">
                Metric
                <select
                  className="select"
                  value={historyMetric}
                  onChange={(event) =>
                    setHistoryMetric(event.target.value as HistoryMetric)
                  }
                >
                  <option value="cpu">CPU</option>
                  <option value="memory">Memory</option>
                  <option value="read">Disk read</option>
                  <option value="write">Disk write</option>
                  <option value="rx">Network in</option>
                  <option value="tx">Network out</option>
                </select>
              </label>
              <label className="inline-field">
                Range
                <select
                  className="select"
                  value={historyMinutes}
                  onChange={(event) => setHistoryMinutes(Number(event.target.value))}
                >
                  <option value={5}>5 minutes</option>
                  <option value={15}>15 minutes</option>
                  <option value={30}>30 minutes</option>
                  <option value={60}>60 minutes</option>
                </select>
              </label>
            </div>

            {historyChart && historyChart.series.length > 0 ? (
              <LineChart
                series={historyChart.series}
                labels={historyChart.labels}
                min={historyChart.min}
                max={historyChart.max}
                formatValue={historyChart.formatValue}
                ariaLabel={`${historyKind} ${historyMetric} history`}
              />
            ) : (
              <p className="muted">
                Collecting history… The server samples every 5 seconds.
              </p>
            )}

            <p className="muted resource-note">
              Top {historyKind} by {historyMetric}; click a row below for that
              entity's own timeline.
            </p>
          </Card>

          <div className="toolbar-row">
            <div className="resource-tabs" role="group" aria-label="Group by">
              {(
                [
                  ["services", "Services"],
                  ["apps", "Apps"],
                  ["processes", "Processes"],
                ] as const
              ).map(([value, label]) => (
                <button
                  key={value}
                  type="button"
                  className={`button tiny${mode === value ? " primary" : " ghost"}`}
                  onClick={() => setMode(value)}
                >
                  {label}
                </button>
              ))}
            </div>
            <input
              className="search-input"
              type="search"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search by name, unit or command"
            />
            <select
              className="select"
              value={sort}
              onChange={(event) => setSort(event.target.value as SortKey)}
            >
              <option value="cpu">Sort by CPU</option>
              <option value="memory">Sort by memory</option>
              <option value="read">Sort by disk read</option>
              <option value="write">Sort by disk write</option>
              <option value="rx">Sort by network in</option>
              <option value="tx">Sort by network out</option>
            </select>
            <button
              type="button"
              className="button ghost"
              onClick={() => setRefreshTick((value) => value + 1)}
            >
              Refresh
            </button>
            <span className="toolbar-count">{rows.length} shown</span>
          </div>

          <p className="muted resource-note">
            CPU is relative to one core and can exceed 100% when a process uses
            several cores. Memory is resident memory (RSS) summed per process.
            Disk values are actual block I/O. Network values are TCP
            receive/send rates derived from per-socket counters; UDP traffic is
            not counted.
          </p>

          {rows.length === 0 ? (
            <EmptyState
              icon="▥"
              title="No matching resource consumers"
              description="Change the search, grouping or sort."
            />
          ) : (
            <div className="resource-table">
              <div className="resource-head">
                <span>Name</span>
                <span>{mode === "processes" ? "PID" : "Tasks"}</span>
                <span>CPU</span>
                <span>Memory</span>
                <span>Read/s</span>
                <span>Write/s</span>
                <span>Net in/s</span>
                <span>Net out/s</span>
              </div>
              {rows.map((row) => (
                <div
                  className="resource-row"
                  key={row.key}
                  role="button"
                  tabIndex={0}
                  onClick={() => setSelected(row)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      setSelected(row);
                    }
                  }}
                >
                  <div className="resource-name">
                    <div>
                      <strong>{row.name}</strong>
                      <StatusBadge text={row.kind} tone={kindTone(row.kind)} />
                    </div>
                    <span className="resource-subline">
                      {mode === "processes" ? row.command : row.unit}
                    </span>
                  </div>
                  <span className="resource-number">
                    {mode === "processes" ? row.pid : row.tasks}
                  </span>
                  <div className="resource-cell">
                    <span>{formatPercent(row.cpu, 1)}</span>
                    <UsageBar
                      fraction={row.cpu / maxCpu}
                      tone="accent"
                    />
                  </div>
                  <div className="resource-cell">
                    <span>{formatBytes(row.memory)}</span>
                    <UsageBar
                      fraction={
                        usage.memory_total > 0
                          ? row.memory / usage.memory_total
                          : 0
                      }
                      tone="accent"
                    />
                  </div>
                  <div className="resource-cell">
                    <span>{formatRate(row.read)}</span>
                    <UsageBar fraction={row.read / maxRead} tone="good" />
                  </div>
                  <div className="resource-cell">
                    <span>{formatRate(row.write)}</span>
                    <UsageBar fraction={row.write / maxWrite} tone="warn" />
                  </div>
                  <div className="resource-cell">
                    <span>{formatRate(row.rx)}</span>
                    <UsageBar fraction={row.rx / maxRx} tone="good" />
                  </div>
                  <div className="resource-cell">
                    <span>{formatRate(row.tx)}</span>
                    <UsageBar fraction={row.tx / maxTx} tone="accent" />
                  </div>
                </div>
              ))}
            </div>
          )}
        </>
      )}

      {selected && usage ? (
        <ResourceDetail
          row={selected}
          usage={usage}
          historyMetric={historyMetric}
          historyMinutes={historyMinutes}
          onClose={() => setSelected(null)}
        />
      ) : null}
    </div>
  );
}

function ResourceDetail({
  row,
  usage,
  historyMetric,
  historyMinutes,
  onClose,
}: {
  row: Row;
  usage: ResourceUsage;
  historyMetric: HistoryMetric;
  historyMinutes: number;
  onClose: () => void;
}) {
  const { fetchResourceHistory } = useNixOSControl();
  const historyKind: HistoryKind = row.kind === "app" ? "apps" : "services";
  const entityKey = row.kind === "app" ? row.name : row.unit;
  const [metric, setMetric] = useState<HistoryMetric>(historyMetric);
  const [entityHistory, setEntityHistory] = useState<ResourceHistory | null>(
    null,
  );

  useEffect(() => {
    setMetric(historyMetric);
  }, [historyMetric]);

  useEffect(() => {
    if (row.pid !== undefined) {
      return;
    }
    let cancelled = false;
    const load = async () => {
      const next = await fetchResourceHistory({
        kind: historyKind,
        minutes: historyMinutes,
        metric,
        top: 1,
        entities: [entityKey],
      });
      if (!cancelled) {
        setEntityHistory(next);
      }
    };
    void load();
    const interval = window.setInterval(() => {
      void load();
    }, 15_000);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [
    row.pid,
    historyKind,
    entityKey,
    historyMinutes,
    metric,
    fetchResourceHistory,
  ]);

  const entityChart = useMemo(() => {
    const series = entityHistory?.series[0];
    if (!series) {
      return null;
    }
    return {
      labels: series.points.map((point) => point.at),
      series: [
        {
          label: series.name,
          color: CHART_COLORS[0],
          values: series.points.map((point) => metricValue(point, metric)),
        },
      ],
      min: 0,
      max: metric === "memory" ? usage.memory_total : undefined,
      formatValue: (value: number) => formatMetric(metric, value),
    };
  }, [entityHistory, metric, usage.memory_total]);
  const processes: ResourceProcess[] =
    row.pid !== undefined
      ? usage.processes.filter((process) => process.pid === row.pid)
      : usage.processes
          .filter((process) =>
            row.kind === "app"
              ? process.name === row.name
              : process.unit === row.unit,
          )
          .sort((left, right) => right.cpu_percent - left.cpu_percent);

  return (
    <Modal title={row.name} onClose={onClose}>
      <div className="detail-grid">
        <InfoRow label="Kind" value={row.kind} />
        <InfoRow label="Unit" value={row.unit} mono />
        {row.pid !== undefined ? (
          <InfoRow label="PID" value={String(row.pid)} />
        ) : (
          <InfoRow label="Tasks" value={String(row.tasks)} />
        )}
        <InfoRow label="CPU" value={formatPercent(row.cpu, 1)} />
        <InfoRow label="Memory" value={formatBytes(row.memory)} />
        <InfoRow label="Disk read" value={formatRate(row.read)} />
        <InfoRow label="Disk write" value={formatRate(row.write)} />
        <InfoRow label="Network in" value={formatRate(row.rx)} />
        <InfoRow label="Network out" value={formatRate(row.tx)} />
      </div>

      {row.pid === undefined ? (
        <section className="session-section">
          <h3>History</h3>
          <div className="resource-history-controls">
            <label className="inline-field">
              Metric
              <select
                className="select"
                value={metric}
                onChange={(event) =>
                  setMetric(event.target.value as HistoryMetric)
                }
              >
                <option value="cpu">CPU</option>
                <option value="memory">Memory</option>
                <option value="read">Disk read</option>
                <option value="write">Disk write</option>
                <option value="rx">Network in</option>
                <option value="tx">Network out</option>
              </select>
            </label>
            <span className="muted">Last {historyMinutes} minutes</span>
          </div>
          {entityChart ? (
            <LineChart
              series={entityChart.series}
              labels={entityChart.labels}
              min={entityChart.min}
              max={entityChart.max}
              formatValue={entityChart.formatValue}
              ariaLabel={`${row.name} history`}
            />
          ) : (
            <p className="muted">No history samples yet.</p>
          )}
        </section>
      ) : null}

      {row.command ? (
        <section className="session-section">
          <h3>Command</h3>
          <pre className="log-output compact">{row.command}</pre>
        </section>
      ) : null}

      {processes.length > 0 ? (
        <section className="session-section">
          <h3>Processes</h3>
          <div className="history-list">
            {processes.map((process) => (
              <div className="history-row" key={process.pid}>
                <span>
                  {process.pid} · {process.name}
                </span>
                <strong>
                  {formatPercent(process.cpu_percent, 1)} ·{" "}
                  {formatBytes(process.memory_bytes)}
                </strong>
              </div>
            ))}
          </div>
        </section>
      ) : null}

      <p className="muted session-note">
        Sampled every 5 seconds. CPU is relative to one core.
      </p>
    </Modal>
  );
}