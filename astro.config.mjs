import { defineConfig } from "astro/config";
import cloudflare from "@astrojs/cloudflare";

// Static output is right for this site today. When you add the
// Pages Function that reads GitHub Discussions activity for the
// forum pulse, switch `output` to "server" (or use hybrid) so the
// function can run server-side.
export default defineConfig({
  output: "static",
  adapter: cloudflare(),
});
