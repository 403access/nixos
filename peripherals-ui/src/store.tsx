import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import type { ReactNode } from "react";

import * as api from "./api";
import type {
  Generation,
  GenerationDiff,
  Job,
  ProbeReport,
  ServiceUnit,
  SessionDetail,
  SessionSummary,
  StatusSample,
  StorageSnapshot,
  SystemStatus,
} from "./types";

export interface Settings {
  serverUrl: string;
  token: string;
}

type ConnectionState = "idle" | "connecting" | "online" | "offline";
type LoadingKey =
  | "status"
  | "services"
  | "storage"
  | "generations"
  | "peripherals"
  | "sessions"
  | "jobs";

const STORAGE_KEY = "nixos-control.settings";
const LEGACY_STORAGE_KEY = "nixos-control.peripherals.settings";
const EMPTY_LOADING: Record<LoadingKey, boolean> = {
  status: false,
  services: false,
  storage: false,
  generations: false,
  peripherals: false,
  sessions: false,
  jobs: false,
};

interface Store {
  settings: Settings | null;
  status: SystemStatus | null;
  services: ServiceUnit[];
  storage: StorageSnapshot | null;
  generations: Generation[];
  peripherals: ProbeReport | null;
  sessions: SessionSummary[];
  jobs: Job[];
  activeJob: Job | null;
  loading: Record<LoadingKey, boolean>;
  error: string | null;
  peripheralsError: string | null;
  serverVersion: string | null;
  lastUpdated: Date | null;
  connectionState: ConnectionState;
  saveSettings(next: Settings): Promise<string | null>;
  clearSettings(): void;
  refreshStatus(): Promise<void>;
  fetchStatusHistory(minutes: number, limit?: number): Promise<StatusSample[]>;
  loadServices(): Promise<void>;
  loadStorage(): Promise<void>;
  loadGenerations(): Promise<void>;
  fetchGenerationDiff(from: number, to: number): Promise<GenerationDiff | null>;
  loadPeripherals(): Promise<void>;
  loadSessions(): Promise<void>;
  fetchSession(id: string, lines: number): Promise<SessionDetail | null>;
  loadJobs(): Promise<void>;
  fetchJob(id: string): Promise<Job | null>;
  performServiceAction(unit: string, action: string): Promise<string | null>;
  startRebuild(action: string): Promise<string | null>;
  cancelActiveJob(): Promise<void>;
  requestPower(action: string): Promise<string | null>;
  fetchServiceLogs(unit: string, lines: number): Promise<string[]>;
  fetchSystemLogs(lines: number): Promise<string[]>;
  fetchPoolStatus(name: string): Promise<string | null>;
  setActiveJob(job: Job | null): void;
}

const StoreContext = createContext<Store | null>(null);

