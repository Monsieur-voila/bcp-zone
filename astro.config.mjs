import { defineConfig } from "astro/config";

// Static output is right for this site today. When you add the
// Pages Function that reads GitHub Discussions activity for the
// forum pulse, add back `@astrojs/cloudflare`, import it here,
// and switch `output` to "server" (or hybrid) so the function
// can run server-side.
export default defineConfig({
  output: "static",
});
