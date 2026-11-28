import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";

import {
  EmptyState,
  ErrorBanner,
  Modal,
  Spinner,
  StatusBadge,
  formatTimestamp,
  titleCase,
} from "../components";
import { useNixOSControl } from "../store";
import type { Sandbox } from "../types";

function tone(sandbox: Sandbox): "good" | "warn" | "muted" {
  if (sandbox.status === "running") {
    return "good";
  }
  if (sandbox.status === "starting") {
    return "warn";
  }
  return "muted";
}

function networkLabel(sandbox: Sandbox): string {
  if (!sandbox.online) {
    return "offline";
  }
  return sandbox.lan ? "online + LAN" : "online";
}

function SandboxLogsModal({
  name,
  onClose,
}: {
  name: string;
  onClose: () => void;
}) {
  const { fetchSandboxLogs } = useNixOSControl();
  const [lines, setLines] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void fetchSandboxLogs(name, 400).then((response) => {
      if (cancelled) {
        return;
      }
      if (!response) {
        setError("Could not read the sandbox log.");
        return;
      }
      setLines(response.lines);
    });
    return () => {
      cancelled = true;
    };
  }, [fetchSandboxLogs, name]);

  return (
    <Modal title={`${name} · logs`} onClose={onClose} wide>
      {error ? <ErrorBanner message={error} /> : null}
      {lines === null && !error ? (
        <Spinner label="Loading sandbox log…" />
      ) : lines && lines.length > 0 ? (
        <pre className="log-output">{lines.join("\n")}</pre>
      ) : (
        <EmptyState
          icon="≣"
          title="No log output"
          description="The sandbox has not written anything yet, or its runtime log was cleared by a reboot."
        />
      )}
    </Modal>
  );
}

