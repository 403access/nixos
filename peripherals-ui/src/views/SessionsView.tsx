import { useEffect, useMemo, useRef, useState } from "react";

import {
  EmptyState,
  ErrorBanner,
  InfoRow,
  Modal,
  Spinner,
  StatusBadge,
  formatTimestamp,
  type Tone,
} from "../components";
import { useNixOSControl } from "../store";
import type { SessionDetail, SessionSummary } from "../types";

type Filter = "all" | "app" | "login";

function statusTone(status: string): Tone {
  switch (status) {
    case "ok":
      return "good";
    case "failed":
      return "bad";
    case "denied":
    case "mixed":
      return "warn";
    default:
      return "muted";
  }
}

function sourceLabel(source: string): string {
  switch (source) {
    case "web":
      return "Web console";
    case "ios":
      return "iOS app";
    case "api":
      return "API client";
    case "ssh":
      return "SSH login";
    case "rdp":
      return "RDP login";
    case "console":
      return "Console login";
    default:
      return source;
  }
}

function sourceIcon(source: string): string {
  switch (source) {
    case "web":
      return "◫";
    case "ios":
      return "▯";
    case "ssh":
      return "⌘";
    case "rdp":
      return "▣";
    case "console":
      return "▤";
    default:
      return "◷";
  }
}

