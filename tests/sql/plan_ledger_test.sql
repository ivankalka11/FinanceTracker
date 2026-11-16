\set ON_ERROR_STOP 1
\pset pager off
-- Fixtures: household H (owner O, member M), household X (owner Z), one account, two gold/stock lots
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
 ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Bersama');
insert into public.holdings (id, household_id, asset_type, ticker, name, quantity, buy_price) values
 ('55555555-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','gold','LM','Antam',10,1000000),
 ('55555555-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','stock','BBCA','BCA',1000,9000);

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
-- first day of the month n months ago
create function pg_temp.m(n int) returns date language sql as
  $$ select (date_trunc('month', current_date) - make_interval(months => n))::date $$;
grant execute on function pg_temp.m(int) to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 1. cash entries through the old view and the new table
insert into public.plans (id, household_id, name, target_amount, start_date, target_date, account_id)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Emergency fund',
        50000000, current_date - 60, current_date + 120, '33333333-3333-3333-3333-333333333333');
insert into public.plan_contributions (household_id, plan_id, amount)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',5000000);
select pg_temp.check((select entry_type = 'deposit' from public.plan_ledger), 'old view writes a deposit row');
insert into public.plan_ledger (household_id, plan_id, entry_type, amount, note)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','withdrawal',-2000000,'dentist');
select pg_temp.check((select count(*) from public.plan_contributions) = 1, 'compat view lists deposits only');
select pg_temp.check((select earmarked from public.account_earmarks('11111111-1111-1111-1111-111111111111')
                      where account_id = '33333333-3333-3333-3333-333333333333') = 3000000,
  'earmark on the account = net cash 3.000.000');

