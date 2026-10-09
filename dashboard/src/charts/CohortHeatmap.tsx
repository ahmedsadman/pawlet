import type { CSSProperties } from "react";
import type { Cohort } from "../api/types";
import { fmtDay, fmtPercent } from "../lib/format";
import { SEQUENTIAL, ctp } from "../theme/tokens";

export function cellStyle(v: number | null): CSSProperties {
  if (v === null) return {};
  if (v === 0) return { backgroundColor: ctp.surface1, color: ctp.subtext0 };
  const idx = Math.min(SEQUENTIAL.length - 1, Math.floor(v * SEQUENTIAL.length));
  // The lighter steps need dark text to keep contrast.
  return { backgroundColor: SEQUENTIAL[idx], color: idx >= 3 ? ctp.crust : ctp.text };
}

export function CohortHeatmap({ cohorts }: { cohorts: Cohort[] }) {
  const weeks = cohorts[0]?.retention.length ?? 13;
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-separate border-spacing-0.5 text-xs">
        <thead>
          <tr className="text-ctp-subtext0">
            <th scope="col" className="pr-2 text-left font-medium">
              Week of
            </th>
            <th scope="col" className="pr-2 text-right font-medium">
              Installs
            </th>
            {Array.from({ length: weeks }, (_, n) => (
              <th key={n} scope="col" className="min-w-10 text-center font-medium">
                W{n}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {cohorts.map((c) => (
            <tr key={c.weekStart}>
              <th
                scope="row"
                className="pr-2 text-left font-normal whitespace-nowrap text-ctp-subtext1"
              >
                {fmtDay(c.weekStart)}
              </th>
              <td className="tabular pr-2 text-right text-ctp-text">{c.size}</td>
              {c.retention.map((v, n) => (
                <td
                  key={n}
                  title={`${fmtDay(c.weekStart)} cohort, week ${n}: ${v === null ? "not reached yet" : `${fmtPercent(v, 0)} active`}`}
                  className="tabular h-7 rounded text-center"
                  style={cellStyle(v)}
                >
                  {v === null ? "" : fmtPercent(v, 0)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
