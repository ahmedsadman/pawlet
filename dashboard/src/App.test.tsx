import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "./App";

function renderAt(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("auth flow", () => {
  it("sends a signed-out visitor to the login page", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue(
          new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }),
        ),
    );
    renderAt("/fleet");
    expect(await screen.findByRole("heading", { name: /pawlet admin/i })).toBeInTheDocument();
  });

  it("signs in and shows the shell", async () => {
    let signedIn = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        if (url === "/api/login") {
          signedIn = true;
          return new Response(null, { status: 204 });
        }
        if (url === "/api/me") return new Response(null, { status: signedIn ? 204 : 401 });
        return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
      }),
    );
    const user = userEvent.setup();
    renderAt("/login");
    await user.type(await screen.findByLabelText(/password/i), "pw");
    await user.click(screen.getByRole("button", { name: /sign in/i }));
    await waitFor(() =>
      expect(screen.getByRole("navigation", { name: /main/i })).toBeInTheDocument(),
    );
  });

  it("shows a wrong-password message", async () => {
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue(
          new Response(JSON.stringify({ error: "invalid_password" }), { status: 401 }),
        ),
    );
    const user = userEvent.setup();
    renderAt("/login");
    await user.type(await screen.findByLabelText(/password/i), "nope");
    await user.click(screen.getByRole("button", { name: /sign in/i }));
    expect(await screen.findByText(/wrong password/i)).toBeInTheDocument();
  });
});
