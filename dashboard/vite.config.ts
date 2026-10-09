/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The dev server proxies the API to a locally running pawlet-admin
// (ADMIN_ADDR=127.0.0.1:8092). The Host header is kept, so the admin's
// same-origin check sees the browser's origin as its own.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:8092",
      "/healthz": "http://127.0.0.1:8092",
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    css: false,
  },
});
