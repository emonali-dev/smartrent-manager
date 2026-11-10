#!/bin/bash
# Loads db/schema.sql into a fresh throwaway database and runs db/tests.sql.
# Never point this at a real database.
# usage: db/run-tests.sh [psql connection args, e.g. -h localhost -p 5432 -U postgres]
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
P="psql $* -q -X"
$P -d postgres -c "drop database if exists smartrent_test" -c "create database smartrent_test" >/dev/null || { echo "cannot create test database"; exit 2; }
$P -d smartrent_test -v ON_ERROR_STOP=1 -f "$DIR/schema.sql" >/dev/null || { echo "schema failed to load"; exit 1; }
OUT=$($P -d smartrent_test -f "$DIR/tests.sql" 2>&1)
echo "$OUT" | grep -E '^(ok|FAIL)'
echo "$OUT" | grep -E 'ERROR' && { echo "unexpected SQL error"; exit 1; }
echo "passed: $(echo "$OUT" | grep -c '^ok')  failed: $(echo "$OUT" | grep -c '^FAIL')"
echo "$OUT" | grep -q '^FAIL' && exit 1 || exit 0
