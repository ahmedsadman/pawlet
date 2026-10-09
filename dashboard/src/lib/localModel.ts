import type { LocalModel } from "../api/types";
import { fmtCount } from "./format";

/** Whole-percent on-device rate; "—" when undefined. */
export function fmtRate(rate: number | null): string {
  return rate == null ? "—" : `${Math.round(rate * 100)}%`;
}

export type Tone = "up" | "down" | "flat";

/**
 * Change against the previous period in percentage points, taken from the
 * rounded percents on screen so the two always agree. null when either side
 * is missing.
 */
export function fmtPointDelta(
  rate: number | null,
  prev: number | null,
): { text: string; tone: Tone } | null {
  if (rate == null || prev == null) return null;
  const pts = Math.round(rate * 100) - Math.round(prev * 100);
  const n = Math.abs(pts);
  const unit = n === 1 ? "pt" : "pts";
  if (pts > 0) return { text: `▲ ${n} ${unit}`, tone: "up" };
  if (pts < 0) return { text: `▼ ${n} ${unit}`, tone: "down" };
  return { text: "0 pts", tone: "flat" };
}

/** The rate's two sides: accepted on device, declined to the LLM. */
export function fmtSplit(accepted: number, declined: number): string {
  return `${fmtCount(accepted)} on device · ${fmtCount(declined)} LLM`;
}

/** Model errors are counted but not in the rate; null when there were none. */
export function fmtModelErrors(unavailable: number): string | null {
  if (unavailable <= 0) return null;
  return `${fmtCount(unavailable)} model ${unavailable === 1 ? "error" : "errors"} (not in %)`;
}

/** Arc length for rate on a ring of the given circumference; 0 without a rate. */
export function ringArc(rate: number | null, circumference: number): number {
  if (rate == null) return 0;
  return Math.min(1, Math.max(0, rate)) * circumference;
}

export interface LocalModelRow {
  day: string;
  rolling: number | null;
  daily: number | null;
  accepted: number;
  declined: number;
}

/** One chart row per day: the rolling rate, the day's rate and its counts. */
export function localModelRows(lm: LocalModel): LocalModelRow[] {
  const rolling = new Map(lm.rolling7.map((r) => [r.day, r.rate]));
  return lm.daily.map((d) => ({
    day: d.day,
    rolling: rolling.get(d.day) ?? null,
    daily: d.rate,
    accepted: d.accepted,
    declined: d.declined,
  }));
}

/** Tooltip line for one day: "81% · 40 on device / 9 LLM". */
export function fmtDayDetail(row: Pick<LocalModelRow, "daily" | "accepted" | "declined">): string {
  return `${fmtRate(row.daily)} · ${fmtCount(row.accepted)} on device / ${fmtCount(row.declined)} LLM`;
}

/**
 * Reliability footer. "Via LLM" is everything the model did not accept:
 * declined messages and model errors both go on to the LLM.
 */
export function fmtReliabilityFooter(lm: LocalModel, successfulCalls: number): string {
  const messages = lm.accepted + lm.declined + lm.unavailable;
  const viaLlm = lm.declined + lm.unavailable;
  return `${fmtCount(messages)} messages classified (${fmtCount(lm.accepted)} on device, ${fmtCount(viaLlm)} via LLM) · ${fmtCount(successfulCalls)} successful LLM calls`;
}
