import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const apiTarget = process.env.HOWMUCH_API_URL ?? "http://localhost:8787";
const apiOrigin = new URL(apiTarget).origin;

const apiProxy = {
  target: apiTarget,
  changeOrigin: true,
  configure(proxy: { on: (event: string, handler: (request: { setHeader: (name: string, value: string) => void }) => void) => void }) {
    proxy.on("proxyReq", (request) => request.setHeader("origin", apiOrigin));
  },
};

export default defineConfig({
  plugins: [react()],
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          react: ["react", "react-dom", "react-router-dom"],
        },
      },
    },
  },
  server: {
    port: 5173,
    fs: {
      allow: ["../.."],
    },
    allowedHosts: [".e2b.app", ".onamp.dev"],
    proxy: {
      "/api": apiProxy,
      "/v1": apiProxy,
    },
  },
});
