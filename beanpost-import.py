#!/usr/bin/env python

import json
import logging
import sys
from pathlib import Path

import psycopg2 as dbapi
from beancount import loader
from beancount.core import data
from beancount.parser import version
from beancount.utils import misc_utils
from psycopg2.extensions import parse_dsn
from psycopg2.extras import execute_batch

account_map: dict[str, int] = {}
document_path: Path


def truncate(cursor, _):
    cursor.execute(
        """
ALTER TABLE "public"."document"
  DROP CONSTRAINT "document_account_id_fkey",
  ALTER COLUMN "account_id" DROP NOT NULL;
"""
    )
    cursor.execute(
        """
UPDATE document SET account_id = NULL;
"""
    )
    cursor.execute(
        """
                   TRUNCATE account, transaction, price, posting, assertion, commodity;
                   """
    )


def import_accounts(cursor, entries):
    account_values = []

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Open):
            meta = get_meta_json(entry.meta)
            account_values.append(
                (eid, entry.account, entry.date, entry.currencies, meta)
            )
            account_map[entry.account] = eid
    execute_batch(
        cursor,
        """
            INSERT INTO account (id, name, open_date, currencies, meta) 
                            VALUES (%s, %s, %s, %s, %s);
                  """,
        account_values,
    )

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Close):
            cursor.execute(
                """
                UPDATE account SET close_date = %s WHERE name = %s; 
            """,
                (entry.date, entry.account),
            )


def import_transactions(cursor, entries):
    transaction_values = []
    posting_values = []

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Transaction):
            transaction_values.append(
                (
                    eid,
                    entry.flag or "",
                    entry.payee or "",
                    entry.narration or "",
                    list(entry.tags),
                    list(entry.links),
                )
            )

            for posting in entry.postings:
                amount = get_amount(posting.units)
                cost = get_amount(posting.cost)
                price = get_amount(posting.price)
                account_id = account_map[posting.account]
                posting_values.append(
                    (entry.date, account_id, eid, posting.flag, amount, price, cost)
                )

    execute_batch(
        cursor,
        """
        INSERT INTO transaction (id, flag, payee, narration, tags, links)
        VALUES (%s, %s, %s, %s, %s, %s);
                  """,
        transaction_values,
    )
    execute_batch(
        cursor,
        """
        INSERT INTO posting (date, account_id, transaction_id, flag, amount, price, cost)
        VALUES (%s, %s, %s, %s, %s, %s, %s);
                  """,
        posting_values,
    )


def import_balances(cursor, entries):
    balance_values = []

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Balance):
            account_id = account_map[entry.account]
            amount = get_amount(entry.amount)
            balance_values.append((eid, entry.date, account_id, amount))

    execute_batch(
        cursor,
        """
        INSERT INTO assertion (id, date, account_id, amount) 
        VALUES (%s, %s, %s, %s);
                    """,
        balance_values,
    )


def import_prices(cursor, entries):
    price_values = []

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Price):
            amount = get_amount(entry.amount)
            price_values.append((eid, entry.date, entry.currency, amount))

    execute_batch(
        cursor,
        """
        INSERT INTO price (id, date, currency, amount) 
        VALUES (%s, %s, %s, %s);
                  """,
        price_values,
    )


def import_commodities(cursor, entries):
    commodity_values = []

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Commodity):
            decimal_places = entry.meta.pop(
                "decimal_places", 0
            )  # This modifies entry.meta. Assuming that's OK.
            meta = get_meta_json(entry.meta)
            commodity_values.append(
                (
                    eid,
                    entry.date,
                    entry.currency,
                    decimal_places,
                    meta,
                )
            )

    execute_batch(
        cursor,
        """
        INSERT INTO commodity (id, date, currency, decimal_places, meta) 
        VALUES (%s, %s, %s, %s, %s);
                  """,
        commodity_values,
    )


def import_documents(cursor, entries):
    def read_data(filename):
        """
        Reads the content of the file specified by `filename` in binary mode.
        Returns the binary content of the file.
        """
        with open(filename, "rb") as file:
            return file.read()

    for eid, entry in enumerate(entries):
        if isinstance(entry, data.Document):
            account_id = account_map[entry.account]
            filename = str(Path(entry.filename).relative_to(document_path))

            # Check if the document already exists in the database
            cursor.execute(
                """
SELECT 1 FROM document WHERE date = %s AND filename = %s LIMIT 1;
                """,
                (entry.date, filename),
            )
            if cursor.fetchone():
                # UPDATE
                cursor.execute(
                    """
UPDATE document SET account_id = %s WHERE date = %s AND filename = %s;
""",
                    (account_id, entry.date, filename),
                )
            else:
                file_data = read_data(entry.filename)
                cursor.execute(
                    """
INSERT INTO document (id, date, account_id, filename, data) 
        VALUES (%s, %s, %s, %s, %s);
                           """,
                    (eid, entry.date, account_id, str(filename), file_data),
                )

    # Add back constraints
    cursor.execute(
        """
DELETE FROM document WHERE account_id IS NULL;
"""
    )
    cursor.execute(
        """
ALTER TABLE "public"."document"
  ADD FOREIGN KEY ("account_id") REFERENCES "public"."account"("id"),
  ALTER COLUMN "account_id" SET NOT NULL;
"""
    )


def get_amount(amount):
    return (amount.number, amount.currency) if amount is not None else None


def get_meta_json(meta):
    keys_to_remove = {"filename", "lineno"}
    filtered_meta = {
        key: value for key, value in meta.items() if key not in keys_to_remove
    }

    return json.dumps(filtered_meta)


def main():
    global document_path

    parser = version.ArgumentParser(description=__doc__)
    parser.add_argument("filename", help="Beancount input filename")
    parser.add_argument("database", help="PostgreSQL connection string")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)-8s: %(message)s")

    entries, errors, options_map = loader.load_file(
        args.filename, log_timings=logging.info, log_errors=sys.stderr
    )

    document_path = Path(args.filename).parent / options_map["documents"][0]

    dsn = parse_dsn(args.database)
    connection = dbapi.connect(**dsn)
    cursor = connection.cursor()

    for function in [
        truncate,
        import_accounts,
        import_transactions,
        import_balances,
        import_prices,
        import_commodities,
        import_documents,
    ]:
        step_name = getattr(function, "__name__", function.__class__.__name__)
        with misc_utils.log_time(step_name, logging.info):
            function(cursor, entries)

    connection.commit()
    cursor.close()
    connection.close()


if __name__ == "__main__":
    main()
