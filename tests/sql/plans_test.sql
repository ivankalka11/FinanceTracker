\set ON_ERROR_STOP 1
\pset pager off
-- Fixtures: household H (owner O, member M), household X (owner Z)
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
 ('44444444-4444-4444-4444-444444444444','22222222-2222-2222-2222-222222222222','Other');

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

-- act as the owner, through RLS
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- 1. plan rules
select pg_temp.expect_error($q$insert into public.plans (household_id,name,target_amount,target_date)
  values ('11111111-1111-1111-1111-111111111111','Past',100,current_date - 1)$q$, 'future');
select pg_temp.expect_error($q$insert into public.plans (household_id,name,target_amount,target_date,account_id)
  values ('11111111-1111-1111-1111-111111111111','Bad acct',100,current_date + 100,'44444444-4444-4444-4444-444444444444')$q$, 'not in this household');
select pg_temp.expect_error($q$insert into public.plans (household_id,name,target_amount,target_date)
  values ('22222222-2222-2222-2222-222222222222','Not mine',100,current_date + 100)$q$, 'row-level security');

insert into public.plans (id, household_id, name, target_amount, start_date, target_date, account_id)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Laptop',10000000,
        current_date - 60, current_date + 120, '33333333-3333-3333-3333-333333333333');
select pg_temp.expect_error($q$update public.plans set behind_since = current_date$q$, 'permission denied');

-- 2. milestones on contribution: 30% -> one '25' milestone, owner only
insert into public.plan_contributions (household_id, plan_id, amount, date)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',3000000,current_date);
select pg_temp.check((select count(*) from public.notifications where kind='plan_milestone' and period_key='25') = 1,
  'one 25% milestone for the owner');
insert into public.plan_contributions (household_id, plan_id, amount, date)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1000,current_date);
select pg_temp.check((select count(*) from public.notifications where kind='plan_milestone') = 1, 'no duplicate milestone');
select pg_temp.check((select title from public.notifications where kind='plan_milestone') = '🎯 Laptop is 25% there', 'milestone title');
select pg_temp.check((select body from public.notifications where kind='plan_milestone') = 'Rp 3.000.000 saved of Rp 10.000.000.', 'Rupiah formatting');

-- member gets nothing by default; sees nothing of the owner's
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select pg_temp.check((select count(*) from public.notifications) = 0, 'member sees no notifications by default');
insert into public.notification_prefs (kind, enabled) values ('plan_milestone', true);
select pg_temp.check((select count(*) from public.plans) = 1, 'member sees household plan');

-- cross household: X owner cannot add to H plan
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c', false);
select pg_temp.expect_error($q$insert into public.plan_contributions (household_id, plan_id, amount)
  values ('22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001',1)$q$, 'not in this household');
select pg_temp.check((select count(*) from public.plans) = 0, 'other household sees no plans');

-- 3. 50% now goes to owner and the opted-in member
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
insert into public.plan_contributions (household_id, plan_id, amount)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',2500000);
reset role;
select pg_temp.check((select count(*) from public.notifications where period_key='50') = 2, '50% to owner + opted-in member');
set role authenticated;

-- 4. delete guard
select pg_temp.expect_error($q$delete from public.plans where id='aaaaaaaa-0000-0000-0000-000000000001'$q$, 'Cancel it');

-- 5. behind: plan started 300 days ago, 60 days left, nothing saved
insert into public.plans (id, household_id, name, icon, target_amount, start_date, target_date)
values ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Nikah','💍',50000000,
        current_date - 300, current_date + 20);
