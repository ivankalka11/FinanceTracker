-- V2.6: the plan ledger, gold and stocks inside plans, and earmarks.
--
-- A plan is an earmark, not an account. Money stays in the real account
-- (plans.account_id), so account balances keep matching the bank. The plan
-- ledger records every movement of a plan:
--   deposit / withdrawal / adjustment   cash set aside, taken out, corrected
--   asset_in / asset_out                a holding (gold or stock) assigned or released
-- Plan value = cash + assigned holdings. The database values holdings at cost
-- (it has no live prices); the app values them live from the prices function.
-- Month-end market prices are stored before closing so a statement can be
-- reproduced (month_end_prices, set_month_end_prices()).
--
-- Needs 20261117000000_ledger_closing.sql and 20261118000000_plans.sql.
-- plan_contributions stays as a compatibility view over the deposit rows, so
-- the current app keeps working until it moves to plan_ledger.
-- Run this once in the SQL Editor (or with `supabase db push`).

-- ---------------------------------------------------------------
-- plan_contributions becomes plan_ledger
-- ---------------------------------------------------------------
alter table public.plan_contributions rename to plan_ledger;
alter index public.plan_contributions_plan_idx rename to plan_ledger_plan_idx;
alter index public.plan_contributions_household_idx rename to plan_ledger_household_idx;
alter policy plan_contributions_all on public.plan_ledger rename to plan_ledger_all;
alter trigger plan_contributions_rules on public.plan_ledger rename to plan_ledger_rules;
alter trigger plan_contributions_closed_month on public.plan_ledger rename to plan_ledger_closed_month;
alter trigger plan_contributions_milestones on public.plan_ledger rename to plan_ledger_milestones;

