-- V2.9: loans from the household's own accounts.
-- A loan is money taken out of one account (for example Bersama) and lent to a
-- household member, who pays it back into an account. The disbursement is a
-- `loan-out` transaction (balance goes down) and each repayment a `loan-in`
-- transaction (balance goes up). Neither counts as income or expense. The monthly
-- statement lists the loans still unpaid at month end and stores that list when
-- the month closes.
-- Needs 20261117 (ledger closing) and 20261118 (notifications).
-- Run this once in the SQL Editor (or with `supabase db push`).

-- ---------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------
create table public.loans (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  borrower_id  uuid references auth.users (id) on delete set null,  -- the household member who owes it
  amount       numeric(18, 2) not null check (amount > 0),
  date         date not null default ((now() at time zone 'Asia/Jakarta')::date),
  due_date     date,
  note         text not null default '',
  status       text not null default 'open' check (status in ('open', 'paid')),
  account_id   uuid references public.accounts (id) on delete set null,
  created_by   uuid references auth.users (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now(),
  check (due_date is null or due_date >= date)
);
create index loans_household_idx on public.loans (household_id, status, date desc);

alter table public.loans enable row level security;
create policy loans_select on public.loans
  for select to authenticated using (private.is_member(household_id));
-- Members read; only the RPCs below write.
revoke all on public.loans from anon, authenticated;
grant select on public.loans to authenticated;
grant all on public.loans to service_role;

-- ---------------------------------------------------------------
-- Transactions: two new types, linked to a loan
-- ---------------------------------------------------------------
alter table public.transactions drop constraint transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in ('income', 'expense', 'invest', 'transfer-out', 'transfer-in', 'loan-in', 'loan-out'));
-- no action (checked at the end of the statement) so deleting a household still cascades
alter table public.transactions add column loan_id uuid references public.loans (id);
alter table public.transactions add constraint transactions_loan_ck
  check ((type in ('loan-in', 'loan-out')) = (loan_id is not null));
create index transactions_loan_idx on public.transactions (loan_id) where loan_id is not null;

-- Account balances count a loan received as money in and a payment as money out.
create or replace view public.account_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.household_id,
  a.name,
  a.archived,
  a.sort_order,
  a.opening_balance + coalesce(sum(
    case when t.type in ('income', 'transfer-in', 'loan-in') then t.amount else -t.amount end
  ), 0) as balance
from public.accounts a
left join public.transactions t on t.account_id = a.id
group by a.id;

-- Loan transactions are written only by the loan functions below (FR-LON-05).
create function private.guard_loan_txn()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_row public.transactions := case when tg_op = 'DELETE' then old else new end;
begin
  if coalesce(current_setting('ft.loan', true), '') = '1' then
    return v_row;
  end if;
  if tg_op = 'DELETE' then
    -- deleting the whole household still passes
    if v_row.type in ('loan-in', 'loan-out')
       and exists (select 1 from public.households h where h.id = v_row.household_id) then
      raise exception 'Loan entries are changed from the Loans screen';
    end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    if new.type in ('loan-in', 'loan-out') then
      raise exception 'Loan entries are added from the Loans screen';
    end if;
    return new;
  end if;
  -- UPDATE: no moving into or out of the loan types; only the "set null" of a deleted account passes
  if new.type in ('loan-in', 'loan-out') or old.type in ('loan-in', 'loan-out') then
    if to_jsonb(new) - 'account_id' = to_jsonb(old) - 'account_id' and new.account_id is null then
      return new;
    end if;
    raise exception 'Loan entries are changed from the Loans screen';
  end if;
  return new;
end;
$$;

create trigger transactions_loan_guard
  before insert or update or delete on public.transactions
  for each row execute function private.guard_loan_txn();

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------
create function private.loan_repaid(p_loan uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(amount), 0) from public.transactions where loan_id = p_loan and type = 'loan-in';
$$;

