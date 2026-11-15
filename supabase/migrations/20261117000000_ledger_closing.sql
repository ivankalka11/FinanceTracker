-- V2.4: monthly ledger closing.
-- A month is closed only by an owner, by hand (close_period). Closing stores a
-- snapshot of the month's figures and locks every transaction and sale dated in
-- or before that month. reopen_period unlocks the latest closed month again and
-- records why. The first close may be any finished month (everything before it
-- becomes the opening balance); after that, months close one after another.
-- Run this once in the SQL Editor (or with `supabase db push`).

-- ---------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------
create table public.ledger_closings (
  id              uuid primary key default gen_random_uuid(),
  household_id    uuid not null references public.households (id) on delete cascade,
  month           date not null check (extract(day from month) = 1),
  version         int  not null default 1,
  status          text not null default 'closed' check (status in ('closed', 'superseded')),
  opening         numeric(18, 2) not null,
  income          numeric(18, 2) not null,
  expense         numeric(18, 2) not null,
  invest          numeric(18, 2) not null,
  transfer_in     numeric(18, 2) not null,
  transfer_out    numeric(18, 2) not null,
  closing         numeric(18, 2) not null,
  savings_rate    numeric(7, 2),
  realized_pl     numeric(18, 2) not null default 0,
  portfolio_value numeric(18, 2),
  unrealized_pl   numeric(18, 2),
  by_category     jsonb not null default '[]',
  checklist       jsonb not null default '{}',
  note            text not null default '',
  closed_by       uuid references auth.users (id) on delete set null default auth.uid(),
  closed_at       timestamptz not null default now(),
  unique (household_id, month, version)
);
-- at most one live snapshot per month; reopened ones become 'superseded'
create unique index ledger_closings_one_closed on public.ledger_closings (household_id, month)
  where status = 'closed';

create table public.ledger_closing_accounts (
  id              uuid primary key default gen_random_uuid(),
  closing_id      uuid not null references public.ledger_closings (id) on delete cascade,
  household_id    uuid not null references public.households (id) on delete cascade,
  account_id      uuid references public.accounts (id) on delete set null, -- null = unassigned entries
  account_name    text not null,
  sort_order      int not null default 0,
  opening         numeric(18, 2) not null,
  income          numeric(18, 2) not null,
  expense         numeric(18, 2) not null,
  invest          numeric(18, 2) not null,
  transfer_in     numeric(18, 2) not null,
  transfer_out    numeric(18, 2) not null,
  closing         numeric(18, 2) not null,
  bank_balance    numeric(18, 2),
  difference      numeric(18, 2),
  difference_note text not null default ''
);
create index ledger_closing_accounts_closing_idx on public.ledger_closing_accounts (closing_id);

create table public.ledger_closing_events (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  month        date not null,
  version      int  not null,
  action       text not null check (action in ('close', 'reopen')),
  reason       text not null default '',
  user_id      uuid references auth.users (id) on delete set null default auth.uid(),
  at           timestamptz not null default now()
);
create index ledger_closing_events_household_idx on public.ledger_closing_events (household_id, month);

-- Members read; only the RPCs below write.
alter table public.ledger_closings         enable row level security;
alter table public.ledger_closing_accounts enable row level security;
alter table public.ledger_closing_events   enable row level security;

create policy ledger_closings_select on public.ledger_closings
  for select to authenticated using (private.is_member(household_id));
create policy ledger_closing_accounts_select on public.ledger_closing_accounts
  for select to authenticated using (private.is_member(household_id));
create policy ledger_closing_events_select on public.ledger_closing_events
  for select to authenticated using (private.is_member(household_id));

revoke all on public.ledger_closings, public.ledger_closing_accounts, public.ledger_closing_events
  from anon, authenticated;
grant select on public.ledger_closings, public.ledger_closing_accounts, public.ledger_closing_events
  to authenticated;
grant all on public.ledger_closings, public.ledger_closing_accounts, public.ledger_closing_events
  to service_role;

-- ---------------------------------------------------------------
-- The lock
-- ---------------------------------------------------------------

-- Last day of the latest closed month, or null when nothing is closed.
create function private.locked_through(hid uuid)
returns date
language sql stable security definer set search_path = ''
as $$
  select (max(c.month) + interval '1 month' - interval '1 day')::date
  from public.ledger_closings c
  where c.household_id = hid and c.status = 'closed';
