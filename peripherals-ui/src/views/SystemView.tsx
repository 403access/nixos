import { useEffect, useState } from "react";

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
    setActiveJob,
  } = useNixOSControl();
  const [rebuildAction, setRebuildAction] = useState<string>("switch");
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showLogs, setShowLogs] = useState(false);

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