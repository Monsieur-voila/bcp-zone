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
