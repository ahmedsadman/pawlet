import { describe, expect, it } from "vitest";
import { placeTooltip } from "./tooltipPosition";

const viewport = { width: 1024, height: 768 };
const tip = { width: 288, height: 100 };
const anchor = (left: number, top: number, size = 16) => ({
  left,
  top,
  width: size,
  height: size,
  right: left + size,
  bottom: top + size,
});

describe("placeTooltip", () => {
  it("centres below the anchor when there is room", () => {
    expect(placeTooltip(anchor(500, 100), tip, viewport)).toEqual({
      left: 364,
      top: 124,
      width: 288,
    });
  });

  it("clamps to the left edge", () => {
    expect(placeTooltip(anchor(20, 100), tip, viewport).left).toBe(8);
  });

  it("clamps to the right edge", () => {
    expect(placeTooltip(anchor(1010, 100), tip, viewport).left).toBe(1024 - 288 - 8);
  });

  it("flips above when there is no room below", () => {
    expect(placeTooltip(anchor(500, 700), tip, viewport).top).toBe(700 - 8 - 100);
  });

  it("stays below when there is no room above either", () => {
    expect(placeTooltip(anchor(500, 50), { width: 288, height: 740 }, viewport).top).toBe(74);
  });

  it("narrows to fit a small viewport", () => {
    expect(placeTooltip(anchor(100, 100), tip, { width: 300, height: 600 })).toMatchObject({
      left: 8,
      width: 284,
    });
  });
});
