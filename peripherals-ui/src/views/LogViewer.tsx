import { useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";

import {
  EmptyState,
  Spinner,
  formatPreciseTimestamp,
  type Tone,
} from "../components";
import { useNixOSControl } from "../store";
import type { LogEntry, LogsResponse } from "../types";

type LevelFilter = "all" | "errors" | "warnings" | "info" | "debug";

interface LogGroup {
  key: string;
  entry: LogEntry;
  count: number;
}

const FILTERS: Array<{ id: LevelFilter; label: string }> = [
  { id: "all", label: "All" },
  { id: "errors", label: "Errors" },
  { id: "warnings", label: "Warnings" },
  { id: "info", label: "Info" },
  { id: "debug", label: "Debug" },
];

function category(entry: LogEntry): Exclude<LevelFilter, "all"> {
  if (entry.priority <= 3) {
    return "errors";
  }
  if (entry.priority === 4) {
    return "warnings";
  }
  if (entry.priority === 7) {
    return "debug";
  }
  return "info";
}

function levelLabel(entry: LogEntry): string {
  switch (entry.priority) {
    case 0:
      return "EMERG";
    case 1:
      return "ALERT";
    case 2:
      return "CRIT";
    case 3:
      return "ERR";
    case 4:
      return "WARN";
    case 5:
      return "NOTICE";
    case 6:
      return "INFO";
    default:
      return "DEBUG";
  }
}

function levelTone(entry: LogEntry): Tone {
  if (entry.priority <= 3) {
    return "bad";
  }
  if (entry.priority === 4) {
    return "warn";
  }
  if (entry.priority === 6) {
    return "accent";
  }
  return "muted";
}

function shortTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value || "—";
  }
  const today = new Date();
  const sameDay =
    date.getFullYear() === today.getFullYear() &&
    date.getMonth() === today.getMonth() &&
    date.getDate() === today.getDate();
  return sameDay
    ? date.toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      })
    : date.toLocaleString([], {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
}

function sameLog(left: LogEntry, right: LogEntry): boolean {
  return (
    left.priority === right.priority &&
    left.message === right.message &&
    left.identifier === right.identifier &&
    left.unit === right.unit
  );
}

function Highlight({
  text,
  query,
}: {
  text: string;
  query: string;
}): ReactNode {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    return text;
  }
  const lower = text.toLowerCase();
  const parts: ReactNode[] = [];
  let cursor = 0;
  let index = lower.indexOf(needle);
  while (index !== -1) {
    if (index > cursor) {
      parts.push(text.slice(cursor, index));
    }
    parts.push(<mark key={`${index}-${cursor}`}>{text.slice(index, index + needle.length)}</mark>);
    cursor = index + needle.length;
    index = lower.indexOf(needle, cursor);
  }
  if (cursor < text.length) {
    parts.push(text.slice(cursor));
  }
  return parts.length > 0 ? parts : text;
}

