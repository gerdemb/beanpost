#!/usr/bin/env sh

# Change to the directory where the script is located
cd "$(dirname "$0")"

psql $DATABASE_URL --quiet --file=tests.sql > expected_output.txt
