import { useEffect, useMemo, useState } from "react";

import {
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
import type { ResourceEntry, ResourceProcess, ResourceUsage } from "../types";

type Mode = "services" | "apps" | "processes";
type SortKey = "cpu" | "memory" | "read" | "write";

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
  }));
}

export default function ResourcesView() {
  const { fetchResources, error } = useNixOSControl();
  const [usage, setUsage] = useState<ResourceUsage | null>(null);
  const [mode, setMode] = useState<Mode>("services");
  const [sort, setSort] = useState<SortKey>("cpu");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [refreshTick, setRefreshTick] = useState(0);

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
          default:
            return right.cpu - left.cpu;
        }
      });
  }, [usage, mode, search, sort]);

  const maxRead = Math.max(1, ...rows.map((row) => row.read));
  const maxWrite = Math.max(1, ...rows.map((row) => row.write));
  const maxCpu = Math.max(100, ...rows.map((row) => row.cpu));

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
          </div>

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
            Disk values are actual block I/O.
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
          onClose={() => setSelected(null)}
        />
      ) : null}
    </div>
  );
}

function ResourceDetail({
  row,
  usage,
  onClose,
}: {
  row: Row;
  usage: ResourceUsage;
  onClose: () => void;
}) {
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
      </div>

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