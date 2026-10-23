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
-- Grain of the fact table: one row per order item (order_id + order_item_id).
--
-- Tables built (children are dropped first, parents are built first):
--   dim_category_translation, dim_geolocation, dim_date, dim_product, dim_customer,
--   dim_carrier, dim_seller, bridge_seller_carrier, dim_delivery, dim_review,
--   dim_payment, fact_order_items
--
-- Surrogate keys are meaningless integers 1..N generated with
-- ROW_NUMBER() OVER (ORDER BY <natural key>), so a re-run on the same data
-- produces exactly the same keys. The natural key stays in the dimension
-- (UNIQUE) so every row can be traced back to the source.
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
             ('order_delivery_dates')) t(table_name)
LEFT JOIN information_schema.tables i ON i.table_name = t.table_name;

SELECT CASE
         WHEN COUNT(*) = 4 THEN 'prerequisites OK'
         ELSE error('Missing tables from profiling.sql. Run profiling.sql first, '
                    || 'then run this script again.')
       END AS prerequisites
FROM information_schema.tables
WHERE table_name IN ('products', 'sellers_clean', 'orders_clean', 'order_delivery_dates');

-- Children first, so they can be dropped without breaking FK dependencies
DROP TABLE IF EXISTS fact_order_items;
DROP TABLE IF EXISTS bridge_seller_carrier;
DROP TABLE IF EXISTS dim_review;
DROP TABLE IF EXISTS dim_payment;
DROP TABLE IF EXISTS dim_seller;
DROP TABLE IF EXISTS dim_carrier;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_delivery;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_geolocation;
DROP TABLE IF EXISTS dim_category_translation;


-- ============================================================================
-- STEP 1 - STAGING (CSVs that are not already cleaned in the database)
-- Zip prefixes are forced to VARCHAR (same in every table) so they join
-- consistently and keep their leading zeros.
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

-- ---- dim_category_translation ------------------------------------------------
-- Translation file + categories that exist in products but not in the file.
SELECT '=== BUILDING: dim_category_translation ===' AS section;

CREATE TABLE dim_category_translation (
    category_key INTEGER PRIMARY KEY,
    product_category_name VARCHAR NOT NULL UNIQUE,
    product_category_name_english VARCHAR
);

SELECT 'Categories in products that were missing from the translation file:' AS section;
SELECT DISTINCT product_category_name
FROM products
WHERE product_category_name IS NOT NULL
  AND product_category_name NOT IN (SELECT product_category_name FROM stg_translation)
ORDER BY 1;

-- 'sem categoria' -> 'uncategorized'; any other missing category stays NULL
INSERT INTO dim_category_translation
SELECT CAST(ROW_NUMBER() OVER (ORDER BY product_category_name) AS INTEGER), *
FROM (
    SELECT product_category_name, product_category_name_english
    FROM stg_translation
    UNION ALL
    SELECT DISTINCT
        product_category_name,
        CASE WHEN product_category_name = 'sem categoria' THEN 'uncategorized' END
    FROM products
    WHERE product_category_name IS NOT NULL
      AND product_category_name NOT IN (SELECT product_category_name FROM stg_translation)
);

SELECT COUNT(*) AS dim_category_translation_rows FROM dim_category_translation;


-- ---- dim_geolocation ----------------------------------------------------------
-- One row per zip prefix, plus stub rows for zips used by customers/sellers.
SELECT '=== BUILDING: dim_geolocation ===' AS section;

CREATE TABLE dim_geolocation (
    geolocation_key INTEGER PRIMARY KEY,
    zip VARCHAR NOT NULL UNIQUE,
    lat DOUBLE,
    lng DOUBLE,
    geo_city VARCHAR,
    geo_state VARCHAR
);

