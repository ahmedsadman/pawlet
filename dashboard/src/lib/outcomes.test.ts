import { describe, expect, it } from "vitest";
import { CLASSIFY_FAILURES, groupDaily, sumKeys } from "./outcomes";

describe("outcomes", () => {
  it("groups failure keys per day and drops ok", () => {
    const rows = groupDaily(
      [
        {
          day: "2026-10-01",
          counts: {
            ok: 90,
            upstream_429: 2,
            upstream_retryable: 3,
            unauthorized: 4,
            client_cancelled: 1,
          },
        },
      ],
      CLASSIFY_FAILURES,
    );
    expect(rows).toEqual([
      { day: "2026-10-01", limited: 0, upstream: 5, internal: 0, client: 4, cancelled: 1 },
    ]);
  });
  it("sums keys across days, largest first, zero keys dropped", () => {
    const got = sumKeys(
      [
        { day: "a", counts: { cert_mismatch: 1, device_integrity: 2, ok: 50 } },
        { day: "b", counts: { device_integrity: 3 } },
      ],
      ["device_integrity", "cert_mismatch", "stale_token"],
    );
    expect(got).toEqual([
      { key: "device_integrity", count: 5 },
      { key: "cert_mismatch", count: 1 },
    ]);
  });
});