-- Status follows the payments: open while something is outstanding, else paid.
create function private.refresh_loan(p_loan uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.loans l
  set status = case when l.amount - private.loan_repaid(l.id) <= 0 then 'paid' else 'open' end
  where l.id = p_loan;
$$;

-- Loans still unpaid at the end of the month, as a JSON array (FR-CLS-16).
create function private.loan_figures(p_household uuid, p_month date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with b as (
    select date_trunc('month', p_month)::date as m0,
           (date_trunc('month', p_month) + interval '1 month')::date as m1
  ),
  f as (
    select l.id, l.borrower_id, u.email as borrower_email, l.amount, l.date, l.due_date, l.note,
      case when l.date >= b.m0 then l.amount else 0 end as borrowed,
      coalesce(sum(t.amount) filter (where t.date >= b.m0), 0) as repaid_month,
      coalesce(sum(t.amount), 0) as repaid_to_date
    from public.loans l
    cross join b
    left join auth.users u on u.id = l.borrower_id
    left join public.transactions t on t.loan_id = l.id and t.type = 'loan-in' and t.date < b.m1
    where l.household_id = p_household and l.date < b.m1
    group by l.id, u.email, b.m0, b.m1
    having l.amount - coalesce(sum(t.amount), 0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'loan_id', id, 'borrower_id', borrower_id, 'borrower', borrower_email,
    'amount', amount, 'date', date, 'due_date', due_date, 'note', note,
    'borrowed', borrowed, 'repaid_month', repaid_month, 'repaid_to_date', repaid_to_date,
    'outstanding', amount - repaid_to_date
  ) order by date, id), '[]')
  from f;
$$;

-- ---------------------------------------------------------------
-- Statement figures: loans join the account maths (FR-CLS-15 / 16)
-- ---------------------------------------------------------------
-- Same body as in 20261117, with loan-in and loan-out added. The plans migration
-- wraps this function (period_figures), so replacing it here is enough.
create or replace function private.period_figures_base(p_household uuid, p_month date)
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
        case when t.type in ('income', 'transfer-in', 'loan-in') then t.amount else -t.amount end end), 0) as opening,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'income'), 0)       as income,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'expense'), 0)      as expense,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'invest'), 0)       as invest,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'transfer-in'), 0)  as transfer_in,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'transfer-out'), 0) as transfer_out,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'loan-in'), 0)      as loan_in,
      coalesce(sum(t.amount) filter (where t.date >= m0 and t.type = 'loan-out'), 0)     as loan_out
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
      'loan_in', loan_in, 'loan_out', loan_out,
      'closing', opening + income + transfer_in + loan_in - expense - invest - transfer_out - loan_out
    ) order by sort_order, name), '[]'),
    jsonb_build_object(
      'opening', coalesce(sum(opening), 0), 'income', coalesce(sum(income), 0),
      'expense', coalesce(sum(expense), 0), 'invest', coalesce(sum(invest), 0),
      'transfer_in', coalesce(sum(transfer_in), 0), 'transfer_out', coalesce(sum(transfer_out), 0),
      'loan_in', coalesce(sum(loan_in), 0), 'loan_out', coalesce(sum(loan_out), 0),
      'closing', coalesce(sum(opening + income + transfer_in + loan_in - expense - invest - transfer_out - loan_out), 0))
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
    'uncategorised', count(*) filter (where t.category_id is null and t.type not like 'transfer%' and t.type not like 'loan%'),
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

-- period_statement and close_period call private.period_figures, which the plans
-- migration defined as period_figures_base + plans. Wrap it again to add loans.
alter function private.period_figures(uuid, date) rename to period_figures_plans;

