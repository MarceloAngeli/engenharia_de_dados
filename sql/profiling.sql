-- ============================================================================
-- profiling.sql  -  profile and clean the raw NorthMart / Olist files (DuckDB)
--
-- Replaces: validate_customers_dataset.py, validate_database.py,
--           validate_geolocation_dataset.py, validate_json.py,
--           validate_order_items_dataset.py, validate_payment.py,
--           validate_products.py, validate_sellers.py
--
-- Run from the src folder (paths below are relative to it):
--     cd src
--     duckdb -bail olist.duckdb < profiling.sql
--
-- Every SELECT prints a result. An empty result means "nothing found".
-- The script also builds the cleaned tables that build_model.sql needs:
--     products, sellers_clean, orders_clean, order_delivery_dates
-- so profiling.sql must run BEFORE build_model.sql.
-- ============================================================================


-- ============================================================================
-- STEP 0 - LOAD THE RAW FILES (each file is loaded once)
-- ============================================================================
SELECT '=== STEP 0 - LOAD RAW FILES ===' AS section;

CREATE OR REPLACE TABLE orders_raw AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_orders_dataset.csv', header = true);

CREATE OR REPLACE TABLE order_items AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_order_items_dataset.csv', header = true);

CREATE OR REPLACE TABLE customers AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_customers_dataset.csv', header = true);

CREATE OR REPLACE TABLE order_payments AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_order_payments_dataset.csv', header = true);

CREATE OR REPLACE TABLE olist_sellers AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_sellers_dataset.csv', header = true);

-- raw_products stays untouched; "products" (below) receives the cleaning.
CREATE OR REPLACE TABLE raw_products AS
SELECT * FROM read_csv_auto('../architecture/data/source/olist_products_dataset.csv', header = true);

-- The zip prefix stays VARCHAR to keep leading zeros.
CREATE OR REPLACE TABLE geo AS
SELECT *, row_number() OVER () AS row_id
FROM read_csv('../architecture/data/source/olist_geolocation_dataset.csv',
              header = true,
              types = {'geolocation_zip_code_prefix': 'VARCHAR'});

-- JSON array: one row per object.
CREATE OR REPLACE TABLE sellers_raw AS
SELECT json
FROM read_json_objects('../architecture/data/source/json_northmart_seller_profiles.json',
                       format = 'array');

SELECT 'Row counts of the loaded raw files:' AS section;
SELECT 'orders_raw' AS table_name, COUNT(*) AS row_count FROM orders_raw
UNION ALL SELECT 'order_items',    COUNT(*) FROM order_items
UNION ALL SELECT 'customers',      COUNT(*) FROM customers
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'olist_sellers',  COUNT(*) FROM olist_sellers
UNION ALL SELECT 'raw_products',   COUNT(*) FROM raw_products
UNION ALL SELECT 'geo',            COUNT(*) FROM geo
UNION ALL SELECT 'sellers_raw (JSON)', COUNT(*) FROM sellers_raw;


-- ============================================================================
-- STEP 1 - CUSTOMERS: NULLs and duplicates
-- ============================================================================
SELECT '=== STEP 1 - CUSTOMERS: NULL COUNT PER COLUMN ===' AS section;

SELECT 'customer_id' AS column_name,
       COUNT(*) FILTER (WHERE customer_id IS NULL) AS null_count,
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_id IS NULL) / COUNT(*), 2) AS null_pct
FROM customers
UNION ALL
SELECT 'customer_unique_id',
       COUNT(*) FILTER (WHERE customer_unique_id IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_unique_id IS NULL) / COUNT(*), 2)
FROM customers
UNION ALL
SELECT 'customer_zip_code_prefix',
       COUNT(*) FILTER (WHERE customer_zip_code_prefix IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_zip_code_prefix IS NULL) / COUNT(*), 2)
FROM customers
UNION ALL
SELECT 'customer_city',
       COUNT(*) FILTER (WHERE customer_city IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_city IS NULL) / COUNT(*), 2)