-- Real rows: collapse the many rows per zip (average coordinates, most
-- frequent city/state). Stub rows (NULL lat/lng/city/state): zips that
-- customers/sellers use but the geolocation file does not have.
INSERT INTO dim_geolocation
WITH real_zips AS (
    SELECT
        geolocation_zip_code_prefix AS zip,
        AVG(geolocation_lat) AS lat,
        AVG(geolocation_lng) AS lng,
        mode(geolocation_city) AS geo_city,
        mode(geolocation_state) AS geo_state
    FROM stg_geolocation
    WHERE geolocation_zip_code_prefix IS NOT NULL
      AND TRIM(geolocation_zip_code_prefix) <> ''
    GROUP BY geolocation_zip_code_prefix
),
stub_zips AS (
    SELECT DISTINCT zip
    FROM (
        SELECT customer_zip_code_prefix AS zip FROM stg_customers
        UNION
        SELECT seller_zip_code_prefix AS zip FROM stg_sellers
    )
    WHERE zip IS NOT NULL
      AND TRIM(zip) <> ''
      AND zip NOT IN (SELECT zip FROM real_zips)
),
all_zips AS (
    SELECT * FROM real_zips
    UNION ALL
    SELECT zip, CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE),
           CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR)
    FROM stub_zips
)
SELECT CAST(ROW_NUMBER() OVER (ORDER BY zip) AS INTEGER), * FROM all_zips;

SELECT COUNT(*) - COUNT(*) FILTER (WHERE lat IS NULL AND lng IS NULL) AS zips_from_geolocation_file,
       COUNT(*) FILTER (WHERE lat IS NULL AND lng IS NULL)            AS stub_rows_added,
       COUNT(*)                                                       AS dim_geolocation_rows
FROM dim_geolocation;


-- ---- dim_date -------------------------------------------------------------------
-- One row per calendar day, from 1 January of the first purchase year to
-- 31 December of the last purchase year (no gaps, so every date joins).
SELECT '=== BUILDING: dim_date ===' AS section;

CREATE TABLE dim_date (
    date_key INTEGER PRIMARY KEY,
    full_date DATE NOT NULL UNIQUE,
    calendar_year INTEGER NOT NULL,
    calendar_quarter INTEGER NOT NULL,
    calendar_month INTEGER NOT NULL,
    month_name VARCHAR NOT NULL,
    year_month VARCHAR NOT NULL,          -- 'YYYY-MM'
    day_of_month INTEGER NOT NULL,
    iso_day_of_week INTEGER NOT NULL,     -- 1 = Monday ... 7 = Sunday
    day_name VARCHAR NOT NULL,
    is_weekend BOOLEAN NOT NULL
);

INSERT INTO dim_date
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY d) AS INTEGER),
    d,
    year(d),
    quarter(d),
    month(d),
    monthname(d),
    strftime(d, '%Y-%m'),
    day(d),
    isodow(d),
    dayname(d),
    isodow(d) >= 6
FROM (
    SELECT CAST(UNNEST(generate_series(
               CAST(make_date(y0, 1, 1) AS TIMESTAMP),
               CAST(make_date(y1, 12, 31) AS TIMESTAMP),
               INTERVAL 1 DAY)) AS DATE) AS d
    FROM (
        SELECT year(MIN(order_purchase_timestamp)) AS y0,
               year(MAX(order_purchase_timestamp)) AS y1
        FROM orders_clean
    )
);

SELECT MIN(full_date) AS first_date, MAX(full_date) AS last_date,
       COUNT(*) AS dim_date_rows
FROM dim_date;


-- ---- dim_product ----------------------------------------------------------------
-- Products are already cleaned: 'sem categoria' was applied by profiling.sql.
SELECT '=== BUILDING: dim_product ===' AS section;

SELECT COUNT(*) AS products_with_null_category_should_be_0
FROM products WHERE product_category_name IS NULL;

CREATE TABLE dim_product (
    product_key INTEGER PRIMARY KEY,
    product_id VARCHAR NOT NULL UNIQUE,
    category_key INTEGER NOT NULL
        REFERENCES dim_category_translation (category_key),
    product_name_lenght INTEGER,
    product_description_lenght INTEGER,
    product_photos_qty INTEGER,
    product_weight_g INTEGER,
    product_length_cm INTEGER,
    product_height_cm INTEGER,
    product_width_cm INTEGER
);

