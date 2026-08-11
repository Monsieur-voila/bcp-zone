#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Sonny front-page — one-shot setup.
#  Run from inside the folder you want the project in (e.g. ~/site).
#  Creates all files, correctly placed. Then: npm install && npm run dev
# ─────────────────────────────────────────────────────────────
set -e

echo "Building project tree..."
mkdir -p src/pages src/components src/layouts public/fonts

echo "  writing package.json"
cat > 'package.json' << 'SONNY_FILE_EOF'
{
  "name": "sonny-site",
  "type": "module",
  "version": "0.1.0",
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview"
  },
  "dependencies": {
    "astro": "^4.16.0",
    "@astrojs/cloudflare": "^11.2.0"
  }
}
SONNY_FILE_EOF

echo "  writing astro.config.mjs"
cat > 'astro.config.mjs' << 'SONNY_FILE_EOF'
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
SONNY_FILE_EOF

echo "  writing README.md"
cat > 'README.md' << 'SONNY_FILE_EOF'
# Sonny — front page

Astro + Cloudflare Pages. Community first.

## Run
```
npm install
npm run dev      # local
npm run build    # -> dist/, what Cloudflare Pages serves
```

## What to edit
**`src/site.config.ts` is the whole control panel.** Name, tagline, the
status strip (`now` / `freq` / `updated`), the depot doorways, and the forum
entry all live there. Change strings, redeploy. No component edits needed.

## Fonts
- Newsreader + Martian Mono load from Google Fonts (nothing to do).
- Redaction 35 is self-hosted: drop `Redaction35-Regular.woff2`/`.woff`
  into `public/fonts/`. Until then it falls back to Newsreader.

## Giscus (the forum — priority)
1. Enable Discussions on your GitHub repo.
2. Go to https://giscus.app, point it at the repo, pick a category.
3. Paste the four values (`repo`, `repoId`, `category`, `categoryId`)
   into the `giscus` object at the top of `src/pages/forum.astro`.

## The forum pulse — future path (not built yet)
The markup is already wired. The forum entry on the home page carries
`data-activity` and a `.forum-pulse` dot. It renders inert ("quiet")
until activity is detected. To light it up later, without touching markup:

- **Quick/manual:** set `forum.live = true` in `src/site.config.ts`.
- **Automatic:** add a Cloudflare Pages Function that queries the GitHub
  GraphQL API for the Discussions repo's last-comment timestamp, caches
  the result (~5–15 min), and returns `{ live, lastActivity }`. Have the
  page set `data-activity="live"` when the last comment is within your
  window. Switch `output` to `"server"` in `astro.config.mjs` so the
  function can run. Only `data-activity` needs to flip — the pulse CSS
  is already in place.
SONNY_FILE_EOF

echo "  writing src/site.config.ts"
cat > 'src/site.config.ts' << 'SONNY_FILE_EOF'
// ─────────────────────────────────────────────────────────────
//  EDIT HERE. This is the whole control panel for the front page.
//  Change the strings below and redeploy. No other file needs touching.
// ─────────────────────────────────────────────────────────────

export const site = {
  name: "SONNY",                    // the handle on the splash
  tagline: "Working in it, full tilt.",   // one line under the name
  entryLabel: "Come in",            // the single way-in link text
  entryHref: "#depot",              // where the way-in link goes
};

// ── STATUS STRIP ──────────────────────────────────────────────
// The thin always-on line. Manual. Change `now` whenever you like.
export const status = {
  now: "cutting drive-line hydraulics on the Billy Goat",  // what you're in right now
  freq: "14.074 MHz",              // a frequency, a place, a signal — your call
  updated: "2026-08-03",           // date you last touched this line (ISO)
};

// ── DEPOT CARDS ───────────────────────────────────────────────
// The doorways below the fold. Reorder / rename / add freely.
export const doorways = [
  {
    key: "voice",
    label: "The Voice",
    line: "Experimental, gospel-lit, built by hand.",
    href: "/voice",
  },
  {
    key: "ground",
    label: "Ground Work",
    line: "Earth moving, trees, turf. Done right, done nearby.",
    href: "/ground",
  },
  {
    key: "signal",
    label: "Signal",
    line: "Radio, electronics, the things that carry a voice.",
    href: "/signal",
  },
];

