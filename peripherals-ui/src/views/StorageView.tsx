import { useEffect, useMemo, useState } from "react";

import {
  EmptyState,
  ErrorBanner,
  Modal,
  Spinner,
  StatusBadge,
  formatBytes,
  formatPercent,
  formatTimestamp,
  poolTone,
} from "../components";
import { useNixOSControl } from "../store";
import type { FileEntry, FileListing, FilesystemInfo } from "../types";

type Explorer = {
  root: string;
  source: string;
  fstype: string;
};

type Crumb = {
  label: string;
  path: string;
};

export default function StorageView() {
  const {
    storage,
    loading,
    error,
    loadStorage,
    fetchPoolStatus,
    fetchFiles,
  } = useNixOSControl();
  const [selectedPool, setSelectedPool] = useState<string | null>(null);
  const [poolStatus, setPoolStatus] = useState("");
  const [poolLoading, setPoolLoading] = useState(false);

  const [explorer, setExplorer] = useState<Explorer | null>(null);
  const [listing, setListing] = useState<FileListing | null>(null);
  const [filesPath, setFilesPath] = useState("");
  const [filesQuery, setFilesQuery] = useState("");
  const [filesSort, setFilesSort] = useState("name");
  const [filesOrder, setFilesOrder] = useState<"asc" | "desc">("asc");
  const [filesFilter, setFilesFilter] = useState("all");
  const [filesHidden, setFilesHidden] = useState(false);
  const [filesLoading, setFilesLoading] = useState(false);
  const [filesError, setFilesError] = useState<string | null>(null);
  const [filesRefresh, setFilesRefresh] = useState(0);

  useEffect(() => {
    if (storage === null) {
      void loadStorage();
    }
  }, [storage, loadStorage]);

  useEffect(() => {
    if (!selectedPool) {
      return;
    }
    let cancelled = false;
    setPoolLoading(true);
    void fetchPoolStatus(selectedPool).then((status) => {
      if (!cancelled) {
        setPoolStatus(status ?? "Could not load pool status.");
        setPoolLoading(false);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [selectedPool, fetchPoolStatus]);

  useEffect(() => {
    if (!explorer) {
      return;
    }
    let active = true;
    const timer = window.setTimeout(
      () => {
        setFilesLoading(true);
        void fetchFiles({
          root: explorer.root,
          path: filesPath,
          q: filesQuery,
          sort: filesSort,
          order: filesOrder,
          filter: filesFilter,
          hidden: filesHidden,
        }).then((next) => {
          if (!active) {
            return;
          }
          if (next) {
            setListing(next);
            setFilesError(null);
          } else {
            setFilesError("Could not read this folder.");
          }
          setFilesLoading(false);
        });
      },
      filesQuery.trim() ? 250 : 0,
    );
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [
    explorer,
    filesPath,
    filesQuery,
    filesSort,
    filesOrder,
    filesFilter,
    filesHidden,
    filesRefresh,
    fetchFiles,
  ]);

  const currentPath = listing?.path ?? filesPath;
  const crumbs = useMemo(
    () => buildCrumbs(explorer?.root ?? "/", currentPath),
    [explorer?.root, currentPath],
  );
  const searching = filesQuery.trim().length > 0;

  if (!storage && loading.storage) {
    return <Spinner label="Loading storage…" />;
  }

  if (!storage) {
    return (
      <>
        {error ? <ErrorBanner message={error} /> : null}
        <EmptyState
          icon="▤"
          title="No storage data"
          description="Check the connection or refresh."
          action={
            <button type="button" className="button primary" onClick={() => void loadStorage()}>
              Refresh
            </button>
          }
        />
      </>
    );
  }

  function openFilesystem(filesystem: FilesystemInfo) {
    const nextRoot = filesystem.mountpoint;
    setSelectedPool(null);
    setExplorer({
      root: nextRoot,
      source: filesystem.source,
      fstype: filesystem.fstype,
    });
    setFilesPath(nextRoot);
    setFilesQuery("");
    setFilesError(null);
    setListing(null);
  }

  function navigate(path: string) {
    setFilesPath(path);
    setFilesQuery("");
  }

  return (
    <>
      <div className="view-stack">
          {error ? <ErrorBanner message={error} /> : null}

          <div className="toolbar-row">
            <span className="toolbar-count">
              {storage.pools.length} pools · {storage.datasets.length} datasets ·{" "}
              {storage.filesystems.length} filesystems
            </span>
            <button
              type="button"
              className="button ghost"
              onClick={() => void loadStorage()}
              disabled={loading.storage}
            >
              {loading.storage ? "Refreshing…" : "Refresh"}
            </button>
          </div>

          {storage.pools.length > 0 ? (
            <section className="card">
              <div className="card-head">
                <div>
                  <h2>ZFS pools</h2>
                  <p>Health and capacity</p>
                </div>
              </div>
              <div className="card-body">
                <div className="list">
                  {storage.pools.map((pool) => (
                    <button
                      type="button"
                      className="pool-row clickable"
                      key={pool.name}
                      onClick={() => {
                        setPoolStatus("");
                        setSelectedPool(pool.name);
                        setExplorer(null);
                      }}
                    >
                      <div className="pool-row-head">
                        <strong>{pool.name}</strong>
                        <span className="row-end">
                          <StatusBadge text={pool.health} tone={poolTone(pool.health)} />
                          <span className="chevron">›</span>
                        </span>
                      </div>
                      <div className="usage-bar">
                        <div
                          className={`usage-fill ${poolTone(pool.health)}`}
                          style={{
                            width: `${usageFraction(pool.allocated, pool.size) * 100}%`,
                          }}
                        />
                      </div>
                      <div className="pool-row-foot">
                        <span>
                          {formatBytes(pool.allocated)} of {formatBytes(pool.size)}
                        </span>
                        <span>{formatBytes(pool.free)} free</span>
                      </div>
                      {pool.fragmentation && pool.fragmentation !== "-" ? (
                        <div className="pool-row-foot">
                          <span>Fragmentation {pool.fragmentation}</span>
                        </div>
                      ) : null}
                    </button>
                  ))}
                </div>
              </div>
            </section>
          ) : null}

          {storage.datasets.length > 0 ? (
            <section className="card">
              <div className="card-head">
                <div>
                  <h2>ZFS datasets</h2>
                  <p>Usage by dataset</p>
                </div>
              </div>
              <div className="card-body">
                <div className="list">
                  {storage.datasets.map((dataset) => (
                    <div className="data-row" key={dataset.name}>
                      <div className="data-main">
                        <strong className="mono">{dataset.name}</strong>
                        <span>{dataset.mountpoint}</span>
                      </div>
                      <div className="data-side">
                        <strong>{formatBytes(dataset.used)}</strong>
                        <span>{formatBytes(dataset.available)} free</span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </section>
          ) : null}

          {storage.filesystems.length > 0 ? (
            <section className="card">
              <div className="card-head">
                <div>
                  <h2>Filesystems</h2>
                  <p>Mounted filesystems · click one to browse its files</p>
                </div>
              </div>
              <div className="card-body">
                <div className="list">
                  {storage.filesystems.map((filesystem) => {
                    const tone = filesystem.use_percent >= 90 ? "bad" : "accent";
                    const active = explorer?.root === filesystem.mountpoint;
                    return (
                      <button
                        type="button"
                        className={`filesystem clickable${active ? " active" : ""}`}
                        key={`${filesystem.mountpoint}-${filesystem.source}`}
                        onClick={() => openFilesystem(filesystem)}
                        aria-pressed={active}
                      >
                        <div className="data-row">
                          <div className="data-main">
                            <strong>{filesystem.mountpoint}</strong>
                            <span>
                              {filesystem.source} · {filesystem.fstype}
                            </span>
                          </div>
                          <div className="data-side">
                            <strong className={`tone-${tone}`}>
                              {formatPercent(filesystem.use_percent, 0)}
                            </strong>
                            <span>
                              {formatBytes(filesystem.used)} of {formatBytes(filesystem.size)}
                            </span>
                            <span className="filesystem-open">
                              {active ? "Browsing" : "Browse files"} <span className="chevron">›</span>
                            </span>
                          </div>
                        </div>
                        <div className="usage-bar">
                          <div
                            className={`usage-fill ${tone}`}
                            style={{
                              width: `${Math.min(Math.max(filesystem.use_percent, 0), 100)}%`,
                            }}
                          />
                        </div>
                      </button>
                    );
                  })}
                </div>
              </div>
            </section>
          ) : null}

          {selectedPool ? (
            <Modal title={selectedPool} onClose={() => setSelectedPool(null)} wide>
              {poolLoading ? (
                <Spinner label="Reading zpool status…" />
              ) : (
                <pre className="log-output">{poolStatus}</pre>
              )}
              <div className="form-actions">
                <button
                  type="button"
                  className="button ghost"
                  onClick={() => {
                    setPoolStatus("");
                    setPoolLoading(true);
                    void fetchPoolStatus(selectedPool).then((status) => {
                      setPoolStatus(status ?? "Could not load pool status.");
                      setPoolLoading(false);
                    });
                  }}
                >
                  Refresh
                </button>
              </div>
            </Modal>
          ) : null}
        </div>

      {explorer ? (
        <Modal title={explorer.root} onClose={() => setExplorer(null)} wide>
          <div className="file-explorer">
            <p className="file-explorer-meta">
              {explorer.source} · {explorer.fstype}
            </p>

            <div className="file-explorer-path">
            <button
              type="button"
              className="button ghost tiny"
              title="Up one folder"
              disabled={!listing?.parent}
              onClick={() => {
                if (listing?.parent) {
                  navigate(listing.parent);
                }
              }}
            >
              ↑
            </button>
            <nav className="breadcrumbs" aria-label="Folder path">
              {crumbs.map((crumb, index) => (
                <span className="breadcrumb" key={crumb.path}>
                  {index > 0 ? <span className="breadcrumb-sep">/</span> : null}
                  <button
                    type="button"
                    className="breadcrumb-link"
                    onClick={() => navigate(crumb.path)}
                    disabled={index === crumbs.length - 1}
                  >
                    {crumb.label}
                  </button>
                </span>
              ))}
            </nav>
            <button
              type="button"
              className="button ghost tiny"
              title="Refresh"
              onClick={() => setFilesRefresh((value) => value + 1)}
            >
              ↻
            </button>
          </div>

          <input
            className="search-input file-search"
            type="search"
            placeholder="Search this folder and below…"
            value={filesQuery}
            onChange={(event) => setFilesQuery(event.target.value)}
            aria-label="Search files"
          />

          <div className="file-explorer-filters">
            <label className="inline-field">
              Show
              <select
                className="select"
                value={filesFilter}
                onChange={(event) => setFilesFilter(event.target.value)}
              >
                <option value="all">Everything</option>
                <option value="files">Files</option>
                <option value="dirs">Folders</option>
              </select>
            </label>
            <label className="inline-field">
              Sort
              <select
                className="select"
                value={filesSort}
                onChange={(event) => setFilesSort(event.target.value)}
              >
                <option value="name">Name</option>
                <option value="size">Size</option>
                <option value="modified">Modified</option>
                <option value="type">Type</option>
              </select>
            </label>
            <button
              type="button"
              className="button ghost tiny"
              title={filesOrder === "asc" ? "Ascending" : "Descending"}
              onClick={() =>
                setFilesOrder((value) => (value === "asc" ? "desc" : "asc"))
              }
            >
              {filesOrder === "asc" ? "↑" : "↓"}
            </button>
            <label className="file-toggle">
              <input
                type="checkbox"
                checked={filesHidden}
                onChange={(event) => setFilesHidden(event.target.checked)}
              />
              Hidden
            </label>
          </div>

          {filesError ? <p className="tone-bad file-error">{filesError}</p> : null}

          <div className="file-list">
            {filesLoading && !listing ? (
              <Spinner label="Reading files…" />
            ) : listing && listing.entries.length > 0 ? (
              listing.entries.map((entry) => (
                <FileRow
                  key={entry.path}
                  entry={entry}
                  base={listing.path}
                  searching={searching}
                  onOpen={navigate}
                />
              ))
            ) : (
              <p className="muted file-empty">
                {searching ? "No files match this search." : "This folder is empty."}
              </p>
            )}
          </div>

          <div className="file-explorer-foot">
            <span>
              {listing ? listing.total : 0} {searching ? "matches" : "entries"}
              {listing?.truncated ? " · limited" : ""}
            </span>
            {filesLoading && listing ? <span>Updating…</span> : null}
          </div>
          </div>
        </Modal>
      ) : null}
    </>
  );
}

function FileRow({
  entry,
  base,
  searching,
  onOpen,
}: {
  entry: FileEntry;
  base: string;
  searching: boolean;
  onOpen: (path: string) => void;
}) {
  const isDir = entry.kind === "dir";
  const relative = relativePath(base, entry.path);
  const subtitle = searching
    ? relative
    : isDir
      ? "Folder"
      : entry.kind === "symlink"
        ? "Symlink"
        : "File";

  const content = (
    <>
      <span className={`file-glyph${isDir ? " dir" : ""}`} aria-hidden="true">
        {isDir ? (
          <svg viewBox="0 0 24 24" width="16" height="16">
            <path
              d="M3 7.5A2.5 2.5 0 0 1 5.5 5h3.1c.7 0 1.3.28 1.77.74l.9.9c.19.18.44.29.7.29h6.53A2.5 2.5 0 0 1 21 9.43v7.07A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5v-9Z"
              fill="currentColor"
              opacity="0.85"
            />
          </svg>
        ) : (
          <svg viewBox="0 0 24 24" width="16" height="16">
            <path
              d="M6 3h7l5 5v13H6V3Z"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinejoin="round"
            />
            <path d="M13 3v5h5" fill="none" stroke="currentColor" strokeWidth="1.6" />
          </svg>
        )}
      </span>
      <span className="file-main">
        <span className="file-name">{entry.name}</span>
        <span className="file-meta">{subtitle}</span>
      </span>
      <span className="file-size">{isDir ? "—" : formatBytes(entry.size)}</span>
      <span className="file-date">
        {entry.modified ? formatTimestamp(entry.modified) : ""}
      </span>
    </>
  );

  if (isDir) {
    return (
      <button
        type="button"
        className="file-row clickable"
        onClick={() => onOpen(entry.path)}
      >
        {content}
      </button>
    );
  }

  return (
    <div className="file-row">
      {content}
    </div>
  );
}

function relativePath(base: string, path: string): string {
  if (path === base) {
    return "";
  }
  const prefix = base === "/" ? "/" : `${base}/`;
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}

function buildCrumbs(root: string, path: string): Crumb[] {
  const rootLabel = root === "/" ? "/" : root;
  const relative = relativePath(root, path);
  const parts = relative.split("/").filter(Boolean);
  const crumbs: Crumb[] = [{ label: rootLabel, path: root }];
  let current = root;
  for (const part of parts) {
    current = current === "/" ? `/${part}` : `${current}/${part}`;
    crumbs.push({ label: part, path: current });
  }
  return crumbs;
}

function usageFraction(used: number, total: number): number {
  if (!Number.isFinite(used) || !Number.isFinite(total) || total <= 0) {
    return 0;
  }
  return Math.min(Math.max(used / total, 0), 1);
}