function CreateSandboxModal({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: (name: string) => void;
}) {
  const { createSandbox, fetchJob, sandboxList } = useNixOSControl();
  const [name, setName] = useState("");
  const [image, setImage] = useState("docker.io/library/alpine:latest");
  const [workspace, setWorkspace] = useState("");
  const [cpus, setCpus] = useState(4);
  const [memory, setMemory] = useState(4096);
  const [online, setOnline] = useState(false);
  const [lan, setLan] = useState(false);
  const [docker, setDocker] = useState(false);
  const [ports, setPorts] = useState("");
  const [command, setCommand] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const parsedPorts = useMemo(() => {
    return ports
      .split(/[,\s]+/)
      .map((value) => value.trim())
      .filter(Boolean)
      .map((value) => {
        const [host, guest] = value.split(":");
        return { host: Number(host), guest: Number(guest) };
      })
      .filter(
        (port) =>
          Number.isInteger(port.host) &&
          Number.isInteger(port.guest) &&
          port.host >= 1024 &&
          port.guest >= 1,
      );
  }, [ports]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy) {
      return;
    }
    if (!name.trim()) {
      setError("Enter a sandbox name.");
      return;
    }
    if (ports.trim() && parsedPorts.length === 0) {
      setError("Ports must be HOST:GUEST, for example 8080:80.");
      return;
    }
    setBusy(true);
    setError(null);
    const job = await createSandbox({
      name: name.trim(),
      image: image.trim(),
      workspace: workspace.trim(),
      cpus,
      memory,
      online: online || lan,
      lan,
      docker,
      ports: parsedPorts,
      command: command.trim() ? ["/bin/sh", "-c", command] : [],
    });
    setBusy(false);
    if (!job) {
      setError("The server rejected the sandbox request.");
      return;
    }
    setBusy(true);
    let current = job;
    for (let attempt = 0; attempt < 60; attempt += 1) {
      await new Promise((resolve) => window.setTimeout(resolve, 2000));
      const next = await fetchJob(job.id);
      if (next) {
        current = next;
      }
      if (current.status !== "running") {
        break;
      }
    }
    setBusy(false);
    if (current.error) {
      setError(current.error);
      return;
    }
    onCreated(name.trim());
    onClose();
  }

  return (
    <Modal title="New sandbox" onClose={onClose} wide>
      <div className="form-note">
        Workspaces are created below <code>{sandboxList?.workspace_root ?? "/var/lib/agent-workspaces"}</code>.
      </div>
      <form className="form-grid" onSubmit={submit}>
        <label>
          Name
          <input
            className="search-input"
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="agent-task"
            autoFocus
          />
        </label>
        <label>
          Image
          <input
            className="search-input"
            value={image}
            onChange={(event) => setImage(event.target.value)}
            placeholder="docker.io/library/alpine:latest"
          />
        </label>
        <label>
          Workspace
          <input
            className="search-input"
            value={workspace}
            onChange={(event) => setWorkspace(event.target.value)}
            placeholder={name || "same as the sandbox name"}
          />
        </label>
        <label>
          Command
          <input
            className="search-input"
            value={command}
            onChange={(event) => setCommand(event.target.value)}
            placeholder="optional; runs with /bin/sh -c"
          />
        </label>
        <label>
          Ports
          <input
            className="search-input"
            value={ports}
            onChange={(event) => setPorts(event.target.value)}
            placeholder="8080:80, 3000:3000"
          />
        </label>
        <label>
          CPUs
          <input
            className="search-input"
            type="number"
            min={1}
            max={8}
            value={cpus}
            onChange={(event) => setCpus(Number(event.target.value))}
          />
        </label>
        <label>
          Memory (MiB)
          <input
            className="search-input"
            type="number"
            min={256}
            max={16384}
            step={256}
            value={memory}
            onChange={(event) => setMemory(Number(event.target.value))}
          />
        </label>
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={online}
            onChange={(event) => {
              setOnline(event.target.checked);
              if (!event.target.checked) {
                setLan(false);
              }
            }}
          />
          Internet egress
        </label>
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={lan}
            disabled={!online}
            onChange={(event) => setLan(event.target.checked)}
          />
          Also allow LAN (never the host)
        </label>
        <label className="checkbox-row">
          <input
            type="checkbox"
            checked={docker}
            onChange={(event) => setDocker(event.target.checked)}
          />
          Start Docker inside the guest
        </label>
        {error ? <ErrorBanner message={error} /> : null}
        <div className="form-actions">
          <button type="button" className="button ghost" onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="button primary" disabled={busy}>
            {busy ? "Starting…" : "Create sandbox"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export default function SandboxesView() {
  const {
    sandboxes,
    sandboxList,
    loading,
    error,
    loadSandboxes,
    performSandboxAction,
  } = useNixOSControl();
  const [logsName, setLogsName] = useState<string | null>(null);
  const [createOpen, setCreateOpen] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyName, setBusyName] = useState<string | null>(null);
  const [createdName, setCreatedName] = useState<string | null>(null);

  useEffect(() => {
    if (!sandboxList) {
      void loadSandboxes();
    }
  }, [sandboxList, loadSandboxes]);

  // A create job pulls the image and boots the VM in the background.  Poll
  // the inventory until the new sandbox appears.
  useEffect(() => {
    if (!createdName) {
      return;
    }
    if (sandboxes.some((sandbox) => sandbox.name === createdName)) {
      setCreatedName(null);
      return;
    }
    const interval = window.setInterval(() => void loadSandboxes(), 2500);
    const timeout = window.setTimeout(() => setCreatedName(null), 90_000);
    return () => {
      window.clearInterval(interval);
      window.clearTimeout(timeout);
    };
  }, [createdName, sandboxes, loadSandboxes]);

  async function runAction(sandbox: Sandbox, action: string) {
    if (
      action === "remove" &&
      !window.confirm(`Remove sandbox ${sandbox.name}? Its workspace is kept.`)
    ) {
      return;
    }
    if (
      action === "stop" &&
      !window.confirm(`Stop sandbox ${sandbox.name}? Running work will be interrupted.`)
    ) {
      return;
    }
    setBusyName(sandbox.name);
    setActionError(null);
    const message = await performSandboxAction(sandbox.name, action);
    setBusyName(null);
    if (message) {
      setActionError(message);
    }
  }

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}
      {actionError ? <ErrorBanner message={actionError} /> : null}
      {createdName ? (
        <div className="banner">
          Creating <strong>{createdName}</strong>… the image pull and VM boot can take a minute.
        </div>
      ) : null}

      <div className="toolbar-row">
        <button
          type="button"
          className="button ghost"
          onClick={() => void loadSandboxes()}
          disabled={loading.sandboxes}
        >
          {loading.sandboxes ? "Refreshing…" : "Refresh"}
        </button>
        <button
          type="button"
          className="button primary"
          onClick={() => setCreateOpen(true)}
          disabled={sandboxList?.available === false}
        >
          New sandbox
        </button>
        <span className="toolbar-count">{sandboxes.length} sandboxes</span>
      </div>

      {loading.sandboxes && sandboxes.length === 0 ? (
        <Spinner label="Loading sandboxes…" />
      ) : sandboxList?.available === false ? (
        <EmptyState
          icon="▣"
          title="Sandbox API is disabled"
          description="Enable mySandbox on the host and restart nixos-control."
        />
      ) : sandboxes.length === 0 ? (
        <EmptyState
          icon="▣"
          title="No sandboxes yet"
          description="Create one here or run sudo agent-vm on the host."
        />
      ) : (
        <div className="sandbox-grid">
          {sandboxes.map((sandbox) => (
            <article className="sandbox-card" key={sandbox.name}>
              <div className="sandbox-card-head">
                <div>
                  <h2>{sandbox.name}</h2>
                  <span className="sandbox-image">{sandbox.image}</span>
                </div>
                <StatusBadge text={titleCase(sandbox.status)} tone={tone(sandbox)} />
              </div>

              <div className="sandbox-meta">
                <span>{sandbox.cpus} vCPU</span>
                <span>{sandbox.memory} MiB</span>
                <span>{networkLabel(sandbox)}</span>
                {sandbox.docker ? <span>docker</span> : null}
                {sandbox.ephemeral ? <span>ephemeral</span> : null}
              </div>

              <div className="sandbox-detail">
                <span>Workspace</span>
                <code>{sandbox.workspace}</code>
              </div>
              <div className="sandbox-detail">
                <span>Created</span>
                <code>{formatTimestamp(sandbox.created)}</code>
              </div>

              {sandbox.ports.length > 0 ? (
                <div className="sandbox-chips">
                  {sandbox.ports.map((port) => (
                    <span className="service-tag" key={`${port.address}:${port.host}:${port.guest}`}>
                      {port.address}:{port.host} → {port.guest}
                    </span>
                  ))}
                </div>
              ) : null}

              {sandbox.shares.length > 0 ? (
                <div className="sandbox-chips">
                  {sandbox.shares.map((share) => (
                    <span className="service-tag" key={share.name}>
                      {share.name}: {share.path}
                      {share.read_only ? " (ro)" : ""}
                    </span>
                  ))}
                </div>
              ) : null}

              <div className="row-actions">
                {sandbox.running ? (
                  <button
                    type="button"
                    className="button tiny danger"
                    disabled={busyName === sandbox.name}
                    onClick={() => void runAction(sandbox, "stop")}
                  >
                    Stop
                  </button>
                ) : (
                  <button
                    type="button"
                    className="button tiny primary"
                    disabled={busyName === sandbox.name || sandbox.status === "starting"}
                    onClick={() => void runAction(sandbox, "start")}
                  >
                    Start
                  </button>
                )}
                <button
                  type="button"
                  className="button tiny ghost"
                  onClick={() => setLogsName(sandbox.name)}
                >
                  Logs
                </button>
                <button
                  type="button"
                  className="button tiny ghost"
                  disabled={busyName === sandbox.name}
                  onClick={() => void runAction(sandbox, "remove")}
                >
                  Remove
                </button>
              </div>
            </article>
          ))}
        </div>
      )}

      {logsName ? (
        <SandboxLogsModal name={logsName} onClose={() => setLogsName(null)} />
      ) : null}
      {createOpen ? (
        <CreateSandboxModal
          onClose={() => setCreateOpen(false)}
          onCreated={(name) => {
            setCreatedName(name);
            void loadSandboxes();
          }}
        />
      ) : null}
    </div>
  );
}
