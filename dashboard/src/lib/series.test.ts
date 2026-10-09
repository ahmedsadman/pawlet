import { describe, expect, it } from "vitest";
import { topVersionSeries } from "./series";
import { OTHER, SERIES } from "../theme/tokens";

describe("topVersionSeries", () => {
  it("keeps the five most common versions, newest first, and folds the rest", () => {
    const adoption = [
      { day: "d1", counts: { "18": 10, "17": 8, "16": 5, "15": 3, "14": 2, "13": 1, unknown: 4 } },
    ];
    const { series, rows } = topVersionSeries(adoption, 5);
    expect(series.map((s) => s.key)).toEqual(["18", "17", "16", "15", "unknown", "other"]);
    expect(series[0].color).toBe(SERIES[0]);
    expect(series.find((s) => s.key === "unknown")!.color).toBe(OTHER);
    expect(rows[0]).toMatchObject({ day: "d1", "18": 10, other: 3 });
  });
});
