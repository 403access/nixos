import { createPortal } from "react-dom";
import { useEffect } from "react";
import type { ReactNode } from "react";

import { usePanel } from "./panel";
import type { SignalInfo } from "./types";

export function Card({
  title,
  subtitle,
  action,
  children,
  className,
}: {
  title?: string;
  subtitle?: string;
  action?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`card${className ? ` ${className}` : ""}`}>
      {title || action ? (
        <div className="card-head">
          <div>
            {title ? <h2>{title}</h2> : null}
            {subtitle ? <p>{subtitle}</p> : null}
          </div>
          {action}
        </div>
      ) : null}
      <div className="card-body">{children}</div>
    </section>
  );
}

export function MetricTile({
  label,
  value,
  caption,
  progress,
  tone = "accent",
  onClick,
}: {
  label: string;
  value: string;
  caption?: string;
  progress?: number;
  tone?: Tone;
  onClick?: () => void;
}) {
  return (
    <div
      className={`metric${onClick ? " clickable" : ""}`}
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onClick={onClick}
      onKeyDown={
        onClick
          ? (event) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onClick();
              }
            }
          : undefined
      }
      title={onClick ? "Open history" : undefined}
    >
      <div className="metric-label">{label}</div>
      <div className="metric-value">{value}</div>
      {caption ? <div className="metric-caption">{caption}</div> : null}
      {progress !== undefined ? (
        <UsageBar fraction={progress} tone={tone} />
      ) : null}
    </div>
  );
}

export type Tone = "accent" | "good" | "warn" | "bad" | "muted";

export function UsageBar({
  fraction,
  tone = "accent",
}: {
  fraction: number;
  tone?: Tone;
}) {
  const clamped = Math.min(Math.max(fraction, 0), 1);
  return (
    <div className="usage-bar">
      <div className={`usage-fill ${tone}`} style={{ width: `${clamped * 100}%` }} />
    </div>
  );
}

export function StatusBadge({
  text,
  tone = "muted",
}: {
  text: string;
  tone?: Tone;
}) {
  return <span className={`badge badge-${tone}`}>{text}</span>;
}

export function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="banner error" role="alert">
      <span className="banner-icon" aria-hidden="true">
        !
      </span>
      <span>{message}</span>
    </div>
  );
}

export function EmptyState({
  icon = "○",
  title,
  description,
  action,
}: {
  icon?: ReactNode;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-icon" aria-hidden="true">
        {icon}
      </div>
      <h3>{title}</h3>
      {description ? <p>{description}</p> : null}
      {action ? <div className="empty-action">{action}</div> : null}
    </div>
  );
}

export function Spinner({ label }: { label?: string }) {
  return (
    <div className="spinner-row">
      <span className="spinner" aria-hidden="true" />
      {label ? <span>{label}</span> : null}
    </div>
  );
}

export function Modal({
  title,
  onClose,
  children,
  wide = false,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  wide?: boolean;
}) {
  const { host, setOpen } = usePanel();

  useEffect(() => {
    setOpen(true);
    return () => setOpen(false);
  }, [setOpen]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  if (!host) {
    return null;
  }

  return createPortal(
    <div
      className={`detail-panel-inner${wide ? " is-wide" : ""}`}
      role="region"
      aria-label={title}
    >
      <div className="detail-panel-head">
        <h2>{title}</h2>
        <button type="button" className="icon-button" onClick={onClose} aria-label="Close">
          ×
        </button>
      </div>
      <div className="detail-panel-body">{children}</div>
    </div>,
    host,
  );
}

export function SectionHeader({
  title,
  count,
  action,
}: {
  title: string;
  count?: string;
  action?: ReactNode;
}) {
  return (
    <div className="section-head">
      <div>
        <h2>{title}</h2>
        {count ? <span>{count}</span> : null}
      </div>
      {action}
    </div>
  );
}

export function InfoRow({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="info-row">
      <span>{label}</span>
      <strong className={mono ? "mono" : undefined}>{value}</strong>
    </div>
  );
}

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let size = value;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toFixed(size >= 10 ? 0 : 1)} ${units[index]}`;
}

export function formatPercent(value: number, digits = 0): string {
  if (!Number.isFinite(value)) {
    return "—";
  }
  return `${value.toFixed(digits)}%`;
}

export function formatUptime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) {
    return "—";
  }
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  if (days > 0) {
    return `${days}d ${hours}h`;
  }
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  return `${minutes}m`;
}

export function formatTime(date: Date): string {
  return date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatPreciseTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value || "—";
  }
  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export function formatDurationMs(value: number): string {
  if (!Number.isFinite(value) || value < 0) {
    return "—";
  }
  if (value < 1_000) {
    return `${Math.round(value)} ms`;
  }
  if (value < 60_000) {
    return `${(value / 1_000).toFixed(value < 10_000 ? 1 : 0)} s`;
  }
  const minutes = Math.floor(value / 60_000);
  const seconds = Math.round((value % 60_000) / 1_000);
  return `${minutes}m ${seconds}s`;
}

export function formatSignal(signal: SignalInfo): string {
  return signal.percent === null ? `raw ${signal.raw}` : `${signal.percent}%`;
}

export function formatStatus(status: string | null): string {
  return status ? status.replaceAll("_", " ") : "unknown";
}

export function formatVoltage(millivolts: number | null): string | null {
  if (millivolts === null) {
    return null;
  }
  return millivolts >= 1_000
    ? `${(millivolts / 1_000).toFixed(2)} V`
    : `${millivolts} mV`;
}

export function poolTone(health: string): Tone {
  switch (health.toUpperCase()) {
    case "ONLINE":
      return "good";
    case "DEGRADED":
      return "warn";
    case "FAULTED":
    case "UNAVAIL":
    case "REMOVED":
      return "bad";
    default:
      return "muted";
  }
}

export function serviceTone(active: string, sub: string): Tone {
  if (active === "failed" || sub === "failed") {
    return "bad";
  }
  if (active === "active") {
    return "good";
  }
  if (active === "activating" || active === "deactivating") {
    return "warn";
  }
  return "muted";
}

export function jobTone(status: string): Tone {
  if (status === "running") {
    return "warn";
  }
  if (status === "success") {
    return "good";
  }
  if (status === "failed" || status === "cancelled") {
    return "bad";
  }
  return "muted";
}

export function titleCase(value: string): string {
  return value
    .replaceAll("_", " ")
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

export function shortUnit(unit: string): string {
  return unit.endsWith(".service") ? unit.slice(0, -".service".length) : unit;
}

export function deviceIcon(kind: string | null): string {
  switch (kind) {
    case "keyboard":
      return "⌨";
    case "mouse":
      return "🖱";
    case "trackball":
      return "🖲";
    case "touchpad":
      return "▭";
    case "numpad":
      return "⌨";
    default:
      return "•";
  }
}