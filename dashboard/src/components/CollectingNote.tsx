import { fmtDay } from "../lib/format";

/** Shown on cards whose data only exists since the capture deploy. */
export function CollectingNote({ since, rangeFrom }: { since: string | null; rangeFrom: string }) {
  if (since === null) {
    return <p className="mb-2 text-xs text-ctp-subtext0">No data collected yet.</p>;
  }
  if (since <= rangeFrom) return null;
  return <p className="mb-2 text-xs text-ctp-subtext0">Collecting since {fmtDay(since)}.</p>;
}
