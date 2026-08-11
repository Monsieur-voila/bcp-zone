import { defineConfig } from "astro/config";

// Static output for Cloudflare Pages. No adapter needed for a static site;
// this also keeps local builds working on any platform (incl. Termux).
export default defineConfig({
  output: "static",
});
