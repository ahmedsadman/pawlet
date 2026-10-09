import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { InfoTip } from "./InfoTip";
import { statCopy } from "../copy/stats";

describe("InfoTip", () => {
  it("opens on focus, links the tooltip, and closes on Escape", async () => {
    const user = userEvent.setup();
    render(<InfoTip id="attestedInstalls" />);
    const button = screen.getByRole("button", { name: /about attested installs/i });
    await user.tab();
    expect(button).toHaveFocus();
    const tip = screen.getByRole("tooltip");
    expect(tip).toHaveTextContent(statCopy.attestedInstalls.meaning);
    expect(button).toHaveAttribute("aria-describedby", tip.id);
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("opens on tap and closes on an outside tap", () => {
    render(
      <div>
        <InfoTip id="dau.any" />
        <p>outside</p>
      </div>,
    );
    fireEvent.click(screen.getByRole("button"));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.pointerDown(screen.getByText("outside"));
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("shows the caveat when there is one", () => {
    render(<InfoTip id="dau.any" />);
    fireEvent.click(screen.getByRole("button"));
    expect(screen.getByRole("tooltip")).toHaveTextContent(statCopy["dau.any"].caveat!);
  });
});
