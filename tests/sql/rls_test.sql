\set ON_ERROR_STOP 1
\pset pager off
-- Row-level security after 20261124000000_query_performance.sql: membership is checked with
-- "household_id in (select private.my_households())". Who sees and writes what must be unchanged.
-- Household H: owner O and member M. Household H2: owner X (an outsider to H).
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','o@x'),
 ('00000000-0000-0000-0000-00000000000b','m@x'),
 ('00000000-0000-0000-0000-00000000000c','x@x');
insert into public.households (id, name) values
 ('11111111-1111-1111-1111-111111111111','H'),
 ('22222222-2222-2222-2222-222222222222','H2');
insert into public.members values
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000a','owner'),
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-00000000000b','member'),
 ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-00000000000c','owner');
insert into public.accounts (id, household_id, name, opening_balance) values
 ('33333333-3333-3333-3333-333333333331','11111111-1111-1111-1111-111111111111','Ivan', 1000),
 ('33333333-3333-3333-3333-333333333332','22222222-2222-2222-2222-222222222222','Other', 1000);
insert into public.transactions (household_id, date, type, description, amount, source, account_id)
 select '11111111-1111-1111-1111-111111111111', current_date, 'expense', 'h'||g, 10, 'web', '33333333-3333-3333-3333-333333333331'
 from generate_series(1,50) g;
insert into public.transactions (household_id, date, type, description, amount, source, account_id)
 values ('22222222-2222-2222-2222-222222222222', current_date, 'expense', 'h2', 10, 'web', '33333333-3333-3333-3333-333333333332');
insert into public.plans (id, household_id, name, target_amount, start_date, target_date) values
 ('55555555-5555-5555-5555-555555555555','11111111-1111-1111-1111-111111111111','Trip', 1000, current_date, current_date + 90);

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
create function pg_temp.expect_count(sql text, want bigint) returns void language plpgsql as $$
declare n bigint;
begin
  execute sql into n;
  if n <> want then raise exception 'Wanted % rows, got %: %', want, n, sql; end if;
  raise notice 'ok: % rows', n;
end $$;

set role authenticated;

-- the owner and the member both see all of H and nothing of H2
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
select pg_temp.expect_count('select count(*) from public.transactions', 50);
select pg_temp.expect_count('select count(*) from public.accounts', 1);
select pg_temp.expect_count('select count(*) from public.plans', 1);
select pg_temp.expect_count('select count(*) from public.members', 2);
select pg_temp.expect_count('select count(*) from public.account_balances', 1);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b', false);
select pg_temp.expect_count('select count(*) from public.transactions', 50);
-- a member may write household data
insert into public.categories (household_id, name) values ('11111111-1111-1111-1111-111111111111','Snacks');

-- the outsider sees only H2 and cannot touch H
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c', false);
select pg_temp.expect_count('select count(*) from public.transactions', 1);
select pg_temp.expect_count('select count(*) from public.accounts', 1);
select pg_temp.expect_count('select count(*) from public.plans', 0);
select pg_temp.expect_count('select count(*) from public.members', 1);
select pg_temp.expect_count('select count(*) from public.categories', 0);
select pg_temp.expect_error(
  $$insert into public.categories (household_id, name) values ('11111111-1111-1111-1111-111111111111','Hack')$$,
  'row-level security');
select pg_temp.expect_error(
  $$insert into public.transactions (household_id, date, type, description, amount, source, account_id)
    values ('11111111-1111-1111-1111-111111111111', current_date, 'expense', 'x', 1, 'web', '33333333-3333-3333-3333-333333333331')$$,
  'row-level security');
-- updates and deletes of H rows silently match nothing
update public.transactions set amount = 999 where household_id = '11111111-1111-1111-1111-111111111111';
delete from public.accounts where household_id = '11111111-1111-1111-1111-111111111111';

-- a signed-out visitor sees nothing
reset role;
select set_config('request.jwt.claim.sub','', false);
set role anon;
select pg_temp.expect_error('select count(*) from public.transactions', 'permission denied');

reset role;
do $$ begin
  if (select count(*) from public.transactions where household_id = '11111111-1111-1111-1111-111111111111' and amount = 10) <> 50 then
    raise exception 'an outsider changed household data';
  end if;
  if (select count(*) from public.accounts where household_id = '11111111-1111-1111-1111-111111111111') <> 1 then
    raise exception 'an outsider deleted household data';
  end if;
end $$;

\echo ALL RLS TESTS PASSED
