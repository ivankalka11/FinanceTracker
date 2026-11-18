\set ON_ERROR_STOP 1
\pset pager off
-- V2.13 plan spending. Fixtures: household H (owner O, member M), household X (owner Z), one account, one category.
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','o@x'),
 ('00000000-0000-0000-0000-00000000000b','m@x'),
 ('00000000-0000-0000-0000-00000000000c','z@x');
insert into public.households (id, name) values
 ('11111111-1111-1111-1111-111111111111','H'), ('22222222-2222-2222-2222-222222222222','X');
insert into public.members values
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','owner'),
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000b','member'),
 ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-00000000000c','owner');
insert into public.accounts (id, household_id, name) values
 ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Bersama'),
 ('33333333-3333-3333-3333-333333333334','22222222-2222-2222-2222-222222222222','Other');
insert into public.categories (id, household_id, name) values
 ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','Renovation'),
 ('44444444-4444-4444-4444-444444444445','22222222-2222-2222-2222-222222222222','Elsewhere');

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
create function pg_temp.m(n int) returns date language sql as
  $$ select (date_trunc('month', current_date) - make_interval(months => n))::date $$;
grant execute on function pg_temp.m(int) to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 1. a 30 juta plan, fully funded
insert into public.plans (id, household_id, name, target_amount, start_date, target_date, account_id)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Renovation',
        30000000, current_date - 30, current_date + 90, '33333333-3333-3333-3333-333333333333');
insert into public.plan_ledger (household_id, plan_id, entry_type, amount)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','deposit',30000000);

-- 2. pay a vendor 5 juta from the plan
select pg_temp.check((public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 5000000, null,
        '44444444-4444-4444-4444-444444444444', null, 'Vendor down payment')).amount = -5000000,
  'spend_from_plan writes a spend entry of -5.000.000');
select pg_temp.check((select count(*) = 1 and bool_and(type = 'expense' and amount = 5000000
                        and account_id = '33333333-3333-3333-3333-333333333333'
                        and description = 'Vendor down payment')
                      from public.transactions), 'it created one expense on the plan''s account');
select pg_temp.check((select transaction_id is not null from public.plan_ledger where entry_type = 'spend'),
  'the spend entry points at the expense');
select pg_temp.check((select earmarked from public.account_earmarks('11111111-1111-1111-1111-111111111111')) = 25000000,
  'set-aside falls to 25.000.000, so free to spend does not change');
reset role;
select pg_temp.check(private.plan_cash('aaaaaaaa-0000-0000-0000-000000000001') = 25000000, 'plan cash is 25.000.000');
select pg_temp.check(private.plan_spent('aaaaaaaa-0000-0000-0000-000000000001') = 5000000, 'spent is 5.000.000');
select pg_temp.check(private.plan_saved('aaaaaaaa-0000-0000-0000-000000000001') = 30000000,
  'saved stays 30.000.000: 25.000.000 cash + 5.000.000 spent');
set role authenticated;
select pg_temp.check((select status = 'achieved' from public.plans), 'the plan is still achieved (spending did not cost progress)');

-- 3. a partial second payment, from a different amount
select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 3000000);
select pg_temp.check((select description = 'Paid from plan: Renovation' from public.transactions
                      where amount = 3000000), 'default description names the plan');
reset role;
select pg_temp.check(private.plan_cash('aaaaaaaa-0000-0000-0000-000000000001') = 22000000
                     and private.plan_spent('aaaaaaaa-0000-0000-0000-000000000001') = 8000000
                     and private.plan_saved('aaaaaaaa-0000-0000-0000-000000000001') = 30000000,
  'two payments: cash 22.000.000, spent 8.000.000, saved 30.000.000');
set role authenticated;