-- The surrogate key of the category is looked up through its natural key
INSERT INTO dim_product
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY p.product_id) AS INTEGER),
    p.product_id,
    c.category_key,
    p.product_name_lenght,
    p.product_description_lenght,
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM products p
JOIN dim_category_translation c
  ON p.product_category_name = c.product_category_name;

SELECT (SELECT COUNT(*) FROM products)     AS products_in_source,
       (SELECT COUNT(*) FROM dim_product)  AS products_loaded,
       (SELECT COUNT(*) FROM products) - (SELECT COUNT(*) FROM dim_product) AS skipped;


-- ---- dim_customer ---------------------------------------------------------------
SELECT '=== BUILDING: dim_customer ===' AS section;

CREATE TABLE dim_customer (
    customer_key INTEGER PRIMARY KEY,
    customer_id VARCHAR NOT NULL UNIQUE,
    customer_unique_id VARCHAR,
    geolocation_key INTEGER NOT NULL
        REFERENCES dim_geolocation (geolocation_key),
    customer_city VARCHAR,
    customer_state VARCHAR
);

INSERT INTO dim_customer
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY c.customer_id) AS INTEGER),
    c.customer_id,
    c.customer_unique_id,
    g.geolocation_key,
    c.customer_city,
    c.customer_state
FROM stg_customers c
JOIN dim_geolocation g ON c.customer_zip_code_prefix = g.zip;

SELECT (SELECT COUNT(*) FROM stg_customers) AS customers_in_file,
       (SELECT COUNT(*) FROM dim_customer)  AS customers_loaded,
       (SELECT COUNT(*) FROM stg_customers) - (SELECT COUNT(*) FROM dim_customer) AS skipped;


-- ---- dim_carrier ----------------------------------------------------------------
-- Small lookup of carriers (snowflaked out of the seller dimension).
SELECT '=== BUILDING: dim_carrier ===' AS section;

CREATE TABLE dim_carrier (
    carrier_key INTEGER PRIMARY KEY,
    carrier_name VARCHAR NOT NULL UNIQUE
);

INSERT INTO dim_carrier
SELECT CAST(ROW_NUMBER() OVER (ORDER BY carrier_name) AS INTEGER), carrier_name
FROM (
    SELECT DISTINCT TRIM(carrier_name) AS carrier_name
    FROM sellers_clean
    WHERE carrier_name IS NOT NULL AND TRIM(carrier_name) <> ''
    UNION
    SELECT 'sem transportadora especificada'
);

SELECT * FROM dim_carrier ORDER BY carrier_key;


-- ---- dim_seller -----------------------------------------------------------------
-- ONE ROW PER SELLER. Union of the sellers from the Olist CSV and the JSON profiles.
--  - JSON fields (tier, joined_on, handling_days, ...) are flattened into the row
--  - no handling days -> 0
--  - any other missing field -> NULL
--  - the list of carriers goes to bridge_seller_carrier (a seller has several)
SELECT '=== BUILDING: dim_seller ===' AS section;

-- sellers_clean has one row per carrier, so the seller-level fields repeat.
-- Confirm they really are identical before collapsing them (should be 0).
SELECT COUNT(*) AS sellers_whose_json_fields_differ_between_carrier_rows
FROM (
    SELECT seller_id
    FROM (
        SELECT DISTINCT seller_id, tier, updated_at, joined_on,
                        email, phone, shipping_time
        FROM sellers_clean
        WHERE seller_id IS NOT NULL
    )
    GROUP BY seller_id
    HAVING COUNT(*) > 1
);

