-- ============================================================================
-- build_model.sql  -  build the dimensional model of the Olist / NorthMart data
--
-- Replaces: build_snowflake.py
--
-- Run from the src folder (paths below are relative to it), AFTER profiling.sql:
--     cd src
--     duckdb -bail olist.duckdb < profiling.sql
--     duckdb -bail olist.duckdb < build_model.sql
--
-- All validations of the raw data live in profiling.sql. This script only
-- builds the model and checks its own output (STEP 4).
--
-- Grain of the fact table: one row per order item (order_id + order_item_id).
--
-- ---------------------------------------------------------------------------
-- THE MODEL (PK = primary key, FK = foreign key; all keys are natural keys,
-- except carrier_key and dates_id, which are integers 1..N)
--
--   fact_order_items
--       PK (order_id, order_item_id)
--       FK product_id             -> dim_product.product_id
--       FK seller_id              -> dim_seller.seller_id
--       FK customer_id            -> dim_customer.customer_id
--       FK dates_id               -> dim_dates.dates_id
--       FK review_id (nullable)   -> dim_review.review_id
--       FK product_category_name  -> dim_category_name_translation.product_category_name
--       order_purchase_timestamp, price, freight_cost
--   dim_customer      PK customer_id; customer_zip_code_prefix -> dim_geo.zip*
--   dim_seller        PK seller_id;   seller_zip_code_prefix   -> dim_geo.zip*
--   bridge_seller_carrier  PK (seller_id, carrier_key); both are FKs
--   dim_carrier       PK carrier_key
--   dim_geo           NO PK: every row of the geolocation file (zip repeats)
--   dim_review        PK review_id (no order_id: the fact points to the review)
--   dim_payment_details  PK (order_id, payment_sequential); order_id -> fact*
--   dim_product       PK product_id
--   dim_category_name_translation  PK product_category_name
--   dim_dates         PK dates_id (one row per order)
--
--   * logical foreign key, NOT enforced: the target column is not unique
--     (zip in dim_geo, order_id in the fact). STEP 4 reports orphans as WARN.
--
-- Tables built (children are dropped first, parents are built first):
--   dim_category_name_translation, dim_geo, dim_product, dim_customer,
--   dim_carrier, dim_seller, bridge_seller_carrier, dim_dates, dim_review,
--   dim_payment_details, fact_order_items
-- ============================================================================


-- ============================================================================
-- STEP 0 - PREREQUISITES AND DROP
-- ============================================================================
SELECT '=== STEP 0 - PREREQUISITES ===' AS section;

-- Tables created by profiling.sql that this script depends on.
SELECT t.table_name,
       CASE WHEN i.table_name IS NOT NULL THEN 'OK'
            ELSE 'MISSING (run profiling.sql)' END AS status
FROM (VALUES ('products'), ('sellers_clean'), ('orders_clean'),
             ('order_dates')) t(table_name)
LEFT JOIN information_schema.tables i ON i.table_name = t.table_name;

SELECT CASE
         WHEN COUNT(*) = 4 THEN 'prerequisites OK'
         ELSE error('Missing tables from profiling.sql. Run profiling.sql first, '
                    || 'then run this script again.')
       END AS prerequisites
FROM information_schema.tables
WHERE table_name IN ('products', 'sellers_clean', 'orders_clean', 'order_dates');

-- Children first, so they can be dropped without breaking FK dependencies
DROP TABLE IF EXISTS fact_order_items;
DROP TABLE IF EXISTS bridge_seller_carrier;
DROP TABLE IF EXISTS dim_review;
DROP TABLE IF EXISTS dim_payment_details;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_carrier;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_dates;
DROP TABLE IF EXISTS dim_geo;
DROP TABLE IF EXISTS dim_category_name_translation;

-- Leftovers from the previous version of the model (old names), if present
DROP TABLE IF EXISTS dim_payment;
DROP TABLE IF EXISTS dim_delivery;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_geolocation;
DROP TABLE IF EXISTS dim_category_translation;


-- ============================================================================
-- STEP 1 - STAGING (CSVs that are not already cleaned in the database)
-- Zip prefixes are forced to VARCHAR (same in every table) so they keep their
-- leading zeros and compare equal.
-- ============================================================================
SELECT '=== STEP 1 - STAGING ===' AS section;

CREATE OR REPLACE TABLE stg_order_items AS
SELECT * FROM read_csv('../architecture/data/source/olist_order_items_dataset.csv',
                       header = true);

