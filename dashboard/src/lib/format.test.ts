import { describe, expect, it } from "vitest";
import { fmtAgo, fmtCount, fmtDay, fmtDelta, fmtMs, fmtPercent, shortHash } from "./format";

describe("format", () => {
  it("formats counts compactly above 10k", () => {
    expect(fmtCount(0)).toBe("0");
    expect(fmtCount(9_999)).toBe("9,999");
    expect(fmtCount(12_900)).toBe("12.9K");
    expect(fmtCount(4_200_000)).toBe("4.2M");
  });
  it("formats percents and nulls", () => {
    expect(fmtPercent(0.982)).toBe("98.2%");
    expect(fmtPercent(0.5, 0)).toBe("50%");
    expect(fmtPercent(null)).toBe("—");
  });
  it("formats milliseconds", () => {
    expect(fmtMs(750)).toBe("750ms");
    expect(fmtMs(1604.5)).toBe("1.6s");
    expect(fmtMs(32000)).toBe("32s");
    expect(fmtMs(null)).toBe("—");
  });
  it("formats UTC days", () => {
    expect(fmtDay("2026-10-09")).toBe("Oct 9");
  });
  it("formats relative time", () => {
    const now = Date.UTC(2026, 9, 9, 12);
    expect(fmtAgo(now / 1000 - 30, now)).toBe("just now");
    expect(fmtAgo(now / 1000 - 3 * 3600, now)).toBe("3h ago");
    expect(fmtAgo(now / 1000 - 5 * 86400, now)).toBe("5d ago");
  });
  it("describes deltas against a previous period", () => {
    expect(fmtDelta(12, 10)).toEqual({ text: "+20%", up: true });
    expect(fmtDelta(5, 10)).toEqual({ text: "−50%", up: false });
    expect(fmtDelta(3, 0)).toEqual({ text: "new", up: true });
    expect(fmtDelta(0, 0)).toBeNull();
  });
  it("shortens hashes", () => {
    expect(shortHash("abcdef0123456789")).toBe("abcdef01");
  });
});
