-- Plan decisions, round 2.
--
-- 1. Selling gold or stocks that sit in a plan puts the sale proceeds into that
--    plan's cash (a deposit entry, "Sale proceeds: ...") on top of releasing the
--    holding (asset_out). Deleting a holding without selling it adds no cash.
--    sell_holding tells the release trigger the sell price through the
--    transaction-local setting ft.sale_price. Cancelled plans are skipped.
-- 2. Month-end prices record the date they are for (price_date), and the
--    statement says so (plans[].prices_on). The app fetches the price of the
--    last day of the month (the last trading day on or before it).
--
-- Needs 20261119000000_plan_ledger.sql.

alter table public.month_end_prices add column price_date date;

-- Release trigger function (now with sale proceeds)
create or replace function private.release_plan_holdings()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_keep   numeric := case when tg_op = 'DELETE' then 0 else new.quantity end;
  v_total  numeric;
  v_extra  numeric;
  v_take   numeric;
  v_today  date := (now() at time zone 'Asia/Jakarta')::date;
  v_sale   numeric := nullif(current_setting('ft.sale_price', true), '')::numeric; -- set by sell_holding
  v_status text;
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
        -- a sale (not a plain delete) puts its proceeds into the plan's cash
        if v_sale is not null and v_sale > 0 then
          select p.status into v_status from public.plans p where p.id = r.plan_id;
          if v_status is distinct from 'cancelled' then
            insert into public.plan_ledger
              (household_id, plan_id, date, amount, note, entry_type)
            values
              (old.household_id, r.plan_id, v_date, round(v_take * v_sale, 2),
               'Sale proceeds: ' || coalesce(nullif(old.name, ''), nullif(old.ticker, ''), old.asset_type), 'deposit');
          end if;
        end if;
        v_extra := v_extra - v_take;
      end loop;
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- sell_holding (now sets ft.sale_price)
create or replace function public.sell_holding(
  p_household  uuid,
  p_quantity   numeric,
  p_sell_price numeric,
  p_account    uuid default null,
  p_holding    uuid default null,
  p_ticker     text default null,
  p_name       text default null,
  p_date       date default null,
  p_source     text default 'web'
)
returns public.sales
language plpgsql security invoker set search_path = ''
as $$
declare
  v_date      date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_ticker    text := upper(trim(coalesce(p_ticker, '')));
  v_name      text := lower(trim(coalesce(p_name, '')));
  v_remaining numeric := p_quantity;
  v_available numeric := 0;
  v_cost      numeric := 0;
  v_take      numeric;
  v_type      text;
  v_lot_tick  text;
  v_lot_name  text;
  v_label     text;
  v_proceeds  numeric;
  v_cat       uuid;
  v_lot       record;
  v_sale      public.sales;
begin
  if p_quantity is null or p_quantity <= 0 or p_sell_price is null or p_sell_price <= 0 then
    raise exception 'Quantity and sell price must be positive';
  end if;
  if p_holding is null and v_ticker = '' and v_name = '' then
    raise exception 'Say which holding to sell';
  end if;

  -- tell the plan-release trigger the sell price, so proceeds reach the plans (this transaction only)
  perform set_config('ft.sale_price', p_sell_price::text, true);

  for v_lot in
    select h.* from public.holdings h
    where h.household_id = p_household
      and (
        (p_holding is not null and h.id = p_holding)
        or (p_holding is null
            and (v_ticker = '' or upper(trim(h.ticker)) = v_ticker)
            and (v_name   = '' or lower(trim(h.name))   = v_name))
      )
    order by h.created_at, h.id
    for update
  loop
    v_available := v_available + v_lot.quantity;
    v_type := v_lot.asset_type; v_lot_tick := v_lot.ticker; v_lot_name := v_lot.name;

    if v_remaining > 0 then
      v_take := least(v_lot.quantity, v_remaining);
      v_cost := v_cost + v_take * v_lot.buy_price;
      v_remaining := v_remaining - v_take;
      if v_lot.quantity - v_take <= 0 then
        delete from public.holdings where id = v_lot.id;
      else
        update public.holdings set quantity = quantity - v_take where id = v_lot.id;
      end if;
    end if;
  end loop;

  perform set_config('ft.sale_price', '', true);

  if v_type is null then
    raise exception 'No matching holding found';
  end if;
  if v_remaining > 0 then
    -- raising rolls back the draw-down above
    raise exception 'Selling % but only % held', p_quantity, v_available;
  end if;

  v_proceeds := p_quantity * p_sell_price;
  v_label := coalesce(nullif(v_lot_name, ''), nullif(v_lot_tick, ''), v_type);

  select id into v_cat from public.categories
  where household_id = p_household and lower(name) = 'asset sale';
  if v_cat is null then
    insert into public.categories (household_id, name)
    values (p_household, 'Asset Sale') returning id into v_cat;
  end if;

  insert into public.transactions
    (household_id, date, type, category_id, description, amount, source, account_id)
  values
    (p_household, v_date, 'income', v_cat,
     'Sold ' || p_quantity || ' ' || v_label || ' @ ' || p_sell_price ||
       case when v_proceeds - v_cost >= 0 then ' (gain)' else ' (loss)' end,
     v_proceeds, p_source, p_account);

  insert into public.sales
    (household_id, date, asset_type, ticker, name, quantity, avg_buy_price,
     sell_price, proceeds, cost_basis, realized_pl, account_id)
  values
    (p_household, v_date, v_type, v_lot_tick, v_lot_name, p_quantity, v_cost / p_quantity,
     p_sell_price, v_proceeds, v_cost, v_proceeds - v_cost, p_account)
  returning * into v_sale;

  return v_sale;
end;
$$;

-- Plan figures (now with prices_on)
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
    'adjustments', adjustments, 'cash', closing_cash,
    'asset_value', asset_value,
    'prices_on', prices_on,
    'assets_priced', case when all_market is null then null when all_market then 'market' else 'cost' end,
    'contributed', deposits,
    'saved', closing_cash + asset_value,
    'progress', round(greatest(least((closing_cash + asset_value) / target_amount * 100, 100), 0), 1)
  ) order by target_date, name), '[]')
  from f;
$$;

-- set_month_end_prices (now takes price_date per row)
create or replace function public.set_month_end_prices(p_household uuid, p_month date, p_prices jsonb)
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
  insert into public.month_end_prices (household_id, month, asset_type, ticker, name, price, price_date)
  select p_household, v_month, x.asset_type, upper(trim(coalesce(x.ticker, ''))),
         lower(trim(coalesce(x.name, ''))), x.price,
         coalesce(x.price_date, (now() at time zone 'Asia/Jakarta')::date)
  from jsonb_to_recordset(p_prices) as x(asset_type text, ticker text, name text, price numeric, price_date date)
  where x.price > 0 and x.asset_type in ('gold', 'stock')
  on conflict (household_id, month, asset_type, ticker, name) do update set price = excluded.price, price_date = excluded.price_date;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