CREATE OR REPLACE TABLE stg_customers AS
SELECT * FROM read_csv('../architecture/data/source/olist_customers_dataset.csv',
                       header = true,
                       types = {'customer_zip_code_prefix': 'VARCHAR'});

CREATE OR REPLACE TABLE stg_sellers AS
SELECT * FROM read_csv('../architecture/data/source/olist_sellers_dataset.csv',
                       header = true,
                       types = {'seller_zip_code_prefix': 'VARCHAR'});

CREATE OR REPLACE TABLE stg_geolocation AS
SELECT * FROM read_csv('../architecture/data/source/olist_geolocation_dataset.csv',
                       header = true,
                       types = {'geolocation_zip_code_prefix': 'VARCHAR'});

CREATE OR REPLACE TABLE stg_reviews AS
SELECT * FROM read_csv('../architecture/data/source/olist_order_reviews_dataset.csv',
                       header = true);

CREATE OR REPLACE TABLE stg_payments AS
SELECT * FROM read_csv('../architecture/data/source/olist_order_payments_dataset.csv',
                       header = true);

CREATE OR REPLACE TABLE stg_translation AS
SELECT * FROM read_csv('../architecture/data/source/product_category_name_translation.csv',
                       header = true);

SELECT 'stg_order_items' AS staging_table, COUNT(*) AS row_count FROM stg_order_items
UNION ALL SELECT 'stg_customers',   COUNT(*) FROM stg_customers
UNION ALL SELECT 'stg_sellers',     COUNT(*) FROM stg_sellers
UNION ALL SELECT 'stg_geolocation', COUNT(*) FROM stg_geolocation
UNION ALL SELECT 'stg_reviews',     COUNT(*) FROM stg_reviews
UNION ALL SELECT 'stg_payments',    COUNT(*) FROM stg_payments
UNION ALL SELECT 'stg_translation', COUNT(*) FROM stg_translation;


-- ============================================================================
-- STEP 2 - DIMENSIONS
-- Order matters: a dimension is built after the ones it points to.
-- ============================================================================

-- ---- dim_category_name_translation ----------------------------------------------
-- Translation file + categories that products use but the file does not have
-- (listed by profiling.sql STEP 10).
SELECT '=== BUILDING: dim_category_name_translation ===' AS section;

CREATE TABLE dim_category_name_translation (
    product_category_name VARCHAR PRIMARY KEY,
    product_category_name_english VARCHAR
);

-- 'sem categoria' -> 'uncategorized'; any other missing category stays NULL
INSERT INTO dim_category_name_translation
SELECT product_category_name, product_category_name_english
FROM stg_translation
UNION ALL
SELECT DISTINCT
    p.product_category_name,
    CASE WHEN p.product_category_name = 'sem categoria' THEN 'uncategorized' END
FROM products p
WHERE p.product_category_name IS NOT NULL
  AND NOT EXISTS (SELECT 1
                    FROM stg_translation t
                   WHERE t.product_category_name = p.product_category_name);

SELECT COUNT(*) AS dim_category_name_translation_rows FROM dim_category_name_translation;


-- ---- dim_geo ----------------------------------------------------------------------
-- EVERY row of the geolocation file, as it is (no PK: zip repeats).
-- customer_zip_code_prefix and seller_zip_code_prefix point to dim_geo.zip, but
-- that foreign key cannot be enforced because zip is not unique.
SELECT '=== BUILDING: dim_geo ===' AS section;

CREATE TABLE dim_geo (
    zip VARCHAR,
    lat DOUBLE,
    lng DOUBLE,
    geo_city VARCHAR,
    geo_state VARCHAR
);

INSERT INTO dim_geo
SELECT
    geolocation_zip_code_prefix,
    geolocation_lat,
    geolocation_lng,
    geolocation_city,
    geolocation_state
FROM stg_geolocation;

SELECT (SELECT COUNT(*) FROM stg_geolocation) AS rows_in_file,
       COUNT(*)                               AS dim_geo_rows,
       COUNT(DISTINCT zip)                    AS distinct_zips
FROM dim_geo;


-- ---- dim_product ----------------------------------------------------------------
-- Products are already cleaned: 'sem categoria' was applied by profiling.sql.
-- The category is not a column here: it lives in the fact table.
SELECT '=== BUILDING: dim_product ===' AS section;

CREATE TABLE dim_product (
    product_id VARCHAR PRIMARY KEY,
    product_name_lenght INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty INTEGER,
    product_weight_g INTEGER,
    product_length_cm INTEGER,
    product_height_cm INTEGER,
    product_width_cm INTEGER
);

