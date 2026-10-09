import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { BanDialog } from "./BanDialog";

describe("BanDialog", () => {
  it("requires a reason and confirms with it trimmed", async () => {
    const user = userEvent.setup();
    const onConfirm = vi.fn();
    render(
      <BanDialog hash={"a".repeat(64)} onClose={() => {}} onConfirm={onConfirm} pending={false} />,
    );
    const confirm = screen.getByRole("button", { name: /ban install/i });
    expect(confirm).toBeDisabled();
    await user.type(screen.getByLabelText(/reason/i), "   ");
    expect(confirm).toBeDisabled();
    await user.type(screen.getByLabelText(/reason/i), "scripted calls  ");
    expect(confirm).toBeEnabled();
    await user.click(confirm);
    expect(onConfirm).toHaveBeenCalledWith("scripted calls");
  });

  it("rejects reasons over 200 characters", async () => {
    const user = userEvent.setup();
    render(
      <BanDialog hash={"a".repeat(64)} onClose={() => {}} onConfirm={() => {}} pending={false} />,
    );
    await user.click(screen.getByLabelText(/reason/i));
    await user.paste("x".repeat(201));
    expect(screen.getByRole("button", { name: /ban install/i })).toBeDisabled();
    expect(screen.getByText(/201 \/ 200/)).toBeInTheDocument();
  });

  it("closes on Escape and Cancel", async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    render(
      <BanDialog hash={"a".repeat(64)} onClose={onClose} onConfirm={() => {}} pending={false} />,
    );
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
