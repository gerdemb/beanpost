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
-- Name: count_colon(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_colon(a text) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
	RETURN (length(a) - length(replace(a, ':', '')));

END;
$$;


--
-- Name: trim_colon(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trim_colon(s text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$

DECLARE

    parts text[];

    trim text[];

BEGIN

    parts := string_to_array(s, ':'); -- Split the input string by ':'

    trim := trim_array(parts, 1);

    RETURN array_to_string(trim,':');

END;

$$;


--
-- Name: account_hierarchy; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.account_hierarchy AS
 WITH RECURSIVE names AS (
         SELECT account.name,
            public.count_colon(account.name) AS depth
           FROM public.account
        UNION ALL
         SELECT public.trim_colon(names_1.name) AS name,
            public.count_colon(names_1.name) AS depth
           FROM names names_1
          WHERE (public.count_colon(names_1.name) > 0)
        )
 SELECT DISTINCT name,
    depth
   FROM names
  ORDER BY name;


--
-- Name: VIEW account_hierarchy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.account_hierarchy IS '@primaryKey name';


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
-- Name: assertion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assertion (
    id integer NOT NULL,
    date date NOT NULL,
    account_id integer NOT NULL,
    amount public.amount NOT NULL
);


--
-- Name: assertion_is_balanced(public.assertion); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assertion_is_balanced(a public.assertion) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
	is_balanced (a.amount, posting_balance (posting.*))
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

COMMENT ON FUNCTION public.assertion_is_balanced(a public.assertion) IS '@nonNull';


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
-- Name: cost_basis_fifo(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_fifo(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
SELECT cost_basis_lifo_fifo(postings, FALSE)
$$;


--
-- Name: cost_basis_lifo(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cost_basis_lifo(postings public.posting[]) RETURNS public.lot[]
    LANGUAGE sql
    AS $$
SELECT cost_basis_lifo_fifo(postings, true)
$$;


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
-- Name: is_balanced(public.amount[], public.amount[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_balanced(balances public.amount[], tolerances public.amount[]) RETURNS boolean
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
-- Name: FUNCTION is_balanced(balances public.amount[], tolerances public.amount[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_balanced(balances public.amount[], tolerances public.amount[]) IS 'Given an array of balances and tolerances assert that there is only a single amount and that it''s value is within the tolerance.';


--
-- Name: is_balanced(public.amount, public.amount[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_balanced(amount public.amount, balances public.amount[]) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
	IF balances IS NULL OR array_length(balances, 1) IS NULL THEN
		RETURN FALSE;

END IF;

FOR i IN 1..array_length(balances, 1)
LOOP
	IF balances[i].currency = amount.currency THEN
		RETURN balances[i].number = amount.number;

END IF;

END LOOP;

RETURN FALSE;

END;
$$;


--
-- Name: FUNCTION is_balanced(amount public.amount, balances public.amount[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_balanced(amount public.amount, balances public.amount[]) IS 'Given a single amount assert that the same amount exists in the array of balances. Used to check balance assertions.';


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
-- Name: sum(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(postings public.posting[]) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE total_amount amount[];

converted_amount amount;

p posting;

BEGIN
	-- Loop through each posting to compute the total amount and max_tolerance
	FOREACH p IN ARRAY postings LOOP
		-- Convert currency if there's a price or cost
		IF p.cost IS NOT NULL THEN
			converted_amount := convert_currency (p.amount, p.cost);

ELSIF p.price IS NOT NULL THEN
	converted_amount := convert_currency (p.amount, p.price);

ELSE
	converted_amount := p.amount;

END IF;

total_amount := sum(total_amount, converted_amount);

END LOOP;

RETURN total_amount;

END;
$$;


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
-- Name: sum(public.amount[], public.amount); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(state public.amount[], current public.amount) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE
	i int;
BEGIN
	IF CURRENT IS NULL THEN
		RETURN state;
	END IF;
	FOR i IN 1..coalesce(array_length(state, 1), 0)
	LOOP
		IF state[i].currency = current.currency THEN
			state[i].number := state[i].number + current.number;
			RETURN state;
		END IF;
	END LOOP;
	RETURN array_append(state, CURRENT);
END;
$$;


--
-- Name: sum(public.lot[], public.posting); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum(state public.lot[], current public.posting) RETURNS public.lot[]
    LANGUAGE plpgsql
    AS $$
DECLARE
	-- Temporary variable to hold the lot constructed from the current posting.
	new_lot lot;
	i int = 0;
BEGIN
	-- Constructing a new lot type from current posting.
	new_lot := (current.id,
		current.amount,
		current.cost,
		current.cost_date,
		current.cost_label,
		current.matching_lot_id);
	-- Check if the state is NULL (first call) and initialize if necessary.
	IF array_length(state, 1) IS NULL THEN
		RETURN array_append(state, new_lot);
	END IF;
	-- If there is a cost, append the new lot to the state array.
	IF current.cost IS NOT NULL THEN
		RETURN array_append(state, new_lot);
	END IF;
	-- Treat as an amount without cost, attempt to merge with existing lots.
	FOR i IN 1..array_length(state, 1)
	LOOP
		IF (state[i].amount).currency = (current.amount).currency AND state[i].
	COST IS NULL THEN
			state[i].amount.number := (state[i].amount).number + (current.amount).number;
			RETURN state;
		END IF;
	END LOOP;
	RETURN array_append(state, new_lot);
END;
$$;


--
-- Name: tolerance(public.posting[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tolerance(postings public.posting[]) RETURNS public.amount[]
    LANGUAGE plpgsql
    AS $$
DECLARE max_tolerance amount[];

temp_tolerance amount;

p posting;

BEGIN
	-- Loop through each posting to compute the total amount and max_tolerance
	FOREACH p IN ARRAY postings LOOP
		-- Convert currency if there's a price or cost
		IF p.cost IS NOT NULL THEN
			temp_tolerance := tolerance (p.amount, p.cost);

ELSIF p.price IS NOT NULL THEN
	temp_tolerance := tolerance (p.price);

ELSE
	temp_tolerance := tolerance (p.amount);

END IF;

IF max_tolerance IS NULL THEN
	max_tolerance := ARRAY[temp_tolerance];

ELSE
	max_tolerance := max(max_tolerance, temp_tolerance);

END IF;

END LOOP;

RETURN max_tolerance;

END;
$$;


--
-- Name: FUNCTION tolerance(postings public.posting[]); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.tolerance(postings public.posting[]) IS 'Calculate tolerance from a list of postings';


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

RETURN (tolerance,
	base.currency)::amount;

END;
$$;


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
-- Name: transaction_balance(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_balance(t public.transaction) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	sum(array_agg(posting.*))
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


--
-- Name: transaction_is_balanced(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_is_balanced(t public.transaction) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
	is_balanced (sum(array_agg(posting.*)), tolerance (array_agg(posting.*)))
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


--
-- Name: transaction_tolerance(public.transaction); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transaction_tolerance(t public.transaction) RETURNS public.amount[]
    LANGUAGE sql STABLE
    AS $$
SELECT
	tolerance (array_agg(posting.*))
FROM
	posting
WHERE
	posting.transaction_id = t.id
$$;


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
    STYPE = public.lot[],
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

