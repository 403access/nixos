import type {
  ActionResponse,
  GenerationsResponse,
  GenerationDiff,
  HealthResponse,
  Job,
  LogsResponse,
  PoolStatusResponse,
  ProbeReport,
  ServiceUnit,
  SessionDetail,
  SessionsResponse,
  ResourceUsage,
  ResourceHistory,
  StatusHistoryResponse,
  StorageSnapshot,
  SystemStatus,
  ThemeApplyResult,
  ThemeCatalog,
} from "./types";

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

function normalizeBase(serverUrl: string): string {
  return serverUrl.trim().replace(/\/+$/, "");
}

function withQuery(
  path: string,
  query: Record<string, string | number | undefined>,
): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined) {
      params.set(key, String(value));
    }
  }
  const suffix = params.toString();
  return suffix ? `${path}?${suffix}` : path;
}

async function request<T>(
  serverUrl: string,
  token: string,
  path: string,
  init?: RequestInit,
): Promise<T> {
  const response = await fetch(`${normalizeBase(serverUrl)}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
      ...(init?.headers ?? {}),
    },
  });

  if (!response.ok) {
    let message = `HTTP ${response.status}`;
    try {
      const body = (await response.json()) as { error?: string };
      if (body.error) {
        message = body.error;
      }
    } catch {
      // Keep the HTTP status when the body is not JSON.
    }
    throw new ApiError(response.status, message);
  }

  return (await response.json()) as T;
}

function postJson(value: unknown): RequestInit {
  return {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(value),
  };
}

export function checkHealth(
  serverUrl: string,
  token: string,
): Promise<HealthResponse> {
  return request<HealthResponse>(serverUrl, token, "/api/health");
}

export function getStatus(
  serverUrl: string,
  token: string,
): Promise<SystemStatus> {
  return request<SystemStatus>(serverUrl, token, "/api/status");
}

export function getStatusHistory(
  serverUrl: string,
  token: string,
  minutes = 60,
  limit = 720,
): Promise<StatusHistoryResponse> {
  return request<StatusHistoryResponse>(
    serverUrl,
    token,
    withQuery("/api/status/history", { minutes, limit }),
  );
}

export function getResources(
  serverUrl: string,
  token: string,
): Promise<ResourceUsage> {
  return request<ResourceUsage>(serverUrl, token, "/api/resources");
}

export function getResourceHistory(
  serverUrl: string,
  token: string,
  params: {
    kind: "services" | "apps";
    minutes: number;
    metric: "cpu" | "memory" | "read" | "write";
    top?: number;
    entities?: string[];
  },
): Promise<ResourceHistory> {
  return request<ResourceHistory>(
    serverUrl,
    token,
    withQuery("/api/resources/history", {
      kind: params.kind,
      minutes: params.minutes,
      metric: params.metric,
      top: params.top,
      entities: params.entities?.join(","),
    }),
  );
}

export function getThemes(
  serverUrl: string,
  token: string,
): Promise<ThemeCatalog> {
  return request<ThemeCatalog>(serverUrl, token, "/api/themes");
}

export function applyTheme(
  serverUrl: string,
  token: string,
  update: { profile?: string; gtkTheme?: string; wallpaper?: string },
): Promise<ThemeApplyResult> {
  return request<ThemeApplyResult>(
    serverUrl,
    token,
    "/api/themes/apply",
    postJson(update),
  );
}

export function getServices(
  serverUrl: string,
  token: string,
): Promise<ServiceUnit[]> {
  return request<ServiceUnit[]>(serverUrl, token, "/api/services");
}

export function serviceAction(
  serverUrl: string,
  token: string,
  unit: string,
  action: string,
): Promise<ActionResponse> {
  return request<ActionResponse>(
    serverUrl,
    token,
    `/api/services/${encodeURIComponent(unit)}/${action}`,
    { method: "POST" },
  );
}

export function getServiceLogs(
  serverUrl: string,
  token: string,
  unit: string,
  lines: number,
): Promise<LogsResponse> {
  return request<LogsResponse>(
    serverUrl,
    token,
    withQuery(`/api/services/${encodeURIComponent(unit)}/logs`, { lines }),
  );
}

export function getStorage(
  serverUrl: string,
  token: string,
): Promise<StorageSnapshot> {
  return request<StorageSnapshot>(serverUrl, token, "/api/storage");
}

export function getPoolStatus(
  serverUrl: string,
  token: string,
  name: string,
): Promise<PoolStatusResponse> {
  return request<PoolStatusResponse>(
    serverUrl,
    token,
    `/api/storage/pools/${encodeURIComponent(name)}`,
  );
}

export function getGenerations(
  serverUrl: string,
  token: string,
): Promise<GenerationsResponse> {
  return request<GenerationsResponse>(
    serverUrl,
    token,
    "/api/system/generations",
  );
}

export function getGenerationDiff(
  serverUrl: string,
  token: string,
  from: number,
  to: number,
): Promise<GenerationDiff> {
  return request<GenerationDiff>(
    serverUrl,
    token,
    withQuery("/api/system/generations/diff", { from, to }),
  );
}

export function startRebuild(
  serverUrl: string,
  token: string,
  action: string,
): Promise<Job> {
  return request<Job>(
    serverUrl,
    token,
    "/api/system/rebuild",
    postJson({ action }),
  );
}

export function requestPower(
  serverUrl: string,
  token: string,
  action: string,
): Promise<ActionResponse> {
  return request<ActionResponse>(
    serverUrl,
    token,
    "/api/system/power",
    postJson({ action }),
  );
}

export function getJobs(serverUrl: string, token: string): Promise<Job[]> {
  return request<Job[]>(serverUrl, token, "/api/jobs");
}

export function getJob(
  serverUrl: string,
  token: string,
  id: string,
): Promise<Job> {
  return request<Job>(
    serverUrl,
    token,
    `/api/jobs/${encodeURIComponent(id)}`,
  );
}

export function cancelJob(
  serverUrl: string,
  token: string,
  id: string,
): Promise<Job> {
  return request<Job>(
    serverUrl,
    token,
    `/api/jobs/${encodeURIComponent(id)}/cancel`,
    { method: "POST" },
  );
}

export function getLogs(
  serverUrl: string,
  token: string,
  lines: number,
): Promise<LogsResponse> {
  return request<LogsResponse>(
    serverUrl,
    token,
    withQuery("/api/logs", { lines }),
  );
}

export function getPeripherals(
  serverUrl: string,
  token: string,
): Promise<ProbeReport> {
  return request<ProbeReport>(serverUrl, token, "/api/peripherals");
}

export function getSessions(
  serverUrl: string,
  token: string,
  limit = 50,
): Promise<SessionsResponse> {
  return request<SessionsResponse>(
    serverUrl,
    token,
    withQuery("/api/sessions", { limit }),
  );
}

export function getSession(
  serverUrl: string,
  token: string,
  id: string,
  lines = 300,
): Promise<SessionDetail> {
  return request<SessionDetail>(
    serverUrl,
    token,
    withQuery(`/api/sessions/${encodeURIComponent(id)}`, { lines }),
  );
}

export const fetchPeripherals = getPeripherals;

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 401) {
      return "Token rejected. Check the API token.";
    }
    if (error.status === 403) {
      return error.message || "This action is disabled on the server.";
    }
    return error.message;
  }
  if (error instanceof TypeError) {
    return "Could not reach the server. Check the URL and network.";
  }
  if (error instanceof Error) {
    return error.message;
  }
  return "Unexpected error.";
}