FROM customers
UNION ALL
SELECT 'customer_state',
       COUNT(*) FILTER (WHERE customer_state IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_state IS NULL) / COUNT(*), 2)
FROM customers;

SELECT 'Customers: rows with at least one NULL:' AS section;
SELECT *
FROM customers
WHERE customer_id IS NULL
   OR customer_unique_id IS NULL
   OR customer_zip_code_prefix IS NULL
   OR customer_city IS NULL
   OR customer_state IS NULL;

SELECT 'Customers: fully duplicated rows:' AS section;
SELECT customer_id, customer_unique_id, customer_zip_code_prefix,
       customer_city, customer_state, COUNT(*) AS occurrences
FROM customers
GROUP BY customer_id, customer_unique_id, customer_zip_code_prefix,
         customer_city, customer_state
HAVING COUNT(*) > 1;

SELECT 'Customers: repeated customer_id (should be unique):' AS section;
SELECT customer_id, COUNT(*) AS occurrences
FROM customers
GROUP BY customer_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC;


-- ============================================================================
-- STEP 2 - ORDERS: key profile, then split the delivery dates
-- ============================================================================
SELECT '=== STEP 2 - ORDERS: KEY PROFILE ===' AS section;

SELECT COUNT(*)                                          AS total_rows,
       COUNT(DISTINCT order_id)                          AS distinct_order_id,
       COUNT(*) FILTER (WHERE order_id IS NULL)          AS null_order_id,
       COUNT(*) FILTER (WHERE customer_id IS NULL)       AS null_customer_id
FROM orders_raw;

-- Guard: stop here if order_id is not a valid key (NULLs or duplicates).
-- The new tables below are only built when this passes.
SELECT CASE
         WHEN COUNT(*) FILTER (WHERE order_id IS NULL) = 0
          AND COUNT(DISTINCT order_id) = COUNT(*)
         THEN 'order_id is a valid key: building orders_clean and order_delivery_dates'
         ELSE error('order_id is not a valid key (NULLs or duplicates found). '
                    || 'Fix this first. The new tables were NOT built.')
       END AS order_id_guard
FROM orders_raw;

-- delivery_id is a deterministic md5 of the order_id (32 hex characters),
-- the same style as order_id, product_id, etc.
CREATE OR REPLACE TABLE order_delivery_dates (
    delivery_id VARCHAR PRIMARY KEY,
    order_delivered_carrier_date TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

INSERT INTO order_delivery_dates
SELECT
    md5('delivery|' || order_id),
    TRY_CAST(order_delivered_carrier_date AS TIMESTAMP),
    TRY_CAST(order_delivered_customer_date AS TIMESTAMP),
    TRY_CAST(order_estimated_delivery_date AS TIMESTAMP)
FROM orders_raw;

CREATE OR REPLACE TABLE orders_clean (
    order_id VARCHAR PRIMARY KEY,
    customer_id VARCHAR,
    order_status VARCHAR,
    order_purchase_timestamp TIMESTAMP,
    order_approved_at TIMESTAMP,
    delivery_id VARCHAR
);

INSERT INTO orders_clean
SELECT
    order_id,
    customer_id,
    order_status,
    TRY_CAST(order_purchase_timestamp AS TIMESTAMP),
    TRY_CAST(order_approved_at AS TIMESTAMP),
    md5('delivery|' || order_id)
FROM orders_raw;

SELECT 'Verification of the new order tables:' AS section;
SELECT
    (SELECT COUNT(*) FROM orders_clean)          AS orders_clean_rows,
    (SELECT COUNT(*) FROM order_delivery_dates)  AS order_delivery_dates_rows,
    (SELECT COUNT(*)
       FROM orders_clean o
       LEFT JOIN order_delivery_dates d ON o.delivery_id = d.delivery_id
      WHERE d.delivery_id IS NULL)               AS orders_without_delivery_match,
    (SELECT COUNT(*) FROM order_delivery_dates
      WHERE LENGTH(delivery_id) <> 32)           AS delivery_id_not_32_chars;

SELECT 'NULLs per date column (NULL is expected for undelivered orders):' AS section;
SELECT
    COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL)  AS null_carrier,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS null_customer,
    COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) AS null_estimated
