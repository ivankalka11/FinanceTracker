\set ON_ERROR_STOP 1
\pset pager off
-- Close / reopen rules (20261117000000_ledger_closing.sql + plans additions).
-- Household H: owner O, member M. Months are relative to today:
--   m3 = three months ago, m2 = two months ago, m1 = last month, m0 = this month.
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','o@x'),
 ('00000000-0000-0000-0000-00000000000b','m@x');
insert into public.households (id, name) values ('11111111-1111-1111-1111-111111111111','H');
insert into public.members values
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','owner'),
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000b','member');
insert into public.accounts (id, household_id, name, opening_balance) values
 ('33333333-3333-3333-3333-333333333331','11111111-1111-1111-1111-111111111111','Ivan', 1000000),
 ('33333333-3333-3333-3333-333333333332','11111111-1111-1111-1111-111111111111','Bersama', 0);
insert into public.categories (id, household_id, name) values
 ('66666666-6666-6666-6666-666666666661','11111111-1111-1111-1111-111111111111','Food'),
 ('66666666-6666-6666-6666-666666666662','11111111-1111-1111-1111-111111111111','Salary');

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

-- entries: salary + food in m2 and m1, one in m0
insert into public.transactions (id, household_id, date, type, category_id, amount, account_id, description) values
 ('77777777-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111', pg_temp.m(2)+1,'income','66666666-6666-6666-6666-666666666662',10000000,'33333333-3333-3333-3333-333333333331','salary'),
 ('77777777-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111', pg_temp.m(2)+5,'expense','66666666-6666-6666-6666-666666666661',2000000,'33333333-3333-3333-3333-333333333331','food'),
 ('77777777-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111', pg_temp.m(1)+1,'income','66666666-6666-6666-6666-666666666662',10000000,'33333333-3333-3333-3333-333333333331','salary'),
 ('77777777-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111', pg_temp.m(1)+9,'expense', null,500000,'33333333-3333-3333-3333-333333333331','no category'),
 ('77777777-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111', current_date,'expense','66666666-6666-6666-6666-666666666661',100000,'33333333-3333-3333-3333-333333333331','today');
select public.add_transfer('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333331','33333333-3333-3333-3333-333333333332',3000000,pg_temp.m(1)+10,'to joint');
insert into public.plans (id, household_id, name, target_amount, start_date, target_date)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Laptop',20000000, pg_temp.m(2), current_date + 200);
insert into public.plan_contributions (household_id, plan_id, amount, date)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',2000000, pg_temp.m(1)+11);

-- 1. statement figures (draft)
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) ->> 'can_close')::boolean,
  'last month can be closed');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(0)) ->> 'blocked_reason') = 'This month has not ended yet.',
  'this month cannot be closed yet');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) #>> '{totals,income}')::numeric = 10000000,
  'income in statement');
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) #>> '{checklist,uncategorised}')::int = 1,
  'checklist counts the uncategorised entry');
-- Ivan: 1,000,000 + 10,000,000 - 2,000,000 (m2) = 9,000,000 opening; +10,000,000 -500,000 -3,000,000 = 15,500,000
select pg_temp.check((select (a ->> 'opening')::numeric = 9000000 and (a ->> 'closing')::numeric = 15500000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'accounts') a
                      where a ->> 'name' = 'Ivan'), 'Ivan opening 9.000.000, closing 15.500.000');
select pg_temp.check((select (a ->> 'closing')::numeric = 3000000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'accounts') a
                      where a ->> 'name' = 'Bersama'), 'Bersama closing 3.000.000 (transfer in)');
select pg_temp.check((select (p ->> 'contributed')::numeric = 2000000
                      from jsonb_array_elements(public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) -> 'plans') p),
  'draft statement lists plan money');

-- 2. close validation
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(0),
  '{"33333333-3333-3333-3333-333333333331":"0","33333333-3333-3333-3333-333333333332":"0"}')$q$, 'has not ended yet');
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15500000"}')$q$, 'Enter the bank balance for Bersama');
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15400000","33333333-3333-3333-3333-333333333332":"3000000"}')$q$, 'differs from the bank');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select pg_temp.check((public.period_statement('11111111-1111-1111-1111-111111111111', pg_temp.m(1)) ->> 'blocked_reason') = 'Only an owner can close a month.',
  'member is told only owners close');
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15500000","33333333-3333-3333-3333-333333333332":"3000000"}')$q$, 'Only an owner');
select pg_temp.expect_error($q$insert into public.ledger_closings (household_id, month, opening, income, expense, invest, transfer_in, transfer_out, closing)
  values ('11111111-1111-1111-1111-111111111111', pg_temp.m(1), 0,0,0,0,0,0,0)$q$, 'permission denied');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 3. close last month with a difference explained (first close: m2 gets locked too)
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15490000","33333333-3333-3333-3333-333333333332":"3000000"}',
  '{"33333333-3333-3333-3333-333333333331":"bank admin fee"}', 'test close');
select pg_temp.check((select count(*) = 1 and bool_and(version = 1 and status = 'closed') from public.ledger_closings), 'snapshot v1 stored');
select pg_temp.check((select difference = -10000 and difference_note = 'bank admin fee' from public.ledger_closing_accounts where account_name = 'Ivan'),
  'difference and note stored');
select pg_temp.check((select jsonb_array_length(plans) = 1 from public.ledger_closings), 'snapshot has plans section');
select pg_temp.check(private.locked_through('11111111-1111-1111-1111-111111111111') = (pg_temp.m(0) - 1), 'locked through end of last month');

