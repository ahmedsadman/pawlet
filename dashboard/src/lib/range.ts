import { useSearchParams } from "react-router";
import type { RangeKey } from "../api/types";

export const RANGES: { key: RangeKey; label: string }[] = [
  { key: "7d", label: "7d" },
  { key: "30d", label: "30d" },
  { key: "90d", label: "90d" },
  { key: "all", label: "All" },
];

const DEFAULT: RangeKey = "30d";

/** The page's range lives in ?range= so views are linkable. */
export function useRange(): [RangeKey, (r: RangeKey) => void] {
  const [params, setParams] = useSearchParams();
  const raw = params.get("range");
  const range = RANGES.some((r) => r.key === raw) ? (raw as RangeKey) : DEFAULT;
  const setRange = (r: RangeKey) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        if (r === DEFAULT) next.delete("range");
        else next.set("range", r);
        return next;
      },
      { replace: true },
    );
  return [range, setRange];
}