-- amounts are signed now: drop the old "amount > 0" check, whatever it was called
do $$
declare
  c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.plan_ledger'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ~* 'amount\)? *> *\(*0'
  loop
    execute format('alter table public.plan_ledger drop constraint %I', c.conname);
  end loop;
end;
$$;

alter table public.plan_ledger
  add column entry_type text not null default 'deposit'
    check (entry_type in ('deposit', 'withdrawal', 'adjustment', 'asset_in', 'asset_out')),
  add column holding_id  uuid references public.holdings (id) on delete set null,
  add column asset_type  text,           -- asset rows describe the asset themselves,
  add column ticker      text,           -- so they still read right after the lot is sold
  add column asset_name  text,
  add column quantity    numeric(18, 6), -- grams or shares
  add column unit_price  numeric(18, 2); -- price per gram / share when it was recorded

alter table public.plan_ledger add constraint plan_ledger_shape check (
  case entry_type
    when 'deposit'    then amount > 0
    when 'withdrawal' then amount < 0
    when 'adjustment' then amount <> 0
    else amount >= 0
  end
  and (entry_type in ('asset_in', 'asset_out')) = (quantity is not null)
  and (quantity is null or quantity > 0)
  and (entry_type in ('asset_in', 'asset_out')
       or (holding_id is null and asset_type is null and ticker is null
           and asset_name is null and unit_price is null))
  and (entry_type not in ('asset_in', 'asset_out')
       or (asset_type in ('gold', 'stock') and unit_price is not null and unit_price >= 0
           and ticker is not null and asset_name is not null))
);

-- ---------------------------------------------------------------
-- Holdings assigned to plans
-- ---------------------------------------------------------------
-- How much of each lot is earmarked for each plan. Changed only through
-- assign_holding_to_plan / unassign_holding_from_plan (and the sale trigger below).
create table public.plan_holdings (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  plan_id      uuid not null references public.plans (id) on delete cascade,
  holding_id   uuid not null references public.holdings (id) on delete cascade,
  quantity     numeric(18, 6) not null check (quantity > 0),
  created_by   uuid references auth.users (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now(),
  unique (plan_id, holding_id)
);
create index plan_holdings_household_idx on public.plan_holdings (household_id);
create index plan_holdings_holding_idx on public.plan_holdings (holding_id);

-- Market price of each asset on the last day of a month, saved before closing.
-- Keys are normalised the way sell_holding matches lots: ticker upper, name lower.
create table public.month_end_prices (
  household_id uuid not null references public.households (id) on delete cascade,
  month        date not null check (month = date_trunc('month', month)::date),
  asset_type   text not null check (asset_type in ('gold', 'stock')),
  ticker       text not null default '',
  name         text not null default '',
  price        numeric(18, 2) not null check (price > 0),
  created_at   timestamptz not null default now(),
  primary key (household_id, month, asset_type, ticker, name)
);

-- ---------------------------------------------------------------
-- Row-level security and grants
-- ---------------------------------------------------------------
alter table public.plan_holdings    enable row level security;
alter table public.month_end_prices enable row level security;

-- Members add and fix cash entries; asset rows come only from the functions below.
drop policy plan_ledger_all on public.plan_ledger;
create policy plan_ledger_select on public.plan_ledger
  for select to authenticated using (private.is_member(household_id));
create policy plan_ledger_insert on public.plan_ledger
  for insert to authenticated
  with check (private.is_member(household_id) and entry_type in ('deposit', 'withdrawal', 'adjustment'));
create policy plan_ledger_update on public.plan_ledger
  for update to authenticated
  using (private.is_member(household_id) and entry_type in ('deposit', 'withdrawal', 'adjustment'))
  with check (private.is_member(household_id) and entry_type in ('deposit', 'withdrawal', 'adjustment'));
create policy plan_ledger_delete on public.plan_ledger
  for delete to authenticated
  using (private.is_member(household_id) and entry_type in ('deposit', 'withdrawal', 'adjustment'));

create policy plan_holdings_select on public.plan_holdings
  for select to authenticated using (private.is_member(household_id));
create policy month_end_prices_select on public.month_end_prices
  for select to authenticated using (private.is_member(household_id));

revoke all on public.plan_ledger, public.plan_holdings, public.month_end_prices from anon;
revoke all on public.plan_ledger, public.plan_holdings, public.month_end_prices from authenticated;
grant select, insert, delete on public.plan_ledger to authenticated;
grant update (plan_id, date, amount, note, transaction_id) on public.plan_ledger to authenticated;
grant select on public.plan_holdings, public.month_end_prices to authenticated;
grant all on public.plan_ledger, public.plan_holdings, public.month_end_prices to service_role;

-- ---------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------

-- Same checks as before. A cancelled plan takes no new money or assets, but
-- money and assets can still leave it (a withdrawal, or a lot being sold).
create or replace function private.contribution_rules()
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
  if v_plan.status = 'cancelled' and new.entry_type in ('deposit', 'adjustment', 'asset_in')
     and (tg_op = 'INSERT' or new.plan_id <> old.plan_id) then
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

-- Entries dated in a closed month are locked, as before. The "set null" that
-- follows deleting the linked transaction or the sold lot still passes.
create or replace function private.guard_closed_contribution()
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
    if (new.transaction_id is null or new.transaction_id is not distinct from old.transaction_id)
       and (new.holding_id is null or new.holding_id is not distinct from old.holding_id)
       and to_jsonb(new) - 'transaction_id' - 'holding_id' = to_jsonb(old) - 'transaction_id' - 'holding_id' then
      return new;
    end if;
    raise exception 'Closed month: entries up to % are locked. An owner can reopen the month.', to_char(v_lock, 'DD Mon YYYY');
  end if;
  return new;
end;
$$;

-- A plan's cash can never go below zero.
create function private.guard_plan_cash()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan uuid;
begin
  for v_plan in
    select distinct x from unnest(array[
      case when tg_op <> 'INSERT' then old.plan_id end,
      case when tg_op <> 'DELETE' then new.plan_id end]) as x where x is not null
  loop
    if exists (select 1 from public.plans p join public.households h on h.id = p.household_id where p.id = v_plan)
       and private.plan_cash(v_plan) < 0 then
      raise exception 'That would take the plan below zero. Withdraw less.';
    end if;
  end loop;
  return null;
end;
$$;

create trigger plan_ledger_cash_floor
  after insert or update or delete on public.plan_ledger
  for each row execute function private.guard_plan_cash();

-- Assigned quantities: same household, never more than the lot holds.
create function private.plan_holding_rules()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_hold  public.holdings;
  v_other numeric;
begin
  if not exists (select 1 from public.plans p where p.id = new.plan_id and p.household_id = new.household_id) then
    raise exception 'That plan is not in this household';
  end if;
  select * into v_hold from public.holdings h where h.id = new.holding_id for update;
  if v_hold.id is null or v_hold.household_id <> new.household_id then
    raise exception 'That holding is not in this household';
  end if;
  select coalesce(sum(ph.quantity), 0) into v_other
  from public.plan_holdings ph where ph.holding_id = new.holding_id and ph.id <> new.id;
  if v_other + new.quantity > v_hold.quantity then
    raise exception 'Only % of this holding is free to assign', v_hold.quantity - v_other;
  end if;
  return new;
end;
$$;

create trigger plan_holdings_rules
  before insert or update on public.plan_holdings
  for each row execute function private.plan_holding_rules();

-- When a lot is sold down or deleted, take the sold quantity out of the plans
-- (newest assignment first) and record it as asset_out. The sale proceeds are
-- not moved into the plan; that is a separate decision.
create function private.release_plan_holdings()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_keep   numeric := case when tg_op = 'DELETE' then 0 else new.quantity end;
  v_total  numeric;
  v_extra  numeric;
  v_take   numeric;
  v_today  date := (now() at time zone 'Asia/Jakarta')::date;
  v_lock   date;
  v_date   date;
  r        record;
begin
  if tg_op = 'UPDATE' and new.quantity >= old.quantity then
    return new;
  end if;
  if exists (select 1 from public.households h where h.id = old.household_id) then
    select coalesce(sum(ph.quantity), 0) into v_total from public.plan_holdings ph where ph.holding_id = old.id;
    v_extra := v_total - v_keep;
    if v_extra > 0 then
      v_lock := private.locked_through(old.household_id);
      v_date := greatest(v_today, coalesce(v_lock + 1, v_today));
      for r in
        select ph.id, ph.plan_id, ph.quantity from public.plan_holdings ph
        where ph.holding_id = old.id order by ph.created_at desc, ph.id
      loop
        exit when v_extra <= 0;
        v_take := least(r.quantity, v_extra);
        if v_take >= r.quantity then
          delete from public.plan_holdings where id = r.id;
        else
          update public.plan_holdings set quantity = quantity - v_take where id = r.id;
        end if;
        insert into public.plan_ledger
          (household_id, plan_id, date, amount, note, entry_type, holding_id,
           asset_type, ticker, asset_name, quantity, unit_price)
        values
          (old.household_id, r.plan_id, v_date, round(v_take * old.buy_price, 2), 'Holding sold or removed',
           'asset_out', old.id, old.asset_type, old.ticker, old.name, v_take, old.buy_price);
        v_extra := v_extra - v_take;
      end loop;
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger holdings_release_plan_holdings
  before update of quantity or delete on public.holdings
  for each row execute function private.release_plan_holdings();

-- A plan with ledger entries or assigned holdings can only be cancelled.
create or replace function private.guard_plan_delete()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.households h where h.id = old.household_id)
     and (exists (select 1 from public.plan_ledger l where l.plan_id = old.id)
          or exists (select 1 from public.plan_holdings ph where ph.plan_id = old.id)) then
    raise exception 'This plan has money in it. Cancel it instead of deleting it.';
  end if;
  return old;
end;
$$;

-- ---------------------------------------------------------------
-- Figures
-- ---------------------------------------------------------------

-- Cash in a plan: deposits, withdrawals and adjustments.
create function private.plan_cash(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(l.amount), 0) from public.plan_ledger l
  where l.plan_id = p_plan and l.entry_type in ('deposit', 'withdrawal', 'adjustment');
$$;

-- Assigned holdings at cost (the database has no live prices).
create function private.plan_assets_cost(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(ph.quantity * h.buy_price), 0)
  from public.plan_holdings ph join public.holdings h on h.id = ph.holding_id
  where ph.plan_id = p_plan;
$$;

create function private.plan_saved(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select private.plan_cash(p_plan) + private.plan_assets_cost(p_plan);
$$;

-- Same checks as before, but "saved" is cash plus assigned holdings at cost,
-- and this month's share counts net flow (assets assigned count as money put in).
create or replace function private.check_plan(p_plan uuid, p_daily boolean)
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

  v_saved := private.plan_saved(p.id);
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
    select coalesce(sum(case when l.entry_type = 'asset_out' then -l.amount else l.amount end), 0)
    into v_thismon from public.plan_ledger l
    where l.plan_id = p.id and l.date >= date_trunc('month', v_today)::date;
    if v_needed - v_thismon > 0 then
      perform private.notify(p.household_id, 'plan_monthly', p.id, to_char(v_today, 'YYYY-MM'),
        v_name || ': ' || private.rp(v_needed - v_thismon) || ' to go this month',
        'Putting in ' || private.rp(v_needed) || ' a month reaches ' || private.rp(p.target_amount)
          || ' by ' || private.long_date(p.target_date) || '.', v_link);
    end if;
  end if;
end;
$$;

-- Per plan, for the closing statement. Cash is split into opening, deposits,
-- withdrawals, adjustments and closing; assigned holdings are rebuilt from the
-- ledger as of month end and valued at the saved month-end price, or at the
-- last recorded price when none was saved (assets_priced says which).
-- Old keys (contributed, saved, progress) keep their meaning.
create or replace function private.plan_figures(p_household uuid, p_month date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with b as (
    select date_trunc('month', p_month)::date as m0,
           (date_trunc('month', p_month) + interval '1 month')::date as m1
  ),
  cash as (
    select l.plan_id,
      coalesce(sum(l.amount) filter (where l.entry_type in ('deposit', 'withdrawal', 'adjustment')
                                       and l.date < b.m0), 0) as opening_cash,
      coalesce(sum(l.amount) filter (where l.entry_type = 'deposit' and l.date >= b.m0), 0) as deposits,
      coalesce(-sum(l.amount) filter (where l.entry_type = 'withdrawal' and l.date >= b.m0), 0) as withdrawals,
      coalesce(sum(l.amount) filter (where l.entry_type = 'adjustment' and l.date >= b.m0), 0) as adjustments,
      coalesce(sum(l.amount) filter (where l.entry_type in ('deposit', 'withdrawal', 'adjustment')), 0) as closing_cash,
      count(*) filter (where l.date >= b.m0) as entries
    from public.plan_ledger l cross join b
    where l.household_id = p_household and l.date < b.m1
    group by l.plan_id
  ),
  held as (
    select l.plan_id, l.asset_type, upper(trim(l.ticker)) as t, lower(trim(l.asset_name)) as n,
      sum(case when l.entry_type = 'asset_in' then l.quantity else -l.quantity end) as qty,
      (array_agg(l.unit_price order by l.date desc, l.created_at desc))[1] as last_price
    from public.plan_ledger l cross join b
    where l.household_id = p_household and l.date < b.m1 and l.entry_type in ('asset_in', 'asset_out')
    group by l.plan_id, l.asset_type, upper(trim(l.ticker)), lower(trim(l.asset_name))
    having sum(case when l.entry_type = 'asset_in' then l.quantity else -l.quantity end) > 0
  ),
  valued as (
    select h.plan_id, h.qty * coalesce(mp.price, h.last_price) as value, (mp.price is not null) as market
    from held h cross join b
    left join public.month_end_prices mp
      on mp.household_id = p_household and mp.month = b.m0
     and mp.asset_type = h.asset_type and mp.ticker = h.t and mp.name = h.n
  ),
  assets as (
    select v.plan_id, sum(v.value) as asset_value, bool_and(v.market) as all_market
    from valued v group by v.plan_id
  ),
  f as (
    select p.id, p.name, p.icon, p.status, p.target_amount, p.target_date,
      coalesce(c.opening_cash, 0) as opening_cash, coalesce(c.deposits, 0) as deposits,
      coalesce(c.withdrawals, 0) as withdrawals, coalesce(c.adjustments, 0) as adjustments,
      coalesce(c.closing_cash, 0) as closing_cash,
      coalesce(a.asset_value, 0) as asset_value, a.all_market
    from public.plans p
    cross join b
    left join cash c on c.plan_id = p.id
    left join assets a on a.plan_id = p.id
    where p.household_id = p_household and p.start_date < b.m1
      and (coalesce(c.entries, 0) > 0
           or p.status in ('active', 'paused')
           or (p.status = 'achieved' and p.achieved_at >= b.m1))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'plan_id', id, 'name', name, 'icon', icon, 'status', status,
    'target', target_amount, 'target_date', target_date,
    'opening_cash', opening_cash, 'deposits', deposits, 'withdrawals', withdrawals,
    'adjustments', adjustments, 'cash', closing_cash,
    'asset_value', asset_value,
    'assets_priced', case when all_market is null then null when all_market then 'market' else 'cost' end,
    'contributed', deposits,
    'saved', closing_cash + asset_value,
    'progress', round(greatest(least((closing_cash + asset_value) / target_amount * 100, 100), 0), 1)
  ) order by target_date, name), '[]')
  from f;
$$;

-- ---------------------------------------------------------------
-- Views for the app
-- ---------------------------------------------------------------

-- Old name, old shape: the deposit rows. Lets the current app keep working.
create view public.plan_contributions with (security_invoker = true) as
  select id, household_id, plan_id, date, amount, note, transaction_id, created_by, created_at
  from public.plan_ledger
  where entry_type = 'deposit'
  with check option;

-- The ledger with a running balance per plan: cash alone, and cash plus
-- assigned holdings at the price they were recorded at.
create view public.plan_ledger_running with (security_invoker = true) as
  select l.*,
    sum(case when l.entry_type in ('deposit', 'withdrawal', 'adjustment') then l.amount else 0 end)
      over (partition by l.plan_id order by l.date, l.created_at, l.id) as cash_balance,
    sum(case when l.entry_type = 'asset_out' then -l.amount else l.amount end)
      over (partition by l.plan_id order by l.date, l.created_at, l.id) as value_balance
  from public.plan_ledger l;

revoke all on public.plan_contributions, public.plan_ledger_running from anon;
grant select, insert, update, delete on public.plan_contributions to authenticated;
grant select on public.plan_ledger_running to authenticated;
grant all on public.plan_contributions, public.plan_ledger_running to service_role;

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------

-- Earmark a quantity of a lot for a plan. p_price is the price to record
-- (the app passes the live one); it defaults to the lot's cost.
create function public.assign_holding_to_plan(
  p_plan     uuid,
  p_holding  uuid,
  p_quantity numeric,
  p_price    numeric default null,
  p_date     date default null
)
returns public.plan_ledger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan  public.plans;
  v_hold  public.holdings;
  v_price numeric;
  v_row   public.plan_ledger;
begin
  select * into v_plan from public.plans where id = p_plan;
  if v_plan.id is null or not private.is_member(v_plan.household_id) then
    raise exception 'Plan not found';
  end if;
  if v_plan.status = 'cancelled' then
    raise exception 'This plan is cancelled. Resume it first.';
  end if;
  select * into v_hold from public.holdings where id = p_holding and household_id = v_plan.household_id;
  if v_hold.id is null then
    raise exception 'Holding not found';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be positive';
  end if;
  v_price := coalesce(p_price, v_hold.buy_price);
  if v_price < 0 then
    raise exception 'Price cannot be negative';
  end if;

  insert into public.plan_holdings (household_id, plan_id, holding_id, quantity)
  values (v_plan.household_id, p_plan, p_holding, p_quantity)
  on conflict (plan_id, holding_id) do update set quantity = public.plan_holdings.quantity + excluded.quantity;

  insert into public.plan_ledger
    (household_id, plan_id, date, amount, note, entry_type, holding_id,
     asset_type, ticker, asset_name, quantity, unit_price)
  values
    (v_plan.household_id, p_plan, coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date),
     round(p_quantity * v_price, 2), '', 'asset_in', p_holding,
     v_hold.asset_type, v_hold.ticker, v_hold.name, p_quantity, v_price)
  returning * into v_row;
  return v_row;
