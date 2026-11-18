-- =====================================================================
-- V2.13: paying from a plan (plan ledger entry type "spend").
--
-- Paying a vendor 5 juta from a 30 juta plan is both a real expense on an
-- account and cash leaving the plan. The plan keeps its progress:
--   saved = cash + gold and stocks + spent
-- so the 30 juta plan shows 25 juta cash + 5 juta spent = 30 juta.
--
-- A spend row is written only by spend_from_plan() and removed only by
-- delete_plan_spend() (or by deleting the expense it points at), so the
-- expense and the plan entry always live and die together.
-- Closing a plan also remembers the progress it had ("Cancelled at 83%").
-- Run after 20261124000000_query_performance.sql.
-- =====================================================================

-- ---------------------------------------------------------------
-- Entry type and shape
-- ---------------------------------------------------------------
alter table public.plan_ledger drop constraint plan_ledger_entry_type_check;
alter table public.plan_ledger add constraint plan_ledger_entry_type_check
  check (entry_type in ('deposit', 'withdrawal', 'adjustment', 'asset_in', 'asset_out', 'spend'));

alter table public.plan_ledger drop constraint plan_ledger_shape;
alter table public.plan_ledger add constraint plan_ledger_shape check (
  case entry_type
    when 'deposit'    then amount > 0
    when 'withdrawal' then amount < 0
    when 'adjustment' then amount <> 0
    when 'spend'      then amount < 0 and transaction_id is not null
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

-- The row-level security policies stay as they are: they only let members write
-- deposit, withdrawal and adjustment rows, so a spend row cannot be written
-- or edited directly, only through the functions below.

-- A cancelled plan takes no new money, assets or payments.
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
  if v_plan.status = 'cancelled' and new.entry_type in ('deposit', 'adjustment', 'asset_in', 'spend')
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

-- ---------------------------------------------------------------
-- Figures
-- ---------------------------------------------------------------

-- Cash in a plan: deposits, withdrawals, adjustments and payments made from it.
create or replace function private.plan_cash(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(l.amount), 0) from public.plan_ledger l
  where l.plan_id = p_plan and l.entry_type in ('deposit', 'withdrawal', 'adjustment', 'spend');
$$;

-- Money already paid out of a plan; it still counts as progress.
create function private.plan_spent(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(-sum(l.amount), 0) from public.plan_ledger l
  where l.plan_id = p_plan and l.entry_type = 'spend';
$$;

create or replace function private.plan_saved(p_plan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select private.plan_cash(p_plan) + private.plan_assets_cost(p_plan) + private.plan_spent(p_plan);
$$;

revoke all on function private.plan_spent(uuid) from public;

-- Same checks as before. "Saved" now includes what was spent, and a payment out
-- of the plan does not count against this month's share (it is not progress lost).
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
    where l.plan_id = p.id and l.date >= date_trunc('month', v_today)::date
      and l.entry_type <> 'spend';
    if v_needed - v_thismon > 0 then
      perform private.notify(p.household_id, 'plan_monthly', p.id, to_char(v_today, 'YYYY-MM'),
        v_name || ': ' || private.rp(v_needed - v_thismon) || ' to go this month',
        'Putting in ' || private.rp(v_needed) || ' a month reaches ' || private.rp(p.target_amount)
          || ' by ' || private.long_date(p.target_date) || '.', v_link);
    end if;
  end if;
end;
$$;

-- Per plan, for the closing statement: the cash movements (now with spent),
-- the value of assigned holdings, and saved including what was spent.
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
      coalesce(sum(l.amount) filter (where l.entry_type in ('deposit', 'withdrawal', 'adjustment', 'spend')
                                       and l.date < b.m0), 0) as opening_cash,
      coalesce(sum(l.amount) filter (where l.entry_type = 'deposit' and l.date >= b.m0), 0) as deposits,
      coalesce(-sum(l.amount) filter (where l.entry_type = 'withdrawal' and l.date >= b.m0), 0) as withdrawals,
      coalesce(sum(l.amount) filter (where l.entry_type = 'adjustment' and l.date >= b.m0), 0) as adjustments,
      coalesce(-sum(l.amount) filter (where l.entry_type = 'spend' and l.date >= b.m0), 0) as spent,
      coalesce(-sum(l.amount) filter (where l.entry_type = 'spend'), 0) as spent_total,
      coalesce(sum(l.amount) filter (where l.entry_type in ('deposit', 'withdrawal', 'adjustment', 'spend')), 0) as closing_cash,
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
    select h.plan_id, h.qty * coalesce(mp.price, h.last_price) as value, (mp.price is not null) as market, mp.price_date as pdate
    from held h cross join b
    left join public.month_end_prices mp
      on mp.household_id = p_household and mp.month = b.m0
     and mp.asset_type = h.asset_type and mp.ticker = h.t and mp.name = h.n
  ),
  assets as (
    select v.plan_id, sum(v.value) as asset_value, bool_and(v.market) as all_market,
           min(v.pdate) as prices_on
    from valued v group by v.plan_id
  ),
  f as (
    select p.id, p.name, p.icon, p.status, p.target_amount, p.target_date,
      coalesce(c.opening_cash, 0) as opening_cash, coalesce(c.deposits, 0) as deposits,
      coalesce(c.withdrawals, 0) as withdrawals, coalesce(c.adjustments, 0) as adjustments,
      coalesce(c.spent, 0) as spent, coalesce(c.spent_total, 0) as spent_total,
      coalesce(c.closing_cash, 0) as closing_cash,
      coalesce(a.asset_value, 0) as asset_value, a.all_market, a.prices_on
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
    'adjustments', adjustments, 'spent', spent, 'spent_total', spent_total, 'cash', closing_cash,
    'asset_value', asset_value,
    'prices_on', prices_on,
    'assets_priced', case when all_market is null then null when all_market then 'market' else 'cost' end,
    'contributed', deposits,
    'saved', closing_cash + asset_value + spent_total,
    'progress', round(greatest(least((closing_cash + asset_value + spent_total) / target_amount * 100, 100), 0), 1)
  ) order by target_date, name), '[]')
  from f;
