import { useCallback, useEffect, useState } from "react";

import { formatTime } from "./components";
import { NixOSControlProvider, useNixOSControl } from "./store";
import type { AppTab } from "./types";
import DashboardView from "./views/DashboardView";
import PeripheralsView from "./views/PeripheralsView";
import ServicesView from "./views/ServicesView";
import SettingsView from "./views/SettingsView";
import StorageView from "./views/StorageView";
import SystemView from "./views/SystemView";

const NAV: Array<{ id: AppTab; label: string; icon: string }> = [
  { id: "dashboard", label: "Dashboard", icon: "◈" },
  { id: "services", label: "Services", icon: "⚙" },
  { id: "storage", label: "Storage", icon: "▤" },
  { id: "system", label: "System", icon: "⌁" },
  { id: "peripherals", label: "Peripherals", icon: "⌨" },
  { id: "settings", label: "Settings", icon: "☰" },
];

export default function App() {
  return (
    <NixOSControlProvider>
      <Shell />
    </NixOSControlProvider>
  );
}

const NAV_IDS = NAV.map((item) => item.id);

// Deep links: /#peripherals opens the receiver view directly.
function tabFromHash(): AppTab | null {
  const id = window.location.hash.replace(/^#\/?/, "").split(/[?&]/)[0];
  return (NAV_IDS as string[]).includes(id) ? (id as AppTab) : null;
}

function Shell() {
  const store = useNixOSControl();
  const [tab, setTabState] = useState<AppTab>(
    () => tabFromHash() ?? (store.settings ? "dashboard" : "settings"),
  );

  const setTab = useCallback((next: AppTab) => {
    setTabState(next);
    if (window.location.hash !== `#${next}`) {
      window.history.replaceState(null, "", `#${next}`);
    }
  }, []);

  useEffect(() => {
    if (!store.settings) {
      setTab("settings");
    }
  }, [store.settings, setTab]);

  const active = NAV.find((item) => item.id === tab) ?? NAV[0];
  const connectionTone =
    store.connectionState === "online"
      ? "good"
      : store.connectionState === "connecting"
        ? "warn"
        : store.connectionState === "offline"
          ? "bad"
          : "muted";

  function refreshCurrent() {
    switch (tab) {
      case "dashboard":
        void store.refreshStatus();
        break;
      case "services":
        void store.loadServices();
        break;
      case "storage":
        void store.loadStorage();
        break;
      case "system":
        void store.refreshStatus();
        void store.loadGenerations();
        void store.loadJobs();
        break;
      case "peripherals":
        void store.loadPeripherals();
        break;
      default:
        break;
    }
  }

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <div className="brand-mark" aria-hidden="true">
            ◉
          </div>
          <div>
            <strong>NixOS Control</strong>
            <span>web console</span>
          </div>
        </div>

        <nav className="nav" aria-label="Sections">
          {NAV.map((item) => (
            <button
              type="button"
              key={item.id}
              className={`nav-item${item.id === tab ? " active" : ""}`}
              onClick={() => setTab(item.id)}
            >
              <span className="nav-icon" aria-hidden="true">
                {item.icon}
              </span>
              {item.label}
            </button>
          ))}
        </nav>

        <div className="sidebar-foot">
          <span className={`status-pill status-${connectionTone}`}>
            <span className="dot" aria-hidden="true" />
            {store.connectionState}
          </span>
          {store.serverVersion ? <small>API {store.serverVersion}</small> : null}
          {store.lastUpdated ? <small>updated {formatTime(store.lastUpdated)}</small> : null}
        </div>
      </aside>

      <main className="main">
        <header className="topbar">
          <div>
            <div className="eyebrow">NixOS Control</div>
            <h1>{active.label}</h1>
          </div>
          <div className="topbar-actions">
            <span className={`status-pill status-${connectionTone}`}>
              <span className="dot" aria-hidden="true" />
              {store.connectionState}
            </span>
            <button
              type="button"
              className="button ghost"
              onClick={refreshCurrent}
              disabled={!store.settings || tab === "settings"}
            >
              Refresh
            </button>
            <button
              type="button"
              className="button ghost"
              onClick={() => setTab("settings")}
            >
              Settings
            </button>
          </div>
        </header>

        {tab === "dashboard" ? <DashboardView onNavigate={setTab} /> : null}
        {tab === "services" ? <ServicesView /> : null}
        {tab === "storage" ? <StorageView /> : null}
        {tab === "system" ? <SystemView /> : null}
        {tab === "peripherals" ? <PeripheralsView /> : null}
        {tab === "settings" ? (
          <SettingsView onConnected={() => setTab("dashboard")} />
        ) : null}

        <footer className="footer">
          <span>Read-only receiver probe · token-protected API</span>
          <span>{store.serverVersion ? `NixOS Control ${store.serverVersion}` : "NixOS Control"}</span>
        </footer>
      </main>
    </div>
  );
}