INSERT INTO dim_product
SELECT
    product_id,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm
FROM products;

SELECT (SELECT COUNT(*) FROM products)     AS products_in_source,
       (SELECT COUNT(*) FROM dim_product)  AS products_loaded;


-- ---- dim_customer ---------------------------------------------------------------
SELECT '=== BUILDING: dim_customer ===' AS section;

CREATE TABLE dim_customer (
    customer_id VARCHAR PRIMARY KEY,
    customer_unique_id VARCHAR,
    customer_zip_code_prefix VARCHAR,     -- logical FK -> dim_geo.zip (not enforced)
    customer_city VARCHAR,
    customer_state VARCHAR
);

INSERT INTO dim_customer
SELECT
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
FROM stg_customers;

SELECT (SELECT COUNT(*) FROM stg_customers) AS customers_in_file,
       (SELECT COUNT(*) FROM dim_customer)  AS customers_loaded;


-- ---- dim_carrier ----------------------------------------------------------------
-- Small lookup of carriers (snowflaked out of the seller dimension).
-- Carrier names are already trimmed and lower-cased by profiling.sql STEP 8c.
SELECT '=== BUILDING: dim_carrier ===' AS section;

CREATE TABLE dim_carrier (
    carrier_key INTEGER PRIMARY KEY,
    carrier_name VARCHAR NOT NULL UNIQUE
);

INSERT INTO dim_carrier
SELECT CAST(ROW_NUMBER() OVER (ORDER BY carrier_name) AS INTEGER), carrier_name
FROM (
    SELECT DISTINCT carrier_name
    FROM sellers_clean
    WHERE carrier_name IS NOT NULL AND carrier_name <> ''
    UNION
    SELECT 'sem transportadora especificada'
);

SELECT * FROM dim_carrier ORDER BY carrier_key;


-- ---- dim_seller -----------------------------------------------------------------
-- ONE ROW PER SELLER. Union of the sellers from the Olist CSV and the JSON profiles.
--  - zip / city / state come from the CSV (JSON-only sellers have NULL there)
--  - JSON fields (tier, joined_on, handling_days, ...) are flattened into the row
--  - no handling days -> 0
--  - any other missing field -> NULL
--  - the list of carriers goes to bridge_seller_carrier (a seller has several)
-- (profiling.sql STEP 8f checks that the seller-level JSON fields are identical
--  across the carrier rows, so ANY_VALUE below is safe.)
SELECT '=== BUILDING: dim_seller ===' AS section;

CREATE TABLE dim_seller (
    seller_id VARCHAR PRIMARY KEY,
    seller_zip_code_prefix VARCHAR,       -- logical FK -> dim_geo.zip (not enforced)
    seller_city VARCHAR,
    seller_state VARCHAR,
    tier VARCHAR,
    updated_at TIMESTAMP,
    joined_on DATE,
    email VARCHAR,
    phone VARCHAR,
    handling_days INTEGER NOT NULL
);

INSERT INTO dim_seller
WITH all_ids AS (
    SELECT seller_id FROM stg_sellers WHERE seller_id IS NOT NULL
    UNION
    SELECT seller_id FROM sellers_clean WHERE seller_id IS NOT NULL
),
json_one AS (
    SELECT
        seller_id,
        ANY_VALUE(tier) AS tier,
        ANY_VALUE(joined_on) AS joined_on,
        ANY_VALUE(shipping_time) AS shipping_time,
        ANY_VALUE(updated_at) AS updated_at,
        ANY_VALUE(email) AS email,
        ANY_VALUE(phone) AS phone
    FROM sellers_clean
    WHERE seller_id IS NOT NULL
    GROUP BY seller_id
)
SELECT
    a.seller_id,
    s.seller_zip_code_prefix,
    s.seller_city,
    s.seller_state,
    j.tier,
    j.updated_at,
    j.joined_on,
    j.email,
    j.phone,
    COALESCE(j.shipping_time, 0)
FROM all_ids a
LEFT JOIN stg_sellers s ON a.seller_id = s.seller_id
LEFT JOIN json_one j ON a.seller_id = j.seller_id;

SELECT 'Seller coverage:' AS section;
SELECT
    COUNT(*) AS sellers,
    COUNT(*) FILTER (
        WHERE seller_id NOT IN (SELECT seller_id FROM stg_sellers)
    ) AS only_in_json,
    COUNT(*) FILTER (
        WHERE seller_id NOT IN (
            SELECT seller_id FROM sellers_clean WHERE seller_id IS NOT NULL)
    ) AS only_in_csv
