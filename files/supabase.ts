// ─────────────────────────────────────────────────────────────
//  Supabase client — browser side.
//
//  Reads credentials from environment variables (see .env).
//  The anon key is SAFE to ship in the browser: it's designed to be
//  public. Your data is protected by Row Level Security policies on
//  the database, not by hiding this key.
//
//  NEVER put the service_role key here or anywhere in site code.
// ─────────────────────────────────────────────────────────────

import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.PUBLIC_SUPABASE_URL;
const anonKey = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  // A loud, clear failure beats a silent broken sign-in button.
  console.error(
    "[supabase] Missing PUBLIC_SUPABASE_URL or PUBLIC_SUPABASE_ANON_KEY. " +
    "Check your .env file in the project root."
  );
}

export const supabase = createClient(url ?? "", anonKey ?? "", {
  auth: {
    // Keep the session in the browser and refresh it automatically,
    // so a signed-in person stays signed in between visits.
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,   // handles the redirect back from Google
  },
});
