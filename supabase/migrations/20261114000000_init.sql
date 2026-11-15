-- FinanceTracker V2, phase 1: schema + row-level security.
--
-- Apply with `supabase db push`, or paste the whole file into the Supabase
-- SQL Editor and run it once.
--
-- Model: every row belongs to a household; a user may touch a row only if
-- they are a member of that household. Types and column names mirror the V1
-- Google Sheet (code.gs) so the import and the front-end port stay simple.

-- ---------------------------------------------------------------
-- Private helpers (schema is not exposed through the Data API)
-- ---------------------------------------------------------------
create schema if not exists private;

-- ---------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------
create table public.households (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  data_source text not null default 'supabase' check (data_source in ('supabase', 'sheets')),
  created_by  uuid references auth.users (id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);

create table public.members (
  household_id uuid not null references public.households (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  role         text not null default 'member' check (role in ('owner', 'member')),
  created_at   timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index members_user_idx on public.members (user_id);

-- User-defined accounts (replaces the hard-coded ACCOUNTS list).
create table public.accounts (
  id              uuid primary key default gen_random_uuid(),
  household_id    uuid not null references public.households (id) on delete cascade,
  name            text not null check (length(trim(name)) > 0),
  opening_balance numeric(18, 2) not null default 0,
  archived        boolean not null default false,
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now()
);
create unique index accounts_name_uq on public.accounts (household_id, lower(name));

create table public.categories (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  created_at   timestamptz not null default now()
);
create unique index categories_name_uq on public.categories (household_id, lower(name));

create table public.transactions (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  date           date not null default ((now() at time zone 'Asia/Jakarta')::date),
  type           text not null check (type in ('income', 'expense', 'invest', 'transfer-out', 'transfer-in')),
  category_id    uuid references public.categories (id) on delete set null,
  description    text not null default '',
  amount         numeric(18, 2) not null check (amount >= 0),
  source         text not null default 'web',
  account_id     uuid references public.accounts (id) on delete set null,  -- null = unassigned
  transfer_group uuid,          -- shared by the two legs of one transfer
  legacy_id      text,          -- V1 sheet id (TXN-..., TRF-...); makes the import re-runnable
  created_by     uuid references auth.users (id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  unique (household_id, legacy_id)
);
create index transactions_household_date_idx on public.transactions (household_id, date desc);
create index transactions_account_idx on public.transactions (account_id);

create table public.holdings (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  asset_type   text not null check (asset_type in ('gold', 'stock')),
  ticker       text not null default '',   -- gold is 'LM', brand goes in name
  name         text not null default '',
  quantity     numeric(18, 6) not null check (quantity > 0),  -- grams or shares
  buy_price    numeric(18, 2) not null check (buy_price >= 0), -- per gram / per share
  buy_date     date,
  legacy_id    text,
  created_at   timestamptz not null default now(),
  unique (household_id, legacy_id)
);
create index holdings_household_idx on public.holdings (household_id);

-- Realized P&L, one row per sale (the V1 "Realized" tab).
create table public.sales (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households (id) on delete cascade,
  date          date not null default ((now() at time zone 'Asia/Jakarta')::date),
  asset_type    text not null,
  ticker        text not null default '',
  name          text not null default '',
  quantity      numeric(18, 6) not null,
  avg_buy_price numeric(18, 2) not null,
  sell_price    numeric(18, 2) not null,
  proceeds      numeric(18, 2) not null,
  cost_basis    numeric(18, 2) not null,
  realized_pl   numeric(18, 2) not null,
  account_id    uuid references public.accounts (id) on delete set null,
  legacy_id     text,
  created_at    timestamptz not null default now(),
  unique (household_id, legacy_id)
);
create index sales_household_idx on public.sales (household_id, date desc);

-- Receipt photos (used from phase 3; the storage bucket is created then).
create table public.receipts (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references public.households (id) on delete cascade,
  transaction_id uuid references public.transactions (id) on delete cascade,
  storage_path   text not null,
  created_at     timestamptz not null default now()
);

-- Telegram chat linked to a member (used from phase 4).
create table public.telegram_links (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  household_id     uuid not null references public.households (id) on delete cascade,
  telegram_user_id bigint not null unique,
  linked_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- Membership checks. SECURITY DEFINER so policies on `members` do not
-- recurse into themselves; search_path is pinned for safety.
-- ---------------------------------------------------------------
create function private.is_member(hid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
    where m.household_id = hid and m.user_id = (select auth.uid())
  );
$$;

create function private.is_owner(hid uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
    where m.household_id = hid and m.user_id = (select auth.uid()) and m.role = 'owner'
  );
$$;

grant usage on schema private to authenticated;
revoke all on function private.is_member(uuid) from public;
revoke all on function private.is_owner(uuid) from public;
grant execute on function private.is_member(uuid) to authenticated;
grant execute on function private.is_owner(uuid) to authenticated;

-- ---------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------
alter table public.households     enable row level security;
alter table public.members        enable row level security;
alter table public.accounts       enable row level security;
alter table public.categories     enable row level security;
alter table public.transactions   enable row level security;
alter table public.holdings       enable row level security;
alter table public.sales          enable row level security;
alter table public.receipts       enable row level security;
alter table public.telegram_links enable row level security;

-- Households: members read; owners rename / switch source / delete.
-- Creation goes through create_household() below.
create policy households_select on public.households
  for select to authenticated using (private.is_member(id));
create policy households_update on public.households
  for update to authenticated using (private.is_owner(id)) with check (private.is_owner(id));
create policy households_delete on public.households
  for delete to authenticated using (private.is_owner(id));

-- Members: everyone in the household sees the list; owners remove people;
-- anyone may leave. Adding goes through add_member_by_email() below.
create policy members_select on public.members
  for select to authenticated using (private.is_member(household_id));
create policy members_delete on public.members
  for delete to authenticated
  using (private.is_owner(household_id) or user_id = (select auth.uid()));

-- Household data: full access for members, nothing for anyone else.
create policy accounts_all on public.accounts
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy categories_all on public.categories
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy transactions_all on public.transactions
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy holdings_all on public.holdings
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy sales_all on public.sales
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));
create policy receipts_all on public.receipts
  for all to authenticated
  using (private.is_member(household_id)) with check (private.is_member(household_id));

-- Telegram link: each user manages only their own.
create policy telegram_links_own on public.telegram_links
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and private.is_member(household_id));

-- Logged-out visitors get nothing, even if RLS were ever switched off.
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
-- Server-side jobs (import script, edge functions) use the secret key.
grant all on all tables in schema public to service_role;

-- ---------------------------------------------------------------
-- Per-account balance (V1 getAccountBalances_). Runs with the caller's
-- rights, so RLS still applies.
-- ---------------------------------------------------------------
create view public.account_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.household_id,
  a.name,
  a.archived,
  a.sort_order,
  a.opening_balance + coalesce(sum(
    case when t.type in ('income', 'transfer-in') then t.amount else -t.amount end
  ), 0) as balance
from public.accounts a
left join public.transactions t on t.account_id = a.id
group by a.id;

revoke all on public.account_balances from anon;
grant select on public.account_balances to authenticated, service_role;

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------

-- First-run onboarding: create a household, make the caller its owner,
-- and add the accounts they typed in.
create function public.create_household(p_name text, p_accounts text[] default '{}')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
  v_acc text;
  v_pos integer := 0;
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  insert into public.households (name, created_by)
  values (trim(p_name), v_uid) returning id into v_id;

  insert into public.members (household_id, user_id, role)
  values (v_id, v_uid, 'owner');

  foreach v_acc in array coalesce(p_accounts, '{}') loop
    if length(trim(v_acc)) > 0 then
      insert into public.accounts (household_id, name, sort_order)
      values (v_id, trim(v_acc), v_pos);
      v_pos := v_pos + 1;
    end if;
  end loop;

  return v_id;
end;
$$;

-- Owner adds an existing user (invited from the Supabase dashboard) by email.
create function public.add_member_by_email(p_household uuid, p_email text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid;
begin
  if not private.is_owner(p_household) then
    raise exception 'Only the household owner can add members';
  end if;

  select u.id into v_user from auth.users u where lower(u.email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No user with that email. Invite them first.';
  end if;

  insert into public.members (household_id, user_id, role)
  values (p_household, v_user, 'member')
  on conflict do nothing;
end;
$$;

-- Transfer = two linked rows, written atomically (V1 addTransfer_).
-- Runs as the caller, so RLS decides whether it is allowed.
create function public.add_transfer(
  p_household uuid,
  p_from      uuid,
  p_to        uuid,
  p_amount    numeric,
  p_date      date default null,
  p_note      text default '',
  p_source    text default 'web'
)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  v_group     uuid := gen_random_uuid();
  v_date      date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_from_name text;
  v_to_name   text;
  v_cat       uuid;
  v_suffix    text := case when coalesce(p_note, '') <> '' then ' - ' || p_note else '' end;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;
  if p_from = p_to then
    raise exception 'Choose two different accounts';
  end if;

  select name into v_from_name from public.accounts where id = p_from and household_id = p_household;
  select name into v_to_name   from public.accounts where id = p_to   and household_id = p_household;
  if v_from_name is null or v_to_name is null then
    raise exception 'Account not found in this household';
  end if;

  select id into v_cat from public.categories
  where household_id = p_household and lower(name) = 'transfer';
  if v_cat is null then
    insert into public.categories (household_id, name)
    values (p_household, 'Transfer') returning id into v_cat;
  end if;

  insert into public.transactions
    (household_id, date, type, category_id, description, amount, source, account_id, transfer_group)
  values
    (p_household, v_date, 'transfer-out', v_cat, 'To ' || v_to_name || v_suffix,
     p_amount, p_source, p_from, v_group),
    (p_household, v_date, 'transfer-in', v_cat, 'From ' || v_from_name || v_suffix,
     p_amount, p_source, p_to, v_group);

  return v_group;
end;
$$;

-- Sell a holding (V1 sellHolding_): draw lots down first-in first-out,
-- log the proceeds as income, and record realized P&L. All or nothing.
-- Match by p_holding (one lot) or by p_ticker and/or p_name.
create function public.sell_holding(
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

-- RPCs are for signed-in users only.
revoke all on function public.create_household(text, text[]) from public, anon;
revoke all on function public.add_member_by_email(uuid, text) from public, anon;
revoke all on function public.add_transfer(uuid, uuid, uuid, numeric, date, text, text) from public, anon;
revoke all on function public.sell_holding(uuid, numeric, numeric, uuid, uuid, text, text, date, text) from public, anon;
grant execute on function public.create_household(text, text[]) to authenticated;
grant execute on function public.add_member_by_email(uuid, text) to authenticated;
grant execute on function public.add_transfer(uuid, uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.sell_holding(uuid, numeric, numeric, uuid, uuid, text, text, date, text) to authenticated;
