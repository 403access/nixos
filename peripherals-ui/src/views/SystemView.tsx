import { useEffect, useMemo, useState } from "react";

import {
  Card,
  EmptyState,
  ErrorBanner,
  InfoRow,
  Spinner,
  StatusBadge,
  formatTimestamp,
  formatUptime,
  jobTone,
} from "../components";
import { useNixOSControl } from "../store";
import type { GenerationDiff } from "../types";
import LogsModal from "./LogsModal";

const REBUILD_ACTIONS = [
  { value: "switch", label: "Switch" },
  { value: "boot", label: "Boot" },
  { value: "test", label: "Test" },
  { value: "dry-activate", label: "Dry activate" },
  { value: "dry-build", label: "Dry build" },
] as const;

export default function SystemView() {
  const {
    status,
    generations,
    activeJob,
    loading,
    error,
    refreshStatus,
    loadGenerations,
    loadJobs,
    startRebuild,
    cancelActiveJob,
    requestPower,
    fetchJob,
    fetchGenerationDiff,
    setActiveJob,
  } = useNixOSControl();
  const [rebuildAction, setRebuildAction] = useState<string>("switch");
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showLogs, setShowLogs] = useState(false);
  const [diffFrom, setDiffFrom] = useState<number | null>(null);
  const [diffTo, setDiffTo] = useState<number | null>(null);
  const [generationDiff, setGenerationDiff] = useState<GenerationDiff | null>(null);
  const [diffLoading, setDiffLoading] = useState(false);
  const [diffError, setDiffError] = useState<string | null>(null);

  const sortedGenerations = useMemo(
    () => [...generations].sort((left, right) => left.number - right.number),
    [generations],
  );

  useEffect(() => {
    if (sortedGenerations.length < 2) {
      setDiffFrom(null);
      setDiffTo(null);
      return;
    }
    const numbers = sortedGenerations.map((generation) => generation.number);
    setDiffTo((current) =>
      current !== null && numbers.includes(current)
        ? current
        : sortedGenerations[sortedGenerations.length - 1].number,
    );
    setDiffFrom((current) =>
      current !== null && numbers.includes(current)
        ? current
        : sortedGenerations[sortedGenerations.length - 2].number,
    );
  }, [sortedGenerations]);

  async function runGenerationDiff() {
    if (diffFrom === null || diffTo === null) {
      return;
    }
    setDiffLoading(true);
    setDiffError(null);
    const result = await fetchGenerationDiff(diffFrom, diffTo);
    setGenerationDiff(result);
    if (!result) {
      setDiffError("Could not compare these generations.");
    }
    setDiffLoading(false);
  }

  useEffect(() => {
    void loadGenerations();
    void loadJobs();
  }, [loadGenerations, loadJobs]);

  useEffect(() => {
    if (!activeJob || activeJob.status !== "running") {
      return;
    }
    const id = activeJob.id;
    const interval = window.setInterval(() => {
      void fetchJob(id).then((job) => {
        if (job) {
          setActiveJob(job);
        }
      });
    }, 1_500);
    return () => window.clearInterval(interval);
  }, [activeJob?.id, activeJob?.status, fetchJob, setActiveJob]);

  useEffect(() => {
    if (activeJob && activeJob.status !== "running") {
      void refreshStatus();
      void loadGenerations();
    }
  }, [activeJob?.status, refreshStatus, loadGenerations]);

  if (!status && loading.status) {
    return <Spinner label="Loading machine information…" />;
  }

  if (!status) {
    return (
      <>
        {error ? <ErrorBanner message={error} /> : null}
        <EmptyState
          icon="⌁"
          title="Server offline"
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

  const description = rebuildDescription(rebuildAction);

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}
      {actionError ? <ErrorBanner message={actionError} /> : null}
      {notice ? <div className="banner">{notice}</div> : null}

      <Card title="Machine" subtitle="NixOS and hardware">
        <InfoRow label="NixOS" value={status.nixos_version || "Unknown"} />
        <InfoRow label="Kernel" value={status.kernel} />
        <InfoRow label="Generation" value={String(status.generation)} />
        <InfoRow label="Uptime" value={formatUptime(status.uptime_seconds)} />
        {status.tailscale ? (
          <InfoRow
            label="Tailscale"
            value={status.tailscale.connected ? status.tailscale.dns_name || "Connected" : status.tailscale.state}
          />
        ) : null}
      </Card>

      {status.capabilities.rebuild ? (
        <Card title="Rebuild" subtitle="nixos-rebuild on the host">
          <div className="rebuild-controls">
            <label className="inline-field">
              Action
              <select
                className="select"
                value={rebuildAction}
                onChange={(event) => setRebuildAction(event.target.value)}
              >
                {REBUILD_ACTIONS.map((action) => (
                  <option value={action.value} key={action.value}>
                    {action.label}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className="button primary"
              disabled={activeJob?.status === "running"}
              onClick={() => {
                if (!window.confirm(`Run nixos-rebuild ${rebuildAction}?`)) {
                  return;
                }
                setActionError(null);
                setNotice(null);
                void startRebuild(rebuildAction).then((message) => {
                  if (message) {
                    setActionError(message);
                  }
                });
              }}
            >
              Start rebuild
            </button>
          </div>
          <p className="muted">{description}</p>

          {activeJob ? (
            <div className="job">
              <div className="job-head">
                <StatusBadge text={activeJob.status} tone={jobTone(activeJob.status)} />
                <span className="mono">{activeJob.kind}</span>
                <span className="muted">{formatTimestamp(activeJob.started_at)}</span>
              </div>
              {activeJob.output ? (
                <pre className="log-output compact">{activeJob.output}</pre>
              ) : activeJob.status === "running" ? (
                <Spinner label="Rebuild running…" />
              ) : null}
              {activeJob.error ? <p className="tone-bad">{activeJob.error}</p> : null}
              {activeJob.status === "running" ? (
                <button
                  type="button"
                  className="button danger"
                  onClick={() => void cancelActiveJob()}
                >
                  Cancel rebuild
                </button>
              ) : null}
            </div>
          ) : null}
        </Card>
      ) : null}

      {status.capabilities.power ? (
        <Card title="Power" subtitle="The server goes offline immediately">
          <div className="form-actions">
            <button
              type="button"
              className="button ghost"
              onClick={() => {
                if (!window.confirm("Reboot the machine?")) {
                  return;
                }
                setActionError(null);
                void requestPower("reboot").then((message) => {
                  if (message) {
                    setActionError(message);
                  } else {
                    setNotice("Reboot requested. The server will go offline.");
                  }
                });
              }}
            >
              Reboot
            </button>
            <button
              type="button"
              className="button danger"
              onClick={() => {
                if (!window.confirm("Shut down the machine?")) {
                  return;
                }
                setActionError(null);
                void requestPower("shutdown").then((message) => {
                  if (message) {
                    setActionError(message);
                  } else {
                    setNotice("Shutdown requested. The server will go offline.");
                  }
                });
              }}
            >
              Shut down
            </button>
          </div>
        </Card>
      ) : null}

      <Card
        title="Generations"
        subtitle="Most recent NixOS generations"
        action={
          <button type="button" className="button ghost" onClick={() => void loadGenerations()}>
            Refresh
          </button>
        }
      >
        {sortedGenerations.length >= 2 ? (
          <div className="generation-compare">
            <label className="inline-field">
              From
              <select
                className="select"
                value={diffFrom ?? ""}
                onChange={(event) => setDiffFrom(Number(event.target.value))}
              >
                {sortedGenerations.map((generation) => (
                  <option value={generation.number} key={generation.number}>
                    Generation {generation.number} — {generation.date}
                  </option>
                ))}
              </select>
            </label>
            <span className="muted" aria-hidden="true">
              →
            </span>
            <label className="inline-field">
              To
              <select
                className="select"
                value={diffTo ?? ""}
                onChange={(event) => setDiffTo(Number(event.target.value))}
              >
                {sortedGenerations.map((generation) => (
                  <option value={generation.number} key={generation.number}>
                    Generation {generation.number} — {generation.date}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className="button primary"
              onClick={() => void runGenerationDiff()}
              disabled={
                diffLoading || diffFrom === null || diffTo === null
              }
            >
              {diffLoading ? "Comparing…" : "Compare"}
            </button>
            {diffError ? <span className="tone-bad">{diffError}</span> : null}
          </div>
        ) : generations.length === 1 ? (
          <p className="muted">
            Create another generation to compare configurations.
          </p>
        ) : null}

        {loading.generations && generations.length === 0 ? (
          <Spinner label="Loading generations…" />
        ) : generations.length === 0 ? (
          <p className="muted">No generations reported.</p>
        ) : (
          <div className="list">
            {[...generations]
              .sort((left, right) => right.number - left.number)
              .slice(0, 20)
              .map((generation) => (
                <div className="data-row" key={generation.number}>
                  <div className="data-main">
                    <strong>Generation {generation.number}</strong>
                    <span>{generation.date}</span>
                  </div>
                  {generation.current ? <StatusBadge text="current" tone="good" /> : null}
                </div>
              ))}
          </div>
        )}

        {generationDiff ? <GenerationDiffPanel diff={generationDiff} /> : null}
      </Card>

      <Card
        title="Journal"
        subtitle="System journal"
        action={
          <button type="button" className="button ghost" onClick={() => setShowLogs(true)}>
            Open logs
          </button>
        }
      >
        <p className="muted">Read the host journal with line count and auto-refresh.</p>
      </Card>

      {showLogs ? (
        <LogsModal title="System journal" unit={null} onClose={() => setShowLogs(false)} />
      ) : null}
    </div>
  );
}

function GenerationDiffPanel({ diff }: { diff: GenerationDiff }) {
  const noChanges = diff.entries.length === 0 && diff.lines.length === 0;

  return (
    <section className="generation-diff">
      <div className="generation-diff-head">
        <strong>
          Generation {diff.from} → {diff.to}
        </strong>
        <span className="muted">
          {diff.added} added · {diff.removed} removed · {diff.changed} changed
        </span>
      </div>

      {noChanges ? (
        <p className="muted">No package changes between these generations.</p>
      ) : diff.entries.length > 0 ? (
        <div className="diff-list">
          {diff.entries.map((entry, index) => (
            <div
              className={`diff-entry diff-${entry.change}`}
              key={`${entry.name}-${index}`}
              title={entry.line}
            >
              <span className="diff-mark" aria-hidden="true">
                {entry.change === "added"
                  ? "+"
                  : entry.change === "removed"
                    ? "−"
                    : "~"}
              </span>
              <div className="diff-main">
                <strong>{entry.name}</strong>
                {entry.before || entry.after ? (
                  <span className="diff-versions">
                    {entry.before ?? "∅"} → {entry.after ?? "∅"}
                  </span>
                ) : null}
              </div>
              {entry.size ? <span className="diff-size">{entry.size}</span> : null}
            </div>
          ))}
        </div>
      ) : (
        <pre className="log-output compact">{diff.lines.join("\n")}</pre>
      )}

      {diff.truncated ? <p className="muted">Output truncated.</p> : null}
      {diff.entries.length > 0 && diff.lines.length > 0 ? (
        <details className="diff-raw">
          <summary>Raw output</summary>
          <pre className="log-output compact">{diff.lines.join("\n")}</pre>
        </details>
      ) : null}
    </section>
  );
}

function rebuildDescription(action: string): string {
  switch (action) {
    case "boot":
      return "Build the configuration and set it as the default for the next boot. The running system is not changed.";
    case "test":
      return "Build and activate the configuration for this boot only. It is not made the default.";
    case "dry-activate":
      return "Show what would change without activating it.";
    case "dry-build":
      return "Build the configuration without activating it.";
    default:
      return "Build and activate the configuration immediately, and make it the default for the next boot.";
  }
}