import { STATUS } from "../theme/tokens";

/** Share of a cap used. The fill turns warning at 70% and critical at 90%. */
export function Meter({ value, max, label }: { value: number; max: number; label: string }) {
  const share = max > 0 ? Math.min(1, value / max) : 0;
  const color = share >= 0.9 ? STATUS.critical : share >= 0.7 ? STATUS.warning : STATUS.good;
  return (
    <div
      role="meter"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={max}
      aria-valuenow={value}
      className="mt-2 h-1.5 overflow-hidden rounded-full bg-ctp-surface1"
    >
      <div
        className="h-full rounded-full"
        style={{ width: `${share * 100}%`, backgroundColor: color }}
      />
    </div>
  );
}