FROM dim_seller;


-- ---- bridge_seller_carrier ------------------------------------------------------
-- Bridge seller <-> carrier (many-to-many). Sellers with none get a placeholder.
SELECT '=== BUILDING: bridge_seller_carrier ===' AS section;

CREATE TABLE bridge_seller_carrier (
    seller_id VARCHAR NOT NULL REFERENCES dim_seller (seller_id),
    carrier_key INTEGER NOT NULL REFERENCES dim_carrier (carrier_key),
    PRIMARY KEY (seller_id, carrier_key)
);

INSERT INTO bridge_seller_carrier
SELECT DISTINCT s.seller_id, c.carrier_key
FROM sellers_clean sc
JOIN dim_seller s ON sc.seller_id = s.seller_id
JOIN dim_carrier c ON sc.carrier_name = c.carrier_name;

CREATE OR REPLACE TEMP TABLE bridge_rows_with_carrier AS
SELECT COUNT(*) AS n FROM bridge_seller_carrier;

-- Sellers that ended up with no carrier row get the placeholder carrier
INSERT INTO bridge_seller_carrier
SELECT s.seller_id,
       (SELECT carrier_key FROM dim_carrier
         WHERE carrier_name = 'sem transportadora especificada')
FROM dim_seller s
WHERE NOT EXISTS (
    SELECT 1 FROM bridge_seller_carrier b WHERE b.seller_id = s.seller_id
);

SELECT (SELECT COUNT(*) FROM bridge_seller_carrier) AS bridge_rows,
       (SELECT COUNT(*) FROM bridge_seller_carrier)
         - (SELECT n FROM bridge_rows_with_carrier) AS sellers_given_placeholder_carrier;


-- ---- dim_dates ------------------------------------------------------------------
-- One row per order. dates_id (integer 1..N) was assigned by profiling.sql
-- STEP 2 and is the same one stored in orders_clean.
SELECT '=== BUILDING: dim_dates ===' AS section;

CREATE TABLE dim_dates (
    dates_id INTEGER PRIMARY KEY,
    order_approved_at TIMESTAMP,
    order_delivered_carrier_date TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

INSERT INTO dim_dates
SELECT
    dates_id,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date
FROM order_dates;

SELECT COUNT(*) AS dim_dates_rows FROM dim_dates;


-- ---- dim_review -----------------------------------------------------------------
-- ONE ROW PER review_id, without order_id (the fact table holds the link).
-- review_id repeats in the source (see profiling.sql STEP 11): the row with the
-- latest answer is kept. Rows without a review_id cannot be keyed and are left out.
SELECT '=== BUILDING: dim_review ===' AS section;

CREATE TABLE dim_review (
    review_id VARCHAR PRIMARY KEY,
    review_score INTEGER,
    review_comment_title VARCHAR,
    review_comment_message VARCHAR,
    review_creation_date TIMESTAMP,
    review_answer_timestamp TIMESTAMP
);

INSERT INTO dim_review
SELECT
    review_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
FROM stg_reviews
WHERE review_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY review_id
    ORDER BY review_answer_timestamp DESC NULLS LAST,
             review_creation_date DESC NULLS LAST,
             order_id DESC NULLS LAST
) = 1;

SELECT (SELECT COUNT(*) FROM stg_reviews) AS rows_in_file,
       (SELECT COUNT(*) FROM dim_review)  AS rows_loaded,
       (SELECT COUNT(*) FROM stg_reviews) - (SELECT COUNT(*) FROM dim_review)
           AS rows_left_out;

-- The review each order points to: its LATEST one (ties broken the same way
-- every run). Orders without any review are simply absent here.
CREATE OR REPLACE TEMP TABLE order_latest_review AS
SELECT order_id, review_id
FROM stg_reviews
WHERE order_id IS NOT NULL AND review_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY order_id
    ORDER BY review_answer_timestamp DESC NULLS LAST,
             review_creation_date DESC NULLS LAST,
             review_id DESC
) = 1;


-- ---- dim_payment_details --------------------------------------------------------
-- Natural key = (order_id, payment_sequential): an order can have several payments.
-- order_id points to the fact table's order_id, but it is a logical FK only
-- (order_id is not unique in the fact: one row per item).
SELECT '=== BUILDING: dim_payment_details ===' AS section;

