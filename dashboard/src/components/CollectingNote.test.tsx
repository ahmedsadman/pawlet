import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { CollectingNote } from "./CollectingNote";

describe("CollectingNote", () => {
  it("explains missing history when collection started inside the range", () => {
    render(<CollectingNote since="2026-10-01" rangeFrom="2026-09-10" />);
    expect(screen.getByText(/collecting since oct 1/i)).toBeInTheDocument();
  });
  it("says nothing when history covers the range", () => {
    const { container } = render(<CollectingNote since="2026-09-01" rangeFrom="2026-09-10" />);
    expect(container).toBeEmptyDOMElement();
  });
  it("says no data yet when nothing has been collected", () => {
    render(<CollectingNote since={null} rangeFrom="2026-09-10" />);
    expect(screen.getByText(/no data collected yet/i)).toBeInTheDocument();
  });
});
