import { afterEach, describe, expect, it, vi } from "vitest";
import { api, ApiError, UNAUTHORIZED_EVENT } from "./client";

function mockFetch(status: number, body?: unknown) {
  const fn = vi.fn().mockResolvedValue(
    new Response(body === undefined ? null : JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    }),
  );
  vi.stubGlobal("fetch", fn);
  return fn;
}

afterEach(() => vi.unstubAllGlobals());

describe("api client", () => {
  it("parses JSON responses", async () => {
    mockFetch(200, { rows: [], total: 0, page: 1, pageSize: 50 });
    await expect(api.installs({ status: "dormant", page: 2 })).resolves.toMatchObject({ total: 0 });
    const url = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[0][0] as string;
    expect(url).toBe("/api/installs?status=dormant&page=2");
  });

  it("sends JSON on POST and resolves 204", async () => {
    const fn = mockFetch(204);
    await expect(api.ban("a".repeat(64), "abuse")).resolves.toBeUndefined();
    const init = fn.mock.calls[0][1] as RequestInit;
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
    expect(init.body).toBe(JSON.stringify({ reason: "abuse" }));
  });

  it("raises ApiError with the server code", async () => {
    mockFetch(400, { error: "bad_request" });
    await expect(api.overview("30d")).rejects.toMatchObject({ status: 400, code: "bad_request" });
  });

  it("announces 401s except on login", async () => {
    const seen = vi.fn();
    window.addEventListener(UNAUTHORIZED_EVENT, seen);
    mockFetch(401, { error: "unauthorized" });
    await expect(api.fleet()).rejects.toBeInstanceOf(ApiError);
    expect(seen).toHaveBeenCalledTimes(1);
    mockFetch(401, { error: "invalid_password" });
    await expect(api.login("x")).rejects.toBeInstanceOf(ApiError);
    expect(seen).toHaveBeenCalledTimes(1);
    window.removeEventListener(UNAUTHORIZED_EVENT, seen);
  });

  it("me resolves true", async () => {
    mockFetch(204);
    await expect(api.me()).resolves.toBe(true);
  });
});
