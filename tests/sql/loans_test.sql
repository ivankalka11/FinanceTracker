\set ON_ERROR_STOP 1
\pset pager off
-- Loans (20261122000000_loans.sql): money lent from a household account to a member and paid back.
-- Household H: owner O, member M, outsider X. Months are relative to today:
--   m2 = two months ago, m1 = last month, m0 = this month.
-- Accounts: Ivan (10.000.000) and Bersama (5.000.000, the joint account the loans come from).
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','o@x'),
 ('00000000-0000-0000-0000-00000000000b','m@x'),
 ('00000000-0000-0000-0000-00000000000c','x@x');
insert into public.households (id, name) values ('11111111-1111-1111-1111-111111111111','H');
insert into public.members values
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','owner'),
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000b','member');
insert into public.accounts (id, household_id, name, opening_balance) values
 ('33333333-3333-3333-3333-333333333331','11111111-1111-1111-1111-111111111111','Ivan', 10000000),
 ('33333333-3333-3333-3333-333333333332','11111111-1111-1111-1111-111111111111','Bersama', 5000000);

create function pg_temp.m(k int) returns date language sql as
$$ select (date_trunc('month', current_date) - make_interval(months => k))::date $$;
create function pg_temp.expect_error(sql text, needle text) returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'EXPECTED ERROR containing "%" but statement succeeded: %', needle, sql;
exception when others then
  if sqlerrm like 'EXPECTED ERROR%' then raise; end if;
  if position(needle in sqlerrm) = 0 then
    raise exception 'Wrong error for %: got "%", wanted "%"', sql, sqlerrm, needle;
  end if;
  raise notice 'ok (refused): %', sqlerrm;
end $$;
create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAILED: %', label; end if;
  raise notice 'ok: %', label;
end $$;
grant execute on function pg_temp.m(int) to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 1. lend: Bersama lends 3.000.000 to M in m2; Ivan lends 1.000.000 to O in m1
select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333332',3000000,
  '00000000-0000-0000-0000-00000000000b', pg_temp.m(2)+3, null, 'laptop') as loan1 \gset
select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',1000000,
  '00000000-0000-0000-0000-00000000000a', pg_temp.m(1)+8, current_date + 3, '') as loan2 \gset
select pg_temp.check((select balance = 2000000 from public.account_balances where name = 'Bersama'), 'lending lowers the account balance');
select pg_temp.check((select balance = 9000000 from public.account_balances where name = 'Ivan'), 'second loan lowers Ivan');
select pg_temp.check((select count(*) = 2 from public.transactions where type = 'loan-out'), 'two loan-out entries');
select pg_temp.check((select c.name = 'Loan' from public.categories c join public.transactions t on t.category_id = c.id where t.loan_id = :'loan1'), 'loan category created');
select pg_temp.check((select description = 'Loan to m - laptop' from public.transactions where loan_id = :'loan1'), 'entry names the borrower');

-- 2. rules
select pg_temp.expect_error($q$select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',100,
  '00000000-0000-0000-0000-00000000000c')$q$, 'borrower must be a member');
select pg_temp.expect_error($q$select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',0,
  '00000000-0000-0000-0000-00000000000a')$q$, 'Amount must be positive');
select pg_temp.expect_error($q$select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',100,
  '00000000-0000-0000-0000-00000000000a', current_date, current_date - 1)$q$, 'due date');
select pg_temp.expect_error($q$insert into public.transactions (household_id, date, type, amount)
  values ('11111111-1111-1111-1111-111111111111', current_date, 'loan-in', 5)$q$, 'Loans screen');
select pg_temp.expect_error($q$delete from public.transactions where type = 'loan-out'$q$, 'Loans screen');
select pg_temp.expect_error($q$update public.transactions set amount = 1 where type = 'loan-out'$q$, 'Loans screen');
select pg_temp.expect_error($q$insert into public.loans (household_id, amount) values ('11111111-1111-1111-1111-111111111111', 1)$q$, 'permission denied');

-- 3. repayments into Bersama
select public.add_loan_payment(:'loan1', '33333333-3333-3333-3333-333333333332', 1200000, pg_temp.m(1)+5, 'first') as pay1 \gset
select pg_temp.check((select balance = 3200000 from public.account_balances where name = 'Bersama'), 'a repayment raises the account balance');
select pg_temp.check((select status = 'open' from public.loans where id = :'loan1'), 'partly repaid loan stays open');
select pg_temp.expect_error(format($q$select public.add_loan_payment(%L, '33333333-3333-3333-3333-333333333332', 1800001)$q$, :'loan1'), 'still owed');
select pg_temp.expect_error(format($q$select public.add_loan_payment(%L, '33333333-3333-3333-3333-333333333332', 1, %L)$q$, :'loan1', (pg_temp.m(2)+1)::text), 'before the loan');
select pg_temp.expect_error(format($q$select public.update_loan(%L, '{"amount": 4000000}')$q$, :'loan1'), 'once repayments exist');
select pg_temp.expect_error(format($q$select public.delete_loan(%L)$q$, :'loan1'), 'has repayments');
select public.update_loan(:'loan1', '{"note":"new note"}');
select pg_temp.check((select note = 'new note' from public.loans where id = :'loan1'), 'note editable with repayments');

