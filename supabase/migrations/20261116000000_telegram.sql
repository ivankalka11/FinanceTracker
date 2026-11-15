-- Phase 4: the Telegram bot as a Supabase Edge Function ("telegram").
-- Adds one-time link codes (app -> bot), per-chat conversation state, and the
-- pieces the function needs when it acts with the service role.
-- Run this once in the SQL Editor.

-- One-time codes: created in the app, typed into the bot as "/link CODE".
create table public.telegram_link_codes (
  code         text primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  household_id uuid not null references public.households (id) on delete cascade,
  expires_at   timestamptz not null
);

-- What the bot is in the middle of with each Telegram user (pending entry,
-- rows waiting for review, "next photo is a payslip", ...).
create table public.telegram_state (
  telegram_user_id bigint primary key,
  state            jsonb not null default '{}'::jsonb,
  updated_at       timestamptz not null default now()
);

-- Both tables are for the Edge Function only: RLS on, no policies, no grants
-- to signed-in users. The service role bypasses RLS.
alter table public.telegram_link_codes enable row level security;
alter table public.telegram_state      enable row level security;
revoke all on public.telegram_link_codes, public.telegram_state from anon, authenticated;
grant all on public.telegram_link_codes, public.telegram_state to service_role;

-- Called from the app (Settings -> Link Telegram). Returns a code that is
-- valid for 10 minutes; any earlier code of the same user is dropped.
create function public.create_telegram_link_code(p_household uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_code text;
begin
  if v_user is null or not private.is_member(p_household) then
    raise exception 'Not a member of this household';
  end if;
  delete from public.telegram_link_codes
  where user_id = v_user or expires_at < now();
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.telegram_link_codes (code, user_id, household_id, expires_at)
  values (v_code, v_user, p_household, now() + interval '10 minutes');
  return v_code;
end;
$$;

revoke all on function public.create_telegram_link_code(uuid) from public, anon;
grant execute on function public.create_telegram_link_code(uuid) to authenticated;

-- Same daily scan limit as use_ocr_scan(), for the bot: the Edge Function
-- passes the linked user because it has no user session of its own.
create function public.use_ocr_scan_for(p_user uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day   date := (now() at time zone 'Asia/Jakarta')::date;
  v_limit constant int := 30;
  v_scans int;
begin
  insert into public.ocr_usage as u (user_id, day, scans)
  values (p_user, v_day, 1)
  on conflict (user_id, day) do update set scans = u.scans + 1
    where u.scans < v_limit
  returning u.scans into v_scans;

  if v_scans is null then
    raise exception 'Daily scan limit reached (% a day). Try again tomorrow.', v_limit;
  end if;
  return v_limit - v_scans;
end;
$$;

revoke all on function public.use_ocr_scan_for(uuid) from public, anon, authenticated;
grant execute on function public.use_ocr_scan_for(uuid) to service_role;

-- The bot records transfers and sales through the same RPCs as the app.
grant execute on function public.add_transfer(uuid, uuid, uuid, numeric, date, text, text) to service_role;
grant execute on function public.sell_holding(uuid, numeric, numeric, uuid, uuid, text, text, date, text) to service_role;
