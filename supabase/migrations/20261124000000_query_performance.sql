-- Query performance for larger data, from a benchmark on 100,000 transactions.
--
-- The row-level security policies called private.is_member(household_id) for every row a query
-- looked at. A function that takes the row's value cannot be cached, so reading a household's
-- whole history cost about one membership lookup per row. Measured as a signed-in user:
--
--                                   before      after
--   whole history (100k rows)       1,178 ms     104 ms
--   deepest page of the history     1,736 ms      97 ms
--   account balances                  928 ms      36 ms
--   row count                         842 ms      18 ms
--
-- The fix: private.my_households() returns the signed-in user's household ids, and each policy
-- asks "household_id in (select private.my_households())". Postgres runs that subquery once per
-- query and checks each row against the result. Who may see or write what does not change.
--
-- Also adds two small indexes for foreign keys that were only ever scanned in full (deleting a
-- category or a holding looked through every transaction or plan entry).

create function private.my_households()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select m.household_id from public.members m where m.user_id = (select auth.uid());
$$;

revoke all on function private.my_households() from public, anon;
grant execute on function private.my_households() to authenticated;

-- Household data: full access for members.
alter policy accounts_all     on public.accounts     using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy categories_all   on public.categories   using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy transactions_all on public.transactions using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy holdings_all     on public.holdings     using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy sales_all        on public.sales        using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy receipts_all     on public.receipts     using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));
alter policy plans_all        on public.plans        using (household_id in (select private.my_households())) with check (household_id in (select private.my_households()));

-- Read-only tables for members.
alter policy members_select                 on public.members                 using (household_id in (select private.my_households()));
alter policy ledger_closings_select         on public.ledger_closings         using (household_id in (select private.my_households()));
alter policy ledger_closing_accounts_select on public.ledger_closing_accounts using (household_id in (select private.my_households()));
alter policy ledger_closing_events_select   on public.ledger_closing_events   using (household_id in (select private.my_households()));
alter policy plan_holdings_select           on public.plan_holdings           using (household_id in (select private.my_households()));
alter policy month_end_prices_select        on public.month_end_prices        using (household_id in (select private.my_households()));
alter policy loans_select                   on public.loans                   using (household_id in (select private.my_households()));

-- Plan ledger: members add and fix cash entries; asset rows come only from the functions.
alter policy plan_ledger_select on public.plan_ledger
  using (household_id in (select private.my_households()));
alter policy plan_ledger_insert on public.plan_ledger
  with check (household_id in (select private.my_households()) and entry_type in ('deposit', 'withdrawal', 'adjustment'));
alter policy plan_ledger_update on public.plan_ledger
  using (household_id in (select private.my_households()) and entry_type in ('deposit', 'withdrawal', 'adjustment'))
  with check (household_id in (select private.my_households()) and entry_type in ('deposit', 'withdrawal', 'adjustment'));
alter policy plan_ledger_delete on public.plan_ledger
  using (household_id in (select private.my_households()) and entry_type in ('deposit', 'withdrawal', 'adjustment'));

-- Left as they are: households (keyed by id, one row each), the owner-only policies, and the
-- per-user tables (notifications, preferences, Telegram), which filter on user_id.

create index transactions_category_idx on public.transactions (category_id) where category_id is not null;
create index plan_ledger_holding_idx on public.plan_ledger (holding_id) where holding_id is not null;
