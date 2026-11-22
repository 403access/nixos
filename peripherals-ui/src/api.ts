import type { HealthResponse, ProbeReport } from "./types";

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

async function request<T>(serverUrl: string, token: string, path: string): Promise<T> {
  const response = await fetch(`${normalizeBase(serverUrl)}${path}`, {
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
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

export function checkHealth(serverUrl: string, token: string): Promise<HealthResponse> {
  return request<HealthResponse>(serverUrl, token, "/api/health");
}

export function fetchPeripherals(serverUrl: string, token: string): Promise<ProbeReport> {
  return request<ProbeReport>(serverUrl, token, "/api/peripherals");
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 401) {
      return "Token rejected. Check the API token.";
    }
    if (error.status === 403) {
      return "This token is not allowed to read peripherals.";
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