FROM order_delivery_dates;

SELECT 'Sample of order_delivery_dates:' AS section;
SELECT * FROM order_delivery_dates LIMIT 5;


-- ============================================================================
-- STEP 3 - ORDER ITEMS: NULL check
-- ============================================================================
SELECT '=== STEP 3 - ORDER_ITEMS: NULL COUNT PER COLUMN ===' AS section;

SELECT 'order_id' AS column_name,
       COUNT(*) FILTER (WHERE order_id IS NULL) AS null_count,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_id IS NULL) / COUNT(*), 2) AS null_pct
FROM order_items
UNION ALL
SELECT 'order_item_id',
       COUNT(*) FILTER (WHERE order_item_id IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_item_id IS NULL) / COUNT(*), 2)
FROM order_items
UNION ALL
SELECT 'product_id',
       COUNT(*) FILTER (WHERE product_id IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE product_id IS NULL) / COUNT(*), 2)
FROM order_items
UNION ALL
SELECT 'seller_id',
       COUNT(*) FILTER (WHERE seller_id IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE seller_id IS NULL) / COUNT(*), 2)
FROM order_items
UNION ALL
SELECT 'shipping_limit_date',
       COUNT(*) FILTER (WHERE shipping_limit_date IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE shipping_limit_date IS NULL) / COUNT(*), 2)
FROM order_items
UNION ALL
SELECT 'price',
       COUNT(*) FILTER (WHERE price IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE price IS NULL) / COUNT(*), 2)
FROM order_items
UNION ALL
SELECT 'freight_value',
       COUNT(*) FILTER (WHERE freight_value IS NULL),
       ROUND(100.0 * COUNT(*) FILTER (WHERE freight_value IS NULL) / COUNT(*), 2)
FROM order_items;

SELECT 'order_items: rows with at least one NULL:' AS section;
SELECT *
FROM order_items
WHERE order_id IS NULL OR order_item_id IS NULL OR product_id IS NULL
   OR seller_id IS NULL OR shipping_limit_date IS NULL
   OR price IS NULL OR freight_value IS NULL;


-- ============================================================================
-- STEP 4 - PAYMENTS: key profile
-- ============================================================================
SELECT '=== STEP 4 - ORDER_PAYMENTS: KEY PROFILE ===' AS section;

SELECT COUNT(*)                                    AS total_rows,
       COUNT(DISTINCT order_id)                    AS distinct_order_id,
       COUNT(*) FILTER (WHERE order_id IS NULL)    AS null_order_id
FROM order_payments;


-- ============================================================================
-- STEP 5 - ORPHAN CHECKS (child values with no match in the parent table)
-- ============================================================================
SELECT '=== STEP 5 - ORPHAN CHECKS ===' AS section;

-- One row per distinct orphan value: which check, the value, how many rows hit.
CREATE OR REPLACE TEMP TABLE orphan_values AS
SELECT 'orders_raw.order_id -> order_items.order_id' AS fk_check,
       c.order_id AS value, COUNT(*) AS rows_affected
FROM orders_raw c
LEFT JOIN order_items p ON c.order_id = p.order_id
WHERE p.order_id IS NULL
GROUP BY c.order_id
UNION ALL
SELECT 'orders_raw.customer_id -> customers.customer_id',
       c.customer_id, COUNT(*)
FROM orders_raw c
LEFT JOIN customers p ON c.customer_id = p.customer_id
WHERE p.customer_id IS NULL
GROUP BY c.customer_id
UNION ALL
SELECT 'order_items.order_id -> orders_raw.order_id',
       c.order_id, COUNT(*)
FROM order_items c
LEFT JOIN orders_raw p ON c.order_id = p.order_id
WHERE p.order_id IS NULL
GROUP BY c.order_id
UNION ALL
SELECT 'order_items.product_id -> raw_products.product_id',
       c.product_id, COUNT(*)
