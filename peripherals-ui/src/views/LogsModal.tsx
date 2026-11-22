import { useEffect, useState } from "react";

import { Modal, Spinner } from "../components";
import { useNixOSControl } from "../store";

export default function LogsModal({
  title,
  unit,
  onClose,
}: {
  title: string;
  unit: string | null;
  onClose: () => void;
}) {
  const { fetchServiceLogs, fetchSystemLogs } = useNixOSControl();
  const [lines, setLines] = useState<string[]>([]);
  const [lineCount, setLineCount] = useState(300);
  const [autoRefresh, setAutoRefresh] = useState(false);
  const [loading, setLoading] = useState(true);
  const [refreshTick, setRefreshTick] = useState(0);

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      setLoading(true);
      const next = unit
        ? await fetchServiceLogs(unit, lineCount)
        : await fetchSystemLogs(lineCount);
      if (!cancelled) {
        setLines(next);
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

  return (
    <Modal title={title} onClose={onClose} wide>
      <div className="logs-toolbar">
        <label className="inline-field">
          Lines
          <select
            value={lineCount}
            onChange={(event) => setLineCount(Number(event.target.value))}
          >
            <option value={100}>100</option>
            <option value={300}>300</option>
            <option value={1000}>1000</option>
          </select>
        </label>
        <label className="toggle">
          <input
            type="checkbox"
            checked={autoRefresh}
            onChange={(event) => setAutoRefresh(event.target.checked)}
          />
          Auto refresh
        </label>
        <button
          type="button"
          className="button ghost"
          onClick={() => setRefreshTick((value) => value + 1)}
        >
          Refresh
        </button>
      </div>

      {loading && lines.length === 0 ? (
        <Spinner label="Loading journal…" />
      ) : lines.length === 0 ? (
        <p className="muted">No journal entries.</p>
      ) : (
        <pre className="log-output">{lines.join("\n")}</pre>
      )}
    </Modal>
  );
}