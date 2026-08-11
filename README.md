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