FROM order_items c
LEFT JOIN raw_products p ON c.product_id = p.product_id
WHERE p.product_id IS NULL
GROUP BY c.product_id
UNION ALL
SELECT 'order_items.seller_id -> olist_sellers.seller_id',
       c.seller_id, COUNT(*)
FROM order_items c
LEFT JOIN olist_sellers p ON c.seller_id = p.seller_id
WHERE p.seller_id IS NULL
GROUP BY c.seller_id
UNION ALL
SELECT 'order_payments.order_id -> orders_raw.order_id',
       c.order_id, COUNT(*)
FROM order_payments c
LEFT JOIN orders_raw p ON c.order_id = p.order_id
WHERE p.order_id IS NULL
GROUP BY c.order_id;

SELECT 'Orphan summary (a check with 0 orphans does not appear in the sample below):' AS section;
WITH checked AS (
    SELECT 'orders_raw.order_id -> order_items.order_id' AS fk_check,
           COUNT(DISTINCT order_id) AS distinct_checked FROM orders_raw
    UNION ALL
    SELECT 'orders_raw.customer_id -> customers.customer_id',
           COUNT(DISTINCT customer_id) FROM orders_raw
    UNION ALL
    SELECT 'order_items.order_id -> orders_raw.order_id',
           COUNT(DISTINCT order_id) FROM order_items
    UNION ALL
    SELECT 'order_items.product_id -> raw_products.product_id',
           COUNT(DISTINCT product_id) FROM order_items
    UNION ALL
    SELECT 'order_items.seller_id -> olist_sellers.seller_id',
           COUNT(DISTINCT seller_id) FROM order_items
    UNION ALL
    SELECT 'order_payments.order_id -> orders_raw.order_id',
           COUNT(DISTINCT order_id) FROM order_payments
),
orphans AS (
    SELECT fk_check,
           COUNT(*)           AS distinct_without_match,
           SUM(rows_affected) AS rows_affected
    FROM orphan_values
    GROUP BY fk_check
)
SELECT c.fk_check,
       c.distinct_checked,
       COALESCE(o.distinct_without_match, 0) AS distinct_without_match,
       COALESCE(o.rows_affected, 0)          AS rows_affected
FROM checked c
LEFT JOIN orphans o USING (fk_check)
ORDER BY c.fk_check;

SELECT 'Sample of unmatched values (up to 20 per check):' AS section;
SELECT fk_check, value, rows_affected
FROM orphan_values
QUALIFY ROW_NUMBER() OVER (PARTITION BY fk_check
                           ORDER BY rows_affected DESC, value) <= 20
ORDER BY fk_check, rows_affected DESC, value;


-- ============================================================================
-- STEP 6 - PRODUCTS: fill the missing category with 'sem categoria'
-- A category is "missing" when it is NULL or empty/whitespace-only.
-- ============================================================================
SELECT '=== STEP 6 - PRODUCTS: MISSING CATEGORY ===' AS section;

CREATE OR REPLACE TABLE products AS
SELECT * FROM raw_products;

SELECT COUNT(*) AS rows_without_category_before
FROM products
WHERE product_category_name IS NULL OR TRIM(product_category_name) = '';

UPDATE products
SET product_category_name = 'sem categoria'
WHERE product_category_name IS NULL OR TRIM(product_category_name) = '';

SELECT
    COUNT(*) FILTER (WHERE product_category_name IS NULL
                        OR TRIM(product_category_name) = '')  AS rows_without_category_after,
    COUNT(*) FILTER (WHERE product_category_name = 'sem categoria') AS rows_labelled_sem_categoria
FROM products;


-- ============================================================================
-- STEP 7 - GEOLOCATION: NULL / EMPTY values and invalid states
-- ============================================================================
SELECT '=== STEP 7 - GEOLOCATION: NULL / EMPTY VALUES ===' AS section;

SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE geolocation_zip_code_prefix IS NULL
                     OR TRIM(geolocation_zip_code_prefix) = '') AS null_zip,
    COUNT(*) FILTER (WHERE geolocation_lat IS NULL)             AS null_lat,
    COUNT(*) FILTER (WHERE geolocation_lng IS NULL)             AS null_lng,
    COUNT(*) FILTER (WHERE geolocation_city IS NULL
                     OR TRIM(geolocation_city) = '')            AS null_city,
    COUNT(*) FILTER (WHERE geolocation_state IS NULL
                     OR TRIM(geolocation_state) = '')           AS null_state
FROM geo;

SELECT 'Geolocation: rows with a NULL/EMPTY value (zip prefix + which column is null):' AS section;
SELECT
    geolocation_zip_code_prefix AS zip_code_prefix,
    row_id,
    concat_ws(', ',
        CASE WHEN geolocation_zip_code_prefix IS NULL
               OR TRIM(geolocation_zip_code_prefix) = '' THEN 'zip_code_prefix' END,
        CASE WHEN geolocation_lat IS NULL THEN 'lat' END,
        CASE WHEN geolocation_lng IS NULL THEN 'lng' END,
        CASE WHEN geolocation_city IS NULL
               OR TRIM(geolocation_city) = '' THEN 'city' END,
        CASE WHEN geolocation_state IS NULL
               OR TRIM(geolocation_state) = '' THEN 'state' END
    ) AS null_columns
FROM geo
WHERE geolocation_zip_code_prefix IS NULL OR TRIM(geolocation_zip_code_prefix) = ''
   OR geolocation_lat IS NULL OR geolocation_lng IS NULL
   OR geolocation_city IS NULL OR TRIM(geolocation_city) = ''
   OR geolocation_state IS NULL OR TRIM(geolocation_state) = ''
ORDER BY zip_code_prefix, row_id;

SELECT '=== STEP 7b - GEOLOCATION: STATE ===' AS section;

-- The 27 valid Brazilian UF codes
CREATE OR REPLACE TEMP TABLE valid_states AS
SELECT unnest(['AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG',
               'PA', 'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE',
               'TO']) AS uf;

SELECT 'Invalid state values (not one of the 27 UFs, or not uppercase/trimmed):' AS section;
SELECT geolocation_state,
       COUNT(*) AS n_rows,
       MIN(geolocation_zip_code_prefix) AS example_zip_prefix
FROM geo
WHERE geolocation_state IS NOT NULL
  AND geolocation_state NOT IN (SELECT uf FROM valid_states)
GROUP BY geolocation_state
ORDER BY n_rows DESC;


-- ============================================================================
-- STEP 8 - JSON SELLER PROFILES: clean, then flatten into sellers_clean
-- ============================================================================

-- ---- 8a. Deduplication: keep only the most recent record (updated_at) -------
SELECT '=== STEP 8a - JSON: DUPLICATED SELLERS ===' AS section;

SELECT 'Inconsistent records (duplicated seller_id) - BEFORE cleaning:' AS section;
SELECT
    json_extract_string(json, '$.seller_id')  AS seller_id,
    json_extract_string(json, '$.updated_at') AS updated_at,
    rowid
FROM sellers_raw
WHERE json_extract_string(json, '$.seller_id') IN (
    SELECT json_extract_string(json, '$.seller_id')
    FROM sellers_raw
    GROUP BY 1
    HAVING COUNT(*) > 1
)
ORDER BY seller_id, updated_at DESC;

CREATE OR REPLACE TEMP TABLE json_count_before AS
SELECT COUNT(*) AS n FROM sellers_raw;

-- rowid is the tie-breaker so the result is deterministic.
DELETE FROM sellers_raw
WHERE rowid IN (
    SELECT rowid
    FROM (
        SELECT
            rowid,
            ROW_NUMBER() OVER (
                PARTITION BY json_extract_string(json, '$.seller_id')
                ORDER BY
                    TRY_CAST(json_extract_string(json, '$.updated_at') AS TIMESTAMP)
                        DESC NULLS LAST,
                    rowid DESC
            ) AS rn
        FROM sellers_raw
    )
    WHERE rn > 1
);

SELECT b.n AS records_before, a.n AS records_after, b.n - a.n AS records_removed
FROM json_count_before b,
     (SELECT COUNT(*) AS n FROM sellers_raw) a;