-- 4. the lock
select pg_temp.expect_error($q$insert into public.transactions (household_id, date, type, amount) values
  ('11111111-1111-1111-1111-111111111111', pg_temp.m(1)+2, 'expense', 1)$q$, 'Closed month');
select pg_temp.expect_error($q$insert into public.transactions (household_id, date, type, amount) values
  ('11111111-1111-1111-1111-111111111111', pg_temp.m(2)+2, 'expense', 1)$q$, 'Closed month');
select pg_temp.expect_error($q$update public.transactions set amount = 1 where id = '77777777-0000-0000-0000-000000000003'$q$, 'Closed month');
select pg_temp.expect_error($q$update public.transactions set date = current_date where id = '77777777-0000-0000-0000-000000000003'$q$, 'Closed month');
select pg_temp.expect_error($q$update public.transactions set date = pg_temp.m(1)+3 where id = '77777777-0000-0000-0000-000000000005'$q$, 'Closed month');
select pg_temp.expect_error($q$delete from public.transactions where id = '77777777-0000-0000-0000-000000000002'$q$, 'Closed month');
select pg_temp.expect_error($q$insert into public.plan_contributions (household_id, plan_id, amount, date)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1, pg_temp.m(1)+3)$q$, 'Closed month');
insert into public.transactions (household_id, date, type, amount) values ('11111111-1111-1111-1111-111111111111', current_date, 'expense', 1);
select pg_temp.check(true, 'this month still open for new entries');
-- deleting a category only nulls it on locked rows
delete from public.categories where id = '66666666-6666-6666-6666-666666666661';
select pg_temp.check((select category_id is null from public.transactions where id = '77777777-0000-0000-0000-000000000002'),
  'deleting a category passes the lock');

-- 5. order: cannot skip ahead or close an older month
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(2), '{}')$q$, 'already closed');
select pg_temp.expect_error($q$select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1), '{}')$q$, 'already closed');

-- 6. reopen
select pg_temp.expect_error($q$select public.reopen_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1), '  ')$q$, 'Say why');
select pg_temp.expect_error($q$select public.reopen_period('11111111-1111-1111-1111-111111111111', pg_temp.m(2), 'older')$q$, 'Only the latest closed month');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select pg_temp.expect_error($q$select public.reopen_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1), 'member')$q$, 'Only an owner');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
select public.reopen_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1), 'late receipt');
select pg_temp.check(private.locked_through('11111111-1111-1111-1111-111111111111') is null, 'reopening the only closed month unlocks everything');
select pg_temp.check((select status from public.ledger_closings where version = 1) = 'superseded', 'v1 kept as superseded');
-- fix the books now that it is open
insert into public.transactions (household_id, date, type, amount, account_id, description)
values ('11111111-1111-1111-1111-111111111111', pg_temp.m(1)+30, 'expense', 10000, '33333333-3333-3333-3333-333333333331', 'bank fee');
select pg_temp.check(true, 'reopened month accepts the fix');

-- 7. close again: version 2, matches the bank now, no note needed
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15490000","33333333-3333-3333-3333-333333333332":"3000000"}');
select pg_temp.check((select version from public.ledger_closings where status = 'closed') = 2, 'closed again as version 2');
select pg_temp.check((select difference = 0 from public.ledger_closing_accounts a join public.ledger_closings c on c.id = a.closing_id
                      where c.version = 2 and a.account_name = 'Ivan'), 'v2 matches the bank');
select pg_temp.check((select string_agg(action || ':' || version, ',' order by at, action) from public.ledger_closing_events) in
                     ('close:1,reopen:1,close:2'), 'history close:1, reopen:1, close:2');
select pg_temp.check((select reason from public.ledger_closing_events where action = 'reopen') = 'late receipt', 'reopen reason recorded');

-- 8. snapshot rows cannot be edited by users
select pg_temp.expect_error($q$update public.ledger_closings set income = 0$q$, 'permission denied');
select pg_temp.expect_error($q$delete from public.ledger_closings$q$, 'permission denied');

-- 9. month-close reminders are marked read by closing
reset role;
insert into public.notifications (household_id, user_id, kind, period_key, title)
values ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','month_close', to_char(pg_temp.m(0),'YYYY-MM') || '-last','t');
update public.ledger_closings set status = 'superseded' where status = 'closed';  -- simulate reopen
insert into public.ledger_closing_events (household_id, month, version, action, reason) values ('11111111-1111-1111-1111-111111111111', pg_temp.m(1), 2, 'reopen', 'sim');
set role authenticated;
-- close m1 again (v3), then check this month's reminder is untouched and m1 reminders are read
reset role;
insert into public.notifications (household_id, user_id, kind, period_key, title)
values ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','month_close', to_char(pg_temp.m(1),'YYYY-MM') || '-d3','t');
set role authenticated;
select public.close_period('11111111-1111-1111-1111-111111111111', pg_temp.m(1),
  '{"33333333-3333-3333-3333-333333333331":"15490000","33333333-3333-3333-3333-333333333332":"3000000"}');
select pg_temp.check((select read_at is not null from public.notifications where period_key like to_char(pg_temp.m(1),'YYYY-MM') || '-%'),
  'closing marks that month''s reminder read');
select pg_temp.check((select read_at is null from public.notifications where period_key like to_char(pg_temp.m(0),'YYYY-MM') || '-%'),
  'other months'' reminders untouched');
\echo ALL LEDGER TESTS PASSED
