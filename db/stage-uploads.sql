-- ═══════════════════════════════════════════════════════════════
--  TIPS — image attachments
--  Paste into Supabase: SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════

-- Attachment keys are stored on the tip itself. The files live in
-- Cloudflare R2 (private); these are just the object keys, which
-- the admin page exchanges for short-lived signed URLs.

alter table public.tips
  add column if not exists attachments jsonb not null default '[]'::jsonb;

-- Allow the insert policy to accept attachments, capped at 3.
drop policy if exists "anyone may send a tip" on public.tips;
create policy "anyone may send a tip"
  on public.tips for insert
  with check (
    length(coalesce(message, '')) between 2 and 5000
    and length(coalesce(name, '')) <= 120
    and length(coalesce(email, '')) <= 200
    and jsonb_array_length(coalesce(attachments, '[]'::jsonb)) <= 3
  );
