import type { DayCounts, KeyCount } from "../api/types";
import { STATUS } from "../theme/tokens";

export interface OutcomeGroup {
  key: string;
  label: string;
  color: string;
  keys: string[];
}

/** Classify failures by kind. Status colors: their meaning is good/bad. */
export const CLASSIFY_FAILURES: OutcomeGroup[] = [
  {
    key: "limited",
    label: "Rate limited",
    color: STATUS.warning,
    keys: ["rate_limited_daily", "rate_limited_burst", "capacity"],
  },
  {
    key: "upstream",
    label: "Upstream error",
    color: STATUS.critical,
    keys: ["upstream_429", "upstream_retryable", "upstream_rejected"],
  },
  { key: "internal", label: "Internal", color: STATUS.serious, keys: ["internal"] },
  {
    key: "client",
    label: "Client error",
    color: STATUS.neutral,
    keys: ["unauthorized", "bad_request", "banned"],
  },
  { key: "cancelled", label: "Cancelled", color: STATUS.muted, keys: ["client_cancelled"] },
];

export const ATTEST_REASONS = [
  "device_integrity",
  "cert_mismatch",
  "app_not_recognized",
  "stale_token",
  "request_hash_mismatch",
  "package_mismatch",
  "attest_failed",
];

export const SESSION_FAILURES: OutcomeGroup[] = [
  { key: "rejected", label: "Attestation rejected", color: STATUS.critical, keys: ATTEST_REASONS },
  {
    key: "unavailable",
    label: "Google unavailable / internal",
    color: STATUS.serious,
    keys: ["attest_unavailable", "internal"],
  },
  {
    key: "challenge",
    label: "Challenge refused",
    color: STATUS.warning,
    keys: ["challenge_invalid", "challenge_rate_limited"],
  },
  { key: "client", label: "Client error", color: STATUS.neutral, keys: ["bad_request", "banned"] },
];

export function groupDaily(
  days: DayCounts[],
  groups: OutcomeGroup[],
): Record<string, number | string>[] {
  return days.map((d) => {
    const row: Record<string, number | string> = { day: d.day };
    for (const g of groups) row[g.key] = g.keys.reduce((sum, k) => sum + (d.counts[k] ?? 0), 0);
    return row;
  });
}

export function sumKeys(days: DayCounts[], keys: string[]): KeyCount[] {
  return keys
    .map((key) => ({ key, count: days.reduce((sum, d) => sum + (d.counts[key] ?? 0), 0) }))
    .filter((k) => k.count > 0)
    .sort((a, b) => b.count - a.count);
}