export default function LogViewer({
  unit,
  compact = false,
}: {
  unit: string | null;
  compact?: boolean;
}) {
  const { fetchServiceLogs, fetchSystemLogs } = useNixOSControl();
  const [response, setResponse] = useState<LogsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [level, setLevel] = useState<LevelFilter>("all");
  const [search, setSearch] = useState("");
  const [lineCount, setLineCount] = useState(300);
  const [autoRefresh, setAutoRefresh] = useState(false);
  const [follow, setFollow] = useState(true);
  const [collapse, setCollapse] = useState(true);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [refreshTick, setRefreshTick] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      const next = unit
        ? await fetchServiceLogs(unit, lineCount)
        : await fetchSystemLogs(lineCount);
      if (!cancelled) {
        setResponse(next);
        setLoading(false);
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
    }, 3_000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [unit, lineCount, autoRefresh, refreshTick, fetchServiceLogs, fetchSystemLogs]);

  const entries = response?.entries ?? [];
  const counts = useMemo(() => {
    const result: Record<LevelFilter, number> = {
      all: entries.length,
      errors: 0,
      warnings: 0,
      info: 0,
      debug: 0,
    };
    for (const entry of entries) {
      result[category(entry)] += 1;
    }
    return result;
  }, [entries]);

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return entries.filter((entry) => {
      if (level !== "all" && category(entry) !== level) {
        return false;
      }
      if (!query) {
        return true;
      }
      return [entry.message, entry.identifier ?? "", entry.unit ?? ""]
        .join(" ")
        .toLowerCase()
        .includes(query);
    });
  }, [entries, level, search]);

  const groups = useMemo(() => {
    if (!collapse) {
      return filtered.map((entry, index) => ({
        key: `${entry.timestamp}-${index}`,
        entry,
        count: 1,
      }));
    }
    const result: LogGroup[] = [];
    for (const entry of filtered) {
      const last = result[result.length - 1];
      if (last && sameLog(last.entry, entry)) {
        last.count += 1;
      } else {
        result.push({
          key: `${entry.timestamp}-${result.length}`,
          entry,
          count: 1,
        });
      }
    }
    return result;
  }, [filtered, collapse]);

  useEffect(() => {
    if (follow && listRef.current) {
      listRef.current.scrollTop = listRef.current.scrollHeight;
    }
  }, [groups.length, follow]);

  function toggleExpanded(key: string) {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  }

  return (
    <div className={`log-viewer${compact ? " compact" : ""}`}>
      <div className="log-toolbar">
        <input
          className="search-input"
          type="search"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search messages, units or identifiers"
        />
        <label className="inline-field">
          Lines
          <select
            className="select"
            value={lineCount}
            onChange={(event) => setLineCount(Number(event.target.value))}
          >
            <option value={100}>100</option>
            <option value={300}>300</option>
            <option value={1000}>1000</option>
            <option value={2000}>2000</option>
          </select>
        </label>
        <button
          type="button"
          className="button ghost"
          onClick={() => setRefreshTick((value) => value + 1)}
        >
          Refresh
        </button>
      </div>

      <div className="log-filters">
        {FILTERS.map((filter) => (
          <button
            key={filter.id}
            type="button"
            className={`log-chip${level === filter.id ? " active" : ""}`}
            onClick={() => setLevel(filter.id)}
          >
            {filter.label}
            <span>{counts[filter.id]}</span>
          </button>
        ))}
        <span className="log-filter-spacer" />
        <label className="toggle">
          <input
            type="checkbox"
            checked={autoRefresh}
            onChange={(event) => setAutoRefresh(event.target.checked)}
          />
          Auto
        </label>
        <label className="toggle">
          <input
            type="checkbox"
            checked={follow}
            onChange={(event) => setFollow(event.target.checked)}
          />
          Follow
        </label>
        <label className="toggle">
          <input
            type="checkbox"
            checked={collapse}
            onChange={(event) => setCollapse(event.target.checked)}
          />
          Collapse
        </label>
      </div>

      {loading && !response ? (
        <Spinner label="Reading journal…" />
      ) : !response ? (
        <p className="muted">
          Could not load the journal. Check the server connection.
        </p>
      ) : entries.length === 0 && response.lines.length > 0 ? (
        <pre className="log-output">{response.lines.join("\n")}</pre>
      ) : groups.length === 0 ? (
        <EmptyState
          icon="≣"
          title={entries.length === 0 ? "No journal entries" : "No matching entries"}
          description={
            entries.length === 0
              ? "The selected journal is empty."
              : "Change the level filter or search."
          }
        />
      ) : (
        <div
          className="log-list"
          ref={listRef}
          onScroll={() => {
            const element = listRef.current;
            if (!element) {
              return;
            }
            const nearBottom =
              element.scrollHeight - element.scrollTop - element.clientHeight <
              40;
            if (nearBottom !== follow) {
              setFollow(nearBottom);
            }
          }}
        >
          {groups.map((group) => {
            const entry = group.entry;
            const isExpanded = expanded.has(group.key);
            return (
              <div
                className={`log-row log-${category(entry)}${
                  isExpanded ? " expanded" : ""
                }`}
                key={group.key}
                role="button"
                tabIndex={0}
                onClick={() => toggleExpanded(group.key)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    toggleExpanded(group.key);
                  }
                }}
              >
                <time className="log-time" title={formatPreciseTimestamp(entry.timestamp)}>
                  {shortTime(entry.timestamp)}
                </time>
                <span className={`log-level level-${levelTone(entry)}`}>
                  {levelLabel(entry)}
                </span>
                <div className="log-main">
                  <div className="log-headline">
                    <span className="log-source">
                      {entry.identifier ?? entry.unit ?? "journal"}
                      {entry.pid ? `[${entry.pid}]` : ""}
                    </span>
                    <span className="log-message">
                      <Highlight text={entry.message} query={search} />
                    </span>
                    {group.count > 1 ? (
                      <span className="log-repeat">×{group.count}</span>
                    ) : null}
                  </div>
                  {isExpanded ? (
                    <div className="log-meta">
                      <span>
                        Time
                        <strong>{formatPreciseTimestamp(entry.timestamp)}</strong>
                      </span>
                      {entry.unit ? (
                        <span>
                          Unit<strong>{entry.unit}</strong>
                        </span>
                      ) : null}
                      {entry.hostname ? (
                        <span>
                          Host<strong>{entry.hostname}</strong>
                        </span>
                      ) : null}
                      {entry.transport ? (
                        <span>
                          Transport<strong>{entry.transport}</strong>
                        </span>
                      ) : null}
                      {entry.comm ? (
                        <span>
                          Command<strong>{entry.comm}</strong>
                        </span>
                      ) : null}
                      {entry.exe ? (
                        <span>
                          Executable<strong>{entry.exe}</strong>
                        </span>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}