CREATE TABLE dim_seller (
    seller_key INTEGER PRIMARY KEY,
    seller_id VARCHAR NOT NULL UNIQUE,
    geolocation_key INTEGER REFERENCES dim_geolocation (geolocation_key),
    seller_city VARCHAR,
    seller_state VARCHAR,
    tier VARCHAR,
    joined_on DATE,
    handling_days INTEGER NOT NULL,
    updated_at TIMESTAMP,
    email VARCHAR,
    phone VARCHAR
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
    CAST(ROW_NUMBER() OVER (ORDER BY a.seller_id) AS INTEGER),
    a.seller_id,
    g.geolocation_key,
    s.seller_city,
    s.seller_state,
    j.tier,
    j.joined_on,
    COALESCE(j.shipping_time, 0),
    j.updated_at,
    j.email,
    j.phone
FROM all_ids a
LEFT JOIN stg_sellers s ON a.seller_id = s.seller_id
LEFT JOIN json_one j ON a.seller_id = j.seller_id
LEFT JOIN dim_geolocation g ON s.seller_zip_code_prefix = g.zip;

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
    seller_key INTEGER NOT NULL REFERENCES dim_seller (seller_key),
    carrier_key INTEGER NOT NULL REFERENCES dim_carrier (carrier_key),
    PRIMARY KEY (seller_key, carrier_key)
);

INSERT INTO bridge_seller_carrier
SELECT DISTINCT s.seller_key, c.carrier_key
FROM sellers_clean sc
JOIN dim_seller s ON sc.seller_id = s.seller_id
JOIN dim_carrier c ON TRIM(sc.carrier_name) = c.carrier_name;

CREATE OR REPLACE TEMP TABLE bridge_rows_with_carrier AS
SELECT COUNT(*) AS n FROM bridge_seller_carrier;

-- Sellers that ended up with no carrier row get the placeholder carrier
INSERT INTO bridge_seller_carrier
SELECT s.seller_key,
       (SELECT carrier_key FROM dim_carrier
         WHERE carrier_name = 'sem transportadora especificada')
FROM dim_seller s
WHERE NOT EXISTS (
    SELECT 1 FROM bridge_seller_carrier b WHERE b.seller_key = s.seller_key
);

SELECT (SELECT COUNT(*) FROM bridge_seller_carrier) AS bridge_rows,
       (SELECT COUNT(*) FROM bridge_seller_carrier)
         - (SELECT n FROM bridge_rows_with_carrier) AS sellers_given_placeholder_carrier;


-- ---- dim_delivery ---------------------------------------------------------------
-- Delivery dates (built by profiling.sql) with a surrogate key.
SELECT '=== BUILDING: dim_delivery ===' AS section;

CREATE TABLE dim_delivery (
    delivery_key INTEGER PRIMARY KEY,
    delivery_id VARCHAR NOT NULL UNIQUE,
    order_delivered_carrier_date TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

INSERT INTO dim_delivery
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY delivery_id) AS INTEGER),
    delivery_id,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date
FROM order_delivery_dates;

SELECT COUNT(*) AS dim_delivery_rows FROM dim_delivery;


-- ---- dim_review -----------------------------------------------------------------
-- Natural key = (review_id, order_id), because review_id alone can repeat.
SELECT '=== BUILDING: dim_review ===' AS section;

SELECT COUNT(*) AS review_id_values_that_appear_more_than_once
FROM (
    SELECT review_id FROM stg_reviews GROUP BY review_id HAVING COUNT(*) > 1
);

CREATE TABLE dim_review (
    review_key INTEGER PRIMARY KEY,
    review_id VARCHAR NOT NULL,
    order_id VARCHAR NOT NULL,
    review_score INTEGER,
    review_comment_title VARCHAR,
    review_comment_message VARCHAR,
    review_creation_date TIMESTAMP,
    review_answer_timestamp TIMESTAMP,
    UNIQUE (review_id, order_id)
);

-- If a (review_id, order_id) pair is repeated, keep the latest answer
INSERT INTO dim_review
SELECT CAST(ROW_NUMBER() OVER (ORDER BY review_id, order_id) AS INTEGER), *
FROM (
    SELECT
        review_id,
        order_id,
        review_score,
        review_comment_title,
        review_comment_message,
        review_creation_date,
        review_answer_timestamp
    FROM stg_reviews
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY review_id, order_id
        ORDER BY review_answer_timestamp DESC NULLS LAST
    ) = 1
);

SELECT (SELECT COUNT(*) FROM stg_reviews) AS rows_in_file,
       (SELECT COUNT(*) FROM dim_review)  AS rows_loaded,
       (SELECT COUNT(*) FROM stg_reviews) - (SELECT COUNT(*) FROM dim_review)
           AS removed_repeated_review_id_plus_order_id;