CREATE TABLE dim_payment_details (
    order_id VARCHAR NOT NULL,            -- logical FK -> fact_order_items.order_id
    payment_sequential INTEGER NOT NULL,
    payment_type VARCHAR,
    payment_installments INTEGER,
    payment_value DOUBLE,
    PRIMARY KEY (order_id, payment_sequential)
);

INSERT INTO dim_payment_details
SELECT
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
FROM stg_payments;

SELECT COUNT(*) AS dim_payment_details_rows FROM dim_payment_details;


-- ============================================================================
-- STEP 3 - FACT TABLE
-- Grain: one row per order item.
-- PK (order_id, order_item_id). Every other reference is a natural key that is
-- an enforced FK to its dimension. review_id is nullable (order without review).
-- Measures: price, freight_cost.
-- ============================================================================
SELECT '=== BUILDING: fact_order_items ===' AS section;

CREATE TABLE fact_order_items (
    order_id VARCHAR NOT NULL,
    order_item_id INTEGER NOT NULL,
    product_id VARCHAR NOT NULL REFERENCES dim_product (product_id),
    seller_id VARCHAR NOT NULL REFERENCES dim_seller (seller_id),
    customer_id VARCHAR NOT NULL REFERENCES dim_customer (customer_id),
    dates_id INTEGER NOT NULL REFERENCES dim_dates (dates_id),
    review_id VARCHAR REFERENCES dim_review (review_id),
    order_purchase_timestamp TIMESTAMP,
    price DOUBLE,
    freight_cost DOUBLE,
    product_category_name VARCHAR NOT NULL
        REFERENCES dim_category_name_translation (product_category_name),
    PRIMARY KEY (order_id, order_item_id)
);

-- Inner joins: an item whose order/product/customer/seller does not exist
-- cannot get a valid key, so it is left out (and reported below).
-- The category comes from the product; the review from the order's latest review.
INSERT INTO fact_order_items
    (order_id, order_item_id, product_id, seller_id, customer_id, dates_id,
     review_id, order_purchase_timestamp, price, freight_cost,
     product_category_name)
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    o.customer_id,
    o.dates_id,
    r.review_id,
    o.order_purchase_timestamp,
    oi.price,
    oi.freight_value,
    p.product_category_name
FROM stg_order_items oi
JOIN orders_clean o ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
JOIN dim_customer c ON o.customer_id = c.customer_id
JOIN dim_seller s ON oi.seller_id = s.seller_id
LEFT JOIN order_latest_review r ON oi.order_id = r.order_id;

SELECT (SELECT COUNT(*) FROM stg_order_items)    AS items_in_file,
       (SELECT COUNT(*) FROM fact_order_items)   AS items_loaded,
       (SELECT COUNT(*) FROM stg_order_items) - (SELECT COUNT(*) FROM fact_order_items)
           AS skipped;

-- Why were items skipped? Each counter is a broken reference (an item can have
-- more than one). All zeros means nothing was skipped.
SELECT 'Skipped items by reason (an item can have more than one):' AS section;
SELECT
    COUNT(*) FILTER (WHERE o.order_id IS NULL)   AS order_not_found,
    COUNT(*) FILTER (WHERE p.product_id IS NULL) AS product_not_found,
    COUNT(*) FILTER (WHERE s.seller_id IS NULL)  AS seller_not_found,
    COUNT(*) FILTER (WHERE o.order_id IS NOT NULL
                     AND c.customer_id IS NULL)  AS customer_not_found
FROM stg_order_items oi
LEFT JOIN orders_clean o ON oi.order_id = o.order_id
LEFT JOIN products p ON oi.product_id = p.product_id
LEFT JOIN dim_seller s ON oi.seller_id = s.seller_id
LEFT JOIN dim_customer c ON o.customer_id = c.customer_id
WHERE NOT EXISTS (
    SELECT 1 FROM fact_order_items f
    WHERE f.order_id = oi.order_id
      AND f.order_item_id = oi.order_item_id
);

SELECT 'Fact rows linked to a review:' AS section;
SELECT COUNT(*)                                     AS fact_rows,
       COUNT(*) FILTER (WHERE review_id IS NOT NULL) AS rows_with_review,
       COUNT(*) FILTER (WHERE review_id IS NULL)     AS rows_without_review
FROM fact_order_items;


-- ============================================================================
-- STEP 4 - VERIFICATION (key and referential checks on the built model)
-- ============================================================================
SELECT '=== VERIFICATION ===' AS section;

