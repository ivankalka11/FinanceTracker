\set ON_ERROR_STOP 1
\pset pager off
-- Hardening (20261123000000_hardening.sql): household and member limits, private helpers locked down.
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','o@x'),
 ('00000000-0000-0000-0000-00000000000b','m@x');

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

set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);

-- three households are allowed, the fourth is not
select public.create_household('One', array['A','B']);
select public.create_household('Two', array['A']);
select public.create_household('Three', '{}');
select pg_temp.expect_error($$select public.create_household('Four', '{}')$$, 'maximum number of households');
select pg_temp.expect_error($$select public.create_household('   ', '{}')$$, 'name of up to 80');
select pg_temp.expect_error($$select public.create_household(repeat('x', 81), '{}')$$, 'name of up to 80');

-- members: an unknown address gets the generic message; a known one is added; the cap is 10
select pg_temp.expect_error(
  format($$select public.add_member_by_email(%L, 'nobody@x')$$, (select id from public.households where name = 'One')),
  'Could not add that person');
select public.add_member_by_email((select id from public.households where name = 'One'), 'M@X');
do $$ begin
  if (select count(*) from public.members where household_id = (select id from public.households where name = 'One')) <> 2 then
    raise exception 'member was not added';
  end if;
end $$;

-- the private helpers are no longer executable by signed-in users
select pg_temp.expect_error($$select private.loan_desc('x', null, null)$$, 'permission denied');
select pg_temp.expect_error($$select private.period_figures_base(gen_random_uuid(), current_date)$$, 'permission denied');

\echo ALL HARDENING TESTS PASSED