select public.check_notifications('11111111-1111-1111-1111-111111111111') as unread_after_check;
select pg_temp.check((select count(*) from public.notifications where kind='plan_behind' and subject_id='aaaaaaaa-0000-0000-0000-000000000002') = 1, 'behind once');
select pg_temp.check((select count(*) from public.notifications where kind='plan_deadline' and period_key like '30d:%') = 1, '30-day deadline');
select public.check_notifications('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select count(*) from public.notifications where kind='plan_behind') = 1, 'behind not repeated');
select pg_temp.check((select behind_since from public.plans where id='aaaaaaaa-0000-0000-0000-000000000002') = current_date, 'behind_since set');

-- catching up clears the streak; falling behind again re-notifies (new date key needed => simulate)
insert into public.plan_contributions (household_id, plan_id, amount)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002',46000000);
select public.check_notifications('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select behind_since from public.plans where id='aaaaaaaa-0000-0000-0000-000000000002') is null, 'caught up clears behind_since');

-- 6. pausing: no date reminders; moving date re-arms deadline
update public.plans set status='paused' where id='aaaaaaaa-0000-0000-0000-000000000002';
update public.plans set target_date = current_date + 5, status='active' where id='aaaaaaaa-0000-0000-0000-000000000002';
select public.check_notifications('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select count(*) from public.notifications where kind='plan_deadline' and period_key like '7d:%') = 1, '7-day deadline after moving date');

-- 7. reaching 100% achieves and sets achieved_at
insert into public.plan_contributions (household_id, plan_id, amount)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002',4000000);
select pg_temp.check((select status = 'achieved' and achieved_at is not null from public.plans where id='aaaaaaaa-0000-0000-0000-000000000002'), 'auto achieved');
select pg_temp.check((select count(*) from public.notifications where kind='plan_achieved') = 1, 'achieved notification');
-- manual achieve below target, then back
update public.plans set status='achieved' where id='aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.check((select achieved_at is not null from public.plans where id='aaaaaaaa-0000-0000-0000-000000000001'), 'manual achieve sets achieved_at');
update public.plans set status='active' where id='aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.check((select achieved_at is null from public.plans where id='aaaaaaaa-0000-0000-0000-000000000001'), 'resume clears achieved_at');
-- cancelled plan refuses money
update public.plans set status='cancelled' where id='aaaaaaaa-0000-0000-0000-000000000001';
select pg_temp.expect_error($q$insert into public.plan_contributions (household_id, plan_id, amount)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1)$q$, 'cancelled');
update public.plans set status='active' where id='aaaaaaaa-0000-0000-0000-000000000001';

-- 8. notifications: user can mark read, cannot edit title or insert
update public.notifications set read_at = now() where kind='plan_milestone';
select pg_temp.expect_error($q$update public.notifications set title='x'$q$, 'permission denied');
select pg_temp.expect_error($q$insert into public.notifications (household_id,user_id,kind,period_key,title)
  values ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','month_close','x','x')$q$, 'permission denied');

-- 9. push subscriptions
select public.save_push_subscription('https://push.example/abc','k','a','test');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select public.save_push_subscription('https://push.example/abc','k2','a2','test');
select pg_temp.check((select count(*) from public.push_subscriptions) = 1, 'endpoint moved to last signed-in user');
select pg_temp.expect_error($q$select public.save_push_subscription('http://bad','k','a')$q$, 'Incomplete');
select pg_temp.expect_error($q$select public.run_notifications()$q$, 'permission denied');

-- 10. ledger: contributions + transaction link in a closed month, statement plans
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
insert into public.transactions (id, household_id, date, type, amount, account_id)
values ('55555555-5555-5555-5555-555555555555','11111111-1111-1111-1111-111111111111',
        (date_trunc('month', current_date) - interval '1 month')::date + 3, 'transfer-in', 1000000, '33333333-3333-3333-3333-333333333333'),
       ('55555555-5555-5555-5555-555555555556','11111111-1111-1111-1111-111111111111',
        current_date, 'transfer-in', 1000, '33333333-3333-3333-3333-333333333333');
insert into public.plan_contributions (household_id, plan_id, amount, date, transaction_id)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1000000,
        (date_trunc('month', current_date) - interval '1 month')::date + 3, '55555555-5555-5555-5555-555555555555');
insert into public.plan_contributions (household_id, plan_id, amount, date, transaction_id)
values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1000,
        (date_trunc('month', current_date) - interval '1 month')::date + 4, '55555555-5555-5555-5555-555555555556');
select pg_temp.expect_error($q$insert into public.plan_contributions (household_id, plan_id, amount, transaction_id)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1,'55555555-5555-5555-5555-555555555555')$q$, 'duplicate key');

select jsonb_pretty(public.period_statement('11111111-1111-1111-1111-111111111111',
  (date_trunc('month', current_date) - interval '1 month')::date) -> 'plans') as statement_plans;

select public.close_period('11111111-1111-1111-1111-111111111111',
  (date_trunc('month', current_date) - interval '1 month')::date,
  '{"33333333-3333-3333-3333-333333333333": "1000000"}'::jsonb);
select pg_temp.check((select jsonb_array_length(plans) from public.ledger_closings) >= 1, 'closing stored plans');
select pg_temp.check((select bool_or(e ->> 'name' = 'Laptop' and (e ->> 'contributed')::numeric = 1001000)
                      from public.ledger_closings, jsonb_array_elements(plans) e),
  'statement shows Laptop contributed 1,001,000');
select pg_temp.check((select bool_or(e ->> 'name' = 'Nikah') from public.ledger_closings, jsonb_array_elements(plans) e),
  'plan achieved after month end still listed');
select pg_temp.expect_error($q$delete from public.plan_contributions where transaction_id='55555555-5555-5555-5555-555555555555'$q$, 'Closed month');
select pg_temp.expect_error($q$insert into public.plan_contributions (household_id, plan_id, amount, date)
  values ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001',1,(date_trunc('month', current_date) - interval '1 month')::date + 5)$q$, 'Closed month');
-- reopen, delete the linked transaction (set null passes the lock once re-closed)
select public.reopen_period('11111111-1111-1111-1111-111111111111',
  (date_trunc('month', current_date) - interval '1 month')::date, 'test');
select public.close_period('11111111-1111-1111-1111-111111111111',
  (date_trunc('month', current_date) - interval '1 month')::date,
  '{"33333333-3333-3333-3333-333333333333": "1000000"}'::jsonb);
-- a locked contribution linked to an open-month transaction: deleting the
-- transaction must still pass (set null)
delete from public.transactions where id='55555555-5555-5555-5555-555555555556';
select pg_temp.check((select count(*) from public.plan_contributions where transaction_id is null and amount = 1000 and date < date_trunc('month', current_date)) = 1, 'deleting a transaction unlinks its contribution');

-- 11. household delete cascades through every guard
reset role;
delete from public.households where id='11111111-1111-1111-1111-111111111111';
select pg_temp.check((select count(*) from public.plans) = 0 and (select count(*) from public.notifications) = 0, 'household delete cascades');
select public.run_notifications();
\echo ALL TESTS PASSED
