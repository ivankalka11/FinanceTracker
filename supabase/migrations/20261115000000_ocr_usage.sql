-- Phase 3: daily scan limit for the "ocr" Edge Function.
-- Each scan calls use_ocr_scan(), which counts it against the caller and
-- refuses once the day's limit is reached. Run this once in the SQL Editor.

create table public.ocr_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day     date not null,
  scans   int  not null default 0,
  primary key (user_id, day)
);

alter table public.ocr_usage enable row level security;

-- Users may read their own counter; only use_ocr_scan() writes it.
create policy ocr_usage_own on public.ocr_usage
  for select to authenticated using (user_id = (select auth.uid()));

revoke all on public.ocr_usage from anon, authenticated;
grant select on public.ocr_usage to authenticated;
grant all on public.ocr_usage to service_role;

-- Counts one scan for the signed-in user and returns how many are left today.
-- Raises when the user is not in any household or has used up the day.
create function public.use_ocr_scan()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := (select auth.uid());
  v_day   date := (now() at time zone 'Asia/Jakarta')::date;
  v_limit constant int := 30;
  v_scans int;
begin
  if v_user is null then
    raise exception 'Not signed in';
  end if;
  if not exists (select 1 from public.members m where m.user_id = v_user) then
    raise exception 'Not a household member';
  end if;

  insert into public.ocr_usage as u (user_id, day, scans)
  values (v_user, v_day, 1)
  on conflict (user_id, day) do update set scans = u.scans + 1
    where u.scans < v_limit
  returning u.scans into v_scans;

  if v_scans is null then
    raise exception 'Daily scan limit reached (% a day). Try again tomorrow.', v_limit;
  end if;
  return v_limit - v_scans;
end;
$$;

revoke all on function public.use_ocr_scan() from public, anon;
grant execute on function public.use_ocr_scan() to authenticated;