// ── FORUM (Giscus) ────────────────────────────────────────────
// Priority element. The forum is the point — community first.
export const forum = {
  label: "The Table",
  line: "Pull up a chair. This is where the talking happens.",
  href: "/forum",
  // FUTURE: flip `live` to true (or drive it from a Pages Function that
  // reads the GitHub Discussions last-comment time) and the entry pulses.
  // The dot + markup are already wired below; only this value needs to change.
  live: false,
  lastActivity: "",   // ISO timestamp the fetch will fill in later
};
SONNY_FILE_EOF

echo "  writing src/layouts/Base.astro"
cat > 'src/layouts/Base.astro' << 'SONNY_FILE_EOF'
---
interface Props {
  title?: string;
}
const { title = "Sonny — a signal in the valley" } = Astro.props;
---

<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="description" content="Community first. The comfort of knowing someone is working in it, full tilt." />
    <title>{title}</title>

    <!-- Fonts. Newsreader + Martian Mono from Google Fonts.
         Redaction 35 is self-hosted: drop the files in /public/fonts and the
         @font-face below picks them up. Falls back gracefully if absent. -->
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,300;0,6..72,400;0,6..72,500;1,6..72,400&family=Martian+Mono:wght@300;400;600&display=swap"
      rel="stylesheet"
    />

    <slot name="head" />
  </head>
  <body>
    <slot />
  </body>
</html>

<style is:global>
  /* ── Redaction 35 (self-hosted display face) ──────────────── */
  @font-face {
    font-family: "Redaction 35";
    src:
      url("/fonts/Redaction35-Regular.woff2") format("woff2"),
      url("/fonts/Redaction35-Regular.woff") format("woff");
    font-weight: 400;
    font-display: swap;
  }

  /* ── Palette: cold high-desert ────────────────────────────── */
  :root {
    --basalt:   #14171a;   /* near-black ground */
    --basalt-2: #1c2126;   /* raised surface */
    --twilight: #2b3440;   /* dusk blue-grey */
    --snowmelt: #e8ecef;   /* off-white light */
    --sage:     #8a9a8e;   /* muted green */
    --oxide:    #c05a2e;   /* the signal — rust/oxide */
    --line:     rgba(232, 236, 239, 0.14);

    --display: "Redaction 35", "Newsreader", Georgia, serif;
    --body:    "Newsreader", Georgia, serif;
    --mono:    "Martian Mono", ui-monospace, "SFMono-Regular", monospace;
  }

  * { box-sizing: border-box; }

  html, body {
    margin: 0;
    padding: 0;
    background: var(--basalt);
    color: var(--snowmelt);
    font-family: var(--body);
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }

  a { color: inherit; text-decoration: none; }

  :focus-visible {
    outline: 2px solid var(--oxide);
    outline-offset: 3px;
  }

  @media (prefers-reduced-motion: reduce) {
    * {
      animation-duration: 0.001ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: 0.001ms !important;
    }
  }
</style>
SONNY_FILE_EOF

echo "  writing src/components/StatusStrip.astro"
cat > 'src/components/StatusStrip.astro' << 'SONNY_FILE_EOF'
---
import { status } from "../site.config";
---

<div class="strip" role="status" aria-label="Current status">
  <span class="dot" aria-hidden="true"></span>
  <span class="key">now</span>
  <span class="val">{status.now}</span>
  <span class="sep" aria-hidden="true">/</span>
  <span class="key">freq</span>
  <span class="val">{status.freq}</span>
  <span class="upd">upd {status.updated}</span>
</div>

