-- V2.5: plans (savings goals) and in-app notifications.
-- A plan has a target amount and date; contributions record money set aside.
-- Notifications are rows in public.notifications, created by the database:
--   * right after a contribution (milestones 25/50/75/100%),
--   * by check_notifications(), which the app calls when it opens,
--   * twice a day by pg_cron (07:00 and 19:00 WIB) when pg_cron is available.
-- Push delivery (push_subscriptions + an Edge Function that sends unsent rows)
-- is the next step; this file only stores the subscriptions.
-- The closing statement gains a per-plan section (ledger_closings.plans).
-- Needs 20261117000000_ledger_closing.sql (contributions follow the month lock).
-- Run this once in the SQL Editor (or with `supabase db push`).

-- ---------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------
create table public.plans (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households (id) on delete cascade,
  name          text not null check (length(trim(name)) > 0),
  icon          text not null default '🎯',
  note          text not null default '',
  target_amount numeric(18, 2) not null check (target_amount > 0),
  start_date    date not null default ((now() at time zone 'Asia/Jakarta')::date),
  target_date   date not null,
  account_id    uuid references public.accounts (id) on delete set null,
  status        text not null default 'active' check (status in ('active', 'paused', 'achieved', 'cancelled')),
  achieved_at   timestamptz,    -- set by the database when status becomes 'achieved'
  behind_since  date,           -- set by the daily check; one "behind" notification per streak
  created_by    uuid references auth.users (id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  check (target_date > start_date)
);
create index plans_household_idx on public.plans (household_id, status);

create table public.plan_contributions (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  plan_id        uuid not null references public.plans (id) on delete cascade,
  date           date not null default ((now() at time zone 'Asia/Jakarta')::date),
  amount         numeric(18, 2) not null check (amount > 0),
  note           text not null default '',
  transaction_id uuid unique references public.transactions (id) on delete set null,
  created_by     uuid references auth.users (id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now()
);
create index plan_contributions_plan_idx on public.plan_contributions (plan_id, date);
create index plan_contributions_household_idx on public.plan_contributions (household_id, date);

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  kind         text not null check (kind in
                 ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly', 'month_close')),
  subject_id   uuid,            -- the plan; null for month_close
  period_key   text not null,   -- makes each notification happen once: '50', '7d:2026-12-31', '2026-11', ...
  title        text not null,
  body         text not null default '',
  link         text not null default '', -- 'plan:<id>' or 'statement:<YYYY-MM-01>'
  created_at   timestamptz not null default now(),
  sent_at      timestamptz,     -- set by push delivery
  read_at      timestamptz,
  unique nulls not distinct (user_id, kind, subject_id, period_key)
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unsent_idx on public.notifications (created_at) where sent_at is null;

-- Missing row = default: owners get everything, other members nothing.
create table public.notification_prefs (
  user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
  kind    text not null check (kind in
            ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly', 'month_close')),
  enabled boolean not null,
  primary key (user_id, kind)
);

-- One row per device that allowed Web Push. Saved through save_push_subscription().
create table public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade default auth.uid(),
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  user_agent text not null default '',
  created_at timestamptz not null default now()
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);

-- The closing statement keeps each plan's month (FR-PLN-11).
alter table public.ledger_closings add column plans jsonb not null default '[]';

-- ---------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------
alter table public.plans              enable row level security;
alter table public.plan_contributions enable row level security;
alter table public.notifications      enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.push_subscriptions enable row level security;

create policy plans_all on public.plans
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy plan_contributions_all on public.plan_contributions
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));

-- Each user sees, marks read and clears only their own notifications;
-- only the database creates them.
create policy notifications_own_select on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));
create policy notifications_own_update on public.notifications
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notifications_own_delete on public.notifications
  for delete to authenticated using (user_id = (select auth.uid()));
create policy notification_prefs_own on public.notification_prefs
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy push_subscriptions_own_select on public.push_subscriptions
  for select to authenticated using (user_id = (select auth.uid()));
create policy push_subscriptions_own_delete on public.push_subscriptions
  for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.plans, public.plan_contributions, public.notifications,
  public.notification_prefs, public.push_subscriptions from anon;
-- Supabase grants everything on new tables by default; take it back and
-- give only what the app needs. behind_since and achieved_at belong to the database.
revoke all on public.plans, public.plan_contributions, public.notifications,
  public.notification_prefs, public.push_subscriptions from authenticated;
