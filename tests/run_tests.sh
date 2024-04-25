#!/usr/bin/env sh

# Change to the directory where the script is located
cd "$(dirname "$0")"

psql $DATABASE_URL -f reset_schema.sql
../beanpost-import.py test.beancount $DATABASE_URL
psql $DATABASE_URL -f tests.sql | diff - expected_output.txt

# Check the exit status of `diff`
if [ $? -eq 0 ]; then
    echo "\n\nPASSED"
fi