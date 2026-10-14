import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  plugins: [react()],
  define: { __SHIP_VERSION__: JSON.stringify(process.env.SHIP_VERSION ?? "dev") },
  build: { assetsInlineLimit: 0 },
});