export function NixOSControlProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<Settings | null>(loadSettings);
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [services, setServices] = useState<ServiceUnit[]>([]);
  const [storage, setStorage] = useState<StorageSnapshot | null>(null);
  const [generations, setGenerations] = useState<Generation[]>([]);
  const [peripherals, setPeripherals] = useState<ProbeReport | null>(null);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [activeJob, setActiveJob] = useState<Job | null>(null);
  const [loading, setLoading] = useState(EMPTY_LOADING);
  const [error, setError] = useState<string | null>(null);
  const [peripheralsError, setPeripheralsError] = useState<string | null>(null);
  const [serverVersion, setServerVersion] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [connectionState, setConnectionState] =
    useState<ConnectionState>("idle");

  const setLoadingKey = useCallback((key: LoadingKey, value: boolean) => {
    setLoading((previous) => ({ ...previous, [key]: value }));
  }, []);

  const refreshStatus = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("status", true);
    try {
      const next = await api.getStatus(settings.serverUrl, settings.token);
      setStatus(next);
      setServerVersion(next.server_version);
      setConnectionState("online");
      setLastUpdated(new Date());
      setError(null);
    } catch (cause) {
      setConnectionState("offline");
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("status", false);
    }
  }, [settings, setLoadingKey]);

  const fetchStatusHistory = useCallback(
    async (minutes: number, limit = 720) => {
      if (!settings) {
        return [];
      }
      try {
        const response = await api.getStatusHistory(
          settings.serverUrl,
          settings.token,
          minutes,
          limit,
        );
        return response.samples;
      } catch (cause) {
        setError(api.errorMessage(cause));
        return [];
      }
    },
    [settings],
  );

  const loadServices = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("services", true);
    try {
      setServices(await api.getServices(settings.serverUrl, settings.token));
      setError(null);
    } catch (cause) {
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("services", false);
    }
  }, [settings, setLoadingKey]);

  const loadStorage = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("storage", true);
    try {
      setStorage(await api.getStorage(settings.serverUrl, settings.token));
      setError(null);
    } catch (cause) {
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("storage", false);
    }
  }, [settings, setLoadingKey]);

  const loadGenerations = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("generations", true);
    try {
      const response = await api.getGenerations(
        settings.serverUrl,
        settings.token,
      );
      setGenerations(response.generations);
      setError(null);
    } catch (cause) {
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("generations", false);
    }
  }, [settings, setLoadingKey]);

  const fetchGenerationDiff = useCallback(
    async (from: number, to: number) => {
      if (!settings) {
        return null;
      }
      try {
        return await api.getGenerationDiff(
          settings.serverUrl,
          settings.token,
          from,
          to,
        );
      } catch (cause) {
        setError(api.errorMessage(cause));
        return null;
      }
    },
    [settings],
  );

  const loadPeripherals = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("peripherals", true);
    try {
      setPeripherals(await api.getPeripherals(settings.serverUrl, settings.token));
      setPeripheralsError(null);
    } catch (cause) {
      setPeripheralsError(api.errorMessage(cause));
    } finally {
      setLoadingKey("peripherals", false);
    }
  }, [settings, setLoadingKey]);

  const loadSessions = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("sessions", true);
    try {
      const response = await api.getSessions(
        settings.serverUrl,
        settings.token,
        100,
      );
      setSessions(response.sessions);
      setError(null);
    } catch (cause) {
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("sessions", false);
    }
  }, [settings, setLoadingKey]);

  const fetchSession = useCallback(
    async (id: string, lines: number) => {
      if (!settings) {
        return null;
      }
      try {
        return await api.getSession(
          settings.serverUrl,
          settings.token,
          id,
          lines,
        );
      } catch (cause) {
        setError(api.errorMessage(cause));
        return null;
      }
    },
    [settings],
  );

  const loadJobs = useCallback(async () => {
    if (!settings) {
      return;
    }
    setLoadingKey("jobs", true);
    try {
      const list = await api.getJobs(settings.serverUrl, settings.token);
      setJobs(list);
      setActiveJob((current) => {
        if (current && current.status === "running") {
          return list.find((job) => job.id === current.id) ?? current;
        }
        return list.find((job) => job.status === "running") ?? list[0] ?? null;
      });
      setError(null);
    } catch (cause) {
      setError(api.errorMessage(cause));
    } finally {
      setLoadingKey("jobs", false);
    }
  }, [settings, setLoadingKey]);

  const fetchJob = useCallback(
    async (id: string) => {
      if (!settings) {
        return null;
      }
      try {
        return await api.getJob(settings.serverUrl, settings.token, id);
      } catch (cause) {
        setError(api.errorMessage(cause));
        return null;
      }
    },
    [settings],
  );

  useEffect(() => {
    if (!settings) {
      return;
    }
    void refreshStatus();
    const interval = window.setInterval(() => {
      void refreshStatus();
    }, 10_000);
    return () => window.clearInterval(interval);
  }, [settings, refreshStatus]);

  const saveSettings = useCallback(async (next: Settings) => {
    setConnectionState("connecting");
    try {
      const health = await api.checkHealth(next.serverUrl, next.token);
      setSettings(next);
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      localStorage.removeItem(LEGACY_STORAGE_KEY);
      setServerVersion(health.version);
      setConnectionState("online");
      setError(null);
      setStatus(null);
      setServices([]);
      setStorage(null);
      setGenerations([]);
      setPeripherals(null);
      setSessions([]);
      setJobs([]);
      setActiveJob(null);
      setPeripheralsError(null);
      return null;
    } catch (cause) {
      setConnectionState("offline");
      return api.errorMessage(cause);
    }
  }, []);

  const clearSettings = useCallback(() => {
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(LEGACY_STORAGE_KEY);
    setSettings(null);
    setStatus(null);
    setServices([]);
    setStorage(null);
    setGenerations([]);
    setPeripherals(null);
    setSessions([]);
    setJobs([]);
    setActiveJob(null);
    setError(null);
    setPeripheralsError(null);
    setServerVersion(null);
    setLastUpdated(null);
    setConnectionState("idle");
  }, []);

  const performServiceAction = useCallback(
    async (unit: string, action: string) => {
      if (!settings) {
        return "Not configured.";
      }
      try {
        await api.serviceAction(settings.serverUrl, settings.token, unit, action);
        await loadServices();
        await refreshStatus();
        return null;
      } catch (cause) {
        return api.errorMessage(cause);
      }
    },
    [settings, loadServices, refreshStatus],
  );

  const startRebuild = useCallback(
    async (action: string) => {
      if (!settings) {
        return "Not configured.";
      }
      try {
        const job = await api.startRebuild(
          settings.serverUrl,
          settings.token,
          action,
        );
        setActiveJob(job);
        setJobs((previous) => [
          job,
          ...previous.filter((item) => item.id !== job.id),
        ]);
        return null;
      } catch (cause) {
        return api.errorMessage(cause);
      }
    },
    [settings],
  );

  const cancelActiveJob = useCallback(async () => {
    if (!settings || !activeJob) {
      return;
    }
    try {
      const job = await api.cancelJob(
        settings.serverUrl,
        settings.token,
        activeJob.id,
      );
      setActiveJob(job);
      setJobs((previous) =>
        previous.map((item) => (item.id === job.id ? job : item)),
      );
    } catch (cause) {
      setError(api.errorMessage(cause));
    }
  }, [settings, activeJob]);

  const requestPower = useCallback(
    async (action: string) => {
      if (!settings) {
        return "Not configured.";
      }
      try {
        await api.requestPower(settings.serverUrl, settings.token, action);
        return null;
      } catch (cause) {
        return api.errorMessage(cause);
      }
    },
    [settings],
  );

  const fetchServiceLogs = useCallback(
    async (unit: string, lines: number) => {
      if (!settings) {
        return [];
      }
      try {
        const response = await api.getServiceLogs(
          settings.serverUrl,
          settings.token,
          unit,
          lines,
        );
        return response.lines;
      } catch (cause) {
        setError(api.errorMessage(cause));
        return [];
      }
    },
    [settings],
  );

  const fetchSystemLogs = useCallback(
    async (lines: number) => {
      if (!settings) {
        return [];
      }
      try {
        const response = await api.getLogs(
          settings.serverUrl,
          settings.token,
          lines,
        );
        return response.lines;
      } catch (cause) {
        setError(api.errorMessage(cause));
        return [];
      }
    },
    [settings],
  );

  const fetchPoolStatus = useCallback(
    async (name: string) => {
      if (!settings) {
        return null;
      }
      try {
        const response = await api.getPoolStatus(
          settings.serverUrl,
          settings.token,
          name,
        );
        return response.status;
      } catch (cause) {
        setError(api.errorMessage(cause));
        return null;
      }
    },
    [settings],
  );

  const value = useMemo<Store>(
    () => ({
      settings,
      status,
      services,
      storage,
      generations,
      peripherals,
      sessions,
      jobs,
      activeJob,
      loading,
      error,
      peripheralsError,
      serverVersion,
      lastUpdated,
      connectionState,
      saveSettings,
      clearSettings,
      refreshStatus,
      fetchStatusHistory,
      loadServices,
      loadStorage,
      loadGenerations,
      fetchGenerationDiff,
      loadPeripherals,
      loadSessions,
      fetchSession,
      loadJobs,
      fetchJob,
      performServiceAction,
      startRebuild,
      cancelActiveJob,
      requestPower,
      fetchServiceLogs,
      fetchSystemLogs,
      fetchPoolStatus,
      setActiveJob,
    }),
    [
      settings,
      status,
      services,
      storage,
      generations,
      peripherals,
      sessions,
      jobs,
      activeJob,
      loading,
      error,
      peripheralsError,
      serverVersion,
      lastUpdated,
      connectionState,
      saveSettings,
      clearSettings,
      refreshStatus,
      fetchStatusHistory,
      loadServices,
      loadStorage,
      loadGenerations,
      fetchGenerationDiff,
      loadPeripherals,
      loadSessions,
      fetchSession,
      loadJobs,
      fetchJob,
      performServiceAction,
      startRebuild,
      cancelActiveJob,
      requestPower,
      fetchServiceLogs,
      fetchSystemLogs,
      fetchPoolStatus,
    ],
  );

  return (
    <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
  );
}

export function useNixOSControl(): Store {
  const store = useContext(StoreContext);
  if (!store) {
    throw new Error("useNixOSControl must be used inside NixOSControlProvider");
  }
  return store;
}

function loadSettings(): Settings | null {
  try {
    const raw =
      localStorage.getItem(STORAGE_KEY) ??
      localStorage.getItem(LEGACY_STORAGE_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw) as Partial<Settings>;
    if (!parsed.token) {
      return null;
    }
    return {
      serverUrl: parsed.serverUrl ?? "",
      token: parsed.token,
    };
  } catch {
    return null;
  }
}