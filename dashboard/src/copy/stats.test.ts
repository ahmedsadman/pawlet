import { describe, expect, it } from "vitest";
import { statCopy } from "./stats";

describe("stat copy", () => {
  it("gives every stat a title, meaning and computation", () => {
    for (const [id, entry] of Object.entries(statCopy)) {
      expect(entry.title.trim(), id).not.toBe("");
      expect(entry.meaning.trim(), id).not.toBe("");
      expect(entry.computation.trim(), id).not.toBe("");
      if ("caveat" in entry && entry.caveat) expect(entry.caveat.trim(), id).not.toBe("");
    }
  });
});