export default function SessionsView() {
  const { sessions, loading, error, loadSessions, fetchSession } = useNixOSControl();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const request = useRef(0);

  useEffect(() => {
    void loadSessions();
    const interval = window.setInterval(() => {
      void loadSessions();
    }, 20_000);
    return () => window.clearInterval(interval);
  }, [loadSessions]);

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return sessions
      .filter((session) => {
        if (filter !== "all" && session.kind !== filter) {
          return false;
        }
        if (!query) {
          return true;
        }
        return [
          session.title,
          session.summary,
          session.user ?? "",
          session.remote_host ?? "",
          session.source,
        ]
          .join(" ")
          .toLowerCase()
          .includes(query);
      })
      .sort((left, right) =>
        right.last_active_at.localeCompare(left.last_active_at),
      );
  }, [sessions, search, filter]);

  async function openSession(session: SessionSummary) {
    const ticket = request.current + 1;
    request.current = ticket;
    setSelectedId(session.id);
    setDetail(null);
    setDetailLoading(true);
    const next = await fetchSession(session.id, 300);
    if (request.current !== ticket) {
      return;
    }
    setDetail(next);
    setDetailLoading(false);
  }

  function closeSession() {
    request.current += 1;
    setSelectedId(null);
    setDetail(null);
    setDetailLoading(false);
  }

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}

      <div className="toolbar-row">
        <input
          className="search-input"
          type="search"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search sessions, users or actions"
        />
        <select
          className="select"
          value={filter}
          onChange={(event) => setFilter(event.target.value as Filter)}
        >
          <option value="all">All sessions</option>
          <option value="app">App actions</option>
          <option value="login">Host logins</option>
        </select>
        <button
          type="button"
          className="button ghost"
          onClick={() => void loadSessions()}
          disabled={loading.sessions}
        >
          {loading.sessions ? "Refreshing…" : "Refresh"}
        </button>
        <span className="toolbar-count">{filtered.length} shown</span>
      </div>

      {loading.sessions && sessions.length === 0 ? (
        <Spinner label="Loading sessions…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon="◷"
          title={sessions.length === 0 ? "No sessions yet" : "No matching sessions"}
          description={
            sessions.length === 0
              ? "Actions taken in the apps and host logins appear here."
              : "Change the search or filter."
          }
        />
      ) : (
        <div className="list session-list">
          {filtered.map((session) => (
            <div
              className="session-row"
              key={session.id}
              role="button"
              tabIndex={0}
              onClick={() => void openSession(session)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  void openSession(session);
                }
              }}
            >
              <span className="session-icon" aria-hidden="true">
                {sourceIcon(session.source)}
              </span>
              <div className="session-main">
                <div className="session-title">
                  <strong>{session.title}</strong>
                  <span className={`badge badge-${statusTone(session.status)}`}>
                    {session.kind === "login"
                      ? session.state
                      : session.status}
                  </span>
                </div>
                <span className="session-summary">{session.summary}</span>
                <div className="session-meta">
                  <span className="service-tag">{sourceLabel(session.source)}</span>
                  {session.user ? (
                    <span className="service-tag">{session.user}</span>
                  ) : null}
                  {session.remote_host ? (
                    <span className="service-tag">{session.remote_host}</span>
                  ) : null}
                  <span className="muted">
                    {formatTimestamp(session.last_active_at)}
                  </span>
                  <span className="muted">
                    {session.kind === "login"
                      ? session.action_count > 0
                        ? `${session.action_count} commands`
                        : "live login"
                      : `${session.action_count} action${session.action_count === 1 ? "" : "s"}`}
                  </span>
                </div>
              </div>
              <span className="session-chevron" aria-hidden="true">
                ›
              </span>
            </div>
          ))}
        </div>
      )}

      {selectedId ? (
        <Modal
          title={detail?.title ?? "Session"}
          onClose={closeSession}
        >
          {detailLoading && !detail ? (
            <Spinner label="Loading session…" />
          ) : !detail ? (
            <p className="muted">Session details are unavailable.</p>
          ) : (
            <div className="session-detail">
              <div className="detail-grid">
                <InfoRow label="Source" value={sourceLabel(detail.source)} />
                <InfoRow
                  label="Type"
                  value={detail.kind === "app" ? "App actions" : "Host login"}
                />
                {detail.user ? <InfoRow label="User" value={detail.user} /> : null}
                {detail.service ? (
                  <InfoRow label="Service" value={detail.service} />
                ) : null}
                {detail.tty ? <InfoRow label="TTY" value={detail.tty} /> : null}
                {detail.seat ? <InfoRow label="Seat" value={detail.seat} /> : null}
                {detail.remote_host ? (
                  <InfoRow label="Remote" value={detail.remote_host} mono />
                ) : null}
                <InfoRow label="State" value={detail.state} />
                <InfoRow label="Status" value={detail.status} />
                <InfoRow
                  label="Started"
                  value={formatTimestamp(detail.started_at)}
                />
                <InfoRow
                  label="Last active"
                  value={formatTimestamp(detail.last_active_at)}
                />
                <InfoRow label="Actions" value={String(detail.action_count)} />
              </div>

              {detail.actions.length > 0 ? (
                <section className="session-section">
                  <h3>Actions</h3>
                  <div className="session-actions">
                    {detail.actions.map((action) => (
                      <div className="session-action" key={action.id}>
                        <div className="session-action-head">
                          <StatusBadge
                            text={action.status}
                            tone={statusTone(action.status)}
                          />
                          <strong>
                            {action.action}
                            {action.target ? ` ${action.target}` : ""}
                          </strong>
                          <span className="muted">
                            {formatTimestamp(action.at)}
                          </span>
                        </div>
                        {action.path ? (
                          <span className="session-action-http">
                            {(action.method ?? "post").toUpperCase()} {action.path}
                            {action.status_code ? ` · ${action.status_code}` : ""}
                            {typeof action.duration_ms === "number"
                              ? ` · ${action.duration_ms}ms`
                              : ""}
                          </span>
                        ) : null}
                        {action.detail ? (
                          <p className="session-action-detail">{action.detail}</p>
                        ) : null}
                        {action.output ? (
                          <pre className="log-output compact">{action.output}</pre>
                        ) : null}
                      </div>
                    ))}
                  </div>
                </section>
              ) : null}

              {detail.commands.length > 0 ? (
                <section className="session-section">
                  <h3>Shell history</h3>
                  <p className="muted session-note">
                    Recovered from the user's shell history. Timestamps are
                    approximate when the shell does not store them.
                  </p>
                  <div className="session-commands">
                    {detail.commands.map((entry, index) => (
                      <div
                        className="session-command"
                        key={`${entry.at ?? "unknown"}-${index}`}
                      >
                        {entry.at ? (
                          <span className="muted">
                            {formatTimestamp(entry.at)}
                          </span>
                        ) : null}
                        <code>{entry.command}</code>
                      </div>
                    ))}
                  </div>
                </section>
              ) : null}

              {detail.logs.length > 0 ? (
                <section className="session-section">
                  <h3>Logs</h3>
                  <pre className="log-output compact">
                    {detail.logs.join("\n")}
                  </pre>
                </section>
              ) : null}

              {detail.actions.length === 0 &&
              detail.commands.length === 0 &&
              detail.logs.length === 0 ? (
                <p className="muted">
                  No actions or log entries were recorded for this session.
                </p>
              ) : null}
            </div>
          )}
        </Modal>
      ) : null}
    </div>
  );
}