end;
$$;

-- Take a quantity of a lot back out of a plan (all of it when p_quantity is null).
create function public.unassign_holding_from_plan(
  p_plan     uuid,
  p_holding  uuid,
  p_quantity numeric default null,
  p_price    numeric default null,
  p_date     date default null
)
returns public.plan_ledger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan  public.plans;
  v_hold  public.holdings;
  v_ph    public.plan_holdings;
  v_qty   numeric;
  v_price numeric;
  v_row   public.plan_ledger;
begin
  select * into v_plan from public.plans where id = p_plan;
  if v_plan.id is null or not private.is_member(v_plan.household_id) then
    raise exception 'Plan not found';
  end if;
  select * into v_ph from public.plan_holdings where plan_id = p_plan and holding_id = p_holding for update;
  if v_ph.id is null then
    raise exception 'That holding is not assigned to this plan';
  end if;
  select * into v_hold from public.holdings where id = p_holding;
  v_qty := coalesce(p_quantity, v_ph.quantity);
  if v_qty <= 0 or v_qty > v_ph.quantity then
    raise exception 'Only % is assigned to this plan', v_ph.quantity;
  end if;
  v_price := coalesce(p_price, v_hold.buy_price);
  if v_price < 0 then
    raise exception 'Price cannot be negative';
  end if;

  if v_qty >= v_ph.quantity then
    delete from public.plan_holdings where id = v_ph.id;
  else
    update public.plan_holdings set quantity = quantity - v_qty where id = v_ph.id;
  end if;

  insert into public.plan_ledger
    (household_id, plan_id, date, amount, note, entry_type, holding_id,
     asset_type, ticker, asset_name, quantity, unit_price)
  values
    (v_plan.household_id, p_plan, coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date),
     round(v_qty * v_price, 2), '', 'asset_out', p_holding,
     v_hold.asset_type, v_hold.ticker, v_hold.name, v_qty, v_price)
  returning * into v_row;
  return v_row;
