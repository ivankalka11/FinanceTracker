#!/usr/bin/env sh
# Applies the migrations to a throwaway Postgres 15 (Docker) and runs the
# SQL tests (ledger close/reopen, plans), each on a fresh database.
# Usage: sh tests/sql/run.sh   (from the repo root; needs Docker running)
set -e
export MSYS_NO_PATHCONV=1
docker rm -f ft-pgtest >/dev/null 2>&1 || true
docker run -d --name ft-pgtest -e POSTGRES_PASSWORD=x postgres:15 >/dev/null
until docker exec ft-pgtest pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
sleep 2
docker exec ft-pgtest mkdir -p /t
docker cp tests/sql/supabase_stubs.sql ft-pgtest:/t/00.sql
docker cp supabase/migrations/20261114000000_init.sql ft-pgtest:/t/10.sql
docker cp supabase/migrations/20261117000000_ledger_closing.sql ft-pgtest:/t/20.sql
docker cp supabase/migrations/20261118000000_plans.sql ft-pgtest:/t/30.sql
docker cp supabase/migrations/20261119000000_plan_ledger.sql ft-pgtest:/t/40.sql
docker cp supabase/migrations/20261120000000_plan_sale_and_month_end.sql ft-pgtest:/t/50.sql
docker cp supabase/migrations/20261121000000_scheduled_jobs.sql ft-pgtest:/t/60.sql
docker cp tests/sql/ledger_test.sql ft-pgtest:/t/ledger.sql
docker cp tests/sql/plans_test.sql ft-pgtest:/t/plans.sql
docker cp tests/sql/plan_ledger_test.sql ft-pgtest:/t/plan_ledger.sql
docker cp tests/sql/price_snapshots_test.sql ft-pgtest:/t/price_snapshots.sql
status=0
for t in ledger plans plan_ledger price_snapshots; do
  echo "== $t"
  docker exec ft-pgtest psql -U postgres -q -c "drop database if exists t" -c "create database t" >/dev/null
  docker exec ft-pgtest psql -U postgres -d t -q -f /t/00.sql >/dev/null 2>&1   # roles already exist after the first run
  for f in 10 20 30 40 50 60; do
    docker exec ft-pgtest psql -U postgres -d t -q -v ON_ERROR_STOP=1 -f /t/$f.sql >/dev/null 2>&1 || { echo "migration $f failed"; exit 1; }
  done
  out=$(docker exec ft-pgtest psql -U postgres -d t -q -f /t/$t.sql 2>&1)
  echo "$out" | grep -E "NOTICE:  ok|ERROR|PASSED" | sed 's/^psql:[^ ]* //'
  echo "$out" | grep -q "PASSED" || status=1
done
docker rm -f ft-pgtest >/dev/null
exit $status
