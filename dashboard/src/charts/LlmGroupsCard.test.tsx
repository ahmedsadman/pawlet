import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { KeyCount } from "../api/types";
import { LlmGroupsCard } from "./LlmGroupsCard";

describe("LlmGroupsCard", () => {
  it("renders labels with their counts", () => {
    const items: KeyCount[] = [
      { key: "on", count: 100 },
      { key: "off", count: 20 },
      { key: "byok", count: 5 },
      { key: "none", count: 10 },
      { key: "unknown", count: 15 },
    ];
    render(<LlmGroupsCard items={items} />);
    expect(screen.getByRole("heading", { name: /llm setting/i })).toBeInTheDocument();
    expect(screen.getByText("LLM on")).toBeInTheDocument();
    expect(screen.getByText("Turned off")).toBeInTheDocument();
    expect(screen.getByText("Own key")).toBeInTheDocument();
    expect(screen.getByText("No LLM")).toBeInTheDocument();
    expect(screen.getByText("Unknown")).toBeInTheDocument();
  });

  it("shows empty text when all counts are zero", () => {
    const items: KeyCount[] = [
      { key: "on", count: 0 },
      { key: "off", count: 0 },
      { key: "byok", count: 0 },
      { key: "none", count: 0 },
      { key: "unknown", count: 0 },
    ];
    render(<LlmGroupsCard items={items} />);
    expect(screen.getByText(/no data yet/i)).toBeInTheDocument();
  });
});
