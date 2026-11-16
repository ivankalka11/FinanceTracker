-- Scheduled jobs (all times WIB; pg_cron runs in UTC).
--
--   08:00, 12:00, 16:00  notification checks (public.run_notifications())
--
-- The checks that used to run at 07:00 and 19:00 move to the three times above, and the
-- last-day month-close reminder (FR-CLS-12) now starts at 16:00 instead of 19:00.
-- This needs the pg_cron extension. Without it the schedule is skipped with a notice;
-- the app still runs the notification checks when it opens.
-- (Holding prices are not scheduled: the Portfolio page has a Sync prices button.)
--
-- Needs 20261118000000_plans.sql.

-- The month-close reminder on the last day of a month used to start at 19:00 WIB. The last
-- check of the day now runs at 16:00, so the reminder starts at 16:00.
create or replace function private.check_household(p_household uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan   uuid;
  v_now    timestamp := now() at time zone 'Asia/Jakarta';
  v_today  date := v_now::date;
  v_this   date := date_trunc('month', v_now)::date;
  v_lock   date := private.locked_through(p_household);
  v_next   date;
  v_day    int := extract(day from v_now)::int;
  v_last   boolean := (v_today + 1) = (v_this + interval '1 month')::date;
begin
  for v_plan in select id from public.plans where household_id = p_household and status in ('active', 'paused') loop
    perform private.check_plan(v_plan, true);
  end loop;

  -- the month that should be closed next; none until the ledger has entries
  if v_lock is not null then
    v_next := v_lock + 1;
  elsif exists (select 1 from public.transactions t where t.household_id = p_household and t.date < v_this) then
    v_next := (v_this - interval '1 month')::date;
  end if;

  -- last day of a month, when it is the next one to close
  if v_last and extract(hour from v_now) >= 16
     and (v_lock + 1 = v_this
          or (v_lock is null and v_next is null
              and exists (select 1 from public.transactions t where t.household_id = p_household))) then
    perform private.notify(p_household, 'month_close', null, to_char(v_this, 'YYYY-MM') || '-last',
      'Time to close ' || private.month_name(v_this),
      'The month ends today. Close it from tomorrow once the last entries are in.',
      'statement:' || to_char(v_this, 'YYYY-MM-DD'));
  end if;

  -- only the latest reminder that applies, so a late first run sends one, not three
  if v_next is not null and v_next < v_this then
    if v_day >= 7 then
      perform private.notify(p_household, 'month_close', null, to_char(v_next, 'YYYY-MM') || '-d7',
        'Last reminder: close ' || private.month_name(v_next),
        'It has been a week since the month ended.', 'statement:' || to_char(v_next, 'YYYY-MM-DD'));
    elsif v_day >= 3 then
      perform private.notify(p_household, 'month_close', null, to_char(v_next, 'YYYY-MM') || '-d3',
        private.month_name(v_next) || ' is still open',
        'Close it so its statement is saved and its entries are locked.', 'statement:' || to_char(v_next, 'YYYY-MM-DD'));
    else
      perform private.notify(p_household, 'month_close', null, to_char(v_next, 'YYYY-MM') || '-d1',
        'Close ' || private.month_name(v_next),
        'Check the figures and bank balances, then lock the month.', 'statement:' || to_char(v_next, 'YYYY-MM-DD'));
    end if;
  end if;
end;
$$;

-- Notification checks: 01:00, 05:00 and 09:00 UTC = 08:00, 12:00 and 16:00 WIB.
do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.unschedule(jobid) from cron.job
    where jobname in ('finance-notifications-morning', 'finance-notifications-evening', 'finance-notifications');
  perform cron.schedule('finance-notifications', '0 1,5,9 * * *', 'select public.run_notifications()');
exception when others then
  raise notice 'pg_cron is not set up (%). Notification checks are not scheduled.', sqlerrm;
end;
$$;