end;
$$;

-- Cash earmarked per account: the cash in every plan that is not cancelled.
-- Free to spend = account balance minus this. Assets are not cash accounts,
-- so they are not counted here.
create function public.account_earmarks(p_household uuid)
returns table (account_id uuid, earmarked numeric)
language sql stable security definer set search_path = ''
as $$
  select p.account_id, coalesce(sum(l.amount), 0)
  from public.plans p
  join public.plan_ledger l on l.plan_id = p.id and l.entry_type in ('deposit', 'withdrawal', 'adjustment')
  where p.household_id = p_household and p.status <> 'cancelled' and p.account_id is not null
    and private.is_member(p_household)
  group by p.account_id;
$$;

-- Owners save the month-end market price of each asset before closing, so the
-- statement values assigned holdings at market. p_prices is a JSON array of
-- {asset_type, ticker, name, price}. Closed months cannot be changed.
create function public.set_month_end_prices(p_household uuid, p_month date, p_prices jsonb)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_lock  date := private.locked_through(p_household);
  v_n     int;
begin
  if not private.is_owner(p_household) then
    raise exception 'Only an owner can set month-end prices';
  end if;
  if v_lock is not null and v_month <= v_lock then
    raise exception 'That month is already closed';
  end if;
  if jsonb_typeof(p_prices) <> 'array' then
    raise exception 'Prices must be a list';
  end if;
  insert into public.month_end_prices (household_id, month, asset_type, ticker, name, price)
  select p_household, v_month, x.asset_type, upper(trim(coalesce(x.ticker, ''))),
         lower(trim(coalesce(x.name, ''))), x.price
  from jsonb_to_recordset(p_prices) as x(asset_type text, ticker text, name text, price numeric)
  where x.price > 0 and x.asset_type in ('gold', 'stock')
  on conflict (household_id, month, asset_type, ticker, name) do update set price = excluded.price;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function private.guard_plan_cash() from public;
revoke all on function private.plan_holding_rules() from public;
revoke all on function private.release_plan_holdings() from public;
revoke all on function private.plan_cash(uuid) from public;
revoke all on function private.plan_assets_cost(uuid) from public;
revoke all on function private.plan_saved(uuid) from public;
revoke all on function public.assign_holding_to_plan(uuid, uuid, numeric, numeric, date) from public, anon;
revoke all on function public.unassign_holding_from_plan(uuid, uuid, numeric, numeric, date) from public, anon;
revoke all on function public.account_earmarks(uuid) from public, anon;
revoke all on function public.set_month_end_prices(uuid, date, jsonb) from public, anon;
grant execute on function public.assign_holding_to_plan(uuid, uuid, numeric, numeric, date) to authenticated;
grant execute on function public.unassign_holding_from_plan(uuid, uuid, numeric, numeric, date) to authenticated;
grant execute on function public.account_earmarks(uuid) to authenticated;
grant execute on function public.set_month_end_prices(uuid, date, jsonb) to authenticated;
