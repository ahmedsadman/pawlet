import type { KeyCount } from "../api/types";
import { fmtCount, fmtPercent } from "../lib/format";
import { OTHER, SERIES } from "../theme/tokens";

/** Horizontal bars for a single breakdown. One series: one colour, "unknown" in grey. */
export function BarList({
  items,
  labelFor = (k) => k,
  color = SERIES[0],
  empty = "No data yet.",
}: {
  items: KeyCount[];
  labelFor?: (key: string) => string;
  color?: string;
  empty?: string;
}) {
  if (items.length === 0) return <p className="text-sm text-ctp-subtext0">{empty}</p>;
  const max = Math.max(...items.map((i) => i.count));
  const total = items.reduce((s, i) => s + i.count, 0);
  return (
    <ul className="space-y-2.5">
      {items.map((i) => {
        const label = labelFor(i.key);
        return (
          <li
            key={i.key}
            title={`${label}: ${i.count.toLocaleString("en")} (${fmtPercent(i.count / total)})`}
            className="grid grid-cols-[minmax(0,9rem)_1fr_auto] items-center gap-3 text-sm"
          >
            <span className="truncate text-ctp-subtext1">{label}</span>
            <span className="h-2.5 overflow-hidden rounded-r bg-ctp-surface1/40">
              <span
                className="block h-full rounded-r"
                style={{
                  width: `${(i.count / max) * 100}%`,
                  backgroundColor: i.key === "unknown" ? OTHER : color,
                }}
              />
            </span>
            <span className="tabular text-right text-ctp-text">
              {fmtCount(i.count)}{" "}
              <span className="text-ctp-subtext0">{fmtPercent(i.count / total, 0)}</span>
            </span>
          </li>
        );
      })}
    </ul>
  );
}
