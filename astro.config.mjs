import { defineConfig } from "astro/config";

// Static output. The /functions directory is picked up by
// Cloudflare Pages directly — it does NOT require the Astro
// Cloudflare adapter, and keeping the site static avoids the
// build complications the adapter introduced previously.
export default defineConfig({
  output: "static",
});
