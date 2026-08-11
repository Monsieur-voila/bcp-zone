// ─────────────────────────────────────────────────────────────
//  SITE CONTROL PANEL. Edit here, redeploy. Most copy lives here.
// ─────────────────────────────────────────────────────────────

export const site = {
  name: "BCP",
  // Used in <title>, meta, and the nav wordmark.
  wordmark: "Blaine County Preparedness",
  description:
    "Community first — the comfort of connection, attention to detail, and family kept close.",
};

// ── NAV ───────────────────────────────────────────────────────
// Order matters: this array is the nav, left to right.
// `center: true` marks the visual centerpiece (The Table).
export const nav = [
  { label: "About", href: "/about" },
  { label: "The Table", href: "/forum", center: true },
  { label: "Comms", href: "/comms" },
  { label: "Contact / Tips", href: "/contact" },
];

// ── STATUS LINE ───────────────────────────────────────────────
// The thin always-on signal line. Manual. Change `now` anytime.
export const status = {
  now: "cutting drive-line hydraulics on the Billy Goat",
  freq: "14.074 MHz",
  updated: "2026-08-09",
};

// ── THE TABLE (forum card on the homepage right rail) ─────────
// The card is a live window into the forum. Real data arrives later
// (Stage 5). `live` + `heat` drive the future "what's hot" pulse;
// the markup + CSS hook are pre-wired so only these values change.
export const forum = {
  label: "The Table",
  line: "Pull up a chair. This is where the action happens.",
  href: "/forum",
  live: false,      // FUTURE: true when there's recent activity
  heat: 0,          // FUTURE: 0–100, drives pulse intensity/color
  // Placeholder threads shown in the rail until real data is wired.
  preview: [
    { title: "Grid resilience — how long could we last?", replies: 0, hot: false },
    { title: "How LoRa mesh nodes keep us connected without power or internet", replies: 0, hot: false },
    { title: "Barn raise, Saturday — hands needed", replies: 0, hot: false },
  ],
};

