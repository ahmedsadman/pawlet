import type { ReactNode } from "react";
import type { StatId } from "../copy/stats";
import { InfoTip } from "./InfoTip";

export function StatTile({
  label,
  statId,
  value,
  sub,
  delta,
}: {
  label: string;
  statId: StatId;
  value: string;
  sub?: ReactNode;
  delta?: { text: string; up: boolean } | null;
}) {
  return (
    <div className="rounded-xl bg-ctp-surface0 p-4 ring-1 ring-ctp-surface1/40">
      <div className="flex items-center gap-1.5 text-xs font-medium tracking-wide text-ctp-subtext0 uppercase">
        {label}
        <InfoTip id={statId} />
      </div>
      <div className="mt-1.5 text-2xl font-semibold text-ctp-text">{value}</div>
      {(sub || delta) && (
        <div className="mt-1 flex items-center gap-2 text-xs text-ctp-subtext0">
          {delta && (
            <span className={delta.up ? "text-ctp-green" : "text-ctp-red"}>
              {delta.up ? "▲" : "▼"} {delta.text}
            </span>
          )}
          {sub}
        </div>
      )}
    </div>
  );
}
