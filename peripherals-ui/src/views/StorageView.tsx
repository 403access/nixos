import { useEffect, useState } from "react";

import {
  EmptyState,
  ErrorBanner,
  Modal,
  Spinner,
  StatusBadge,
  formatBytes,
  formatPercent,
  poolTone,
} from "../components";
import { useNixOSControl } from "../store";

export default function StorageView() {
  const { storage, loading, error, loadStorage, fetchPoolStatus } = useNixOSControl();
  const [selectedPool, setSelectedPool] = useState<string | null>(null);
  const [poolStatus, setPoolStatus] = useState("");
  const [poolLoading, setPoolLoading] = useState(false);

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

  return (
    <div className="view-stack">
      {error ? <ErrorBanner message={error} /> : null}

      <div className="toolbar-row">
        <span className="toolbar-count">
          {storage.pools.length} pools · {storage.datasets.length} datasets · {storage.filesystems.length} filesystems
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
                      style={{ width: `${usageFraction(pool.allocated, pool.size) * 100}%` }}
                    />
                  </div>
                  <div className="pool-row-foot">
                    <span>{formatBytes(pool.allocated)} of {formatBytes(pool.size)}</span>
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
              <p>Mounted filesystems</p>
            </div>
          </div>
          <div className="card-body">
            <div className="list">
              {storage.filesystems.map((filesystem) => {
                const tone = filesystem.use_percent >= 90 ? "bad" : "accent";
                return (
                  <div className="filesystem" key={`${filesystem.mountpoint}-${filesystem.source}`}>
                    <div className="data-row">
                      <div className="data-main">
                        <strong>{filesystem.mountpoint}</strong>
                        <span>{filesystem.source} · {filesystem.fstype}</span>
                      </div>
                      <div className="data-side">
                        <strong className={`tone-${tone}`}>{formatPercent(filesystem.use_percent, 0)}</strong>
                        <span>{formatBytes(filesystem.used)} of {formatBytes(filesystem.size)}</span>
                      </div>
                    </div>
                    <div className="usage-bar">
                      <div
                        className={`usage-fill ${tone}`}
                        style={{ width: `${Math.min(Math.max(filesystem.use_percent, 0), 100)}%` }}
                      />
                    </div>
                  </div>
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
  );
}

function usageFraction(used: number, total: number): number {
  if (!Number.isFinite(used) || !Number.isFinite(total) || total <= 0) {
    return 0;
  }
  return Math.min(Math.max(used / total, 0), 1);
}