/*
Project: Sales Performance Analysis
File: 04_reporting_model.sql
Purpose: Build the Stage 3 reporting model from clean transactions.
Run from project root. Manual execution and export are documented in README.md.
Implementation note: AI assists with this SQL; each material model decision is
reviewed and approved by the user before execution.
*/

-- @step classify_sales_population
BEGIN TRANSACTION;

-- Mỗi dòng clean thuộc population nào theo quyết định Stage 2?
CREATE OR REPLACE TEMP VIEW sales_population_classification AS
WITH normalized_lines AS (
    SELECT
        *,
        UPPER(TRIM(InvoiceNo)) AS normalized_invoice_no,
        UPPER(TRIM(StockCode)) AS product_key
    FROM clean_transactions
)
SELECT
    *,
    CASE
        WHEN normalized_invoice_no IS NULL
            THEN 'excluded_missing_invoice'
        WHEN normalized_invoice_no LIKE 'C%'
            THEN 'excluded_cancellation'
        WHEN Quantity IS NULL OR Quantity <= 0
            THEN 'excluded_non_positive_quantity'
        WHEN UnitPrice IS NULL OR UnitPrice <= 0
            THEN 'excluded_non_positive_unit_price'
        WHEN product_key IS NULL
            THEN 'excluded_missing_product_code'
        WHEN product_key IN (
            'AMAZONFEE',
            'B',
            'BANK CHARGES',
            'C2',
            'DOT',
            'M',
            'POST',
            'S'
        )
        OR product_key LIKE 'GIFT!_%' ESCAPE '!'
            THEN 'excluded_non_merchandise'
        ELSE 'accepted_sale'
    END AS population_status
FROM normalized_lines;

-- @step create_accepted_sales_lines
-- Dòng bán nào được giữ, với những trường nào để truy vết và tạo model?
CREATE OR REPLACE TABLE accepted_sales_lines AS
SELECT
    source_row_number,
    InvoiceNo,
    StockCode,
    product_key,
    Description,
    Quantity,
    InvoiceDate,
    CAST(InvoiceDate AS DATE) AS transaction_date,
    UnitPrice,
    Quantity * UnitPrice AS sales_value,
    CustomerID,
    Country,
    non_c_negative_quantity,
    zero_unit_price,
    accounting_adjustment
FROM sales_population_classification
WHERE population_status = 'accepted_sale';

-- @step accepted_sales_table_schema
-- Accepted sales có đúng cột và kiểu dữ liệu để làm nguồn cho model không?
DESCRIBE accepted_sales_lines;