-- 4. rules
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 22000001)$q$, 'only');
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 0)$q$, 'positive');
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000, '33333333-3333-3333-3333-333333333334')$q$, 'Account not found');
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000, null, '44444444-4444-4444-4444-444444444445')$q$, 'Category not found');
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000, null, null, current_date + 1)$q$, 'future');
select pg_temp.expect_error($q$insert into public.plan_ledger (household_id, plan_id, entry_type, amount, transaction_id)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','spend',-100,(select id from public.transactions limit 1))$q$, 'row-level security');
select pg_temp.expect_error($q$update public.transactions set amount = 6000000 where amount = 5000000$q$, 'paid from a plan');
select pg_temp.expect_error($q$update public.transactions set date = current_date - 1 where amount = 5000000$q$, 'paid from a plan');
update public.transactions set description = 'Vendor, renamed' where amount = 5000000;
select pg_temp.check((select count(*) from public.transactions where description = 'Vendor, renamed') = 1,
  'description and category of the expense can still be edited');
delete from public.plan_ledger where entry_type = 'spend';
select pg_temp.check((select count(*) from public.plan_ledger where entry_type = 'spend') = 2,
  'a spend entry cannot be deleted directly');

-- 5. a member can pay; another household cannot
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000000, null, null, null, 'Member payment');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c', false);
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000)$q$, 'Plan not found');
select pg_temp.expect_error($q$select public.delete_plan_spend((select id from public.plan_ledger limit 1))$q$, 'Payment not found');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 6. deleting: through the function, and by deleting the expense itself
select public.delete_plan_spend((select id from public.plan_ledger where note = 'Vendor down payment'));
select pg_temp.check((select count(*) from public.transactions where description = 'Vendor, renamed') = 0
                       and (select count(*) from public.plan_ledger where note = 'Vendor down payment') = 0,
  'delete_plan_spend removes the expense and the entry');
delete from public.transactions where description = 'Paid from plan: Renovation';
select pg_temp.check((select count(*) from public.plan_ledger where entry_type = 'spend') = 1,
  'deleting the expense from Activity removes its spend entry');
reset role;
select pg_temp.check(private.plan_cash('aaaaaaaa-0000-0000-0000-000000000001') = 29000000
                     and private.plan_spent('aaaaaaaa-0000-0000-0000-000000000001') = 1000000,
  'cash and spent follow: 29.000.000 cash, 1.000.000 spent');
set role authenticated;

-- 7. a cancelled plan takes no payments, and keeps what was spent
update public.plans set status = 'cancelled', progress_at_close = 100 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000001', 1000)$q$, 'cancelled');
select pg_temp.check((select count(*) from public.account_earmarks('11111111-1111-1111-1111-111111111111')) = 0,
  'a cancelled plan sets nothing aside');
select pg_temp.check((select progress_at_close = 100 from public.plans), 'cancelling can store the progress reached');
update public.plans set status = 'active' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.check((select progress_at_close is null from public.plans), 'resuming clears the stored progress');

-- 8. the statement: spent this month, spent to date, saved includes it; closing freezes it and locks it
insert into public.plans (id, household_id, name, target_amount, start_date, target_date, account_id)
values ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Holiday',
        20000000, pg_temp.m(2), current_date + 200, '33333333-3333-3333-3333-333333333333');
insert into public.plan_ledger (household_id, plan_id, entry_type, amount, date)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','deposit',10000000, pg_temp.m(1) + 3);
select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000002', 4000000, null, null, pg_temp.m(1) + 5, 'Flights');
select pg_temp.check((select (p ->> 'spent')::numeric = 4000000 and (p ->> 'spent_total')::numeric = 4000000
                        and (p ->> 'cash')::numeric = 6000000 and (p ->> 'saved')::numeric = 10000000
                        and (p ->> 'progress')::numeric = 50.0
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p
                      where p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'statement: spent 4.000.000, cash 6.000.000, saved 10.000.000 (50%)');
select pg_temp.check((select (a ->> 'expense')::numeric = 4000000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'accounts') a
                      where a ->> 'account_id' = '33333333-3333-3333-3333-333333333333'),
  'the payment shows as an expense of the account in the statement');
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333333":"-4000000"}');
select pg_temp.check((select (p ->> 'spent')::numeric = 4000000 and (p ->> 'saved')::numeric = 10000000
                      from public.ledger_closings c, jsonb_array_elements(c.plans) p
                      where c.month = pg_temp.m(1) and p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'closing stored the spent figures');
select pg_temp.expect_error($q$select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000002', 1000, null, null, pg_temp.m(1) + 6)$q$, 'Closed month');
select pg_temp.expect_error($q$select public.delete_plan_spend((select id from public.plan_ledger where note = 'Flights'))$q$, 'Closed month');
select pg_temp.expect_error($q$delete from public.transactions where description = 'Flights'$q$, 'Closed month');
-- a payment this month still works, and next month's opening cash carries the earlier spend
select public.spend_from_plan('aaaaaaaa-0000-0000-0000-000000000002', 500000, null, null, null, 'This month');
reset role;
select pg_temp.check(private.plan_saved('aaaaaaaa-0000-0000-0000-000000000002') = 10000000,
  'saved still 10.000.000 after both payments (cash 5.500.000 + spent 4.500.000)');
set role authenticated;

do $$ begin raise notice 'PASSED'; end $$;