SELECT 'Row counts:' AS section;
SELECT 'fact_order_items' AS table_name, COUNT(*) AS row_count FROM fact_order_items
UNION ALL SELECT 'bridge_seller_carrier',          COUNT(*) FROM bridge_seller_carrier
UNION ALL SELECT 'dim_review',                     COUNT(*) FROM dim_review
UNION ALL SELECT 'dim_payment_details',            COUNT(*) FROM dim_payment_details
UNION ALL SELECT 'dim_seller',                     COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_carrier',                    COUNT(*) FROM dim_carrier
UNION ALL SELECT 'dim_customer',                   COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_product',                    COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_dates',                      COUNT(*) FROM dim_dates
UNION ALL SELECT 'dim_geo',                        COUNT(*) FROM dim_geo
UNION ALL SELECT 'dim_category_name_translation',  COUNT(*) FROM dim_category_name_translation;

-- ---- Key integrity --------------------------------------------------------------
-- Primary key: no NULL part, no duplicate.
-- Integer keys (carrier_key, dates_id): also numbered 1..N without gaps.
-- dim_geo has no key (zip repeats) and is not part of this check.
CREATE OR REPLACE TEMP TABLE key_checks AS
SELECT table_name, key_columns, n, null_keys, distinct_keys, sequence_ok,
       CASE WHEN null_keys = 0 AND distinct_keys = n AND sequence_ok
            THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'dim_category_name_translation' AS table_name,
           'product_category_name' AS key_columns,
           COUNT(*) AS n,
           COUNT(*) FILTER (WHERE product_category_name IS NULL) AS null_keys,
           COUNT(DISTINCT product_category_name) AS distinct_keys,
           TRUE AS sequence_ok
    FROM dim_category_name_translation
    UNION ALL
    SELECT 'dim_product', 'product_id', COUNT(*),
           COUNT(*) FILTER (WHERE product_id IS NULL),
           COUNT(DISTINCT product_id), TRUE
    FROM dim_product
    UNION ALL
    SELECT 'dim_customer', 'customer_id', COUNT(*),
           COUNT(*) FILTER (WHERE customer_id IS NULL),
           COUNT(DISTINCT customer_id), TRUE
    FROM dim_customer
    UNION ALL
    SELECT 'dim_seller', 'seller_id', COUNT(*),
           COUNT(*) FILTER (WHERE seller_id IS NULL),
           COUNT(DISTINCT seller_id), TRUE
    FROM dim_seller
    UNION ALL
    SELECT 'dim_carrier', 'carrier_key (integer 1..N)', COUNT(*),
           COUNT(*) FILTER (WHERE carrier_key IS NULL),
           COUNT(DISTINCT carrier_key),
           (COUNT(*) = 0 OR (MIN(carrier_key) = 1 AND MAX(carrier_key) = COUNT(*)))
    FROM dim_carrier
    UNION ALL
    SELECT 'dim_dates', 'dates_id (integer 1..N)', COUNT(*),
           COUNT(*) FILTER (WHERE dates_id IS NULL),
           COUNT(DISTINCT dates_id),
           (COUNT(*) = 0 OR (MIN(dates_id) = 1 AND MAX(dates_id) = COUNT(*)))
    FROM dim_dates
    UNION ALL
    SELECT 'dim_review', 'review_id', COUNT(*),
           COUNT(*) FILTER (WHERE review_id IS NULL),
           COUNT(DISTINCT review_id), TRUE
    FROM dim_review
    UNION ALL
    SELECT 'dim_payment_details', 'order_id + payment_sequential', COUNT(*),
           COUNT(*) FILTER (WHERE order_id IS NULL OR payment_sequential IS NULL),
           (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, payment_sequential
                                    FROM dim_payment_details)),
           TRUE
    FROM dim_payment_details
    UNION ALL
    SELECT 'bridge_seller_carrier', 'seller_id + carrier_key', COUNT(*),
           COUNT(*) FILTER (WHERE seller_id IS NULL OR carrier_key IS NULL),
           (SELECT COUNT(*) FROM (SELECT DISTINCT seller_id, carrier_key
                                    FROM bridge_seller_carrier)),
           TRUE
    FROM bridge_seller_carrier
    UNION ALL
    SELECT 'fact_order_items', 'order_id + order_item_id', COUNT(*),
           COUNT(*) FILTER (WHERE order_id IS NULL OR order_item_id IS NULL),
           (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, order_item_id
                                    FROM fact_order_items)),
           TRUE
    FROM fact_order_items
);

