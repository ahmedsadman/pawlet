const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const plain = new Intl.NumberFormat("en");

/** 1,284 below ten thousand, 12.9K / 4.2M above. */
export function fmtCount(n: number): string {
  return Math.abs(n) < 10_000 ? plain.format(Math.round(n)) : compact.format(n);
}

export function fmtPercent(v: number | null | undefined, digits = 1): string {
  return v == null ? "—" : `${(v * 100).toFixed(digits)}%`;
}

export function fmtMs(ms: number | null | undefined): string {
  if (ms == null) return "—";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  const s = ms / 1000;
  return s >= 10 ? `${Math.round(s)}s` : `${s.toFixed(1)}s`;
}

/** "2026-10-09" → "Oct 9", always in UTC so days match the server. */
export function fmtDay(day: string): string {
  return new Date(`${day}T00:00:00Z`).toLocaleDateString("en", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

export function fmtDateTime(unix: number): string {
  return new Date(unix * 1000).toLocaleString("en", { dateStyle: "medium", timeStyle: "short" });
}

export function fmtAgo(unix: number, nowMs: number = Date.now()): string {
  const s = Math.max(0, nowMs / 1000 - unix);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

/** Change versus a previous period; null when both are zero. */
export function fmtDelta(current: number, previous: number): { text: string; up: boolean } | null {
  if (previous === 0) return current === 0 ? null : { text: "new", up: true };
  const change = (current - previous) / previous;
  const pct = Math.round(Math.abs(change) * 100);
  return { text: `${change >= 0 ? "+" : "−"}${pct}%`, up: change >= 0 };
}

export function shortHash(hash: string): string {
  return hash.slice(0, 8);
}
