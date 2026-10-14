import { defineConfig } from "astro/config";
// Static output (SSG): the container only serves files.
// assetsInlineLimit 0: Astro otherwise inlines small <script> bundles, which the strict edge CSP
// (script-src 'self') blocks — found by the headless-browser CSP check during the build.
export default defineConfig({
  output: "static",
  build: { inlineStylesheets: "never" },
  vite: { build: { assetsInlineLimit: 0 } },
});
