import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import InstallsPage from "./InstallsPage";

function renderInstallsPage(initialUrl = "/installs") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialUrl]}>
        <InstallsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("InstallsPage", () => {
  it("renders install hash as a keyboard-accessible link", async () => {
    const mockHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            rows: [
              {
                hash: mockHash,
                firstSeen: "2024-01-01T00:00:00Z",
                lastSeen: "2024-01-02T00:00:00Z",
                appVersionCode: 1,
                deviceTier: "mid",
                callsToday: 5,
                calls7d: 35,
                callsTotal: 100,
                tokensTotal: 5000,
                quotaHitDays: 0,
                isBanned: false,
                isDormant: false,
              },
            ],
            total: 1,
            page: 1,
            pageSize: 50,
          }),
          { status: 200 },
        ),
      ),
    );

    renderInstallsPage();

    const link = await screen.findByRole("link", { name: /012345/i });
    expect(link).toHaveAttribute("href", `/installs/${mockHash}`);
  });

  it("falls back to lastSeen for an unknown sort parameter", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ rows: [], total: 0, page: 1, pageSize: 50 }), {
        status: 200,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    renderInstallsPage("/installs?sort=bogus");

    await screen.findByText(/No installs match/i);
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringMatching(/\/api\/installs\?.*sort=lastSeen/),
      expect.any(Object),
    );
  });
});