-- 2. rules
select pg_temp.expect_error($q$insert into public.plan_ledger (household_id, plan_id, entry_type, amount)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','withdrawal',-4000000)$q$, 'below zero');
select pg_temp.expect_error($q$insert into public.plan_ledger (household_id, plan_id, entry_type, amount)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','deposit',-5)$q$, 'plan_ledger_shape');
select pg_temp.expect_error($q$insert into public.plan_ledger (household_id, plan_id, entry_type, amount, quantity, asset_type, ticker, asset_name, unit_price)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','asset_in',1000,1,'gold','LM','Antam',1000)$q$, 'row-level security');
select pg_temp.expect_error($q$delete from public.plans where id = 'aaaaaaaa-0000-0000-0000-000000000001'$q$, 'Cancel it');

-- 3. holdings in a plan
select pg_temp.check((public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000001',4,1200000)).amount = 4800000,
  'assigning 4 g at 1.200.000 records an asset_in of 4.800.000');
select pg_temp.expect_error($q$select public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000001',7)$q$, 'free to assign');
select pg_temp.check((select earmarked from public.account_earmarks('11111111-1111-1111-1111-111111111111')) = 3000000,
  'assets do not change the cash earmark');
select pg_temp.check((select value_balance from public.plan_ledger_running order by date, created_at desc limit 1) is not null, 'running view works');
reset role;
select pg_temp.check(private.plan_saved('aaaaaaaa-0000-0000-0000-000000000001') = 3000000 + 4 * 1000000,
  'plan saved = cash + assets at cost');
set role authenticated;

-- 4. a second plan with last month's entries, for the statement
insert into public.plans (id, household_id, name, target_amount, start_date, target_date)
values ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Holiday',
        20000000, pg_temp.m(2), current_date + 200);
insert into public.plan_ledger (household_id, plan_id, entry_type, amount, date)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','deposit',1000000, pg_temp.m(1) + 4);
select public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000002','55555555-0000-0000-0000-000000000001',2,900000, pg_temp.m(1) + 5);

select pg_temp.check((select (p ->> 'assets_priced') = 'cost' and (p ->> 'asset_value')::numeric = 1800000
                        and (p ->> 'cash')::numeric = 1000000 and (p ->> 'saved')::numeric = 2800000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p
                      where p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'statement values holdings at cost until prices are saved');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select pg_temp.check((select count(*) from public.plan_holdings) = 2, 'member sees the assignments');
select pg_temp.expect_error($q$select public.set_month_end_prices('11111111-1111-1111-1111-111111111111', pg_temp.m(1), '[]')$q$, 'Only an owner');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
select public.set_month_end_prices('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  format('[{"asset_type":"gold","ticker":"lm","name":"Antam","price":1100000,"price_date":"%s"}]', pg_temp.m(0) - 1)::jsonb);
select pg_temp.check((select (p ->> 'assets_priced') = 'market' and (p ->> 'asset_value')::numeric = 2200000
                        and (p ->> 'saved')::numeric = 3200000 and (p ->> 'deposits')::numeric = 1000000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p
                      where p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'statement values holdings at the month-end price');
select pg_temp.check((select (p ->> 'prices_on')::date = pg_temp.m(0) - 1
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p
                      where p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'statement says which day the prices are for');
select pg_temp.check((select (p ->> 'asset_value')::numeric = 0
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p
                      where p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'assets assigned this month are not in last month''s figures');

-- 5. closing freezes the plan section and locks the plan ledger
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333333":"0"}');
select pg_temp.check((select (p ->> 'asset_value')::numeric = 2200000
                      from public.ledger_closings c, jsonb_array_elements(c.plans) p
                      where c.month = pg_temp.m(1) and p ->> 'plan_id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'closing stored the plan snapshot');
select pg_temp.expect_error($q$select public.set_month_end_prices('11111111-1111-1111-1111-111111111111', pg_temp.m(1), '[]')$q$, 'already closed');
select pg_temp.expect_error($q$insert into public.plan_ledger (household_id, plan_id, entry_type, amount, date)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','deposit',100, pg_temp.m(1) + 6)$q$, 'Closed month');
select pg_temp.expect_error($q$select public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000002','55555555-0000-0000-0000-000000000001',1,null, pg_temp.m(1) + 6)$q$, 'Closed month');

-- 6. selling a lot takes it out of the plans, newest assignment first
select public.sell_holding('11111111-1111-1111-1111-111111111111', 8, 1300000, '33333333-3333-3333-3333-333333333333', '55555555-0000-0000-0000-000000000001');
select pg_temp.check((select coalesce(sum(quantity), 0) from public.plan_holdings) = 2, 'after selling 8 of 10 g, 2 g stay assigned');
select pg_temp.check((select quantity from public.plan_holdings where plan_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2,
  'the older plan keeps 2 g; the newer one lost its 2 g');
select pg_temp.check((select count(*) from public.plan_ledger where entry_type = 'asset_out') = 2, 'two asset_out rows were written');
select pg_temp.check((select count(*) from public.plan_ledger where note like 'Sale proceeds%') = 2
                       and (select sum(amount) from public.plan_ledger where note like 'Sale proceeds%') = 5200000,
  'the sale put 2 g x 1.300.000 into each plan''s cash (5.200.000 in total)');
select pg_temp.check((select earmarked from public.account_earmarks('11111111-1111-1111-1111-111111111111')
                      where account_id = '33333333-3333-3333-3333-333333333333') = 3000000 + 2600000,
  'earmark on the plan account includes its 2.600.000 of sale proceeds');
-- selling the rest deletes the lot; entries in the closed month keep reading fine (holding_id -> null)
select public.sell_holding('11111111-1111-1111-1111-111111111111', 2, 1300000, '33333333-3333-3333-3333-333333333333', '55555555-0000-0000-0000-000000000001');
select pg_temp.check((select count(*) from public.plan_holdings) = 0, 'nothing left assigned');
select pg_temp.check((select sum(amount) from public.plan_ledger where note like 'Sale proceeds%') = 5200000 + 2600000,
  'selling the last 2 g added 2.600.000 more');
-- deleting a lot without selling it releases it but adds no cash
select public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000002',100,9500);
delete from public.holdings where id = '55555555-0000-0000-0000-000000000002';
select pg_temp.check((select count(*) from public.plan_holdings) = 0
                       and (select sum(amount) from public.plan_ledger where note like 'Sale proceeds%') = 5200000 + 2600000,
  'deleting a lot releases it from the plan without adding cash');
select pg_temp.check((select holding_id is null and asset_name = 'Antam' from public.plan_ledger
                      where plan_id = 'aaaaaaaa-0000-0000-0000-000000000002' and entry_type = 'asset_in'),
  'closed-month asset row keeps its description after the lot is gone');

-- 7. another household sees and touches nothing
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c', false);
select pg_temp.check((select count(*) from public.plan_ledger) = 0, 'other household sees no ledger rows');
select pg_temp.expect_error($q$select public.assign_holding_to_plan('aaaaaaaa-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000002',1)$q$, 'Plan not found');
select pg_temp.check((select count(*) from public.account_earmarks('11111111-1111-1111-1111-111111111111')) = 0, 'other household gets no earmarks');

do $$ begin raise notice 'PASSED'; end $$;