-- ---- dim_payment ----------------------------------------------------------------
-- Natural key = (order_id, payment_sequential): an order can have several payments.
SELECT '=== BUILDING: dim_payment ===' AS section;

CREATE TABLE dim_payment (
    payment_key INTEGER PRIMARY KEY,
    order_id VARCHAR NOT NULL,
    payment_sequential INTEGER NOT NULL,
    payment_type VARCHAR,
    payment_installments INTEGER,
    payment_value DOUBLE,
    UNIQUE (order_id, payment_sequential)
);

INSERT INTO dim_payment
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY order_id, payment_sequential) AS INTEGER),
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
FROM stg_payments;

SELECT COUNT(*) AS dim_payment_rows FROM dim_payment;


-- ============================================================================
-- STEP 3 - FACT TABLE
-- Grain: one row per order item.
-- Natural key (order_id, order_item_id) = degenerate dimension, kept in the fact.
-- Every other reference is a surrogate key looked up in its dimension.
-- Measures: price, freight_cost.
-- ============================================================================
SELECT '=== BUILDING: fact_order_items ===' AS section;

CREATE TABLE fact_order_items (
    order_item_key INTEGER PRIMARY KEY,
    order_id VARCHAR NOT NULL,
    order_item_id INTEGER NOT NULL,
    product_key INTEGER NOT NULL REFERENCES dim_product (product_key),
    customer_key INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    seller_key INTEGER NOT NULL REFERENCES dim_seller (seller_key),
    delivery_key INTEGER NOT NULL REFERENCES dim_delivery (delivery_key),
    category_key INTEGER NOT NULL
        REFERENCES dim_category_translation (category_key),
    purchase_date_key INTEGER NOT NULL REFERENCES dim_date (date_key),
    order_purchase_timestamp TIMESTAMP,
    price DOUBLE,
    freight_cost DOUBLE,
    UNIQUE (order_id, order_item_id)
);

-- Inner joins: an item whose order/product/customer/seller does not exist
-- cannot get a valid key, so it is left out (and reported below).
INSERT INTO fact_order_items
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY oi.order_id, oi.order_item_id) AS INTEGER),
    oi.order_id,
    oi.order_item_id,
    p.product_key,
    c.customer_key,
    s.seller_key,
    d.delivery_key,
    p.category_key,
    dd.date_key,
    o.order_purchase_timestamp,
    oi.price,
    oi.freight_value
FROM stg_order_items oi
JOIN orders_clean o ON oi.order_id = o.order_id
JOIN dim_product p ON oi.product_id = p.product_id
JOIN dim_customer c ON o.customer_id = c.customer_id
JOIN dim_seller s ON oi.seller_id = s.seller_id
JOIN dim_delivery d ON o.delivery_id = d.delivery_id
JOIN dim_date dd ON CAST(o.order_purchase_timestamp AS DATE) = dd.full_date;

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
                     AND c.customer_id IS NULL)  AS customer_not_found,
    COUNT(*) FILTER (WHERE o.order_id IS NOT NULL
                     AND dd.date_key IS NULL)    AS purchase_date_not_found
FROM stg_order_items oi
LEFT JOIN orders_clean o ON oi.order_id = o.order_id
LEFT JOIN dim_product p ON oi.product_id = p.product_id
LEFT JOIN dim_seller s ON oi.seller_id = s.seller_id
LEFT JOIN dim_customer c ON o.customer_id = c.customer_id
LEFT JOIN dim_date dd ON CAST(o.order_purchase_timestamp AS DATE) = dd.full_date
WHERE NOT EXISTS (
    SELECT 1 FROM fact_order_items f
    WHERE f.order_id = oi.order_id
      AND f.order_item_id = oi.order_item_id
);


-- ============================================================================
-- STEP 4 - VERIFICATION (key and referential checks)
-- ============================================================================
SELECT '=== VERIFICATION ===' AS section;

