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
// The rotating signal line at the bottom of every page.
// To change what it says: edit, add, or remove entries in `items`.
//   label  short tag shown in oxide
//   text   the message (long text scrolls sideways)
//   href   where a click goes ("/forum", "/contact", "mailto:...")
// Bump `updated` whenever you change it.
export const status = {
  interval: 7000, // ms each short entry stays up
  updated: "2026-09-26",
  freq: "14.074 MHz", // kept in case anything else references it
  items: [
    {
      label: "SITE",
      text: "Replies are fixed! Start a thread! A glowing red, shaking card in The Table means ACTIVITY — replies are HOT! Jump in!",
      href: "/forum",
    },
    {
      label: "MEETUPS",
      text: "contacts@bcp.zone for planning, hosting, or attending the next in-person meetup",
      href: "mailto:contacts@bcp.zone",
    },
    {
      label: "COMMS",
      text: "Meshtastic & MeshCore nodes are going online as they get built. contacts@bcp.zone for more on unfettered communications.",
      href: "mailto:contacts@bcp.zone",
    },
    {
      label: "CONTRIBUTE",
      text: "Email contacts@bcp.zone or send a tip. We take care of our own.",
      href: "/contact",
    },
    {
      label: "WATER",
      text: "Next water meetup: send a tip or post a thread in The Table! We're monitoring water quality.",
      href: "/forum",
    },
  ],
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