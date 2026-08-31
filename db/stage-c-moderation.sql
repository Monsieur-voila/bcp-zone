-- ═══════════════════════════════════════════════════════════════
--  THE TABLE — Stage C: posting + moderation floor
--  Paste into Supabase: SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════


-- ── Has this person posted before? ────────────────────────────
create or replace function public.is_first_post(uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select not exists (
    select 1 from public.replies
     where author_id = uid and is_pending = false
    union all
    select 1 from public.threads
     where author_id = uid
  );
$$;


-- ── Rate limit: max 5 posts per 5 minutes ─────────────────────
create or replace function public.under_rate_limit(uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select (
    (select count(*) from public.replies
      where author_id = uid and created_at > now() - interval '5 minutes')
    +
    (select count(*) from public.threads
      where author_id = uid and created_at > now() - interval '5 minutes')
  ) < 5;
$$;


-- ── Read a boolean setting ────────────────────────────────────
create or replace function public.setting_bool(k text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select (value#>>'{}')::boolean from public.settings where key = k), false);
$$;


-- ── Enforce the floor on writes ───────────────────────────────
drop policy if exists "signed-in may start threads" on public.threads;
create policy "signed-in may start threads"
  on public.threads for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
    and public.under_rate_limit(auth.uid())
  );

drop policy if exists "signed-in may reply" on public.replies;
create policy "signed-in may reply"
  on public.replies for insert
  with check (
    auth.uid() is not null
    and auth.uid() = author_id
    and public.is_blocked() = false
    and public.under_rate_limit(auth.uid())
    and (
      public.setting_bool('hold_first_post_for_review') = false
      or public.is_first_post(auth.uid()) = false
      or is_pending = true
    )
  );


-- ── Admin: move a thread between sections ─────────────────────
create or replace function public.move_thread(thread uuid, new_section uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not permitted';
  end if;
  update public.threads set section_id = new_section where id = thread;
end;
$$;


-- ── Admin: approve a pending reply ────────────────────────────
create or replace function public.approve_reply(reply uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'not permitted';
  end if;
  update public.replies set is_pending = false where id = reply;
end;
$$;
