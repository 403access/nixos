import { useCallback, useEffect, useState, type CSSProperties } from "react";

import {
  Card,
  ErrorBanner,
  InfoRow,
  Spinner,
  StatusBadge,
  formatTimestamp,
  jobTone,
} from "../components";
import { useNixOSControl } from "../store";
import type { Job, ThemeCard, ThemeCatalog } from "../types";

export default function ThemesView() {
  const { fetchThemes, applyTheme, fetchJob, setActiveJob } = useNixOSControl();
  const [catalog, setCatalog] = useState<ThemeCatalog | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [job, setJob] = useState<Job | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    const next = await fetchThemes();
    setCatalog(next);
    setLoading(false);
    if (!next) {
      setError("Could not load the theme catalog.");
    }
  }, [fetchThemes]);

  useEffect(() => {
    void reload();
  }, [reload]);

  useEffect(() => {
    if (!job || job.status !== "running") {
      return;
    }
    const id = job.id;
    const interval = window.setInterval(() => {
      void fetchJob(id).then((next) => {
        if (!next) {
          return;
        }
        setJob(next);
        setActiveJob(next);
        if (next.status !== "running") {
          setNotice(
            next.status === "success"
              ? "Theme applied. The new configuration is active."
              : `Theme rebuild ${next.status}.`,
          );
          void reload();
        }
      });
    }, 1_500);
    return () => window.clearInterval(interval);
  }, [job?.id, job?.status, fetchJob, setActiveJob, reload]);

  async function apply(
    update: { profile?: string; gtkTheme?: string; wallpaper?: string },
    label: string,
  ) {
    if (
      !window.confirm(
        `Apply ${label}? This writes the selection and runs nixos-rebuild switch.`,
      )
    ) {
      return;
    }
    setError(null);
    setNotice(null);
    const result = await applyTheme(update);
    if (!result) {
      setError("Could not apply the theme. Check the server log.");
      return;
    }
    setJob(result.job);
    setActiveJob(result.job);
    setNotice(`${label} selected. Rebuilding the host…`);
  }

  if (loading && !catalog) {
    return <Spinner label="Loading themes…" />;
  }

  if (!catalog) {
    return (
      <>
        {error ? <ErrorBanner message={error} /> : null}
        <button type="button" className="button primary" onClick={() => void reload()}>
          Retry
        </button>
      </>
    );
  }

  const busy = job?.status === "running";

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}
      {notice ? <div className="banner">{notice}</div> : null}

      <Card
        title="Current theme"
        subtitle="Active desktop configuration"
        action={
          <button type="button" className="button ghost" onClick={() => void reload()}>
            Refresh
          </button>
        }
      >
        <div className="detail-grid">
          <InfoRow label="Desktop" value={catalog.current.profile} />
          <InfoRow label="GTK theme" value={catalog.current.gtkTheme} />
          <InfoRow label="Wallpaper" value={catalog.current.wallpaper} />
          <InfoRow label="Catppuccin flavour" value={catalog.current.flavour} />
          <InfoRow label="Accent" value={catalog.current.accent} />
        </div>
      </Card>

      {job ? (
        <Card
          title="Theme rebuild"
          subtitle="nixos-rebuild switch"
          action={
            <StatusBadge text={job.status} tone={jobTone(job.status)} />
          }
        >
          <div className="job-head">
            <span className="mono">{job.kind}</span>
            <span className="muted">{formatTimestamp(job.started_at)}</span>
          </div>
          {job.output ? (
            <pre className="log-output compact">{job.output}</pre>
          ) : job.status === "running" ? (
            <Spinner label="Rebuilding…" />
          ) : null}
          {job.error ? <p className="tone-bad">{job.error}</p> : null}
        </Card>
      ) : null}

      <div>
        <h2 className="theme-section-title">Desktop profiles</h2>
        <p className="muted theme-section-note">
          Switching profiles changes the desktop session, login manager and
          dotfiles. Every apply runs a full NixOS rebuild.
        </p>
        <div className="theme-grid">
          {catalog.profiles.map((theme) => (
            <ThemeCardView
              key={theme.id}
              theme={theme}
              busy={busy}
              onApply={() => void apply({ profile: theme.id }, theme.name)}
            />
          ))}
        </div>
      </div>

      <div>
        <h2 className="theme-section-title">GTK theme</h2>
        <p className="muted theme-section-note">
          The GTK, icon and cursor theme is independent of the desktop profile.
          Switching it also selects the matching wallpaper.
        </p>
        <div className="theme-grid">
          {catalog.gtkThemes.map((theme) => (
            <ThemeCardView
              key={theme.id}
              theme={theme}
              busy={busy}
              onApply={() => void apply({ gtkTheme: theme.id }, theme.name)}
            />
          ))}
        </div>
      </div>

      <div>
        <h2 className="theme-section-title">Wallpaper</h2>
        <p className="muted theme-section-note">
          The wallpaper follows the GTK theme by default; choosing one here
          pins it for the desktop and login screen.
        </p>
        <div className="theme-grid">
          {catalog.wallpapers.map((theme) => (
            <ThemeCardView
              key={theme.id}
              theme={theme}
              busy={busy}
              onApply={() => void apply({ wallpaper: theme.id }, theme.name)}
            />
          ))}
        </div>
      </div>

      <p className="muted theme-section-note">
        The selection is written to <code>desktop/selected.nix</code> and applied
        with <code>nixos-rebuild switch</code>. The previous generation remains
        available for rollback.
      </p>
    </div>
  );
}

function ThemeCardView({
  theme,
  busy,
  onApply,
}: {
  theme: ThemeCard;
  busy: boolean;
  onApply: () => void;
}) {
  return (
    <article className={`theme-card${theme.current ? " current" : ""}`}>
      <div
        className="theme-preview"
        style={{ "--theme-accent": theme.accent } as CSSProperties}
      >
        {theme.screenshot ? (
          <img
            src={`/themes/${theme.screenshot}.png`}
            alt={`${theme.name} screenshot`}
            loading="lazy"
          />
        ) : (
          <div className="theme-gradient">
            <span>{theme.name}</span>
          </div>
        )}
      </div>

      <div className="theme-body">
        <div className="theme-card-head">
          <h3>{theme.name}</h3>
          {theme.current ? (
            <StatusBadge text="current" tone="good" />
          ) : null}
        </div>
        <p>{theme.description}</p>
        <ul className="theme-details">
          {theme.details.map((detail) => (
            <li key={detail}>{detail}</li>
          ))}
        </ul>
        <button
          type="button"
          className={`button${theme.current ? " ghost" : " primary"}`}
          disabled={busy || theme.current}
          onClick={onApply}
        >
          {theme.current ? "Active" : "Apply theme"}
        </button>
      </div>
    </article>
  );
}