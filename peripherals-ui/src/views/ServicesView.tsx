import { useEffect, useMemo, useState } from "react";

import {
  EmptyState,
  ErrorBanner,
  InfoRow,
  Modal,
  Spinner,
  StatusBadge,
  serviceTone,
  shortUnit,
} from "../components";
import { useNixOSControl } from "../store";
import type { ServiceUnit } from "../types";
import LogsModal from "./LogsModal";

type Filter = "all" | "running" | "failed";

export default function ServicesView() {
  const {
    services,
    loading,
    error,
    loadServices,
    performServiceAction,
  } = useNixOSControl();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [selected, setSelected] = useState<ServiceUnit | null>(null);
  const [logsUnit, setLogsUnit] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  useEffect(() => {
    if (services.length === 0) {
      void loadServices();
    }
  }, [services.length, loadServices]);

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return services
      .filter((service) => {
        if (filter === "running" && service.active !== "active") {
          return false;
        }
        if (filter === "failed" && service.active !== "failed" && service.sub !== "failed") {
          return false;
        }
        if (!query) {
          return true;
        }
        return (
          service.unit.toLowerCase().includes(query) ||
          service.description.toLowerCase().includes(query)
        );
      })
      .sort((left, right) => {
        const leftFailed = left.active === "failed" || left.sub === "failed";
        const rightFailed = right.active === "failed" || right.sub === "failed";
        if (leftFailed !== rightFailed) {
          return leftFailed ? -1 : 1;
        }
        return left.unit.localeCompare(right.unit);
      });
  }, [services, search, filter]);

  async function runAction(service: ServiceUnit, action: string) {
    if (action === "stop" && !window.confirm(`Stop ${service.unit}? This may interrupt running work.`)) {
      return;
    }
    const message = await performServiceAction(service.unit, action);
    if (message) {
      setActionError(message);
    }
  }

  const selectedService = selected
    ? services.find((service) => service.unit === selected.unit) ?? selected
    : null;

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}
      {actionError ? <ErrorBanner message={actionError} /> : null}

      <div className="toolbar-row">
        <input
          className="search-input"
          type="search"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search services"
        />
        <select
          className="select"
          value={filter}
          onChange={(event) => setFilter(event.target.value as Filter)}
        >
          <option value="all">All services</option>
          <option value="running">Running</option>
          <option value="failed">Failed</option>
        </select>
        <button
          type="button"
          className="button ghost"
          onClick={() => void loadServices()}
          disabled={loading.services}
        >
          {loading.services ? "Refreshing…" : "Refresh"}
        </button>
        <span className="toolbar-count">{filtered.length} shown</span>
      </div>

      {loading.services && services.length === 0 ? (
        <Spinner label="Loading services…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon="⚙"
          title={services.length === 0 ? "No services loaded" : "No matching services"}
          description={services.length === 0 ? "Check the connection or refresh." : "Change the search or filter."}
        />
      ) : (
        <div className="list service-list">
          {filtered.map((service) => {
            const tone = serviceTone(service.active, service.sub);
            return (
              <div
                className="service-row"
                key={service.unit}
                role="button"
                tabIndex={0}
                onClick={() => setSelected(service)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    setSelected(service);
                  }
                }}
              >
                <span className={`status-dot ${tone}`} aria-hidden="true" />
                <div className="service-main">
                  <strong>{shortUnit(service.unit)}</strong>
                  {service.description ? <span>{service.description}</span> : null}
                </div>
                <StatusBadge text={service.sub || service.active} tone={tone} />
                <div className="row-actions">
                  {service.active === "active" ? (
                    <>
                      <button
                        type="button"
                        className="button tiny"
                        onClick={(event) => {
                          event.stopPropagation();
                          void runAction(service, "restart");
                        }}
                      >
                        Restart
                      </button>
                      <button
                        type="button"
                        className="button tiny danger"
                        onClick={(event) => {
                          event.stopPropagation();
                          void runAction(service, "stop");
                        }}
                      >
                        Stop
                      </button>
                    </>
                  ) : (
                    <button
                      type="button"
                      className="button tiny primary"
                      onClick={(event) => {
                        event.stopPropagation();
                        void runAction(service, "start");
                      }}
                    >
                      Start
                    </button>
                  )}
                  <button
                    type="button"
                    className="button tiny ghost"
                    onClick={(event) => {
                      event.stopPropagation();
                      setLogsUnit(service.unit);
                    }}
                  >
                    Logs
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {selectedService ? (
        <Modal title={shortUnit(selectedService.unit)} onClose={() => setSelected(null)} wide>
          <div className="detail-grid">
            <InfoRow label="Unit" value={selectedService.unit} mono />
            <InfoRow label="Load" value={selectedService.load} />
            <InfoRow label="Active" value={selectedService.active} />
            <InfoRow label="Sub" value={selectedService.sub} />
            <InfoRow label="Description" value={selectedService.description || "—"} />
          </div>

          <div className="form-actions">
            <button
              type="button"
              className="button primary"
              onClick={() => void runAction(selectedService, "restart")}
            >
              Restart
            </button>
            <button
              type="button"
              className="button danger"
              onClick={() => void runAction(selectedService, "stop")}
            >
              Stop
            </button>
            <button
              type="button"
              className="button ghost"
              onClick={() => void runAction(selectedService, "reload")}
            >
              Reload
            </button>
            <button
              type="button"
              className="button ghost"
              onClick={() => void runAction(selectedService, selectedService.active === "active" ? "disable" : "enable")}
            >
              {selectedService.active === "active" ? "Disable at boot" : "Enable at boot"}
            </button>
            <button
              type="button"
              className="button ghost"
              onClick={() => setLogsUnit(selectedService.unit)}
            >
              Open logs
            </button>
          </div>
        </Modal>
      ) : null}

      {logsUnit ? (
        <LogsModal
          title={`${shortUnit(logsUnit)} journal`}
          unit={logsUnit}
          onClose={() => setLogsUnit(null)}
        />
      ) : null}
    </div>
  );
}