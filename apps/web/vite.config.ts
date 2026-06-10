import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const apiTarget = process.env.HOWMUCH_API_URL ?? "http://localhost:8787";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": { target: apiTarget, changeOrigin: true },
      "/v1": { target: apiTarget, changeOrigin: true },
    },
  },
});
