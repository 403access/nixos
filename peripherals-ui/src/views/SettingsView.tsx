import { useEffect, useState } from "react";
import type { FormEvent } from "react";

import { Card, InfoRow, StatusBadge } from "../components";
import { useNixOSControl } from "../store";

export default function SettingsView({
  onConnected,
}: {
  onConnected: () => void;
}) {
  const {
    settings,
    saveSettings,
    clearSettings,
    connectionState,
    serverVersion,
    status,
  } = useNixOSControl();
  const [serverUrl, setServerUrl] = useState(
    settings?.serverUrl ?? import.meta.env.VITE_API_BASE ?? "",
  );
  const [token, setToken] = useState(settings?.token ?? "");
  const [showToken, setShowToken] = useState(false);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(
    null,
  );

  useEffect(() => {
    if (settings) {
      setServerUrl(settings.serverUrl);
      setToken(settings.token);
    }
  }, [settings]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setMessage(null);
    const error = await saveSettings({
      serverUrl: serverUrl.trim(),
      token: token.trim(),
    });
    setSaving(false);
    if (error) {
      setMessage({ tone: "bad", text: error });
      return;
    }
    setMessage({ tone: "good", text: "Connected." });
    onConnected();
  }

  return (
    <div className="view-stack settings-view">
      {!settings ? (
        <div className="setup-hero">
          <div className="setup-mark" aria-hidden="true">
            ◉
          </div>
          <h1>NixOS Control</h1>
          <p>
            Monitor and manage your NixOS machine, its services, storage, rebuilds
            and Logitech receiver.
          </p>
        </div>
      ) : null}

      <div className="two-column">
        <Card
          title={settings ? "Connection" : "Connect to the NixOS API"}
          subtitle="Server URL and bearer token"
          action={
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
          }
        >
          <form className="settings-form" onSubmit={submit}>
            <label>
              Server URL
              <input
                value={serverUrl}
                onChange={(event) => setServerUrl(event.target.value)}
                placeholder="http://192.168.178.5:3050 or leave blank"
                autoComplete="url"
                spellCheck={false}
              />
            </label>
            <p className="field-hint">
              Leave blank when the dashboard is served by the NixOS Bun proxy. Use{" "}
              <code>http://192.168.178.5:3050</code> from the iOS app on the LAN.
            </p>

            <label>
              API token
              <span className="token-row">
                <input
                  type={showToken ? "text" : "password"}
                  value={token}
                  onChange={(event) => setToken(event.target.value)}
                  placeholder="nixos-control-token"
                  autoComplete="off"
                  spellCheck={false}
                />
                <button
                  type="button"
                  className="button ghost"
                  onClick={() => setShowToken((value) => !value)}
                >
                  {showToken ? "Hide" : "Show"}
                </button>
              </span>
            </label>

            {message ? (
              <div className={`form-message ${message.tone}`}>{message.text}</div>
            ) : null}

            <div className="form-actions">
              <button
                type="submit"
                className="button primary"
                disabled={saving || token.trim().length === 0}
              >
                {saving ? "Testing…" : "Test & save"}
              </button>
              {settings ? (
                <button
                  type="button"
                  className="button danger"
                  onClick={() => {
                    clearSettings();
                    setServerUrl("");
                    setToken("");
                    setMessage(null);
                  }}
                >
                  Disconnect
                </button>
              ) : null}
            </div>
          </form>

          <div className="hint">
            Run <code>sudo nixos-control-token</code> on the host to print the token.
            The web dashboard stores it in this browser&apos;s localStorage.
          </div>
        </Card>

        <Card title="Server" subtitle="Current connection">
          <InfoRow label="Status" value={connectionState} />
          {status ? <InfoRow label="Hostname" value={status.hostname} /> : null}
          {serverVersion ? <InfoRow label="API version" value={serverVersion} /> : null}
          {settings ? (
            <InfoRow label="Saved URL" value={settings.serverUrl || "same-origin proxy"} />
          ) : null}
          <InfoRow
            label="Peripherals"
            value="Read-only Logitech receiver, paired devices, battery and firmware"
          />
        </Card>
      </div>

      <Card title="Local macOS receiver" subtitle="Run the API on this Mac">
        <p className="muted">
          To inspect a receiver plugged into this Mac, run the Rust server locally
          and set the server URL to <code>http://127.0.0.1:8787</code>. The token
          comes from the local token file created by the helper script.
        </p>
        <pre className="code-block">cd server
cargo run -- --listen 127.0.0.1:8787 --token-file /tmp/nixos-control-token --allow-rebuild=false --allow-power=false

cd peripherals-ui
API_TARGET=http://127.0.0.1:8787 bun run dev</pre>
        <p className="muted">
          On macOS the receiver vendor collection may require Input Monitoring
          permission for the terminal. The rest of the system tabs will be mostly
          empty because the Linux probes are unavailable.
        </p>
      </Card>
    </div>
  );
}