<style>
  .strip {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    gap: 0.55rem;
    flex-wrap: wrap;
    padding: 0.6rem 1.1rem;
    background: rgba(20, 23, 26, 0.82);
    backdrop-filter: blur(8px);
    border-top: 1px solid var(--line);
    font-family: var(--mono);
    font-size: 0.72rem;
    font-weight: 300;
    letter-spacing: 0.02em;
    color: var(--snowmelt);
  }

  /* the live indicator — a slow, calm breath, not a blink */
  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--oxide);
    box-shadow: 0 0 0 0 rgba(192, 90, 46, 0.5);
    animation: breathe 3.4s ease-in-out infinite;
    flex: none;
  }

  @keyframes breathe {
    0%, 100% { box-shadow: 0 0 0 0 rgba(192, 90, 46, 0.45); opacity: 0.85; }
    50%      { box-shadow: 0 0 0 5px rgba(192, 90, 46, 0);   opacity: 1; }
  }

  .key { color: var(--sage); text-transform: uppercase; font-size: 0.66rem; }
  .val { color: var(--snowmelt); }
  .sep { color: var(--line); }
  .upd {
    margin-left: auto;
    color: var(--sage);
    opacity: 0.7;
    font-size: 0.66rem;
  }

  @media (max-width: 560px) {
    .upd { margin-left: 0; width: 100%; }
  }
</style>
SONNY_FILE_EOF

echo "  writing src/pages/index.astro"
cat > 'src/pages/index.astro' << 'SONNY_FILE_EOF'
---
import Base from "../layouts/Base.astro";
import StatusStrip from "../components/StatusStrip.astro";
import { site, doorways, forum } from "../site.config";
---

<Base title={`${site.name} — a signal in the valley`}>
  <!-- ══ SPLASH ══════════════════════════════════════════════ -->
  <section class="splash">
    <!-- the signature: an oxide signal-line — radio waveform and a
         horizon of moved earth at once. A faint pulse travels its
         length, like a signal moving down a wire. -->
    <svg class="signalline" viewBox="0 0 1200 120" preserveAspectRatio="none" aria-hidden="true">
      <!-- base line: always visible, dim -->
      <path class="sl-base"
        d="M0,60 L360,60 Q380,60 388,44 T404,60 Q412,84 420,60 L470,60
           Q478,60 484,50 T496,60 L560,60 L580,26 L600,94 L620,60 L1200,60"
        fill="none" stroke="var(--oxide)" stroke-width="1.5" />
      <!-- travelling pulse: same path, bright, a short dash that sweeps -->
      <path class="sl-pulse"
        d="M0,60 L360,60 Q380,60 388,44 T404,60 Q412,84 420,60 L470,60
           Q478,60 484,50 T496,60 L560,60 L580,26 L600,94 L620,60 L1200,60"
        fill="none" stroke="var(--oxide)" stroke-width="2" />
    </svg>

    <div class="splash-inner">
      <h1 class="name">{site.name}</h1>
      <p class="tagline">{site.tagline}</p>
      <a class="enter" href={site.entryHref}>
        {site.entryLabel}
        <span class="enter-mark" aria-hidden="true">↓</span>
      </a>
    </div>

    <p class="ethos">
      Community first — the comfort of connection, attention to detail,
      and family kept close.
    </p>
  </section>

  <!-- ══ DEPOT ═══════════════════════════════════════════════ -->
  <main id="depot" class="depot">
    <p class="depot-eyebrow">The depot</p>

    <!-- FORUM FIRST. It's the point. Given full width and the top slot. -->
    <a
      class="forum"
      href={forum.href}
      data-activity={forum.live ? "live" : "quiet"}
      data-last={forum.lastActivity}
    >
      <span class="forum-pulse" aria-hidden="true"></span>
      <div class="forum-text">
        <span class="forum-label">{forum.label}</span>
        <span class="forum-line">{forum.line}</span>
      </div>
      <span class="forum-cta" aria-hidden="true">Enter →</span>
    </a>

    <!-- the other doorways -->
    <div class="doors">
      {doorways.map((d) => (
        <a class="door" href={d.href}>
          <span class="door-label">{d.label}</span>
          <span class="door-line">{d.line}</span>
        </a>
      ))}
    </div>
  </main>

  <StatusStrip />
