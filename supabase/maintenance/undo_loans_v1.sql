-- Removes the FIRST version of the loans migration (money borrowed into an account),
-- so that the current 20261122000000_loans.sql (money lent from an account to a member)
-- can be run. Run this once, then run 20261122000000_loans.sql.
--
-- Do NOT run it after the current version has been applied and is in use: it deletes
-- every loan and every loan-in / loan-out entry. It is meant for the test loans you
-- entered while trying the first version.
--
-- If a month containing a test loan was already closed, reopen it first (Settings ->
-- Monthly statements), otherwise the lock refuses to delete that month's loan entries.

begin;

-- 1. test data: the loan entries, their reminders, then the loans themselves
select set_config('ft.loan', '1', true);            -- lets this transaction touch loan entries
delete from public.transactions where type in ('loan-in', 'loan-out');
delete from public.notifications where kind in ('loan_due', 'loan_overdue');
delete from public.notification_prefs where kind in ('loan_due', 'loan_overdue');

-- 2. triggers
drop trigger if exists transactions_loan_guard on public.transactions;
drop trigger if exists ledger_closings_loans on public.ledger_closings;
drop trigger if exists ledger_closing_accounts_loans on public.ledger_closing_accounts;

-- 3. put the statement and notification functions back the way the plans migration left them
drop function if exists private.period_figures(uuid, date);
alter function private.period_figures_plans(uuid, date) rename to period_figures;
drop function if exists private.check_household(uuid);
alter function private.check_household_plans(uuid) rename to check_household;

-- 4. loan functions (both generations of the signatures)
drop function if exists public.add_loan(uuid, uuid, numeric, uuid, date, text, date, text, text);
drop function if exists public.add_loan(uuid, uuid, numeric, uuid, date, date, text, text);
drop function if exists public.update_loan(uuid, jsonb);
drop function if exists public.delete_loan(uuid);
drop function if exists public.add_loan_payment(uuid, uuid, numeric, date, text, text);
drop function if exists public.delete_loan_payment(uuid);
drop function if exists public.household_members(uuid);
drop function if exists private.check_loans(uuid);
drop function if exists private.closing_loans();
drop function if exists private.closing_account_loans();
drop function if exists private.loan_figures(uuid, date);
drop function if exists private.loan_desc(text, uuid, text);
drop function if exists private.loan_desc(text, text, text);
drop function if exists private.loan_category(uuid);
drop function if exists private.refresh_loan(uuid);
drop function if exists private.loan_repaid(uuid);
drop function if exists private.guard_loan_txn();

-- 5. columns and tables
alter table public.ledger_closing_accounts drop column if exists loan_in, drop column if exists loan_out;
alter table public.ledger_closings drop column if exists loan_in, drop column if exists loan_out,
  drop column if exists loans, drop column if exists loans_outstanding;
alter table public.transactions drop constraint if exists transactions_loan_ck;
drop index if exists public.transactions_loan_idx;
alter table public.transactions drop column if exists loan_id;
drop table if exists public.loans;

-- 6. the type list and notification kinds go back to what they were before loans
alter table public.transactions drop constraint if exists transactions_type_check;
alter table public.transactions add constraint transactions_type_check
  check (type in ('income', 'expense', 'invest', 'transfer-out', 'transfer-in'));
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly', 'month_close'));
alter table public.notification_prefs drop constraint if exists notification_prefs_kind_check;
alter table public.notification_prefs add constraint notification_prefs_kind_check
  check (kind in ('plan_milestone', 'plan_achieved', 'plan_behind', 'plan_deadline', 'plan_overdue', 'plan_monthly', 'month_close'));

commit;