$$;

-- Cash set aside per account: payments made from a plan lower it, like withdrawals.
create or replace function public.account_earmarks(p_household uuid)
returns table (account_id uuid, earmarked numeric)
language sql stable security definer set search_path = ''
as $$
  select p.account_id, coalesce(sum(l.amount), 0)
  from public.plans p
  join public.plan_ledger l on l.plan_id = p.id
    and l.entry_type in ('deposit', 'withdrawal', 'adjustment', 'spend')
  where p.household_id = p_household and p.status <> 'cancelled' and p.account_id is not null
    and private.is_member(p_household)
  group by p.account_id;
$$;

create or replace view public.plan_ledger_running with (security_invoker = true) as
  select l.*,
    sum(case when l.entry_type in ('deposit', 'withdrawal', 'adjustment', 'spend') then l.amount else 0 end)
      over (partition by l.plan_id order by l.date, l.created_at, l.id) as cash_balance,
    sum(case when l.entry_type = 'asset_out' then -l.amount else l.amount end)
      over (partition by l.plan_id order by l.date, l.created_at, l.id) as value_balance
  from public.plan_ledger l;

-- ---------------------------------------------------------------
-- The expense and its plan entry live and die together
-- ---------------------------------------------------------------

-- Deleting the expense (from Activity, or by delete_plan_spend) removes the plan entry first.
create function private.drop_plan_spend()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.plan_ledger where transaction_id = old.id and entry_type = 'spend';
  return old;
end;
$$;

create trigger transactions_drop_plan_spend
  before delete on public.transactions
  for each row execute function private.drop_plan_spend();

-- Amount, account, date and type of a plan payment change only through the plan.
create function private.guard_spend_transaction()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.plan_ledger l where l.transaction_id = old.id and l.entry_type = 'spend') then
    raise exception 'This expense was paid from a plan. Change it from the plan.';
  end if;
  return new;
end;
$$;