SELECT 'Key integrity:' AS section;
SELECT * FROM key_checks ORDER BY table_name;

-- ---- Referential checks -----------------------------------------------------------
-- For every foreign key:
--   orphans: child rows whose key has no matching row in the parent table
--   nulls:   child rows with NULL where a NULL is not allowed
--   enforced -> declared as FOREIGN KEY in DuckDB; any problem is a FAIL
--   logical  -> not declared (parent column is not unique, so DuckDB cannot
--               enforce it); problems are only reported as a WARN
CREATE OR REPLACE TEMP TABLE fk_checks AS
WITH raw_checks AS (
    SELECT '[enforced] fact_order_items.product_id -> dim_product.product_id' AS fk_check,
           'enforced' AS kind,
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.product_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_product p WHERE p.product_id = c.product_id)) AS orphans,
           (SELECT COUNT(*) FROM fact_order_items WHERE product_id IS NULL) AS nulls
    UNION ALL
    SELECT '[enforced] fact_order_items.seller_id -> dim_seller.seller_id', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.seller_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_seller p WHERE p.seller_id = c.seller_id)),
           (SELECT COUNT(*) FROM fact_order_items WHERE seller_id IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.customer_id -> dim_customer.customer_id', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.customer_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_customer p WHERE p.customer_id = c.customer_id)),
           (SELECT COUNT(*) FROM fact_order_items WHERE customer_id IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.dates_id -> dim_dates.dates_id', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.dates_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_dates p WHERE p.dates_id = c.dates_id)),
           (SELECT COUNT(*) FROM fact_order_items WHERE dates_id IS NULL)
    UNION ALL
    -- review_id is nullable (an order without reviews): only orphans count
    SELECT '[enforced] fact_order_items.review_id -> dim_review.review_id (NULL allowed)',
           'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.review_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_review p WHERE p.review_id = c.review_id)),
           0
    UNION ALL
    SELECT '[enforced] fact_order_items.product_category_name -> dim_category_name_translation.product_category_name',
           'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.product_category_name IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_category_name_translation p
                                WHERE p.product_category_name = c.product_category_name)),
           (SELECT COUNT(*) FROM fact_order_items WHERE product_category_name IS NULL)
    UNION ALL
    SELECT '[enforced] bridge_seller_carrier.seller_id -> dim_seller.seller_id', 'enforced',
           (SELECT COUNT(*) FROM bridge_seller_carrier c
             WHERE c.seller_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_seller p WHERE p.seller_id = c.seller_id)),
           (SELECT COUNT(*) FROM bridge_seller_carrier WHERE seller_id IS NULL)
    UNION ALL
    SELECT '[enforced] bridge_seller_carrier.carrier_key -> dim_carrier.carrier_key', 'enforced',
           (SELECT COUNT(*) FROM bridge_seller_carrier c
             WHERE c.carrier_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_carrier p WHERE p.carrier_key = c.carrier_key)),
           (SELECT COUNT(*) FROM bridge_seller_carrier WHERE carrier_key IS NULL)
    UNION ALL
    -- zip is not unique in dim_geo (every file row is kept): logical FK only
    SELECT '[logical] dim_customer.customer_zip_code_prefix -> dim_geo.zip', 'logical',
           (SELECT COUNT(*) FROM dim_customer c
             WHERE c.customer_zip_code_prefix IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_geo g WHERE g.zip = c.customer_zip_code_prefix)),
           (SELECT COUNT(*) FROM dim_customer WHERE customer_zip_code_prefix IS NULL)
    UNION ALL
    -- JSON-only sellers have no zip code in the Olist CSV, so NULL is allowed here
    SELECT '[logical] dim_seller.seller_zip_code_prefix -> dim_geo.zip', 'logical',
           (SELECT COUNT(*) FROM dim_seller c
             WHERE c.seller_zip_code_prefix IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_geo g WHERE g.zip = c.seller_zip_code_prefix)),
           0
    UNION ALL
    -- order_id is not unique in the fact (many items per order): logical FK only
    SELECT '[logical] dim_payment_details.order_id -> fact_order_items.order_id', 'logical',
           (SELECT COUNT(*) FROM dim_payment_details c
             WHERE c.order_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM fact_order_items p WHERE p.order_id = c.order_id)),
           (SELECT COUNT(*) FROM dim_payment_details WHERE order_id IS NULL)
)
SELECT fk_check, kind, orphans, nulls,
       CASE WHEN orphans = 0 AND nulls = 0 THEN 'PASS'
            WHEN kind = 'enforced' THEN 'FAIL'
            ELSE 'WARN' END AS status
