-- Hardening, from a security review.
--
--  1. Internal helpers in the private schema lose their default EXECUTE grant. They are only
--     called from other SECURITY DEFINER functions and triggers (which run as the owner and
--     need no grant), and the schema is not exposed through the API, so nothing changes.
--  2. create_household() is limited: up to 3 households per user, sane name and account sizes.
--     Any signed-in user may call it, so without a limit one account could create rows forever.
--  3. add_member_by_email() caps a household at 10 members and no longer says that a given
--     address has no account in so many words. This does NOT make the lookup private: success
--     still tells the owner the address exists. The real protection is to turn off public
--     sign-ups (Supabase Dashboard -> Authentication -> Sign In / Providers -> "Allow new users
--     to sign up"), so that only people you invite can have an account at all.

revoke all on function private.period_figures_base(uuid, date) from public, anon, authenticated;
revoke all on function private.closing_loans() from public, anon, authenticated;
revoke all on function private.closing_account_loans() from public, anon, authenticated;
revoke all on function private.loan_desc(text, uuid, text) from public, anon, authenticated;

create or replace function public.create_household(p_name text, p_accounts text[] default '{}')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
  v_acc text;
  v_pos integer := 0;
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 or length(trim(p_name)) > 80 then
    raise exception 'Give the household a name of up to 80 characters';
  end if;
  if coalesce(array_length(p_accounts, 1), 0) > 30 then
    raise exception 'A household starts with at most 30 accounts';
  end if;
  if (select count(*) from public.households h where h.created_by = v_uid) >= 3 then
    raise exception 'You already have the maximum number of households';
  end if;

  insert into public.households (name, created_by)
  values (trim(p_name), v_uid) returning id into v_id;

  insert into public.members (household_id, user_id, role)
  values (v_id, v_uid, 'owner');

  foreach v_acc in array coalesce(p_accounts, '{}') loop
    if length(trim(v_acc)) > 0 then
      if length(trim(v_acc)) > 60 then
        raise exception 'Account names can be up to 60 characters';
      end if;
      insert into public.accounts (household_id, name, sort_order)
      values (v_id, trim(v_acc), v_pos);
      v_pos := v_pos + 1;
    end if;
  end loop;

  return v_id;
end;
$$;

create or replace function public.add_member_by_email(p_household uuid, p_email text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid;
begin
  if not private.is_owner(p_household) then
    raise exception 'Only the household owner can add members';
  end if;
  if (select count(*) from public.members m where m.household_id = p_household) >= 10 then
    raise exception 'A household can have up to 10 members';
  end if;

  select u.id into v_user from auth.users u where lower(u.email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'Could not add that person. Check the address, and make sure they already have an account.';
  end if;

  insert into public.members (household_id, user_id, role)
  values (p_household, v_user, 'member')
  on conflict do nothing;
end;
$$;