grant select, insert, update, delete on public.plan_contributions, public.notification_prefs to authenticated;
grant select, insert, delete on public.plans to authenticated;
grant update (name, icon, note, target_amount, start_date, target_date, account_id, status)
  on public.plans to authenticated;
grant select, delete on public.notifications, public.push_subscriptions to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant all on public.plans, public.plan_contributions, public.notifications,
  public.notification_prefs, public.push_subscriptions to service_role;

-- ---------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------

-- Plans: the linked account must be in the same household, the target date
-- must be in the future when it is set, and status drives achieved_at.
create function private.plan_rules()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if tg_op = 'UPDATE' and new.household_id <> old.household_id then
    raise exception 'A plan cannot move to another household';
  end if;
  if new.account_id is not null and not exists (
       select 1 from public.accounts a where a.id = new.account_id and a.household_id = new.household_id) then
    raise exception 'That account is not in this household';
  end if;
  if (tg_op = 'INSERT' or new.target_date <> old.target_date)
     and new.target_date <= v_today and new.status in ('active', 'paused') then
    raise exception 'The target date must be in the future';
  end if;

  if tg_op = 'INSERT' then
    new.behind_since := null;
  end if;
  if new.status = 'achieved' then
    new.achieved_at := coalesce(case when tg_op = 'UPDATE' and old.status = 'achieved' then old.achieved_at end, now());
  else
    new.achieved_at := null;
  end if;
  -- a fresh start: pausing, cancelling or moving the date ends a "behind" streak
  if new.status <> 'active' or (tg_op = 'UPDATE' and new.target_date <> old.target_date) then
    new.behind_since := null;
  end if;
  return new;
end;
$$;

create trigger plans_rules
  before insert or update on public.plans
  for each row execute function private.plan_rules();

-- A plan with contributions can only be cancelled, not deleted.
create function private.guard_plan_delete()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.households h where h.id = old.household_id)
     and exists (select 1 from public.plan_contributions c where c.plan_id = old.id) then
    raise exception 'This plan has money in it. Cancel it instead of deleting it.';
  end if;
  return old;
end;
$$;

create trigger plans_no_delete_with_money
  before delete on public.plans
  for each row execute function private.guard_plan_delete();

-- Contributions: the plan and the linked transaction must be in the same
-- household; cancelled plans take no new money.
create function private.contribution_rules()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan public.plans;
begin
  select * into v_plan from public.plans where id = new.plan_id;
  if v_plan.id is null or v_plan.household_id <> new.household_id then
    raise exception 'That plan is not in this household';
  end if;
  if v_plan.status = 'cancelled' and (tg_op = 'INSERT' or new.plan_id <> old.plan_id) then
    raise exception 'This plan is cancelled. Resume it first.';
  end if;
  if new.transaction_id is not null
     and (tg_op = 'INSERT' or new.transaction_id is distinct from old.transaction_id)
     and not exists (select 1 from public.transactions t
                     where t.id = new.transaction_id and t.household_id = new.household_id) then
    raise exception 'That transaction is not in this household';
  end if;
  return new;
end;
$$;

create trigger plan_contributions_rules
  before insert or update on public.plan_contributions
  for each row execute function private.contribution_rules();

-- Contributions dated in a closed month are locked like transactions.
-- Two things still pass: deleting the whole household, and the "set null"
-- that follows deleting the linked transaction.
create function private.guard_closed_contribution()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_hid  uuid := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  v_lock date := private.locked_through(v_hid);
begin
  if v_lock is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'INSERT' then
    if new.date <= v_lock then
      raise exception 'Closed month: entries up to % are locked. An owner can reopen the month.', to_char(v_lock, 'DD Mon YYYY');
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.date <= v_lock and exists (select 1 from public.households h where h.id = old.household_id) then
      raise exception 'Closed month: entries up to % are locked. An owner can reopen the month.', to_char(v_lock, 'DD Mon YYYY');
    end if;
    return old;
  end if;

  -- UPDATE
  if old.date <= v_lock or new.date <= v_lock then
    if new.transaction_id is null
       and to_jsonb(new) - 'transaction_id' = to_jsonb(old) - 'transaction_id' then
      return new;
    end if;
    raise exception 'Closed month: entries up to % are locked. An owner can reopen the month.', to_char(v_lock, 'DD Mon YYYY');
  end if;
  return new;