-- @step accepted_sales_validation
-- Membership, grain và các trường dẫn xuất có khớp định nghĩa đã chốt không?
CREATE OR REPLACE TEMP VIEW accepted_sales_validation AS
WITH expected_accepted_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('source_row_number', 'BIGINT', 1),
        ('InvoiceNo', 'VARCHAR', 2),
        ('StockCode', 'VARCHAR', 3),
        ('product_key', 'VARCHAR', 4),
        ('Description', 'VARCHAR', 5),
        ('Quantity', 'BIGINT', 6),
        ('InvoiceDate', 'TIMESTAMP', 7),
        ('transaction_date', 'DATE', 8),
        ('UnitPrice', 'DECIMAL(18,3)', 9),
        ('sales_value', 'DECIMAL(37,3)', 10),
        ('CustomerID', 'VARCHAR', 11),
        ('Country', 'VARCHAR', 12),
        ('non_c_negative_quantity', 'BOOLEAN', 13),
        ('zero_unit_price', 'BOOLEAN', 14),
        ('accounting_adjustment', 'BOOLEAN', 15)
),
actual_accepted_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main'
      AND table_name = 'accepted_sales_lines'
),
expected_accepted_rows AS (
    SELECT source_row_number
    FROM sales_population_classification
    WHERE population_status = 'accepted_sale'
),
membership_differences AS (
    SELECT
        e.source_row_number AS expected_source_row_number,
        a.source_row_number AS actual_source_row_number
    FROM expected_accepted_rows e
    FULL OUTER JOIN accepted_sales_lines a USING (source_row_number)
    WHERE e.source_row_number IS NULL
       OR a.source_row_number IS NULL
),
derived_value_errors AS (
    SELECT COUNT(*) AS error_rows
    FROM accepted_sales_lines
    WHERE product_key IS DISTINCT FROM UPPER(TRIM(StockCode))
       OR transaction_date IS DISTINCT FROM CAST(InvoiceDate AS DATE)
       OR sales_value IS DISTINCT FROM Quantity * UnitPrice
),
checks AS (
    SELECT
        'accepted_sales_schema' AS check_name,
        COUNT(*) AS error_rows
    FROM expected_accepted_schema e
    FULL OUTER JOIN actual_accepted_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT
        'population_membership',
        COUNT(*) AS error_rows
    FROM membership_differences
    UNION ALL
    SELECT
        'source_row_number_uniqueness',
        COUNT(*) - COUNT(DISTINCT source_row_number)
    FROM accepted_sales_lines
    UNION ALL
    SELECT
        'derived_values',
        error_rows
    FROM derived_value_errors
    UNION ALL
    SELECT
        'stage_2_accepted_row_count',
        CASE WHEN COUNT(*) = 522540 THEN 0 ELSE 1 END
    FROM accepted_sales_lines
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks;

SELECT *
FROM accepted_sales_validation
ORDER BY check_name;

-- @step enforce_accepted_sales_validation
CREATE OR REPLACE TEMP TABLE accepted_sales_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Accepted sales validation failed. Do not commit; inspect accepted_sales_validation.')
END AS passed
FROM accepted_sales_validation;

SELECT * FROM accepted_sales_validation_gate;

-- @step prepare_fact_sales
-- Giá trị và số lượng bán theo ngày, sản phẩm và quốc gia là bao nhiêu?
CREATE OR REPLACE TEMP VIEW expected_fact_sales AS
SELECT
    transaction_date,
    product_key AS stock_code,
    Country AS country,
    SUM(sales_value) AS sales_value,
    CAST(SUM(Quantity) AS BIGINT) AS sales_quantity
FROM accepted_sales_lines
WHERE transaction_date >= DATE '2010-12-01'
  AND transaction_date < DATE '2011-12-01'
GROUP BY
    transaction_date,
    product_key,
    Country;

-- @step create_fact_sales
CREATE OR REPLACE TABLE fact_sales AS
SELECT * FROM expected_fact_sales;

-- @step fact_sales_table_schema
-- Fact có đúng cột và kiểu dữ liệu cho reporting model không?
DESCRIBE fact_sales;

-- @step fact_sales_validation
-- Grain, kỳ báo cáo và giá trị tổng hợp có khớp nguồn accepted sales không?
CREATE OR REPLACE TEMP VIEW fact_sales_validation AS
WITH expected_fact_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('transaction_date', 'DATE', 1),
        ('stock_code', 'VARCHAR', 2),
        ('country', 'VARCHAR', 3),
        ('sales_value', 'DECIMAL(38,3)', 4),
        ('sales_quantity', 'BIGINT', 5)
),
actual_fact_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main'
      AND table_name = 'fact_sales'
),
fact_differences AS (
    (SELECT * FROM expected_fact_sales EXCEPT ALL SELECT * FROM fact_sales)
    UNION ALL
    (SELECT * FROM fact_sales EXCEPT ALL SELECT * FROM expected_fact_sales)
),
duplicate_fact_grains AS (
    SELECT
        transaction_date,
        stock_code,
        country
    FROM fact_sales
    GROUP BY
        transaction_date,
        stock_code,
        country
    HAVING COUNT(*) > 1
),
checks AS (
    SELECT
        'fact_sales_schema' AS check_name,
        COUNT(*) AS error_rows
    FROM expected_fact_schema e
    FULL OUTER JOIN actual_fact_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT
        'fact_sales_grain_uniqueness',
        COUNT(*)
    FROM duplicate_fact_grains
    UNION ALL
    SELECT
        'fact_sales_reporting_period',
        COUNT(*)
    FROM fact_sales
    WHERE transaction_date < DATE '2010-12-01'
       OR transaction_date >= DATE '2011-12-01'
    UNION ALL
    SELECT
        'fact_sales_values',
        COUNT(*)
    FROM fact_differences
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks;

SELECT *
FROM fact_sales_validation
ORDER BY check_name;

-- @step enforce_fact_sales_validation
CREATE OR REPLACE TEMP TABLE fact_sales_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Fact sales validation failed. Do not commit; inspect fact_sales_validation.')
END AS passed
FROM fact_sales_validation;

SELECT * FROM fact_sales_validation_gate;

-- @step prepare_dim_product
-- Mỗi product key trong kỳ báo cáo nhận nhãn nào theo quy tắc Stage 2?
CREATE OR REPLACE TEMP VIEW expected_dim_product AS
WITH description_counts AS (
    SELECT
        product_key AS stock_code,
        Description AS product_description,
        COUNT(*) AS description_rows,
        MAX(InvoiceDate) AS last_seen
    FROM accepted_sales_lines
    WHERE transaction_date >= DATE '2010-12-01'
      AND transaction_date < DATE '2011-12-01'
      AND Description IS NOT NULL
    GROUP BY
        product_key,
        Description
),
ranked_descriptions AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY stock_code
            ORDER BY
                description_rows DESC,
                last_seen DESC,
                product_description
        ) AS label_rank
    FROM description_counts
)
SELECT
    stock_code,
    product_description
