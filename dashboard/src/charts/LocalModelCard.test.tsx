import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { LocalModel } from "../api/types";
import { LocalModelCard, LocalModelSummary } from "./LocalModelCard";

const base: LocalModel = {
  accepted: 0,
  declined: 0,
  unavailable: 0,
  rate: null,
  prevRate: null,
  daily: [],
  rolling7: [],
  versionMarkers: [],
};

describe("LocalModelSummary", () => {
  it("shows the rate, its change in points and the counts behind it", () => {
    render(
      <LocalModelSummary
        lm={{ ...base, accepted: 81, declined: 19, unavailable: 3, rate: 0.81, prevRate: 0.72 }}
      />,
    );
    expect(screen.getByText("81%")).toBeInTheDocument();
    expect(screen.getByText(/▲ 9 pts/)).toBeInTheDocument();
    expect(screen.getByText("81 on device · 19 LLM")).toBeInTheDocument();
    expect(screen.getByText("3 model errors (not in %)")).toBeInTheDocument();
  });

  it("shows a dash and an empty track when there is no rate", () => {
    const { container } = render(<LocalModelSummary lm={{ ...base, prevRate: 0.7 }} />);
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.queryByText(/pts/)).not.toBeInTheDocument();
    expect(screen.queryByText(/model error/)).not.toBeInTheDocument();
    expect(container.querySelectorAll("circle")).toHaveLength(1);
  });
});

describe("LocalModelCard", () => {
  it("says there is nothing to plot when the range has no message counts", () => {
    render(<LocalModelCard lm={base} />);
    expect(screen.getByRole("heading", { name: /local model/i })).toBeInTheDocument();
    expect(screen.getByText(/no message counts in this range/i)).toBeInTheDocument();
  });
});