</Base>

<style>
  /* ── SPLASH ────────────────────────────────────────────── */
  .splash {
    position: relative;
    min-height: 100svh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 2rem 1.5rem 5rem;
    background:
      radial-gradient(120% 80% at 50% 0%, var(--twilight) 0%, var(--basalt) 62%);
    overflow: hidden;
  }

  .signalline {
    position: absolute;
    top: 50%;
    left: 0;
    width: 100%;
    height: 120px;
    transform: translateY(-50%);
    pointer-events: none;
  }
  .sl-base { opacity: 0.32; }

  /* the pulse: a short bright dash that travels the whole path.
     pathLength-independent — large dash + gap, offset animated. */
  .sl-pulse {
    opacity: 0.9;
    stroke-dasharray: 90 3000;
    stroke-dashoffset: 3090;
    filter: drop-shadow(0 0 3px rgba(192, 90, 46, 0.6));
    animation: travel 7s linear infinite;
  }
  @keyframes travel {
    to { stroke-dashoffset: 0; }
  }

  /* stillness for anyone who asks for it */
  @media (prefers-reduced-motion: reduce) {
    .sl-base  { opacity: 0.55; }
    .sl-pulse { display: none; }
  }

  .splash-inner {
    position: relative;
    text-align: center;
    z-index: 1;
  }

  .name {
    font-family: var(--display);
    font-weight: 400;
    font-size: clamp(3.4rem, 14vw, 8.5rem);
    line-height: 0.92;
    letter-spacing: 0.04em;
    margin: 0;
    color: var(--snowmelt);
  }

  .tagline {
    font-family: var(--body);
    font-style: italic;
    font-size: clamp(1.05rem, 3.2vw, 1.5rem);
    color: var(--sage);
    margin: 1rem 0 2.2rem;
  }

  .enter {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    font-family: var(--mono);
    font-size: 0.82rem;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--snowmelt);
    padding: 0.75rem 1.4rem;
    border: 1px solid var(--line);
    border-radius: 2px;
    transition: border-color 0.25s ease, background 0.25s ease;
  }
  .enter:hover { border-color: var(--oxide); background: rgba(192, 90, 46, 0.06); }
  .enter-mark { color: var(--oxide); }

  .ethos {
    position: absolute;
    bottom: 3.4rem;
    max-width: 34ch;
    text-align: center;
    font-family: var(--body);
    font-size: 0.95rem;
    line-height: 1.5;
    color: var(--sage);
    opacity: 0.85;
    margin: 0;
    padding: 0 1rem;
    z-index: 1;
  }

  /* ── DEPOT ─────────────────────────────────────────────── */
  .depot {
    max-width: 820px;
    margin: 0 auto;
    padding: 5rem 1.5rem 7rem;
  }

  .depot-eyebrow {
    font-family: var(--mono);
    font-size: 0.7rem;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: var(--sage);
    margin: 0 0 1.6rem;
  }

  /* FORUM — the priority entry */
  .forum {
    display: flex;
    align-items: center;
    gap: 1.1rem;
    padding: 1.6rem 1.8rem;
    background:
      linear-gradient(180deg, var(--basalt-2) 0%, #171b1f 100%);
    border: 1px solid var(--line);
    border-left: 2px solid var(--oxide);
    border-radius: 3px;
    margin-bottom: 1.4rem;
    transition: border-color 0.25s ease, transform 0.25s ease;
  }
  .forum:hover { border-color: var(--sage); transform: translateY(-1px); }

  /* the pulse dot. inert ("quiet") by default; when the config's
     forum.live flips to true (or a Pages Function sets data-activity
     to "live"), it pulses. Zero markup change needed later. */
  .forum-pulse {
    flex: none;
    width: 11px;
    height: 11px;
    border-radius: 50%;
    background: var(--sage);
    opacity: 0.4;
    position: relative;
  }
  .forum[data-activity="live"] .forum-pulse {
    background: var(--oxide);
    opacity: 1;
    animation: pulse 1.8s ease-out infinite;
  }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(192, 90, 46, 0.55); }
    70%  { box-shadow: 0 0 0 12px rgba(192, 90, 46, 0); }
    100% { box-shadow: 0 0 0 0 rgba(192, 90, 46, 0); }
  }

  .forum-text { display: flex; flex-direction: column; gap: 0.3rem; }
  .forum-label {
    font-family: var(--display);
    font-size: 1.7rem;
    letter-spacing: 0.02em;
    color: var(--snowmelt);
  }
  .forum-line {
    font-family: var(--body);
    font-size: 1rem;
    color: var(--sage);
  }
  .forum-cta {
    margin-left: auto;
    font-family: var(--mono);
    font-size: 0.72rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--oxide);
    white-space: nowrap;
  }

  /* the other doorways */
  .doors {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 1rem;
  }
  .door {
    display: flex;
    flex-direction: column;
    gap: 0.45rem;
    padding: 1.4rem 1.5rem;
    background: var(--basalt-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    transition: border-color 0.25s ease, transform 0.25s ease;
  }
  .door:hover { border-color: var(--oxide); transform: translateY(-1px); }
  .door-label {
    font-family: var(--display);
    font-size: 1.35rem;
    letter-spacing: 0.02em;
    color: var(--snowmelt);
  }
  .door-line {
    font-family: var(--body);
    font-size: 0.95rem;
    line-height: 1.45;
    color: var(--sage);
  }

  @media (max-width: 560px) {
    .forum { flex-wrap: wrap; }
    .forum-cta { margin-left: 0; width: 100%; }
    .ethos { bottom: 4.2rem; }
  }
</style>
SONNY_FILE_EOF

echo "  writing src/pages/forum.astro"
cat > 'src/pages/forum.astro' << 'SONNY_FILE_EOF'
---
import Base from "../layouts/Base.astro";
import { forum } from "../site.config";

// ── Giscus ────────────────────────────────────────────────────
// Fill these four from https://giscus.app after enabling Discussions
// on your GitHub repo. Everything else is set.
const giscus = {
  repo: "YOUR_GH_USER/YOUR_REPO",        // e.g. "sonny/site"
  repoId: "YOUR_REPO_ID",
  category: "General",
  categoryId: "YOUR_CATEGORY_ID",
};
---

<Base title={`${forum.label} — Sonny`}>
  <a slot="head" />

  <main class="forum-page">
    <a class="back" href="/">← back</a>
    <h1 class="title">{forum.label}</h1>
    <p class="sub">{forum.line}</p>

    <div class="giscus-mount">
      <script
        src="https://giscus.app/client.js"
        data-repo={giscus.repo}
        data-repo-id={giscus.repoId}
        data-category={giscus.category}
        data-category-id={giscus.categoryId}
        data-mapping="pathname"
        data-strict="0"
        data-reactions-enabled="1"
        data-emit-metadata="0"
        data-input-position="top"
        data-theme="dark_dimmed"
        data-lang="en"
        crossorigin="anonymous"
        async
      ></script>
    </div>
  </main>
</Base>

<style>
  .forum-page {
    max-width: 820px;
    margin: 0 auto;
    padding: 3.5rem 1.5rem 6rem;
    min-height: 100svh;
  }
  .back {
    font-family: var(--mono);
    font-size: 0.72rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--sage);
  }
  .back:hover { color: var(--oxide); }
  .title {
    font-family: var(--display);
    font-weight: 400;
    font-size: clamp(2.4rem, 8vw, 4rem);
    letter-spacing: 0.03em;
    margin: 1.4rem 0 0.5rem;
    color: var(--snowmelt);
  }
  .sub {
    font-family: var(--body);
    font-style: italic;
    font-size: 1.1rem;
    color: var(--sage);
    margin: 0 0 2.6rem;
  }
  .giscus-mount { min-height: 300px; }
</style>
SONNY_FILE_EOF

echo ""
echo "Done. Files created:"
ls -1
echo ""
echo "Next:"
echo "  npm install"
echo "  npm run dev"
echo "  then open http://localhost:4321"
