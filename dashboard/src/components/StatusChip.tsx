import type { InstallRow } from "../api/types";

export function StatusChip({ row }: { row: Pick<InstallRow, "banned" | "dormant"> }) {
  const [label, cls] = row.banned
    ? ["Banned", "bg-ctp-red/15 text-ctp-red ring-ctp-red/30"]
    : row.dormant
      ? ["Dormant", "bg-ctp-overlay0/15 text-ctp-subtext0 ring-ctp-overlay0/30"]
      : ["Active", "bg-ctp-green/15 text-ctp-green ring-ctp-green/30"];
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${cls}`}>
      {label}
    </span>
  );
}
