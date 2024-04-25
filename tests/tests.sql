


SELECT
	account_change (account, daterange(NULL, '2022-12-31'))
FROM
	account
WHERE
	name = 'Assets:Account';
	
SELECT
	account_change (account, daterange('2022-01-01', '2022-12-31'))
FROM
	account
WHERE
	name = 'Assets:Account';
	
SELECT
	account_hierarchy_change (account_hierarchy, daterange(NULL, '2022-12-31'))
FROM
	account_hierarchy
WHERE
	name = 'Assets';


SELECT
	assertion.*,
	assertion_is_balanced (assertion)
FROM
	assertion;
	
SELECT
	market_price ((1, 'USD'), 'JPY', '2024-01-01');
	
SELECT
	market_price (ARRAY[(1, 'USD')::amount, (1, 'EUR')::amount], 'JPY', '2024-01-01');
	
SELECT
	market_price (account_hierarchy_change (account_hierarchy, daterange(NULL, '2022-12-31')), 'USD', '2024-01-01')
FROM
	account_hierarchy
WHERE
	name = 'Assets';
	
SELECT
	posting.*,
	posting_balance (posting)
FROM
	posting;
	
SELECT
	transaction.*,
	transaction_tolerance (TRANSACTION),
	transaction_balance (TRANSACTION),
	transaction_is_balanced (TRANSACTION)
FROM
	TRANSACTION;
	
SELECT
	inventory (posting.*) AS none,
	cost_basis (posting.*) AS strict,
	cost_basis_avg (posting.*) AS avg,
	cost_basis_fifo (posting.*) AS fifo,
	cost_basis_lifo (posting.*) AS lifo
FROM
	posting;