SELECT 'Row counts:' AS section;
SELECT 'fact_order_items' AS table_name, COUNT(*) AS row_count FROM fact_order_items
UNION ALL SELECT 'bridge_seller_carrier',     COUNT(*) FROM bridge_seller_carrier
UNION ALL SELECT 'dim_review',                COUNT(*) FROM dim_review
UNION ALL SELECT 'dim_payment',               COUNT(*) FROM dim_payment
UNION ALL SELECT 'dim_seller',                COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_carrier',               COUNT(*) FROM dim_carrier
UNION ALL SELECT 'dim_customer',              COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_product',               COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_delivery',              COUNT(*) FROM dim_delivery
UNION ALL SELECT 'dim_date',                  COUNT(*) FROM dim_date
UNION ALL SELECT 'dim_geolocation',           COUNT(*) FROM dim_geolocation
UNION ALL SELECT 'dim_category_translation',  COUNT(*) FROM dim_category_translation;

-- ---- Key integrity --------------------------------------------------------------
-- Surrogate key: no NULL, no duplicate, numbered 1..N without gaps.
-- Natural key:   no duplicate (one row per real-world entity).
CREATE OR REPLACE TEMP TABLE key_checks AS
WITH raw_checks AS (
    SELECT 'dim_category_translation' AS table_name,
           COUNT(*) AS n,
           COUNT(*) FILTER (WHERE category_key IS NULL) AS sk_nulls,
           COUNT(DISTINCT category_key) AS sk_distinct,
           MIN(category_key) AS sk_min, MAX(category_key) AS sk_max,
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_category_translation
                                  GROUP BY product_category_name HAVING COUNT(*) > 1))
               AS nk_duplicates
    FROM dim_category_translation
    UNION ALL
    SELECT 'dim_geolocation', COUNT(*),
           COUNT(*) FILTER (WHERE geolocation_key IS NULL),
           COUNT(DISTINCT geolocation_key), MIN(geolocation_key), MAX(geolocation_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_geolocation
                                  GROUP BY zip HAVING COUNT(*) > 1))
    FROM dim_geolocation
    UNION ALL
    SELECT 'dim_date', COUNT(*),
           COUNT(*) FILTER (WHERE date_key IS NULL),
           COUNT(DISTINCT date_key), MIN(date_key), MAX(date_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_date
                                  GROUP BY full_date HAVING COUNT(*) > 1))
    FROM dim_date
    UNION ALL
    SELECT 'dim_product', COUNT(*),
           COUNT(*) FILTER (WHERE product_key IS NULL),
           COUNT(DISTINCT product_key), MIN(product_key), MAX(product_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_product
                                  GROUP BY product_id HAVING COUNT(*) > 1))
    FROM dim_product
    UNION ALL
    SELECT 'dim_customer', COUNT(*),
           COUNT(*) FILTER (WHERE customer_key IS NULL),
           COUNT(DISTINCT customer_key), MIN(customer_key), MAX(customer_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_customer
                                  GROUP BY customer_id HAVING COUNT(*) > 1))
    FROM dim_customer
    UNION ALL
    SELECT 'dim_carrier', COUNT(*),
           COUNT(*) FILTER (WHERE carrier_key IS NULL),
           COUNT(DISTINCT carrier_key), MIN(carrier_key), MAX(carrier_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_carrier
                                  GROUP BY carrier_name HAVING COUNT(*) > 1))
    FROM dim_carrier
    UNION ALL
    SELECT 'dim_seller', COUNT(*),
           COUNT(*) FILTER (WHERE seller_key IS NULL),
           COUNT(DISTINCT seller_key), MIN(seller_key), MAX(seller_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_seller
                                  GROUP BY seller_id HAVING COUNT(*) > 1))
    FROM dim_seller
    UNION ALL
    SELECT 'dim_delivery', COUNT(*),
           COUNT(*) FILTER (WHERE delivery_key IS NULL),
           COUNT(DISTINCT delivery_key), MIN(delivery_key), MAX(delivery_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_delivery
                                  GROUP BY delivery_id HAVING COUNT(*) > 1))
    FROM dim_delivery
    UNION ALL
    SELECT 'dim_review', COUNT(*),
           COUNT(*) FILTER (WHERE review_key IS NULL),
           COUNT(DISTINCT review_key), MIN(review_key), MAX(review_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_review
                                  GROUP BY review_id, order_id HAVING COUNT(*) > 1))
    FROM dim_review
    UNION ALL
    SELECT 'dim_payment', COUNT(*),
           COUNT(*) FILTER (WHERE payment_key IS NULL),
           COUNT(DISTINCT payment_key), MIN(payment_key), MAX(payment_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM dim_payment
                                  GROUP BY order_id, payment_sequential HAVING COUNT(*) > 1))
    FROM dim_payment
    UNION ALL
    SELECT 'fact_order_items', COUNT(*),
           COUNT(*) FILTER (WHERE order_item_key IS NULL),
           COUNT(DISTINCT order_item_key), MIN(order_item_key), MAX(order_item_key),
           (SELECT COUNT(*) FROM (SELECT 1 FROM fact_order_items
                                  GROUP BY order_id, order_item_id HAVING COUNT(*) > 1))
    FROM fact_order_items
)
SELECT table_name,
       (sk_nulls = 0 AND sk_distinct = n
        AND (n = 0 OR (sk_min = 1 AND sk_max = n))) AS surrogate_key_ok,
       nk_duplicates AS duplicated_natural_keys,
       CASE WHEN sk_nulls = 0 AND sk_distinct = n
                 AND (n = 0 OR (sk_min = 1 AND sk_max = n))
                 AND nk_duplicates = 0
            THEN 'PASS' ELSE 'FAIL' END AS status