-- ---- 8b. Tier: trim whitespace and lower-case -------------------------------
SELECT '=== STEP 8b - JSON: TIER ===' AS section;

SELECT 'Tier distribution - BEFORE cleaning:' AS section;
SELECT json_extract_string(json, '$.profile.tier') AS tier,
       COUNT(*) AS occurrences
FROM sellers_raw
GROUP BY tier
ORDER BY tier NULLS FIRST;

SELECT 'Tier: inconsistent records (extra spaces or mixed case):' AS section;
SELECT json_extract_string(json, '$.seller_id') AS seller_id,
       json_extract_string(json, '$.profile.tier') AS tier
FROM sellers_raw
WHERE json_extract_string(json, '$.profile.tier') IS NOT NULL
  AND json_extract_string(json, '$.profile.tier')
      <> LOWER(TRIM(json_extract_string(json, '$.profile.tier')))
ORDER BY seller_id;

UPDATE sellers_raw
SET json = json_merge_patch(
    json,
    json_object(
        'profile',
        json_object(
            'tier',
            LOWER(TRIM(json_extract_string(json, '$.profile.tier')))
        )
    )
)
WHERE json_extract_string(json, '$.profile.tier') IS NOT NULL;

SELECT 'Tier distribution - AFTER cleaning:' AS section;
SELECT json_extract_string(json, '$.profile.tier') AS tier,
       COUNT(*) AS occurrences
FROM sellers_raw
GROUP BY tier
ORDER BY tier NULLS FIRST;

-- ---- 8c. Carriers: trim whitespace and lower-case every name ----------------
SELECT '=== STEP 8c - JSON: CARRIER_NAME ===' AS section;

-- One row per (seller, carrier). It is a view, so it always reflects the
-- current state of sellers_raw (before and after the UPDATE below).
CREATE OR REPLACE TEMP VIEW seller_carriers AS
SELECT
    json_extract_string(s.json, '$.seller_id') AS seller_id,
    json_extract_string(c.value, '$') AS carrier_name
FROM sellers_raw AS s,
     json_each(s.json, '$.shipping.carriers') AS c
WHERE json_type(s.json, '$.shipping.carriers') = 'ARRAY';

SELECT 'Carrier distribution - BEFORE cleaning:' AS section;
SELECT carrier_name, COUNT(*) AS occurrences
FROM seller_carriers
GROUP BY carrier_name
ORDER BY carrier_name NULLS FIRST;

SELECT 'Carrier: inconsistent records (extra spaces or mixed case):' AS section;
SELECT seller_id, carrier_name
FROM seller_carriers
WHERE carrier_name IS NOT NULL
  AND carrier_name <> LOWER(TRIM(carrier_name))
ORDER BY seller_id;

UPDATE sellers_raw
SET json = json_merge_patch(
    json,
    json_object(
        'shipping',
        json_object(
            'carriers',
            list_transform(
                from_json(
                    json_extract(json, '$.shipping.carriers'),
                    '["VARCHAR"]'
                ),
                x -> LOWER(TRIM(x))
            )
        )
    )
)
WHERE json_type(json, '$.shipping.carriers') = 'ARRAY';

SELECT 'Carrier distribution - AFTER cleaning:' AS section;
SELECT carrier_name, COUNT(*) AS occurrences
FROM seller_carriers
GROUP BY carrier_name
ORDER BY carrier_name NULLS FIRST;

-- ---- 8d. Phone (validation only, no changes) --------------------------------
-- Expected format: +55 DD 9xxxx-xxxx  ->  ^\+55\s\d{2}\s9\d{4}-\d{4}$
SELECT '=== STEP 8d - JSON: PHONE ===' AS section;

SELECT 'Phone: inconsistent records (expected pattern ^\+55\s\d{2}\s9\d{4}-\d{4}$):' AS section;
SELECT json_extract_string(json, '$.seller_id') AS seller_id,
       json_extract_string(json, '$.contact.phone') AS phone