end;
$$;

create trigger plan_contributions_closed_month
  before insert or update or delete on public.plan_contributions
  for each row execute function private.guard_closed_contribution();

-- ---------------------------------------------------------------
-- Notification helpers
-- ---------------------------------------------------------------
create function private.rp(v numeric)
returns text
language sql immutable set search_path = ''
as $$
  select case when v < 0 then '−' else '' end || 'Rp '
    || replace(to_char(abs(round(v)), 'FM999,999,999,999,990'), ',', '.');
$$;

create function private.month_name(d date)
returns text
language sql immutable set search_path = ''
as $$
  select (array['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus',
                'September','Oktober','November','Desember'])[extract(month from d)::int]
    || ' ' || extract(year from d)::int;
$$;

create function private.long_date(d date)
returns text
language sql immutable set search_path = ''
as $$
  select extract(day from d)::int || ' ' || private.month_name(d);
$$;

-- Owners get every kind unless they turned it off; other members only
-- the kinds they turned on. month_close goes to owners only.
create function private.notify(
  p_household uuid, p_kind text, p_subject uuid, p_key text, p_title text, p_body text, p_link text
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.notifications (household_id, user_id, kind, subject_id, period_key, title, body, link)
  select p_household, m.user_id, p_kind, p_subject, p_key, p_title, p_body, p_link
  from public.members m
  left join public.notification_prefs np on np.user_id = m.user_id and np.kind = p_kind
  where m.household_id = p_household
    and case when m.role = 'owner' then coalesce(np.enabled, true)
             else p_kind <> 'month_close' and coalesce(np.enabled, false) end
  on conflict (user_id, kind, subject_id, period_key) do nothing;
end;
$$;

-- Check one plan. p_daily = false runs only the milestone check (after a
-- contribution); true also runs the date-based checks (FR-PLN-09).
create function private.check_plan(p_plan uuid, p_daily boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p          public.plans;
  v_today    date := (now() at time zone 'Asia/Jakarta')::date;
  v_saved    numeric;
  v_left_amt numeric;
  v_pct      numeric;
  v_mile     int;
  v_total    int;
  v_elapsed  int;
  v_expected numeric;
  v_days     int;
  v_months   int;
  v_needed   numeric;
  v_thismon  numeric;
  v_link     text;
  v_name     text;
begin
  select * into p from public.plans where id = p_plan;
  if p.id is null or p.status in ('achieved', 'cancelled') then return; end if;
  v_link := 'plan:' || p.id;
  v_name := p.icon || ' ' || p.name;

  select coalesce(sum(amount), 0) into v_saved from public.plan_contributions where plan_id = p.id;
  v_left_amt := greatest(p.target_amount - v_saved, 0);
  v_pct := v_saved / p.target_amount * 100;

  -- milestones: only the highest one reached, once
  v_mile := case when v_pct >= 100 then 100 when v_pct >= 75 then 75 when v_pct >= 50 then 50
                 when v_pct >= 25 then 25 else 0 end;
  if v_mile = 100 then
    update public.plans set status = 'achieved' where id = p.id;
    perform private.notify(p.household_id, 'plan_achieved', p.id, '100',
      v_name || ' reached its target',
      private.rp(v_saved) || ' saved of ' || private.rp(p.target_amount) || '.', v_link);
    return;
  elsif v_mile > 0 then
    perform private.notify(p.household_id, 'plan_milestone', p.id, v_mile::text,
      v_name || ' is ' || v_mile || '% there',
      private.rp(v_saved) || ' saved of ' || private.rp(p.target_amount) || '.', v_link);
  end if;

  -- paused plans get no date-based reminders
  if not p_daily or p.status <> 'active' then return; end if;

  v_days   := p.target_date - v_today;
  v_months := greatest(1, (extract(year from age(p.target_date, v_today)) * 12
                           + extract(month from age(p.target_date, v_today))
                           + case when extract(day from age(p.target_date, v_today)) > 0 then 1 else 0 end)::int);
  v_needed := v_left_amt / v_months;

  -- keys carry the target date, so moving the date re-arms these
  if v_days < 0 then
    perform private.notify(p.household_id, 'plan_overdue', p.id, 'overdue:' || p.target_date,
      v_name || ' passed its target date',
      private.rp(v_left_amt) || ' still to go. Move the date or add money.', v_link);
    return;
  end if;

  if v_days <= 7 then
    perform private.notify(p.household_id, 'plan_deadline', p.id, '7d:' || p.target_date,
      v_name || ': ' || case when v_days = 0 then 'due today'
                             else v_days || ' day' || case when v_days = 1 then '' else 's' end || ' left' end,
      private.rp(v_left_amt) || ' still to go.', v_link);
  elsif v_days <= 30 then
    perform private.notify(p.household_id, 'plan_deadline', p.id, '30d:' || p.target_date,
      v_name || ': ' || v_days || ' days left',
      private.rp(v_left_amt) || ' still to go.', v_link);
  end if;

  -- behind: below the straight line from start to target by more than 5% of
  -- the target (FR-PLN-05). One notification each time the plan falls behind.
  v_total    := greatest(p.target_date - p.start_date, 1);
  v_elapsed  := least(greatest(v_today - p.start_date, 0), v_total);
  v_expected := p.target_amount * v_elapsed / v_total;
  if v_saved < v_expected - p.target_amount * 0.05 then
    if p.behind_since is null then
      update public.plans set behind_since = v_today where id = p.id;
      perform private.notify(p.household_id, 'plan_behind', p.id, v_today::text,
        v_name || ' is falling behind',
        'Saved ' || private.rp(v_saved) || '; by now it should be about '
          || private.rp(v_expected) || '. Aim for ' || private.rp(v_needed) || ' a month.', v_link);
    end if;
  elsif p.behind_since is not null then
    update public.plans set behind_since = null where id = p.id;
  end if;

  -- monthly reminder from the 25th, if this month's share is not in yet
  if extract(day from v_today) >= 25 then
    select coalesce(sum(amount), 0) into v_thismon from public.plan_contributions
    where plan_id = p.id and date >= date_trunc('month', v_today)::date;
    if v_needed - v_thismon > 0 then
      perform private.notify(p.household_id, 'plan_monthly', p.id, to_char(v_today, 'YYYY-MM'),
        v_name || ': ' || private.rp(v_needed - v_thismon) || ' to go this month',
        'Putting in ' || private.rp(v_needed) || ' a month reaches ' || private.rp(p.target_amount)
          || ' by ' || private.long_date(p.target_date) || '.', v_link);
    end if;
  end if;
end;
$$;

-- Daily checks for one household: every plan, plus the month-close reminder
-- (FR-CLS-12: last day of the month from 19:00 WIB, then days 1, 3 and 7 of
-- the next month while the month that should be closed next is still open).
create function private.check_household(p_household uuid)
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
  if v_last and extract(hour from v_now) >= 19
     and (v_lock + 1 = v_this
          or (v_lock is null and v_next is null
              and exists (select 1 from public.transactions t where t.household_id = p_household))) then
    perform private.notify(p_household, 'month_close', null, to_char(v_this, 'YYYY-MM') || '-last',
      'Time to close ' || private.month_name(v_this),
      'The month ends tonight. Close it from tomorrow once the last entries are in.',
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

-- After a contribution, check milestones at once (FR-NTF-08).
create function private.after_contribution()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.check_plan(new.plan_id, false);
  return null;
end;
$$;

create trigger plan_contributions_milestones
  after insert or update of amount, plan_id on public.plan_contributions
  for each row execute function private.after_contribution();

-- ---------------------------------------------------------------
-- Plans in the closing statement (FR-PLN-11)
-- ---------------------------------------------------------------

-- Per plan: money put in during the month and progress at month end.
-- Lists plans that got money that month, plus plans running at month end.
create function private.plan_figures(p_household uuid, p_month date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with b as (
    select date_trunc('month', p_month)::date as m0,
           (date_trunc('month', p_month) + interval '1 month')::date as m1
  ),
  f as (
    select p.id, p.name, p.icon, p.status, p.target_amount, p.target_date,
      coalesce(sum(c.amount) filter (where c.date >= b.m0), 0) as contributed,
      coalesce(sum(c.amount), 0) as saved
    from public.plans p
    cross join b
    left join public.plan_contributions c on c.plan_id = p.id and c.date < b.m1
    where p.household_id = p_household and p.start_date < b.m1
    group by p.id, b.m0, b.m1
    having coalesce(sum(c.amount) filter (where c.date >= b.m0), 0) > 0
        or p.status in ('active', 'paused')
        or (p.status = 'achieved' and p.achieved_at >= b.m1)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'plan_id', id, 'name', name, 'icon', icon, 'status', status,
    'target', target_amount, 'target_date', target_date,
    'contributed', contributed, 'saved', saved,
    'progress', round(least(saved / target_amount * 100, 100), 1)
  ) order by target_date, name), '[]')
  from f;
$$;

-- period_statement and close_period keep calling private.period_figures;
-- the old body becomes period_figures_base and the new one adds 'plans'.
alter function private.period_figures(uuid, date) rename to period_figures_base;

create function private.period_figures(p_household uuid, p_month date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select private.period_figures_base(p_household, p_month)
    || jsonb_build_object('plans', private.plan_figures(p_household, p_month));
$$;

-- Store the plan section with each closing, and clear that month's
-- close reminders once it is closed.
create function private.closing_plans()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.plans := private.plan_figures(new.household_id, new.month);
  return new;
end;
$$;

create trigger ledger_closings_plans
  before insert on public.ledger_closings
  for each row execute function private.closing_plans();

create function private.closing_clears_reminders()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.notifications set read_at = now()
  where household_id = new.household_id and kind = 'month_close' and read_at is null
    and period_key like to_char(new.month, 'YYYY-MM') || '-%';
  return null;
end;
$$;

create trigger ledger_closings_clear_reminders
  after insert on public.ledger_closings
  for each row execute function private.closing_clears_reminders();

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------

-- Called by the app when it opens: runs the daily checks for this household
-- and returns the caller's unread count. Safe to call often; each
-- notification is created only once.
create function public.check_notifications(p_household uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_unread int;
begin
  if not private.is_member(p_household) then
    raise exception 'Not a member of this household';
  end if;
  perform private.check_household(p_household);
  select count(*) into v_unread from public.notifications
  where user_id = auth.uid() and read_at is null;
  return v_unread;
end;
$$;

-- Saves this device's Web Push subscription for the caller. An endpoint
-- belongs to one browser, so it moves to whoever signed in there last.
create function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default '')
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Incomplete push subscription';
  end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent, ''), 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, created_at = now();
end;
$$;

-- Called by pg_cron: runs the daily checks for every household and trims
-- old notifications (read ones after 90 days, all after a year).
create function public.run_notifications()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_h uuid;
begin
  for v_h in select id from public.households loop
    perform private.check_household(v_h);
  end loop;
  delete from public.notifications
  where (read_at is not null and created_at < now() - interval '90 days')
     or created_at < now() - interval '365 days';
end;
$$;

revoke all on function private.plan_rules() from public;
revoke all on function private.guard_plan_delete() from public;
revoke all on function private.contribution_rules() from public;
revoke all on function private.guard_closed_contribution() from public;
revoke all on function private.rp(numeric) from public;
revoke all on function private.month_name(date) from public;
revoke all on function private.long_date(date) from public;
revoke all on function private.notify(uuid, text, uuid, text, text, text, text) from public;
revoke all on function private.check_plan(uuid, boolean) from public;
revoke all on function private.check_household(uuid) from public;
revoke all on function private.after_contribution() from public;
revoke all on function private.plan_figures(uuid, date) from public;
revoke all on function private.period_figures(uuid, date) from public;
revoke all on function private.closing_plans() from public;
revoke all on function private.closing_clears_reminders() from public;
revoke all on function public.check_notifications(uuid) from public, anon;
revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke all on function public.run_notifications() from public, anon, authenticated;
grant execute on function public.check_notifications(uuid) to authenticated;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.run_notifications() to service_role;

-- ---------------------------------------------------------------
-- Live bell count (optional): stream notifications over Realtime.
-- ---------------------------------------------------------------
do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when others then
  raise notice 'Realtime not set up for notifications (%). The app still reads them when it opens.', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------
-- Schedule (optional): 07:00 and 19:00 WIB (00:00 and 12:00 UTC). Skipped
-- with a notice when pg_cron is not available; the app still runs the checks
-- when it opens. Re-running replaces the jobs of the same name.
-- ---------------------------------------------------------------
do $$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('finance-notifications-morning', '0 0 * * *', 'select public.run_notifications()');
  perform cron.schedule('finance-notifications-evening', '0 12 * * *', 'select public.run_notifications()');
exception when others then
  raise notice 'pg_cron is not set up (%). Notifications are still created when the app opens.', sqlerrm;
end;
$$;
