import type {
  ActiveMode,
  EngagementResponse,
  FleetResponse,
  InstallDetailResponse,
  InstallsQuery,
  InstallsResponse,
  OverviewResponse,
  RangeKey,
  ReliabilityResponse,
} from "./types";

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) {
    super(`${status} ${code}`);
    this.status = status;
    this.code = code;
  }
}

/** Fired on any 401 outside login, so the app can send the user to sign in. */
export const UNAUTHORIZED_EVENT = "pawlet:unauthorized";

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = init.body ? { "Content-Type": "application/json" } : {};
  const res = await fetch(path, { credentials: "same-origin", ...init, headers });
  if (res.status === 401 && path !== "/api/login") {
    window.dispatchEvent(new Event(UNAUTHORIZED_EVENT));
  }
  if (!res.ok) {
    let code = "error";
    try {
      code = ((await res.json()) as { error?: string }).error ?? code;
    } catch {
      // Non-JSON error body; keep the generic code.
    }
    throw new ApiError(res.status, code);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

function post<T>(path: string, body: unknown): Promise<T> {
  return request<T>(path, { method: "POST", body: JSON.stringify(body) });
}

function query(params: Record<string, string | number | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== "") q.set(k, String(v));
  }
  const s = q.toString();
  return s ? `?${s}` : "";
}

export const api = {
  login: (password: string) => post<void>("/api/login", { password }),
  logout: () => post<void>("/api/logout", {}),
  me: async () => {
    await request<void>("/api/me");
    return true;
  },
  overview: (range: RangeKey) => request<OverviewResponse>(`/api/overview${query({ range })}`),
  installs: (q: InstallsQuery) =>
    request<InstallsResponse>(
      `/api/installs${query({ sort: q.sort, order: q.order, q: q.q, status: q.status, page: q.page })}`,
    ),
  install: (hash: string) => request<InstallDetailResponse>(`/api/installs/${hash}`),
  ban: (hash: string, reason: string) => post<void>(`/api/installs/${hash}/ban`, { reason }),
  unban: (hash: string) => post<void>(`/api/installs/${hash}/unban`, {}),
  engagement: (range: RangeKey, active: ActiveMode) =>
    request<EngagementResponse>(`/api/engagement${query({ range, active })}`),
  reliability: (range: RangeKey) =>
    request<ReliabilityResponse>(`/api/reliability${query({ range })}`),
  fleet: () => request<FleetResponse>("/api/fleet"),
};