FROM sellers_raw
WHERE json_extract_string(json, '$.contact.phone') IS NOT NULL
  AND NOT regexp_full_match(
      json_extract_string(json, '$.contact.phone'), '^\+55\s\d{2}\s9\d{4}-\d{4}$')
ORDER BY seller_id;

SELECT 'Phone validation summary:' AS section;
SELECT
    CASE
        WHEN json_extract_string(json, '$.contact.phone') IS NULL THEN 'MISSING'
        WHEN regexp_full_match(
            json_extract_string(json, '$.contact.phone'), '^\+55\s\d{2}\s9\d{4}-\d{4}$')
            THEN 'VALID'
        ELSE 'INVALID'
    END AS validation_status,
    COUNT(*) AS occurrences
FROM sellers_raw
GROUP BY validation_status
ORDER BY validation_status;

-- ---- 8e. Type conversion checks (nothing is modified) -----------------------
-- Shows the records whose values become NULL (or change type) when cast in
-- sellers_clean.
SELECT '=== STEP 8e - JSON: TYPE CONVERSION (handling_days, dates) ===' AS section;

SELECT 'Inconsistent handling_days (string type or not an integer):' AS section;
SELECT json_extract_string(json, '$.seller_id') AS seller_id,
       json_extract_string(json, '$.shipping.handling_days') AS value,
       json_type(json, '$.shipping.handling_days') AS original_type
FROM sellers_raw
WHERE json_extract_string(json, '$.shipping.handling_days') IS NOT NULL
  AND (
      json_type(json, '$.shipping.handling_days') = 'VARCHAR'
      OR TRY_CAST(json_extract_string(json, '$.shipping.handling_days') AS INTEGER) IS NULL
  )
ORDER BY seller_id;

SELECT 'Inconsistent $.updated_at (cannot be cast to TIMESTAMP):' AS section;
SELECT json_extract_string(json, '$.seller_id') AS seller_id,
       json_extract_string(json, '$.updated_at') AS value
FROM sellers_raw
WHERE json_extract_string(json, '$.updated_at') IS NOT NULL
  AND TRY_CAST(json_extract_string(json, '$.updated_at') AS TIMESTAMP) IS NULL
ORDER BY seller_id;

SELECT 'Inconsistent $.profile.joined_on (cannot be cast to DATE):' AS section;
SELECT json_extract_string(json, '$.seller_id') AS seller_id,
       json_extract_string(json, '$.profile.joined_on') AS value
FROM sellers_raw
WHERE json_extract_string(json, '$.profile.joined_on') IS NOT NULL
  AND TRY_CAST(json_extract_string(json, '$.profile.joined_on') AS DATE) IS NULL
ORDER BY seller_id;

-- ---- 8f. Final flat table ----------------------------------------------------
-- TRY_CAST returns NULL for values that cannot be converted.
-- LEFT JOIN LATERAL keeps sellers without carriers (carrier_name = NULL).
-- Each element of the carriers array becomes one row.
SELECT '=== STEP 8f - BUILDING: sellers_clean ===' AS section;

CREATE OR REPLACE TABLE sellers_clean AS
SELECT
    json_extract_string(s.json, '$.seller_id') AS seller_id,
    TRY_CAST(json_extract_string(s.json, '$.updated_at') AS TIMESTAMP) AS updated_at,
    json_extract_string(s.json, '$.profile.tier') AS tier,
    TRY_CAST(json_extract_string(s.json, '$.profile.joined_on') AS DATE) AS joined_on,
    json_extract_string(s.json, '$.contact.email') AS email,
    json_extract_string(s.json, '$.contact.phone') AS phone,
    json_extract_string(c.value, '$') AS carrier_name,
    TRY_CAST(json_extract_string(s.json, '$.shipping.handling_days') AS INTEGER)
        AS shipping_time
FROM sellers_raw AS s
LEFT JOIN LATERAL json_each(s.json, '$.shipping.carriers') AS c ON TRUE;

SELECT COUNT(*) AS sellers_clean_rows FROM sellers_clean;

