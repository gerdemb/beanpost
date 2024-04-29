--
-- PostgreSQL database dump
--

-- Dumped from database version 16.2 (Postgres.app)
-- Dumped by pg_dump version 16.2 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: amount; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.amount AS (
	number numeric,
	currency text
);


--
-- Name: lot; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.lot AS (
	id integer,
	amount public.amount,
	cost public.amount,
	date date,
	label text
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account (
    id integer NOT NULL,
    name text NOT NULL,
    open_date date NOT NULL,
    close_date date,
    currencies text[],
    meta json DEFAULT '{}'::json NOT NULL
);


--
-- Name: TABLE account; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.account IS 'Combines beancount open and close directives';


--
-- Name: account_change(public.account, daterange); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.account_change(account public.account, range daterange) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	sum(amount)
FROM
	posting
WHERE
	account_id = account.id
	AND RANGE @> date;
$$;


--
-- Name: FUNCTION account_change(account public.account, range daterange); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.account_change(account public.account, range daterange) IS 'Calculates the total amount of postings for a given account within a specified date range';


--
-- Name: depth(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.depth(a text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT length(a) - length(replace(a, ':', ''))
$$;


--
-- Name: FUNCTION depth(a text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.depth(a text) IS 'Find depth of an account name by counting colons';


--
-- Name: reduce_depth(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reduce_depth(s text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT array_to_string(trim_array(string_to_array(s, ':'), 1),':')
$$;


--
-- Name: FUNCTION reduce_depth(s text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reduce_depth(s text) IS 'Reduce depth of an account name by dropping last part of hierarchy';


--
-- Name: account_hierarchy; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.account_hierarchy AS
 WITH RECURSIVE names AS (
         SELECT account.name,
            public.depth(account.name) AS depth
           FROM public.account
        UNION ALL
         SELECT public.reduce_depth(names_1.name) AS name,
            public.depth(names_1.name) AS depth
           FROM names names_1
          WHERE (public.depth(names_1.name) > 0)
        )
 SELECT DISTINCT name,
    depth
   FROM names
  ORDER BY name;


--
-- Name: VIEW account_hierarchy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.account_hierarchy IS 'Returns all hierarchial account names and their depth level';


--
-- Name: account_hierarchy_change(public.account_hierarchy, daterange); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.account_hierarchy_change(account_hierarchy public.account_hierarchy, range daterange) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	sum(amount)
FROM
	posting
	JOIN account ON account.id = posting.account_id
WHERE
	account.name LIKE account_hierarchy.name || ':%'
	AND RANGE @> posting.date;
$$;


--
-- Name: FUNCTION account_hierarchy_change(account_hierarchy public.account_hierarchy, range daterange); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.account_hierarchy_change(account_hierarchy public.account_hierarchy, range daterange) IS 'Calculates the total amount of postings for a given account hierarchy within a specified date range';


--
-- Name: assertion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assertion (
    id integer NOT NULL,
    date date NOT NULL,
    account_id integer NOT NULL,
    amount public.amount NOT NULL
);


--
-- Name: TABLE assertion; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.assertion IS 'Beancount balance directive';


--
-- Name: assertion_is_balanced(public.assertion); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assertion_is_balanced(a public.assertion) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
	balance_contains_amount (a.amount, posting_balance (posting.*))
FROM
	posting
WHERE
	posting.account_id = a.account_id
	AND posting.date < a.date
ORDER BY
	date DESC,
	id DESC
LIMIT 1
$$;


--
-- Name: FUNCTION assertion_is_balanced(a public.assertion); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.assertion_is_balanced(a public.assertion) IS 'Checks if a balance directive (assertion) is balanced';


--
-- Name: balance_contains_amount(public.amount, public.amount[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.balance_contains_amount(amount public.amount, balances public.amount[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM unnest(balances) as bal
        WHERE bal.currency = amount.currency AND bal.number = amount.number
    )
$$;


--
-- Name: FUNCTION balance_contains_amount(amount public.amount, balances public.amount[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.balance_contains_amount(amount public.amount, balances public.amount[]) IS 'Given a single amount, assert that the same amount exists in the array of balances. Used to check balance assertions.';


--
-- Name: convert_currency(public.amount, public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.convert_currency(base public.amount, quote public.amount) RETURNS public.amount
    LANGUAGE plpgsql
    AS $$
DECLARE converted_amount public.amount;

BEGIN
	IF quote IS NULL THEN
		RETURN base;

END IF;

-- Convert the currency
converted_amount.number := base.number * quote.number;

converted_amount.currency := quote.currency;

RETURN converted_amount;

END;
$$;


--
-- Name: FUNCTION convert_currency(base public.amount, quote public.amount); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.convert_currency(base public.amount, quote public.amount) IS 'Converts base currency to quote currency given the quote value';


--
-- Name: posting; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posting (
    id integer NOT NULL,
    date date NOT NULL,
    account_id integer NOT NULL,
    transaction_id integer NOT NULL,
    flag character(1),
    amount public.amount NOT NULL,
    price public.amount,
    cost public.amount,
    cost_date date,
    cost_label text,
    matching_lot_id integer
);


--
-- Name: TABLE posting; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.posting IS 'Transaction posting';


--
-- Name: cost_basis(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
	WITH augmentation AS (
		SELECT
			posting.id,
			posting.amount,
			posting.cost,
			posting.cost_date,
			posting.cost_label,
			(sum(matching_lot.amount))[1] AS reduction --matching_lost must have same currency
		FROM
			unnest(postings) AS posting
		LEFT JOIN unnest(postings) AS matching_lot ON matching_lot.matching_lot_id = posting.id
	WHERE (posting.amount).number > 0
	AND posting.cost IS NOT NULL
GROUP BY
	posting.id,
	posting.amount,
	posting.cost,
	posting.cost_date,
	posting.cost_label
)
SELECT
	array_agg(ROW(augmentation.id, ((augmentation.amount).number + coalesce((augmentation.reduction).number, 0), (augmentation.amount).currency)::amount, augmentation.cost, augmentation.cost_date, augmentation.cost_label)::lot)
FROM
	augmentation
$$;


--
-- Name: FUNCTION cost_basis(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.cost_basis(postings public.posting[]) IS 'Calculates the cost basis by matching lots';


--
-- Name: cost_basis_avg(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_avg(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
	WITH summed AS (
		-- Sum the total cost and total amount
		SELECT
			sum((posting.cost).number * (posting.amount).number) AS total_cost,
			sum((posting.amount).number) AS total_amount,
			min((posting.amount).currency) AS currency
		FROM
			unnest(postings) AS posting
		WHERE
			posting.cost IS NOT NULL
		GROUP BY
			(posting.amount).currency
)
	SELECT
		array_agg(ROW (NULL::integer, -- Corresponds to the id in the lot
				(total_amount, currency)::amount, -- Total amount
				(total_cost / total_amount, currency)::amount, -- Average cost
				NULL::date, -- Corresponds to `cost_date`
				NULL::text)::lot) -- Corresponds to `cost_label`
	FROM
		summed
$$;


--
-- Name: FUNCTION cost_basis_avg(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.cost_basis_avg(postings public.posting[]) IS 'Calculates the average cost basis';


--
-- Name: cost_basis_fifo(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_fifo(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
SELECT cost_basis_lifo_fifo(postings, FALSE)
$$;


--
-- Name: FUNCTION cost_basis_fifo(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.cost_basis_fifo(postings public.posting[]) IS 'Calculates the cost basis by matching lots using FIFO';


--
-- Name: cost_basis_lifo(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_lifo(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
SELECT cost_basis_lifo_fifo(postings, true)
$$;


--
-- Name: FUNCTION cost_basis_lifo(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.cost_basis_lifo(postings public.posting[]) IS 'Calculates the cost basis by matching lots using LIFO';


--
-- Name: cost_basis_lifo_fifo(public.posting[], boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_lifo_fifo(postings public.posting[], is_lifo boolean) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
-- Determine the correct ordering based on is_lifo parameter
WITH reduction AS (
    SELECT
        (amount).currency AS currency,
        sum((amount).number) AS number
    FROM
        unnest(postings) AS posting
    WHERE
        (amount).number < 0
        AND posting.cost IS NOT NULL
    GROUP BY
        (amount).currency
),
adjusted_postings AS (
    SELECT
        posting.*,
        reduction.*,
        -- Dynamic order direction based on is_lifo parameter
        (sum((amount).number) OVER (
            PARTITION BY (posting.amount).currency 
            ORDER BY CASE WHEN is_lifo THEN date END desc,
            CASE WHEN not is_lifo THEN date END asc
        )) + coalesce(reduction.number, 0) AS adjusted_amount
    FROM
        unnest(postings) AS posting
    LEFT JOIN reduction ON reduction.currency = (posting.amount).currency
    WHERE
        posting.cost IS NOT NULL
        AND (posting.amount).number > 0
)
SELECT
    array_agg(
        ROW (
            id,
            (least((adjusted_postings.amount).number, adjusted_amount), (adjusted_postings.amount).currency)::amount,
            cost,
            cost_date,
            cost_label
        )::lot
    )
FROM
    adjusted_postings
WHERE
    adjusted_amount > 0
$$;


--
-- Name: FUNCTION cost_basis_lifo_fifo(postings public.posting[], is_lifo boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.cost_basis_lifo_fifo(postings public.posting[], is_lifo boolean) IS 'A generic function for calculating the cost basis using either FIFO or LIFO';


--
-- Name: inventory(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.inventory(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
SELECT
    ARRAY_AGG(
        ROW(
            posting.id,
            posting.amount,
            posting.cost,
            posting.cost_date,
            posting.cost_label
        )::lot  -- Convert the row to a `lot` type
    )
FROM
    UNNEST(postings) AS posting  -- Unnest the postings array
WHERE
    posting.cost IS NOT NULL;  -- Filter rows with non-null cost
$$;


--
-- Name: FUNCTION inventory(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.inventory(postings public.posting[]) IS 'Create an inventory (lot[]) for a list of postings';


--
-- Name: is_balance_in_tolerance(public.amount[], public.amount[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_balance_in_tolerance(balances public.amount[], tolerances public.amount[]) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
	IF array_length(balances,
		1) != 1 OR array_length(tolerances, 1) != 1 THEN
		RETURN FALSE;

END IF;

IF balances[1].currency != tolerances[1].currency THEN
	RETURN FALSE;

END IF;

RETURN abs(balances[1].number) < tolerances[1].number;

END;
$$;


--
-- Name: FUNCTION is_balance_in_tolerance(balances public.amount[], tolerances public.amount[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_balance_in_tolerance(balances public.amount[], tolerances public.amount[]) IS 'Given an array of balances and tolerances assert that there is only a single amount and that it''s value is within the tolerance.';


--
-- Name: market_price(public.amount[], text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.market_price(balance public.amount[], into_currency text, for_date date) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE total amount[];

i int = 0;

BEGIN
	IF balance IS NULL OR array_length(balance, 1) IS NULL THEN
		RETURN NULL;

END IF;

FOR i IN 1..array_length(balance, 1)
LOOP
	total := sum(total, market_price (balance[i], into_currency, for_date));

END LOOP;

RETURN total;

END;
$$;


--
-- Name: FUNCTION market_price(balance public.amount[], into_currency text, for_date date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.market_price(balance public.amount[], into_currency text, for_date date) IS 'Convert a balance into a currency for a given date';


--
-- Name: market_price(public.amount, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.market_price(convert_amount public.amount, into_currency text, for_date date) RETURNS public.amount
    LANGUAGE plpgsql
    AS $$
DECLARE quote amount;

BEGIN
	SELECT
		(amount).number,
		(amount).currency INTO quote
	FROM
		price_inverted
	WHERE
		currency = (convert_amount).currency
		AND (amount).currency = into_currency
		AND date <= for_date
	ORDER BY
		date DESC
	LIMIT 1;

RETURN convert_currency (convert_amount, quote);

END;
$$;


--
-- Name: FUNCTION market_price(convert_amount public.amount, into_currency text, for_date date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.market_price(convert_amount public.amount, into_currency text, for_date date) IS 'Convert a amount into a currency for a given date';


--
-- Name: max(public.amount[], public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.max(state public.amount[], current public.amount) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE found boolean = FALSE;

i int = 0;

BEGIN
	IF state IS NULL OR array_length(state, 1) IS NULL THEN
		RETURN ARRAY[CURRENT];

END IF;

FOR i IN 1..array_length(state, 1)
LOOP
	IF state[i].currency = current.currency THEN
		state[i].number := greatest (state[i].number, current.number);

found := TRUE;

EXIT;

END IF;

END LOOP;

IF NOT found THEN
	state := array_append(state, CURRENT);

END IF;

RETURN state;

END;
$$;


--
-- Name: FUNCTION max(state public.amount[], current public.amount); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.max(state public.amount[], current public.amount) IS 'Aggregate function to find max balance of amounts. Used for calculating the max tolerance.';


--
-- Name: posting_balance(public.posting); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.posting_balance(p public.posting) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	sum(amount)
FROM
	posting
WHERE
	posting.account_id = p.account_id
	AND posting.date <= p.date
	AND posting.id <= p.id
$$;


--
-- Name: FUNCTION posting_balance(p public.posting); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.posting_balance(p public.posting) IS 'Calculate running balance for posting';


--
-- Name: sum(public.amount[], public.amount[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(state public.amount[], current public.amount[]) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE new_state amount[] := state;

i int := 0;

BEGIN
	IF array_length(CURRENT,
		1) IS NULL THEN
		RETURN new_state;

END IF;

FOR i IN 1..array_length(CURRENT, 1)
LOOP
	-- Assuming you want to append each element of current to new_state
	new_state := sum(new_state, CURRENT[i]);

END LOOP;

RETURN new_state;

END;
$$;


--
-- Name: FUNCTION sum(state public.amount[], current public.amount[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sum(state public.amount[], current public.amount[]) IS 'Aggregate sum of balances (amount[])';


--
-- Name: sum(public.amount[], public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(state public.amount[], current public.amount) RETURNS public.amount[]
    LANGUAGE sql
    AS $$
	SELECT
		ARRAY (
			SELECT
				(sum(combined.number),
					combined.currency)::public.amount
			FROM (
				SELECT
					number,
					currency
				FROM
					unnest(state)
				UNION ALL
				SELECT
					current.number,
					current.currency) AS combined
			GROUP BY
				currency
			ORDER BY
				currency)
$$;


--
-- Name: FUNCTION sum(state public.amount[], current public.amount); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sum(state public.amount[], current public.amount) IS 'Aggregate sum of amount';


--
-- Name: sum(public.amount[], public.posting); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(state public.amount[], current public.posting) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE
	converted_amount amount;
BEGIN
	-- Loop through each posting to compute the total amount and max_tolerance
	-- Convert currency if there's a price or cost
	IF current.cost IS NOT NULL THEN
		converted_amount := convert_currency (current.amount, current.cost);
	ELSIF current.price IS NOT NULL THEN
		converted_amount := convert_currency (current.amount, current.price);
	ELSE
		converted_amount := current.amount;
	END IF;
	RETURN sum(state, converted_amount);
END;
$$;


--
-- Name: FUNCTION sum(state public.amount[], current public.posting); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.sum(state public.amount[], current public.posting) IS 'Aggregate sum of postings accounting for cost and price';


--
-- Name: tolerance(public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tolerance(base public.amount) RETURNS public.amount
    LANGUAGE plpgsql
    AS $$
DECLARE tolerance decimal;

BEGIN
	SELECT
		power(10,
			- decimal_places) / 2 INTO tolerance
	FROM
		commodity
	WHERE
		commodity.currency = base.currency;

RETURN (coalesce(tolerance, 0),
	base.currency)::amount;

END;
$$;


--
-- Name: FUNCTION tolerance(base public.amount); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.tolerance(base public.amount) IS 'Calculate tolerance for an amount';


--
-- Name: tolerance(public.amount[], public.posting); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tolerance(state public.amount[], current public.posting) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE
	tolerance amount;
BEGIN
	-- Loop through each posting to compute the total amount and max_tolerance
	-- Convert currency if there's a price or cost
	IF current.cost IS NOT NULL THEN
		tolerance := tolerance (current.amount, current.cost);
	ELSIF current.price IS NOT NULL THEN
		tolerance := tolerance (current.price);
	ELSE
		tolerance := tolerance (current.amount);
	END IF;
	RETURN max(state, tolerance);
END;
$$;


--
-- Name: FUNCTION tolerance(state public.amount[], current public.posting); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.tolerance(state public.amount[], current public.posting) IS 'Aggregate tolerance for a list postings';


--
-- Name: tolerance(public.amount, public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tolerance(base public.amount, quote public.amount) RETURNS public.amount
    LANGUAGE plpgsql
    AS $$
DECLARE tolerance decimal;

BEGIN
	SELECT
		power(10,
			- decimal_places) INTO tolerance
	FROM
		commodity
	WHERE
		commodity.currency = base.currency;

RETURN (tolerance * quote.number,
	quote.currency)::amount;

END;
$$;


--
-- Name: FUNCTION tolerance(base public.amount, quote public.amount); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.tolerance(base public.amount, quote public.amount) IS 'Calculate tolerance for a cost';


--
-- Name: transaction; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transaction (
    id integer NOT NULL,
    flag character(1) NOT NULL,
    payee text NOT NULL,
    narration text NOT NULL,
    tags text NOT NULL,
    links text NOT NULL
);


--
-- Name: TABLE transaction; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.transaction IS 'Beancount transaction directive';


--
-- Name: transaction_balance(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_balance(t public.transaction) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	sum(posting.*)
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


--
-- Name: FUNCTION transaction_balance(t public.transaction); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.transaction_balance(t public.transaction) IS 'Calculate balance of a transaction';


--
-- Name: transaction_is_balanced(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_is_balanced(t public.transaction) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
	is_balance_in_tolerance (sum(posting.*), tolerance (posting.*))
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


--
-- Name: FUNCTION transaction_is_balanced(t public.transaction); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.transaction_is_balanced(t public.transaction) IS 'Calculate if a transaction is balanced';


--
-- Name: transaction_tolerance(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_tolerance(t public.transaction) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	tolerance (posting.*)
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


--
-- Name: FUNCTION transaction_tolerance(t public.transaction); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.transaction_tolerance(t public.transaction) IS 'Calculate tolerance for a transaction';


--
-- Name: cost_basis(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.cost_basis(public.posting) (
    SFUNC = array_append,
    STYPE = public.posting[],
    INITCOND = '{}',
    FINALFUNC = public.cost_basis
);


--
-- Name: cost_basis_avg(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.cost_basis_avg(public.posting) (
    SFUNC = array_append,
    STYPE = public.posting[],
    INITCOND = '{}',
    FINALFUNC = public.cost_basis_avg
);


--
-- Name: cost_basis_fifo(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.cost_basis_fifo(public.posting) (
    SFUNC = array_append,
    STYPE = public.posting[],
    INITCOND = '{}',
    FINALFUNC = public.cost_basis_fifo
);


--
-- Name: cost_basis_lifo(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.cost_basis_lifo(public.posting) (
    SFUNC = array_append,
    STYPE = public.posting[],
    INITCOND = '{}',
    FINALFUNC = public.cost_basis_lifo
);


--
-- Name: inventory(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.inventory(public.posting) (
    SFUNC = array_append,
    STYPE = public.posting[],
    INITCOND = '{}',
    FINALFUNC = public.inventory
);


--
-- Name: sum(public.amount[]); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.sum(public.amount[]) (
    SFUNC = public.sum,
    STYPE = public.amount[],
    INITCOND = '{}'
);


--
-- Name: sum(public.amount); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.sum(public.amount) (
    SFUNC = public.sum,
    STYPE = public.amount[],
    INITCOND = '{}'
);


--
-- Name: sum(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.sum(public.posting) (
    SFUNC = public.sum,
    STYPE = public.amount[],
    INITCOND = '{}'
);


--
-- Name: tolerance(public.posting); Type: AGGREGATE; Schema: public; Owner: -
--

CREATE AGGREGATE public.tolerance(public.posting) (
    SFUNC = public.tolerance,
    STYPE = public.amount[],
    INITCOND = '{}'
);


--
-- Name: account_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.account ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.account_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: balance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.assertion ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.balance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: commodity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commodity (
    id integer NOT NULL,
    date date NOT NULL,
    currency text NOT NULL,
    meta json DEFAULT '{}'::json NOT NULL,
    decimal_places integer NOT NULL,
    CONSTRAINT commodity_currency_check CHECK ((currency <> ''::text))
);


--
-- Name: TABLE commodity; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.commodity IS 'Beancount commodity directive';


--
-- Name: commodity_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.commodity ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.commodity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: document; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document (
    id integer NOT NULL,
    date date NOT NULL,
    account_id integer NOT NULL,
    data bytea NOT NULL,
    filename text NOT NULL
);


--
-- Name: TABLE document; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.document IS 'Binary document data';


--
-- Name: document_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.document ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.document_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: posting_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.posting ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.posting_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.price (
    id integer NOT NULL,
    date date NOT NULL,
    currency text NOT NULL,
    amount public.amount NOT NULL
);


--
-- Name: TABLE price; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.price IS 'Beancount price directive';


--
-- Name: price_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.price ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.price_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: price_inverted; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.price_inverted AS
 SELECT price.date,
    price.currency,
    price.amount
   FROM public.price
UNION ALL
 SELECT price.date,
    (price.amount).currency AS currency,
    ROW(((1)::numeric / (price.amount).number), price.currency)::public.amount AS amount
   FROM public.price;


--
-- Name: VIEW price_inverted; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.price_inverted IS 'price directive with inverted prices';


--
-- Name: transaction_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.transaction ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.transaction_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: account account_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_name_key UNIQUE (name);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: assertion balance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assertion
    ADD CONSTRAINT balance_pkey PRIMARY KEY (id);


--
-- Name: commodity commodity_currency_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commodity
    ADD CONSTRAINT commodity_currency_key UNIQUE (currency);


--
-- Name: commodity commodity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commodity
    ADD CONSTRAINT commodity_pkey PRIMARY KEY (id);


--
-- Name: document document_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document
    ADD CONSTRAINT document_pkey PRIMARY KEY (id);


--
-- Name: posting posting_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting
    ADD CONSTRAINT posting_pkey PRIMARY KEY (id);


--
-- Name: price price_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.price
    ADD CONSTRAINT price_pkey PRIMARY KEY (id);


--
-- Name: transaction transaction_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaction
    ADD CONSTRAINT transaction_pkey PRIMARY KEY (id);


--
-- Name: posting_account_id_date_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posting_account_id_date_id_idx ON public.posting USING btree (account_id, date, id);


--
-- Name: posting_transaction_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX posting_transaction_id_idx ON public.posting USING btree (transaction_id);


--
-- Name: assertion balance_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assertion
    ADD CONSTRAINT balance_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.account(id);


--
-- Name: document document_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document
    ADD CONSTRAINT document_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.account(id);


--
-- Name: posting posting_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting
    ADD CONSTRAINT posting_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.account(id);


--
-- Name: posting posting_matching_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting
    ADD CONSTRAINT posting_matching_lot_id_fkey FOREIGN KEY (matching_lot_id) REFERENCES public.posting(id);


--
-- Name: posting posting_transaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting
    ADD CONSTRAINT posting_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.transaction(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

