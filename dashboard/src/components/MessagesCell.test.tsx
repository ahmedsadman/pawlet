import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MessagesCell } from "./MessagesCell";

describe("MessagesCell", () => {
  it("shows messages with LLM calls muted underneath", () => {
    render(<MessagesCell messages={1284} calls={37} hasStats />);
    expect(screen.getByText("1,284")).toBeInTheDocument();
    expect(screen.getByText("37 LLM")).toHaveClass("text-ctp-subtext0");
  });

  it("shows a dash but keeps the calls for installs without model stats", () => {
    render(<MessagesCell messages={0} calls={5} hasStats={false} />);
    expect(screen.getByText("—")).toBeInTheDocument();
    expect(screen.getByText("5 LLM")).toBeInTheDocument();
  });
});
