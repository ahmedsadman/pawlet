import { fmtDay } from "../lib/format";

interface Item {
  name?: string | number;
  value?: number | string | readonly (number | string)[] | null;
  color?: string;
  dataKey?: string | number | ((obj: unknown) => unknown);
}

/** Tooltip body shared by every Recharts chart. Text stays in text colours; a swatch carries identity. */
export function ChartTooltip({
  active,
  payload,
  label,
  format,
  labelFormat = fmtDay,
}: {
  active?: boolean;
  payload?: readonly Item[];
  label?: string | number;
  format: (v: number) => string;
  labelFormat?: (label: string) => string;
}) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg bg-ctp-mantle px-3 py-2 text-xs shadow-xl ring-1 ring-ctp-surface1">
      <div className="mb-1 font-medium text-ctp-subtext1">{labelFormat(String(label))}</div>
      {[...payload].reverse().map((p) => (
        <div key={String(p.dataKey)} className="flex items-center justify-between gap-4">
          <span className="flex items-center gap-1.5 text-ctp-subtext0">
            <span className="size-2 rounded-sm" style={{ backgroundColor: p.color }} aria-hidden />
            {p.name}
          </span>
          <span className="tabular text-ctp-text">
            {typeof p.value === "number" ? format(p.value) : "—"}
          </span>
        </div>
      ))}
    </div>
  );
}