$$;

-- Refuses any change to a transaction or sale dated in a closed month.
-- Two things still pass: deleting the whole household, and the "set null"
-- that follows deleting a category or account (the snapshot keeps the names).
create function private.guard_closed_month()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_lock date;
  v_hid  uuid := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
  v_old  jsonb;
  v_new  jsonb;
begin
  v_lock := private.locked_through(v_hid);
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
    v_old := to_jsonb(old) - 'category_id' - 'account_id';
    v_new := to_jsonb(new) - 'category_id' - 'account_id';
    if v_new = v_old
       and (to_jsonb(new) -> 'category_id' is null or jsonb_typeof(to_jsonb(new) -> 'category_id') = 'null'
            or to_jsonb(new) -> 'category_id' = to_jsonb(old) -> 'category_id')
       and (new.account_id is null or new.account_id is not distinct from old.account_id) then
      return new;
    end if;
    raise exception 'Closed month: entries up to % are locked. An owner can reopen the month.', to_char(v_lock, 'DD Mon YYYY');
  end if;
  return new;
end;
$$;

create trigger transactions_closed_month
  before insert or update or delete on public.transactions
  for each row execute function private.guard_closed_month();
create trigger sales_closed_month
  before insert or update or delete on public.sales
  for each row execute function private.guard_closed_month();

-- ---------------------------------------------------------------
-- Figures for one month (shared by the draft view and the snapshot)
-- ---------------------------------------------------------------
create function private.period_figures(p_household uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  m0 date := date_trunc('month', p_month)::date;
  m1 date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_accounts jsonb;
  v_totals   jsonb;
  v_cats     jsonb;
  v_realized numeric;
  v_check    jsonb;
  v_income   numeric;
  v_expense  numeric;
  v_invest   numeric;
begin
  -- one row per account, plus "Unassigned" when entries without an account exist
  with acc_rows as (
    select a.id as account_id, a.name, a.sort_order, a.archived, a.opening_balance as base
    from public.accounts a where a.household_id = p_household
    union all
    select null, 'Unassigned', 1000000, false, 0
    where exists (select 1 from public.transactions t
                  where t.household_id = p_household and t.account_id is null and t.date < m1)
  ),
  figs as (
    select r.account_id, r.name, r.sort_order, r.archived,
      r.base + coalesce(sum(case when t.date < m0 then
        case when t.type in ('income', 'transfer-in') then t.amount else -t.amount end end), 0) as opening,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'income'), 0)       as income,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'expense'), 0)      as expense,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'invest'), 0)       as invest,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'transfer-in'), 0)  as transfer_in,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'transfer-out'), 0) as transfer_out
    from acc_rows r
    left join public.transactions t
      on t.household_id = p_household and t.date < m1
     and t.account_id is not distinct from r.account_id
    group by r.account_id, r.name, r.sort_order, r.archived, r.base
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'account_id', account_id, 'name', name, 'sort_order', sort_order, 'archived', archived,
      'opening', opening, 'income', income, 'expense', expense, 'invest', invest,
      'transfer_in', transfer_in, 'transfer_out', transfer_out,
      'closing', opening + income + transfer_in - expense - invest - transfer_out
    ) order by sort_order, name), '[]'),
    jsonb_build_object(
      'opening', coalesce(sum(opening), 0), 'income', coalesce(sum(income), 0),
      'expense', coalesce(sum(expense), 0), 'invest', coalesce(sum(invest), 0),
      'transfer_in', coalesce(sum(transfer_in), 0), 'transfer_out', coalesce(sum(transfer_out), 0),
      'closing', coalesce(sum(opening + income + transfer_in - expense - invest - transfer_out), 0))
  into v_accounts, v_totals
  from figs;

  v_income  := (v_totals ->> 'income')::numeric;
  v_expense := (v_totals ->> 'expense')::numeric;
  v_invest  := (v_totals ->> 'invest')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'amount', amount) order by amount desc), '[]')
  into v_cats
  from (
    select coalesce(c.name, 'Other') as name, sum(t.amount) as amount
    from public.transactions t
    left join public.categories c on c.id = t.category_id
    where t.household_id = p_household and t.type = 'expense' and t.date >= m0 and t.date < m1
    group by coalesce(c.name, 'Other')
  ) x;

  select coalesce(sum(s.realized_pl), 0) into v_realized
  from public.sales s
  where s.household_id = p_household and s.date >= m0 and s.date < m1;

  select jsonb_build_object(
    'entries',       count(*),
    'uncategorised', count(*) filter (where t.category_id is null and t.type not like 'transfer%'),
    'unassigned',    count(*) filter (where t.account_id is null))
  into v_check
  from public.transactions t
  where t.household_id = p_household and t.date >= m0 and t.date < m1;

  return jsonb_build_object(
    'month', m0,
    'accounts', v_accounts,
    'totals', v_totals,
    'savings_rate', case when v_income > 0 then round((v_income - v_expense - v_invest) / v_income * 100, 1) end,
    'realized_pl', v_realized,
    'by_category', v_cats,
    'checklist', v_check
  );
