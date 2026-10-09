import { describe, expect, it } from "vitest";
import { MESSAGE_COUNTS_RELEASE, statCopy } from "./stats";

describe("stat copy", () => {
  it("gives every stat a title, meaning and computation", () => {
    for (const [id, entry] of Object.entries(statCopy)) {
      expect(entry.title.trim(), id).not.toBe("");
      expect(entry.meaning.trim(), id).not.toBe("");
      expect(entry.computation.trim(), id).not.toBe("");
      if ("caveat" in entry && entry.caveat) expect(entry.caveat.trim(), id).not.toBe("");
    }
  });

  it("says which app release reports message counts on every messages stat", () => {
    const ids = [
      "chart.localModel",
      "col.messagesToday",
      "col.messages7d",
      "col.messagesTotal",
      "chart.installMessages",
      "chart.messagesDistribution",
      "chart.messagesPerDay",
      "messagesPerActiveInstallDay",
    ] as const;
    for (const id of ids) expect(statCopy[id].caveat, id).toContain(MESSAGE_COUNTS_RELEASE);
  });

  it("keeps the rate's definition and the 90-day reach in the copy", () => {
    expect(statCopy["chart.localModel"].computation).toContain("accepted ÷ (accepted + declined)");
    expect(statCopy["chart.messagesDistribution"].caveat).toContain("90 days");
  });

  it("explains why the ring's LLM count differs from the footer's", () => {
    expect(statCopy["chart.localModel"].caveat).toContain("messages the model declined");
    expect(statCopy["chart.localModel"].caveat).toContain("model errors");
  });
});
