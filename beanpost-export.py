#!/usr/bin/env python

import logging
from argparse import ArgumentParser
from pathlib import Path

import psycopg2 as dbapi
import psycopg2.extras
from beancount.utils import misc_utils
from psycopg2.extensions import parse_dsn


def export_accounts(cursor, file):
    # Execute the SQL query
    cursor.execute(
        """
SELECT
	name,
	open_date,
	close_date,
	currencies,
    meta
FROM
	account
ORDER BY
	account.id
                   """
    )

    # Fetch all rows from the cursor
    rows = cursor.fetchall()

    # Iterate over each row
    for row in rows:
        open_date = row["open_date"]
        name = row["name"]
        # Handle None case by defaulting to an empty list if row["currencies"] is None
        currencies = ",".join(row["currencies"] or [])

        # Write the open_date to the file followed by a newline
        file.write(f"{open_date} open {name} {currencies}\n")
        export_meta(file, row["meta"])

        if close_date := row["close_date"]:
            file.write(f"{close_date} close {name}\n\n")


def export_transactions(cursor, file):
    cursor.execute(
        """
SELECT
	transaction.id,
	transaction.flag,
	transaction.payee,
	transaction.narration,
	transaction.tags,
	transaction.links,
	posting.date,
	posting.amount,
	posting.cost,
	posting.cost_date,
	posting.cost_label,
	posting.price,
	account.name
FROM
	TRANSACTION
	JOIN posting ON posting.transaction_id = transaction.id
	JOIN account ON account.id = posting.account_id
ORDER BY
	transaction.id
"""
    )

    rows = cursor.fetchall()
    transaction_id = None

    # Iterate over each row
    for row in rows:
        if transaction_id != row["id"]:
            transaction_id = row["id"]
            date = row["date"]
            flag = row["flag"] or ""
            payee = row["payee"] or ""
            narration = row["narration"] or ""
            file.write(f'\n{date} {flag} "{payee}" "{narration}"\n')
        account = row["name"]
        number, currency = parse_amount(row["amount"])
        amount = f"{number} {currency}"
        if cost := row["cost"]:
            number, currency = parse_amount(cost)
            cost_date = row["cost_date"]
            cost_label = row["cost_label"]
            if cost_label:
                amount += f' {{{cost_date}, {number} {currency}, "{cost_label}"}}'
            else:
                amount += f" {{{cost_date}, {number} {currency}}}"
        if price := row["price"]:
            number, currency = parse_amount(price)
            amount += f" @ {number} {currency}"

        file.write(f"  {account} {amount}\n")


def export_balances(cursor, file):
    # Execute the SQL query
    cursor.execute(
        """
SELECT
	assertion.date,
	assertion.amount,
	account.name
FROM
	assertion
	JOIN account ON account.id = assertion.account_id
ORDER BY
	assertion.id
"""
    )

    # Fetch all rows from the cursor
    rows = cursor.fetchall()

    # Iterate over each row
    for row in rows:
        date = row["date"]
        account = row["name"]
        number, currency = parse_amount(row["amount"])
        file.write(f"{date} balance {account} {number} {currency}\n\n")


def export_prices(cursor, file):
    # Execute the SQL query
    cursor.execute(
        """
SELECT
	date, currency, amount
FROM
	price
ORDER BY
    price.id
"""
    )

    # Fetch all rows from the cursor
    rows = cursor.fetchall()

    # Iterate over each row
    for row in rows:
        date = row["date"]
        base_currency = row["currency"]
        number, currency = parse_amount(row["amount"])
        file.write(f"{date} price {base_currency} {number} {currency}\n\n")


def export_commodities(cursor, file):
    # Execute the SQL query
    cursor.execute(
        """
SELECT
	date, currency, decimal_places, meta
FROM
	commodity
ORDER BY
    commodity.id
"""
    )

    # Fetch all rows from the cursor
    rows = cursor.fetchall()

    # Iterate over each row
    for row in rows:
        date = row["date"]
        currency = row["currency"]
        decimal_places = row["decimal_places"]
        meta = row["meta"]
        meta["decimal_places"] = decimal_places
        file.write(f"{date} commodity {currency}\n")
        export_meta(file, meta)


def export_documents(cursor, file):
    documents_path = Path(file.name).parent / "documents"

    # Selecting without fetching document.data initially
    cursor.execute(
        """
SELECT
    document.date,
    document.filename,
    document.id,
    account.name
FROM
    document
    JOIN account ON account.id = document.account_id
ORDER BY
    document.id
"""
    )

    # Fetch all rows from the cursor
    rows = cursor.fetchall()

    # Iterate over each row
    for row in rows:
        relative_path = Path(row["filename"])
        final_path = documents_path / relative_path

        # Check if the file already exists
        if not final_path.exists():
            # Fetch the document data only if the file does not exist
            cursor.execute(
                """
SELECT document.data
FROM document
WHERE document.id = %s;
                """,
                (row["id"],),
            )
            data = cursor.fetchone()["data"]

            # Ensure the directory for this file exists
            final_path.parent.mkdir(parents=True, exist_ok=True)

            # Write bytea data in data column to final_path
            with final_path.open("wb") as doc_file:
                doc_file.write(data)


def export_insert_entry(cursor, file):
    file.write('2020-01-01 custom "fava-option" "insert-entry" ".*"')


def parse_amount(amount):
    stripped_string = amount.strip("()")
    number, currency = stripped_string.split(",")
    return number, currency


def export_meta(file, meta):
    for k, v in meta.items():
        # Check if the value is of boolean type
        if isinstance(v, bool):
            # Convert boolean to uppercase string
            value_str = "TRUE" if v else "FALSE"
        # Check if the value is a string
        elif isinstance(v, str):
            # Surround the string with quotes
            value_str = f'"{v}"'
        else:
            value_str = v
        file.write(f"  {k}: {value_str}\n")


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("database", help="PostgreSQL connection string")
    parser.add_argument("filename", help="Beancount filename")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)-8s: %(message)s")

    dsn = parse_dsn(args.database)
    connection = dbapi.connect(**dsn)
    cursor = connection.cursor(cursor_factory=psycopg2.extras.DictCursor)

    absolute_file_path = Path(args.filename).resolve()
    with absolute_file_path.open("w") as file:
        for function in [
            export_accounts,
            export_transactions,
            export_balances,
            export_prices,
            export_commodities,
            export_documents,
            export_insert_entry,
        ]:
            step_name = getattr(function, "__name__", function.__class__.__name__)
            with misc_utils.log_time(step_name, logging.info):
                function(cursor, file)

    connection.commit()
    cursor.close()
    connection.close()


if __name__ == "__main__":
    main()
