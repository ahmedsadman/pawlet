import type { DayCounts } from "../api/types";
import type { Series } from "../charts/TimeSeriesChart";
import { OTHER, SERIES } from "../theme/tokens";

/**
 * The n most common versions over the period become series, coloured newest
 * first so a version keeps its colour while the range changes; "unknown" and
 * everything else fold into grey buckets.
 */
export function topVersionSeries(adoption: DayCounts[], n = 5) {
  const totals = new Map<string, number>();
  for (const d of adoption)
    for (const [k, v] of Object.entries(d.counts)) totals.set(k, (totals.get(k) ?? 0) + v);

  const versions = [...totals.keys()].filter((k) => k !== "unknown");
  const top = versions
    .sort((a, b) => totals.get(b)! - totals.get(a)! || Number(b) - Number(a))
    .slice(0, n - (totals.has("unknown") ? 1 : 0))
    .sort((a, b) => Number(b) - Number(a));

  const series: Series[] = top.map((k, i) => ({
    key: k,
    label: `v${k}`,
    color: SERIES[i % SERIES.length],
  }));
  if (totals.has("unknown")) series.push({ key: "unknown", label: "unknown", color: OTHER });
  const hasOther = versions.length > top.length;
  if (hasOther) series.push({ key: "other", label: "Other", color: "#5b6078" });

  const keep = new Set(series.map((s) => s.key));
  const rows = adoption.map((d) => {
    const row: Record<string, number | string> = { day: d.day };
    for (const s of series) row[s.key] = 0;
    for (const [k, v] of Object.entries(d.counts)) {
      const target = keep.has(k) ? k : "other";
      row[target] = (row[target] as number) + v;
    }
    return row;
  });
  return { series, rows };
}