create trigger transactions_spend_guard
  before update on public.transactions
  for each row
  when (old.amount is distinct from new.amount
        or old.date is distinct from new.date
        or old.type is distinct from new.type
        or (new.account_id is not null and old.account_id is distinct from new.account_id))
  execute function private.guard_spend_transaction();

revoke all on function private.drop_plan_spend() from public;
revoke all on function private.guard_spend_transaction() from public;

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------

-- Pay for something from a plan: one expense on an account (default: the plan's
-- account) and the same amount out of the plan's cash, in one step.
create function public.spend_from_plan(
  p_plan     uuid,
  p_amount   numeric,
  p_account  uuid default null,
  p_category uuid default null,
  p_date     date default null,
  p_note     text default '',
  p_source   text default 'web'
)
returns public.plan_ledger
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan  public.plans;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_date  date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_acc   uuid;
  v_note  text := coalesce(trim(p_note), '');
  v_cash  numeric;
  v_tx    uuid;
  v_row   public.plan_ledger;
begin
  select * into v_plan from public.plans where id = p_plan for update;
  if v_plan.id is null or not private.is_member(v_plan.household_id) then
    raise exception 'Plan not found';
  end if;
  if v_plan.status = 'cancelled' then
    raise exception 'This plan is cancelled. Resume it first.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;
  if v_date > v_today then
    raise exception 'The date cannot be in the future';
  end if;
  v_acc := coalesce(p_account, v_plan.account_id);
  if v_acc is null then
    raise exception 'Choose the account the payment is made from';
  end if;
  if not exists (select 1 from public.accounts where id = v_acc and household_id = v_plan.household_id) then
    raise exception 'Account not found in this household';
  end if;
  if p_category is not null
     and not exists (select 1 from public.categories where id = p_category and household_id = v_plan.household_id) then
    raise exception 'Category not found in this household';
  end if;
  v_cash := private.plan_cash(p_plan);
  if p_amount > v_cash then
    raise exception 'The plan has only % in cash. Pay less, or sell gold or stocks into the plan first.', private.rp(v_cash);
  end if;

  insert into public.transactions
    (household_id, date, type, category_id, description, amount, source, account_id)
  values
    (v_plan.household_id, v_date, 'expense', p_category,
     case when v_note <> '' then v_note else 'Paid from plan: ' || v_plan.name end,
     p_amount, p_source, v_acc)
  returning id into v_tx;

  insert into public.plan_ledger
    (household_id, plan_id, date, amount, note, entry_type, transaction_id)
  values
    (v_plan.household_id, p_plan, v_date, -p_amount, v_note, 'spend', v_tx)
  returning * into v_row;
  return v_row;
end;
$$;

-- Undo a payment: removes the expense and the plan entry, and the cash goes back into the plan.
create function public.delete_plan_spend(p_entry uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.plan_ledger;
begin
  select * into l from public.plan_ledger where id = p_entry and entry_type = 'spend';
  if l.id is null or not private.is_member(l.household_id) then
    raise exception 'Payment not found';
  end if;
  delete from public.transactions where id = l.transaction_id;
end;
$$;

revoke all on function public.spend_from_plan(uuid, numeric, uuid, uuid, date, text, text) from public, anon;
revoke all on function public.delete_plan_spend(uuid) from public, anon;
grant execute on function public.spend_from_plan(uuid, numeric, uuid, uuid, date, text, text) to authenticated;
grant execute on function public.delete_plan_spend(uuid) to authenticated;

-- ---------------------------------------------------------------
-- Progress at the time a plan was closed ("Cancelled at 83%")
-- ---------------------------------------------------------------
alter table public.plans add column progress_at_close numeric(5, 1);
grant update (progress_at_close) on public.plans to authenticated;

create function private.plan_close_progress()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status in ('active', 'paused') then
    new.progress_at_close := null;
  end if;
  return new;
end;
$$;

create trigger plans_close_progress
  before insert or update on public.plans
  for each row execute function private.plan_close_progress();

revoke all on function private.plan_close_progress() from public;