FROM raw_checks;

SELECT 'Referential checks (child rows without a match in the parent):' AS section;
SELECT fk_check, orphans, nulls, status FROM fk_checks ORDER BY fk_check;

-- ---- Reconciliation -----------------------------------------------------------------
-- Source vs warehouse: every source row is either loaded or explained.
-- DIFF is not an error: it means rows were left out (see the load messages above).
-- The "distinct ..." lines compare unique keys and must match exactly (FAIL if not).
CREATE OR REPLACE TEMP TABLE recon_checks AS
SELECT 'stg_geolocation -> dim_geo' AS reconciliation,
       (SELECT COUNT(*) FROM stg_geolocation) AS source_rows,
       (SELECT COUNT(*) FROM dim_geo)         AS loaded_rows
UNION ALL
SELECT 'stg_customers -> dim_customer',
       (SELECT COUNT(*) FROM stg_customers), (SELECT COUNT(*) FROM dim_customer)
UNION ALL
SELECT 'products -> dim_product',
       (SELECT COUNT(*) FROM products), (SELECT COUNT(*) FROM dim_product)
UNION ALL
SELECT 'order_dates -> dim_dates',
       (SELECT COUNT(*) FROM order_dates), (SELECT COUNT(*) FROM dim_dates)
UNION ALL
SELECT 'stg_payments -> dim_payment_details',
       (SELECT COUNT(*) FROM stg_payments), (SELECT COUNT(*) FROM dim_payment_details)
UNION ALL
-- DIFF here = repeated review_id (one row kept per review_id) or NULL review_id
SELECT 'stg_reviews -> dim_review',
       (SELECT COUNT(*) FROM stg_reviews), (SELECT COUNT(*) FROM dim_review)
UNION ALL
SELECT 'stg_order_items -> fact_order_items',
       (SELECT COUNT(*) FROM stg_order_items), (SELECT COUNT(*) FROM fact_order_items)
UNION ALL
-- Every seller found in either source must be in dim_seller
SELECT 'distinct sellers (CSV + JSON) -> dim_seller',
       (SELECT COUNT(*) FROM (
            SELECT seller_id FROM stg_sellers WHERE seller_id IS NOT NULL
            UNION
            SELECT seller_id FROM sellers_clean WHERE seller_id IS NOT NULL)),
       (SELECT COUNT(*) FROM dim_seller)
UNION ALL
-- Every review_id of the file must be in dim_review
SELECT 'distinct review_id (stg_reviews) -> dim_review',
       (SELECT COUNT(DISTINCT review_id) FROM stg_reviews),
       (SELECT COUNT(*) FROM dim_review)
UNION ALL
-- Every category (translation file + products) must be in the translation dim
SELECT 'distinct categories (file + products) -> dim_category_name_translation',
       (SELECT COUNT(*) FROM (
            SELECT product_category_name FROM stg_translation
             WHERE product_category_name IS NOT NULL
            UNION
            SELECT product_category_name FROM products
             WHERE product_category_name IS NOT NULL)),
       (SELECT COUNT(*) FROM dim_category_name_translation);

SELECT 'Reconciliation (source rows vs loaded rows):' AS section;
SELECT reconciliation, source_rows, loaded_rows,
       CASE WHEN source_rows = loaded_rows THEN 'PASS'
            WHEN reconciliation LIKE 'distinct %' THEN 'FAIL'
            ELSE 'DIFF' END AS status
FROM recon_checks;

-- ---- Final result ---------------------------------------------------------------------
-- FAIL counts: key checks, enforced FK checks, and the "distinct ..." reconciliations.
-- WARN and DIFF lines are informational. On any FAIL the script stops with an error.
SELECT CASE
         WHEN fails = 0
         THEN 'RESULT: all key and referential checks passed (WARN/DIFF lines are informational).'
         ELSE error('RESULT: ' || fails || ' check(s) FAILED - see the check tables above.')
       END AS result
FROM (
    SELECT (SELECT COUNT(*) FROM key_checks WHERE status = 'FAIL')
         + (SELECT COUNT(*) FROM fk_checks WHERE status = 'FAIL')
         + (SELECT COUNT(*) FROM recon_checks
             WHERE reconciliation LIKE 'distinct %'
               AND source_rows <> loaded_rows) AS fails
);