end;
$$;

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------

-- Live (draft) figures for a month, plus whether it can be closed now.
create function public.period_statement(p_household uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  m0     date := date_trunc('month', p_month)::date;
  v_lock date;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_next date;
  v_why  text := null;
begin
  if not private.is_member(p_household) then
    raise exception 'Not a member of this household';
  end if;
  v_lock := private.locked_through(p_household);
  v_next := case when v_lock is null then null else (v_lock + 1) end;

  if v_lock is not null and m0 <= v_lock then
    v_why := 'This month is already closed.';
  elsif (m0 + interval '1 month')::date > v_today then
    v_why := 'This month has not ended yet.';
  elsif v_next is not null and m0 <> v_next then
    v_why := 'Close ' || to_char(v_next, 'FMMonth YYYY') || ' first.';
  elsif not private.is_owner(p_household) then
    v_why := 'Only an owner can close a month.';
  end if;

  return private.period_figures(p_household, m0) || jsonb_build_object(
    'locked_through', v_lock,
    'can_close', v_why is null,
    'blocked_reason', v_why
  );
end;
$$;

-- Close a month: owner only, by hand. p_bank maps account id -> real bank
-- balance at month end (required for every active account); p_notes maps
-- account id -> why the bank and the books differ (required when they do).
create function public.close_period(
  p_household       uuid,
  p_month           date,
  p_bank            jsonb   default '{}',
  p_notes           jsonb   default '{}',
  p_note            text    default '',
  p_portfolio_value numeric default null,
  p_unrealized      numeric default null
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  m0        date := date_trunc('month', p_month)::date;
  v_today   date := (now() at time zone 'Asia/Jakarta')::date;
  v_lock    date;
  v_fig     jsonb;
  v_acc     jsonb;
  v_bank    numeric;
  v_diff    numeric;
  v_noteacc text;
  v_version int;
  v_id      uuid;
  v_rows    jsonb := '[]';
begin
  if not private.is_owner(p_household) then
    raise exception 'Only an owner can close a month';
  end if;
  -- one close at a time per household
  perform 1 from public.households where id = p_household for update;

  if (m0 + interval '1 month')::date > v_today then
    raise exception '% has not ended yet', to_char(m0, 'FMMonth YYYY');
  end if;
  v_lock := private.locked_through(p_household);
  if v_lock is not null and m0 <= v_lock then
    raise exception '% is already closed', to_char(m0, 'FMMonth YYYY');
  end if;
  if v_lock is not null and m0 <> v_lock + 1 then
    raise exception 'Close % first', to_char(v_lock + 1, 'FMMonth YYYY');
  end if;

  v_fig := private.period_figures(p_household, m0);

  for v_acc in select * from jsonb_array_elements(v_fig -> 'accounts') loop
    v_bank := null; v_diff := null; v_noteacc := '';
    if v_acc ->> 'account_id' is not null then
      v_bank := nullif(trim(coalesce(p_bank ->> (v_acc ->> 'account_id'), '')), '')::numeric;
      v_noteacc := trim(coalesce(p_notes ->> (v_acc ->> 'account_id'), ''));
      if v_bank is null and not (v_acc ->> 'archived')::boolean then
        raise exception 'Enter the bank balance for %', v_acc ->> 'name';
      end if;
      if v_bank is not null then
        v_diff := v_bank - (v_acc ->> 'closing')::numeric;
        if v_diff <> 0 and v_noteacc = '' then
          raise exception '% differs from the bank by %. Add a note or an adjusting entry.',
            v_acc ->> 'name', v_diff;
        end if;
      end if;
    end if;
    v_rows := v_rows || jsonb_build_object('acc', v_acc, 'bank', v_bank, 'diff', v_diff, 'note', v_noteacc);
  end loop;

  select coalesce(max(version), 0) + 1 into v_version
  from public.ledger_closings where household_id = p_household and month = m0;

  insert into public.ledger_closings
    (household_id, month, version, status, opening, income, expense, invest, transfer_in, transfer_out,
     closing, savings_rate, realized_pl, portfolio_value, unrealized_pl, by_category, checklist, note)
  values
    (p_household, m0, v_version, 'closed',
     (v_fig #>> '{totals,opening}')::numeric, (v_fig #>> '{totals,income}')::numeric,
     (v_fig #>> '{totals,expense}')::numeric, (v_fig #>> '{totals,invest}')::numeric,
     (v_fig #>> '{totals,transfer_in}')::numeric, (v_fig #>> '{totals,transfer_out}')::numeric,
     (v_fig #>> '{totals,closing}')::numeric, (v_fig ->> 'savings_rate')::numeric,
     (v_fig ->> 'realized_pl')::numeric, p_portfolio_value, p_unrealized,
     v_fig -> 'by_category', v_fig -> 'checklist', coalesce(trim(p_note), ''))
  returning id into v_id;

  insert into public.ledger_closing_accounts
    (closing_id, household_id, account_id, account_name, sort_order, opening, income, expense, invest,
     transfer_in, transfer_out, closing, bank_balance, difference, difference_note)
  select v_id, p_household, (r #>> '{acc,account_id}')::uuid, r #>> '{acc,name}', (r #>> '{acc,sort_order}')::int,
    (r #>> '{acc,opening}')::numeric, (r #>> '{acc,income}')::numeric, (r #>> '{acc,expense}')::numeric,
    (r #>> '{acc,invest}')::numeric, (r #>> '{acc,transfer_in}')::numeric, (r #>> '{acc,transfer_out}')::numeric,
    (r #>> '{acc,closing}')::numeric, (r ->> 'bank')::numeric, (r ->> 'diff')::numeric, coalesce(r ->> 'note', '')
  from jsonb_array_elements(v_rows) as e(r);

  insert into public.ledger_closing_events (household_id, month, version, action)
  values (p_household, m0, v_version, 'close');

  return v_id;
end;
$$;

-- Reopen the latest closed month (owner only, reason required).
-- Its snapshot is kept as 'superseded'; closing again makes a new version.
create function public.reopen_period(p_household uuid, p_month date, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m0        date := date_trunc('month', p_month)::date;
  v_latest  date;
  v_version int;
begin
  if not private.is_owner(p_household) then
    raise exception 'Only an owner can reopen a month';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'Say why the month is being reopened';
  end if;
  perform 1 from public.households where id = p_household for update;

  select max(month) into v_latest
  from public.ledger_closings where household_id = p_household and status = 'closed';
  if v_latest is null or m0 <> v_latest then
    raise exception 'Only the latest closed month (%) can be reopened', coalesce(to_char(v_latest, 'FMMonth YYYY'), 'none');
  end if;

  update public.ledger_closings set status = 'superseded'
  where household_id = p_household and month = m0 and status = 'closed'
  returning version into v_version;

  insert into public.ledger_closing_events (household_id, month, version, action, reason)
  values (p_household, m0, v_version, 'reopen', trim(p_reason));
end;
$$;

revoke all on function private.locked_through(uuid) from public;
revoke all on function private.guard_closed_month() from public;
revoke all on function private.period_figures(uuid, date) from public;
grant execute on function private.locked_through(uuid) to authenticated, service_role;

revoke all on function public.period_statement(uuid, date) from public, anon;
revoke all on function public.close_period(uuid, date, jsonb, jsonb, text, numeric, numeric) from public, anon;
revoke all on function public.reopen_period(uuid, date, text) from public, anon;
grant execute on function public.period_statement(uuid, date) to authenticated;
grant execute on function public.close_period(uuid, date, jsonb, jsonb, text, numeric, numeric) to authenticated;
grant execute on function public.reopen_period(uuid, date, text) to authenticated;