FROM ranked_descriptions
WHERE label_rank = 1;

-- @step create_dim_product
CREATE OR REPLACE TABLE dim_product AS
SELECT * FROM expected_dim_product;

-- @step dim_product_table_schema
-- Product dimension có đúng khóa, nhãn và kiểu dữ liệu không?
DESCRIBE dim_product;

-- @step dim_product_validation
-- Khóa có duy nhất, đủ cho fact và dùng đúng nhãn đã xếp hạng không?
CREATE OR REPLACE TEMP VIEW dim_product_validation AS
WITH expected_product_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('stock_code', 'VARCHAR', 1),
        ('product_description', 'VARCHAR', 2)
),
actual_product_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main'
      AND table_name = 'dim_product'
),
dim_product_differences AS (
    (SELECT * FROM expected_dim_product EXCEPT ALL SELECT * FROM dim_product)
    UNION ALL
    (SELECT * FROM dim_product EXCEPT ALL SELECT * FROM expected_dim_product)
),
duplicate_product_keys AS (
    SELECT stock_code
    FROM dim_product
    GROUP BY stock_code
    HAVING COUNT(*) > 1
),
fact_product_keys AS (
    SELECT DISTINCT stock_code
    FROM fact_sales
),
missing_fact_product_keys AS (
    SELECT f.stock_code
    FROM fact_product_keys f
    LEFT JOIN dim_product d USING (stock_code)
    WHERE d.stock_code IS NULL
),
unexpected_dimension_keys AS (
    SELECT d.stock_code
    FROM dim_product d
    LEFT JOIN fact_product_keys f USING (stock_code)
    WHERE f.stock_code IS NULL
),
checks AS (
    SELECT
        'dim_product_schema' AS check_name,
        COUNT(*) AS error_rows
    FROM expected_product_schema e
    FULL OUTER JOIN actual_product_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT
        'dim_product_key_uniqueness',
        COUNT(*)
    FROM duplicate_product_keys
    UNION ALL
    SELECT
        'dim_product_missing_labels',
        COUNT(*)
    FROM dim_product
    WHERE product_description IS NULL
    UNION ALL
    SELECT
        'fact_product_key_coverage',
        COUNT(*)
    FROM missing_fact_product_keys
    UNION ALL
    SELECT
        'dim_product_fact_membership',
        COUNT(*)
    FROM unexpected_dimension_keys
    UNION ALL
    SELECT
        'dim_product_values',
        COUNT(*)
    FROM dim_product_differences
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks;

SELECT *
FROM dim_product_validation
ORDER BY check_name;

-- @step enforce_dim_product_validation
CREATE OR REPLACE TEMP TABLE dim_product_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Product dimension validation failed. Do not commit; inspect dim_product_validation.')
END AS passed
FROM dim_product_validation;

SELECT * FROM dim_product_validation_gate;

-- @step prepare_dim_country
-- Mỗi quốc gia trong reporting fact có khóa và nhãn nào?
CREATE OR REPLACE TEMP VIEW expected_dim_country AS
SELECT DISTINCT
    country,
    country AS country_label
FROM fact_sales;

-- @step create_dim_country
CREATE OR REPLACE TABLE dim_country AS
SELECT * FROM expected_dim_country;

-- @step dim_country_table_schema
-- Country dimension có đúng khóa, nhãn và kiểu dữ liệu không?
DESCRIBE dim_country;

-- @step dim_country_validation
-- Khóa có duy nhất, đầy đủ cho fact và giữ đúng nhãn nguồn không?
CREATE OR REPLACE TEMP VIEW dim_country_validation AS
WITH expected_country_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('country', 'VARCHAR', 1),
        ('country_label', 'VARCHAR', 2)
),
actual_country_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main'
      AND table_name = 'dim_country'
),
dim_country_differences AS (
    (SELECT * FROM expected_dim_country EXCEPT ALL SELECT * FROM dim_country)
    UNION ALL
    (SELECT * FROM dim_country EXCEPT ALL SELECT * FROM expected_dim_country)
),
duplicate_country_keys AS (
    SELECT country
    FROM dim_country
    GROUP BY country
    HAVING COUNT(*) > 1
),
fact_country_keys AS (
    SELECT DISTINCT country
    FROM fact_sales
),
missing_fact_country_keys AS (
    SELECT f.country
    FROM fact_country_keys f
    LEFT JOIN dim_country d USING (country)
    WHERE d.country IS NULL
),
unexpected_dimension_keys AS (
    SELECT d.country
    FROM dim_country d
    LEFT JOIN fact_country_keys f USING (country)
    WHERE f.country IS NULL
),
checks AS (
    SELECT
        'dim_country_schema' AS check_name,
        COUNT(*) AS error_rows
    FROM expected_country_schema e
    FULL OUTER JOIN actual_country_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT
        'dim_country_key_uniqueness',
        COUNT(*)
    FROM duplicate_country_keys
    UNION ALL
    SELECT
        'dim_country_missing_keys_or_labels',
        COUNT(*)
    FROM dim_country
    WHERE country IS NULL
       OR country_label IS NULL
    UNION ALL
    SELECT
        'fact_country_key_coverage',
        COUNT(*)
    FROM missing_fact_country_keys
    UNION ALL
    SELECT
        'dim_country_fact_membership',
        COUNT(*)
    FROM unexpected_dimension_keys
    UNION ALL
    SELECT
        'dim_country_values',
        COUNT(*)
    FROM dim_country_differences
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks;

SELECT *
FROM dim_country_validation
ORDER BY check_name;

-- @step enforce_dim_country_validation
CREATE OR REPLACE TEMP TABLE dim_country_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Country dimension validation failed. Do not commit; inspect dim_country_validation.')
END AS passed
FROM dim_country_validation;

SELECT * FROM dim_country_validation_gate;

-- @step prepare_dim_date
-- Những ngày nào thuộc kỳ báo cáo, kể cả khi không có giao dịch?
CREATE OR REPLACE TEMP VIEW expected_dim_date AS
SELECT
    CAST(calendar_day AS DATE) AS calendar_date,
    CAST(EXTRACT(YEAR FROM calendar_day) AS INTEGER) AS year_number,
    CAST(EXTRACT(MONTH FROM calendar_day) AS INTEGER) AS month_number,
    CAST(DATE_TRUNC('month', calendar_day) AS DATE) AS month_start
FROM GENERATE_SERIES(
    DATE '2010-12-01',
    DATE '2011-11-30',
    INTERVAL 1 DAY
) AS dates(calendar_day);

-- @step create_dim_date
CREATE OR REPLACE TABLE dim_date AS
SELECT * FROM expected_dim_date;

-- @step dim_date_table_schema
-- Date dimension có đúng khóa, thuộc tính và kiểu dữ liệu không?
DESCRIBE dim_date;

-- @step dim_date_validation
-- Lịch có liên tục, khóa duy nhất và bao phủ mọi ngày trong fact không?
CREATE OR REPLACE TEMP VIEW dim_date_validation AS
WITH expected_date_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('calendar_date', 'DATE', 1),
        ('year_number', 'INTEGER', 2),
        ('month_number', 'INTEGER', 3),
        ('month_start', 'DATE', 4)
),
actual_date_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main'
      AND table_name = 'dim_date'
),
dim_date_differences AS (
    (SELECT * FROM expected_dim_date EXCEPT ALL SELECT * FROM dim_date)
    UNION ALL
    (SELECT * FROM dim_date EXCEPT ALL SELECT * FROM expected_dim_date)
),
duplicate_date_keys AS (
    SELECT calendar_date
    FROM dim_date
    GROUP BY calendar_date
    HAVING COUNT(*) > 1
),
fact_dates AS (
    SELECT DISTINCT transaction_date
    FROM fact_sales
),
missing_fact_dates AS (
    SELECT f.transaction_date
    FROM fact_dates f
    LEFT JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    WHERE d.calendar_date IS NULL
),
checks AS (
    SELECT
        'dim_date_schema' AS check_name,
        COUNT(*) AS error_rows
    FROM expected_date_schema e
    FULL OUTER JOIN actual_date_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT
        'dim_date_key_uniqueness',
        COUNT(*)
    FROM duplicate_date_keys
    UNION ALL
    SELECT
        'dim_date_missing_values',
        COUNT(*)
    FROM dim_date
    WHERE calendar_date IS NULL
       OR year_number IS NULL
       OR month_number IS NULL
       OR month_start IS NULL
    UNION ALL
    SELECT
        'fact_date_coverage',
        COUNT(*)
    FROM missing_fact_dates
    UNION ALL
    SELECT
        'dim_date_values_and_continuity',
        COUNT(*)
    FROM dim_date_differences
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks;

SELECT *
FROM dim_date_validation
ORDER BY check_name;

-- @step enforce_dim_date_validation
CREATE OR REPLACE TEMP TABLE dim_date_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Date dimension validation failed. Do not commit; inspect dim_date_validation.')
END AS passed
FROM dim_date_validation;

SELECT * FROM dim_date_validation_gate;

-- @step reporting_model_validation
-- Tất cả bảng Stage 3 có vượt các kiểm tra xây dựng model không?
CREATE OR REPLACE TEMP VIEW reporting_model_validation AS
SELECT
    'accepted_sales_lines' AS dataset_name,
    check_name,
    error_rows,
    passed
FROM accepted_sales_validation
UNION ALL
SELECT
    'fact_sales',
    check_name,
    error_rows,
    passed
FROM fact_sales_validation
UNION ALL
SELECT
    'dim_product',
    check_name,
    error_rows,
    passed
FROM dim_product_validation
UNION ALL
SELECT
    'dim_country',
    check_name,
    error_rows,
    passed
FROM dim_country_validation
UNION ALL
SELECT
    'dim_date',
    check_name,
    error_rows,
    passed
FROM dim_date_validation;

SELECT *
FROM reporting_model_validation
ORDER BY
    dataset_name,
    check_name;

-- @step enforce_reporting_model_validation
CREATE OR REPLACE TEMP TABLE reporting_model_validation_gate AS
SELECT CASE
    WHEN SUM(error_rows) = 0 THEN TRUE
    ELSE error('Reporting model validation failed. Do not commit; inspect reporting_model_validation.')
END AS passed
FROM reporting_model_validation;

SELECT * FROM reporting_model_validation_gate;

COMMIT;