FROM raw_checks;

SELECT 'Key integrity:' AS section;
SELECT * FROM key_checks ORDER BY table_name;

-- ---- Referential checks -----------------------------------------------------------
-- For every foreign key:
--   orphans: child rows whose key has no matching row in the parent table
--   nulls:   child rows with NULL where a NULL is not allowed
--   enforced -> declared as FOREIGN KEY in DuckDB; any problem is a FAIL
--   logical  -> not declared (parent column is not unique / not a key);
--               orphans are only reported as a WARN
CREATE OR REPLACE TEMP TABLE fk_checks AS
WITH raw_checks AS (
    SELECT '[enforced] fact_order_items.product_key -> dim_product.product_key' AS fk_check,
           'enforced' AS kind,
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.product_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_product p WHERE p.product_key = c.product_key)) AS orphans,
           (SELECT COUNT(*) FROM fact_order_items WHERE product_key IS NULL) AS nulls
    UNION ALL
    SELECT '[enforced] fact_order_items.customer_key -> dim_customer.customer_key', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.customer_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_customer p WHERE p.customer_key = c.customer_key)),
           (SELECT COUNT(*) FROM fact_order_items WHERE customer_key IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.seller_key -> dim_seller.seller_key', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.seller_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_seller p WHERE p.seller_key = c.seller_key)),
           (SELECT COUNT(*) FROM fact_order_items WHERE seller_key IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.delivery_key -> dim_delivery.delivery_key', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.delivery_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_delivery p WHERE p.delivery_key = c.delivery_key)),
           (SELECT COUNT(*) FROM fact_order_items WHERE delivery_key IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.category_key -> dim_category_translation.category_key',
           'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.category_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_category_translation p
                                WHERE p.category_key = c.category_key)),
           (SELECT COUNT(*) FROM fact_order_items WHERE category_key IS NULL)
    UNION ALL
    SELECT '[enforced] fact_order_items.purchase_date_key -> dim_date.date_key', 'enforced',
           (SELECT COUNT(*) FROM fact_order_items c
             WHERE c.purchase_date_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_date p WHERE p.date_key = c.purchase_date_key)),
           (SELECT COUNT(*) FROM fact_order_items WHERE purchase_date_key IS NULL)
    UNION ALL
    SELECT '[enforced] dim_product.category_key -> dim_category_translation.category_key',
           'enforced',
           (SELECT COUNT(*) FROM dim_product c
             WHERE c.category_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_category_translation p
                                WHERE p.category_key = c.category_key)),
           (SELECT COUNT(*) FROM dim_product WHERE category_key IS NULL)
    UNION ALL
    SELECT '[enforced] dim_customer.geolocation_key -> dim_geolocation.geolocation_key',
           'enforced',
           (SELECT COUNT(*) FROM dim_customer c
             WHERE c.geolocation_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_geolocation p
                                WHERE p.geolocation_key = c.geolocation_key)),
           (SELECT COUNT(*) FROM dim_customer WHERE geolocation_key IS NULL)
    UNION ALL
    -- JSON-only sellers have no zip code in the Olist CSV, so NULL is allowed here
    SELECT '[enforced] dim_seller.geolocation_key -> dim_geolocation.geolocation_key',
           'enforced',
           (SELECT COUNT(*) FROM dim_seller c
             WHERE c.geolocation_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_geolocation p
                                WHERE p.geolocation_key = c.geolocation_key)),
           0
    UNION ALL
    SELECT '[enforced] bridge_seller_carrier.seller_key -> dim_seller.seller_key', 'enforced',
           (SELECT COUNT(*) FROM bridge_seller_carrier c
             WHERE c.seller_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_seller p WHERE p.seller_key = c.seller_key)),
           (SELECT COUNT(*) FROM bridge_seller_carrier WHERE seller_key IS NULL)
    UNION ALL
    SELECT '[enforced] bridge_seller_carrier.carrier_key -> dim_carrier.carrier_key', 'enforced',
           (SELECT COUNT(*) FROM bridge_seller_carrier c
             WHERE c.carrier_key IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dim_carrier p WHERE p.carrier_key = c.carrier_key)),
           (SELECT COUNT(*) FROM bridge_seller_carrier WHERE carrier_key IS NULL)
    UNION ALL
    -- order_id is a degenerate dimension (many items per order): not unique in the fact
    SELECT '[logical] dim_review.order_id -> fact_order_items.order_id', 'logical',
           (SELECT COUNT(*) FROM dim_review c
             WHERE c.order_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM fact_order_items p WHERE p.order_id = c.order_id)),
           (SELECT COUNT(*) FROM dim_review WHERE order_id IS NULL)
    UNION ALL
    SELECT '[logical] dim_payment.order_id -> fact_order_items.order_id', 'logical',
           (SELECT COUNT(*) FROM dim_payment c
             WHERE c.order_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM fact_order_items p WHERE p.order_id = c.order_id)),
           (SELECT COUNT(*) FROM dim_payment WHERE order_id IS NULL)
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
CREATE OR REPLACE TEMP TABLE recon_checks AS
SELECT 'stg_customers -> dim_customer' AS reconciliation,
       (SELECT COUNT(*) FROM stg_customers) AS source_rows,
       (SELECT COUNT(*) FROM dim_customer)  AS loaded_rows
UNION ALL
SELECT 'products -> dim_product',
       (SELECT COUNT(*) FROM products), (SELECT COUNT(*) FROM dim_product)
UNION ALL
SELECT 'order_delivery_dates -> dim_delivery',
       (SELECT COUNT(*) FROM order_delivery_dates), (SELECT COUNT(*) FROM dim_delivery)
UNION ALL
SELECT 'stg_payments -> dim_payment',
       (SELECT COUNT(*) FROM stg_payments), (SELECT COUNT(*) FROM dim_payment)
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
       (SELECT COUNT(*) FROM dim_seller);

SELECT 'Reconciliation (source rows vs loaded rows):' AS section;
SELECT reconciliation, source_rows, loaded_rows,
       CASE WHEN source_rows = loaded_rows THEN 'PASS'
            WHEN reconciliation LIKE 'distinct sellers%' THEN 'FAIL'
            ELSE 'DIFF' END AS status
FROM recon_checks;

-- ---- Final result ---------------------------------------------------------------------
-- FAIL counts: key checks, enforced FK checks, and the seller reconciliation.
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
             WHERE reconciliation LIKE 'distinct sellers%'
               AND source_rows <> loaded_rows) AS fails
);