create function private.period_figures(p_household uuid, p_month date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with l as (select private.loan_figures(p_household, p_month) as loans)
  select private.period_figures_plans(p_household, p_month)
    || jsonb_build_object(
         'loans', l.loans,
         'loans_outstanding', (select coalesce(sum((x ->> 'outstanding')::numeric), 0) from jsonb_array_elements(l.loans) x))
  from l;
$$;

-- Closing snapshots: store the loan columns and the Loans section (FR-CLS-16).
alter table public.ledger_closings
  add column loan_in  numeric(18, 2) not null default 0,
  add column loan_out numeric(18, 2) not null default 0,
  add column loans    jsonb not null default '[]',
  add column loans_outstanding numeric(18, 2) not null default 0;
alter table public.ledger_closing_accounts
  add column loan_in  numeric(18, 2) not null default 0,
  add column loan_out numeric(18, 2) not null default 0;

create function private.closing_loans()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_fig jsonb := private.period_figures_base(new.household_id, new.month);
begin
  new.loan_in  := (v_fig #>> '{totals,loan_in}')::numeric;
  new.loan_out := (v_fig #>> '{totals,loan_out}')::numeric;
  new.loans    := private.loan_figures(new.household_id, new.month);
  new.loans_outstanding := (select coalesce(sum((x ->> 'outstanding')::numeric), 0) from jsonb_array_elements(new.loans) x);
  return new;
end;
$$;

create trigger ledger_closings_loans
  before insert on public.ledger_closings
  for each row execute function private.closing_loans();

create function private.closing_account_loans()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_month date;
begin
  select month into v_month from public.ledger_closings where id = new.closing_id;
  select coalesce(sum(t.amount) filter (where t.type = 'loan-in'), 0),
         coalesce(sum(t.amount) filter (where t.type = 'loan-out'), 0)
  into new.loan_in, new.loan_out
  from public.transactions t
  where t.household_id = new.household_id and t.account_id is not distinct from new.account_id
    and t.date >= v_month and t.date < (v_month + interval '1 month')::date;
  return new;
end;
$$;

create trigger ledger_closing_accounts_loans
  before insert on public.ledger_closing_accounts
  for each row execute function private.closing_account_loans();

-- ---------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------
create function private.loan_category(p_household uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_cat uuid;
begin
  select id into v_cat from public.categories where household_id = p_household and lower(name) = 'loan';
  if v_cat is null then
    insert into public.categories (household_id, name) values (p_household, 'Loan') returning id into v_cat;
  end if;
  return v_cat;
end;
$$;

create function private.loan_desc(p_prefix text, p_borrower uuid, p_note text)
returns text
language sql stable security definer set search_path = ''
as $$
  select p_prefix || coalesce(' ' || (select split_part(email, '@', 1) from auth.users where id = p_borrower), '')
    || case when coalesce(trim(p_note), '') <> '' then ' - ' || trim(p_note) else '' end;
$$;

-- Lend money out of an account to a household member.
create function public.add_loan(
  p_household uuid,
  p_account   uuid,
  p_amount    numeric,
  p_borrower  uuid,
  p_date      date default null,
  p_due_date  date default null,
  p_note      text default '',
  p_source    text default 'web'
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_id   uuid;
begin
  if not private.is_member(p_household) then raise exception 'Not a member of this household'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if not exists (select 1 from public.accounts where id = p_account and household_id = p_household) then
    raise exception 'Account not found in this household';
  end if;
  if not exists (select 1 from public.members where household_id = p_household and user_id = p_borrower) then
    raise exception 'The borrower must be a member of this household';
  end if;
  if p_due_date is not null and p_due_date < v_date then
    raise exception 'The due date cannot be before the loan date';
  end if;

  perform set_config('ft.loan', '1', true);
  insert into public.loans (household_id, borrower_id, amount, date, due_date, note, account_id)
  values (p_household, p_borrower, p_amount, v_date, p_due_date, coalesce(trim(p_note), ''), p_account)
  returning id into v_id;

  insert into public.transactions
    (household_id, date, type, category_id, description, amount, source, account_id, loan_id)
  values
    (p_household, v_date, 'loan-out', private.loan_category(p_household),
     private.loan_desc('Loan to', p_borrower, p_note), p_amount, p_source, p_account, v_id);
  perform set_config('ft.loan', '', true);
  return v_id;
end;
$$;

-- A repayment: money comes back into an account.
create function public.add_loan_payment(
  p_loan    uuid,
  p_account uuid,
  p_amount  numeric,
  p_date    date default null,
  p_note    text default '',
  p_source  text default 'web'
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  l       public.loans;
  v_date  date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_left  numeric;
  v_id    uuid;
begin
  select * into l from public.loans where id = p_loan for update;
  if l.id is null or not private.is_member(l.household_id) then raise exception 'Loan not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if not exists (select 1 from public.accounts where id = p_account and household_id = l.household_id) then
    raise exception 'Account not found in this household';
  end if;
  if v_date < l.date then raise exception 'A repayment cannot be dated before the loan (%)', to_char(l.date, 'DD Mon YYYY'); end if;
  v_left := l.amount - private.loan_repaid(l.id);
  if p_amount > v_left then
    raise exception 'Only % is still owed on this loan', v_left;
  end if;

  perform set_config('ft.loan', '1', true);
  insert into public.transactions
    (household_id, date, type, category_id, description, amount, source, account_id, loan_id)
  values
    (l.household_id, v_date, 'loan-in', private.loan_category(l.household_id),
     private.loan_desc('Loan repayment from', l.borrower_id, p_note), p_amount, p_source, p_account, l.id)
  returning id into v_id;
  perform private.refresh_loan(l.id);
  perform set_config('ft.loan', '', true);
  return v_id;
end;
$$;

-- Remove a repayment (open months only; the closed-month trigger refuses the rest).
create function public.delete_loan_payment(p_txn uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  t public.transactions;
begin
  select * into t from public.transactions where id = p_txn and type = 'loan-in' for update;
  if t.id is null or not private.is_member(t.household_id) then raise exception 'Payment not found'; end if;
  perform 1 from public.loans where id = t.loan_id for update;
  perform set_config('ft.loan', '1', true);
  delete from public.transactions where id = p_txn;
  perform private.refresh_loan(t.loan_id);
  perform set_config('ft.loan', '', true);
end;
$$;

-- Edit a loan. p_fields keys: account, amount, date, borrower, due_date, note.
-- Money fields (account, amount, date) change only while there are no repayments.
create function public.update_loan(p_loan uuid, p_fields jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l       public.loans;
  v_acc   uuid;
  v_amt   numeric;
  v_date  date;
  v_bor   uuid;
  v_due   date;
  v_note  text;
  v_money boolean;
  v_pay   int;
begin
  select * into l from public.loans where id = p_loan for update;
  if l.id is null or not private.is_member(l.household_id) then raise exception 'Loan not found'; end if;

  v_acc  := case when p_fields ? 'account'  then (p_fields ->> 'account')::uuid  else l.account_id end;
  v_amt  := case when p_fields ? 'amount'   then (p_fields ->> 'amount')::numeric else l.amount end;
  v_date := case when p_fields ? 'date'     then (p_fields ->> 'date')::date     else l.date end;
  v_bor  := case when p_fields ? 'borrower' then (p_fields ->> 'borrower')::uuid else l.borrower_id end;
  v_due  := case when p_fields ? 'due_date' then (p_fields ->> 'due_date')::date else l.due_date end;
  v_note := case when p_fields ? 'note'     then coalesce(trim(p_fields ->> 'note'), '') else l.note end;

  v_money := v_acc is distinct from l.account_id or v_amt <> l.amount or v_date <> l.date;
  select count(*) into v_pay from public.transactions where loan_id = l.id and type = 'loan-in';
  if v_money and v_pay > 0 then
    raise exception 'Amount, date and account cannot change once repayments exist. Delete the repayments first.';
  end if;
  if v_amt <= 0 then raise exception 'Amount must be positive'; end if;
  if v_due is not null and v_due < v_date then raise exception 'The due date cannot be before the loan date'; end if;
  if v_bor is distinct from l.borrower_id
     and not exists (select 1 from public.members where household_id = l.household_id and user_id = v_bor) then
    raise exception 'The borrower must be a member of this household';
  end if;
  if v_money and not exists (select 1 from public.accounts where id = v_acc and household_id = l.household_id) then
    raise exception 'Account not found in this household';
  end if;

  if v_money then
    perform set_config('ft.loan', '1', true);
    update public.transactions
    set amount = v_amt, date = v_date, account_id = v_acc,
        description = private.loan_desc('Loan to', v_bor, v_note)
    where loan_id = l.id and type = 'loan-out';
    perform set_config('ft.loan', '', true);
  end if;
  update public.loans
  set account_id = v_acc, amount = v_amt, date = v_date, borrower_id = v_bor, due_date = v_due, note = v_note
  where id = l.id;
  perform private.refresh_loan(l.id);
end;
$$;

-- Delete a loan that has no repayments, together with its loan-out entry.
create function public.delete_loan(p_loan uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.loans;
begin
  select * into l from public.loans where id = p_loan for update;
  if l.id is null or not private.is_member(l.household_id) then raise exception 'Loan not found'; end if;
  if exists (select 1 from public.transactions where loan_id = l.id and type = 'loan-in') then
    raise exception 'This loan has repayments. Delete the repayments first.';
  end if;
  perform set_config('ft.loan', '1', true);
  delete from public.transactions where loan_id = l.id;
  delete from public.loans where id = l.id;
  perform set_config('ft.loan', '', true);
end;
$$;

-- Members with their email, so the app can offer a borrower list. The members
-- table has no names; any member of the household may read this list.
create function public.household_members(p_household uuid)
returns table (user_id uuid, role text, email text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_member(p_household) then raise exception 'Not a member of this household'; end if;
  return query
    select m.user_id, m.role, u.email::text
    from public.members m join auth.users u on u.id = m.user_id
    where m.household_id = p_household
    order by m.role desc, u.email;
end;
$$;

-- ---------------------------------------------------------------
-- Notifications (FR-LON-11)
-- ---------------------------------------------------------------
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly',
                  'month_close', 'loan_due', 'loan_overdue'));
alter table public.notification_prefs drop constraint notification_prefs_kind_check;
alter table public.notification_prefs add constraint notification_prefs_kind_check
  check (kind in ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly',
                  'month_close', 'loan_due', 'loan_overdue'));

create function private.check_loans(p_household uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l       record;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_left  numeric;
begin
  for l in select * from public.loans where household_id = p_household and status = 'open' and due_date is not null loop
    v_left := l.amount - private.loan_repaid(l.id);
    if l.due_date < v_today then
      perform private.notify(p_household, 'loan_overdue', l.id, 'overdue:' || l.due_date || ':' || to_char(v_today, 'IYYY-IW'),
        'A loan is overdue',
        private.rp(v_left) || ' is still owed. It was due ' || private.long_date(l.due_date) || '.', 'loan:' || l.id);
    elsif l.due_date - v_today <= 7 then
      perform private.notify(p_household, 'loan_due', l.id, '7d:' || l.due_date,
        case when l.due_date = v_today then 'A loan is due today' else 'A loan is due in ' || (l.due_date - v_today) || ' days' end,
        private.rp(v_left) || ' to pay back by ' || private.long_date(l.due_date) || '.', 'loan:' || l.id);
    end if;
  end loop;
end;
$$;

-- check_household (replaced by 20261121) keeps its body; loan checks run after it.
alter function private.check_household(uuid) rename to check_household_plans;

create function private.check_household(p_household uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform private.check_household_plans(p_household);
  perform private.check_loans(p_household);
end;
$$;

-- ---------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------
revoke all on function private.guard_loan_txn() from public;
revoke all on function private.loan_repaid(uuid) from public;
revoke all on function private.refresh_loan(uuid) from public;
revoke all on function private.loan_figures(uuid, date) from public;
revoke all on function private.loan_category(uuid) from public;
revoke all on function private.check_loans(uuid) from public;
revoke all on function private.period_figures(uuid, date) from public;
revoke all on function private.check_household(uuid) from public;

revoke all on function public.add_loan(uuid, uuid, numeric, uuid, date, date, text, text) from public, anon;
revoke all on function public.add_loan_payment(uuid, uuid, numeric, date, text, text) from public, anon;
revoke all on function public.delete_loan_payment(uuid) from public, anon;
revoke all on function public.update_loan(uuid, jsonb) from public, anon;
revoke all on function public.delete_loan(uuid) from public, anon;
grant execute on function public.add_loan(uuid, uuid, numeric, uuid, date, date, text, text) to authenticated;
grant execute on function public.add_loan_payment(uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.delete_loan_payment(uuid) to authenticated;
grant execute on function public.update_loan(uuid, jsonb) to authenticated;
grant execute on function public.delete_loan(uuid) to authenticated;
revoke all on function public.household_members(uuid) from public, anon;
grant execute on function public.household_members(uuid) to authenticated;