SELECT 'Sellers without carriers:' AS section;
SELECT * FROM sellers_clean WHERE carrier_name IS NULL;


-- ============================================================================
-- STEP 9 - SELLERS: correspondence between JSON, Olist CSV and order_items
-- ============================================================================
SELECT '=== STEP 9 - SELLERS: PROFILE OF sellers_clean (JSON) ===' AS section;

-- One row per seller_id (sellers_clean has one row per carrier)
CREATE OR REPLACE TEMP VIEW json_ids AS
SELECT DISTINCT seller_id FROM sellers_clean WHERE seller_id IS NOT NULL;

CREATE OR REPLACE TEMP VIEW csv_ids AS
SELECT DISTINCT seller_id FROM olist_sellers;

CREATE OR REPLACE TEMP VIEW item_ids AS
SELECT DISTINCT seller_id FROM order_items;

SELECT
    (SELECT COUNT(*) FROM sellers_clean)                          AS rows_in_sellers_clean,
    (SELECT COUNT(*) FROM json_ids)                               AS distinct_seller_id,
    (SELECT COUNT(*) FROM sellers_clean WHERE seller_id IS NULL)  AS null_seller_id,
    (SELECT COUNT(*) FROM json_ids
      WHERE LENGTH(seller_id) <> 32
         OR seller_id <> LOWER(TRIM(seller_id)))                  AS seller_id_bad_format;

SELECT 'Sample of badly formatted seller_id (up to 20):' AS section;
SELECT seller_id
FROM json_ids
WHERE LENGTH(seller_id) <> 32 OR seller_id <> LOWER(TRIM(seller_id))
LIMIT 20;

SELECT '=== STEP 9b - SELLERS: CORRESPONDENCE CHECKS ===' AS section;

CREATE OR REPLACE TEMP TABLE seller_orphans AS
SELECT 'A) sellers_clean (JSON) -> olist_sellers (CSV)' AS check_name, c.seller_id
FROM json_ids c LEFT JOIN csv_ids p ON c.seller_id = p.seller_id
WHERE p.seller_id IS NULL
UNION ALL
SELECT 'B) olist_sellers (CSV) -> sellers_clean (JSON)', c.seller_id
FROM csv_ids c LEFT JOIN json_ids p ON c.seller_id = p.seller_id
WHERE p.seller_id IS NULL
UNION ALL
SELECT 'C) order_items -> sellers_clean (JSON)', c.seller_id
FROM item_ids c LEFT JOIN json_ids p ON c.seller_id = p.seller_id
WHERE p.seller_id IS NULL
UNION ALL
SELECT 'D) sellers_clean (JSON) -> order_items (informational: profiles with no sales)',
       c.seller_id
FROM json_ids c LEFT JOIN item_ids p ON c.seller_id = p.seller_id
WHERE p.seller_id IS NULL;

WITH checked AS (
    SELECT 'A) sellers_clean (JSON) -> olist_sellers (CSV)' AS check_name,
           COUNT(*) AS distinct_checked FROM json_ids
    UNION ALL
    SELECT 'B) olist_sellers (CSV) -> sellers_clean (JSON)', COUNT(*) FROM csv_ids
    UNION ALL
    SELECT 'C) order_items -> sellers_clean (JSON)', COUNT(*) FROM item_ids
    UNION ALL
    SELECT 'D) sellers_clean (JSON) -> order_items (informational: profiles with no sales)',
           COUNT(*) FROM json_ids
)
SELECT c.check_name,
       c.distinct_checked,
       COUNT(o.seller_id) AS distinct_without_match
FROM checked c
LEFT JOIN seller_orphans o USING (check_name)
GROUP BY c.check_name, c.distinct_checked
ORDER BY c.check_name;

SELECT 'Sample of unmatched seller_id (up to 20 per check):' AS section;
SELECT check_name, seller_id
FROM seller_orphans
QUALIFY ROW_NUMBER() OVER (PARTITION BY check_name ORDER BY seller_id) <= 20
ORDER BY check_name, seller_id;

SELECT '=== profiling.sql finished ===' AS section;