import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { CohortHeatmap, cellStyle } from "./CohortHeatmap";
import { SEQUENTIAL, ctp } from "../theme/tokens";

describe("CohortHeatmap", () => {
  it("labels cells with percentages and leaves future weeks blank", () => {
    render(
      <CohortHeatmap
        cohorts={[
          { weekStart: "2026-10-05", size: 4, retention: [1, 0.5, null, ...Array(10).fill(null)] },
        ]}
      />,
    );
    expect(screen.getByText("100%")).toBeInTheDocument();
    expect(screen.getByText("50%")).toBeInTheDocument();
    expect(screen.getByTitle(/week 2: not reached yet/i)).toBeInTheDocument();
  });
  it("maps shares onto the sequential ramp", () => {
    expect(cellStyle(0).backgroundColor).toBe(ctp.surface1);
    expect(cellStyle(0.05).backgroundColor).toBe(SEQUENTIAL[0]);
    expect(cellStyle(1).backgroundColor).toBe(SEQUENTIAL[4]);
  });
});
