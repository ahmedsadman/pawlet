import { describe, expect, it } from "vitest";
import type { LocalModel } from "../api/types";
import {
  fmtDayDetail,
  fmtModelErrors,
  fmtPointDelta,
  fmtRate,
  fmtReliabilityFooter,
  fmtSplit,
  localModelRows,
  ringArc,
} from "./localModel";

const empty: LocalModel = {
  accepted: 0,
  declined: 0,
  unavailable: 0,
  rate: null,
  prevRate: null,
  daily: [],
  rolling7: [],
  versionMarkers: [],
};

describe("local model formatting", () => {
  it("shows the rate as a whole percent, or a dash", () => {
    expect(fmtRate(0.814)).toBe("81%");
    expect(fmtRate(0)).toBe("0%");
    expect(fmtRate(null)).toBe("—");
  });

  it("measures the change in points between the percents shown", () => {
    expect(fmtPointDelta(0.81, 0.72)).toEqual({ text: "▲ 9 pts", tone: "up" });
    expect(fmtPointDelta(0.7, 0.73)).toEqual({ text: "▼ 3 pts", tone: "down" });
    expect(fmtPointDelta(0.806, 0.796)).toEqual({ text: "▲ 1 pt", tone: "up" });
    expect(fmtPointDelta(0.8, 0.801)).toEqual({ text: "0 pts", tone: "flat" });
    expect(fmtPointDelta(null, 0.7)).toBeNull();
    expect(fmtPointDelta(0.7, null)).toBeNull();
  });

  it("splits counts and notes model errors only when there are some", () => {
    expect(fmtSplit(12_900, 1_284)).toBe("12.9K on device · 1,284 LLM");
    expect(fmtModelErrors(0)).toBeNull();
    expect(fmtModelErrors(1)).toBe("1 model error (not in %)");
    expect(fmtModelErrors(3)).toBe("3 model errors (not in %)");
  });

  it("sizes the ring arc and leaves it empty without a rate", () => {
    expect(ringArc(0.5, 200)).toBe(100);
    expect(ringArc(null, 200)).toBe(0);
    expect(ringArc(1.2, 200)).toBe(200);
  });

  it("joins daily rates with the rolling line by day", () => {
    const lm: LocalModel = {
      ...empty,
      daily: [
        { day: "2026-10-01", accepted: 0, declined: 0, unavailable: 0, rate: null },
        { day: "2026-10-02", accepted: 9, declined: 3, unavailable: 0, rate: 0.75 },
      ],
      rolling7: [
        { day: "2026-10-01", rate: 0.7 },
        { day: "2026-10-02", rate: 0.74 },
      ],
    };
    expect(localModelRows(lm)).toEqual([
      { day: "2026-10-01", rolling: 0.7, daily: null, accepted: 0, declined: 0 },
      { day: "2026-10-02", rolling: 0.74, daily: 0.75, accepted: 9, declined: 3 },
    ]);
  });

  it("describes one day for the tooltip", () => {
    expect(fmtDayDetail({ daily: 0.81, accepted: 40, declined: 9 })).toBe(
      "81% · 40 on device / 9 LLM",
    );
    expect(fmtDayDetail({ daily: null, accepted: 0, declined: 0 })).toBe("— · 0 on device / 0 LLM");
  });

  it("writes the footer with messages split by where they were classified", () => {
    const lm: LocalModel = { ...empty, accepted: 900, declined: 80, unavailable: 20 };
    expect(fmtReliabilityFooter(lm, 95)).toBe(
      "1,000 messages classified (900 on device, 100 via LLM) · 95 successful LLM calls",
    );
  });
});
