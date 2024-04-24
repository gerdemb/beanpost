# beanpost

An experiment using PostgreSQL for accounting, inspired by the fantastic [beancount](https://beancount.github.io), a plain text accounting package.

## The Idea

Recreate the functionality of plain text accounting using a PostgreSQL database.

## Why?

It's an interesting challenge! 😀 Additionally, PostgreSQL provides a standard interface for querying and manipulating data, and it can easily be used as a back-end for other services like web apps, reporting tools, etc.

## How Does It Work?

The project has three main components:

1. A PostgreSQL schema `schema.sql`
2. An import command `beanpost-import.py` to import data from a beanpost file into the database
3. An export command `beanpost-export.py` to export data from the database to a beancount file

## How Do I Try This?

To get started with beanpost, follow these steps:

1. Create the schema in your PostgreSQL database with:

`psql -d your_database -f schema.sql`

2. Import a beancount file into the database:

`beanpost-import.py data.beancount postgresql:///your_database`

3. Export the database to a beancount file:

`beanpost-export.py postgresql:///your_database export.beancount`

## What Is the Database Schema?

The database schema closely aligns with beancount's directives: `Account`, `Transaction`, `Posting`, `Price`, and `Document`. For clarity, beancount `Balance` directives are stored in a table called `assertion`.

A custom type, amount, is defined as follows:

```
CREATE TYPE amount AS (
	number numeric,
	currency text
);
```

This custom type enables PostgreSQL functions like `sum(amount)`, allowing us to create balances (baskets of currencies) with queries like `SELECT sum(amount) FROM POSTING`. Using this amount type as a foundation, we build other useful functions as described below.

## What Can I Do with This?

- Calculate the balance of an account:

```
SELECT
	account_change (account, daterange(NULL, '2022-12-31'))
FROM
	account
WHERE
	name = 'Assets:Account';
```

- Calculate the change in an account over a specific period:

```
SELECT
	account_change (account, daterange('2022-01-01', '2022-12-31'))
FROM
	account
WHERE
	name = 'Income:Salary';
```

- Calculate the balance or change in an account and its sub-accounts:

```
SELECT
	account_hierarchy_change (account_hierarchy, daterange(NULL, '2022-12-31'))
FROM
	account_hierarchy
WHERE
	name = 'Assets';
```

- Check if a balance (assertion) is balanced:

```
SELECT
	assertion.*,
	assertion_is_balanced (assertion)
FROM
	assertion;
```

- Convert an amount to another currency:

```
SELECT
	market_price ((1, 'USD'), 'JPY', '2024-01-01')
```

- Convert a balance (basket of currencies) to another currency:

```
SELECT
	market_price (ARRAY[(1, 'USD')::amount, (1, 'EUR')::amount], 'JPY', '2024-01-01')
```

- Convert the balance of an account or account hierarchy into a single currency:

```
SELECT
	market_price (account_hierarchy_change (account_hierarchy, daterange(NULL, '2022-12-31')), 'USD', '2022-12-31')
FROM
	account_hierarchy
WHERE
	name = 'Assets';
```

- Show the running balance of an account by posting:

```
SELECT
	posting.*,
	posting_balance (posting)
FROM
	posting;
```

- Calculate if a transaction is balanced and show its balance:

```
SELECT
	transaction.*,
	transaction_balance (transaction),
	transaction_tolerance (transaction),
	transaction_is_balanced (transaction)
FROM
	transaction;
```

- Calculate cost basis

```
SELECT
	inventory (posting.*) AS none,
	cost_basis (posting.*) AS strict,
	cost_basis_avg (posting.*) AS avg,
	cost_basis_fifo (posting.*) AS fifo,
	cost_basis_lifo (posting.*) AS lifo
FROM
	posting;
```

## What's Missing?

Although beanpost is fairly comprehensive, some features are currently missing:

- _Some beancount data types are not imported_: While the common directives are supported, some more obscure feature aren't. These could likely be added easily.
  1. `Notes` and `Events` directives
  2. Flags on postings
- _Validation_: should be straightforward to add most of these.
  1.  Check for transactions occurring after an account has been closed
  2.  Check that transactions match with specified account currencies
  3.  Check that inventory reductions have the same currency as the augmentation (lot) they are reducing from
  4.  Check that inventory reductions don't reduce lot amounts below zero
  5.  For strict cost-basis, all reductions should have matching augmentation lots
- _Plugins_
- _Importing statements_: This might be out of scope for this project. Since the data is stored in a PostgreSQL database, any client that can insert data into the database could be written in any language.

## What is Different from beancount?

- _Transaction dates_: Each posting can have its own date, allowing transactions to balance even if individual postings have different dates. This helps with common issues when transferring money between accounts where withdrawal and deposit dates differ.
- _Pad directives_: Converted to regular Transaction directives with a fixed amount instead of "padded" adjustable amounts.
- _Tolerances_: Decimal places for commodities are defined explicitly in the commodity table decimal_places column, not derived automatically like in beancount. Tolerances are calculated as if the option `infer_tolerance_from_cost` is true.
- _Documents_: Stored as byte data inside the database, with support for import and export.
- _Balance directive name_: Beancount `Balance` directives are stored in the assertion table for clarity.
- _Lot matching_: The logic for matching lots for cost basis has not been tested thoroughly and may not match lots in the exact same way as beancount does.

## Conclusions

Implementing most of beancount's core functionality with PostgreSQL was surprisingly straightforward. While some features are missing, adding them shouldn't be a major challenge. The main advantage of PostgreSQL is the ability to easily query and manipulate data, which can sometimes be difficult with simple text files. However, simple text files have the benefit of being more accessible and user-friendly, a front-end will be required to make this a truely useful project.

I have tested this with a personal beancount file containing about 10,000 entries, spanning four years, with transactions in multiple currencies and various accounts. So far, I haven't found any discrepancies between the original beancount file and the exported data from beanpost. I'd love to hear about your experiences with beanpost—please drop me a line!
