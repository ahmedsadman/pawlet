export type RangeKey = "7d" | "30d" | "90d" | "all";
export type ActiveMode = "any" | "classify";

export interface Range {
  from: string;
  to: string;
}
export interface CollectingSince {
  sessions: string | null;
  counters: string | null;
}
export interface ServerInfo {
  dailyPerInstall: number;
  burstPerMin: number;
  globalDailyCap: number;
  models: string[];
  startedAt: number;
  imageTag: string;
}
export interface Bucket {
  label: string;
  count: number;
}

export interface OverviewResponse {
  range: Range;
  kpis: {
    attestedInstalls: number;
    banned: number;
    newInstalls: number;
    newInstallsPrev: number;
    dau: number;
    wau: number;
    mau: number;
    callsToday: number;
    tokensToday: number;
    successRateToday: number | null;
    callsPerActiveInstallDay: number | null;
    messagesPerActiveInstallDay: number | null;
  };
  daily: {
    day: string;
    calls: number;
    messages: number;
    tokens: number;
    activeInstalls: number;
    newInstalls: number;
  }[];
  server: ServerInfo;
  collectingSince: CollectingSince;
}

export interface InstallRow {
  hash: string;
  firstSeen: number;
  lastSeen: number;
  lastActiveDay: string;
  appVersionCode: number | null;
  deviceTier: string | null;
  licensing: string | null;
  sdkVersion: number | null;
  callsToday: number;
  calls7d: number;
  callsTotal: number;
  messagesToday: number;
  messages7d: number;
  messagesTotal: number;
  hasModelStats: boolean;
  tokensTotal: number;
  quotaHitDays: number;
  banned: boolean;
  banReason: string;
  dormant: boolean;
}
export interface InstallsResponse {
  rows: InstallRow[];
  total: number;
  page: number;
  pageSize: number;
}
export interface InstallsQuery {
  sort?: string;
  order?: "asc" | "desc";
  q?: string;
  status?: string;
  page?: number;
}
export interface InstallDetailResponse {
  install: InstallRow;
  daily: {
    day: string;
    calls: number;
    tokens: number;
    session: boolean;
    /** null outside the last 90 days and for installs that never reported model stats. */
    messages: number | null;
    onDevice: number | null;
  }[];
}

export interface ActiveCount {
  day: string;
  dau: number;
  wau: number;
  mau: number;
  stickiness: number;
}
export interface Cohort {
  weekStart: string;
  size: number;
  retention: (number | null)[];
}
export interface EngagementResponse {
  range: Range;
  mode: ActiveMode;
  daily: ActiveCount[];
  cohorts: Cohort[];
  messagesDistribution: Bucket[];
  dormant: number;
  collectingSince: CollectingSince;
}

export interface DayCounts {
  day: string;
  counts: Record<string, number>;
}
export interface DayValue {
  day: string;
  value: number | null;
}
export interface KeyCount {
  key: string;
  count: number;
}
export interface ModelDay {
  day: string;
  accepted: number;
  declined: number;
  unavailable: number;
  rate: number | null;
}
export interface LocalModel {
  accepted: number;
  declined: number;
  unavailable: number;
  rate: number | null;
  prevRate: number | null;
  daily: ModelDay[];
  rolling7: { day: string; rate: number | null }[];
  versionMarkers: { day: string; appVersionCode: number }[];
}
export interface ReliabilityResponse {
  range: Range;
  classifyOutcomes: DayCounts[];
  sessionOutcomes: DayCounts[];
  successRate: DayValue[];
  latency: { day: string; p50: number | null; p95: number | null; count: number }[];
  models: KeyCount[];
  categories: DayCounts[];
  tokensPerCall: DayValue[];
  localModel: LocalModel;
  collectingSince: CollectingSince;
}

export interface FleetResponse {
  activeInstalls: number;
  versions: KeyCount[];
  deviceTier: KeyCount[];
  licensing: KeyCount[];
  sdk: KeyCount[];
  adoption: DayCounts[];
  collectingSince: CollectingSince;
}