-- 4. reports ignore loans; statements list unpaid loans
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(2)) #>> '{totals,income}')::numeric = 0
  and (public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(2)) #>> '{totals,expense}')::numeric = 0,
  'loans are not income or expense');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(2)) #>> '{totals,loan_out}')::numeric = 3000000,
  'loan_out shown apart');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(2)) ->> 'loans_outstanding')::numeric = 3000000
  and jsonb_array_length(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(2)) -> 'loans') = 1,
  'm2 statement: one loan, 3.000.000 outstanding');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) ->> 'loans_outstanding')::numeric = 2800000
  and jsonb_array_length(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'loans') = 2,
  'm1 statement: two loans, 2.800.000 outstanding');
select pg_temp.check((select (l ->> 'repaid_month')::numeric = 1200000 and (l ->> 'outstanding')::numeric = 1800000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'loans') l
                      where l ->> 'loan_id' = :'loan1'), 'm1 statement: repaid in month and outstanding for loan 1');
select pg_temp.check((select (a ->> 'closing')::numeric = 3200000 from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'accounts') a
                      where a ->> 'name' = 'Bersama'), 'Bersama closing includes the loan and the repayment');

-- 5. close m1 and check the snapshot
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"9000000","33333333-3333-3333-3333-333333333332":"3200000"}');
select pg_temp.check((select loans_outstanding = 2800000 and jsonb_array_length(loans) = 2 and loan_in = 1200000 and loan_out = 1000000
                      from public.ledger_closings where status = 'closed'), 'snapshot stores the loans section');
select pg_temp.check((select loan_out = 1000000 from public.ledger_closing_accounts where account_name = 'Ivan'), 'snapshot account loan_out');
select pg_temp.check((select loan_in = 1200000 from public.ledger_closing_accounts where account_name = 'Bersama'), 'snapshot account loan_in');

-- 6. the lock
select pg_temp.expect_error(format($q$select public.add_loan_payment(%L, '33333333-3333-3333-3333-333333333332', 1, %L)$q$, :'loan1', (pg_temp.m(1)+10)::text), 'Closed month');
select pg_temp.expect_error($q$select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',1,
  '00000000-0000-0000-0000-00000000000a', pg_temp.m(1)+11)$q$, 'Closed month');
select pg_temp.expect_error(format($q$select public.delete_loan_payment(%L)$q$, :'pay1'), 'Closed month');
select pg_temp.expect_error(format($q$select public.delete_loan(%L)$q$, :'loan2'), 'Closed month');
select pg_temp.expect_error(format($q$select public.update_loan(%L, '{"amount": 1}')$q$, :'loan2'), 'Closed month');
select public.update_loan(:'loan2', format('{"due_date":"%s"}', current_date + 3)::jsonb);
select pg_temp.check((select due_date = current_date + 3 from public.loans where id = :'loan2'), 'due date editable in a closed month');

-- 7. repay in the open month; the closed statement does not move
select public.add_loan_payment(:'loan1', '33333333-3333-3333-3333-333333333332', 1800000, current_date, 'rest') as pay2 \gset
select pg_temp.check((select status = 'paid' from public.loans where id = :'loan1'), 'fully repaid loan is paid');
select pg_temp.check((select loans_outstanding = 2800000 from public.ledger_closings where status = 'closed'), 'closed snapshot unchanged');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(0)) ->> 'loans_outstanding')::numeric = 1000000
  and jsonb_array_length(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(0)) -> 'loans') = 1,
  'this month lists only the loan still unpaid');
select public.delete_loan_payment(:'pay2');
select pg_temp.check((select status = 'open' from public.loans where id = :'loan1'), 'deleting a repayment reopens the loan');
select pg_temp.check((select balance = 3200000 from public.account_balances where name = 'Bersama'), 'balance back after deleting the repayment');

-- 8. members and outsiders
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',100000,
  '00000000-0000-0000-0000-00000000000b', current_date) as loan3 \gset
select pg_temp.check(true, 'a member can record a loan');
select public.delete_loan(:'loan3');
select pg_temp.check((select count(*) = 2 from public.loans), 'loan deleted with its entry');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
select pg_temp.check((select count(*) = 2 and bool_or(email = 'm@x') from public.household_members('11111111-1111-1111-1111-111111111111')),
  'members list has both members with email');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c', false);
select pg_temp.expect_error($q$select * from public.household_members('11111111-1111-1111-1111-111111111111')$q$, 'Not a member');
select pg_temp.expect_error($q$select public.add_loan('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331',1,
  '00000000-0000-0000-0000-00000000000a')$q$, 'Not a member');
select pg_temp.expect_error(format($q$select public.add_loan_payment(%L, '33333333-3333-3333-3333-333333333331', 1)$q$, :'loan1'), 'Loan not found');
select pg_temp.check((select count(*) = 0 from public.loans), 'outsider sees no loans');

-- 9. notifications: loan2 is due in 3 days
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
select public.check_notifications('11111111-1111-1111-1111-111111111111');
select public.check_notifications('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select count(*) = 1 from public.notifications where kind = 'loan_due' and user_id = '00000000-0000-0000-0000-00000000000a'),
  'due-soon loan notifies the owner once');
\echo ALL LOAN TESTS PASSED
