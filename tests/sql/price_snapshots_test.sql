\set ON_ERROR_STOP 1
insert into auth.users values ('00000000-0000-0000-0000-00000000000a','o@x');
insert into public.price_snapshots values ('stock','BBCA',current_date,5500,now());
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a', false);
do $$ begin
  if (select count(*) from public.price_snapshots) <> 1 then raise exception 'FAILED: authenticated cannot read snapshots'; end if;
  raise notice 'ok: signed-in user reads snapshots';
  begin insert into public.price_snapshots values ('gold','LM',current_date,1,now()); raise exception 'FAILED: user could write';
  exception when insufficient_privilege then raise notice 'ok (refused): users cannot write snapshots'; end;
end $$;
reset role; set role anon;
do $$ begin
  begin perform count(*) from public.price_snapshots; raise exception 'FAILED: anon could read';
  exception when insufficient_privilege then raise notice 'ok (refused): anon cannot read snapshots'; end;
end $$;
do $$ begin raise notice 'PASSED'; end $$;
