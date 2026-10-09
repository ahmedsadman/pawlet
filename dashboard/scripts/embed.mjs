// Copies the production build into the directory pawlet-admin embeds, so
// `go run ./cmd/pawlet-admin` serves the real UI. Keeps the committed .gitkeep.
import { cpSync, readdirSync, rmSync } from "node:fs";

const target = new URL("../../server/internal/admin/web/dist/", import.meta.url);
for (const name of readdirSync(target)) {
  if (name !== ".gitkeep") rmSync(new URL(name, target), { recursive: true, force: true });
}
cpSync(new URL("../dist/", import.meta.url), target, { recursive: true });
console.log("copied dashboard build into server/internal/admin/web/dist");
